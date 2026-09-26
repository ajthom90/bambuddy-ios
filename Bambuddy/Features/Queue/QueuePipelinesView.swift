import SwiftUI

/// Pipelines tab of the Queue section: pipeline definitions plus the run history dashboard.
struct QueuePipelinesView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(LiveUpdates.self) private var live

    @State private var pipelines = Loader<[QueuePipeline]>()
    @State private var runs: [QueuePipelineRun] = []
    @State private var total = 0
    @State private var runsError: String?
    @State private var loadingRuns = false
    @State private var statusFilter = ""
    @State private var pipelineFilter: Int?
    @State private var targetFilter = ""
    @State private var search = ""
    @State private var limit = 25
    @State private var runner = ActionRunner()
    @State private var editing: QueuePipeline?
    @State private var creating = false
    @State private var runningPipeline: QueuePipeline?
    @State private var deleting: QueuePipeline?
    @State private var confirmClear = false

    private var client: APIClient { session.client }
    private static let statuses = ["queued", "slicing", "dispatching", "in_progress", "completed", "partial_failure", "failed", "cancelled"]

    private var filteredPipelines: [QueuePipeline] {
        let all = pipelines.value ?? []
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        return term.isEmpty ? all : all.filter { $0.name.lowercased().contains(term) || ($0.description ?? "").lowercased().contains(term) }
    }

    private var targetOptions: (printers: [Printer], classes: [String]) {
        var ids = Set<Int>(), classes = Set<String>()
        for p in pipelines.value ?? [] {
            if p.targetKind == "printer_class", let c = p.targetModelClass, !c.isEmpty { classes.insert(c) }
            else if let id = p.targetPrinterId { ids.insert(id) }
        }
        return (store.printers.filter { ids.contains($0.id) }, classes.sorted())
    }

    var body: some View {
        List {
            Section {
                if pipelines.value == nil, pipelines.error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let error = pipelines.error, pipelines.value == nil {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if filteredPipelines.isEmpty {
                    Text(search.isEmpty ? "No pipelines yet. Save one from the slicer, or create one here." : "No pipelines match.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredPipelines) { p in
                    pipelineRow(p)
                }
            } header: {
                HStack {
                    Text("Pipelines")
                    Spacer()
                    if session.can("pipelines:write") {
                        Button { creating = true } label: { Label("New", systemImage: "plus") }
                            .font(.caption)
                    }
                }
            }

            Section {
                if loadingRuns && runs.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let runsError, runs.isEmpty {
                    Label(runsError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if runs.isEmpty {
                    Text(hasRunFilter ? "No runs match the current filters." : "No pipeline runs yet.").foregroundStyle(.secondary)
                }
                ForEach(runs) { run in
                    NavigationLink(value: QueueRoute.pipelineRun(run.id)) {
                        QueuePipelineRunRow(run: run, pipelineName: pipelineName(run), targetLabel: targetLabel(run))
                    }
                    .swipeActions(edge: .trailing) { runActions(run) }
                    .contextMenu { runActions(run) }
                }
                if runs.count < total {
                    Button("Show More (\(runs.count) of \(total))") { limit += 25 }
                }
            } header: {
                HStack {
                    Text("Runs" + (total > 0 ? " (\(total))" : ""))
                    Spacer()
                    runFilterMenu
                }
            }
        }
        .searchable(text: $search, placement: .automatic, prompt: "Search pipelines")
        .refreshable { await reloadAll() }
        .task(id: live.revision("pipeline_run_updated", "queue_item_acked", "print_complete")) { await reloadAll() }
        .task(id: "\(statusFilter)|\(pipelineFilter ?? -1)|\(targetFilter)|\(limit)") { await loadRuns() }
        .task(id: "poll") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if runs.contains(where: \.isInFlight) { await loadRuns() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button(role: .destructive) { confirmClear = true } label: { Label("Clear Run Log", systemImage: "trash") }
                    .disabled(total == 0 || !session.can("pipelines:write"))
            }
        }
        .confirm("Clear run log?", isPresented: $confirmClear, message: "Deletes every completed, failed, cancelled and partially failed run. Runs still in progress are kept.", action: "Clear") {
            Task {
                await runner.run {
                    let r: QueuePipelineClearResult = try await client.send(.post, "pipeline-runs/clear")
                    runner.successMessage = "\(r.deleted ?? 0) runs cleared"
                    await loadRuns()
                }
            }
        }
        .confirmationDialog("Delete pipeline?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { p in
            Button("Delete \(p.name)", role: .destructive) {
                Task { await runner.run("Pipeline deleted") { try await client.call(.delete, "slicer-pipelines/\(p.id)"); await loadPipelines() } }
            }
        } message: { _ in Text("This cannot be undone.") }
        .sheet(item: $editing) { p in
            QueuePipelineEditor(pipeline: p) { Task { await loadPipelines() } }
        }
        .sheet(isPresented: $creating) {
            QueuePipelineEditor(pipeline: nil) { Task { await loadPipelines() } }
        }
        .sheet(item: $runningPipeline) { p in
            QueuePipelineRunSheet(source: nil, preselected: p) { Task { await loadRuns() } }
        }
        .actionAlerts(runner)
    }

    private var hasRunFilter: Bool { !statusFilter.isEmpty || pipelineFilter != nil || !targetFilter.isEmpty }

    private var runFilterMenu: some View {
        Menu {
            Picker("Pipeline", selection: $pipelineFilter) {
                Text("All Pipelines").tag(Int?.none)
                ForEach(pipelines.value ?? []) { Text($0.name).tag(Int?.some($0.id)) }
            }
            .pickerStyle(.menu)
            Picker("Status", selection: $statusFilter) {
                Text("All Statuses").tag("")
                ForEach(Self.statuses, id: \.self) { Text(QueueStatusStyle.pipelineLabel($0)).tag($0) }
            }
            .pickerStyle(.menu)
            let targets = targetOptions
            if !targets.printers.isEmpty || !targets.classes.isEmpty {
                Picker("Target", selection: $targetFilter) {
                    Text("All Targets").tag("")
                    ForEach(targets.printers) { Text($0.name).tag("p:\($0.id)") }
                    ForEach(targets.classes, id: \.self) { Text("Any \($0)").tag("c:\($0)") }
                }
                .pickerStyle(.menu)
            }
            if hasRunFilter {
                Button("Clear Filters") { statusFilter = ""; pipelineFilter = nil; targetFilter = "" }
            }
        } label: {
            Label("Filter", systemImage: hasRunFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.caption)
        }
    }

    private func pipelineRow(_ p: QueuePipeline) -> some View {
        Button { if session.can("pipelines:write") { editing = p } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "flowchart").foregroundStyle(.tint)
                    Text(p.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Spacer()
                    if let label = pipelineTargetLabel(p) {
                        StatusBadge(text: label, color: .blue)
                    } else {
                        StatusBadge(text: "No target", color: .orange)
                    }
                }
                if let d = p.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let bed = p.bedType, !bed.isEmpty {
                    Text(bed).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if session.can("pipelines:write") {
                Button(role: .destructive) { deleting = p } label: { Label("Delete", systemImage: "trash") }
                Button { editing = p } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
            }
        }
        .swipeActions(edge: .leading) {
            if session.can("pipelines:run") {
                Button { runningPipeline = p } label: { Label("Run", systemImage: "play.fill") }.tint(.green)
            }
        }
        .contextMenu {
            if session.can("pipelines:run") {
                Button { runningPipeline = p } label: { Label("Run…", systemImage: "play.fill") }
            }
            Button { pipelineFilter = p.id } label: { Label("Show Runs", systemImage: "list.bullet") }
            if session.can("pipelines:write") {
                Button { editing = p } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { deleting = p } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    @ViewBuilder
    private func runActions(_ run: QueuePipelineRun) -> some View {
        if run.isInFlight && session.can("pipelines:run") {
            Button(role: .destructive) {
                Task { await runner.run("Run cancelled") { let _: QueuePipelineRun = try await client.send(.post, "pipeline-runs/\(run.id)/cancel"); await loadRuns() } }
            } label: { Label("Cancel Run", systemImage: "xmark.circle") }
        }
        if run.canRetryFailed && session.can("pipelines:run") {
            Button {
                Task { await runner.run("Retry started") { let _: JSONValue = try await client.send(.post, "pipeline-runs/\(run.id)/retry-failed"); await loadRuns() } }
            } label: { Label("Retry Failed", systemImage: "arrow.counterclockwise") }
            .tint(.orange)
        }
    }

    private func pipelineName(_ run: QueuePipelineRun) -> String {
        run.pipelineId.flatMap { id in pipelines.value?.first { $0.id == id }?.name } ?? run.pipelineName ?? "Deleted pipeline"
    }

    private func targetLabel(_ run: QueuePipelineRun) -> String? {
        if run.targetKind == "printer_class", let c = run.targetModelClass, !c.isEmpty { return "Any \(c)" }
        return run.targetPrinterId.flatMap { store.printer($0)?.name }
    }

    private func pipelineTargetLabel(_ p: QueuePipeline) -> String? {
        if p.targetKind == "printer_class" { return p.targetModelClass.flatMap { $0.isEmpty ? nil : "Any \($0)" } }
        return p.targetPrinterId.map { id in store.printer(id)?.name ?? "Printer #\(id)" }
    }

    private func reloadAll() async {
        await loadPipelines()
        await loadRuns()
    }

    private func loadPipelines() async {
        await pipelines.load {
            let list: QueuePipelineList = try await client.get("slicer-pipelines/")
            return list.pipelines ?? []
        }
    }

    private func loadRuns() async {
        loadingRuns = true
        defer { loadingRuns = false }
        var query: [String: QueryValue?] = ["limit": .int(limit), "status": statusFilter.isEmpty ? nil : .string(statusFilter), "pipeline_id": .of(pipelineFilter)]
        if targetFilter.hasPrefix("p:") { query["target_printer_id"] = .of(Int(targetFilter.dropFirst(2))) }
        if targetFilter.hasPrefix("c:") { query["target_model_class"] = .string(String(targetFilter.dropFirst(2))) }
        do {
            let list: QueuePipelineRunList = try await client.get("pipeline-runs", query: query)
            runs = list.runs ?? []
            total = list.total ?? runs.count
            runsError = nil
        } catch is CancellationError {
        } catch {
            runsError = error.localizedDescription
        }
    }
}

struct QueuePipelineRunRow: View {
    let run: QueuePipelineRun
    let pipelineName: String
    let targetLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(run.id)").font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(pipelineName).font(.subheadline).lineLimit(1)
                Spacer()
                QueuePipelineStatusBadge(status: run.status ?? "queued")
            }
            if let file = run.sourceFilename {
                Label(file, systemImage: "doc").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(Fmt.date(run.createdAt))
                if let copies = run.copies, copies > 1 { Text("· \(copies) copies") }
                if (run.copiesCompleted ?? 0) + (run.copiesFailed ?? 0) + (run.copiesCancelled ?? 0) > 0 {
                    Text("· \(run.copiesCompleted ?? 0)/\(run.copies ?? 1) done")
                }
                if let f = run.copiesFailed, f > 0 { Text("· \(f) failed").foregroundStyle(.red) }
                if let t = targetLabel { Text("· \(t)") }
                if let parent = run.parentRunId { Text("· retry of #\(parent)").italic() }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct QueuePipelineStatusBadge: View {
    let status: String
    var body: some View {
        StatusBadge(text: QueueStatusStyle.pipelineLabel(status), color: Self.color(status))
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "queued", "pending": .secondary
        case "slicing", "dispatching", "awaiting_printer": .blue
        case "in_progress", "printing": .teal
        case "completed": .green
        case "failed": .red
        case "partial_failure": .orange
        case "cancelled": .pink
        default: .secondary
        }
    }
}

/// Detail of a single pipeline run with per-copy status.
struct QueuePipelineRunDetail: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(LiveUpdates.self) private var live
    let runId: Int
    @State private var loader = Loader<QueuePipelineRun>()
    @State private var runner = ActionRunner()

    var body: some View {
        LoadingContent(loader: loader, retry: load) { run in
            List {
                Section {
                    HStack {
                        Text(run.pipelineName ?? "Pipeline run").font(.headline)
                        Spacer()
                        QueuePipelineStatusBadge(status: run.status ?? "queued")
                    }
                    InfoRow("Source", run.sourceFilename, systemImage: "doc")
                    InfoRow("Target", runTarget(run), systemImage: "printer")
                    if let f = run.fanoutStrategy { InfoRow("Fan-out", QueuePipelineEditor.fanoutLabel(f)) }
                    InfoRow("Copies", "\(run.copiesCompleted ?? 0) of \(run.copies ?? 1) completed" + ((run.copiesFailed ?? 0) > 0 ? ", \(run.copiesFailed!) failed" : ""))
                    InfoRow("Created", Fmt.date(run.createdAt))
                    if run.startedAt != nil { InfoRow("Started", Fmt.date(run.startedAt)) }
                    if run.completedAt != nil { InfoRow("Finished", Fmt.date(run.completedAt)) }
                    if run.eligibilityOverridden == true { Label("Eligibility check was overridden", systemImage: "exclamationmark.shield").foregroundStyle(.orange) }
                    if let parent = run.parentRunId { InfoRow("Retry of", "#\(parent)") }
                }
                if let error = run.errorMessage, !error.isEmpty {
                    Section("Message") {
                        Text(run.cancelledByUser ? "Cancelled by user" : error).foregroundStyle(run.cancelledByUser ? Color.secondary : .red)
                    }
                }
                Section("Copies") {
                    if (run.jobs ?? []).isEmpty { Text("No copies dispatched yet.").foregroundStyle(.secondary) }
                    ForEach(run.jobs ?? []) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Copy \((job.copyIndex ?? 0) + 1)").font(.subheadline.weight(.medium))
                                Spacer()
                                QueuePipelineStatusBadge(status: job.status ?? "pending")
                            }
                            if let p = job.assignedPrinterName ?? job.assignedPrinterId.flatMap({ store.printer($0)?.name }) {
                                Label(p, systemImage: "printer").font(.caption).foregroundStyle(.secondary)
                            }
                            if let q = job.queueEntryId { Text("Queue item #\(q)").font(.caption2).foregroundStyle(.tertiary) }
                            if let e = job.errorMessage, !e.isEmpty { Text(e).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
            }
            .toolbar {
                if session.can("pipelines:run") {
                    if run.isInFlight {
                        Button("Cancel Run", role: .destructive) {
                            Task { await runner.run("Run cancelled") { loader.value = try await session.client.send(.post, "pipeline-runs/\(runId)/cancel") } }
                        }
                    } else if run.canRetryFailed {
                        Button("Retry Failed") {
                            Task { await runner.run("Retry started") { let _: JSONValue = try await session.client.send(.post, "pipeline-runs/\(runId)/retry-failed"); await load() } }
                        }
                    }
                }
            }
        }
        .navigationTitle("Run #\(runId)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: live.revision("pipeline_run_updated", "queue_item_acked", "queue_item_failed", "print_complete")) { await load() }
        .actionAlerts(runner)
    }

    private func runTarget(_ run: QueuePipelineRun) -> String? {
        if run.targetKind == "printer_class", let c = run.targetModelClass { return "Any \(c)" }
        return run.targetPrinterId.flatMap { store.printer($0)?.name }
    }

    private func load() async {
        await loader.load { try await session.client.get("pipeline-runs/\(runId)") }
    }
}

// MARK: - Editor

/// Create or edit a slicer pipeline (presets, bed type, target and fan-out).
struct QueuePipelineEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pipeline: QueuePipeline?
    var onSaved: () -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var targetKind = "specific_printer"
    @State private var targetPrinterId: Int?
    @State private var targetModelClass = ""
    @State private var fanout = "max_parallel"
    @State private var bedType = ""
    @State private var printerPreset: QueuePipelinePresetRef?
    @State private var processPreset: QueuePipelinePresetRef?
    @State private var filamentPresets: [QueuePipelinePresetRef] = []
    @State private var catalog: QueueSlicerPresetCatalog?
    @State private var runner = ActionRunner()
    @State private var saving = false

    static let fanouts: [(String, String)] = [("max_parallel", "Max Parallel"), ("fill_one_first", "Fill One First"), ("round_robin", "Round Robin")]
    static func fanoutLabel(_ key: String) -> String { fanouts.first { $0.0 == key }?.1 ?? key }
    private static let bedTypes = ["", "Cool Plate", "Engineering Plate", "High Temp Plate", "Textured PEI Plate", "Supertack Plate"]

    private var installedModels: [String] {
        Array(Set(store.printers.compactMap(\.model).filter { !$0.isEmpty })).sorted()
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if pipeline == nil { return printerPreset != nil && processPreset != nil && !filamentPresets.isEmpty }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...4)
                }
                Section {
                    presetPicker("Printer Preset", slot: "printer", selection: $printerPreset)
                    presetPicker("Process Preset", slot: "process", selection: $processPreset)
                    ForEach(filamentPresets.indices, id: \.self) { i in
                        presetPicker("Filament \(i + 1)", slot: "filament", selection: Binding(
                            get: { filamentPresets.indices.contains(i) ? filamentPresets[i] : nil },
                            set: { v in if let v, filamentPresets.indices.contains(i) { filamentPresets[i] = v } }
                        ))
                        .swipeActions { if filamentPresets.count > 1 { Button("Remove", role: .destructive) { filamentPresets.remove(at: i) } } }
                    }
                    Button { if let first = catalog?.all("filament").first { filamentPresets.append(QueuePipelinePresetRef(source: first.source ?? "standard", id: first.id)) } } label: {
                        Label("Add Filament", systemImage: "plus")
                    }
                    .disabled(catalog?.all("filament").isEmpty ?? true)
                    Picker("Bed Type", selection: $bedType) {
                        ForEach(Self.bedTypes, id: \.self) { Text($0.isEmpty ? "As in file" : $0).tag($0) }
                        if !Self.bedTypes.contains(bedType) { Text(bedType).tag(bedType) }
                    }
                } header: {
                    Text("Slicer Presets")
                } footer: {
                    if catalog == nil { Text("Loading presets…") }
                }
                Section {
                    Picker("Target", selection: $targetKind) {
                        Text("Specific Printer").tag("specific_printer")
                        Text("Printer Class").tag("printer_class")
                    }
                    .pickerStyle(.segmented)
                    if targetKind == "specific_printer" {
                        Picker("Printer", selection: $targetPrinterId) {
                            Text("None").tag(Int?.none)
                            ForEach(store.printers) { Text($0.name).tag(Int?.some($0.id)) }
                        }
                    } else {
                        Picker("Model", selection: $targetModelClass) {
                            Text("None").tag("")
                            ForEach(installedModels, id: \.self) { Text($0).tag($0) }
                            if !targetModelClass.isEmpty && !installedModels.contains(targetModelClass) { Text(targetModelClass).tag(targetModelClass) }
                        }
                        Picker("Fan-out", selection: $fanout) {
                            ForEach(Self.fanouts, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                } header: {
                    Text("Target")
                } footer: {
                    Text(targetKind == "printer_class" ? "Copies are spread across every eligible printer of this model." : "Every copy goes to this printer.")
                }
            }
            .navigationTitle(pipeline == nil ? "New Pipeline" : "Edit Pipeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave || saving)
                }
            }
            .actionAlerts(runner)
            .task { await load() }
        }
    }

    private func presetPicker(_ title: String, slot: String, selection: Binding<QueuePipelinePresetRef?>) -> some View {
        let all = catalog?.all(slot) ?? []
        let currentName = catalog?.name(for: selection.wrappedValue, slot: slot) ?? selection.wrappedValue.map { "\($0.id) (missing)" }
        return Menu {
            ForEach(QueueSlicerPresetCatalog.sources, id: \.key) { src in
                let items = all.filter { $0.source == src.key }
                if !items.isEmpty {
                    Section(src.label) {
                        ForEach(items, id: \.id) { p in
                            Button(p.name) { selection.wrappedValue = QueuePipelinePresetRef(source: src.key, id: p.id) }
                        }
                    }
                }
            }
        } label: {
            LabeledContent(title) {
                Text(currentName ?? "Choose…").foregroundStyle(currentName == nil ? .secondary : .primary).lineLimit(1)
            }
        }
    }

    private func load() async {
        if let p = pipeline {
            name = p.name
            description = p.description ?? ""
            targetKind = p.targetKind ?? "specific_printer"
            targetPrinterId = p.targetPrinterId
            targetModelClass = p.targetModelClass ?? ""
            fanout = p.fanoutStrategy ?? "max_parallel"
            bedType = p.bedType ?? ""
            printerPreset = p.printerPreset
            processPreset = p.processPreset
            filamentPresets = p.filamentPresets ?? []
        }
        catalog = try? await session.client.get("slicer/presets")
        if pipeline == nil, filamentPresets.isEmpty, let first = catalog?.all("filament").first {
            filamentPresets = [QueuePipelinePresetRef(source: first.source ?? "standard", id: first.id)]
        }
    }

    private func refJSON(_ r: QueuePipelinePresetRef) -> JSONValue { ["source": .string(r.source), "id": .string(r.id)] }

    private func save() async {
        saving = true
        defer { saving = false }
        var body: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "description": description.isEmpty ? .null : .string(description),
            "target_kind": .string(targetKind),
            "target_printer_id": .number(Double(targetKind == "specific_printer" ? (targetPrinterId ?? 0) : 0)),
            "target_model_class": .string(targetKind == "printer_class" ? targetModelClass : ""),
            "fanout_strategy": .string(fanout),
        ]
        if let printerPreset { body["printer_preset"] = refJSON(printerPreset) }
        if let processPreset { body["process_preset"] = refJSON(processPreset) }
        if !filamentPresets.isEmpty { body["filament_presets"] = .array(filamentPresets.map(refJSON)) }
        if !bedType.isEmpty { body["bed_type"] = .string(bedType) }
        await runner.run {
            let client = session.client
            if let p = pipeline {
                let _: QueuePipeline = try await client.send(.put, "slicer-pipelines/\(p.id)", body: JSONValue.object(body))
            } else {
                // Creation accepts only the base fields; the target is applied with a follow-up update.
                var create = body
                for key in ["target_kind", "target_printer_id", "target_model_class", "fanout_strategy"] { create[key] = nil }
                let created: QueuePipeline = try await client.send(.post, "slicer-pipelines/", body: JSONValue.object(create))
                var target: [String: JSONValue] = [:]
                for key in ["target_kind", "target_printer_id", "target_model_class", "fanout_strategy"] { target[key] = body[key] }
                let _: QueuePipeline = try await client.send(.put, "slicer-pipelines/\(created.id)", body: JSONValue.object(target))
            }
            onSaved()
            dismiss()
        }
    }
}

// MARK: - Run a pipeline

/// Picks a pipeline (and, when started from the Pipelines tab, a source file), checks
/// eligibility, and starts a run. Requires `pipelines:run`.
struct QueuePipelineRunSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State var source: PrintSource?
    var preselected: QueuePipeline? = nil
    var onStarted: () -> Void = {}

    @State private var pipelines: [QueuePipeline] = []
    @State private var picked: QueuePipeline?
    @State private var copies = 1
    @State private var maxCopies = 50
    @State private var report: QueuePipelineEligibility?
    @State private var checking = false
    @State private var runner = ActionRunner()
    @State private var choosingSource = false

    init(source: PrintSource?, preselected: QueuePipeline? = nil, onStarted: @escaping () -> Void = {}) {
        _source = State(initialValue: source)
        self.preselected = preselected
        self.onStarted = onStarted
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    Button { choosingSource = true } label: {
                        LabeledContent("File") {
                            Text(source?.name ?? "Choose…").foregroundStyle(source == nil ? .secondary : .primary).lineLimit(1)
                        }
                    }
                }
                Section("Pipeline") {
                    if pipelines.isEmpty { Text("No pipelines defined.").foregroundStyle(.secondary) }
                    ForEach(pipelines) { p in
                        Button {
                            picked = p
                            report = nil
                        } label: {
                            HStack {
                                Image(systemName: picked?.id == p.id ? "checkmark.circle.fill" : "circle").foregroundStyle(picked?.id == p.id ? Color.accentColor : .secondary)
                                VStack(alignment: .leading) {
                                    Text(p.name).foregroundStyle(.primary)
                                    Text(targetLabel(p) ?? "No target set").font(.caption).foregroundStyle(p.hasTarget ? Color.secondary : .orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!p.hasTarget)
                    }
                    Stepper("Copies: \(copies)", value: $copies, in: 1...max(1, maxCopies))
                }
                if let report {
                    Section {
                        if report.ok == true {
                            Label("All checks passed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        } else {
                            ForEach(Array((report.issues ?? []).enumerated()), id: \.offset) { _, issue in
                                Label(issue.summary, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            ForEach(Array((report.printerReports ?? []).enumerated()), id: \.offset) { _, pr in
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(pr.printerName ?? "Printer", systemImage: pr.ok == true ? "checkmark.circle" : "xmark.circle")
                                        .foregroundStyle(pr.ok == true ? .green : .red)
                                    ForEach(Array((pr.issues ?? []).enumerated()), id: \.offset) { _, i in
                                        Text(i.summary).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Eligibility")
                    } footer: {
                        if report.ok != true { Text("You can run anyway; the eligibility override is recorded on the run.") }
                    }
                }
            }
            .navigationTitle("Run with Pipeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if let report, report.ok != true {
                        Button("Run Anyway") { Task { await run(force: true) } }.disabled(runner.isRunning)
                    } else {
                        Button("Run") { Task { await checkAndRun() } }.disabled(picked == nil || source == nil || checking || runner.isRunning)
                    }
                }
            }
            .overlay { if checking || runner.isRunning { ProgressView().padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
            .actionAlerts(runner)
            .sheet(isPresented: $choosingSource) {
                QueueSourcePicker { source = $0; report = nil }
            }
            .task { await load() }
        }
    }

    private func targetLabel(_ p: QueuePipeline) -> String? {
        if p.targetKind == "printer_class" { return p.targetModelClass.flatMap { $0.isEmpty ? nil : "Any \($0)" } }
        return p.targetPrinterId.map { id in store.printer(id)?.name ?? "Printer #\(id)" }
    }

    private var sourceBody: [String: JSONValue] {
        switch source {
        case .archive(let id, _)?: ["source_archive_id": .number(Double(id))]
        case .libraryFile(let id, _)?: ["source_library_file_id": .number(Double(id))]
        case nil: [:]
        }
    }

    private func load() async {
        let list: QueuePipelineList? = try? await session.client.get("slicer-pipelines/")
        pipelines = list?.pipelines ?? []
        if let preselected { picked = pipelines.first { $0.id == preselected.id } ?? preselected }
        if let settings: JSONValue = try? await session.client.get("settings/"), let m = settings["pipeline_max_copies"]?.intValue { maxCopies = m }
    }

    private func checkAndRun() async {
        guard let picked else { return }
        checking = true
        var body = sourceBody
        body["force"] = false
        let result: QueuePipelineEligibility?
        do {
            result = try await session.client.send(.post, "slicer-pipelines/\(picked.id)/check-eligibility", body: JSONValue.object(body))
        } catch {
            checking = false
            runner.errorMessage = error.localizedDescription
            return
        }
        checking = false
        report = result
        if result?.ok == true { await run(force: false) }
    }

    private func run(force: Bool) async {
        guard let picked else { return }
        var body = sourceBody
        body["force"] = .bool(force)
        body["copies"] = .number(Double(copies))
        await runner.run {
            let _: QueuePipelineRun = try await session.client.send(.post, "slicer-pipelines/\(picked.id)/run", body: JSONValue.object(body))
            onStarted()
            dismiss()
        }
    }
}

/// Lets the user pick a library file or archive as the source of a pipeline run.
struct QueueSourcePicker: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var onPick: (PrintSource) -> Void
    @State private var kind = 0
    @State private var files = Loader<[JSONValue]>()
    @State private var archives = Loader<[JSONValue]>()
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Picker("Source", selection: $kind) {
                    Text("Files").tag(0)
                    Text("Archives").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                let loader = kind == 0 ? files : archives
                if let error = loader.error, loader.value == nil {
                    Text(error).foregroundStyle(.secondary)
                } else if loader.value == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(Array(filtered(loader.value ?? []).enumerated()), id: \.offset) { _, row in
                    let id = row["id"]?.intValue ?? 0
                    let name = row["print_name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? row["filename"]?.stringValue ?? "#\(id)"
                    Button {
                        onPick(kind == 0 ? .libraryFile(id: id, name: name) : .archive(id: id, name: name))
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            RemoteImage(path: kind == 0 ? "library/files/\(id)/thumbnail" : "archives/\(id)/thumbnail", systemImage: "cube")
                                .frame(width: 40, height: 40).clipShape(.rect(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(name).foregroundStyle(.primary).lineLimit(1)
                                if let m = row["sliced_for_model"]?.stringValue { Text(m).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Choose Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: kind) {
                if kind == 0, files.value == nil {
                    await files.load {
                        let all: [JSONValue] = try await session.client.get("library/files/", query: ["include_root": true, "recursive": true])
                        return all.filter { ["3mf", "gcode"].contains(($0["file_type"]?.stringValue ?? "").lowercased()) || ($0["filename"]?.stringValue ?? "").lowercased().hasSuffix(".3mf") }
                    }
                } else if kind == 1, archives.value == nil {
                    await archives.load { try await session.client.get("archives/", query: ["limit": 200]) }
                }
            }
        }
    }

    private func filtered(_ rows: [JSONValue]) -> [JSONValue] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return rows }
        return rows.filter {
            ($0["filename"]?.stringValue ?? "").lowercased().contains(term) || ($0["print_name"]?.stringValue ?? "").lowercased().contains(term)
        }
    }
}
