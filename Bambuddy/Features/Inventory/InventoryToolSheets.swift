import SwiftUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Labels

/// Generates a printable PDF of spool labels and offers it for preview / sharing.
struct InventoryLabelSheet: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let spoolIds: [Int]

    @AppStorage("inventory.labelTemplate") private var templateRaw = InventoryLabelTemplate.amsHolderSmall.rawValue
    @AppStorage("inventory.labelMonochrome") private var monochrome = false
    @State private var selected: Set<Int> = []
    @State private var startingPosition = 1
    @State private var pdfURL: URL?
    @State private var runner = ActionRunner()

    private var template: InventoryLabelTemplate { InventoryLabelTemplate(rawValue: templateRaw) ?? .amsHolderSmall }

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    Picker("Template", selection: $templateRaw) {
                        ForEach(InventoryLabelTemplate.allCases) { t in
                            VStack(alignment: .leading) {
                                Text(t.title)
                                Text(t.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(t.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Toggle("Monochrome", isOn: $monochrome)
                    if let capacity = template.sheetCapacity {
                        Stepper(value: $startingPosition, in: 1...capacity) {
                            LabeledContent("Start at Label", value: "\(startingPosition) of \(capacity)")
                        }
                    }
                }
                if spoolIds.count > 1 {
                    Section {
                        ForEach(spoolIds, id: \.self) { id in
                            if let spool = store.spool(id) {
                                Button {
                                    if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected.contains(id) ? Color.accentColor : .secondary)
                                        InventorySpoolSwatch(spool: spool, size: 22)
                                        Text("#\(spool.id) \(spool.displayName)").foregroundStyle(.primary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(selected.count) of \(spoolIds.count) spools")
                            Spacer()
                            Button(selected.count == spoolIds.count ? "None" : "All") {
                                selected = selected.count == spoolIds.count ? [] : Set(spoolIds)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Print Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else {
                        Button("Generate") { generate() }.disabled(selected.isEmpty)
                    }
                }
            }
            .onChange(of: templateRaw) { startingPosition = 1 }
            .onAppear { if selected.isEmpty { selected = Set(spoolIds) } }
            .quickLookPreview($pdfURL)
            .actionAlerts(runner)
        }
    }

    private func generate() {
        let ids = spoolIds.filter { selected.contains($0) }
        Task {
            await runner.run {
                pdfURL = try await store.labelsPDF(ids: ids, template: template, monochrome: monochrome, startingPosition: startingPosition)
            }
        }
    }
}

// MARK: - Bulk edit

/// Apply the same field values to several spools at once.
struct InventoryBulkEditView: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let spoolIds: [Int]
    var onDone: () -> Void

    private enum Field: String, CaseIterable, Identifiable {
        case material = "Material", subtype = "Subtype", brand = "Brand", colorName = "Color Name", color = "Color"
        case location = "Storage Location", presetName = "Slicer Preset Name", preset = "Slicer Preset ID"
        case cost = "Cost per kg", note = "Note", labelWeight = "Label Weight", coreWeight = "Empty Spool Weight"
        case category = "Category", lowStock = "Low Stock Threshold"
        var id: String { rawValue }
        var spoolmanSupported: Bool { ![.category, .lowStock].contains(self) }
    }

    @State private var enabled: Set<Field> = []
    @State private var texts: [Field: String] = [:]
    @State private var numbers: [Field: Double] = [:]
    @State private var locationId: Int?
    @State private var color = Color.gray
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Turn on the fields to change. Everything else on the \(spoolIds.count) selected spools stays as it is; an empty text field clears the value.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Field.allCases.filter { !store.isSpoolman || $0.spoolmanSupported }) { field in
                    Section {
                        Toggle(field.rawValue, isOn: Binding(get: { enabled.contains(field) }, set: { if $0 { enabled.insert(field) } else { enabled.remove(field) } }))
                        if enabled.contains(field) { editor(field) }
                    }
                }
            }
            .navigationTitle("Edit \(spoolIds.count) Spools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }.disabled(enabled.isEmpty || runner.isRunning)
                }
            }
            .actionAlerts(runner)
        }
    }

    @ViewBuilder
    private func editor(_ field: Field) -> some View {
        switch field {
        case .material:
            InventorySuggestField(title: "Material", text: text(field), suggestions: InventoryFormOptions.materials, capitalization: .characters)
        case .subtype:
            InventorySuggestField(title: "Subtype", text: text(field), suggestions: InventoryFormOptions.subtypes)
        case .brand:
            InventorySuggestField(title: "Brand", text: text(field), suggestions: InventoryFormOptions.brands)
        case .category:
            InventorySuggestField(title: "Category", text: text(field), suggestions: Array(Set(store.spools.compactMap(\.category).filter { !$0.isEmpty } + ["Stock"])).sorted())
        case .colorName, .presetName, .preset:
            TextField(field.rawValue, text: text(field))
        case .note:
            TextField("Note", text: text(field), axis: .vertical).lineLimit(2...5)
        case .color:
            ColorPicker("Color", selection: $color, supportsOpacity: false)
        case .location:
            Picker("Location", selection: $locationId) {
                Text("None").tag(Int?.none)
                ForEach(store.locations) { Text($0.name).tag(Int?.some($0.id)) }
            }
        case .cost, .labelWeight, .coreWeight, .lowStock:
            TextField(field == .cost ? store.currencyCode : (field == .lowStock ? "Percent (empty = global)" : "Grams"), value: number(field), format: .number)
                .keyboardType(.decimalPad)
        }
    }

    private func text(_ f: Field) -> Binding<String> {
        Binding(get: { texts[f] ?? "" }, set: { texts[f] = $0 })
    }

    private func number(_ f: Field) -> Binding<Double?> {
        Binding(get: { numbers[f] }, set: { numbers[f] = $0 })
    }

    private func apply() {
        var patch: [String: JSONValue] = [:]
        func str(_ f: Field) -> JSONValue {
            let t = (texts[f] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? .null : .string(t)
        }
        for field in enabled {
            switch field {
            case .material:
                guard case .string = str(field) else { runner.errorMessage = "Material can't be empty."; return }
                patch["material"] = str(field)
            case .subtype: patch["subtype"] = str(field)
            case .brand: patch["brand"] = str(field)
            case .colorName: patch["color_name"] = str(field)
            case .color: patch["rgba"] = .string(InventoryColors.rgba(from: color))
            case .location: patch["location_id"] = locationId.map { .number(Double($0)) } ?? .null
            case .presetName: patch["slicer_filament_name"] = str(field)
            case .preset: patch["slicer_filament"] = str(field)
            case .note: patch["note"] = str(field)
            case .category: patch["category"] = str(field)
            case .cost: patch["cost_per_kg"] = numbers[field].map { .number($0) } ?? .null
            case .labelWeight:
                guard let v = numbers[field], v >= 1 else { runner.errorMessage = "Label weight must be at least 1 g."; return }
                patch["label_weight"] = .number(v.rounded())
            case .coreWeight:
                guard let v = numbers[field], v >= 0 else { runner.errorMessage = "Enter an empty spool weight."; return }
                patch["core_weight"] = .number(v.rounded())
            case .lowStock:
                if let v = numbers[field], !(1...99).contains(v) { runner.errorMessage = "Low stock threshold must be between 1 and 99%."; return }
                patch["low_stock_threshold_pct"] = numbers[field].map { .number($0.rounded()) } ?? .null
            }
        }
        Task {
            await runner.run {
                let result = try await store.bulkUpdate(ids: spoolIds, patch: patch)
                if result.succeeded == 0 && result.failedCount > 0 {
                    runner.errorMessage = "None of the spools could be updated."
                    return
                }
                onDone()
                dismiss()
            }
        }
    }
}

