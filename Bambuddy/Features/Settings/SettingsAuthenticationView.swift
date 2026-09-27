import SwiftUI

/// Authentication administration: turning auth on/off, session policy, advanced (email-based)
/// authentication, LDAP / OIDC sign-in methods, and the at-rest encryption status.
struct SettingsAuthenticationView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store

    @State private var advanced = Loader<AdvancedAuthStatus>()
    @State private var ldap = Loader<SettingsLDAPStatus>()
    @State private var providers = Loader<[SettingsOIDCProviderRecord]>()
    @State private var encryption = Loader<SettingsAuthEncryptionStatus>()
    @State private var runner = ActionRunner()
    @State private var showEnableSheet = false
    @State private var confirmDisable = false
    @State private var confirmDisableAdvanced = false

    private var isAdmin: Bool { !session.isAuthEnabled || session.user?.isAdmin == true }

    var body: some View {
        Form {
            statusSection
            if session.isAuthEnabled { sessionPolicySection }
            advancedSection
            signInMethodsSection
            if session.can("settings:update") { securitySection }
        }
        .navigationTitle("Authentication")
        .toolbar {
            if runner.isRunning || store.isSaving {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
        }
        .task { await reload() }
        .refreshable { await reload(includeStore: true) }
        .actionAlerts(runner)
        .modifier(SettingsAuthSaveErrorAlert())
        .sheet(isPresented: $showEnableSheet) {
            SettingsAuthEnableSheet()
        }
        .confirm("Turn Off Authentication?", isPresented: $confirmDisable,
                 message: "Anyone who can reach this server will have full access without signing in. User accounts and groups are kept and apply again if you turn authentication back on.",
                 action: "Turn Off") {
            Task { await disableAuth() }
        }
        .confirm("Turn Off Advanced Authentication?", isPresented: $confirmDisableAdvanced,
                 message: "Email-based features such as password reset links and emailed passwords for new users will stop working.",
                 action: "Turn Off") {
            Task { await setAdvanced(false) }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: session.isAuthEnabled ? "lock.fill" : "lock.open.fill")
                    .font(.title2)
                    .foregroundStyle(session.isAuthEnabled ? .green : .secondary)
                    .frame(width: 44, height: 44)
                    .background((session.isAuthEnabled ? Color.green : Color.secondary).opacity(0.15), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.isAuthEnabled ? "Authentication Is On" : "Authentication Is Off").font(.headline)
                    Text(session.isAuthEnabled
                         ? "People must sign in, and what they can do is controlled by their groups."
                         : "Everyone who can reach this server has full access without signing in.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            if session.isAuthEnabled {
                if let user = session.user {
                    LabeledContent("Signed In As") {
                        HStack(spacing: 6) {
                            Text(user.username)
                            if user.isAdmin { StatusBadge(text: "Admin", color: .purple) }
                        }
                    }
                }
                if session.user?.isAdmin == true {
                    Button("Turn Off Authentication…", role: .destructive) { confirmDisable = true }
                }
            } else {
                Button("Turn On Authentication…") { showEnableSheet = true }
            }
        } footer: {
            if !session.isAuthEnabled {
                Text("Turning on authentication creates the first administrator account (or reuses an existing one) and signs you out of this app so you can sign in.")
            } else if session.user?.isAdmin != true {
                Text("Only administrators can turn authentication off.")
            }
        }
    }

    private var sessionPolicySection: some View {
        let hours = store.int("session_max_hours") ?? 24
        return Section {
            SettingsPicker("Session Length", key: "session_max_hours", options: [
                (.number(24), "24 hours"),
                (.number(168), "7 days"),
                (.number(720), "30 days"),
            ])
            SettingsNumberField("Custom Length", key: "session_max_hours", unit: "hours", range: 1...720)
        } header: {
            Text("Session Policy")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("How long a sign-in stays valid before people must sign in again (1–720 hours). Applies to new sign-ins only.")
                if hours > 24 {
                    Label("Longer sessions mean a lost or shared device stays signed in for longer.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .disabled(!store.hasLoaded)
    }

    @ViewBuilder
    private var advancedSection: some View {
        let status = advanced.value
        let enabled = status?.advancedAuthEnabled == true
        let smtpReady = status?.smtpConfigured == true
        Section {
            LabeledContent("Status") {
                if status == nil, advanced.error == nil {
                    ProgressView()
                } else {
                    StatusBadge(text: enabled ? "On" : "Off", color: enabled ? .green : .secondary)
                }
            }
            NavigationLink {
                SettingsEmailView()
            } label: {
                LabeledContent("Email (SMTP)") {
                    Text(status == nil ? "—" : (smtpReady ? "Configured" : "Not Configured"))
                        .foregroundStyle(smtpReady ? .green : .secondary)
                }
            }
            if isAdmin {
                if enabled {
                    Button("Turn Off Advanced Authentication…", role: .destructive) { confirmDisableAdvanced = true }
                        .disabled(runner.isRunning || !session.isAuthEnabled)
                } else {
                    Button("Turn On Advanced Authentication") { Task { await setAdvanced(true) } }
                        .disabled(runner.isRunning || !session.isAuthEnabled || !smtpReady)
                }
            }
            if let error = advanced.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Advanced Authentication")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Uses email to generate and send passwords for new users, lets people sign in with their email address, and enables self-service and admin password resets.")
                if !session.isAuthEnabled {
                    Text("Requires authentication to be turned on.")
                } else if !smtpReady && !enabled {
                    Text("Set up and test Email (SMTP) first.")
                }
            }
        }
    }

    @ViewBuilder
    private var signInMethodsSection: some View {
        Section {
            NavigationLink {
                SettingsLDAPView()
            } label: {
                LabeledContent {
                    ldapBadge
                } label: {
                    Label("LDAP / Active Directory", systemImage: "building.2")
                }
            }
            if isAdmin {
                NavigationLink {
                    SettingsOIDCProvidersView()
                } label: {
                    LabeledContent {
                        oidcBadge
                    } label: {
                        Label("Single Sign-On (OIDC)", systemImage: "globe")
                    }
                }
            }
            if let status = advanced.value, status.localLoginEnabled == false {
                Label("Username and password sign-in is turned off. Only single sign-on can be used.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Sign-In Methods")
        } footer: {
            Text("Local accounts always work alongside LDAP. Password sign-in can be turned off in Single Sign-On once a provider is set up.")
        }
    }

    @ViewBuilder
    private var ldapBadge: some View {
        if let status = ldap.value {
            if status.ldapEnabled == true {
                StatusBadge(text: "On", color: .green)
            } else if status.ldapConfigured == true {
                StatusBadge(text: "Configured", color: .orange)
            } else {
                StatusBadge(text: "Off")
            }
        }
    }

    @ViewBuilder
    private var oidcBadge: some View {
        if let list = providers.value {
            let active = list.filter { $0.isEnabled == true }.count
            if list.isEmpty {
                StatusBadge(text: "None")
            } else {
                StatusBadge(text: "\(active) of \(list.count) on", color: active > 0 ? .green : .secondary)
            }
        }
    }

    @ViewBuilder
    private var securitySection: some View {
        Section {
            if let status = encryption.value {
                SettingsAuthEncryptionSummary(status: status)
            } else if let error = encryption.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Try Again") { Task { await loadEncryption() } }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Secret Encryption")
        } footer: {
            Text("OIDC client secrets and two-factor seeds are encrypted at rest with a server key. Full backups include this key.")
        }
    }

    // MARK: Loading

    private func reload(includeStore: Bool = false) async {
        let client = session.client
        if includeStore || (!store.hasLoaded && !store.isLoading) { await store.load() }
        await advanced.load { try await client.get("auth/advanced-auth/status") }
        await ldap.load { try await client.get("auth/ldap/status") }
        await loadProviders()
        await loadEncryption()
    }

    private func loadProviders() async {
        guard isAdmin, session.can("settings:read") else { return }
        let client = session.client
        await providers.load { try await client.get("auth/oidc/providers/all") }
    }

    private func loadEncryption() async {
        guard session.can("settings:update") else { return }
        let client = session.client
        await encryption.load { try await client.get("auth/encryption-status") }
    }

    // MARK: Actions

    private func disableAuth() async {
        await runner.run {
            try await session.client.call(.post, "auth/disable")
        }
        if runner.errorMessage == nil { await session.connect() }
    }

    private func setAdvanced(_ enable: Bool) async {
        await runner.run(enable ? "Advanced authentication turned on" : "Advanced authentication turned off") {
            let _: SettingsAuthMessageResponse = try await session.client.send(.post, enable ? "auth/advanced-auth/enable" : "auth/advanced-auth/disable")
        }
        let client = session.client
        await advanced.load { try await client.get("auth/advanced-auth/status") }
    }
}

