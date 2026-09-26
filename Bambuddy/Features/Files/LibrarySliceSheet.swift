import SwiftUI

/// Slices an STL / 3MF library file with the server's slicer sidecar, then
/// tracks the background job until the sliced file lands in the library.
struct LibrarySliceSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let file: LibraryFileRef
    var onSliced: () -> Void = {}

    @State private var catalog = Loader<LibrarySlicerPresetCatalog>()
    @State private var plates: LibraryPlatesResponse?
    @State private var slots: [LibraryPlateFilament] = []
    @State private var printerKey: String?
    @State private var processKey: String?
    @State private var filamentKeys: [String?] = []
    @State private var plate: Int? = nil
    @State private var bedType: String = ""
    @State private var useEmbedded = false
    @State private var autoOrient = false
    @State private var autoArrange = false
    @State private var job: LibrarySliceJob?
    @State private var jobId: Int?
    @State private var errorMessage: String?
    @State private var submitting = false
    @State private var printSliced: LibraryFileRef?

    private static let bedTypes = ["Cool Plate", "Engineering Plate", "High Temp Plate", "Textured PEI Plate",
                                   "Smooth PEI Plate", "Cool Plate (SuperTack)", "Supertack Plate"]

    private var is3MF: Bool { file.filename.lowercased().hasSuffix(".3mf") }
    private var plateList: [LibraryPlate] { plates?.plates ?? [] }

    var body: some View {
        NavigationStack {
            Group {
                if let jobId {
                    progressView(jobId: jobId)
                } else {
                    LoadingContent(loader: catalog, retry: load) { catalog in
                        form(catalog)
                    }
                }
            }
            .navigationTitle("Slice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(job?.isFinished == true || jobId == nil ? "Close" : "Hide") { dismiss() }
                }
                if jobId == nil, let catalog = catalog.value {
                    ToolbarItem(placement: .confirmationAction) {
                        if submitting { ProgressView() } else {
                            Button("Slice") { Task { await submit(catalog) } }
                                .disabled(!isReady(catalog))
                        }
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: plate) { old, _ in
            guard old != nil else { return }
            Task { await loadSlots(); applyDefaults() }
        }
        .onChange(of: printerKey) { _, _ in
            guard let catalog = catalog.value else { return }
            let printer = catalog.printers.first { $0.key == printerKey }
            let procs = compatible(catalog.processes, with: printer)
            if !procs.contains(where: { $0.key == processKey }) { processKey = procs.first?.key }
            let fils = compatible(catalog.filaments, with: printer)
            for i in filamentKeys.indices where !fils.contains(where: { $0.key == filamentKeys[i] }) { filamentKeys[i] = nil }
            applyDefaults()
        }
        .sheet(item: $printSliced) { sliced in
            PrintJobSheet(source: .libraryFile(id: sliced.id, name: sliced.displayName), mode: .printNow)
        }
    }

    // MARK: Form

    @ViewBuilder
    private func form(_ catalog: LibrarySlicerPresetCatalog) -> some View {
        let printers = catalog.printers
        let selectedPrinter = printers.first { $0.key == printerKey }
        let processes = compatible(catalog.processes, with: selectedPrinter)
        let filaments = compatible(catalog.filaments, with: selectedPrinter)
        Form {
            Section {
                LabeledContent("File", value: file.displayName)
            } footer: {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            if printers.isEmpty {
                Section {
                    Text("No slicer presets are available. Import presets or sign in to Bambu Cloud / Orca Cloud on the server.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Presets") {
                Picker("Printer", selection: $printerKey) {
                    Text("Choose…").tag(String?.none)
                    presetOptions(printers)
                }
                Picker("Process", selection: $processKey) {
                    Text("Choose…").tag(String?.none)
                    presetOptions(processes)
                }
                ForEach(filamentKeys.indices, id: \.self) { index in
                    Picker(selection: Binding(get: { filamentKeys[index] }, set: { filamentKeys[index] = $0 })) {
                        Text("Choose…").tag(String?.none)
                        presetOptions(filaments)
                    } label: {
                        HStack(spacing: 8) {
                            if index < slots.count { ColorSwatch(hex: slots[index].color, size: 16) }
                            Text(filamentKeys.count == 1 ? "Filament" : "Filament \(slotLabel(index))")
                            if index < slots.count, let type = slots[index].type, !type.isEmpty {
                                Text(type).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let cloud = catalog.cloudStatus, cloud != "ok", cloud != "not_authenticated" {
                    Label("Bambu Cloud presets: \(cloud.replacingOccurrences(of: "_", with: " "))", systemImage: "exclamationmark.icloud")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if is3MF, plateList.count > 1 {
                Section("Plate") {
                    Picker("Plate", selection: $plate) {
                        Text("All Plates").tag(Int?.some(0))
                        ForEach(plateList) { p in
                            Text("Plate \(p.index)\(p.name.map { " · \($0)" } ?? "")").tag(Int?.some(p.index))
                        }
                    }
                }
            }
            Section {
                Picker("Build Plate", selection: $bedType) {
                    Text("From Process Preset").tag("")
                    ForEach(Self.bedTypes, id: \.self) { Text($0).tag($0) }
                }
                if is3MF {
                    Toggle("Slice as Designed", isOn: $useEmbedded)
                }
                Toggle("Auto Orient", isOn: $autoOrient)
                Toggle("Auto Arrange", isOn: $autoArrange)
            } header: {
                Text("Options")
            } footer: {
                Text(is3MF
                     ? "“Slice as Designed” uses the settings embedded in the 3MF instead of the chosen process preset. Auto orient and arrange move objects the designer placed."
                     : "Auto orient and arrange let the slicer rotate and lay out the model before slicing.")
            }
        }
    }

    @ViewBuilder
    private func presetOptions(_ presets: [LibrarySlicerPreset]) -> some View {
        ForEach(presets, id: \.key) { preset in
            Text("\(preset.name)\(sourceSuffix(preset.source))").tag(String?.some(preset.key))
        }
    }

    private func sourceSuffix(_ source: String) -> String {
        switch source {
        case "cloud": " (Bambu Cloud)"
        case "orca_cloud": " (Orca Cloud)"
        case "local": " (Imported)"
        default: ""
        }
    }

    private func slotLabel(_ index: Int) -> String {
        if index < slots.count, let id = slots[index].slotId { return "\(id)" }
        return "\(index + 1)"
    }

    /// Presets that declare compatibility with the chosen printer (presets
    /// without a compatibility list are always offered).
    private func compatible(_ presets: [LibrarySlicerPreset], with printer: LibrarySlicerPreset?) -> [LibrarySlicerPreset] {
        guard let printer else { return presets }
        let filtered = presets.filter { p in
            guard let list = p.compatiblePrinters, !list.isEmpty else { return true }
            return list.contains(printer.name)
        }
        return filtered.isEmpty ? presets : filtered
    }

    private func isReady(_ catalog: LibrarySlicerPresetCatalog) -> Bool {
        printerKey != nil && processKey != nil && !filamentKeys.isEmpty && filamentKeys.allSatisfy { $0 != nil }
    }

    // MARK: Progress

    @ViewBuilder
    private func progressView(jobId: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()
            if let job, job.status == "completed" {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("Slicing Complete").font(.title2.bold())
                if let result = job.result {
                    VStack(spacing: 6) {
                        if let name = result["name"]?.stringValue { Text(name).font(.headline).multilineTextAlignment(.center) }
                        HStack(spacing: 16) {
                            Label(Fmt.duration(seconds: result["print_time_seconds"]?.doubleValue), systemImage: "clock")
                            Label(Fmt.grams(result["filament_used_g"]?.doubleValue), systemImage: "scalemass")
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                        if let fallback = result["external_write_fallback"]?.stringValue, !fallback.isEmpty {
                            Text("The source folder couldn't receive the file (\(fallback)); it was saved to the library root instead.")
                                .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                        }
                    }
                }
                if let id = job.resultFileId, session.can("queue:create") {
                    Button("Print…", systemImage: "printer") {
                        printSliced = LibraryFileRef(id: id, filename: job.result?["name"]?.stringValue ?? "Sliced file")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if let job, job.status == "failed" {
                Image(systemName: "xmark.octagon.fill").font(.system(size: 56)).foregroundStyle(.red)
                Text("Slicing Failed").font(.title2.bold())
                Text(job.errorDetail ?? "The slicer reported an error.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { self.jobId = nil; self.job = nil }
                    .buttonStyle(.bordered)
            } else {
                let percent = job?.progress?.totalPercent
                if let percent {
                    ProgressView(value: min(max(percent, 0), 100), total: 100)
                        .frame(maxWidth: 280)
                } else {
                    ProgressView().controlSize(.large)
                }
                Text(stageText).font(.headline)
                if let percent { Text("\(Int(percent))%").monospacedDigit().foregroundStyle(.secondary) }
                Text("You can close this sheet; slicing continues on the server and the result appears in the library.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding()
        .task(id: jobId) { await poll(jobId) }
    }

    private var stageText: String {
        guard let job else { return "Queued…" }
        var text = job.progress?.stage ?? (job.status == "pending" ? "Waiting for slicer…" : "Slicing…")
        if let i = job.progress?.multiPlateIndex, let n = job.progress?.multiPlateCount {
            text = "Plate \(i) of \(n) · " + text
        }
        return text
    }

    // MARK: Networking

    private func load() async {
        let client = session.client
        await catalog.load { try await client.get("slicer/presets") }
        if is3MF {
            plates = try? await client.get("library/files/\(file.id)/plates")
            if let count = plates?.plates?.count, count > 1, plate == nil { plate = plates?.plates?.first?.index }
        }
        await loadSlots()
        applyDefaults()
    }

    private func loadSlots() async {
        var query: [String: QueryValue?] = ["full_slots": true]
        if let plate, plate > 0 { query["plate_id"] = .int(plate) }
        let reqs: LibraryFilamentRequirements? = try? await session.client.get("library/files/\(file.id)/filament-requirements", query: query)
        slots = (reqs?.filaments ?? []).sorted { ($0.slotId ?? 0) < ($1.slotId ?? 0) }
        let count = max(slots.count, 1)
        if filamentKeys.count != count { filamentKeys = Array(repeating: nil, count: count) }
    }

    private func applyDefaults() {
        guard let catalog = catalog.value else { return }
        if printerKey == nil {
            let embedded = plates?.embeddedPrinter
            printerKey = (catalog.printers.first { $0.name == embedded } ?? catalog.printers.first)?.key
        }
        let printer = catalog.printers.first { $0.key == printerKey }
        if processKey == nil {
            let procs = compatible(catalog.processes, with: printer)
            let embedded = plates?.embeddedProcess
            processKey = (procs.first { $0.name == embedded } ?? procs.first)?.key
        }
        let fils = compatible(catalog.filaments, with: printer)
        for i in filamentKeys.indices where filamentKeys[i] == nil {
            let type = i < slots.count ? slots[i].type?.lowercased() : nil
            filamentKeys[i] = (fils.first { type != nil && $0.filamentType?.lowercased() == type } ?? fils.first)?.key
        }
    }

    private func submit(_ catalog: LibrarySlicerPresetCatalog) async {
        let all = catalog.printers + catalog.processes + catalog.filaments
        func ref(_ key: String?) -> LibraryPresetRefBody? {
            guard let key, let p = all.first(where: { $0.key == key }) else { return nil }
            return LibraryPresetRefBody(source: p.source, id: p.id)
        }
        guard let printer = ref(printerKey), let process = ref(processKey) else { return }
        let filaments = filamentKeys.compactMap(ref)
        guard let first = filaments.first, filaments.count == filamentKeys.count else { return }
        let colours = filamentKeys.indices.map { i -> String in
            guard i < slots.count, let c = slots[i].color, !c.isEmpty else { return "" }
            return c.hasPrefix("#") ? c : "#" + c
        }
        let body = LibrarySliceBody(
            printerPreset: printer, processPreset: process, filamentPreset: first, filamentPresets: filaments,
            filamentColours: colours.contains { !$0.isEmpty } ? colours.map { validHex($0) ? $0 : "" } : nil,
            plate: plateList.count > 1 ? plate : nil,
            bedType: bedType.isEmpty ? nil : bedType,
            useEmbeddedSettings: is3MF && useEmbedded ? true : nil,
            autoOrient: autoOrient ? true : nil,
            autoArrange: autoArrange ? true : nil)
        submitting = true
        defer { submitting = false }
        do {
            let enqueued: LibrarySliceEnqueued = try await session.client.send(.post, "library/files/\(file.id)/slice", body: body)
            errorMessage = nil
            jobId = enqueued.jobId
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func validHex(_ s: String) -> Bool {
        s.range(of: "^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", options: .regularExpression) != nil
    }

    private func poll(_ id: Int) async {
        while !Task.isCancelled {
            if let state: LibrarySliceJob = try? await session.client.get("slice-jobs/\(id)") {
                job = state
                if state.isFinished {
                    if state.status == "completed" { onSliced() }
                    return
                }
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
}
