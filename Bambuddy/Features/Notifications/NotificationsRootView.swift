import SwiftUI

/// Per-user email preferences for print job events (`/user-notifications/preferences`).
struct NotificationEmailPreferences: Codable, Sendable, Equatable {
    var notifyPrintStart: Bool
    var notifyPrintComplete: Bool
    var notifyPrintFailed: Bool
    var notifyPrintStopped: Bool
}

/// The pieces of server state that decide whether per-user email is available.
struct NotificationAvailability: Sendable, Equatable {
    var advancedAuthEnabled: Bool
    var smtpConfigured: Bool
    var userNotificationsEnabled: Bool
}

struct NotificationsRootView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live

    @State private var availability = Loader<NotificationAvailability>()
    @State private var loader = Loader<NotificationEmailPreferences>()
    @State private var draft: NotificationEmailPreferences?
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Notifications")
                .toolbar {
                    if isAvailable, draft != nil {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { Task { await save() } }
                                .disabled(!isDirty || runner.isRunning || !canReceive)
                        }
                    }
                }
                .actionAlerts(runner)
                .task(id: live.revision("settings_updated")) { await load() }
        }
    }

    private var isAvailable: Bool {
        guard let a = availability.value else { return false }
        return session.isAuthEnabled && a.advancedAuthEnabled && a.userNotificationsEnabled
    }

    private var canReceive: Bool { session.can("notifications:user_email") && !(session.user?.email ?? "").isEmpty }

    private var isDirty: Bool { draft != nil && draft != loader.value }

    @ViewBuilder
    private var content: some View {
        LoadingContent(loader: availability, retry: load) { a in
            if !session.isAuthEnabled {
                unavailable("Sign-In Is Off",
                            "Email notifications are sent to individual user accounts. Enable authentication on the server to use them.",
                            systemImage: "person.crop.circle.badge.xmark")
            } else if !a.advancedAuthEnabled {
                unavailable("Email Not Set Up",
                            "An administrator needs to configure email (SMTP) and enable advanced authentication before per-user notifications can be sent.",
                            systemImage: "envelope.badge.shield.half.filled")
            } else if !a.userNotificationsEnabled {
                unavailable("User Notifications Disabled",
                            "An administrator has turned off per-user email notifications on this server.",
                            systemImage: "bell.slash")
            } else if !session.can("notifications:user_email") {
                unavailable("Not Available",
                            "Your account does not have permission to receive email notifications.",
                            systemImage: "lock")
            } else {
                preferencesForm
            }
        }
    }

    private func unavailable(_ title: String, _ message: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }

    @ViewBuilder
    private var preferencesForm: some View {
        LoadingContent(loader: loader, retry: load) { _ in
            Form {
                Section {
                    if let email = session.user?.email, !email.isEmpty {
                        LabeledContent("Send To", value: email)
                    } else {
                        Label("Add an email address to your account to receive notifications.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("These emails cover print jobs you started yourself.")
                }
                Section("Email Me When") {
                    toggle("A print starts", "play.circle", \.notifyPrintStart)
                    toggle("A print finishes", "checkmark.circle", \.notifyPrintComplete)
                    toggle("A print fails", "exclamationmark.octagon", \.notifyPrintFailed)
                    toggle("A print is stopped", "stop.circle", \.notifyPrintStopped)
                }
                .disabled(!canReceive)
            }
        }
    }

    private func toggle(_ title: String, _ image: String, _ key: WritableKeyPath<NotificationEmailPreferences, Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { draft?[keyPath: key] ?? false },
            set: { draft?[keyPath: key] = $0 }
        )) {
            Label(title, systemImage: image)
        }
    }

    private func load() async {
        let client = session.client
        await availability.load {
            async let adv = client.get("auth/advanced-auth/status", as: AdvancedAuthStatus.self)
            async let settings = client.get("settings/", as: JSONValue.self)
            let a = try await adv
            let s = (try? await settings) ?? .null
            return NotificationAvailability(
                advancedAuthEnabled: a.advancedAuthEnabled ?? false,
                smtpConfigured: a.smtpConfigured ?? false,
                userNotificationsEnabled: s["user_notifications_enabled"]?.boolValue ?? true
            )
        }
        guard isAvailable, session.can("notifications:user_email") else { return }
        await loader.load { try await client.get("user-notifications/preferences") }
        if let value = loader.value, draft == nil || !isDirty { draft = value }
    }

    private func save() async {
        guard let draft else { return }
        await runner.run("Preferences saved") {
            let saved: NotificationEmailPreferences = try await session.client.send(.put, "user-notifications/preferences", body: draft)
            loader.value = saved
            self.draft = saved
        }
    }
}