// MARK: - CSV import

/// Import spools from a CSV file: pick → preview (dry run) → import.
struct InventoryImportSheet: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var fileName: String?
    @State private var fileData: Data?
    @State private var preview: InventoryImportResponse?
    @State private var result: InventoryImportResponse?
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showPicker = true } label: {
                        Label(fileName ?? "Choose CSV File…", systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("Use the same columns as the CSV export (material, brand, subtype, color_name, rgba, label_weight, …). A preview is shown before anything is imported.")
                }
                if let result {
                    Section("Imported") {
                        InfoRow("Created", "\(result.created ?? 0)")
                        InfoRow("Skipped", "\(result.skipped ?? 0)")
                        InfoRow("Errors", "\(result.errors ?? 0)")
                        ForEach(result.errorRows ?? []) { row in
                            Text("Row \(row.rowNumber): \(row.reason ?? "error")").font(.footnote).foregroundStyle(.red)
                        }
                    }
                } else if let preview {
                    Section("Preview") {
                        InfoRow("Rows", "\(preview.total ?? 0)")
                        InfoRow("Valid", "\(preview.validCount ?? 0)")
                        InfoRow("Errors", "\(preview.errorCount ?? 0)")
                        InfoRow("Skipped", "\(preview.skippedCount ?? 0)")
                    }
                    if let warnings = preview.warnings, !warnings.isEmpty {
                        Section("Warnings") {
                            ForEach(warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
                        }
                    }
                    Section("Rows") {
                        ForEach(preview.rows ?? []) { row in
                            HStack(spacing: 10) {
                                InventorySpoolSwatch(rgba: row.rgba, size: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Row \(row.rowNumber): \(InventoryFormat.joined([row.brand, row.material, row.colorName], separator: " "))").lineLimit(1)
                                    if let reason = row.reason, !reason.isEmpty {
                                        Text(reason).font(.caption).foregroundStyle(row.status == "error" ? .red : .secondary)
                                    } else if row.duplicateOfExisting == true {
                                        Text("Matches an existing spool").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                StatusBadge(text: (row.status ?? "—").capitalized, color: row.status == "error" ? .red : row.status == "skipped" ? .secondary : .green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import Spools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancel" : "Done") { dismiss() } }
                if result == nil, let preview, (preview.validCount ?? 0) > 0 {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import \(preview.validCount ?? 0)") { commit() }.disabled(runner.isRunning)
                    }
                }
            }
            .overlay { if runner.isRunning { ProgressView() } }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { picked in
                guard case .success(let url) = picked else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { runner.errorMessage = "Couldn't read the file."; return }
                fileName = url.lastPathComponent
                fileData = data
                result = nil
                preview = nil
                Task { await runner.run { preview = try await store.importCSV(data: data, fileName: url.lastPathComponent, dryRun: true) } }
            }
            .actionAlerts(runner)
        }
    }

    private func commit() {
        guard let fileData, let fileName else { return }
        Task { await runner.run { result = try await store.importCSV(data: fileData, fileName: fileName, dryRun: false) } }
    }
}

// MARK: - Spoolman

/// Spoolman connection status and sync actions.
struct InventorySpoolmanStatusSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var status = Loader<InventorySpoolmanStatus>()
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    if let s = status.value {
                        LabeledContent("Status") {
                            Label(s.connected ? "Connected" : "Disconnected", systemImage: s.connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(s.connected ? .green : .red)
                        }
                        InfoRow("URL", s.url)
                        if session.can("settings:update") {
                            if s.connected {
                                Button("Disconnect", role: .destructive) { act("Disconnected") { try await session.client.call(.post, "spoolman/disconnect") } }
                            } else {
                                Button("Reconnect") { act("Connected") { try await session.client.call(.post, "spoolman/connect") } }
                            }
                        }
                    } else if let e = status.error {
                        Text(e).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                if session.can("filaments:update") {
                    Section {
                        Button { act(nil) {
                            let r: InventorySpoolmanSyncResult = try await session.client.send(.post, "spoolman/sync-all")
                            runner.successMessage = "Synced \(r.syncedCount ?? 0) spools" + ((r.skippedCount ?? 0) > 0 ? ", skipped \(r.skippedCount ?? 0)" : "")
                            if let first = r.errors?.first { runner.errorMessage = first }
                        } } label: { Label("Sync All Printers to Spoolman", systemImage: "arrow.triangle.2.circlepath") }
                    } footer: {
                        Text("Pushes the AMS contents of every printer to Spoolman.")
                    }
                }
            }
            .navigationTitle("Spoolman")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await reload() }
            .actionAlerts(runner)
        }
        .presentationDetents([.medium, .large])
    }

    private func reload() async {
        await status.load { try await session.client.get("spoolman/status") }
    }

    private func act(_ success: String?, _ work: @escaping () async throws -> Void) {
        Task {
            await runner.run(success, work)
            await reload()
            await store.load()
        }
    }
}
