import SwiftUI

/// Seed data for the preset editor sheet.
struct ProfilesEditorSeed: Identifiable {
    enum Mode { case create, duplicate, edit, template }
    let id = UUID()
    var mode: Mode
    var kind: ProfilesPresetKind
    var name: String
    var baseId: String
    var setting: [String: JSONValue]
    var editingId: String?
}

// MARK: - Bambu Cloud tab

struct ProfilesCloudTab: View {
    @Environment(AppSession.self) private var session
    @State private var status = Loader<ProfilesCloudStatus>()
    @State private var settings = Loader<ProfilesSlicerSettingsResponse>()
    @State private var runner = ActionRunner()
    @State private var lastSync: Date?

    var body: some View {
        LoadingContent(loader: status, retry: loadStatus) { st in
            if st.isAuthenticated {
                LoadingContent(loader: settings, retry: loadSettings) { response in
                    ProfilesCloudPresetList(status: st, response: response, lastSync: lastSync,
                                            reload: loadSettings, logout: logout)
                }
                .task { if settings.value == nil { await loadSettings() } }
            } else {
                ProfilesCloudLoginForm(signInExpired: st.signInExpired == true) {
                    settings.value = nil
                    await loadStatus()
                }
            }
        }
        .task { await loadStatus() }
        .actionAlerts(runner)
    }

    private func loadStatus() async {
        await status.load { try await session.client.get("cloud/status") }
    }

    private func loadSettings() async {
        await settings.load { try await session.client.get("cloud/settings") }
        if settings.error == nil { lastSync = Date() }
    }

    private func logout() async {
        await runner.run("Signed out of Bambu Cloud") {
            try await session.client.call(.post, "cloud/logout")
            settings.value = nil
            await loadStatus()
        }
    }
}

// MARK: Login

private struct ProfilesCloudLoginForm: View {
    enum Step { case credentials, code, token }
    @Environment(AppSession.self) private var session
    let signInExpired: Bool
    let onSignedIn: () async -> Void

    @State private var step: Step = .credentials
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var token = ""
    @State private var region = "global"
    @State private var verificationType = "email"
    @State private var tfaKey: String?
    @State private var captchaBlocked = false
    @State private var info: String?
    @State private var runner = ActionRunner()

