import SwiftUI

/// Every page reachable from the Settings sidebar.
enum SettingsDestination: String, Hashable, CaseIterable, Identifiable {
    // App
    case server, accountSecurity
    // Server settings
    case general, costs, cameras, workflow, gcode, filament, smartPlugs, sensors, notifications,
         network, virtualPrinters, failureDetection, spoolbuddy, externalLinks, backup, updates, support
    // Security & administration
    case authentication, email, users, apiKeys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server: "Server"
        case .accountSecurity: "Account Security"
        case .general: "General"
        case .costs: "Costs & Energy"
        case .cameras: "Cameras"
        case .workflow: "Print Workflow"
        case .gcode: "G-code Snippets"
        case .filament: "Filament & AMS"
        case .smartPlugs: "Smart Plugs"
        case .sensors: "Sensors"
        case .notifications: "Notifications"
        case .network: "Network & Integrations"
        case .virtualPrinters: "Virtual Printers"
        case .failureDetection: "Failure Detection"
        case .spoolbuddy: "SpoolBuddy"
        case .externalLinks: "External Links"
        case .backup: "Backup & Restore"
        case .updates: "Updates"
        case .support: "Support & Logs"
        case .authentication: "Authentication"
        case .email: "Email (SMTP)"
        case .users: "Users & Groups"
        case .apiKeys: "API Keys"
        }
    }

    var systemImage: String {
        switch self {
        case .server: "server.rack"
        case .accountSecurity: "lock.shield"
        case .general: "gearshape"
        case .costs: "dollarsign.circle"
        case .cameras: "video"
        case .workflow: "list.number"
        case .gcode: "chevron.left.forwardslash.chevron.right"
        case .filament: "circle.circle"
        case .smartPlugs: "powerplug"
        case .sensors: "gauge.with.dots.needle.33percent"
        case .notifications: "bell.badge"
        case .network: "network"
        case .virtualPrinters: "printer.dotmatrix"
        case .failureDetection: "eye.trianglebadge.exclamationmark"
        case .spoolbuddy: "scalemass"
        case .externalLinks: "link"
        case .backup: "externaldrive.badge.timemachine"
        case .updates: "arrow.down.circle"
        case .support: "lifepreserver"
        case .authentication: "person.badge.key"
        case .email: "envelope"
        case .users: "person.2"
        case .apiKeys: "key"
        }
    }

    /// Permission required to show the page when auth is enabled (nil = always visible).
    var permission: String? {
        switch self {
        case .server, .accountSecurity: nil
        case .smartPlugs: "smart_plugs:read"
        case .notifications: "notifications:read"
        case .externalLinks: "external_links:read"
        case .backup: "settings:backup"
        case .updates: "settings:read"
        case .users: "users:read"
        case .apiKeys: "api_keys:read"
        default: "settings:read"
        }
    }

    static let serverPages: [SettingsDestination] = [
        .general, .costs, .cameras, .workflow, .gcode, .filament, .smartPlugs, .sensors, .notifications,
        .network, .virtualPrinters, .failureDetection, .spoolbuddy, .externalLinks, .backup, .updates, .support,
    ]
    static let adminPages: [SettingsDestination] = [.authentication, .email, .users, .apiKeys]

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .server: SettingsServerInfoView()
        case .accountSecurity: AccountSecurityView()
        case .general: SettingsGeneralView()
        case .costs: SettingsCostsView()
        case .cameras: SettingsCamerasView()
        case .workflow: SettingsWorkflowView()
        case .gcode: SettingsGcodeSnippetsView()
        case .filament: SettingsFilamentView()
        case .smartPlugs: SettingsSmartPlugsView()
        case .sensors: SettingsSensorsView()
        case .notifications: SettingsNotificationsView()
        case .network: SettingsNetworkView()
        case .virtualPrinters: SettingsVirtualPrintersView()
        case .failureDetection: SettingsFailureDetectionView()
        case .spoolbuddy: SettingsSpoolBuddyView()
        case .externalLinks: SettingsExternalLinksView()
        case .backup: SettingsBackupView()
        case .updates: SettingsUpdatesView()
        case .support: SettingsSupportView()
        case .authentication: SettingsAuthenticationView()
        case .email: SettingsEmailView()
        case .users: UsersAndGroupsView()
        case .apiKeys: APIKeysView()
        }
    }
}

