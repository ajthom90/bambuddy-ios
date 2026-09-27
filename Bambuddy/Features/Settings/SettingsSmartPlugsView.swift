import SwiftUI

/// Settings → Smart Plugs: every configured plug with its live state, an energy
/// summary, bulk on/off, and add/edit/delete.
struct SettingsSmartPlugsView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store
    @Environment(\.openURL) private var openURL

    @State private var loader = Loader<[SettingsSmartPlug]>()
    @State private var statuses: [Int: SettingsSmartPlugStatus] = [:]
    @State private var polled: Set<Int> = []
    @State private var hasPolledOnce = false
    @State private var runner = ActionRunner()
    @State private var editorTarget: SettingsSmartPlugEditorTarget?
    @State private var showDiscovery = false
    @State private var discoveredDevice: SettingsTasmotaDevice?
    @State private var bulkAction: String?
    @State private var plugToDelete: SettingsSmartPlug?
    @State private var plugToTurnOff: SettingsSmartPlug?

    private var plugs: [SettingsSmartPlug] { loader.value ?? [] }
    private var bulkTargets: [SettingsSmartPlug] { plugs.filter { $0.isEnabled && $0.type.isControllable } }

    var body: some View {
        LoadingContent(loader: loader, retry: load) { plugs in
            if plugs.isEmpty {
                emptyState
            } else {
                list(plugs)
            }
        }
        .navigationTitle("Smart Plugs")
        .toolbar { toolbar }
        .task { await load() }
        .task { if !store.hasLoaded { await store.load() } }
        .task(id: plugs.map(\.id)) { await pollStatuses() }
        .sheet(item: $editorTarget) { target in
            SettingsSmartPlugEditor(target: target, existingPlugs: plugs) { await load() }
        }
        .sheet(isPresented: $showDiscovery, onDismiss: {
            if let device = discoveredDevice {
                discoveredDevice = nil
                editorTarget = .add(prefill: device)
            }
        }) {
            NavigationStack {
                SettingsTasmotaDiscoveryView(configuredAddresses: Set(plugs.compactMap(\.ipAddress))) { device in
                    discoveredDevice = device
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { showDiscovery = false } }
                }
            }
        }
        .confirmationDialog(bulkTitle, isPresented: Binding(get: { bulkAction != nil }, set: { if !$0 { bulkAction = nil } }), titleVisibility: .visible) {
            if let action = bulkAction {
                Button(action == "on" ? "Turn All On" : "Turn All Off", role: action == "off" ? .destructive : nil) {
                    Task { await runBulk(action) }
                }
            }
        } message: {
            Text(bulkAction == "off"
                 ? "Every enabled plug will switch off, including any that power a printer that is printing right now."
                 : "Every enabled plug will switch on.")
        }
        .confirmationDialog("Turn Off \(plugToTurnOff?.name ?? "Plug")?", isPresented: Binding(get: { plugToTurnOff != nil }, set: { if !$0 { plugToTurnOff = nil } }), titleVisibility: .visible) {
            if let plug = plugToTurnOff {
                Button("Turn Off", role: .destructive) { Task { await control(plug, "off") } }
            }
        } message: {
            Text("Anything powered by this plug loses power immediately.")
        }
        .confirmationDialog("Delete \(plugToDelete?.name ?? "Plug")?", isPresented: Binding(get: { plugToDelete != nil }, set: { if !$0 { plugToDelete = nil } }), titleVisibility: .visible) {
            if let plug = plugToDelete {
                Button("Delete", role: .destructive) { Task { await delete(plug) } }
            }
        } message: {
            Text("The plug is removed from Bambuddy. The device itself is not changed.")
        }
        .actionAlerts(runner)
    }

    private var bulkTitle: String {
        "Turn \(bulkAction == "on" ? "On" : "Off") \(bulkTargets.count) Plugs?"
    }

    // MARK: Content

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Smart Plugs", systemImage: "powerplug")
        } description: {
            Text("Add a Tasmota, Home Assistant, MQTT or REST plug to switch printers on and off automatically and track their energy use.")
        } actions: {
            if session.can("smart_plugs:create") {
                Button("Add Smart Plug") { editorTarget = .add(prefill: nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .refreshable { await load() }
    }

    private func list(_ plugs: [SettingsSmartPlug]) -> some View {
        List {
            Section {
                energySummary(plugs)
            } header: {
                HStack {
                    Text("Energy")
                    if !hasPolledOnce { ProgressView().controlSize(.mini) }
                }
            } footer: {
                Text("Totals across enabled plugs that are currently reachable. Updates every 10 seconds.")
            }

            Section("Plugs") {
                ForEach(plugs) { plug in
                    row(plug)
                }
            }
        }
        .refreshable {
            await load()
            await refreshStatuses()
        }
    }

    @ViewBuilder
    private func energySummary(_ plugs: [SettingsSmartPlug]) -> some View {
        let summary = SettingsSmartPlugEnergySummary(plugs: plugs, statuses: statuses)
        let cost = store.double("energy_cost_per_kwh") ?? 0
        let currency = store.string("currency", default: "USD")
        if summary.total == 0 {
            Text("Enable at least one plug to see its energy use here.")
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                SettingsSmartPlugTile(title: "Power Now", systemImage: "bolt.fill",
                                      value: summary.totalPower.formatted(.number.precision(.fractionLength(1))), unit: "W",
                                      detail: "\(summary.reachable) of \(summary.total) online")
                SettingsSmartPlugTile(title: "Today", systemImage: "calendar",
                                      value: summary.today.formatted(.number.precision(.fractionLength(3))), unit: "kWh",
                                      detail: costText(summary.today, cost: cost, currency: currency))
                SettingsSmartPlugTile(title: "Yesterday", systemImage: "clock.arrow.circlepath",
                                      value: summary.yesterday.formatted(.number.precision(.fractionLength(3))), unit: "kWh",
                                      detail: costText(summary.yesterday, cost: cost, currency: currency))
                SettingsSmartPlugTile(title: "Lifetime", systemImage: "sum",
                                      value: summary.lifetime.formatted(.number.precision(.fractionLength(1))), unit: "kWh",
                                      detail: costText(summary.lifetime, cost: cost, currency: currency))
            }
            .padding(.vertical, 4)
        }
    }

    private func costText(_ kwh: Double, cost: Double, currency: String) -> String? {
        guard cost > 0 else { return nil }
        return "≈ " + (kwh * cost).formatted(.currency(code: currency.isEmpty ? "USD" : currency))
    }

    private func row(_ plug: SettingsSmartPlug) -> some View {
        let status = statuses[plug.id]
        let printerName = plug.printerId.flatMap { session.printers.printer($0)?.name }
        return SettingsSmartPlugRow(
            plug: plug,
            status: status,
            isPolled: polled.contains(plug.id),
            printerName: printerName,
            canControl: session.can("smart_plugs:control"),
            onSwitch: { on in
                if on { Task { await control(plug, "on") } } else { plugToTurnOff = plug }
            }
        )
        .contentShape(.rect)
        .onTapGesture { if canEdit { editorTarget = .edit(plug) } }
        .swipeActions(edge: .trailing) {
            if session.can("smart_plugs:delete") {
                Button("Delete", systemImage: "trash", role: .destructive) { plugToDelete = plug }
            }
            if canEdit {
                Button("Edit", systemImage: "pencil") { editorTarget = .edit(plug) }.tint(.blue)
            }
        }
        .contextMenu { contextMenu(plug, status: status) }
    }

    private var canEdit: Bool { session.can("smart_plugs:update") }

    @ViewBuilder
    private func contextMenu(_ plug: SettingsSmartPlug, status: SettingsSmartPlugStatus?) -> some View {
        if plug.type.isControllable, session.can("smart_plugs:control") {
            Section {
                Button("Turn On", systemImage: "power") { Task { await control(plug, "on") } }
                Button("Turn Off", systemImage: "poweroff") { plugToTurnOff = plug }
                Button("Toggle", systemImage: "arrow.left.arrow.right") { Task { await control(plug, "toggle") } }
            }
        }
        if canEdit {
            Section {
                Button("Edit", systemImage: "pencil") { editorTarget = .edit(plug) }
                quickToggle(plug, "Show in Switchbar", key: "show_in_switchbar", value: plug.showInSwitchbar ?? false)
                if plug.printerId != nil {
                    quickToggle(plug, "Powers the Printer", key: "controls_printer_power", value: plug.controlsPrinterPower ?? true)
                }
                if plug.type.isControllable {
                    Menu("Automation") {
                        quickToggle(plug, "Enabled", key: "enabled", value: plug.isEnabled)
                        quickToggle(plug, "Auto On", key: "auto_on", value: plug.autoOn ?? true)
                        quickToggle(plug, "Auto Off", key: "auto_off", value: plug.autoOff ?? true)
                        quickToggle(plug, "Off After Drying", key: "auto_off_after_drying", value: plug.autoOffAfterDrying ?? false)
                    }
                }
            }
        }
        if plug.type == .tasmota, let ip = plug.ipAddress, !ip.isEmpty, let url = URL(string: "http://\(ip)/") {
            Button("Open Device Page", systemImage: "safari") { openURL(url) }
        }
        if session.can("smart_plugs:delete") {
            Button("Delete", systemImage: "trash", role: .destructive) { plugToDelete = plug }
        }
    }

    private func quickToggle(_ plug: SettingsSmartPlug, _ title: String, key: String, value: Bool) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: { newValue in
            Task { await patch(plug, [key: .bool(newValue)]) }
        }))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !plugs.isEmpty, bulkTargets.count > 1, session.can("smart_plugs:control") {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Turn All On", systemImage: "power") { bulkAction = "on" }
                    Button("Turn All Off", systemImage: "poweroff") { bulkAction = "off" }
                } label: {
                    if runner.isRunning { ProgressView() } else { Label("All Plugs", systemImage: "bolt.circle") }
                }
                .disabled(runner.isRunning)
            }
        }
        if session.can("smart_plugs:create") {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add Smart Plug", systemImage: "plus") { editorTarget = .add(prefill: nil) }
                    Button("Discover Tasmota Devices", systemImage: "dot.radiowaves.left.and.right") { showDiscovery = true }
                } label: {
                    Label("Add", systemImage: "plus")
                } primaryAction: {
                    editorTarget = .add(prefill: nil)
                }
            }
        }
    }

    // MARK: Data

    private func load() async {
        let client = session.client
        await loader.load { try await client.get("smart-plugs/") }
    }

    /// Polls every plug's live status while the page is visible.
    private func pollStatuses() async {
        while !Task.isCancelled {
            await refreshStatuses()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func refreshStatuses() async {
        let ids = plugs.map(\.id)
        guard !ids.isEmpty else { return }
        let client = session.client
        let results = await withTaskGroup(of: (Int, SettingsSmartPlugStatus?).self) { group in
            for id in ids {
                group.addTask {
                    let status = try? await client.get("smart-plugs/\(id)/status", as: SettingsSmartPlugStatus.self)
                    return (id, status)
                }
            }
            var collected: [(Int, SettingsSmartPlugStatus?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        guard !Task.isCancelled else { return }
        for (id, status) in results {
            statuses[id] = status ?? SettingsSmartPlugStatus(state: nil, reachable: false)
            polled.insert(id)
        }
        hasPolledOnce = true
    }

    private func control(_ plug: SettingsSmartPlug, _ action: String) async {
        let client = session.client
        let previous = statuses[plug.id]
        var optimistic = previous ?? SettingsSmartPlugStatus()
        switch action {
        case "on": optimistic.state = "ON"
        case "off": optimistic.state = "OFF"
        default: optimistic.state = (previous?.isOn ?? false) ? "OFF" : "ON"
        }
        statuses[plug.id] = optimistic
        var failed = false
        await runner.run {
            do {
                try await client.call(.post, "smart-plugs/\(plug.id)/control", body: ["action": action])
            } catch {
                failed = true
                throw error
            }
        }
        if failed { statuses[plug.id] = previous }
        try? await Task.sleep(for: .seconds(1))
        if let status = try? await client.get("smart-plugs/\(plug.id)/status", as: SettingsSmartPlugStatus.self) {
            statuses[plug.id] = status
        }
    }

    private func runBulk(_ action: String) async {
        let targets = bulkTargets
        let client = session.client
        runner.isRunning = true
        let failures = await withTaskGroup(of: Bool.self) { group in
            for plug in targets {
                group.addTask {
                    do {
                        try await client.call(.post, "smart-plugs/\(plug.id)/control", body: ["action": action])
                        return false
                    } catch {
                        return true
                    }
                }
            }
            var count = 0
            for await failed in group where failed { count += 1 }
            return count
        }
        runner.isRunning = false
        if failures == 0 {
            runner.successMessage = action == "on" ? "All plugs turned on" : "All plugs turned off"
        } else {
            runner.errorMessage = "\(failures) of \(targets.count) plugs didn't respond."
        }
        try? await Task.sleep(for: .seconds(1))
        await load()
        await refreshStatuses()
    }

    private func patch(_ plug: SettingsSmartPlug, _ changes: [String: JSONValue]) async {
        let client = session.client
        await runner.run {
            let updated: SettingsSmartPlug = try await client.send(.patch, "smart-plugs/\(plug.id)", body: JSONValue.object(changes))
            if var list = loader.value, let index = list.firstIndex(where: { $0.id == plug.id }) {
                list[index] = updated
                loader.value = list
            }
        }
    }

    private func delete(_ plug: SettingsSmartPlug) async {
        let client = session.client
        await runner.run("Plug deleted") {
            try await client.call(.delete, "smart-plugs/\(plug.id)")
            loader.value?.removeAll { $0.id == plug.id }
            statuses[plug.id] = nil
        }
    }
}

// MARK: - Editor target

/// What the add/edit sheet is opened for.
enum SettingsSmartPlugEditorTarget: Identifiable {
    case add(prefill: SettingsTasmotaDevice?)
    case edit(SettingsSmartPlug)

    var id: String {
        switch self {
        case .add(let device): "add-\(device?.ipAddress ?? "")"
        case .edit(let plug): "edit-\(plug.id)"
        }
    }
}

// MARK: - Row & tiles

private struct SettingsSmartPlugTile: View {
    let title: String
    let systemImage: String
    let value: String
    let unit: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Text(detail ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsSmartPlugRow: View {
    let plug: SettingsSmartPlug
    let status: SettingsSmartPlugStatus?
    let isPolled: Bool
    let printerName: String?
    let canControl: Bool
    let onSwitch: (Bool) -> Void

    private var reachable: Bool { SettingsSmartPlugEnergySummary.isReachable(plug, status) }
    private var isOn: Bool { status?.isOn ?? false }

    private var tint: Color {
        guard isPolled else { return .secondary }
        if !reachable { return .red }
        if plug.type == .mqtt { return .teal }
        return isOn ? .green : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: plug.type.systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.15), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(plug.name).font(.headline).lineLimit(1)
                    if let subtitle = plug.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            badges
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var trailing: some View {
        if !isPolled {
            ProgressView()
        } else if plug.type.isControllable && canControl && reachable {
            Toggle(isOn: Binding(get: { isOn }, set: { onSwitch($0) })) {
                Text(isOn ? "On" : "Off")
            }
            .labelsHidden()
            .accessibilityLabel("\(plug.name) power")
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                StatusBadge(text: stateText, color: tint)
            }
        }
    }

    private var stateText: String {
        if !reachable { return plug.type == .mqtt ? "No Data" : "Offline" }
        if plug.type == .mqtt { return "Receiving" }
        return status?.state?.uppercased() ?? "Unknown"
    }

    private var badges: some View {
        let energy = status?.energy
        return FlowBadges {
            StatusBadge(text: plug.type.shortLabel, color: plug.type == .mqtt ? .teal : .blue)
            if !plug.isEnabled { StatusBadge(text: "Automation Off", color: .orange) }
            if let power = energy?.power, reachable {
                StatusBadge(text: "\(power.formatted(.number.precision(.fractionLength(0...1)))) W", color: .yellow)
            }
            if let today = energy?.today, reachable {
                StatusBadge(text: "\(today.formatted(.number.precision(.fractionLength(0...3)))) kWh today", color: .secondary)
            }
            if let printerName { StatusBadge(text: printerName, color: .indigo) }
            if plug.type == .mqtt { StatusBadge(text: "Monitor Only", color: .teal) }
            if plug.powerAlertEnabled == true { StatusBadge(text: "Alerts", color: .yellow) }
            if plug.scheduleEnabled == true { StatusBadge(text: scheduleText, color: .blue) }
            if plug.showInSwitchbar == true { StatusBadge(text: "Switchbar", color: .secondary) }
        }
    }

    private var scheduleText: String {
        switch (plug.scheduleOnTime, plug.scheduleOffTime) {
        case let (on?, off?): "\(on)–\(off)"
        case let (on?, nil): "On at \(on)"
        case let (nil, off?): "Off at \(off)"
        default: "Schedule"
        }
    }
}

/// Wraps badges onto as many lines as needed.
private struct FlowBadges: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