    private var canAuth: Bool { session.can("cloud:auth") }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "cloud.fill").font(.system(size: 36)).foregroundStyle(.tint)
                    Text("Sign in to Bambu Cloud").font(.title3.bold())
                    Text("Access and manage your slicer presets synced with Bambu Studio.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if signInExpired {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bambu Cloud sign-in expired").font(.subheadline.bold())
                            Text("Bambu no longer accepts the stored session. Sign in again to keep syncing presets.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                }
            }
            if captchaBlocked && step != .token {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Bambu is challenging this network").font(.subheadline.bold())
                            Text("Bambu's servers are asking for a CAPTCHA, so no password will be accepted right now. Wait a while and try again, or sign in with an access token instead.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Use an Access Token") { captchaBlocked = false; step = .token }
                                .font(.caption.bold())
                        }
                    } icon: { Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange) }
                }
            }
            switch step {
            case .credentials:
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    regionPicker
                }
                Section {
                    submitButton("Sign In", enabled: !email.isEmpty && !password.isEmpty) { await login() }
                    Button("Use an Access Token Instead", systemImage: "key") { step = .token }
                }
            case .code:
                Section {
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .font(.title2.monospacedDigit())
                        .onChange(of: code) { _, new in
                            let digits = String(new.filter(\.isNumber).prefix(6))
                            if digits != new { code = digits }
                        }
                } header: {
                    Text(verificationType == "totp" ? "Authenticator Code" : "Verification Code")
                } footer: {
                    Text(verificationType == "totp"
                         ? "Enter the 6-digit code from your authenticator app."
                         : "Enter the code Bambu Lab sent to \(email).")
                }
                Section {
                    submitButton("Verify", enabled: code.count == 6) { await verify() }
                    Button("Back") { step = .credentials; code = "" }
                }
            case .token:
                Section {
                    TextEditor(text: $token)
                        .font(.caption.monospaced())
                        .frame(minHeight: 110)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    regionPicker
                } header: {
                    Text("Access Token")
                } footer: {
                    Text("Paste an access token from Bambu Studio or another signed-in Bambu Lab client.")
                }
                Section {
                    submitButton("Save Token", enabled: !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { await setToken() }
                    Button("Sign In with Email Instead", systemImage: "envelope") { step = .credentials }
                }
            }
            if !canAuth {
                Section { Text("You don't have permission to connect Bambu Cloud.").foregroundStyle(.secondary) }
            }
        }
        .disabled(runner.isRunning)
        .actionAlerts(runner)
        .alert("Bambu Cloud", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(info ?? "") }
    }

    private var regionPicker: some View {
        Picker("Region", selection: $region) {
            Text("Global").tag("global")
            Text("China").tag("china")
        }
    }

    private func submitButton(_ title: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Text(title).bold()
                if runner.isRunning { Spacer(); ProgressView() }
            }
        }
        .disabled(!enabled || !canAuth)
    }

    private func login() async {
        await runner.run {
            let r: ProfilesCloudLoginResponse = try await session.client.send(.post, "cloud/login",
                body: ProfilesCloudLoginRequest(email: email.trimmingCharacters(in: .whitespaces), password: password, region: region))
            captchaBlocked = r.reason == "captcha"
            if r.success {
                await onSignedIn()
            } else if captchaBlocked {
                return
            } else if r.needsVerification == true {
                verificationType = r.verificationType ?? "email"
                tfaKey = r.tfaKey
                code = ""
                step = .code
            } else {
                info = r.message ?? "Sign-in failed."
            }
        }
    }

    private func verify() async {
        await runner.run {
            let r: ProfilesCloudLoginResponse = try await session.client.send(.post, "cloud/verify",
                body: ProfilesCloudVerifyRequest(email: email.trimmingCharacters(in: .whitespaces), code: code, tfaKey: tfaKey, region: region))
            captchaBlocked = r.reason == "captcha"
            if r.success {
                await onSignedIn()
            } else if !captchaBlocked {
                info = r.message ?? "Verification failed."
            }
        }
    }

    private func setToken() async {
        await runner.run {
            let _: ProfilesCloudStatus = try await session.client.send(.post, "cloud/token",
                body: ProfilesCloudTokenRequest(accessToken: token.trimmingCharacters(in: .whitespacesAndNewlines), region: region))
            await onSignedIn()
        }
    }
}

// MARK: Preset list

