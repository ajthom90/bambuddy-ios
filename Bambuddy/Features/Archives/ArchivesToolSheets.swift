import SwiftUI

// MARK: Filters

/// All archive filters (collections, printer, material, colors, tags, user,
/// project, file type, date range, toggles).
struct ArchivesFilterSheet: View {
    @Environment(PrinterStore.self) private var printers
    @Environment(ArchivesLookups.self) private var lookups
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ArchivesBrowserModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Collection", selection: $model.filters.collection) {
                        ForEach(ArchivesCollection.allCases) { c in Label(c.title, systemImage: c.systemImage).tag(c) }
                    }
                    Picker("Sort", selection: $model.filters.sort) {
                        ForEach(ArchivesSort.allCases) { s in Text(s.title).tag(s) }
                    }
                }
                Section("Show") {
                    Toggle("Favorites Only", isOn: $model.filters.favoritesOnly)
                    Toggle("Hide Failed Prints", isOn: $model.filters.hideFailed)
                    Toggle("Hide Duplicates", isOn: $model.filters.hideDuplicates)
                    Picker("File Type", selection: $model.filters.fileType) {
                        ForEach(ArchivesFileTypeFilter.allCases) { t in Text(t.title).tag(t) }
                    }
                }
                Section("Source") {
                    Picker("Printer", selection: $model.filters.printerId) {
                        Text("All Printers").tag(Int?.none)
                        ForEach(printers.printers) { p in Text(p.name).tag(Int?.some(p.id)) }
                    }
                    if !lookups.projects.isEmpty {
                        Picker("Project", selection: $model.filters.projectId) {
                            Text("All Projects").tag(Int?.none)
                            ForEach(lookups.projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { p in
                                Text(p.name).tag(Int?.some(p.id))
                            }
                        }
                    }
                    if !model.users.isEmpty {
                        Picker("Uploaded By", selection: $model.filters.user) {
                            Text("Anyone").tag(String?.none)
                            ForEach(model.users, id: \.self) { u in Text(u).tag(String?.some(u)) }
                        }
                    }
                    if !model.materials.isEmpty {
                        Picker("Material", selection: $model.filters.material) {
                            Text("All Materials").tag(String?.none)
                            ForEach(model.materials, id: \.self) { m in Text(m).tag(String?.some(m)) }
                        }
                    }
                    if !model.tags.isEmpty {
                        Picker("Tag", selection: $model.filters.tag) {
                            Text("All Tags").tag(String?.none)
                            ForEach(model.tags, id: \.self) { t in Text(t).tag(String?.some(t)) }
                        }
                    }
                }
                if !model.colors.isEmpty {
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 10)], spacing: 10) {
                            ForEach(model.colors, id: \.self) { hex in
                                let on = model.filters.colors.contains(hex)
                                Button {
                                    if on { model.filters.colors.remove(hex) } else { model.filters.colors.insert(hex) }
                                } label: {
                                    Circle()
                                        .fill(Color(hex: hex) ?? .gray)
                                        .frame(width: 30, height: 30)
                                        .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1) }
                                        .overlay { if on { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white).shadow(radius: 1) } }
                                        .padding(3)
                                        .overlay { if on { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(hex)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                        if model.filters.colors.count > 1 {
                            Picker("Match", selection: $model.filters.colorsMatchAll) {
                                Text("Any Color").tag(false)
                                Text("All Colors").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        if !model.filters.colors.isEmpty {
                            Button("Clear Colors") { model.filters.colors.removeAll() }
                        }
                    } header: {
                        Text("Colors")
                    }
                }
                Section("Date Archived") {
                    Toggle("From", isOn: Binding(get: { model.filters.dateFrom != nil }, set: { model.filters.dateFrom = $0 ? (model.filters.dateFrom ?? Calendar.current.date(byAdding: .month, value: -1, to: Date())) : nil }))
                    if let from = model.filters.dateFrom {
                        DatePicker("From", selection: Binding(get: { from }, set: { model.filters.dateFrom = $0 }), displayedComponents: .date)
                    }
                    Toggle("To", isOn: Binding(get: { model.filters.dateTo != nil }, set: { model.filters.dateTo = $0 ? (model.filters.dateTo ?? Date()) : nil }))
                    if let to = model.filters.dateTo {
                        DatePicker("To", selection: Binding(get: { to }, set: { model.filters.dateTo = $0 }), displayedComponents: .date)
                    }
                }
                if model.filters.activeCount > 0 {
                    Section {
                        Button("Reset Filters", role: .destructive) { model.filters.resetRefinements() }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: Compare

/// Side-by-side comparison of 2–5 archives with success/failure insights.
struct ArchivesCompareSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    @Environment(\.dismiss) private var dismiss
    let archiveIds: [Int]
    @State private var loader = Loader<ArchivesComparison>()
    @State private var differencesOnly = false

    var body: some View {
        NavigationStack {
            LoadingContent(loader: loader, retry: load) { result in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        insights(result)
                        table(result)
                    }
                    .padding()
                }
            }
            .navigationTitle("Compare \(archiveIds.count) Archives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $differencesOnly) { Label("Differences Only", systemImage: "line.3.horizontal.decrease") }
                        .toggleStyle(.button)
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func insights(_ result: ArchivesComparison) -> some View {
        if let corr = result.successCorrelation {
            VStack(alignment: .leading, spacing: 8) {
                Label("Success Analysis", systemImage: "lightbulb").font(.headline)
                if corr.hasBothOutcomes == true {
                    Text("\(corr.successfulCount ?? 0) successful · \(corr.failedCount ?? 0) failed")
                        .font(.subheadline).foregroundStyle(.secondary)
                    let list = corr.insights ?? []
                    if list.isEmpty {
                        Text("No setting clearly separates the successful prints from the failed ones.").font(.subheadline)
                    }
                    ForEach(Array(list.enumerated()), id: \.offset) { _, insight in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(insight.insight ?? insight.label ?? "").font(.subheadline.weight(.medium))
                            if let s = insight.successAvg, let f = insight.failedAvg {
                                Text("Successful avg \(Fmt.number(s, digits: 2)) · Failed avg \(Fmt.number(f, digits: 2))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if let s = insight.successValues, let f = insight.failedValues {
                                Text("Successful: \(s.map(\.displayString).joined(separator: ", ")) · Failed: \(f.map(\.displayString).joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text(corr.message ?? "Compare successful and failed prints to see what differed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
        }
    }

    private func table(_ result: ArchivesComparison) -> some View {
        let fields = (differencesOnly ? result.differences : result.comparison) ?? []
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(result.archives) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            RemoteImage(path: "archives/\(a.id)/thumbnail", contentMode: .fit, systemImage: "cube")
                                .frame(width: 120, height: 80)
                                .clipShape(.rect(cornerRadius: 8))
                            Text(a.printName ?? "#\(a.id)").font(.subheadline.weight(.semibold)).lineLimit(2)
                            ArchivesStatusBadge(status: a.status)
                            Text([a.printerId.flatMap { printers.printer($0)?.name }, a.projectName].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(Fmt.date(a.createdAt)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(width: 140, alignment: .leading)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(fields) { field in
                    GridRow {
                        Text(field.label ?? field.field)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(field.hasDifference == true ? Color.orange : .primary)
                            .frame(width: 130, alignment: .leading)
                        ForEach(Array((field.values ?? []).enumerated()), id: \.offset) { _, v in
                            Text(v.isNull ? "—" : v.displayString + (field.unit.map { v.isNull ? "" : " \($0)" } ?? ""))
                                .font(.subheadline)
                                .frame(width: 140, alignment: .leading)
                        }
                    }
                }
                if fields.isEmpty {
                    Text(differencesOnly ? "These archives have identical settings." : "No comparable fields.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        await loader.load {
            try await session.client.get("archives/compare", query: ["archive_ids": .string(archiveIds.map(String.init).joined(separator: ","))])
        }
    }
}

// MARK: Batch tags

/// Add or remove tags on several archives.
struct ArchivesBatchTagSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(ArchivesLookups.self) private var lookups
    @Environment(\.dismiss) private var dismiss
    let archiveIds: [Int]
    let knownTags: [String]
    @State private var removing = false
    @State private var chosen = Set<String>()
    @State private var newTag = ""
    @State private var runner = ActionRunner()
    @State private var progress = 0

    private var allTags: [String] {
        Array(Set(knownTags + lookups.tags.map(\.name) + chosen)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $removing) {
                        Text("Add Tags").tag(false)
                        Text("Remove Tags").tag(true)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Applies to \(archiveIds.count) selected archive\(archiveIds.count == 1 ? "" : "s").")
                }
                if !removing {
                    Section("New Tag") {
                        HStack {
                            TextField("Tag name", text: $newTag).textInputAutocapitalization(.never).onSubmit(addNew)
                            Button("Add", action: addNew).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                Section("Tags") {
                    if allTags.isEmpty { Text("No tags yet.").foregroundStyle(.secondary) }
                    ForEach(allTags, id: \.self) { tag in
                        Button {
                            if chosen.contains(tag) { chosen.remove(tag) } else { chosen.insert(tag) }
                        } label: {
                            HStack {
                                Text(tag).foregroundStyle(.primary)
                                Spacer()
                                if chosen.contains(tag) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(removing ? "Remove Tags" : "Add Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { Text("\(progress)/\(archiveIds.count)").monospacedDigit() } else {
                        Button("Apply") { Task { await apply() } }.disabled(chosen.isEmpty)
                    }
                }
            }
            .actionAlerts(runner)
        }
    }

    private func addNew() {
        for part in newTag.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { chosen.insert(t) }
        }
        newTag = ""
    }

    private func apply() async {
        progress = 0
        await runner.run {
            // Sequential, like the web UI (the server uses SQLite).
            for id in archiveIds {
                let archive: ArchivesRecord = try await session.client.get("archives/\(id)")
                var tags = archive.tagList
                if removing { tags.removeAll { chosen.contains($0) } } else { for t in chosen.sorted() where !tags.contains(t) { tags.append(t) } }
                var body = ArchivesUpdate()
                body.set("tags", tags.joined(separator: ", "))
                let _: ArchivesRecord = try await session.client.send(.patch, "archives/\(id)", body: body)
                progress += 1
            }
            await lookups.refreshTags(client: session.client)
            dismiss()
        }
    }
}

// MARK: Batch project

/// Assign several archives to a project, or remove them from their project.
struct ArchivesBatchProjectSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(ArchivesLookups.self) private var lookups
    @Environment(\.dismiss) private var dismiss
    let archiveIds: [Int]
    @State private var query = ""
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(role: .destructive) { Task { await removeFromProjects() } } label: {
                        Label("Remove from Project", systemImage: "xmark.circle")
                    }
                }
                Section("Projects") {
                    let list = lookups.assignableProjects().filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                    if list.isEmpty { Text("No projects available.").foregroundStyle(.secondary) }
                    ForEach(list) { project in
                        Button { Task { await assign(project) } } label: {
                            HStack {
                                Circle().fill(Color(hex: project.color) ?? .gray).frame(width: 12, height: 12)
                                Text(project.name).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search projects")
            .navigationTitle("Add \(archiveIds.count) to Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if runner.isRunning { ToolbarItem(placement: .confirmationAction) { ProgressView() } }
            }
            .disabled(runner.isRunning)
            .actionAlerts(runner)
            .task { if lookups.projects.isEmpty { await lookups.refresh(client: session.client) } }
        }
    }

    private func assign(_ project: ArchivesProjectOption) async {
        await runner.run {
            try await session.client.call(.post, "projects/\(project.id)/add-archives", body: ArchivesAddToProjectBody(archiveIds: archiveIds))
            dismiss()
        }
    }

    private func removeFromProjects() async {
        await runner.run {
            for id in archiveIds {
                var body = ArchivesUpdate()
                body.set("project_id", nil as Int?)
                let _: ArchivesRecord = try await session.client.send(.patch, "archives/\(id)", body: body)
            }
            dismiss()
        }
    }
}

// MARK: Tag management

/// Rename or delete tags across all archives.
struct ArchivesTagManagerSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(ArchivesLookups.self) private var lookups
    @Environment(\.dismiss) private var dismiss
    @State private var loader = Loader<[ArchivesTagCount]>()
    @State private var runner = ActionRunner()
    @State private var renaming: ArchivesTagCount?
    @State private var newName = ""
    @State private var deleting: ArchivesTagCount?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            LoadingContent(loader: loader, retry: load) { tags in
                let filtered = tags.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                List {
                    if tags.isEmpty {
                        ContentUnavailableView("No Tags", systemImage: "tag", description: Text("Add tags to archives to organize them."))
                    }
                    ForEach(filtered) { tag in
                        LabeledContent(tag.name) { Text("\(tag.count ?? 0)").monospacedDigit() }
                            .swipeActions {
                                if ArchivesPermissions.canAdminister(session) {
                                    Button(role: .destructive) { deleting = tag } label: { Label("Delete", systemImage: "trash") }
                                    Button { newName = tag.name; renaming = tag } label: { Label("Rename", systemImage: "pencil") }.tint(.blue)
                                }
                            }
                            .contextMenu {
                                if ArchivesPermissions.canAdminister(session) {
                                    Button { newName = tag.name; renaming = tag } label: { Label("Rename", systemImage: "pencil") }
                                    Button(role: .destructive) { deleting = tag } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                    }
                }
                .searchable(text: $query, prompt: "Search tags")
            }
            .navigationTitle("Manage Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .alert("Rename Tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("New name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { if let tag = renaming { Task { await rename(tag) } } }
            } message: {
                Text("Renames the tag on every archive that uses it.")
            }
            .confirmationDialog("Delete tag “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete from \(deleting?.count ?? 0) archive(s)", role: .destructive) { if let tag = deleting { Task { await delete(tag) } } }
            }
            .actionAlerts(runner)
        }
    }

    private func path(_ name: String) -> String {
        "archives/tags/" + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
    }

    private func load() async {
        await loader.load { try await session.client.get("archives/tags") }
        if let tags = loader.value { lookups.tags = tags }
    }

    private func rename(_ tag: ArchivesTagCount) async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != tag.name else { return }
        await runner.run {
            let r: ArchivesAffectedResponse = try await session.client.send(.put, path(tag.name), body: ArchivesTagRenameBody(newName: name))
            runner.successMessage = "Renamed on \(r.affected ?? 0) archive(s)"
        }
        await load()
    }

    private func delete(_ tag: ArchivesTagCount) async {
        await runner.run {
            let r: ArchivesAffectedResponse = try await session.client.send(.delete, path(tag.name))
            runner.successMessage = "Removed from \(r.affected ?? 0) archive(s)"
        }
        await load()
    }
}

// MARK: Purge

/// Bulk-delete archives older than N days, with a live preview.
struct ArchivesPurgeSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var days = 365
    @State private var purgeStats = false
    @State private var preview: ArchivesPurgePreview?
    @State private var loadingPreview = false
    @State private var confirm = false
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $days, in: 1...3650, step: days >= 60 ? 30 : 1) {
                        LabeledContent("Older Than", value: "\(days) day\(days == 1 ? "" : "s")")
                    }
                    Toggle("Also remove from statistics", isOn: $purgeStats)
                } footer: {
                    Text("Deletes the files of archives created before the cutoff. By default their filament, time and cost still count in statistics.")
                }
                Section("Preview") {
                    if loadingPreview && preview == nil {
                        ProgressView()
                    } else if let preview {
                        LabeledContent("Archives", value: "\(preview.count ?? 0)")
                        LabeledContent("Space Freed", value: Fmt.bytes(preview.totalBytes))
                        ForEach(preview.sampleFilenames ?? [], id: \.self) { name in
                            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if (preview.count ?? 0) > (preview.sampleFilenames?.count ?? 0) {
                            Text("…and \((preview.count ?? 0) - (preview.sampleFilenames?.count ?? 0)) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("Purge \(preview?.count ?? 0) Archive\((preview?.count ?? 0) == 1 ? "" : "s")", role: .destructive) { confirm = true }
                        .disabled((preview?.count ?? 0) == 0 || runner.isRunning)
                }
            }
            .navigationTitle("Purge Old Archives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task(id: "\(days)-\(purgeStats)") {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                loadingPreview = true
                defer { loadingPreview = false }
                if let p: ArchivesPurgePreview = try? await session.client.get("archives/purge/preview", query: ["older_than_days": .int(days), "purge_stats": .bool(purgeStats)]) {
                    preview = p
                }
            }
            .task {
                if let s: ArchivesPurgeSettings = try? await session.client.get("archives/purge/settings"), let d = s.days, d > 0 {
                    days = d
                }
            }
            .confirmationDialog("Permanently delete \(preview?.count ?? 0) archives?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Purge", role: .destructive) { Task { await purge() } }
            } message: {
                Text("This cannot be undone.")
            }
            .actionAlerts(runner)
        }
    }

    private func purge() async {
        await runner.run {
            let r: ArchivesPurgeResult = try await session.client.send(.post, "archives/purge", body: ArchivesPurgeRequest(olderThanDays: days, purgeStats: purgeStats))
            runner.successMessage = "Purged \(r.deleted ?? 0) archive(s)"
            preview = nil
        }
        if runner.errorMessage == nil { dismiss() }
    }
}

// MARK: Upload

/// Upload one or more 3MF files as archives.
struct ArchivesUploadSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var showImporter = true
    @State private var runner = ActionRunner()
    @State private var result: ArchivesBulkUploadResult?

    var body: some View {
        NavigationStack {
            List {
                if let result {
                    Section("Result") {
                        Label("\(result.uploaded ?? 0) uploaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if (result.failed ?? 0) > 0 {
                            Label("\(result.failed ?? 0) failed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        }
                        ForEach(Array((result.errors ?? []).enumerated()), id: \.offset) { _, e in
                            VStack(alignment: .leading) {
                                Text(e.filename ?? "File")
                                Text(e.error ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Section {
                        ForEach(files, id: \.self) { url in Label(url.lastPathComponent, systemImage: "doc") }
                            .onDelete { files.remove(atOffsets: $0) }
                        Button { showImporter = true } label: { Label(files.isEmpty ? "Choose 3MF Files…" : "Add More…", systemImage: "plus") }
                    } footer: {
                        Text("Printer model and print settings are read from each 3MF file.")
                    }
                }
            }
            .navigationTitle("Upload 3MF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancel" : "Done") { dismiss() } }
                if result == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if runner.isRunning { ProgressView() } else {
                            Button("Upload") { Task { await upload() } }.disabled(files.isEmpty)
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [ArchivesFileTypes.threeMF], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { files += urls.filter { u in !files.contains(u) } }
            }
            .actionAlerts(runner)
        }
    }

    private func upload() async {
        await runner.run {
            let parts = try files.map { url in
                UploadFile(fieldName: "files", fileName: url.lastPathComponent, mimeType: "application/octet-stream", data: try archivesReadPickedFile(url))
            }
            result = try await session.client.upload("archives/upload-bulk", files: parts)
        }
    }
}

// MARK: Calendar

/// Month calendar of archives by creation date; tapping a day lists its prints.
struct ArchivesCalendarView: View {
    let archives: [ArchivesRecord]
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var selectedDay: Date?

    private let calendar = Calendar.current

    private var byDay: [Date: [ArchivesRecord]] {
        Dictionary(grouping: archives.filter { $0.createdDate != nil }) { calendar.startOfDay(for: $0.createdDate!) }
    }

    var body: some View {
        let groups = byDay
        VStack(spacing: 12) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
            }
            .padding(.horizontal, 4)
            let symbols = calendar.veryShortStandaloneWeekdaySymbols
            let first = calendar.firstWeekday - 1
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols[(i + first) % 7]).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(Array(days().enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day, items: groups[day] ?? [])
                    } else {
                        Color.clear.frame(height: 48)
                    }
                }
            }
            if let selectedDay {
                let items = groups[selectedDay] ?? []
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedDay.formatted(date: .complete, time: .omitted)).font(.subheadline.weight(.semibold))
                    if items.isEmpty { Text("No prints on this day.").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(items) { archive in
                        NavigationLink(value: ArchivesDetailRoute(id: archive.id)) {
                            ArchivesRow(archive: archive)
                                .padding(8)
                                .background(.background.secondary, in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.bottom)
    }

    private func dayCell(_ day: Date, items: [ArchivesRecord]) -> some View {
        let isSelected = selectedDay == day
        let isToday = calendar.isDateInToday(day)
        let failed = items.contains { $0.isFailed }
        return Button { selectedDay = isSelected ? nil : day } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.accentColor : .primary)
                if items.isEmpty {
                    Circle().fill(.clear).frame(width: 6, height: 6)
                } else {
                    Text("\(items.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 18)
                        .padding(.horizontal, 3)
                        .background(failed ? Color.orange : Color.green, in: .capsule)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemFill).opacity(items.isEmpty ? 0.3 : 0.8), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.formatted(date: .abbreviated, time: .omitted)), \(items.count) prints")
    }

    private func shift(_ months: Int) {
        if let d = calendar.date(byAdding: .month, value: months, to: month) { month = d }
        selectedDay = nil
    }

    private func days() -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: month)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var out: [Date?] = Array(repeating: nil, count: leading)
        for d in range {
            out.append(calendar.date(byAdding: .day, value: d - 1, to: month))
        }
        return out
    }
}