// MARK: - Encryption summary

private struct SettingsAuthEncryptionSummary: View {
    let status: SettingsAuthEncryptionStatus

    var body: some View {
        let (title, detail, symbol, color) = describe()
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .padding(.vertical, 2)
        if status.keySource == "generated", status.legacyTotal > 0 {
            Label("\(status.legacyTotal) stored secret(s) are still unencrypted and will be encrypted on the next restart.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
        }
        if let errors = status.migrationErrorCount, errors > 0 {
            Label("\(errors) secret(s) could not be encrypted during the last migration. Check the server logs.", systemImage: "exclamationmark.octagon.fill")
                .font(.footnote).foregroundStyle(.red)
        }
        LabeledContent("Key Source", value: keySourceText)
        LabeledContent("Encrypted") {
            Text("OIDC \(status.encryptedRows?.oidcProviders ?? 0) · TOTP \(status.encryptedRows?.userTotp ?? 0)").monospacedDigit()
        }
        LabeledContent("Unencrypted") {
            Text("OIDC \(status.legacyPlaintextRows?.oidcProviders ?? 0) · TOTP \(status.legacyPlaintextRows?.userTotp ?? 0)").monospacedDigit()
        }
    }

    private var keySourceText: String {
        switch status.keySource {
        case "env": "Environment variable"
        case "file": "Key file"
        case "generated": "Generated automatically"
        case "none", nil: "None"
        case let other?: other
        }
    }

    private func describe() -> (String, String, String, Color) {
        switch status.severity {
        case .critical:
            return ("Secrets Can't Be Decrypted",
                    "\(status.encryptedTotal) encrypted secret(s) can't be read with the current key. Restore the original key file or MFA_ENCRYPTION_KEY value.",
                    "xmark.shield.fill", .red)
        case .warning where status.keySource == "generated":
            return ("Encryption On — Back Up Your Key",
                    "The key was generated automatically. Keep a copy of the key file (or set MFA_ENCRYPTION_KEY) so secrets survive a reinstall.",
                    "exclamationmark.shield.fill", .orange)
        case .warning:
            return ("Encryption On",
                    "\(status.legacyTotal) stored secret(s) are still unencrypted and will be encrypted on the next restart.",
                    "exclamationmark.shield.fill", .orange)
        case .good:
            return ("Encryption On", "All stored secrets are encrypted.", "checkmark.shield.fill", .green)
        case .inactive:
            return ("Encryption Not Configured", "No encryption key is set and no secrets are stored yet.", "shield.slash", .secondary)
        }
    }
}

// MARK: - Turn on authentication

private struct SettingsAuthEnableSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var runner = ActionRunner()

