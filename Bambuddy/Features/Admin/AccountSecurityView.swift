import SwiftUI

/// The signed-in user's security: password, two-factor authentication,
/// linked single-sign-on accounts and personal camera tokens.
/// Pushed from Settings (no NavigationStack of its own).
struct AccountSecurityView: View {
    @Environment(AppSession.self) private var session

    @State private var status = Loader<AdminTwoFAStatus>()
    @State private var links: [AdminOIDCLink] = []
    @State private var runner = ActionRunner()

    @State private var showPassword = false
    @State private var showTOTPSetup = false
    @State private var replacementCode: String?
    @State private var codePrompt: AdminCodePrompt?
    @State private var promptText = ""
    @State private var backupCodes: [String]?
    @State private var emailSetupToken: String?
    @State private var unlinkTarget: AdminOIDCLink?

    var body: some View {
        Group {
            if !session.isAuthEnabled {
                AdminAuthDisabledView(feature: "Account security")
            } else {
                form
            }
        }
        .navigationTitle("Account Security")
    }

    private var user: User? { session.user }
    private var usesLocalPassword: Bool { (user?.authSource ?? "local") == "local" }

    private var form: some View {
        Form {
            Section {
                if let user {
                    LabeledContent("Username", value: user.username)
                    LabeledContent("Email", value: (user.email ?? "").isEmpty ? "Not set" : user.email!)
                    if let source = user.authSource, source != "local" {
                        LabeledContent("Signs In With", value: source.uppercased())
                    }
                    if let groups = user.groups, !groups.isEmpty {
                        LabeledContent("Groups", value: groups.map(\.name).joined(separator: ", "))
                    }
                }
                if usesLocalPassword {
                    Button { showPassword = true } label: { Label("Change Password", systemImage: "key") }
                }
            } header: {
                Text("Account")
            } footer: {
                if !usesLocalPassword { Text("Your password is managed by your directory or sign-in provider.") }
            }

            LoadingContent(loader: status, retry: load) { s in
                totpSection(s)
                emailSection(s)
            }

            if !links.isEmpty {
                Section {
                    ForEach(links) { link in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.providerName)
                                if let e = link.providerEmail { Text(e).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Unlink", role: .destructive) { unlinkTarget = link }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Linked Accounts")
                } footer: {
                    Text("Single sign-on providers you can use to sign in to this account.")
                }
            }

            Section {
                NavigationLink {
                    AdminPersonalTokensView()
                } label: {
                    Label("Camera & Display Tokens", systemImage: "video.badge.checkmark")
                }
            } footer: {
                Text("Long-lived tokens for Home Assistant, kiosk displays and stream overlays.")
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .actionAlerts(runner)
        .sheet(isPresented: $showPassword) { AdminChangePasswordSheet() }
        .sheet(isPresented: $showTOTPSetup) {
            AdminTOTPSetupSheet(replacing: status.value?.totpEnabled == true, currentCode: replacementCode) { codes in
                backupCodes = codes
                Task { await load() }
            }
        }
        .sheet(item: Binding(get: { backupCodes.map { AdminBackupCodeList(codes: $0) } }, set: { if $0 == nil { backupCodes = nil } })) { list in
            AdminBackupCodesSheet(codes: list.codes)
        }
        .alert(codePrompt?.title ?? "", isPresented: Binding(get: { codePrompt != nil }, set: { if !$0 { codePrompt = nil; promptText = "" } })) {
            if codePrompt?.isPassword == true {
                SecureField("Password", text: $promptText)
            } else {
                TextField("Code", text: $promptText).keyboardType(.numberPad).textContentType(.oneTimeCode)
            }
            Button("Cancel", role: .cancel) {}
            Button(codePrompt?.action ?? "OK", role: codePrompt?.destructive == true ? .destructive : nil) {
                if let p = codePrompt { let text = promptText; Task { await submit(p, text) } }
            }
        } message: {
            Text(codePrompt?.message ?? "")
        }
        .confirm("Unlink \(unlinkTarget?.providerName ?? "account")?", isPresented: Binding(get: { unlinkTarget != nil }, set: { if !$0 { unlinkTarget = nil } }),
                 message: "You won't be able to sign in with this provider until you link it again.", action: "Unlink") {
            if let l = unlinkTarget { Task { await unlink(l) } }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func totpSection(_ s: AdminTwoFAStatus) -> some View {
        Section {
            HStack {
                Label("Authenticator App", systemImage: "iphone.badge.checkmark")
                Spacer()
                StatusBadge(text: s.totpEnabled ? "On" : "Off", color: s.totpEnabled ? .green : .secondary)
            }
            if s.totpEnabled {
                LabeledContent("Backup Codes Left", value: "\(s.backupCodesRemaining)")
                    .foregroundStyle(s.backupCodesRemaining <= 2 ? .orange : .primary)
                Button { codePrompt = .regenerate } label: { Label("New Backup Codes", systemImage: "arrow.clockwise") }
                Button { codePrompt = .replaceAuthenticator } label: { Label("Move to a New Authenticator", systemImage: "arrow.left.arrow.right") }
                Button(role: .destructive) { codePrompt = .disableTOTP } label: { Label("Turn Off", systemImage: "xmark.shield") }
            } else {
                Button { replacementCode = nil; showTOTPSetup = true } label: { Label("Set Up Authenticator App", systemImage: "plus.circle") }
            }
        } header: {
            Text("Two-Factor Authentication")
        } footer: {
            Text("Require a code from an authenticator app (such as Passwords, 1Password or Google Authenticator) when signing in.")
        }
    }

    @ViewBuilder
    private func emailSection(_ s: AdminTwoFAStatus) -> some View {
        Section {
            HStack {
                Label("Email Codes", systemImage: "envelope.badge.shield.half.filled")
                Spacer()
                StatusBadge(text: s.emailOtpEnabled ? "On" : "Off", color: s.emailOtpEnabled ? .green : .secondary)
            }
            if (user?.email ?? "").isEmpty {
                Text("Add an email address to your account to use email codes.").font(.footnote).foregroundStyle(.secondary)
            } else if s.emailOtpEnabled {
                Button(role: .destructive) { codePrompt = .disableEmail } label: { Label("Turn Off", systemImage: "xmark.shield") }
            } else if emailSetupToken != nil {
                Button { codePrompt = .confirmEmail } label: { Label("Enter Verification Code", systemImage: "number") }
                Button("Cancel Setup", role: .cancel) { emailSetupToken = nil }
            } else {
                Button { Task { await startEmailSetup() } } label: { Label("Turn On", systemImage: "plus.circle") }
            }
        } footer: {
            if let email = user?.email, !email.isEmpty {
                Text("A one-time code is emailed to \(email) when you sign in.")
            }
        }
    }

    // MARK: Actions

    private func load() async {
        guard session.isAuthEnabled else { return }
        let client = session.client
        await status.load { try await client.get("auth/2fa/status") }
        links = (try? await client.get("auth/oidc/links")) ?? []
    }

    private func submit(_ prompt: AdminCodePrompt, _ text: String) async {
        let value = text.trimmingCharacters(in: .whitespaces)
        struct Code: Encodable { var code: String }
        struct Password: Encodable { var password: String }
        struct Confirm: Encodable { var setupToken: String; var code: String }
        switch prompt {
        case .disableTOTP:
            await runner.run("Authenticator app turned off") {
                try await session.client.call(.post, "auth/2fa/totp/disable", body: Code(code: value))
                await load()
            }
        case .regenerate:
            await runner.run {
                let r: AdminBackupCodes = try await session.client.send(.post, "auth/2fa/totp/regenerate-backup-codes", body: Code(code: value))
                backupCodes = r.backupCodes
                await load()
            }
        case .replaceAuthenticator:
            // The setup call needs a current code to replace an active authenticator.
            replacementCode = value
            showTOTPSetup = true
        case .disableEmail:
            await runner.run("Email codes turned off") {
                try await session.client.call(.post, "auth/2fa/email/disable", body: Password(password: value))
                await load()
            }
        case .confirmEmail:
            guard let token = emailSetupToken else { return }
            await runner.run("Email codes turned on") {
                try await session.client.call(.post, "auth/2fa/email/enable/confirm", body: Confirm(setupToken: token, code: value))
                emailSetupToken = nil
                await load()
            }
        }
    }

    private func startEmailSetup() async {
        await runner.run {
            let r: AdminEmailOTPSetup = try await session.client.send(.post, "auth/2fa/email/enable")
            emailSetupToken = r.setupToken
            runner.successMessage = r.message ?? "Verification code sent"
            if r.setupToken != nil { codePrompt = .confirmEmail }
        }
    }

    private func unlink(_ link: AdminOIDCLink) async {
        await runner.run("Account unlinked") {
            try await session.client.call(.delete, "auth/oidc/links/\(link.providerId)")
            await load()
        }
    }
}

fileprivate enum AdminCodePrompt: Identifiable {
    case disableTOTP, regenerate, replaceAuthenticator, disableEmail, confirmEmail
    var id: Self { self }

    var title: String {
        switch self {
        case .disableTOTP: "Turn Off Authenticator App"
        case .regenerate: "New Backup Codes"
        case .replaceAuthenticator: "Move to a New Authenticator"
        case .disableEmail: "Turn Off Email Codes"
        case .confirmEmail: "Verify Email"
        }
    }

    var message: String {
        switch self {
        case .disableTOTP: "Enter a code from your authenticator app or a backup code."
        case .regenerate: "Enter a code from your authenticator app or a backup code. Your old backup codes stop working."
        case .replaceAuthenticator: "Enter a current code from your existing authenticator app."
        case .disableEmail: "Enter your password to confirm."
        case .confirmEmail: "Enter the code we emailed you."
        }
    }

    var action: String {
        switch self {
        case .disableTOTP, .disableEmail: "Turn Off"
        case .regenerate: "Generate"
        case .replaceAuthenticator: "Continue"
        case .confirmEmail: "Verify"
        }
    }

    var destructive: Bool { self == .disableTOTP || self == .disableEmail }
    var isPassword: Bool { self == .disableEmail }
}

private struct AdminBackupCodeList: Identifiable {
    let codes: [String]
    var id: String { codes.joined() }
}

// MARK: - Change password

private struct AdminChangePasswordSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var runner = ActionRunner()

    private var problem: String? {
        if new.isEmpty { return nil }
        if let p = AdminPasswordPolicy.problem(new) { return p }
        if !confirm.isEmpty && confirm != new { return "Passwords don't match." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current password", text: $current).textContentType(.password)
                }
                Section {
                    SecureField("New password", text: $new).textContentType(.newPassword)
                    SecureField("Confirm new password", text: $confirm).textContentType(.newPassword)
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.red) }
                    else { Text("At least 8 characters with upper- and lowercase letters, a digit and a symbol.") }
                }
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(current.isEmpty || new.isEmpty || new != confirm || problem != nil || runner.isRunning)
                }
            }
            .actionAlerts(runner)
        }
    }

    private func save() async {
        struct Body: Encodable { var currentPassword: String; var newPassword: String }
        await runner.run {
            try await session.client.call(.post, "users/me/change-password", body: Body(currentPassword: current, newPassword: new))
            dismiss()
        }
    }
}

