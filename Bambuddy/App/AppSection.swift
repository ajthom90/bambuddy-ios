import SwiftUI

/// Top-level navigation destinations, mirroring the web UI's sidebar.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case printers, camWall, inventory, archives, queue, projects, files, makerworld,
         profiles, maintenance, stats, finance, spoolbuddy, links, notifications, system, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .printers: "Printers"
        case .camWall: "Camera Wall"
        case .inventory: "Inventory"
        case .archives: "Archives"
        case .queue: "Queue"
        case .projects: "Projects"
        case .files: "Files"
        case .makerworld: "MakerWorld"
        case .profiles: "Profiles"
        case .maintenance: "Maintenance"
        case .stats: "Statistics"
        case .finance: "Finance"
        case .spoolbuddy: "SpoolBuddy"
        case .links: "Links"
        case .notifications: "Notifications"
        case .system: "System"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .printers: "printer"
        case .camWall: "square.grid.2x2"
        case .inventory: "circle.circle"
        case .archives: "archivebox"
        case .queue: "list.number"
        case .projects: "folder.badge.gearshape"
        case .files: "folder"
        case .makerworld: "globe"
        case .profiles: "slider.horizontal.3"
        case .maintenance: "wrench.and.screwdriver"
        case .stats: "chart.bar"
        case .finance: "dollarsign.circle"
        case .spoolbuddy: "sensor.tag.radiowaves.forward"
        case .links: "link"
        case .notifications: "bell"
        case .system: "info.circle"
        case .settings: "gearshape"
        }
    }

    /// Permission required to show the section when auth is enabled.
    var permission: String? {
        switch self {
        case .finance: "cost_centers:read_own"
        case .makerworld: "makerworld:view"
        case .settings: "settings:read"
        case .links: "external_links:read"
        default: nil
        }
    }

    @MainActor @ViewBuilder
    var rootView: some View {
        switch self {
        case .printers: PrintersView()
        case .camWall: CamWallView()
        case .inventory: InventoryRootView()
        case .archives: ArchivesRootView()
        case .queue: QueueRootView()
        case .projects: ProjectsRootView()
        case .files: FilesRootView()
        case .makerworld: MakerWorldRootView()
        case .profiles: ProfilesRootView()
        case .maintenance: MaintenanceRootView()
        case .stats: StatsRootView()
        case .finance: FinanceRootView()
        case .spoolbuddy: SpoolBuddyRootView()
        case .links: ExternalLinksView()
        case .notifications: NotificationsRootView()
        case .system: SystemRootView()
        case .settings: SettingsRootView()
        }
    }
}