    private var validationMessage: String? {
        if username.isEmpty && password.isEmpty && confirmation.isEmpty { return nil }
        if username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty { return "Enter both a username and a password." }
        if password != confirmation { return "The passwords don't match." }
        if password.count < 8 { return "Use at least 8 characters." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.newPassword)
                    SecureField("Confirm Password", text: $confirmation).textContentType(.newPassword)
                } header: {
                    Text("Administrator Account")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The password needs at least 8 characters with upper- and lowercase letters, a digit and a symbol.")
                        Text("If an administrator account already exists, you can leave these fields empty and sign in with it afterwards.")
                    }
                }
                if let validationMessage {
                    Section { Label(validationMessage, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Turn On Authentication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else {
                        Button("Turn On") { Task { await submit() } }.disabled(validationMessage != nil)
                    }
                }
            }
            .interactiveDismissDisabled(runner.isRunning)
            .actionAlerts(runner)
        }
    }

    private func submit() async {
        let name = username.trimmingCharacters(in: .whitespaces)
        let body = SettingsAuthSetupRequest(authEnabled: true,
                                            adminUsername: name.isEmpty ? nil : name,
                                            adminPassword: password.isEmpty ? nil : password)
        await runner.run {
            let _: SettingsAuthSetupResponse = try await session.client.send(.post, "auth/setup", body: body)
        }
        guard runner.errorMessage == nil else { return }
        dismiss()
        await session.connect()
    }
}

// MARK: - Shared helpers for the authentication pages

/// Presents `ServerSettingsStore.saveError` for pages that don't use `SettingsForm`.
struct SettingsAuthSaveErrorAlert: ViewModifier {
    @Environment(ServerSettingsStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        content
            .alert("Couldn't Save", isPresented: Binding(get: { store.saveError != nil }, set: { if !$0 { store.saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.saveError ?? "") }
            .onDisappear { Task { await store.flush() } }
    }
}
