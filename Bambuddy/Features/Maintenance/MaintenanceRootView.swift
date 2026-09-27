import SwiftUI

enum MaintenanceTab: String, CaseIterable, Identifiable {
    case status, setup
    var id: String { rawValue }
    var title: String { self == .status ? "Status" : "Setup" }
}

enum MaintenanceRoute: Hashable {
    case item(printerId: Int, itemId: Int)
    case type(Int)
}

/// Loads the overview and the list of maintenance types together; shared by
/// the status and setup tabs and the pushed detail screens.
@MainActor
@Observable
final class MaintenanceStore {
    var overview: [MaintenancePrinterOverview]?
    var types: [MaintenanceTypeInfo] = []
    var error: String?
    var isLoading = false

    func load(client: APIClient) async {
        isLoading = true
        defer { isLoading = false }
        async let typesReq: [MaintenanceTypeInfo]? = try? client.get("maintenance/types")
        do {
            let o: [MaintenancePrinterOverview] = try await client.get("maintenance/overview")
            overview = o.sorted { a, b in
                if a.dueCount != b.dueCount { return a.dueCount > b.dueCount }
                if a.warningCount != b.warningCount { return a.warningCount > b.warningCount }
                return a.printerName.localizedStandardCompare(b.printerName) == .orderedAscending
            }
            error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
        if let t = await typesReq { types = t }
    }

    func item(printerId: Int, itemId: Int) -> MaintenanceItemStatus? {
        overview?.first { $0.printerId == printerId }?.maintenanceItems.first { $0.id == itemId }
    }

    func type(_ id: Int) -> MaintenanceTypeInfo? { types.first { $0.id == id } }

    /// Printers that have the given type, with the item id on each.
    func assignments(for typeId: Int) -> [(printer: MaintenancePrinterOverview, itemId: Int)] {
        (overview ?? []).compactMap { p in
            p.maintenanceItems.first { $0.maintenanceTypeId == typeId }.map { (p, $0.id) }
        }
    }

    var totalDue: Int { (overview ?? []).reduce(0) { $0 + $1.dueCount } }
    var totalWarning: Int { (overview ?? []).reduce(0) { $0 + $1.warningCount } }
}

struct MaintenanceRootView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live

    @State private var store = MaintenanceStore()
    @State private var path = NavigationPath()
    @AppStorage("maintenance.tab") private var tab = MaintenanceTab.status.rawValue

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.overview == nil, let error = store.error {
                    ContentUnavailableView {
                        Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Try Again") { Task { await reload() } }.buttonStyle(.bordered)
                    }
                } else if store.overview == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tab == MaintenanceTab.setup.rawValue {
                    MaintenanceSetupView(store: store, reload: reload)
                } else {
                    MaintenanceStatusView(store: store, reload: reload)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("View", selection: $tab) {
                    ForEach(MaintenanceTab.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .navigationTitle("Maintenance")
            .refreshable { await reload() }
            .task(id: live.revision("print_complete", "print_start")) { await reload() }
            .navigationDestination(for: MaintenanceRoute.self) { route in
                switch route {
                case .item(let printerId, let itemId):
                    MaintenanceItemDetailView(store: store, printerId: printerId, itemId: itemId, reload: reload)
                case .type(let id):
                    MaintenanceTypeDetailView(store: store, typeId: id, reload: reload)
                }
            }
            #if DEBUG
            .onAppear {
                if let t = UserDefaults.standard.string(forKey: "maintenanceTab") { tab = t }
                let item = UserDefaults.standard.integer(forKey: "openMaintenanceItem")
                let printer = UserDefaults.standard.integer(forKey: "openMaintenancePrinter")
                if item > 0, printer > 0, path.isEmpty { path.append(MaintenanceRoute.item(printerId: printer, itemId: item)) }
            }
            #endif
        }
    }

    private func reload() async { await store.load(client: session.client) }
}

// MARK: - Status tab

private struct MaintenanceStatusView: View {
    @Environment(AppSession.self) private var session
    let store: MaintenanceStore
    let reload: () async -> Void

