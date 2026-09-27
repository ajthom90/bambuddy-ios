import SwiftUI

/// Outgoing email (SMTP) server used for advanced authentication, password resets and
/// user email notifications. Stored separately from the settings blob (`/auth/smtp`).
struct SettingsEmailView: View {
    @Environment(AppSession.self) private var session

    @State private var loaded = false
    @State private var loadError: String?
    @State private var isConfigured = false
    @State private var draft = SettingsEmailDraft()
    @State private var baseline = SettingsEmailDraft()
    @State private var runner = ActionRunner()
    @State private var testRecipient = ""
    @State private var testResult: SettingsAuthMessageResponse?
    @State private var isTesting = false

    private var canEdit: Bool { session.can("settings:update") }
    private var isDirty: Bool { draft != baseline }

    var body: some View {
        Group {
            if loaded {
                form
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Email Settings", systemImage: "exclamationmark.triangle")
                } description: { Text(loadError) } actions: {
                    Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Email (SMTP)")
        .toolbar {
            if canEdit && loaded {
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }.disabled(!isDirty || draft.validationMessage != nil)
                    }
                }
            }
        }
        .task { if !loaded { await load() } }
        .actionAlerts(runner)
    }

    private var form: some View {
        Form {
            Section {
                labeled("SMTP Server") {
                    TextField("smtp.example.com", text: $draft.host)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Picker("Security", selection: $draft.security) {
                    Text("STARTTLS").tag("starttls")
                    Text("SSL/TLS").tag("ssl")
                    Text("None").tag("none")
                }
                .onChange(of: draft.security) { _, security in
                    // Follow the conventional port unless a custom one was entered.
                    if SettingsSMTPConfig.security(forPort: Int(draft.port) ?? 0) != nil || draft.port.isEmpty {
                        draft.port = String(SettingsSMTPConfig.defaultPort(for: security))
                    }
                }
                LabeledContent("Port") {
                    TextField("587", text: $draft.port)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                        .onChange(of: draft.port) { _, port in
                            if let p = Int(port), let match = SettingsSMTPConfig.security(forPort: p), match != draft.security {
                                draft.security = match
                            }
                        }
                }
            } header: {
                Text("Server")
            } footer: {
                Text("STARTTLS usually uses port 587, SSL/TLS port 465 and unencrypted connections port 25.")
            }
            .disabled(!canEdit)

            Section {
                Toggle("Requires Sign-In", isOn: $draft.authEnabled)
                if draft.authEnabled {
                    labeled("Username") {
                        TextField("Username", text: $draft.username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    labeled("Password") {
                        SecureField(isConfigured ? "Unchanged" : "Password", text: $draft.password)
                            .textContentType(.password)
                    }
                }
            } header: {
                Text("Authentication")
            } footer: {
                if draft.authEnabled && isConfigured {
                    Text("The saved password is never shown. Leave it empty to keep it.")
                }
            }
            .disabled(!canEdit)

            Section {
                labeled("From Address") {
                    TextField("bambuddy@example.com", text: $draft.fromEmail)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                labeled("From Name") {
                    TextField("BamBuddy", text: $draft.fromName)
                }
            } header: {
                Text("Sender")
            }
            .disabled(!canEdit)

            if isDirty, let message = draft.validationMessage {
                Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.footnote) }
            }

            if canEdit {
                Section {
                    TextField("Recipient address", text: $testRecipient)
                        .keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        Task { await sendTest() }
                    } label: {
                        HStack {
                            Text(isDirty ? "Save and Send Test Email" : "Send Test Email")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isTesting || !testRecipient.contains("@") || (isDirty && draft.validationMessage != nil) || (!isConfigured && !isDirty))
                    if let testResult {
                        SettingsTestResultLabel(success: testResult.success == true, message: testResult.message ?? "")
                    }
                } header: {
                    Text("Test")
                } footer: {
                    Text("Sends a message using the saved settings.")
                }
            }

            Section {
                Text("Advanced authentication, password reset emails and per-user notifications use this server. Turn on advanced authentication under Authentication once a test email arrives.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .refreshable { await load() }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            let config: SettingsSMTPConfig? = try await session.client.get("auth/smtp")
            let fresh = config.map(SettingsEmailDraft.init) ?? SettingsEmailDraft()
            isConfigured = config != nil
            if !isDirty || !loaded { draft = fresh }
            baseline = fresh
            loadError = nil
            loaded = true
        } catch is CancellationError {
        } catch {
            if !loaded { loadError = error.localizedDescription } else { runner.errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    private func save() async -> Bool {
        let body = draft.config
        await runner.run("Email settings saved") {
            let _: SettingsAuthMessageResponse = try await session.client.send(.post, "auth/smtp", body: body)
        }
        guard runner.errorMessage == nil else { return false }
        draft.password = ""
        baseline = draft
        isConfigured = true
        return true
    }

    private func sendTest() async {
        if isDirty {
            guard await save() else { return }
        }
        isTesting = true
        defer { isTesting = false }
        testResult = nil
        let request = SettingsSMTPTestRequest(testRecipient: testRecipient.trimmingCharacters(in: .whitespaces))
        do {
            testResult = try await session.client.send(.post, "auth/smtp/test", body: request)
        } catch {
            testResult = SettingsAuthMessageResponse(success: false, message: error.localizedDescription)
        }
    }
}

/// Local edit state for the SMTP form.
struct SettingsEmailDraft: Equatable {
    var host = ""
    var port = "587"
    var security = "starttls"
    var authEnabled = true
    var username = ""
    var password = ""
    var fromEmail = ""
    var fromName = "BamBuddy"

    init() {}

    init(_ config: SettingsSMTPConfig) {
        host = config.smtpHost ?? ""
        port = config.smtpPort.map(String.init) ?? "587"
        security = config.smtpSecurity ?? (config.smtpUseTls == false ? "ssl" : "starttls")
        authEnabled = config.smtpAuthEnabled ?? true
        username = config.smtpUsername ?? ""
        fromEmail = config.smtpFromEmail ?? ""
        fromName = config.smtpFromName ?? "BamBuddy"
    }

    var validationMessage: String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the SMTP server." }
        guard let p = Int(port), (1...65535).contains(p) else { return "Enter a port between 1 and 65535." }
        if !fromEmail.contains("@") { return "Enter the address emails are sent from." }
        if authEnabled && username.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the SMTP username." }
        return nil
    }

    /// Request body for `POST /auth/smtp`. An empty password keeps the stored one.
    var config: SettingsSMTPConfig {
        SettingsSMTPConfig(
            smtpHost: host.trimmingCharacters(in: .whitespaces),
            smtpPort: Int(port) ?? SettingsSMTPConfig.defaultPort(for: security),
            smtpUsername: authEnabled ? username.trimmingCharacters(in: .whitespaces) : "",
            smtpPassword: authEnabled && !password.isEmpty ? password : nil,
            smtpSecurity: security,
            smtpAuthEnabled: authEnabled,
            smtpFromEmail: fromEmail.trimmingCharacters(in: .whitespaces),
            smtpFromName: fromName.trimmingCharacters(in: .whitespaces).isEmpty ? "BamBuddy" : fromName.trimmingCharacters(in: .whitespaces),
            smtpUseTls: nil
        )
    }
}
