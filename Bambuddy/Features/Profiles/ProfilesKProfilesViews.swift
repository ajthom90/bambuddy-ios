import SwiftUI
import UniformTypeIdentifiers

// MARK: - K-profiles tab

struct ProfilesKProfilesTab: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @AppStorage("profiles.kNozzle") private var nozzle = "0.4"
    @AppStorage("profiles.kSort") private var sort = "name"
    @AppStorage("profiles.kPrinter") private var storedPrinterId = 0

    @State private var loader = Loader<ProfilesKProfilesResponse>()
    @State private var notes: [String: String] = [:]
    @State private var filamentNames: [String: String] = [:]
    @State private var search = ""
    @State private var extruderFilter = "all"
    @State private var flowFilter = "all"
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var editor: ProfilesKEditorSeed?
    @State private var confirmBulkDelete = false
    @State private var showImporter = false
    @State private var runner = ActionRunner()

    private var activePrinters: [Printer] { store.printers.filter(\.isActive) }
    private var printer: Printer? {
        activePrinters.first { $0.id == storedPrinterId } ?? activePrinters.first
    }
    private var isDual: Bool { printer?.nozzleCount == 2 }
    private var supportsFlow: Bool { printer?.supportsNozzleFlowType ?? true }

    var body: some View {
        Group {
            if store.printers.isEmpty {
                ContentUnavailableView("No Printers", systemImage: "printer",
                                       description: Text("Add a printer to manage its pressure-advance calibration profiles."))
            } else if activePrinters.isEmpty {
                ContentUnavailableView("No Active Printers", systemImage: "printer.dotmatrix",
                                       description: Text("Enable a printer's connection to read its K-profiles."))
            } else if let printer {
                content(printer)
            }
        }
        .task { await loadNames() }
    }

    @ViewBuilder
    private func content(_ printer: Printer) -> some View {
        let profiles = filteredProfiles
        List(selection: $selection) {
            Section {
                Picker("Printer", selection: Binding(get: { printer.id }, set: { storedPrinterId = $0; selection = [] })) {
                    ForEach(activePrinters) { Text($0.name).tag($0.id) }
                }
                Picker("Nozzle", selection: $nozzle) {
                    ForEach(ProfilesKMath.diameters, id: \.self) { Text("\($0) mm").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if let error = loader.error, loader.value == nil || error.localizedCaseInsensitiveContains("not connected") {
                ContentUnavailableView {
                    Label(error.localizedCaseInsensitiveContains("not connected") ? "Printer Offline" : "Couldn't Load", systemImage: "wifi.slash")
                } description: {
                    Text(error.localizedCaseInsensitiveContains("not connected")
                         ? "K-profiles are read directly from the printer. Make sure it's powered on and connected."
                         : error)
                } actions: {
                    Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
                }
            } else if loader.value == nil {
                HStack { Spacer(); ProgressView("Reading profiles from printer…"); Spacer() }
                    .listRowBackground(Color.clear)
            } else if profiles.isEmpty {
                if search.isEmpty && extruderFilter == "all" && flowFilter == "all" {
                    ContentUnavailableView {
                        Label("No K-Profiles", systemImage: "gauge.with.dots.needle.33percent")
                    } description: {
                        Text("This printer has no pressure-advance profiles for the \(nozzle) mm nozzle.")
                    } actions: {
                        if session.can("kprofiles:create") {
                            Button("Add Profile") { editor = ProfilesKEditorSeed(mode: .new) }.buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    ContentUnavailableView("No Matching Profiles", systemImage: "magnifyingglass",
                                           description: Text("Try a different search or filter."))
                }
            } else if isDual {
                profileSection("Left Extruder", profiles.filter { $0.extruder == 1 })
                profileSection("Right Extruder", profiles.filter { $0.extruder == 0 })
            } else {
                profileSection("\(profiles.count) Profile\(profiles.count == 1 ? "" : "s")", profiles)
            }
        }
        .environment(\.editMode, $editMode)
        .searchable(text: $search, prompt: "Search profiles")
        .refreshable { await load() }
        .overlay(alignment: .top) {
            if loader.isLoading && loader.value != nil {
                ProgressView().padding(8).background(.regularMaterial, in: .capsule).padding(.top, 8)
            }
        }
        .task(id: "\(printer.id)-\(nozzle)") {
            loader.value = nil
            loader.error = nil
            await load()
        }
        .onChange(of: supportsFlow) { _, new in if !new { flowFilter = "all" } }
        .toolbar { toolbar(printer) }
        .sheet(item: $editor) { seed in
            ProfilesKProfileEditor(seed: seed, printer: printer, nozzle: nozzle, filamentNames: filamentNames, notes: notes) {
                await load()
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { Task { await importProfiles(url, printer: printer) } }
        }
        .confirm("Delete \(selection.count) profile\(selection.count == 1 ? "" : "s")?", isPresented: $confirmBulkDelete,
                 message: "The selected profiles are removed from the printer. This cannot be undone.") {
            Task { await bulkDelete(printer) }
        }
        .actionAlerts(runner)
    }

    @ViewBuilder
    private func profileSection(_ title: String, _ rows: [ProfilesKProfile]) -> some View {
        Section(title) {
            if rows.isEmpty {
                Text("No profiles").foregroundStyle(.secondary)
            }
            ForEach(rows) { p in
                let note = note(for: p).text
                Button {
                    if editMode.isEditing {
                        if selection.contains(p.id) { selection.remove(p.id) } else { selection.insert(p.id) }
                    } else {
                        editor = ProfilesKEditorSeed(mode: .edit(p))
                    }
                } label: {
                    ProfilesKProfileRow(profile: p, filamentName: filamentName(p), note: note)
                }
                .tint(.primary)
                .tag(p.id)
                .swipeActions(edge: .trailing) {
                    if session.can("kprofiles:delete") {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            selection = [p.id]
                            confirmBulkDelete = true
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    if session.can("kprofiles:create") {
                        Button("Copy", systemImage: "plus.square.on.square") { editor = ProfilesKEditorSeed(mode: .copy(p)) }.tint(.indigo)
                    }
                }
                .contextMenu {
                    Button("Edit", systemImage: "pencil") { editor = ProfilesKEditorSeed(mode: .edit(p)) }
                    if session.can("kprofiles:create") {
                        Button("Copy", systemImage: "plus.square.on.square") { editor = ProfilesKEditorSeed(mode: .copy(p)) }
                    }
                    Button("Copy K Value", systemImage: "doc.on.doc") { UIPasteboard.general.string = p.displayK }
                    if session.can("kprofiles:delete") {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            selection = [p.id]
                            confirmBulkDelete = true
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ printer: Printer) -> some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == filteredProfiles.count ? "Deselect All" : "Select All") {
                    selection = selection.count == filteredProfiles.count ? [] : Set(filteredProfiles.map(\.id))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Delete (\(selection.count))", systemImage: "trash", role: .destructive) { confirmBulkDelete = true }
                    .disabled(selection.isEmpty || !session.can("kprofiles:delete"))
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { editMode = .inactive; selection = [] }
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = ProfilesKEditorSeed(mode: .new) } label: { Label("Add Profile", systemImage: "plus") }
                    .disabled(!session.can("kprofiles:create"))
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        Label("Name", systemImage: "textformat").tag("name")
                        Label("K Value", systemImage: "number").tag("k_value")
                        Label("Filament", systemImage: "drop").tag("filament")
                    }
                    if isDual {
                        Picker("Extruder", selection: $extruderFilter) {
                            Text("All Extruders").tag("all")
                            Text("Left Only").tag("left")
                            Text("Right Only").tag("right")
                        }
                    }
                    if supportsFlow {
                        Picker("Flow Type", selection: $flowFilter) {
                            Text("All Flow Types").tag("all")
                            Text("High Flow Only").tag("hf")
                            Text("Standard Only").tag("s")
                        }
                    }
                } label: {
                    Label("Sort & Filter", systemImage: extruderFilter != "all" || flowFilter != "all"
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Select", systemImage: "checkmark.circle") { editMode = .active }
                    .disabled(filteredProfiles.isEmpty || !session.can("kprofiles:delete"))
            }
            ToolbarItem(placement: .secondaryAction) {
                ShareLink(item: exportFile(printer), preview: SharePreview(exportFile(printer).fileName)) {
                    Label("Export Profiles", systemImage: "square.and.arrow.up")
                }
                .disabled(loader.value?.profiles.isEmpty ?? true)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Import Profiles", systemImage: "square.and.arrow.down") { showImporter = true }
                    .disabled(!session.can("kprofiles:create"))
            }
        }
    }

    // MARK: Data

    private var filteredProfiles: [ProfilesKProfile] {
        let all = loader.value?.profiles ?? []
        let q = search.lowercased()
        return all.filter { p in
            (q.isEmpty || p.name.lowercased().contains(q) || p.filamentId.lowercased().contains(q) || filamentName(p).lowercased().contains(q))
                && (extruderFilter == "all" || (extruderFilter == "left" && p.extruder == 1) || (extruderFilter == "right" && p.extruder == 0))
                && (flowFilter == "all" || (flowFilter == "hf" && p.nozzleId.hasPrefix("HH")) || (flowFilter == "s" && p.nozzleId.hasPrefix("HS")))
        }
        .sorted { a, b in
            switch sort {
            case "k_value": return a.kDouble < b.kDouble
            case "filament": return filamentName(a).localizedStandardCompare(filamentName(b)) == .orderedAscending
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    private func filamentName(_ p: ProfilesKProfile) -> String {
        filamentNames[p.filamentId] ?? p.nameWithoutFlowPrefix
    }

    private func note(for p: ProfilesKProfile) -> (text: String, key: String?) {
        for key in p.noteKeys { if let n = notes[key], !n.isEmpty { return (n, key) } }
        return ("", nil)
    }

    private func load() async {
        guard let printer else { return }
        let client = session.client
        await loader.load { try await client.get("printers/\(printer.id)/kprofiles/", query: ["nozzle_diameter": .string(nozzle)]) }
        let n: ProfilesKProfileNotes? = try? await client.get("printers/\(printer.id)/kprofiles/notes")
        notes = n?.notes ?? [:]
    }

    private func loadNames() async {
        let client = session.client
        async let builtin: [ProfilesBuiltinFilament]? = try? client.get("cloud/builtin-filaments")
        async let idMap: [String: String]? = try? client.get("cloud/filament-id-map", as: [String: String].self)
        var map: [String: String] = [:]
        for b in await builtin ?? [] { map[b.filamentId] = b.name }
        for (k, v) in await idMap ?? [:] where map[k] == nil { map[k] = v }
        filamentNames = map
    }

    private func exportFile(_ printer: Printer) -> ProfilesJSONFile {
        let export = ProfilesKProfileExport(
            version: 1, exportedAt: Date().ISO8601Format(), printer: printer.name, nozzleDiameter: nozzle,
            profiles: (loader.value?.profiles ?? []).map {
                .init(name: $0.name, kValue: $0.kValue, filamentId: $0.filamentId, nozzleId: $0.nozzleId, nozzleDiameter: $0.nozzleDiameter, extruderId: $0.extruder)
            })
        let day = Date().formatted(.iso8601.year().month().day())
        return ProfilesJSONFile(fileName: "kprofiles_\(printer.name)_\(nozzle)mm_\(day).json", value: (try? JSONValue.from(export)) ?? .null)
    }

    private func importProfiles(_ url: URL, printer: Printer) async {
        await runner.run {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard let file = try? APICoders.decoder.decode(ProfilesKProfileExport.self, from: data), let entries = file.profiles else {
                throw APIError(status: 0, message: "That file isn't a K-profile export.", code: nil, detail: nil)
            }
            var imported = 0
            for e in entries {
                guard let name = e.name, let k = e.kValue.flatMap(ProfilesKMath.wire), let fid = e.filamentId else { continue }
                let body = ProfilesKProfileCreate(slotId: 0, extruderId: e.extruderId ?? 0,
                                                  nozzleId: e.nozzleId ?? "\(ProfilesKMath.standardFlow)-\(nozzle)",
                                                  nozzleDiameter: e.nozzleDiameter ?? nozzle, filamentId: fid, name: name, kValue: k)
                do {
                    try await session.client.call(.post, "printers/\(printer.id)/kprofiles/", body: body)
                    imported += 1
                    try await Task.sleep(for: .milliseconds(500))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
            runner.successMessage = "Imported \(imported) of \(entries.count) profiles"
            await load()
        }
    }

    private func bulkDelete(_ printer: Printer) async {
        let targets = (loader.value?.profiles ?? []).filter { selection.contains($0.id) }
        var deleted = 0
        await runner.run {
            for p in targets {
                let body = ProfilesKProfileDelete(slotId: p.slotId, extruderId: p.extruder, nozzleId: p.nozzleId,
                                                  nozzleDiameter: p.nozzleDiameter, filamentId: p.filamentId, settingId: p.settingId)
                do {
                    try await session.client.call(.delete, "printers/\(printer.id)/kprofiles/", body: body)
                    deleted += 1
                    try await Task.sleep(for: .milliseconds(300))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
            runner.successMessage = "Deleted \(deleted) profile\(deleted == 1 ? "" : "s")"
        }
        selection = []
        editMode = .inactive
        try? await Task.sleep(for: .seconds(1))
        await load()
    }
}

private struct ProfilesKProfileRow: View {
    let profile: ProfilesKProfile
    let filamentName: String
    let note: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(profile.displayK)
                .font(.body.monospacedDigit().bold())
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile.name.isEmpty ? "Unnamed" : profile.name).lineLimit(1)
                    if !note.isEmpty { Image(systemName: "note.text").font(.caption).foregroundStyle(.yellow) }
                }
                Text(filamentName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.yellow.opacity(0.8)).lineLimit(1)
                }
            }
            Spacer()
            Text("\(profile.flowLabel) \(profile.nozzleDiameter)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Editor

struct ProfilesKEditorSeed: Identifiable {
    enum Mode { case new, edit(ProfilesKProfile), copy(ProfilesKProfile) }
    let id = UUID()
    var mode: Mode
}

private struct ProfilesKProfileEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let seed: ProfilesKEditorSeed
    let printer: Printer
    let filamentNames: [String: String]
    let notes: [String: String]
    let onFinished: () async -> Void

    @State private var name: String
    @State private var kValue: String
    @State private var flow: String
    @State private var diameter: String
    @State private var extruders: Set<Int>
    @State private var note = ""
    @State private var initialNote = ""
    @State private var initialNoteKey: String?
    @State private var filamentChoice: ProfilesFilamentOption?
    @State private var options: [ProfilesFilamentOption] = []
    @State private var loadingOptions = false
    @State private var syncing: String?
    @State private var confirmDelete = false
    @State private var runner = ActionRunner()
    @FocusState private var kFocused: Bool

    init(seed: ProfilesKEditorSeed, printer: Printer, nozzle: String, filamentNames: [String: String], notes: [String: String], onFinished: @escaping () async -> Void) {
        self.seed = seed
        self.printer = printer
        self.filamentNames = filamentNames
        self.notes = notes
        self.onFinished = onFinished
        let dual = printer.nozzleCount == 2
        switch seed.mode {
        case .new:
            _name = State(initialValue: "")
            _kValue = State(initialValue: "0.020")
            _flow = State(initialValue: ProfilesKMath.standardFlow)
            _diameter = State(initialValue: nozzle)
            _extruders = State(initialValue: dual ? [0, 1] : [0])
        case .edit(let p):
            _name = State(initialValue: p.name)
            _kValue = State(initialValue: p.displayK)
            _flow = State(initialValue: p.flowPrefix)
            _diameter = State(initialValue: p.nozzleDiameter)
            _extruders = State(initialValue: [p.extruder])
        case .copy(let p):
            _name = State(initialValue: "\(p.name) (Copy)")
            _kValue = State(initialValue: p.displayK)
            _flow = State(initialValue: p.flowPrefix)
            _diameter = State(initialValue: p.nozzleDiameter)
            _extruders = State(initialValue: [p.extruder])
        }
    }

    private var editing: ProfilesKProfile? { if case .edit(let p) = seed.mode { return p }; return nil }
    private var source: ProfilesKProfile? {
        switch seed.mode { case .edit(let p), .copy(let p): return p; case .new: return nil }
    }
    private var isDual: Bool { printer.nozzleCount == 2 }
    private var supportsFlow: Bool { printer.supportsNozzleFlowType ?? true }
    private var canSave: Bool {
        guard session.can(editing != nil ? "kprofiles:update" : "kprofiles:create") else { return false }
        guard ProfilesKMath.wire(kValue) != nil else { return false }
        if editing == nil {
            if name.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if source == nil && filamentChoice == nil { return false }
            if isDual && extruders.isEmpty { return false }
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Profile Name", text: $name)
                        .disabled(editing != nil)
                    LabeledContent("K Value") {
                        TextField("0.020", text: $kValue)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                            .focused($kFocused)
                    }
                } footer: {
                    Text("Pressure advance factor. Typical values are 0.01–0.06 for direct drive; the printer stores three decimals.")
                }
                .onChange(of: kFocused) { _, focused in
                    if !focused, ProfilesKMath.wire(kValue) != nil { kValue = ProfilesKMath.truncated(kValue) }
                }

                Section("Filament") {
                    if let source {
                        LabeledContent("Filament", value: filamentNames[source.filamentId] ?? source.nameWithoutFlowPrefix)
                        LabeledContent("Filament ID", value: source.filamentId)
                    } else {
                        NavigationLink {
                            ProfilesFilamentPicker(options: options, loading: loadingOptions, selection: $filamentChoice)
                        } label: {
                            LabeledContent("Filament") {
                                Text(filamentChoice?.name ?? "Choose…").lineLimit(1)
                            }
                        }
                    }
                }
                .onChange(of: filamentChoice) { _, f in
                    if let f, name.isEmpty { name = "\(flow == ProfilesKMath.highFlow ? "HF" : "S") \(f.name)" }
                }

                Section("Nozzle") {
                    if supportsFlow {
                        Picker("Flow Type", selection: $flow) {
                            Text("Standard").tag(ProfilesKMath.standardFlow)
                            Text("High Flow").tag(ProfilesKMath.highFlow)
                        }
                        .disabled(editing != nil)
                    }
                    Picker("Nozzle Size", selection: $diameter) {
                        ForEach(Set(ProfilesKMath.diameters + [diameter]).sorted(), id: \.self) { Text("\($0) mm").tag($0) }
                    }
                    .disabled(editing != nil)
                    if isDual {
                        if let editing {
                            LabeledContent("Extruder", value: editing.extruder == 1 ? "Left" : "Right")
                        } else {
                            Toggle("Left Extruder", isOn: extruderBinding(1))
                            Toggle("Right Extruder", isOn: extruderBinding(0))
                        }
                    }
                }

                Section {
                    TextField("Optional note", text: $note, axis: .vertical).lineLimit(2...5)
                } header: {
                    Text("Note")
                } footer: {
                    Text("Notes are stored in Bambuddy, not on the printer.")
                }

                if let editing, session.can("kprofiles:delete") {
                    Section {
                        Button("Delete Profile", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Slot \(editing.slotId)\(editing.settingId.map { " · \($0)" } ?? "")")
                    }
                }
            }
            .disabled(syncing != nil)
            .overlay {
                if let syncing {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text(syncing).font(.headline)
                        Text("Waiting for the printer to apply the change.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
            .navigationTitle(editing != nil ? "Edit K-Profile" : "New K-Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(syncing != nil) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave || syncing != nil || runner.isRunning)
                }
            }
            .interactiveDismissDisabled(syncing != nil)
            .confirm("Delete \(name)?", isPresented: $confirmDelete, message: "The profile is removed from the printer. This cannot be undone.") {
                Task { await delete() }
            }
            .actionAlerts(runner)
        }
        .task {
            if let source {
                for key in source.noteKeys { if let n = notes[key], !n.isEmpty { note = n; initialNote = n; initialNoteKey = key; break } }
            }
            if source == nil { await loadOptions() }
        }
    }

    private func extruderBinding(_ id: Int) -> Binding<Bool> {
        Binding(get: { extruders.contains(id) }, set: { if $0 { extruders.insert(id) } else { extruders.remove(id) } })
    }

    private func loadOptions() async {
        loadingOptions = true
        defer { loadingOptions = false }
        let client = session.client
        async let local: ProfilesLocalPresetsResponse? = try? client.get("local-presets/")
        async let orca: ProfilesOrcaProfileList? = try? client.get("orca-cloud/profiles")
        async let cloud: ProfilesSlicerSettingsResponse? = try? client.get("cloud/settings")
        async let builtin: [ProfilesBuiltinFilament]? = try? client.get("cloud/builtin-filaments")
        options = await ProfilesFilamentOption.build(local: local?.filament ?? [], orca: orca?.filament ?? [],
                                                     cloud: cloud?.filament ?? [], builtin: builtin ?? [])
    }

    private func resolveFilamentId() async throws -> String {
        if let source { return source.filamentId }
        guard let choice = filamentChoice else { throw APIError(status: 0, message: "Choose a filament.", code: nil, detail: nil) }
        if !choice.filamentId.isEmpty { return choice.filamentId }
        if choice.source == .cloud,
           let detail: ProfilesSlicerSettingDetail = try? await session.client.get("cloud/settings/\(ProfilesAPI.escape(choice.id))"),
           let fid = detail.filamentId, !fid.isEmpty {
            return fid
        }
        throw APIError(status: 0, message: "Couldn't determine a filament ID for “\(choice.name)”. Pick a different preset.", code: nil, detail: nil)
    }

    private func save() async {
        guard let k = ProfilesKMath.wire(kValue) else { return }
        let path = "printers/\(printer.id)/kprofiles/"
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        await runner.run {
            let client = session.client
            var noteKey: String
            var wait = 2.5
            if let p = editing {
                let body = ProfilesKProfileCreate(slotId: p.slotId, extruderId: p.extruder,
                                                  nozzleId: p.nozzleId.isEmpty ? "\(flow)-\(diameter)" : p.nozzleId,
                                                  nozzleDiameter: p.nozzleDiameter, filamentId: p.filamentId,
                                                  name: p.name, kValue: k, settingId: p.settingId)
                try await client.call(.post, path, body: body)
                noteKey = p.slotId > 0 ? (p.settingId ?? "slot_\(p.slotId)_\(p.filamentId)_\(p.extruder)") : "name_\(p.name)_\(p.filamentId)"
            } else {
                let fid = try await resolveFilamentId()
                let ids = isDual ? extruders.sorted() : [source?.extruder ?? 0]
                let bodies = ids.map {
                    ProfilesKProfileCreate(slotId: 0, extruderId: $0, nozzleId: "\(flow)-\(diameter)", nozzleDiameter: diameter,
                                           filamentId: fid, name: trimmedName, kValue: k)
                }
                if bodies.count == 1 {
                    try await client.call(.post, path, body: bodies[0])
                } else {
                    syncing = "Saving \(bodies.count) profiles…"
                    try await client.call(.post, path + "batch", body: bodies)
                    wait = 3
                }
                noteKey = "name_\(trimmedName)_\(fid)"
            }
            if note != initialNote {
                if note.isEmpty, let initialNoteKey { noteKey = initialNoteKey }
                try? await client.call(.put, "printers/\(printer.id)/kprofiles/notes", body: ProfilesKProfileNoteBody(settingId: noteKey, note: note))
            }
            syncing = "Syncing with printer…"
            try? await Task.sleep(for: .seconds(wait))
            await onFinished()
            syncing = nil
            dismiss()
        }
        if runner.errorMessage != nil { syncing = nil }
    }

    private func delete() async {
        guard let p = editing else { return }
        await runner.run {
            let body = ProfilesKProfileDelete(slotId: p.slotId, extruderId: p.extruder, nozzleId: p.nozzleId,
                                              nozzleDiameter: p.nozzleDiameter, filamentId: p.filamentId, settingId: p.settingId)
            try await session.client.call(.delete, "printers/\(printer.id)/kprofiles/", body: body)
            syncing = "Deleting…"
            try? await Task.sleep(for: .seconds(4))
            await onFinished()
            syncing = nil
            dismiss()
        }
        if runner.errorMessage != nil { syncing = nil }
    }
}

private struct ProfilesFilamentPicker: View {
    let options: [ProfilesFilamentOption]
    let loading: Bool
    @Binding var selection: ProfilesFilamentOption?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        let shown = search.isEmpty ? options : options.filter { $0.name.localizedCaseInsensitiveContains(search) }
        List {
            ForEach(ProfilesFilamentOption.Source.allCases, id: \.self) { source in
                let items = shown.filter { $0.source == source }
                if !items.isEmpty {
                    Section("\(source.title) (\(items.count))") {
                        ForEach(items) { f in
                            Button {
                                selection = f
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.name).foregroundStyle(.primary)
                                        if !f.filamentId.isEmpty || !f.material.isEmpty {
                                            Text([f.material, f.filamentId].filter { !$0.isEmpty }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selection?.id == f.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if loading && options.isEmpty {
                ProgressView("Loading filaments…")
            } else if shown.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No Filaments", systemImage: "drop",
                                           description: Text("Import presets or connect a cloud account to choose a filament."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .searchable(text: $search, prompt: "Search filaments")
        .navigationTitle("Filament")
        .navigationBarTitleDisplayMode(.inline)
    }
}
