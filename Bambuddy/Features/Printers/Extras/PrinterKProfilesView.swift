import SwiftUI
import UniformTypeIdentifiers

// MARK: Models

struct PrinterKProfile: Codable, Sendable, Hashable, Identifiable {
    var slotId: Int
    var extruderId: Int?
    var nozzleId: String
    var nozzleDiameter: String
    var filamentId: String
    var name: String
    var kValue: String
    var nCoef: String?
    var amsId: Int?
    var trayId: Int?
    var settingId: String?

    var id: String { "\(slotId)_\(extruderId ?? 0)_\(filamentId)_\(settingId ?? "")" }
    var extruder: Int { extruderId ?? 0 }
    var isHighFlow: Bool { nozzleId.uppercased().hasPrefix("HH") }
    var kDouble: Double? { Double(kValue) }

    /// K value truncated (not rounded) to three decimals, like the printer's own display.
    var kDisplay: String {
        guard let k = kDouble else { return kValue }
        let truncated = (k * 1000).rounded(.towardZero) / 1000
        return String(format: "%.3f", truncated)
    }

    var displayName: String { name.isEmpty ? "Unnamed" : name }

    /// Keys under which the web stores a profile's note, in lookup order.
    var noteKeys: [String] {
        var keys: [String] = []
        if let s = settingId, !s.isEmpty { keys.append(s) }
        keys.append("slot_\(slotId)_\(filamentId)_\(extruder)")
        keys.append("name_\(name)_\(filamentId)")
        return keys
    }
}

struct PrinterKProfilesResponse: Codable, Sendable, Hashable {
    var profiles: [PrinterKProfile]
    var nozzleDiameter: String
}

struct PrinterKProfileWrite: Codable, Sendable, Hashable {
    var slotId: Int
    var extruderId: Int
    var nozzleId: String
    var nozzleDiameter: String
    var filamentId: String
    var name: String
    var kValue: String
    var settingId: String?
}

struct PrinterKProfileDelete: Codable, Sendable, Hashable {
    var slotId: Int
    var extruderId: Int
    var nozzleId: String
    var nozzleDiameter: String
    var filamentId: String
    var settingId: String?
}

struct PrinterKProfileNotes: Codable, Sendable, Hashable {
    var notes: [String: String]

    // Keys are arbitrary strings; keep them verbatim.
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(JSONValue.self)
        var out: [String: String] = [:]
        for (k, v) in raw["notes"]?.objectValue ?? [:] { if let s = v.stringValue { out[k] = s } }
        notes = out
    }

    init(notes: [String: String]) { self.notes = notes }

    func note(for profile: PrinterKProfile) -> (key: String, text: String)? {
        for key in profile.noteKeys { if let n = notes[key], !n.isEmpty { return (key, n) } }
        return nil
    }
}

struct PrinterKProfileNoteBody: Codable, Sendable { var settingId: String; var note: String }

struct PrinterKProfileMessage: Codable, Sendable { var success: Bool?; var message: String? }

/// Export file format shared with the web UI.
struct PrinterKProfileExport: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var name: String?
        var kValue: String?
        var filamentId: String?
        var nozzleId: String?
        var nozzleDiameter: String?
        var extruderId: Int?
    }
    var version: Int?
    var exportedAt: String?
    var printer: String?
    var nozzleDiameter: String?
    var profiles: [Entry]
}

enum PrinterKProfileSort: String, CaseIterable, Identifiable {
    case name, kValue, filament
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .kValue: return "K Value"
        case .filament: return "Filament"
        }
    }
}

// MARK: List