private struct ProfilesCloudPresetList: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    let status: ProfilesCloudStatus
    let response: ProfilesSlicerSettingsResponse
    let lastSync: Date?
    let reload: () async -> Void
    let logout: () async -> Void

    @State private var index: ProfilesIndexedPresets<ProfilesSlicerSetting>
    @State private var filter = ProfilesPresetFilter()
    @State private var search = ""
    @State private var compareMode = false
    @State private var compareSelection: [ProfilesSlicerSetting] = []
    @State private var compareData: (left: [String: JSONValue], right: [String: JSONValue])?
    @State private var showCompare = false
    @State private var editorSeed: ProfilesEditorSeed?
    @State private var showTemplates = false
    @State private var confirmLogout = false
    @State private var deleteTarget: ProfilesSlicerSetting?
    @State private var runner = ActionRunner()

    init(status: ProfilesCloudStatus, response: ProfilesSlicerSettingsResponse, lastSync: Date?, reload: @escaping () async -> Void, logout: @escaping () async -> Void) {
        self.status = status
        self.response = response
        self.lastSync = lastSync
        self.reload = reload
        self.logout = logout
        _index = State(initialValue: ProfilesIndexedPresets(response.all))
    }

    private var canAuth: Bool { session.can("cloud:auth") }

    var body: some View {
        let grouped = index.filtered(filter, search: search)
        List {
            Section {
                HStack {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Connected as \(Text(status.email ?? "Bambu Cloud").bold())")
                    if let region = status.region {
                        StatusBadge(text: region == "china" ? "China" : "Global")
                    }
                    Spacer()
                }
                .font(.subheadline)
                if let lastSync {
                    Label("Synced \(lastSync.formatted(.relative(presentation: .named)))", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if compareMode {
                Section {
                    Text(compareSelection.isEmpty ? "Select two presets of the same type to compare."
                         : compareSelection.count == 1 ? "Select another \(compareSelection[0].kind.title.lowercased()) preset."
                         : "Ready to compare.")
                        .font(.subheadline)
                    ForEach(Array(compareSelection.enumerated()), id: \.element.settingId) { i, p in
                        Label(p.name, systemImage: "\(i + 1).circle.fill").font(.caption)
                    }
                    if compareSelection.count == 2 {
                        Button("Compare Now", systemImage: "arrow.left.arrow.right") { Task { await runCompare() } }
                    }
                }
            }
            if grouped.values.allSatisfy(\.isEmpty) {
                ContentUnavailableView {
                    Label("No Presets Found", systemImage: "square.stack.3d.up.slash")
                } description: {
                    Text(filter.isActive || !search.isEmpty ? "Try clearing the search or filters." : "Your Bambu Cloud account has no presets.")
                } actions: {
                    if filter.isActive { Button("Clear Filters") { filter = ProfilesPresetFilter(); search = "" } }
                }
            }
            ForEach([ProfilesPresetKind.filament, .process, .printer]) { kind in
                if let rows = grouped[kind], !rows.isEmpty {
                    Section {
                        ForEach(rows, id: \.preset.settingId) { row in
                            presetRow(row.preset, meta: row.meta)
                        }
                    } header: {
                        Label("\(kind.title) (\(rows.count))", systemImage: kind.systemImage)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search presets")
        .refreshable { await reload() }
        .onChange(of: response.all) { _, new in index = ProfilesIndexedPresets(new) }
        .navigationDestination(for: ProfilesSlicerSetting.self) { s in
            ProfilesCloudPresetDetail(setting: s, allPresets: response, onChanged: reload)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editorSeed = ProfilesEditorSeed(mode: .create, kind: .filament, name: "", baseId: "", setting: [:]) } label: {
                    Label("New Preset", systemImage: "plus")
                }
                .disabled(!canAuth)
            }
            ToolbarItem(placement: .primaryAction) {
                ProfilesFilterMenu(filter: $filter, index: index, printers: printers.printers)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(compareMode ? "Cancel Compare" : "Compare", systemImage: "arrow.left.arrow.right") {
                    compareMode.toggle()
                    compareSelection = []
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Templates", systemImage: "sparkles") { showTemplates = true }.disabled(!canAuth)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }.disabled(!canAuth)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLogout = true }
                    .disabled(!canAuth)
            }
        }
        .sheet(item: $editorSeed) { seed in
            ProfilesPresetEditor(seed: seed, allPresets: response) { await reload() }
        }
        .sheet(isPresented: $showTemplates) {
            ProfilesTemplatesSheet { template in
                showTemplates = false
                editorSeed = ProfilesEditorSeed(mode: .template, kind: ProfilesPresetKind(any: template.type) ?? .filament,
                                                name: "", baseId: "", setting: template.settings)
            }
        }
        .sheet(isPresented: $showCompare) {
            if let compareData, compareSelection.count == 2 {
                ProfilesDiffView(left: compareData.left, right: compareData.right,
                                 leftLabel: compareSelection[0].name, rightLabel: compareSelection[1].name)
            }
        }
        .confirm("Sign out of Bambu Cloud?", isPresented: $confirmLogout, action: "Sign Out") { Task { await logout() } }
        .confirm("Delete \(deleteTarget?.name ?? "preset")?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                 message: "The preset is removed from your Bambu Cloud account. This cannot be undone.") {
            if let target = deleteTarget { Task { await delete(target) } }
        }
        .actionAlerts(runner)
    }

    @ViewBuilder
    private func presetRow(_ preset: ProfilesSlicerSetting, meta: ProfilesPresetMeta.Info) -> some View {
        if compareMode {
            let idx = compareSelection.firstIndex(of: preset)
            let disabled = idx == nil && compareSelection.first.map { $0.kind != preset.kind } == true
            Button {
                toggleCompare(preset)
            } label: {
                ProfilesPresetRow(preset: preset, meta: meta, selectionIndex: idx, dimmed: disabled)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        } else {
            NavigationLink(value: preset) {
                ProfilesPresetRow(preset: preset, meta: meta)
            }
            .swipeActions(edge: .leading) {
                if canAuth {
                    Button("Duplicate", systemImage: "plus.square.on.square") { Task { await duplicate(preset) } }.tint(.indigo)
                }
            }
            .swipeActions(edge: .trailing) {
                if canAuth && preset.isUserPreset {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = preset }
                }
            }
            .contextMenu {
                if canAuth {
                    Button("Duplicate", systemImage: "plus.square.on.square") { Task { await duplicate(preset) } }
                    if preset.isUserPreset {
                        Button("Edit", systemImage: "pencil") { Task { await edit(preset) } }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = preset }
                    }
                }
                Button("Compare…", systemImage: "arrow.left.arrow.right") {
                    compareMode = true
                    compareSelection = [preset]
                }
            }
        }
    }

    private func toggleCompare(_ preset: ProfilesSlicerSetting) {
        if let i = compareSelection.firstIndex(of: preset) {
            compareSelection.remove(at: i)
        } else if compareSelection.isEmpty {
            compareSelection = [preset]
        } else if compareSelection[0].kind == preset.kind {
            compareSelection = [compareSelection[0], preset]
        }
    }

    private func runCompare() async {
        guard compareSelection.count == 2 else { return }
        let client = session.client
        let a = compareSelection[0].settingId, b = compareSelection[1].settingId
        await runner.run {
            async let l: ProfilesSlicerSettingDetail = client.get("cloud/settings/\(ProfilesAPI.escape(a))")
            async let r: ProfilesSlicerSettingDetail = client.get("cloud/settings/\(ProfilesAPI.escape(b))")
            let (left, right) = try await (l, r)
            compareData = (left.settingObject, right.settingObject)
            showCompare = true
        }
    }

    private func duplicate(_ preset: ProfilesSlicerSetting) async {
        await runner.run {
            let seed = try await ProfilesCloudSeeds.seed(for: preset, mode: .duplicate, client: session.client, all: response)
            editorSeed = seed
        }
    }

    private func edit(_ preset: ProfilesSlicerSetting) async {
        await runner.run {
            editorSeed = try await ProfilesCloudSeeds.seed(for: preset, mode: .edit, client: session.client, all: response)
        }
    }

    private func delete(_ preset: ProfilesSlicerSetting) async {
        await runner.run("Preset deleted") {
            try await session.client.call(.delete, "cloud/settings/\(ProfilesAPI.escape(preset.settingId))")
            await reload()
        }
    }
}

enum ProfilesCloudSeeds {
    /// Builds an editor seed from a fresh copy of the preset's detail.
    @MainActor
    static func seed(for preset: ProfilesSlicerSetting, mode: ProfilesEditorSeed.Mode, client: APIClient, all: ProfilesSlicerSettingsResponse) async throws -> ProfilesEditorSeed {
        let detail: ProfilesSlicerSettingDetail = try await client.get("cloud/settings/\(ProfilesAPI.escape(preset.settingId))")
        return seed(for: preset, detail: detail, mode: mode, all: all)
    }

    static func seed(for preset: ProfilesSlicerSetting, detail: ProfilesSlicerSettingDetail, mode: ProfilesEditorSeed.Mode, all: ProfilesSlicerSettingsResponse) -> ProfilesEditorSeed {
        var baseId = detail.baseId ?? ""
        if baseId.isEmpty {
            if !preset.isUserPreset {
                baseId = preset.settingId
            } else if let inherits = detail.settingObject["inherits"]?.stringValue,
                      let parent = all.presets(preset.kind).first(where: { $0.name == inherits && !$0.isUserPreset }) {
                baseId = parent.settingId
            }
        }
        return ProfilesEditorSeed(mode: mode, kind: preset.kind,
                                  name: mode == .edit ? preset.name : "\(preset.name) (Copy)",
                                  baseId: baseId, setting: detail.settingObject,
                                  editingId: mode == .edit ? preset.settingId : nil)
    }
}

// MARK: Detail

private struct ProfilesCloudPresetDetail: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let setting: ProfilesSlicerSetting
    let allPresets: ProfilesSlicerSettingsResponse
    let onChanged: () async -> Void

    @State private var detail = Loader<ProfilesSlicerSettingDetail>()
    @State private var runner = ActionRunner()
    @State private var editorSeed: ProfilesEditorSeed?
    @State private var confirmDelete = false

    private var canAuth: Bool { session.can("cloud:auth") }

    var body: some View {
        LoadingContent(loader: detail, retry: load) { d in
            let meta = ProfilesPresetMeta.extract(setting.name, inherits: d.settingObject["inherits"]?.stringValue)
            ProfilesSettingsBrowser(title: setting.name, settings: d.settingObject, header: AnyView(
                Section {
                    InfoRow("Type", setting.kind.title)
                    InfoRow("Owner", setting.isUserPreset ? "My preset (editable)" : "Built-in")
                    InfoRow("Setting ID", setting.settingId)
                    if let v = d.version ?? setting.version { InfoRow("Version", v) }
                    if let inherits = d.settingObject["inherits"]?.stringValue, !inherits.isEmpty { InfoRow("Inherits", inherits) }
                    if let fid = d.filamentId { InfoRow("Filament ID", fid) }
                    if let p = meta.printer { InfoRow("Printer", p) }
                    if let n = meta.nozzle { InfoRow("Nozzle", n) }
                    if let u = d.updateTime { InfoRow("Updated", Fmt.date(u)) }
                }
            ))
        }
        .navigationTitle(setting.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .toolbar {
            if canAuth {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Duplicate", systemImage: "plus.square.on.square") { makeSeed(.duplicate) }
                        if setting.isUserPreset {
                            Button("Edit", systemImage: "pencil") { makeSeed(.edit) }
                            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        }
                        if let d = detail.value {
                            ShareLink(item: ProfilesJSONFile(fileName: setting.name, value: .object([
                                "name": .string(setting.name), "type": .string(setting.kind.apiType),
                                "base_id": .string(d.baseId ?? ""), "setting": d.setting ?? .object([:]),
                            ])), preview: SharePreview("\(setting.name).json")) {
                                Label("Export JSON", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: { Label("Actions", systemImage: "ellipsis.circle") }
                    .disabled(detail.value == nil)
                }
            }
        }
        .sheet(item: $editorSeed) { seed in
            ProfilesPresetEditor(seed: seed, allPresets: allPresets) {
                await onChanged()
                await load()
            }
        }
        .confirm("Delete \(setting.name)?", isPresented: $confirmDelete, message: "The preset is removed from your Bambu Cloud account. This cannot be undone.") {
            Task {
                await runner.run {
                    try await session.client.call(.delete, "cloud/settings/\(ProfilesAPI.escape(setting.settingId))")
                    await onChanged()
                    dismiss()
                }
            }
        }
        .actionAlerts(runner)
    }

    private func load() async {
        await detail.load { try await session.client.get("cloud/settings/\(ProfilesAPI.escape(setting.settingId))") }
    }

    private func makeSeed(_ mode: ProfilesEditorSeed.Mode) {
        guard let d = detail.value else { return }
        editorSeed = ProfilesCloudSeeds.seed(for: setting, detail: d, mode: mode, all: allPresets)
    }
}
