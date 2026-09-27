import SwiftUI

/// Single sign-on (OpenID Connect) provider administration plus the local password sign-in switch.
struct SettingsOIDCProvidersView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store

    @State private var loader = Loader<[SettingsOIDCProviderRecord]>()
    @State private var groups: [GroupBrief] = []
    @State private var runner = ActionRunner()
    @State private var editing: SettingsOIDCEditTarget?
    @State private var pendingDelete: SettingsOIDCProviderRecord?
    @State private var iconReload = 0

    private var canEdit: Bool { session.can("settings:update") }

    var body: some View {
        List {
            localLoginSection
            providersSection
        }
        .navigationTitle("Single Sign-On")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .create } label: { Label("Add Provider", systemImage: "plus") }
                }
            }
            if runner.isRunning {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
        }
        .task { await load() }
        .refreshable { await load(); await store.load() }
        .actionAlerts(runner)
        .modifier(SettingsAuthSaveErrorAlert())
        .sheet(item: $editing) { target in
            SettingsOIDCProviderEditor(target: target, groups: groups) { await load() }
        }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "Provider")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { provider in
            Button("Delete", role: .destructive) { Task { await delete(provider) } }
        } message: { _ in
            Text("People who sign in only through this provider will lose access, and their links to it are removed.")
        }
    }

    // MARK: Sections

    private var localLoginSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.bool("local_login_enabled", default: true) },
                set: { newValue in Task { await store.save(["local_login_enabled": .bool(newValue)]) } }
            )) {
                SettingsLabel("Password Sign-In", help: "Allow signing in with a username and password.")
            }
            .disabled(!store.canEdit || !store.hasLoaded)
        } footer: {
            Text("Turn this off to allow only single sign-on. The server refuses if no provider is enabled or if your own account isn't linked to one. Setting BAMBUDDY_LOCAL_LOGIN=true on the server always re-enables password sign-in for recovery. LDAP sign-in is not affected.")
        }
        .task { if !store.hasLoaded && !store.isLoading { await store.load() } }
    }

    @ViewBuilder
    private var providersSection: some View {
        Section {
            if let providers = loader.value {
                if providers.isEmpty {
                    ContentUnavailableView {
                        Label("No Providers", systemImage: "globe")
                    } description: {
                        Text("Add an OpenID Connect provider such as Authentik, Keycloak, Google or Microsoft Entra ID to offer single sign-on.")
                    } actions: {
                        if canEdit { Button("Add Provider") { editing = .create }.buttonStyle(.bordered) }
                    }
                } else {
                    ForEach(providers) { provider in row(provider) }
                }
            } else if let error = loader.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Try Again") { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Providers")
        } footer: {
            if let first = loader.value?.first, let base = session.serverURL {
                Text("Register this redirect URL with each provider: \(base.appending(path: "api/v1/auth/oidc/callback").absoluteString)")
                    .textSelection(.enabled)
                    .id(first.id)
            }
        }
    }

    private func row(_ provider: SettingsOIDCProviderRecord) -> some View {
        let managed = provider.isEnvManaged == true
        return Button {
            editing = .edit(provider)
        } label: {
            HStack(spacing: 12) {
                SettingsOIDCProviderIcon(provider: provider, reload: iconReload)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(provider.name).font(.headline).foregroundStyle(.primary)
                        if provider.isEnabled != true { StatusBadge(text: "Off") }
                        if provider.isAutologin == true { StatusBadge(text: "Auto Sign-In", color: .blue) }
                        if managed { StatusBadge(text: "Environment", color: .orange) }
                    }
                    Text(provider.issuerUrl ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(summary(provider)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if canEdit && !managed {
                Button(role: .destructive) { pendingDelete = provider } label: { Label("Delete", systemImage: "trash") }
                Button { Task { await toggle(provider) } } label: {
                    Label(provider.isEnabled == true ? "Turn Off" : "Turn On", systemImage: provider.isEnabled == true ? "pause.circle" : "play.circle")
                }
                .tint(provider.isEnabled == true ? .gray : .green)
            }
        }
        .contextMenu {
            Button { editing = .edit(provider) } label: {
                Label(managed || !canEdit ? "View Details" : "Edit", systemImage: managed || !canEdit ? "info.circle" : "pencil")
            }
            if canEdit && !managed {
                Button { Task { await toggle(provider) } } label: {
                    Label(provider.isEnabled == true ? "Turn Off" : "Turn On", systemImage: provider.isEnabled == true ? "pause.circle" : "play.circle")
                }
                if !(provider.iconUrl ?? "").isEmpty {
                    Button { Task { await refreshIcon(provider) } } label: { Label("Refresh Icon", systemImage: "arrow.clockwise") }
                }
                if provider.hasIcon == true || !(provider.iconUrl ?? "").isEmpty {
                    Button { Task { await removeIcon(provider) } } label: { Label("Remove Icon", systemImage: "photo.badge.minus") }
                }
                Divider()
                Button(role: .destructive) { pendingDelete = provider } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func summary(_ p: SettingsOIDCProviderRecord) -> String {
        var parts: [String] = []
        if p.autoCreateUsers == true { parts.append("Creates accounts") }
        if p.autoLinkExistingAccounts == true { parts.append("Links by email") }
        if p.requireEmailVerified != false { parts.append("Verified email") }
        let group = p.defaultGroupId.flatMap { id in groups.first { $0.id == id }?.name } ?? "Viewers"
        parts.append("Group: \(group)")
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func load() async {
        let client = session.client
        await loader.load { try await client.get("auth/oidc/providers/all") }
        if let list: [GroupBrief] = try? await client.get("groups/") { groups = list }
    }

    private func toggle(_ provider: SettingsOIDCProviderRecord) async {
        let on = provider.isEnabled != true
        await runner.run(on ? "\(provider.name) turned on" : "\(provider.name) turned off") {
            let _: SettingsOIDCProviderRecord = try await session.client.send(.put, "auth/oidc/providers/\(provider.id)", body: JSONValue.object(["is_enabled": .bool(on)]))
        }
        await load()
    }

    private func refreshIcon(_ provider: SettingsOIDCProviderRecord) async {
        await runner.run("Icon refreshed") {
            let _: SettingsOIDCProviderRecord = try await session.client.send(.post, "auth/oidc/providers/\(provider.id)/icon/refresh")
        }
        await evictIcon(provider)
        await load()
    }

    private func removeIcon(_ provider: SettingsOIDCProviderRecord) async {
        await runner.run("Icon removed") {
            try await session.client.call(.delete, "auth/oidc/providers/\(provider.id)/icon")
        }
        await evictIcon(provider)
        await load()
    }

    private func evictIcon(_ provider: SettingsOIDCProviderRecord) async {
        await ImageLoader.shared.evict(session.client.url(SettingsOIDCProviderIcon.path(provider.id)))
        iconReload += 1
    }

    private func delete(_ provider: SettingsOIDCProviderRecord) async {
        await runner.run("\(provider.name) deleted") {
            try await session.client.call(.delete, "auth/oidc/providers/\(provider.id)")
        }
        await load()
    }
}

// MARK: - Icon

private struct SettingsOIDCProviderIcon: View {
    let provider: SettingsOIDCProviderRecord
    let reload: Int

    static func path(_ id: Int) -> String { "auth/oidc/providers/\(id)/icon" }

    var body: some View {
        Group {
            // The icon route only serves enabled providers.
            if provider.hasIcon == true && provider.isEnabled == true {
                RemoteImage(path: Self.path(provider.id), contentMode: .fit, reloadKey: reload) { fallback }
            } else {
                fallback
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(.rect(cornerRadius: 8))
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 8).fill(.fill.tertiary)
            .overlay { Image(systemName: "globe").foregroundStyle(.secondary) }
    }
}

// MARK: - Editor

enum SettingsOIDCEditTarget: Identifiable {
    case create
    case edit(SettingsOIDCProviderRecord)

    var id: String {
        switch self {
        case .create: "new"
        case .edit(let p): "provider-\(p.id)"
        }
    }
}

private struct SettingsOIDCProviderEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let target: SettingsOIDCEditTarget
    let groups: [GroupBrief]
    var onSaved: () async -> Void

    @State private var draft = SettingsOIDCProviderDraft()
    @State private var runner = ActionRunner()
    @State private var seeded = false

    private var original: SettingsOIDCProviderRecord? {
        if case .edit(let p) = target { return p }
        return nil
    }
    private var isEdit: Bool { original != nil }
    private var readOnly: Bool { original?.isEnvManaged == true || !session.can("settings:update") }

    var body: some View {
        NavigationStack {
            Form {
                if original?.isEnvManaged == true {
                    Section {
                        Label("This provider is configured through BAMBUDDY_OIDC_* environment variables on the server and can't be changed here.", systemImage: "lock.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Name", text: $draft.name)
                    labeled("Issuer URL") {
                        TextField("https://auth.example.com/application/o/bambuddy", text: $draft.issuerUrl)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    labeled("Client ID") {
                        TextField("Client ID", text: $draft.clientId).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    labeled("Client Secret") {
                        SecureField(isEdit ? "Unchanged" : "Client secret", text: $draft.clientSecret)
                    }
                    labeled("Scopes") {
                        TextField("openid email profile", text: $draft.scopes).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    Text("Provider")
                } footer: {
                    Text("The issuer must use HTTPS and publish /.well-known/openid-configuration. Scopes must include openid.\(isEdit ? " Leave the secret empty to keep the saved one." : "")")
                }

                Section {
                    Toggle("Enabled", isOn: $draft.isEnabled)
                    Toggle(isOn: $draft.isAutologin) {
                        SettingsLabel("Automatic Sign-In", help: "Send visitors straight to this provider instead of the sign-in page. Only one provider can do this.")
                    }
                } header: { Text("Sign-In") }

                Section {
                    Toggle(isOn: $draft.autoCreateUsers) {
                        SettingsLabel("Create Accounts", help: "Make a Bambuddy account the first time someone signs in.")
                    }
                    Toggle(isOn: $draft.autoLinkExistingAccounts) {
                        SettingsLabel("Link Existing Accounts", help: "Connect to an existing account with the same email address.")
                    }
                    Toggle(isOn: $draft.requireEmailVerified) {
                        SettingsLabel("Require Verified Email", help: "Ignore email addresses the provider hasn't verified.")
                    }
                    .disabled(draft.autoLinkExistingAccounts && trimmedClaim == "email")
                    labeled("Email Claim") {
                        TextField("email", text: $draft.emailClaim).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Picker("Default Group", selection: $draft.defaultGroupId) {
                        if original?.defaultGroupId == nil {
                            Text("Viewers (default)").tag(Int?.none)
                        }
                        ForEach(groups) { Text($0.name).tag(Int?.some($0.id)) }
                        if let id = draft.defaultGroupId, !groups.contains(where: { $0.id == id }) {
                            Text("Group #\(id)").tag(Int?.some(id))
                        }
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if draft.autoLinkExistingAccounts && trimmedClaim == "email" {
                            Text("Linking by the standard email claim always requires a verified email, so another person can't take over an account.")
                        } else if draft.autoLinkExistingAccounts {
                            Text("With a custom claim, make sure the provider controls its value — anyone who can set it can link to a matching account.")
                                .foregroundStyle(.orange)
                        } else if !draft.requireEmailVerified {
                            Text("Unverified email addresses will be accepted for new accounts.").foregroundStyle(.orange)
                        }
                        Text("New accounts join the default group.")
                    }
                }

                Section {
                    labeled("Icon URL") {
                        TextField("https://…", text: $draft.iconUrl)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Shown on the sign-in button. The server downloads and caches the image; it must be an HTTPS address on the public internet.")
                }
            }
            .disabled(readOnly || runner.isRunning)
            .navigationTitle(isEdit ? (readOnly ? draft.name : "Edit Provider") : "New Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(readOnly ? "Done" : "Cancel") { dismiss() }
                }
                if !readOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        if runner.isRunning {
                            ProgressView()
                        } else {
                            Button("Save") { Task { await save() } }.disabled(!draft.isValid(isEdit: isEdit))
                        }
                    }
                }
            }
            .onAppear {
                guard !seeded else { return }
                seeded = true
                if let original { draft = SettingsOIDCProviderDraft(original) }
            }
            .onChange(of: draft.autoLinkExistingAccounts) { _, on in
                if on && trimmedClaim == "email" { draft.requireEmailVerified = true }
            }
            .interactiveDismissDisabled(runner.isRunning)
            .actionAlerts(runner)
        }
    }

    private var trimmedClaim: String {
        let c = draft.emailClaim.trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? "email" : c
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
    }

    private func save() async {
        let client = session.client
        let draft = draft
        let original = original
        await runner.run {
            if let original {
                let _: SettingsOIDCProviderRecord = try await client.send(.put, "auth/oidc/providers/\(original.id)", body: draft.updateBody(original: original))
            } else {
                let _: SettingsOIDCProviderRecord = try await client.send(.post, "auth/oidc/providers", body: draft.createBody())
            }
        }
        guard runner.errorMessage == nil else { return }
        await onSaved()
        dismiss()
    }
}