struct PrinterKProfilesView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    let printerId: Int

    @AppStorage("kprofiles.nozzle") private var nozzle = "0.4"
    @AppStorage("kprofiles.sort") private var sort: PrinterKProfileSort = .name
    @State private var loader = Loader<PrinterKProfilesResponse>()
    @State private var notes = PrinterKProfileNotes(notes: [:])
    @State private var runner = ActionRunner()
    @State private var search = ""
    @State private var extruderFilter: Int? = nil
    @State private var flowFilter: String = "all"
    @State private var editing: PrinterKProfileEditTarget?
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var exportDoc: PrinterKProfileExportDocument?
    @State private var showImporter = false
    @State private var syncing: String?

    static let diameters = ["0.2", "0.4", "0.6", "0.8"]

    private var printer: Printer? { store.printer(printerId) }
    private var isDual: Bool { (printer?.nozzleCount ?? 1) >= 2 || (store.statuses[printerId]?.isDualNozzle ?? false) }
    private var supportsFlow: Bool { printer?.supportsNozzleFlowType ?? true }
    private var client: APIClient { session.client }

    var body: some View {
        LoadingContent(loader: loader, retry: load) { response in
            list(response.profiles)
        }
        .overlay {
            if let syncing {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(syncing).font(.subheadline)
                }
                .padding(24)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .navigationTitle("K-Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Name or filament ID")
        .environment(\.editMode, $editMode)
        .toolbar { toolbar }
        .task(id: nozzle) { await load() }
        .actionAlerts(runner)
        .sheet(item: $editing) { target in
            PrinterKProfileEditor(printerId: printerId, target: target, isDual: isDual, supportsFlow: supportsFlow,
                                  defaultDiameter: nozzle, notes: notes) { message in
                await afterWrite(message, delay: 2.5)
            }
        }
        .confirm("Delete \(selection.count) K-profile\(selection.count == 1 ? "" : "s")?", isPresented: $confirmBulkDelete,
                 message: "The profiles are removed from the printer.") {
            Task { await bulkDelete() }
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }), document: exportDoc,
                      contentType: .json, defaultFilename: exportDoc?.filename ?? "kprofiles.json") { result in
            if case .failure(let error) = result { runner.errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            Task { await importProfiles(result) }
        }
    }

    @ViewBuilder
    private func list(_ all: [PrinterKProfile]) -> some View {
        let profiles = filtered(all)
        List(selection: $selection) {
            Section {
                Picker("Nozzle", selection: $nozzle) {
                    ForEach(Self.diameters, id: \.self) { d in Text("\(d) mm").tag(d) }
                }
                .pickerStyle(.segmented)
                if isDual {
                    Picker("Extruder", selection: $extruderFilter) {
                        Text("All").tag(Int?.none)
                        Text("Left").tag(Int?.some(1))
                        Text("Right").tag(Int?.some(0))
                    }
                    .pickerStyle(.segmented)
                }
                if supportsFlow {
                    Picker("Flow", selection: $flowFilter) {
                        Text("All Flow").tag("all")
                        Text("High Flow").tag("hf")
                        Text("Standard").tag("s")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .selectionDisabled()

            if all.isEmpty {
                ContentUnavailableView {
                    Label("No K-Profiles", systemImage: "gauge.with.dots.needle.33percent")
                } description: {
                    Text("No pressure-advance profiles for \(nozzle) mm nozzles. Printers sometimes answer slowly — pull to refresh.")
                } actions: {
                    if session.can("kprofiles:create") {
                        Button("Create Profile") { editing = .new }.buttonStyle(.bordered)
                    }
                }
                .selectionDisabled()
            } else if profiles.isEmpty {
                ContentUnavailableView.search(text: search).selectionDisabled()
            }

            if isDual && extruderFilter == nil {
                ForEach([1, 0], id: \.self) { ext in
                    let group = profiles.filter { $0.extruder == ext }
                    if !group.isEmpty {
                        Section(ext == 1 ? "Left Extruder" : "Right Extruder") { rows(group) }
                    }
                }
            } else if !profiles.isEmpty {
                Section { rows(profiles) } footer: { Text("\(profiles.count) profile\(profiles.count == 1 ? "" : "s")") }
            }
        }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func rows(_ profiles: [PrinterKProfile]) -> some View {
        ForEach(profiles) { profile in
            Button { if editMode == .inactive { editing = .edit(profile) } } label: {
                HStack(spacing: 12) {
                    Text(profile.kDisplay)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName).foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text(profile.filamentId)
                            if supportsFlow { Text(profile.isHighFlow ? "High Flow" : "Standard") }
                            Text("\(profile.nozzleDiameter) mm")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if let note = notes.note(for: profile) {
                            Label(String(note.text.prefix(50)) + (note.text.count > 50 ? "…" : ""), systemImage: "note.text")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .tag(profile.id)
            .contextMenu {
                Button { editing = .edit(profile) } label: { Label("Edit", systemImage: "pencil") }
                if session.can("kprofiles:create") {
                    Button { editing = .copy(profile) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                }
                if session.can("kprofiles:delete") {
                    Button(role: .destructive) { selection = [profile.id]; confirmBulkDelete = true } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .swipeActions {
                if session.can("kprofiles:delete") {
                    Button(role: .destructive) { selection = [profile.id]; confirmBulkDelete = true } label: { Label("Delete", systemImage: "trash") }
                }
                if session.can("kprofiles:create") {
                    Button { editing = .copy(profile) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.tint(.indigo)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if editMode == .active {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { editMode = .inactive; selection = [] } }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Select All") { selection = Set(filtered(loader.value?.profiles ?? []).map(\.id)) }
                Spacer()
                Button(role: .destructive) { confirmBulkDelete = true } label: { Label("Delete (\(selection.count))", systemImage: "trash") }
                    .disabled(selection.isEmpty)
            }
        } else {
            if session.can("kprofiles:create") {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .new } label: { Image(systemName: "plus") }.accessibilityLabel("Add Profile")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(selection: $sort) {
                        ForEach(PrinterKProfileSort.allCases) { s in Text(s.label).tag(s) }
                    } label: { Label("Sort By", systemImage: "arrow.up.arrow.down") }
                    .pickerStyle(.menu)
                    Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    if session.can("kprofiles:delete") {
                        Button { editMode = .active } label: { Label("Select Profiles", systemImage: "checkmark.circle") }
                    }
                    Divider()
                    Button { prepareExport() } label: { Label("Export JSON…", systemImage: "square.and.arrow.up") }
                        .disabled((loader.value?.profiles ?? []).isEmpty)
                    if session.can("kprofiles:create") {
                        Button { showImporter = true } label: { Label("Import JSON…", systemImage: "square.and.arrow.down") }
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
    }

    // MARK: Filtering

    private func filtered(_ profiles: [PrinterKProfile]) -> [PrinterKProfile] {
        let q = search.trimmingCharacters(in: .whitespaces)
        var out = profiles.filter { p in
            (q.isEmpty || p.name.localizedCaseInsensitiveContains(q) || p.filamentId.localizedCaseInsensitiveContains(q))
                && (extruderFilter == nil || p.extruder == extruderFilter)
                && (flowFilter == "all" || (flowFilter == "hf") == p.isHighFlow)
        }
        switch sort {
        case .name: out.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .kValue: out.sort { ($0.kDouble ?? 0) < ($1.kDouble ?? 0) }
        case .filament: out.sort { $0.filamentId.localizedStandardCompare($1.filamentId) == .orderedAscending }
        }
        return out
    }

    // MARK: Networking

    private func load() async {
        await loader.load { try await client.get("printers/\(printerId)/kprofiles/", query: ["nozzle_diameter": .string(nozzle)]) }
        if let n: PrinterKProfileNotes = try? await client.get("printers/\(printerId)/kprofiles/notes") { notes = n }
    }

    private func afterWrite(_ message: String?, delay: Double) async {
        syncing = "Syncing with printer…"
        try? await Task.sleep(for: .seconds(delay))
        syncing = nil
        if let message { runner.successMessage = message }
        await load()
    }

    private func bulkDelete() async {
        let targets = (loader.value?.profiles ?? []).filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }
        var deleted = 0
        await runner.run {
            for (i, p) in targets.enumerated() {
                syncing = targets.count > 1 ? "Deleting \(i + 1) of \(targets.count)…" : "Deleting…"
                let body = PrinterKProfileDelete(slotId: p.slotId, extruderId: p.extruder, nozzleId: p.nozzleId, nozzleDiameter: p.nozzleDiameter, filamentId: p.filamentId, settingId: p.settingId)
                var req = client.makeRequest(.delete, "printers/\(printerId)/kprofiles/", body: try APICoders.encoder.encode(body))
                req.timeoutInterval = 30
                let _: EmptyResponse = try await client.perform(req)
                deleted += 1
                if i < targets.count - 1 { try await Task.sleep(for: .milliseconds(300)) }
            }
        }
        selection = []
        editMode = .inactive
        syncing = nil
        await afterWrite(deleted > 0 ? "Deleted \(deleted) profile\(deleted == 1 ? "" : "s")" : nil, delay: 4)
    }

    private func prepareExport() {
        let profiles = loader.value?.profiles ?? []
        let export = PrinterKProfileExport(
            version: 1,
            exportedAt: Date().ISO8601Format(),
            printer: printer?.name,
            nozzleDiameter: nozzle,
            profiles: profiles.map { .init(name: $0.name, kValue: $0.kValue, filamentId: $0.filamentId, nozzleId: $0.nozzleId, nozzleDiameter: $0.nozzleDiameter, extruderId: $0.extruder) }
        )
        guard let data = try? APICoders.encoder.encode(export) else { return }
        let safeName = (printer?.name ?? "printer").map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let day = Date().formatted(.iso8601.year().month().day())
        exportDoc = PrinterKProfileExportDocument(data: data, filename: "kprofiles_\(String(safeName))_\(nozzle)mm_\(day).json")
    }

    private func importProfiles(_ result: Result<URL, Error>) async {
        await runner.run {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let file = try APICoders.decoder.decode(PrinterKProfileExport.self, from: data)
            let valid = file.profiles.filter { ($0.name?.isEmpty == false) && $0.kValue != nil && ($0.filamentId?.isEmpty == false) }
            var ok = 0
            for (i, e) in valid.enumerated() {
                syncing = "Importing \(i + 1) of \(valid.count)…"
                let k = Double(e.kValue ?? "") ?? 0
                let body = PrinterKProfileWrite(slotId: 0, extruderId: e.extruderId ?? 0, nozzleId: e.nozzleId ?? "HS00-\(nozzle)",
                                                nozzleDiameter: e.nozzleDiameter ?? nozzle, filamentId: e.filamentId ?? "",
                                                name: e.name ?? "", kValue: String(format: "%.6f", k), settingId: nil)
                do {
                    let _: PrinterKProfileMessage = try await client.send(.post, "printers/\(printerId)/kprofiles/", body: body)
                    ok += 1
                } catch {}
                try await Task.sleep(for: .milliseconds(500))
            }
            syncing = nil
            await afterWrite("Imported \(ok) of \(file.profiles.count) profiles", delay: 2.5)
        }
        syncing = nil
    }
}

// MARK: Export document

struct PrinterKProfileExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    var filename: String
    init(data: Data, filename: String) { self.data = data; self.filename = filename }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        filename = "kprofiles.json"
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: Editor

enum PrinterKProfileEditTarget: Identifiable, Hashable {
    case new
    case edit(PrinterKProfile)
    case copy(PrinterKProfile)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let p): return "edit-\(p.id)"
        case .copy(let p): return "copy-\(p.id)"
        }
    }
}

private struct PrinterKProfileEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let printerId: Int
    let target: PrinterKProfileEditTarget
    let isDual: Bool
    let supportsFlow: Bool
    let defaultDiameter: String
    let notes: PrinterKProfileNotes
    let onSaved: (String?) async -> Void

    @State private var name = ""
    @State private var kText = "0.020"
    @State private var note = ""
    @State private var originalNote = ""
    @State private var noteKey: String?
    @State private var filament: PrinterFilamentChoice?
    @State private var manualFilamentId = ""
    @State private var highFlow = false
    @State private var diameter = "0.4"
    @State private var extruders: Set<Int> = [0]
    @State private var runner = ActionRunner()
    @State private var confirmDelete = false
    @State private var showFilamentPicker = false

    private var existing: PrinterKProfile? {
        switch target {
        case .new: return nil
        case .edit(let p), .copy(let p): return p
        }
    }
    private var isEdit: Bool { if case .edit = target { return true }; return false }
    private var isNew: Bool { if case .new = target { return true }; return false }
    private var client: APIClient { session.client }

    private var kValue: Double? {
        let v = Double(kText.trimmingCharacters(in: .whitespaces))
        guard let v, v >= 0, v < 10 else { return nil }
        return v
    }

    /// Whether enough is known to resolve a filament id (cloud user presets resolve on save).
    private var hasFilament: Bool {
        if existing != nil || filament != nil { return true }
        return !manualFilamentId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func resolveFilamentId() async -> String? {
        if let existing { return existing.filamentId }
        if let filament { return await PrinterFilamentLogic.resolveFilamentId(filament, client: client) }
        let manual = manualFilamentId.trimmingCharacters(in: .whitespaces).uppercased()
        return manual.isEmpty ? nil : manual
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isNew {
                        TextField("Name (optional)", text: $name)
                    } else {
                        InfoRow("Name", existing?.displayName)
                    }
                    LabeledContent("K Value") {
                        TextField("0.020", text: $kText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                    }
                } footer: {
                    if kValue == nil { Text("Enter a pressure-advance value such as 0.020.").foregroundStyle(.red) }
                }

                Section("Filament") {
                    if let existing {
                        InfoRow("Filament ID", existing.filamentId)
                    } else {
                        Button { showFilamentPicker = true } label: {
                            HStack {
                                Text("Preset").foregroundStyle(.primary)
                                Spacer()
                                Text(filament?.name ?? "Choose…").foregroundStyle(.secondary).lineLimit(1)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        if filament == nil {
                            TextField("Or enter a filament ID (e.g. GFL99)", text: $manualFilamentId)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                        } else if let fid = filament?.filamentId, filament?.source != .cloud || filament?.rawId.hasPrefix("GFS") == true {
                            InfoRow("Filament ID", fid)
                        }
                    }
                }

                Section("Nozzle") {
                    if isNew {
                        if supportsFlow {
                            Picker("Flow", selection: $highFlow) {
                                Text("Standard").tag(false)
                                Text("High Flow").tag(true)
                            }
                        }
                        Picker("Diameter", selection: $diameter) {
                            ForEach(PrinterKProfilesView.diameters, id: \.self) { d in Text("\(d) mm").tag(d) }
                        }
                        if isDual {
                            Toggle("Left Extruder", isOn: binding(for: 1))
                            Toggle("Right Extruder", isOn: binding(for: 0))
                        }
                    } else if let existing {
                        if supportsFlow { InfoRow("Flow", existing.isHighFlow ? "High Flow" : "Standard") }
                        InfoRow("Diameter", "\(existing.nozzleDiameter) mm")
                        if isDual { InfoRow("Extruder", existing.extruder == 1 ? "Left" : "Right") }
                    }
                }

                Section("Note") {
                    TextField("Optional note stored in Bambuddy", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                }

                if isEdit, session.can("kprofiles:delete") {
                    Section {
                        Button("Delete Profile", role: .destructive) { confirmDelete = true }
                    }
                }
                if isEdit, existing?.slotId == 0 {
                    Section {
                        Text("This profile occupies calibration slot 0 and cannot be edited in place; duplicate it instead.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isEdit ? "Edit K-Profile" : (isNew ? "New K-Profile" : "Duplicate K-Profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave || runner.isRunning)
                }
            }
            .disabled(runner.isRunning)
            .overlay { if runner.isRunning { ProgressView().controlSize(.large) } }
            .actionAlerts(runner)
            .confirm("Delete this K-profile?", isPresented: $confirmDelete, message: "It is removed from the printer.") {
                Task { await delete() }
            }
            .sheet(isPresented: $showFilamentPicker) {
                PrinterFilamentPresetPicker(printerId: printerId, selection: $filament, nozzle: diameter)
            }
            .onAppear(perform: setup)
        }
    }

    private var canSave: Bool {
        guard kValue != nil, hasFilament else { return false }
        if isEdit { return session.can("kprofiles:update") && (existing?.slotId ?? 0) > 0 || noteChanged }
        if isNew, isDual, extruders.isEmpty { return false }
        return session.can("kprofiles:create") || session.can("kprofiles:update")
    }

    private var noteChanged: Bool { note.trimmingCharacters(in: .whitespacesAndNewlines) != originalNote }

    private func binding(for ext: Int) -> Binding<Bool> {
        Binding(get: { extruders.contains(ext) }, set: { on in if on { extruders.insert(ext) } else { extruders.remove(ext) } })
    }

    private func setup() {
        diameter = defaultDiameter
        extruders = isDual ? [0, 1] : [0]
        if let existing {
            kText = existing.kDisplay
            if case .copy = target { name = "\(existing.name) (Copy)" } else { name = existing.name }
            if let n = notes.note(for: existing) {
                note = n.text
                originalNote = n.text
                if isEdit { noteKey = n.key }
            }
        }
    }

    private func nozzleId(highFlow: Bool, diameter: String) -> String { "\(highFlow ? "HH00" : "HS00")-\(diameter)" }

    private func save() async {
        guard let k = kValue else { return }
        let kString = String(format: "%.6f", k)
        await runner.run {
            guard let filamentId = await resolveFilamentId() else {
                throw APIError(status: 0, message: "Couldn't determine the Bambu filament ID for this preset. Pick another preset or enter an ID.", code: nil, detail: nil)
            }
            var message: String?
            var noteTarget: String?
            switch target {
            case .edit(let p):
                let kChanged = p.kDouble.map { abs($0 - k) > 0.0000005 } ?? true
                if kChanged && p.slotId > 0 {
                    let body = PrinterKProfileWrite(slotId: p.slotId, extruderId: p.extruder, nozzleId: p.nozzleId.isEmpty ? nozzleId(highFlow: false, diameter: p.nozzleDiameter) : p.nozzleId,
                                                    nozzleDiameter: p.nozzleDiameter, filamentId: p.filamentId, name: p.name, kValue: kString, settingId: p.settingId)
                    let r: PrinterKProfileMessage = try await client.send(.post, "printers/\(printerId)/kprofiles/", body: body)
                    message = r.message ?? "K-profile updated"
                }
                noteTarget = noteKey ?? p.settingId.flatMap { $0.isEmpty ? nil : $0 } ?? "slot_\(p.slotId)_\(p.filamentId)_\(p.extruder)"
            case .copy(let p):
                let body = PrinterKProfileWrite(slotId: 0, extruderId: p.extruder, nozzleId: p.nozzleId.isEmpty ? nozzleId(highFlow: false, diameter: p.nozzleDiameter) : p.nozzleId,
                                                nozzleDiameter: p.nozzleDiameter, filamentId: p.filamentId, name: name, kValue: kString, settingId: nil)
                let r: PrinterKProfileMessage = try await client.send(.post, "printers/\(printerId)/kprofiles/", body: body)
                message = r.message ?? "K-profile added"
                noteTarget = "name_\(name)_\(p.filamentId)"
            case .new:
                var finalName = name.trimmingCharacters(in: .whitespaces)
                if finalName.isEmpty { finalName = "\(highFlow ? "HF" : "S") \(filament?.name ?? filamentId)" }
                let targets = isDual ? extruders.sorted() : [0]
                let bodies = targets.map {
                    PrinterKProfileWrite(slotId: 0, extruderId: $0, nozzleId: nozzleId(highFlow: highFlow, diameter: diameter),
                                         nozzleDiameter: diameter, filamentId: filamentId, name: finalName, kValue: kString, settingId: nil)
                }
                if bodies.count > 1 {
                    let r: PrinterKProfileMessage = try await client.send(.post, "printers/\(printerId)/kprofiles/batch", body: bodies)
                    message = r.message ?? "K-profiles added"
                } else if let body = bodies.first {
                    let r: PrinterKProfileMessage = try await client.send(.post, "printers/\(printerId)/kprofiles/", body: body)
                    message = r.message ?? "K-profile added"
                }
                noteTarget = "name_\(finalName)_\(filamentId)"
            }
            if noteChanged, let key = noteTarget {
                let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                try await client.call(.put, "printers/\(printerId)/kprofiles/notes", body: PrinterKProfileNoteBody(settingId: key, note: text))
                if message == nil { message = text.isEmpty ? "Note removed" : "Note saved" }
            }
            dismiss()
            await onSaved(message)
        }
    }

    private func delete() async {
        guard let p = existing else { return }
        await runner.run {
            let body = PrinterKProfileDelete(slotId: p.slotId, extruderId: p.extruder, nozzleId: p.nozzleId, nozzleDiameter: p.nozzleDiameter, filamentId: p.filamentId, settingId: p.settingId)
            let req = client.makeRequest(.delete, "printers/\(printerId)/kprofiles/", body: try APICoders.encoder.encode(body))
            let _: EmptyResponse = try await client.perform(req)
            dismiss()
            await onSaved("K-profile deleted")
        }
    }
}
