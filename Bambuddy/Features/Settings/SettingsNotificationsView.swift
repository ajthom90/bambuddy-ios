import SwiftUI

/// Settings › Notifications: global notification settings, the server's notification providers,
/// message templates and the delivery log.
struct SettingsNotificationsView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store
    @Environment(PrinterStore.self) private var printers

    @State private var loader = Loader<[SettingsNotificationProvider]>()
    @State private var runner = ActionRunner()
    @State private var advancedAuthEnabled: Bool?
    @State private var editing: SettingsNotificationEditTarget?
    @State private var deleting: SettingsNotificationProvider?
    @State private var testingId: Int?
    @State private var testResult: SettingsNotificationTestOutcome?
    @State private var testAll: SettingsNotificationTestAllResult?
    @State private var isTestingAll = false

    private var canRead: Bool { session.can("notifications:read") }
    private var canCreate: Bool { session.can("notifications:create") }
    private var canUpdate: Bool { session.can("notifications:update") }
    private var canDelete: Bool { session.can("notifications:delete") }

    var body: some View {
        @Bindable var store = store
        List {
            settingsSection
            if canRead {
                if let testAll { testAllSection(testAll) }
                providersSection
                Section {
                    if session.can("notification_templates:read") {
                        NavigationLink {
                            SettingsNotificationTemplatesView()
                        } label: {
                            Label("Message Templates", systemImage: "text.bubble")
                        }
                    }
                    NavigationLink {
                        SettingsNotificationLogView(providers: loader.value ?? [])
                    } label: {
                        Label("Delivery Log", systemImage: "clock.arrow.circlepath")
                    }
                } footer: {
                    Text("Templates control the wording of every message. The log lists recent deliveries and failures.")
                }
            } else {
                Section {
                    Label("You don't have permission to view notification providers.", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Notifications")
        .toolbar {
            if store.isSaving || isTestingAll {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
            if canRead, canUpdate, !(loader.value ?? []).isEmpty {
                ToolbarItem(placement: .secondaryAction) {
                    Button { Task { await runTestAll() } } label: {
                        Label("Test All Enabled Providers", systemImage: "paperplane")
                    }
                    .disabled(isTestingAll || !(loader.value ?? []).contains { $0.enabled })
                }
            }
            if canRead, canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .new } label: { Label("Add Provider", systemImage: "plus") }
                }
            }
        }
        .task {
            if !store.hasLoaded, !store.isLoading { await store.load() }
        }
        .task { await loadAll() }
        .refreshable {
            await store.load()
            await loadAll()
        }
        .sheet(item: $editing) { target in
            SettingsNotificationProviderEditor(provider: target.provider) { _ in
                Task { await loadProviders() }
            }
        }
        .confirm("Delete Provider?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                 message: deleting.map { "“\($0.name)” will stop sending notifications. Its delivery log entries are kept." }) {
            if let provider = deleting { Task { await delete(provider) } }
        }
        .alert(testResult?.success == true ? "Test Sent" : "Test Failed",
               isPresented: Binding(get: { testResult != nil }, set: { if !$0 { testResult = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(testResult?.message ?? "")
        }
        .alert("Couldn't Save", isPresented: Binding(get: { store.saveError != nil }, set: { if !$0 { store.saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.saveError ?? "") }
        .actionAlerts(runner)
        .onDisappear { Task { await store.flush() } }
    }

    // MARK: Sections

    @ViewBuilder
    private var settingsSection: some View {
        Section {
            if store.hasLoaded {
                SettingsPicker("Message Language", key: "notification_language",
                               choices: Self.languages, help: "Language used for notification messages.")
                SettingsNumberField("Bed Cooled Below", key: "bed_cooled_threshold", unit: "°C",
                                    help: "Temperature at which the bed counts as cooled after a print.",
                                    integer: true, range: 20...80)
                SettingsToggle("User Notifications", key: "user_notifications_enabled",
                               help: advancedAuthEnabled == false
                                   ? "Requires Advanced Authentication, which is currently off."
                                   : "Lets users subscribe to email updates about their own print jobs.",
                               default: true)
                    .disabled(advancedAuthEnabled == false)
            } else if let error = store.loadError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Try Again") { Task { await store.load() } }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } header: {
            Text("General")
        }
    }

    @ViewBuilder
    private var providersSection: some View {
        Section {
            if let providers = loader.value {
                if providers.isEmpty {
                    ContentUnavailableView {
                        Label("No Providers", systemImage: "bell.slash")
                    } description: {
                        Text("Add a provider to get print and printer alerts by email, Telegram, Discord, ntfy and more.")
                    } actions: {
                        if canCreate {
                            Button("Add Provider") { editing = .new }.buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    ForEach(providers) { provider in
                        providerRow(provider)
                    }
                }
            } else if let error = loader.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadProviders() } }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } header: {
            Text("Providers")
        } footer: {
            if let providers = loader.value, !providers.isEmpty {
                Text("Swipe a provider to test, pause or delete it.")
            }
        }
    }

    private func providerRow(_ provider: SettingsNotificationProvider) -> some View {
        Button {
            if canUpdate { editing = .existing(provider) }
        } label: {
            SettingsNotificationProviderRow(
                provider: provider,
                printerName: provider.printerId.map { id in printers.printer(id)?.name ?? "Printer \(id)" },
                isTesting: testingId == provider.id
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if canDelete {
                Button(role: .destructive) { deleting = provider } label: { Label("Delete", systemImage: "trash") }
            }
            if canUpdate {
                Button { Task { await test(provider) } } label: { Label("Test", systemImage: "paperplane") }
                    .tint(.blue)
            }
        }
        .swipeActions(edge: .leading) {
            if canUpdate {
                Button { Task { await setEnabled(provider, !provider.enabled) } } label: {
                    provider.enabled
                        ? Label("Pause", systemImage: "bell.slash")
                        : Label("Enable", systemImage: "bell")
                }
                .tint(provider.enabled ? .orange : .green)
            }
        }
        .contextMenu {
            if canUpdate {
                Button { Task { await test(provider) } } label: { Label("Send Test", systemImage: "paperplane") }
                Button { editing = .existing(provider) } label: { Label("Edit", systemImage: "pencil") }
                Button { Task { await setEnabled(provider, !provider.enabled) } } label: {
                    provider.enabled
                        ? Label("Pause", systemImage: "bell.slash")
                        : Label("Enable", systemImage: "bell")
                }
            }
            if canDelete {
                Divider()
                Button(role: .destructive) { deleting = provider } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func testAllSection(_ result: SettingsNotificationTestAllResult) -> some View {
        Section {
            if (result.tested ?? 0) == 0 {
                Text("No enabled providers to test.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    Label("\(result.success ?? 0) passed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if (result.failed ?? 0) > 0 {
                        Label("\(result.failed ?? 0) failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                .font(.subheadline.weight(.medium))
                ForEach(Array((result.results ?? []).filter { $0.success != true }.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.providerName ?? "Provider").font(.subheadline.weight(.semibold))
                        Text(entry.message ?? "Unknown error").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Button("Dismiss") { withAnimation { testAll = nil } }
        } header: {
            Text("Test Results")
        }
    }

    // MARK: Actions

    private func loadAll() async {
        async let providers: Void = loadProviders()
        async let auth: Void = loadAdvancedAuth()
        _ = await (providers, auth)
    }

    private func loadProviders() async {
        guard canRead else { return }
        let client = session.client
        await loader.load { try await client.get("notifications/") }
    }

    private func loadAdvancedAuth() async {
        let status: SettingsNotificationAdvancedAuthStatus? = try? await session.client.get("auth/advanced-auth/status")
        if let status { advancedAuthEnabled = status.advancedAuthEnabled ?? false }
    }

    private func setEnabled(_ provider: SettingsNotificationProvider, _ enabled: Bool) async {
        await runner.run(enabled ? "Provider enabled" : "Provider paused") {
            let updated: SettingsNotificationProvider = try await session.client.send(
                .patch, "notifications/\(provider.id)", body: JSONValue.object(["enabled": .bool(enabled)]))
            replace(updated)
        }
    }

    private func test(_ provider: SettingsNotificationProvider) async {
        testingId = provider.id
        defer { testingId = nil }
        do {
            let result: SettingsNotificationTestResult = try await session.client.send(.post, "notifications/\(provider.id)/test")
            testResult = SettingsNotificationTestOutcome(success: result.success,
                                                         message: result.message ?? (result.success ? "The test notification was sent." : "The provider reported an error."))
        } catch is CancellationError {
        } catch {
            testResult = SettingsNotificationTestOutcome(success: false, message: error.localizedDescription)
        }
        await loadProviders()
    }

    private func runTestAll() async {
        isTestingAll = true
        defer { isTestingAll = false }
        await runner.run {
            let result: SettingsNotificationTestAllResult = try await session.client.send(.post, "notifications/test-all")
            withAnimation { testAll = result }
        }
        await loadProviders()
    }

    private func delete(_ provider: SettingsNotificationProvider) async {
        await runner.run("Provider deleted") {
            try await session.client.call(.delete, "notifications/\(provider.id)")
            loader.value?.removeAll { $0.id == provider.id }
        }
    }

    private func replace(_ provider: SettingsNotificationProvider) {
        guard var list = loader.value, let index = list.firstIndex(where: { $0.id == provider.id }) else { return }
        list[index] = provider
        loader.value = list
    }

    /// Languages the server can write notifications in.
    static let languages: [(String, String)] = [
        ("en", "English"), ("de", "Deutsch"), ("es", "Español"), ("fr", "Français"), ("ja", "日本語"),
        ("it", "Italiano"), ("ko", "한국어"), ("nl", "Nederlands"), ("pt-BR", "Português (Brasil)"),
        ("zh-CN", "简体中文"), ("zh-TW", "繁體中文"), ("tr", "Türkçe"), ("ru", "Русский"), ("uk", "Українська"),
    ]
}

// MARK: - Helpers

private struct SettingsNotificationTestOutcome: Hashable {
    let success: Bool
    let message: String
}

private enum SettingsNotificationEditTarget: Identifiable {
    case new
    case existing(SettingsNotificationProvider)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let p): "provider-\(p.id)"
        }
    }

    var provider: SettingsNotificationProvider? {
        if case .existing(let p) = self { return p }
        return nil
    }
}

/// A provider in the list: type icon, name, status, event summary and delivery health.
struct SettingsNotificationProviderRow: View {
    let provider: SettingsNotificationProvider
    let printerName: String?
    var isTesting = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: SettingsNotificationProviderKind.systemImage(for: provider.providerType))
                .font(.body)
                .foregroundStyle(provider.enabled ? Color.white : Color.secondary)
                .frame(width: 34, height: 34)
                .background(provider.enabled ? Color.accentColor : Color.secondary.opacity(0.2), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(provider.name).font(.headline).lineLimit(1)
                    if !provider.enabled { StatusBadge(text: "Paused", color: .orange) }
                    Spacer(minLength: 0)
                    if isTesting { ProgressView().controlSize(.small) }
                }
                Text([SettingsNotificationProviderKind.title(for: provider.providerType), printerName ?? "All printers"]
                    .joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)

                let events = provider.enabledEvents
                Text(events.isEmpty ? "No events selected" : Self.summary(events))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)

                HStack(spacing: 10) {
                    if provider.quietHoursEnabled {
                        Label("Quiet \(provider.quietHoursStart ?? "?")–\(provider.quietHoursEnd ?? "?")", systemImage: "moon.fill")
                    }
                    if provider.dailyDigestEnabled {
                        Label("Digest \(provider.dailyDigestTime ?? "")", systemImage: "calendar")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

                if provider.lastAttemptFailed, let error = provider.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if let success = provider.lastSuccess {
                    Label("Last delivered \(success.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    static func summary(_ events: [SettingsNotificationEvent]) -> String {
        let names = events.map(\.title)
        if names.count <= 4 { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }
}
