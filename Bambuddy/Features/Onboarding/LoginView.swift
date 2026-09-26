import SwiftUI
import WebKit

struct LoginView: View {
    @Environment(AppSession.self) private var session
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var providers: [OIDCProvider] = []
    @State private var advanced: AdvancedAuthStatus?
    @State private var twoFactor: TwoFactorChallenge?
    @State private var oidcURL: IdentifiableURL?
    @State private var showForgot = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 48)).foregroundStyle(.tint)
                        Text("Sign In").font(.title2.bold())
                        Text(session.serverURL?.host() ?? "").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)

                if advanced?.localLoginEnabled ?? true {
                    Section {
                        TextField("Username or Email", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .onSubmit { Task { await login() } }
                    }
                    Section {
                        Button {
                            Task { await login() }
                        } label: {
                            HStack { Spacer(); if isWorking { ProgressView() } else { Text("Sign In").bold() }; Spacer() }
                        }
                        .disabled(username.isEmpty || password.isEmpty || isWorking)
                        if advanced?.smtpConfigured == true {
                            Button("Forgot Password?") { showForgot = true }
                        }
                    }
                }

                if !providers.isEmpty {
                    Section("Single Sign-On") {
                        ForEach(providers) { provider in
                            Button {
                                Task { await startOIDC(provider) }
                            } label: {
                                Label("Continue with \(provider.name)", systemImage: "key.horizontal")
                            }
                        }
                    }
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }

                Section {
                    Button("Use a Different Server") { session.forgetServer() }
                }
            }
            .navigationTitle("Bambuddy")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                providers = (try? await session.client.get("auth/oidc/providers")) ?? []
                advanced = try? await session.client.get("auth/advanced-auth/status")
            }
            .sheet(item: $twoFactor) { challenge in
                TwoFactorView(challenge: challenge)
            }
            .sheet(item: $oidcURL) { item in
                OIDCLoginSheet(url: item.url) { token in
                    oidcURL = nil
                    Task { await exchangeOIDC(token) }
                }
            }
            .sheet(isPresented: $showForgot) { ForgotPasswordView() }
        }
    }

    private func login() async {
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            let response: LoginResponse = try await session.client.send(.post, "auth/login", body: LoginRequest(username: username, password: password))
            if response.requires2fa == true, let pre = response.preAuthToken {
                twoFactor = TwoFactorChallenge(preAuthToken: pre, methods: response.twoFaMethods ?? ["totp"])
            } else if let token = response.accessToken {
                await session.completeLogin(token: token, user: response.user)
            } else {
                error = "Unexpected response from server."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startOIDC(_ provider: OIDCProvider) async {
        do {
            struct Authorize: Decodable { var authUrl: String }
            let r: Authorize = try await session.client.get("auth/oidc/authorize/\(provider.id)")
            if let url = URL(string: r.authUrl) { oidcURL = IdentifiableURL(url: url) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func exchangeOIDC(_ token: String) async {
        do {
            struct Exchange: Encodable { var oidcToken: String }
            let response: LoginResponse = try await session.client.send(.post, "auth/oidc/exchange", body: Exchange(oidcToken: token))
            if response.requires2fa == true, let pre = response.preAuthToken {
                twoFactor = TwoFactorChallenge(preAuthToken: pre, methods: response.twoFaMethods ?? ["totp"])
            } else if let access = response.accessToken {
                await session.completeLogin(token: access, user: response.user)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct IdentifiableURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

struct TwoFactorChallenge: Identifiable {
    let preAuthToken: String
    let methods: [String]
    var id: String { preAuthToken }
}

struct TwoFactorView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let challenge: TwoFactorChallenge
    @State private var method = "totp"
    @State private var code = ""
    @State private var error: String?
    @State private var info: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Method", selection: $method) {
                        ForEach(challenge.methods + ["backup"], id: \.self) { m in
                            Text(label(m)).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField(method == "backup" ? "Backup code" : "6-digit code", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(method == "backup" ? .asciiCapable : .numberPad)
                        .textInputAutocapitalization(.never)
                    if method == "email" {
                        Button("Send Code by Email") { Task { await sendEmail() } }
                    }
                }
                if let info { Section { Text(info).foregroundStyle(.secondary) } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("Verify") { Task { await verify() } }.disabled(code.isEmpty || isWorking)
                }
            }
            .navigationTitle("Two-Factor Authentication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { method = challenge.methods.first ?? "totp" }
        }
    }

    private func label(_ m: String) -> String {
        switch m { case "totp": "Authenticator"; case "email": "Email"; default: "Backup" }
    }

    private func sendEmail() async {
        do {
            struct Send: Encodable { var preAuthToken: String }
            try await session.client.call(.post, "auth/2fa/email/send", body: Send(preAuthToken: challenge.preAuthToken))
            info = "A code was sent to your email address."
        } catch { self.error = error.localizedDescription }
    }

    private func verify() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let r: LoginResponse = try await session.client.send(.post, "auth/2fa/verify", body: TwoFAVerifyRequest(preAuthToken: challenge.preAuthToken, code: code.trimmingCharacters(in: .whitespaces), method: method))
            if let token = r.accessToken {
                dismiss()
                await session.completeLogin(token: token, user: r.user)
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct ForgotPasswordView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                } footer: { Text("If an account exists for this address, you'll receive a password reset email.") }
                if let message { Section { Text(message) } }
                Button("Send Reset Email") {
                    Task {
                        do {
                            struct Req: Encodable { var email: String }
                            let r: JSONValue = try await session.client.send(.post, "auth/forgot-password", body: Req(email: email))
                            message = r["message"]?.stringValue ?? "Check your email."
                        } catch { message = error.localizedDescription }
                    }
                }.disabled(email.isEmpty)
            }
            .navigationTitle("Reset Password")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

/// Runs the OIDC flow in a web view and captures the `#oidc_token=` redirect.
struct OIDCLoginSheet: View {
    let url: URL
    let onToken: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            OIDCWebView(url: url, onToken: onToken)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign In")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct OIDCWebView: UIViewRepresentable {
    let url: URL
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onToken: (String) -> Void
        var delivered = false
        init(onToken: @escaping (String) -> Void) { self.onToken = onToken }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .allow }
            if let fragment = url.fragment, fragment.hasPrefix("oidc_token=") {
                let token = String(fragment.dropFirst("oidc_token=".count))
                if !delivered { delivered = true; onToken(token.removingPercentEncoding ?? token) }
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Fragment-only redirects may not trigger a policy decision; check the committed URL too.
            if let url = webView.url, let fragment = url.fragment, fragment.hasPrefix("oidc_token="), !delivered {
                delivered = true
                onToken(String(fragment.dropFirst("oidc_token=".count)))
            }
        }
    }
}
