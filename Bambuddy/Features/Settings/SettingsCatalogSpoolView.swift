import SwiftUI
import UniformTypeIdentifiers

/// Empty-spool weight catalog: searchable list with add/edit/delete, multi-select delete,
/// reset to defaults, and JSON import/export.
struct SettingsCatalogSpoolView: View {
    @Environment(AppSession.self) private var session
    @State private var loader = Loader<[SettingsCatalogSpoolEntry]>()
    @State private var runner = ActionRunner()
    @State private var search = ""
    @State private var editing: SettingsCatalogSpoolEditTarget?
    @State private var pendingDelete: SettingsCatalogSpoolEntry?
    @State private var selection = Set<Int>()
    @State private var editMode: EditMode = .inactive
    @State private var confirmBulkDelete = false
    @State private var confirmReset = false
    @State private var showImporter = false

    private var canEdit: Bool { session.can("inventory:update") }

    private var filtered: [SettingsCatalogSpoolEntry] {
        let all = loader.value ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        LoadingContent(loader: loader, retry: load) { entries in
            List(selection: $selection) {
                Section {
                    ForEach(filtered) { entry in
                        row(entry).tag(entry.id)
                    }
                } footer: {
                    Text("Weight of the empty spool by brand and type, used to work out how much filament is left when a spool is weighed.")
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No Spool Weights", systemImage: "scalemass",
                                           description: Text("Add an entry, or restore the built-in list."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .refreshable { await load() }
        }
        .searchable(text: $search, prompt: "Search spools")
        .navigationTitle("Spool Weights")
        .environment(\.editMode, $editMode)
        .toolbar { toolbar }
        .task { if loader.value == nil { await load() } }
        .sheet(item: $editing) { target in
            SettingsCatalogSpoolEditor(entry: target.entry) { payload in
                await save(payload, id: target.entry?.id)
            }
        }
        .confirm("Delete \(pendingDelete?.name ?? "entry")?",
                 isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            if let entry = pendingDelete { Task { await delete(entry) } }
        }
        .confirm("Delete \(selection.count) \(selection.count == 1 ? "entry" : "entries")?", isPresented: $confirmBulkDelete) {
            Task { await bulkDelete() }
        }
        .confirm("Restore the built-in spool list?", isPresented: $confirmReset,
                 message: "All custom entries and edits will be replaced by the default catalog.",
                 action: "Restore Defaults") {
            Task { await reset() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { Task { await importFile(url) } }
            if case .failure(let error) = result { runner.errorMessage = error.localizedDescription }
        }
        .actionAlerts(runner)
    }

    private func row(_ entry: SettingsCatalogSpoolEntry) -> some View {
        let content = HStack {
            Text(entry.name).foregroundStyle(.primary)
            Spacer()
            Text(Fmt.grams(entry.weight)).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        return Group {
            if canEdit, !editMode.isEditing {
                Button { editing = SettingsCatalogSpoolEditTarget(entry: entry) } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .swipeActions(edge: .trailing) {
            if canEdit {
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = entry }
                Button("Edit", systemImage: "pencil") { editing = SettingsCatalogSpoolEditTarget(entry: entry) }
                    .tint(.blue)
            }
        }
        .contextMenu {
            if canEdit {
                Button("Edit", systemImage: "pencil") { editing = SettingsCatalogSpoolEditTarget(entry: entry) }
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = entry }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == filtered.count && !filtered.isEmpty ? "Deselect All" : "Select All") {
                    if selection.count == filtered.count { selection = [] } else { selection = Set(filtered.map(\.id)) }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Delete (\(selection.count))", systemImage: "trash", role: .destructive) { confirmBulkDelete = true }
                    .disabled(selection.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { editMode = .inactive; selection = [] }
            }
        } else {
            if runner.isRunning {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis.circle") {
                    if canEdit {
                        Button("Select", systemImage: "checkmark.circle") { editMode = .active }
                            .disabled((loader.value ?? []).isEmpty)
                        Button("Import…", systemImage: "square.and.arrow.down") { showImporter = true }
                    }
                    if let entries = loader.value, !entries.isEmpty {
                        ShareLink(item: SettingsCatalogSpoolExport(data: SettingsCatalog.exportSpools(entries)),
                                  preview: SharePreview("Spool Catalog")) {
                            Label("Export…", systemImage: "square.and.arrow.up")
                        }
                    }
                    if canEdit {
                        Divider()
                        Button("Restore Defaults…", systemImage: "arrow.counterclockwise", role: .destructive) { confirmReset = true }
                    }
                }
            }
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Entry", systemImage: "plus") { editing = SettingsCatalogSpoolEditTarget(entry: nil) }
                }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        await loader.load { try await session.client.get("inventory/catalog") }
    }

    private func sorted(_ entries: [SettingsCatalogSpoolEntry]) -> [SettingsCatalogSpoolEntry] {
        entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func save(_ payload: SettingsCatalogSpoolPayload, id: Int?) async -> Bool {
        var ok = false
        await runner.run(id == nil ? "Entry added" : "Entry updated") {
            if let id {
                let updated: SettingsCatalogSpoolEntry = try await session.client.send(.put, "inventory/catalog/\(id)", body: payload)
                loader.value = sorted((loader.value ?? []).map { $0.id == id ? updated : $0 })
            } else {
                let created: SettingsCatalogSpoolEntry = try await session.client.send(.post, "inventory/catalog", body: payload)
                loader.value = sorted((loader.value ?? []) + [created])
            }
            ok = true
        }
        return ok
    }

    private func delete(_ entry: SettingsCatalogSpoolEntry) async {
        await runner.run("Entry deleted") {
            try await session.client.call(.delete, "inventory/catalog/\(entry.id)")
            loader.value?.removeAll { $0.id == entry.id }
        }
    }

    private func bulkDelete() async {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        var deleted = 0
        await runner.run(nil) {
            let result: SettingsCatalogBulkDeleteResult = try await session.client.send(
                .post, "inventory/catalog/bulk-delete", body: SettingsCatalogBulkDelete(ids: ids))
            deleted = result.deleted ?? ids.count
            loader.value?.removeAll { ids.contains($0.id) }
            selection = []
            editMode = .inactive
            runner.successMessage = "Deleted \(deleted) \(deleted == 1 ? "entry" : "entries")"
        }
    }

    private func reset() async {
        await runner.run("Spool list restored") {
            try await session.client.call(.post, "inventory/catalog/reset")
        }
        await load()
    }

    private func importFile(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        await runner.run(nil) {
            let records = try SettingsCatalog.importSpools(try Data(contentsOf: url))
            var existing = Set((loader.value ?? []).map { $0.name.lowercased() })
            var added = 0, skipped = 0
            for record in records {
                guard let name = record.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                      let weight = record.weight, weight.isFinite, !existing.contains(name.lowercased()) else {
                    skipped += 1
                    continue
                }
                do {
                    let created: SettingsCatalogSpoolEntry = try await session.client.send(
                        .post, "inventory/catalog", body: SettingsCatalogSpoolPayload(name: name, weight: Int(weight.rounded())))
                    loader.value = sorted((loader.value ?? []) + [created])
                    existing.insert(name.lowercased())
                    added += 1
                } catch {
                    skipped += 1
                }
            }
            runner.successMessage = "Imported \(added), skipped \(skipped)"
        }
    }
}

private struct SettingsCatalogSpoolEditTarget: Identifiable {
    let entry: SettingsCatalogSpoolEntry?
    let id = UUID()
}

/// Create/edit sheet for a spool weight entry.
private struct SettingsCatalogSpoolEditor: View {
    @Environment(\.dismiss) private var dismiss
    let entry: SettingsCatalogSpoolEntry?
    let onSave: (SettingsCatalogSpoolPayload) async -> Bool

    @State private var name: String
    @State private var weight: String
    @State private var saving = false

    init(entry: SettingsCatalogSpoolEntry?, onSave: @escaping (SettingsCatalogSpoolPayload) async -> Bool) {
        self.entry = entry
        self.onSave = onSave
        _name = State(initialValue: entry?.name ?? "")
        _weight = State(initialValue: entry.map { String(Int($0.weight.rounded())) } ?? "")
    }

    private var weightValue: Int? {
        Int(weight.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }
    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && weightValue != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Brand - Spool type"))
                    LabeledContent("Empty Weight") {
                        HStack(spacing: 4) {
                            TextField("0", text: $weight)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                            Text("g").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("For example \"Bambu Lab - Plastic\" with the weight of the empty spool in grams.")
                }
            }
            .navigationTitle(entry == nil ? "New Spool Weight" : "Edit Spool Weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            guard let weightValue else { return }
                            saving = true
                            let payload = SettingsCatalogSpoolPayload(name: name.trimmingCharacters(in: .whitespaces), weight: weightValue)
                            Task {
                                let ok = await onSave(payload)
                                saving = false
                                if ok { dismiss() }
                            }
                        }
                        .disabled(!isValid)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