struct SettingsRootView: View {
    @Environment(AppSession.self) private var session
    @State private var store = ServerSettingsStore()
    @State private var selection: SettingsDestination?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $selection, searchText: searchText)
                .navigationTitle("Settings")
                .searchable(text: $searchText, placement: .sidebar, prompt: "Search Settings")
        } detail: {
            NavigationStack {
                if let selection {
                    selection.view
                } else {
                    ContentUnavailableView("Select a Category", systemImage: "gearshape",
                                           description: Text("Choose a settings category from the list."))
                }
            }
            .id(selection)
        }
        .environment(store)
        .task(id: session.client.baseURL) {
            store.attach(session)
            if session.can("settings:read") { await store.load() }
        }
        .onAppear(perform: applyLaunchArguments)
    }

    private func applyLaunchArguments() {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "settingsPage"), let page = SettingsDestination(rawValue: raw) {
            selection = page
        }
        #endif
    }
}

private struct SettingsSidebar: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Binding var selection: SettingsDestination?
    let searchText: String

    var body: some View {
        List(selection: $selection) {
            if searchText.isEmpty {
                Section("App") {
                    NavigationLink(value: SettingsDestination.server) { serverRow }
                    if session.isAuthEnabled {
                        row(.accountSecurity)
                    }
                }
            }
            let server = filter(SettingsDestination.serverPages)
            if !server.isEmpty {
                Section("Server") { ForEach(server) { row($0) } }
            }
            let admin = filter(SettingsDestination.adminPages)
            if !admin.isEmpty {
                Section("Security & Administration") { ForEach(admin) { row($0) } }
            }
        }
        .overlay {
            if !searchText.isEmpty && filter(SettingsDestination.serverPages + SettingsDestination.adminPages).isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var serverRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.tint, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.serverURL?.host() ?? "Server").font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(live.isConnected ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusLine: String {
        var parts: [String] = []
        if let v = session.serverVersion { parts.append("v\(v)") }
        parts.append(live.isConnected ? "Live" : "Connecting…")
        if let user = session.user { parts.append(user.username) }
        return parts.joined(separator: " · ")
    }

    private func row(_ destination: SettingsDestination) -> some View {
        NavigationLink(value: destination) {
            Label(destination.title, systemImage: destination.systemImage)
        }
    }

    private func filter(_ pages: [SettingsDestination]) -> [SettingsDestination] {
        pages.filter { page in
            (page.permission.map(session.can) ?? true)
                && (searchText.isEmpty || Self.keywords(page).localizedCaseInsensitiveContains(searchText))
        }
    }

    /// Search terms per page, so users can find a setting without knowing its category.
    private static func keywords(_ page: SettingsDestination) -> String {
        let extra: String = switch page {
        case .general: "language date time format default printer archive thumbnails finish photo library disk storage notification logs"
        case .costs: "currency filament cost electricity energy kwh billing kill switch budget ledger"
        case .cameras: "external camera rtsp mjpeg snapshot usb rotation ffmpeg view mode"
        case .workflow: "queue print options bed levelling flow calibration timelapse plate clear stagger preheat keep warm slicer drying humidity presets fan temperature uploads"
        case .gcode: "gcode start end injection snippets"
        case .filament: "spoolman ams humidity temperature thresholds history retention filament warnings catalog color low stock rfid"
        case .smartPlugs: "tasmota home assistant shelly rest plug energy power automation"
        case .sensors: "home assistant sensors location printer readings"
        case .notifications: "providers templates push telegram discord email ntfy pushover language bed cooled test log"
        case .network: "mqtt home assistant prometheus metrics external url ftp retry timeout webhook"
        case .virtualPrinters: "virtual printer slicer upload proxy tailscale access code"
        case .failureDetection: "obico ai spaghetti failure detection"
        case .spoolbuddy: "spoolbuddy scale nfc device"
        case .externalLinks: "external links sidebar"
        case .backup: "backup restore github local schedule export import"
        case .updates: "updates version firmware beta"
        case .support: "debug logging logs support bundle"
        case .authentication: "auth login ldap oidc sso local login session advanced"
        case .email: "smtp email mail server"
        case .users: "users groups permissions"
        case .apiKeys: "api keys tokens webhook"
        default: ""
        }
        return page.title + " " + extra
    }
}