// MARK: - TOTP setup

private struct AdminTOTPSetupSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let replacing: Bool
    /// A current code from the existing authenticator, required to replace it.
    let currentCode: String?
    var onEnabled: ([String]) -> Void

    @State private var setup = Loader<AdminTOTPSetup>()
    @State private var code = ""
    @State private var showSecret = false
    @State private var runner = ActionRunner()

    private func provisioningURI(_ s: AdminTOTPSetup) -> URL? {
        let issuer = s.issuer ?? "Bambuddy"
        let account = session.user?.username ?? "user"
        var comps = URLComponents()
        comps.scheme = "otpauth"
        comps.host = "totp"
        comps.path = "/\(issuer):\(account)"
        comps.queryItems = [URLQueryItem(name: "secret", value: s.secret), URLQueryItem(name: "issuer", value: issuer)]
        return comps.url
    }

    var body: some View {
        NavigationStack {
            LoadingContent(loader: setup, retry: start) { s in
                Form {
                    Section {
                        VStack(spacing: 12) {
                            if let uri = provisioningURI(s) {
                                AdminQRCodeView(text: uri.absoluteString, fallbackPNGBase64: s.qrCodeB64, size: 200)
                                Button {
                                    openURL(uri)
                                } label: {
                                    Label("Add to Authenticator on This Device", systemImage: "arrow.up.forward.app")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } header: {
                        Text("1. Add the Account")
                    } footer: {
                        Text("Scan the code with an authenticator on another device, or add it to an app on this device.")
                    }
                    Section {
                        if showSecret {
                            AdminSecretField(title: "Setup Key", value: s.secret)
                        } else {
                            Button("Show Setup Key") { showSecret = true }
                        }
                    } footer: {
                        Text("Enter the setup key manually if you can't scan the code.")
                    }
                    Section {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.title3.monospacedDigit())
                    } header: {
                        Text("2. Enter a Code")
                    }
                }
            }
            .navigationTitle(replacing ? "New Authenticator" : "Authenticator App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Verify") { Task { await enable() } }
                        .disabled(code.trimmingCharacters(in: .whitespaces).count < 6 || runner.isRunning || setup.value == nil)
                }
            }
            .actionAlerts(runner)
            .task { await start() }
        }
    }

    private func start() async {
        struct Body: Encodable { var code: String? }
        let code = currentCode
        await setup.load { try await session.client.send(.post, "auth/2fa/totp/setup", body: Body(code: code)) }
    }

    private func enable() async {
        struct Body: Encodable { var code: String }
        await runner.run {
            let r: AdminBackupCodes = try await session.client.send(.post, "auth/2fa/totp/enable", body: Body(code: code.trimmingCharacters(in: .whitespaces)))
            dismiss()
            onEnabled(r.backupCodes)
        }
    }
}

private struct AdminBackupCodesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let codes: [String]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Save these codes somewhere safe. Each one works once if you lose your authenticator. They won't be shown again.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Section("Backup Codes") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(codes, id: \.self) { c in
                            Text(c).font(.body.monospaced()).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 6)
                    Button {
                        UIPasteboard.general.string = codes.joined(separator: "\n")
                    } label: { Label("Copy All", systemImage: "doc.on.doc") }
                    ShareLink(item: codes.joined(separator: "\n")) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
            .navigationTitle("Backup Codes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .interactiveDismissDisabled()
        }
    }
}

// MARK: - Personal tokens screen

private struct AdminPersonalTokensView: View {
    @Environment(AppSession.self) private var session
    @State private var tokens = AdminCameraTokenStore()

    var body: some View {
        List {
            AdminCameraTokenSections(store: tokens)
        }
        .navigationTitle("Camera Tokens")
        .refreshable { await tokens.load(session) }
        .adminCameraTokenPresentation(tokens)
    }
}