    @AppStorage("maintenance.attentionOnly") private var attentionOnly = false
    @AppStorage("maintenance.hideDisabled") private var hideDisabled = false
    @State private var runner = ActionRunner()
    @State private var performing: MaintenanceItemStatus?
    @State private var editingHours: MaintenancePrinterOverview?
    @State private var hoursText = ""

    private var canUpdate: Bool { session.can("maintenance:update") }

    var body: some View {
        let overview = store.overview ?? []
        List {
            Section {
                summary
            }
            if overview.isEmpty {
                ContentUnavailableView("No Printers", systemImage: "printer",
                                       description: Text("Maintenance is tracked for each active printer."))
            }
            ForEach(overview) { printer in
                let items = printer.sortedItems.filter { item in
                    (!attentionOnly || (item.enabled && (item.isDue || item.isWarning))) && (!hideDisabled || item.enabled)
                }
                Section {
                    hoursRow(printer)
                    ForEach(items) { item in
                        NavigationLink(value: MaintenanceRoute.item(printerId: printer.printerId, itemId: item.id)) {
                            MaintenanceItemRow(item: item)
                        }
                        .swipeActions(edge: .leading) {
                            if canUpdate && item.enabled {
                                Button { performing = item } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if canUpdate {
                                Button { Task { await setEnabled(item, !item.enabled) } } label: {
                                    Label(item.enabled ? "Disable" : "Enable", systemImage: item.enabled ? "pause.circle" : "play.circle")
                                }
                                .tint(item.enabled ? .gray : .blue)
                            }
                        }
                        .contextMenu {
                            if canUpdate {
                                if item.enabled {
                                    Button { performing = item } label: { Label("Mark as Done…", systemImage: "checkmark.circle") }
                                }
                                Button { Task { await setEnabled(item, !item.enabled) } } label: {
                                    Label(item.enabled ? "Disable" : "Enable", systemImage: item.enabled ? "pause.circle" : "play.circle")
                                }
                            }
                            if let s = item.maintenanceTypeWikiUrl, let url = URL(string: s) {
                                Link(destination: url) { Label("View Guide", systemImage: "book") }
                            }
                        }
                    }
                    if items.isEmpty {
                        Text(attentionOnly ? "Nothing needs attention." : "No maintenance items.").foregroundStyle(.secondary)
                    }
                } header: {
                    MaintenancePrinterHeader(printer: printer)
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Toggle("Needs Attention Only", isOn: $attentionOnly)
                    Toggle("Hide Disabled", isOn: $hideDisabled)
                } label: {
                    Label("Filter", systemImage: attentionOnly || hideDisabled ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(item: $performing) { item in
            MaintenancePerformSheet(item: item) { Task { await reload() } }
        }
        .alert("Total Print Hours", isPresented: Binding(get: { editingHours != nil }, set: { if !$0 { editingHours = nil } })) {
            TextField("Hours", text: $hoursText).keyboardType(.decimalPad)
            Button("Save") { if let p = editingHours { Task { await saveHours(p) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Set the printer's lifetime print hours, e.g. from the printer's own counter. Hours-based maintenance is measured from this.")
        }
        .actionAlerts(runner)
    }

    @ViewBuilder
    private var summary: some View {
        let due = store.totalDue, warn = store.totalWarning
        HStack(spacing: 12) {
            Image(systemName: due > 0 ? "exclamationmark.triangle.fill" : warn > 0 ? "clock.fill" : "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(due > 0 ? .red : warn > 0 ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                if due == 0 && warn == 0 {
                    Text("All maintenance is up to date").font(.headline)
                } else {
                    Text([due > 0 ? "\(due) overdue" : nil, warn > 0 ? "\(warn) due soon" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.headline)
                }
                Text("\(store.overview?.count ?? 0) printer\((store.overview?.count ?? 0) == 1 ? "" : "s") tracked")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func hoursRow(_ printer: MaintenancePrinterOverview) -> some View {
        Button {
            guard canUpdate else { return }
            hoursText = String(Int(printer.totalPrintHours.rounded()))
            editingHours = printer
        } label: {
            HStack {
                Label("Total print time", systemImage: "timer")
                Spacer()
                Text("\(Int(printer.totalPrintHours.rounded())) h").monospacedDigit().foregroundStyle(.secondary)
                if canUpdate { Image(systemName: "pencil").font(.caption).foregroundStyle(.tint) }
            }
        }
        .foregroundStyle(.primary)
    }

    private func setEnabled(_ item: MaintenanceItemStatus, _ enabled: Bool) async {
        await runner.run(nil) {
            try await session.client.call(.patch, "maintenance/items/\(item.id)", body: ["enabled": JSONValue.bool(enabled)])
        }
        await reload()
    }

    private func saveHours(_ printer: MaintenancePrinterOverview) async {
        guard let hours = Double(hoursText.replacingOccurrences(of: ",", with: ".")), hours >= 0 else {
            runner.errorMessage = "Enter a number of hours."
            return
        }
        await runner.run("Print hours updated") {
            try await session.client.call(.patch, "maintenance/printers/\(printer.printerId)/hours", query: ["total_hours": .double(hours)])
        }
        await reload()
    }
}

private struct MaintenancePrinterHeader: View {
    let printer: MaintenancePrinterOverview
    var body: some View {
        HStack(spacing: 6) {
            Text(printer.printerName)
            if let m = printer.printerModel { Text(m).foregroundStyle(.secondary) }
            Spacer()
            if printer.dueCount > 0 { StatusBadge(text: "\(printer.dueCount) overdue", color: .red) }
            if printer.warningCount > 0 { StatusBadge(text: "\(printer.warningCount) due soon", color: .orange) }
            if printer.dueCount == 0 && printer.warningCount == 0 { StatusBadge(text: "All good", color: .green) }
        }
        .textCase(nil)
    }
}

struct MaintenanceItemRow: View {
    let item: MaintenanceItemStatus
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: MaintenanceIcons.symbol(for: item.maintenanceTypeIcon))
                .font(.body)
                .foregroundStyle(item.statusColor)
                .frame(width: 34, height: 34)
                .background(item.statusColor.opacity(0.14), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(item.maintenanceTypeName).foregroundStyle(item.enabled ? .primary : .secondary)
                    if item.isDaysBased { Image(systemName: "calendar").font(.caption2).foregroundStyle(.secondary) }
                }
                ProgressView(value: item.progress).tint(item.statusColor)
                Label(item.statusText, systemImage: item.statusSymbol)
                    .font(.caption)
                    .foregroundStyle(item.statusColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Mark performed

struct MaintenancePerformSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let item: MaintenanceItemStatus
    var onDone: () -> Void

    @State private var notes = ""
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Printer", value: item.printerName)
                    LabeledContent("Task", value: item.maintenanceTypeName)
                    LabeledContent("Status") { Text(item.statusText).foregroundStyle(item.statusColor) }
                }
                Section {
                    TextField("What was done, parts used…", text: $notes, axis: .vertical).lineLimit(3...8)
                } header: {
                    Text("Notes (optional)")
                } footer: {
                    Text("Resets the counter to now and logs it in the history.")
                }
            }
            .navigationTitle("Mark as Done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await perform() } }.disabled(runner.isRunning)
                }
            }
            .actionAlerts(runner)
        }
        .presentationDetents([.medium, .large])
    }

    private func perform() async {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        await runner.run(nil) {
            let body: [String: JSONValue] = ["notes": trimmed.isEmpty ? .null : .string(trimmed)]
            let _: MaintenanceItemStatus = try await session.client.send(.post, "maintenance/items/\(item.id)/perform", body: body)
        }
        if runner.errorMessage == nil { onDone(); dismiss() }
    }
}
