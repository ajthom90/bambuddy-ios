import SwiftUI

// MARK: - Orca Cloud tab

struct ProfilesOrcaTab: View {
    @Environment(AppSession.self) private var session
    @State private var status = Loader<ProfilesOrcaStatus>()
    @State private var profiles = Loader<ProfilesOrcaProfileList>()
    @State private var runner = ActionRunner()
    @State private var lastSync: Date?
    @State private var confirmLogout = false

    private var canManage: Bool { session.can("orca_cloud:auth") }

    var body: some View {
        LoadingContent(loader: status, retry: loadStatus) { st in
            if st.connected {
                LoadingContent(loader: profiles, retry: loadProfiles) { list in
                    ProfilesOrcaList(status: st, list: list, lastSync: lastSync, reload: loadProfiles)
                }
                .task { if profiles.value == nil { await loadProfiles() } }
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLogout = true }
                            .disabled(!canManage)
                    }
                }
            } else {
                ProfilesOrcaConnectView(canManage: canManage) {
                    profiles.value = nil
                    await loadStatus()
                }
            }
        }
        .task { await loadStatus() }
        .confirm("Disconnect Orca Cloud?", isPresented: $confirmLogout, action: "Disconnect") {
            Task {
                await runner.run("Orca Cloud disconnected") {
                    try await session.client.call(.post, "orca-cloud/logout")
                    profiles.value = nil
                    await loadStatus()
                }
            }
        }
        .actionAlerts(runner)
    }

    private func loadStatus() async {
        await status.load { try await session.client.get("orca-cloud/status") }
    }

    private func loadProfiles() async {
        await profiles.load { try await session.client.get("orca-cloud/profiles") }
        if profiles.error == nil { lastSync = Date() }
    }
}

/// Device-code pairing: the server requests a code, the user approves it on
/// Orca's site, and the app polls until the pairing completes.
private struct ProfilesOrcaConnectView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    let canManage: Bool
    let onConnected: () async -> Void

    @State private var pairing: ProfilesOrcaDeviceStart?
    @State private var error: String?
    @State private var starting = false

    var body: some View {
        Form {
            if let pairing {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "link.icloud.fill").font(.system(size: 36)).foregroundStyle(.tint)
                        Text("Approve This Device").font(.title3.bold())
                        Text("Open the link below, sign in to Orca Cloud and approve the request using this code.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text(pairing.userCode)
                            .font(.largeTitle.monospaced().bold())
                            .tracking(6)
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                        Button("Copy Code", systemImage: "doc.on.doc") { UIPasteboard.general.string = pairing.userCode }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                }
                Section {
                    Button("Open Orca Cloud", systemImage: "safari") {
                        if let url = URL(string: pairing.verificationUriComplete ?? pairing.verificationUri) { openURL(url) }
                    }
                    LabeledContent("Or visit", value: pairing.verificationUri).font(.caption)
                    HStack {
                        ProgressView()
                        Text("Waiting for approval…").foregroundStyle(.secondary)
                    }
                    Button("Cancel", role: .cancel) { self.pairing = nil }
                }
                .task(id: pairing.userCode) { await poll(pairing) }
            } else {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "cloud.fill").font(.system(size: 36)).foregroundStyle(.tint)
                        Text("Connect Orca Cloud").font(.title3.bold())
                        Text("Link your Orca Cloud account to browse the slicer profiles you sync from OrcaSlicer.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    Button {
                        Task { await start() }
                    } label: {
                        HStack {
                            Label("Connect", systemImage: "checkmark.circle")
                            if starting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(starting || !canManage)
                } footer: {
                    if !canManage { Text("You don't have permission to connect Orca Cloud.") }
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            }
        }
    }

    private func start() async {
        starting = true
        defer { starting = false }
        do {
            pairing = try await session.client.send(.post, "orca-cloud/device/start")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func poll(_ p: ProfilesOrcaDeviceStart) async {
        var interval = max(1, p.interval ?? 5)
        let deadline = Date().addingTimeInterval(TimeInterval(p.expiresIn ?? 900))
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, pairing?.userCode == p.userCode else { return }
            do {
                let r: ProfilesOrcaPoll = try await session.client.send(.post, "orca-cloud/device/poll")
                switch r.status {
                case "authorization_pending": continue
                case "slow_down": interval += 5
                case "complete":
                    pairing = nil
                    await onConnected()
                    return
                case "access_denied":
                    error = "The request was denied in Orca Cloud."
                    pairing = nil
                    return
                case "expired_token":
                    error = "The code expired before it was approved. Try again."
                    pairing = nil
                    return
                default: continue
                }
            } catch {
                self.error = "Couldn't check the pairing status: \(error.localizedDescription)"
                pairing = nil
                return
            }
        }
        if pairing?.userCode == p.userCode {
            error = "The code expired before it was approved. Try again."
            pairing = nil
        }
    }
}

