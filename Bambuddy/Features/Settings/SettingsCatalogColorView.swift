import SwiftUI
import UniformTypeIdentifiers

/// Filament color catalog: searchable, grouped by manufacturer, with add/edit/delete,
/// multi-select delete, reset to defaults, JSON import/export and an online sync.
struct SettingsCatalogColorView: View {
    @Environment(AppSession.self) private var session
    @State private var loader = Loader<[SettingsCatalogColorEntry]>()
    @State private var runner = ActionRunner()
    @State private var search = ""
    @State private var manufacturerFilter = ""
    @State private var editing: SettingsCatalogColorEditTarget?
    @State private var pendingDelete: SettingsCatalogColorEntry?
    @State private var selection = Set<Int>()
    @State private var editMode: EditMode = .inactive
    @State private var confirmBulkDelete = false
    @State private var confirmReset = false
    @State private var confirmSync = false
    @State private var showImporter = false
    @State private var syncProgress: (fetched: Int, total: Int)?
    @State private var isSyncing = false

    private var canEdit: Bool { session.can("inventory:update") }

    private var manufacturers: [String] {
        Array(Set((loader.value ?? []).map(\.manufacturer))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filtered: [SettingsCatalogColorEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return (loader.value ?? []).filter { entry in
            (manufacturerFilter.isEmpty || entry.manufacturer == manufacturerFilter)
                && (query.isEmpty
                    || entry.manufacturer.localizedCaseInsensitiveContains(query)
                    || entry.colorName.localizedCaseInsensitiveContains(query)
                    || (entry.material?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    private var grouped: [(manufacturer: String, entries: [SettingsCatalogColorEntry])] {
        Dictionary(grouping: filtered, by: \.manufacturer)
            .map { (manufacturer: $0.key, entries: $0.value) }
            .sorted { $0.manufacturer.localizedStandardCompare($1.manufacturer) == .orderedAscending }
    }

    var body: some View {
        LoadingContent(loader: loader, retry: load) { entries in
            List(selection: $selection) {
                if isSyncing {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Syncing from FilamentColors.xyz…").font(.subheadline)
                            if let progress = syncProgress, progress.total > 0 {
                                ProgressView(value: Double(progress.fetched), total: Double(progress.total))
                                Text("\(progress.fetched) of \(progress.total) swatches")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                }
                ForEach(grouped, id: \.manufacturer) { group in
                    Section(group.manufacturer) {
                        ForEach(group.entries) { entry in
                            row(entry).tag(entry.id)
                        }
                    }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No Colors", systemImage: "paintpalette",
                                           description: Text("Add a color, sync from FilamentColors.xyz, or restore the built-in list."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .refreshable { await load() }
        }
        .searchable(text: $search, prompt: "Search colors, brands, materials")
        .navigationTitle("Colors")
        .environment(\.editMode, $editMode)
        .toolbar { toolbar }
        .task { if loader.value == nil { await load() } }
        .sheet(item: $editing) { target in
            SettingsCatalogColorEditor(entry: target.entry, manufacturers: manufacturers) { payload in
                await save(payload, id: target.entry?.id)
            }
        }
        .confirm("Delete \(pendingDelete.map { "\($0.manufacturer) \($0.colorName)" } ?? "color")?",
                 isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            if let entry = pendingDelete { Task { await delete(entry) } }
        }
        .confirm("Delete \(selection.count) \(selection.count == 1 ? "color" : "colors")?", isPresented: $confirmBulkDelete) {
            Task { await bulkDelete() }
        }
        .confirm("Restore the built-in color list?", isPresented: $confirmReset,
                 message: "All custom and synced colors will be replaced by the default catalog.",
                 action: "Restore Defaults") {
            Task { await reset() }
        }
        .confirm("Sync from FilamentColors.xyz?", isPresented: $confirmSync,
                 message: "Downloads the community color database and adds colors that aren't in the catalog yet. This can take a few minutes.",
                 action: "Sync", role: nil) {
            Task { await sync() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { Task { await importFile(url) } }
            if case .failure(let error) = result { runner.errorMessage = error.localizedDescription }
        }
        .actionAlerts(runner)
    }

    private func row(_ entry: SettingsCatalogColorEntry) -> some View {
        let content = HStack(spacing: 12) {
            SettingsCatalogColorSwatch(hex: entry.hexColor, extraColors: entry.extraColors)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.colorName).foregroundStyle(.primary)
                Text(([entry.material, SettingsCatalog.effectLabel(entry.effectType)].compactMap { $0 }.filter { !$0.isEmpty }
                      + [entry.hexColor.uppercased()]).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.isDefault == false {
                StatusBadge(text: "Custom", color: .blue)
            }
        }
        .contentShape(.rect)
        return Group {
            if canEdit, !editMode.isEditing {
                Button { editing = SettingsCatalogColorEditTarget(entry: entry) } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .swipeActions(edge: .trailing) {
            if canEdit {
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = entry }
                Button("Edit", systemImage: "pencil") { editing = SettingsCatalogColorEditTarget(entry: entry) }
                    .tint(.blue)
            }
        }
        .contextMenu {
            Button("Copy Hex", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.hexColor }
            if canEdit {
                Button("Edit", systemImage: "pencil") { editing = SettingsCatalogColorEditTarget(entry: entry) }
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
            if runner.isRunning || isSyncing {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis.circle") {
                    Picker("Manufacturer", selection: $manufacturerFilter) {
                        Text("All Manufacturers").tag("")
                        ForEach(manufacturers, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Divider()
                    if canEdit {
                        Button("Select", systemImage: "checkmark.circle") { editMode = .active }
                            .disabled((loader.value ?? []).isEmpty)
                        Button("Sync from FilamentColors.xyz…", systemImage: "icloud.and.arrow.down") { confirmSync = true }
                            .disabled(isSyncing)
                        Button("Import…", systemImage: "square.and.arrow.down") { showImporter = true }
                    }
                    if let entries = loader.value, !entries.isEmpty {
                        ShareLink(item: SettingsCatalogColorExport(data: SettingsCatalog.exportColors(entries)),
                                  preview: SharePreview("Color Catalog")) {
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
                    Button("Add Color", systemImage: "plus") { editing = SettingsCatalogColorEditTarget(entry: nil) }
                }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        await loader.load { try await session.client.get("inventory/colors") }
    }

    private func sorted(_ entries: [SettingsCatalogColorEntry]) -> [SettingsCatalogColorEntry] {
        entries.sorted {
            if $0.manufacturer != $1.manufacturer { return $0.manufacturer.localizedStandardCompare($1.manufacturer) == .orderedAscending }
            if ($0.material ?? "") != ($1.material ?? "") { return ($0.material ?? "").localizedStandardCompare($1.material ?? "") == .orderedAscending }
            return $0.colorName.localizedStandardCompare($1.colorName) == .orderedAscending
        }
    }

    private func save(_ payload: SettingsCatalogColorPayload, id: Int?) async -> Bool {
        var ok = false
        await runner.run(id == nil ? "Color added" : "Color updated") {
            if let id {
                let updated: SettingsCatalogColorEntry = try await session.client.send(.put, "inventory/colors/\(id)", body: payload)
                loader.value = sorted((loader.value ?? []).map { $0.id == id ? updated : $0 })
            } else {
                let created: SettingsCatalogColorEntry = try await session.client.send(.post, "inventory/colors", body: payload)
                loader.value = sorted((loader.value ?? []) + [created])
            }
            ok = true
        }
        return ok
    }

    private func delete(_ entry: SettingsCatalogColorEntry) async {
        await runner.run("Color deleted") {
            try await session.client.call(.delete, "inventory/colors/\(entry.id)")
            loader.value?.removeAll { $0.id == entry.id }
        }
    }

    private func bulkDelete() async {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        await runner.run(nil) {
            let result: SettingsCatalogBulkDeleteResult = try await session.client.send(
                .post, "inventory/colors/bulk-delete", body: SettingsCatalogBulkDelete(ids: ids))
            let deleted = result.deleted ?? ids.count
            loader.value?.removeAll { ids.contains($0.id) }
            selection = []
            editMode = .inactive
            runner.successMessage = "Deleted \(deleted) \(deleted == 1 ? "color" : "colors")"
        }
    }

    private func reset() async {
        await runner.run("Color list restored") {
            try await session.client.call(.post, "inventory/colors/reset")
        }
        await load()
    }

    /// Streams the server's sync progress (server-sent events) and reloads when done.
    private func sync() async {
        isSyncing = true
        syncProgress = nil
        defer { isSyncing = false; syncProgress = nil }
        await runner.run(nil) {
            var request = session.client.makeRequest(.post, "inventory/colors/sync")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 300
            let (bytes, response) = try await APIClient.session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                throw APIError.from(status: http.statusCode, data: body)
            }
            var finished = false
            for try await line in bytes.lines {
                guard let event = SettingsCatalog.parseSyncLine(line) else { continue }
                switch event.type {
                case "progress":
                    syncProgress = (event.totalFetched ?? 0, event.totalAvailable ?? 0)
                case "complete":
                    finished = true
                    let added = event.added ?? 0
                    runner.successMessage = added == 0
                        ? "Already up to date"
                        : "Added \(added) colors, skipped \(event.skipped ?? 0)"
                case "error":
                    throw APIError(status: 502, message: event.error ?? "Sync failed", code: nil, detail: nil)
                default:
                    break
                }
            }
            if !finished { throw APIError(status: 0, message: "The sync ended unexpectedly.", code: nil, detail: nil) }
        }
        await load()
    }

    private func importFile(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        await runner.run(nil) {
            let records = try SettingsCatalog.importColors(try Data(contentsOf: url))
            func identity(_ manufacturer: String, _ name: String, _ material: String?) -> String {
                [manufacturer, name, material ?? ""].map { $0.lowercased() }.joined(separator: "|")
            }
            var existing = Set((loader.value ?? []).map { identity($0.manufacturer, $0.colorName, $0.material) })
            var added = 0, skipped = 0
            for record in records {
                guard let manufacturer = record.manufacturer?.trimmingCharacters(in: .whitespaces), !manufacturer.isEmpty,
                      let name = record.colorName?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                      let hex = record.hexColor.flatMap(SettingsCatalog.normalizedHex) else {
                    skipped += 1
                    continue
                }
                let material = record.material.flatMap { $0.isEmpty ? nil : $0 }
                let key = identity(manufacturer, name, material)
                guard !existing.contains(key) else { skipped += 1; continue }
                let payload = SettingsCatalogColorPayload(
                    manufacturer: manufacturer, colorName: name, hexColor: hex, material: material,
                    extraColors: record.extraColors.flatMap { $0.isEmpty ? nil : $0 },
                    effectType: record.effectType.flatMap { $0.isEmpty ? nil : $0 })
                do {
                    let created: SettingsCatalogColorEntry = try await session.client.send(.post, "inventory/colors", body: payload)
                    loader.value = sorted((loader.value ?? []) + [created])
                    existing.insert(key)
                    added += 1
                } catch {
                    skipped += 1
                }
            }
            runner.successMessage = "Imported \(added), skipped \(skipped)"
        }
    }
}

private struct SettingsCatalogColorEditTarget: Identifiable {
    let entry: SettingsCatalogColorEntry?
    let id = UUID()
}

/// Round swatch that also shows extra gradient stops, when present.
private struct SettingsCatalogColorSwatch: View {
    let hex: String
    let extraColors: String?
    var size: CGFloat = 26

    private var stops: [Color] {
        let extras = (extraColors ?? "").split(separator: ",").compactMap { Color(hex: String($0).trimmingCharacters(in: .whitespaces)) }
        guard !extras.isEmpty else { return [] }
        return [Color(hex: hex) ?? .clear] + extras
    }

    var body: some View {
        Group {
            if stops.count > 1 {
                Circle()
                    .fill(AngularGradient(colors: stops + [stops[0]], center: .center))
                    .overlay { Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1) }
                    .frame(width: size, height: size)
            } else {
                ColorSwatch(hex: hex, size: size)
            }
        }
    }
}

/// Create/edit sheet for a color catalog entry.
private struct SettingsCatalogColorEditor: View {
    @Environment(\.dismiss) private var dismiss
    let entry: SettingsCatalogColorEntry?
    let manufacturers: [String]
    let onSave: (SettingsCatalogColorPayload) async -> Bool

    @State private var manufacturer: String
    @State private var colorName: String
    @State private var hex: String
    @State private var material: String
    @State private var effectType: String
    @State private var extraColors: String
    @State private var saving = false

    init(entry: SettingsCatalogColorEntry?, manufacturers: [String], onSave: @escaping (SettingsCatalogColorPayload) async -> Bool) {
        self.entry = entry
        self.manufacturers = manufacturers
        self.onSave = onSave
        _manufacturer = State(initialValue: entry?.manufacturer ?? "")
        _colorName = State(initialValue: entry?.colorName ?? "")
        _hex = State(initialValue: entry?.hexColor ?? "#FFFFFF")
        _material = State(initialValue: entry?.material ?? "")
        _effectType = State(initialValue: entry?.effectType ?? "")
        _extraColors = State(initialValue: entry?.extraColors ?? "")
    }

    private var normalizedHex: String? { SettingsCatalog.normalizedHex(hex) }
    private var extraColorsError: String? { SettingsCatalog.extraColorsError(extraColors) }

    private var isValid: Bool {
        !manufacturer.trimmingCharacters(in: .whitespaces).isEmpty
            && !colorName.trimmingCharacters(in: .whitespaces).isEmpty
            && normalizedHex != nil
            && extraColorsError == nil
    }

    private var pickerColor: Binding<Color> {
        Binding(
            get: { Color(hex: hex) ?? .white },
            set: { hex = "#" + $0.hexString }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Manufacturer", text: $manufacturer)
                        if !manufacturers.isEmpty {
                            Menu {
                                ForEach(manufacturers, id: \.self) { name in
                                    Button(name) { manufacturer = name }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            .accessibilityLabel("Choose Manufacturer")
                        }
                    }
                    TextField("Color Name", text: $colorName)
                    TextField("Material (optional)", text: $material, prompt: Text("e.g. PLA Basic"))
                }
                Section {
                    ColorPicker("Color", selection: pickerColor, supportsOpacity: false)
                    LabeledContent("Hex") {
                        TextField("#RRGGBB", text: $hex)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .monospaced()
                    }
                } footer: {
                    if normalizedHex == nil {
                        Text("Enter a hex color such as #1A2B3C (or #1A2B3CFF with transparency).").foregroundStyle(.red)
                    }
                }
                Section {
                    Picker("Effect", selection: $effectType) {
                        Text("None").tag("")
                        ForEach(SettingsCatalog.effectTypes, id: \.value) { Text($0.label).tag($0.value) }
                        if !effectType.isEmpty, !SettingsCatalog.effectTypes.contains(where: { $0.value == effectType }) {
                            Text(effectType).tag(effectType)
                        }
                    }
                    TextField("Extra Colors", text: $extraColors, prompt: Text("ff0000, 00ff00"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .monospaced()
                } header: {
                    Text("Appearance")
                } footer: {
                    if let extraColorsError {
                        Text(extraColorsError).foregroundStyle(.red)
                    } else {
                        Text("Optional comma-separated hex colors for multi-color or gradient filaments (up to \(SettingsCatalog.maxExtraColorStops)).")
                    }
                }
            }
            .navigationTitle(entry == nil ? "New Color" : "Edit Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SettingsCatalogColorSwatch(hex: normalizedHex ?? "", extraColors: extraColorsError == nil ? extraColors : nil)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { submit() }.disabled(!isValid)
                    }
                }
            }
        }
    }

    private func submit() {
        guard let normalizedHex else { return }
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        let payload = SettingsCatalogColorPayload(
            manufacturer: manufacturer.trimmingCharacters(in: .whitespaces),
            colorName: colorName.trimmingCharacters(in: .whitespaces),
            hexColor: normalizedHex,
            material: clean(material),
            extraColors: clean(extraColors),
            effectType: clean(effectType)
        )
        saving = true
        Task {
            let ok = await onSave(payload)
            saving = false
            if ok { dismiss() }
        }
    }
}
