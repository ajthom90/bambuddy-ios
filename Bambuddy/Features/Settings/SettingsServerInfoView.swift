import SwiftUI

/// The app's own connection settings: which server it talks to and who is signed in.
struct SettingsServerInfoView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Environment(\.openURL) private var openURL
    @State private var confirmSwitch = false
    @State private var confirmSignOut = false
    @State private var isReconnecting = false

    var body: some View {
        Form {
            Section {
                InfoRow("Address", session.serverURL?.absoluteString, systemImage: "link")
                InfoRow("Version", session.serverVersion.map { "v\($0)" }, systemImage: "number")
                LabeledContent {
                    HStack(spacing: 6) {
                        Circle().fill(live.isConnected ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(live.isConnected ? "Connected" : "Reconnecting…").foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Live Updates", systemImage: "dot.radiowaves.left.and.right")
                }
                InfoRow("Authentication", session.isAuthEnabled ? "Enabled" : "Disabled", systemImage: "lock")
            } header: {
                Text("Server")
            } footer: {
                Text("Live updates stream printer status and events from the server over a WebSocket.")
            }

            Section {
                Button {
                    Task {
                        isReconnecting = true
                        await session.connect()
                        isReconnecting = false
                    }
                } label: {
                    HStack {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                        if isReconnecting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isReconnecting)
                if let url = session.serverURL {
                    Button { openURL(url) } label: { Label("Open Web Interface", systemImage: "safari") }
                }
                Button(role: .destructive) { confirmSwitch = true } label: {
                    Label("Switch Server…", systemImage: "arrow.left.arrow.right")
                }
            }

            if session.isAuthEnabled {
                Section("Account") {
                    if let user = session.user {
                        InfoRow("Username", user.username, systemImage: "person.crop.circle")
                        if let email = user.email, !email.isEmpty { InfoRow("Email", email, systemImage: "envelope") }
                        InfoRow("Role", user.isAdmin ? "Administrator" : user.role.capitalized, systemImage: "person.badge.shield.checkmark")
                        if let groups = user.groups, !groups.isEmpty {
                            InfoRow("Groups", groups.map(\.name).joined(separator: ", "), systemImage: "person.2")
                        }
                        if let source = user.authSource, !source.isEmpty, source != "local" {
                            InfoRow("Signed in via", source.uppercased(), systemImage: "key")
                        }
                    }
                    NavigationLink {
                        AccountSecurityView()
                    } label: {
                        Label("Account Security", systemImage: "lock.shield")
                    }
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .navigationTitle("Server")
        .confirm("Switch Server?", isPresented: $confirmSwitch,
                 message: "You'll be disconnected from this server and signed out on this device.",
                 action: "Switch Server") {
            session.forgetServer()
        }
        .confirm("Sign Out?", isPresented: $confirmSignOut, action: "Sign Out") {
            Task { await session.logout() }
        }
    }
}