private struct ProfilesOrcaList: View {
    @Environment(PrinterStore.self) private var printers
    let status: ProfilesOrcaStatus
    let list: ProfilesOrcaProfileList
    let lastSync: Date?
    let reload: () async -> Void

    @State private var index: ProfilesIndexedPresets<ProfilesOrcaProfileMeta>
    @State private var filter = ProfilesPresetFilter()
    @State private var search = ""

    init(status: ProfilesOrcaStatus, list: ProfilesOrcaProfileList, lastSync: Date?, reload: @escaping () async -> Void) {
        self.status = status
        self.list = list
        self.lastSync = lastSync
        self.reload = reload
        _index = State(initialValue: ProfilesIndexedPresets(list.all))
    }

    var body: some View {
        let grouped = index.filtered(filter, search: search)
        List {
            Section {
                HStack {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    if let email = status.email {
                        Text("Connected as \(Text(email).bold())")
                    } else {
                        Text("Connected to Orca Cloud")
                    }
                }
                .font(.subheadline)
                if let lastSync {
                    Label("Synced \(lastSync.formatted(.relative(presentation: .named)))", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if grouped.values.allSatisfy(\.isEmpty) {
                ContentUnavailableView {
                    Label("No Profiles Found", systemImage: "square.stack.3d.up.slash")
                } description: {
                    Text(filter.isActive || !search.isEmpty ? "Try clearing the search or filters." : "No profiles are synced to this Orca Cloud account.")
                } actions: {
                    if filter.isActive { Button("Clear Filters") { filter = ProfilesPresetFilter(); search = "" } }
                }
            }
            ForEach([ProfilesPresetKind.filament, .process, .printer]) { kind in
                if let rows = grouped[kind], !rows.isEmpty {
                    Section {
                        ForEach(rows, id: \.preset.settingId) { row in
                            NavigationLink(value: row.preset) {
                                ProfilesPresetRow(preset: row.preset, meta: row.meta, showOwnership: false)
                            }
                        }
                    } header: {
                        Label("\(kind.title) (\(rows.count))", systemImage: kind.systemImage)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search profiles")
        .refreshable { await reload() }
        .onChange(of: list.all) { _, new in index = ProfilesIndexedPresets(new) }
        .navigationDestination(for: ProfilesOrcaProfileMeta.self) { ProfilesOrcaDetail(meta: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ProfilesFilterMenu(filter: $filter, index: index, printers: printers.printers, showOwner: false)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
            }
        }
    }
}

private struct ProfilesOrcaDetail: View {
    @Environment(AppSession.self) private var session
    let meta: ProfilesOrcaProfileMeta
    @State private var detail = Loader<ProfilesOrcaProfileDetail>()

    var body: some View {
        LoadingContent(loader: detail, retry: load) { d in
            let settings = d.setting?.objectValue ?? [:]
            ProfilesSettingsBrowser(title: meta.name, settings: settings, header: AnyView(
                Section {
                    InfoRow("Type", meta.kind.title)
                    InfoRow("Setting ID", d.settingId)
                    if let v = d.version ?? meta.version { InfoRow("Version", v) }
                    if let b = d.baseId, !b.isEmpty { InfoRow("Base", b) }
                    if let inherits = settings["inherits"]?.stringValue, !inherits.isEmpty { InfoRow("Inherits", inherits) }
                    if let u = d.updateTime ?? meta.updatedTime { InfoRow("Updated", Fmt.date(u)) }
                }
            ))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: ProfilesJSONFile(fileName: meta.name, value: d.setting ?? .object([:])),
                              preview: SharePreview("\(meta.name).json")) {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle(meta.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        await detail.load { try await session.client.get("orca-cloud/profiles/\(ProfilesAPI.escape(meta.settingId))") }
    }
}
