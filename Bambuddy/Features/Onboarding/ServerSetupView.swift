import SwiftUI

struct ServerSetupView: View {
    @Environment(AppSession.self) private var session
    @State private var address = ""
    @State private var isChecking = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "printer.dotmatrix.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text("Welcome to Bambuddy").font(.title2.bold())
                        Text("Connect to your self-hosted Bambuddy server to monitor and manage your Bambu Lab printers.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("https://bambuddy.local:8000", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit { Task { await connect() } }
                } header: {
                    Text("Server Address")
                } footer: {
                    Text("Enter the address you use to open Bambuddy in a browser, e.g. http://192.168.1.20:8000")
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if isChecking { ProgressView() } else { Text("Connect").bold() }
                            Spacer()
                        }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
                }

                if !session.recentServers.isEmpty {
                    Section("Recent") {
                        ForEach(session.recentServers, id: \.self) { server in
                            Button(server) { address = server; Task { await connect() } }
                        }
                    }
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { focused = session.recentServers.isEmpty }
        }
    }

    private func connect() async {
        guard let url = AppSession.normalize(address) else {
            error = "That doesn't look like a valid address."
            return
        }
        isChecking = true
        defer { isChecking = false }
        error = nil
        do {
            _ = try await AppSession.probe(url)
            await session.useServer(url)
        } catch {
            // If the user omitted the scheme and http failed, try https.
            if !address.lowercased().hasPrefix("http"), var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                comps.scheme = "https"
                if let https = comps.url, (try? await AppSession.probe(https)) != nil {
                    await session.useServer(https)
                    return
                }
            }
            self.error = "Couldn't reach a Bambuddy server at \(url.absoluteString). \(error.localizedDescription)"
        }
    }
}

/// Shown when a server has never been configured (`requires_setup`).
struct FirstRunSetupView: View {
    @Environment(AppSession.self) private var session
    @State private var enableAuth = true
    @State private var username = "admin"
    @State private var password = ""
    @State private var confirm = ""
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This Bambuddy server hasn't been set up yet. Choose whether to require sign-in.")
                }
                Section {
                    Toggle("Enable Authentication", isOn: $enableAuth)
                    if enableAuth {
                        TextField("Admin Username", text: $username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        SecureField("Confirm Password", text: $confirm)
                    }
                }
                Section {
                    Button("Complete Setup") {
                        Task {
                            await runner.run {
                                struct Setup: Encodable { var authEnabled: Bool; var adminUsername: String?; var adminPassword: String? }
                                try await session.client.call(.post, "auth/setup", body: Setup(authEnabled: enableAuth, adminUsername: enableAuth ? username : nil, adminPassword: enableAuth ? password : nil))
                                await session.connect()
                            }
                        }
                    }
                    .disabled(enableAuth && (username.isEmpty || password.count < 8 || password != confirm))
                } footer: {
                    if enableAuth { Text("Password must be at least 8 characters.") }
                }
                Section { Button("Use a Different Server", role: .destructive) { session.forgetServer() } }
            }
            .navigationTitle("Server Setup")
            .actionAlerts(runner)
        }
    }
}
