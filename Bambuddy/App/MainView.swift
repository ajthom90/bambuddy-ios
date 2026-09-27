import SwiftUI

/// Tab bar on iPhone, sidebar on iPad (via `.sidebarAdaptable`).
struct MainView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @AppStorage("selectedSection") private var selection: AppSection = .printers
    @AppStorage("tabCustomization") private var customization: TabViewCustomization

    private let primary: [AppSection] = [.printers, .queue, .archives, .inventory]
    private let library: [AppSection] = [.files, .projects, .makerworld, .profiles]
    private let manage: [AppSection] = [.camWall, .maintenance, .stats, .finance, .spoolbuddy]
    private let admin: [AppSection] = [.links, .notifications, .system, .settings]

    var body: some View {
        TabView(selection: $selection) {
            ForEach(visible(primary)) { section in
                Tab(section.title, systemImage: section.systemImage, value: section) {
                    section.rootView
                }
                .customizationID(section.rawValue)
            }
            TabSection("Library") {
                ForEach(visible(library)) { section in
                    Tab(section.title, systemImage: section.systemImage, value: section) { section.rootView }
                        .customizationID(section.rawValue)
                }
            }
            .customizationID("library")
            TabSection("Manage") {
                ForEach(visible(manage)) { section in
                    Tab(section.title, systemImage: section.systemImage, value: section) { section.rootView }
                        .customizationID(section.rawValue)
                }
            }
            .customizationID("manage")
            TabSection("Server") {
                ForEach(visible(admin)) { section in
                    Tab(section.title, systemImage: section.systemImage, value: section) { section.rootView }
                        .customizationID(section.rawValue)
                }
            }
            .customizationID("server")
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewCustomization($customization)
        .background { SectionShortcuts(sections: visible(primary + library + manage + admin), selection: $selection) }
        .overlay(alignment: .top) { LiveNoticeBanner() }
    }

    private func visible(_ sections: [AppSection]) -> [AppSection] {
        sections.filter { $0.permission.map(session.can) ?? true }
    }
}

/// Transient banner for notable server events (print finished, plate not empty, …).
struct LiveNoticeBanner: View {
    @Environment(LiveUpdates.self) private var live
    @Environment(PrinterStore.self) private var printers
    @State private var visibleNotice: String?

    var body: some View {
        VStack {
            if let visibleNotice {
                Toast(message: visibleNotice, systemImage: "bell.fill")
                    .padding(.top, 8)
                    .onTapGesture { self.visibleNotice = nil }
            }
        }
        .animation(.snappy, value: visibleNotice)
        .onChange(of: live.latestNotice?.raw) { _, _ in
            guard let event = live.latestNotice else { return }
            visibleNotice = describe(event)
            Task {
                try? await Task.sleep(for: .seconds(5))
                if visibleNotice == describe(event) { visibleNotice = nil }
            }
        }
    }

    private func describe(_ e: LiveEvent) -> String {
        let name = e.printerId.flatMap { printers.printer($0)?.name } ?? "Printer"
        let file = e.data?["subtask_name"]?.stringValue ?? e.data?["filename"]?.stringValue
        switch e.type {
        case "print_start": return "\(name): started \(file ?? "print")"
        case "print_complete":
            let status = e.data?["status"]?.stringValue ?? "completed"
            return "\(name): print \(status)"
        case "plate_not_empty": return "\(name): build plate not empty"
        case "missing_spool_assignment": return "\(name): missing spool assignment"
        case "kill_switch_triggered": return "\(name): kill switch triggered"
        case "billing_charge_failed": return "Billing charge failed"
        case "unknown_tag": return "Unknown RFID tag detected"
        case "queue_item_failed": return "Queue item failed to start"
        default: return e.type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Hardware-keyboard shortcuts: ⌘1…⌘9 jump to the first nine visible sections, ⌘, opens Settings.
private struct SectionShortcuts: View {
    let sections: [AppSection]
    @Binding var selection: AppSection

    var body: some View {
        ZStack {
            ForEach(Array(sections.prefix(9).enumerated()), id: \.element) { index, section in
                Button(section.title) { selection = section }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            if sections.contains(.settings) {
                Button("Settings") { selection = .settings }.keyboardShortcut(",", modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
