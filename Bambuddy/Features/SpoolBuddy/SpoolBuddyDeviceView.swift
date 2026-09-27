import SwiftUI

/// Live dashboard for one SpoolBuddy station: scale, current tag and spool actions.
struct SpoolBuddyDeviceView: View {
    @Environment(AppSession.self) private var session
    @Environment(SpoolBuddyLiveState.self) private var liveState
    @Environment(SpoolBuddyStore.self) private var store
    let deviceId: String

    @State private var runner = ActionRunner()
    @State private var showLink = false
    @State private var showAssign = false
    @State private var confirmQuickAdd = false

    private var device: SpoolBuddyDevice? { store.devices.value?.first { $0.deviceId == deviceId } }
    private var reading: SpoolBuddyLiveState.Reading? { liveState.readings[deviceId] }

    /// Inventory record for the spool on the reader (fresher than the event payload).
    private var currentSpool: SpoolBuddySpool? {
        if let m = liveState.matched[deviceId] { return store.spool(m.id) ?? store.spool(tag: m.tagUid) }
        return nil
    }

    var body: some View {
        Group {
            if let device {
                content(device)
            } else if store.devices.value != nil {
                ContentUnavailableView("Station Removed", systemImage: "sensor.tag.radiowaves.forward")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(device?.displayName ?? "Station")
        .navigationBarTitleDisplayMode(.inline)
        .actionAlerts(runner)
        .toolbar {
            if device != nil {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: SpoolBuddyRoute.settings(deviceId)) { Label("Station Settings", systemImage: "gearshape") }
                }
            }
        }
        .sheet(isPresented: $showLink) {
            SpoolBuddySpoolPicker(title: "Link Tag to Spool", onlyUntagged: true) { spool in
                Task { await link(spool) }
            }
        }
        .sheet(isPresented: $showAssign) {
            if let spoolId = currentSpool?.id ?? liveState.matched[deviceId]?.id {
                SpoolBuddySlotPicker(spoolId: spoolId)
            }
        }
        .confirm("Add a new spool for this tag?", isPresented: $confirmQuickAdd,
                 message: "Creates a basic 1 kg PLA spool linked to this tag. Edit its brand, material and color later in Inventory.",
                 action: "Add Spool", role: nil) {
            Task { await quickAdd() }
        }
    }

    @ViewBuilder
    private func content(_ device: SpoolBuddyDevice) -> some View {
        let online = liveState.isOnline(device)
        List {
            if !online {
                Section {
                    Label("This station is offline. Live weight and tag scans resume when it reconnects.", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
            }
            if device.hasScale {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        SpoolBuddyWeightText(reading: online ? reading : nil, font: .system(size: 52, weight: .semibold, design: .rounded))
                        if let m = liveState.matched[deviceId], let r = reading {
                            Text("≈ \(Fmt.grams(max(0, r.grams - m.coreWeight))) of filament (minus \(Fmt.grams(m.coreWeight)) spool)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    if session.can("inventory:update") {
                        Button { Task { await tare() } } label: { Label("Tare (Set Zero)", systemImage: "scalemass") }
                            .disabled(!online)
                        NavigationLink(value: SpoolBuddyRoute.calibration(deviceId)) { Label("Calibrate Scale", systemImage: "dial.medium") }
                    }
                } header: {
                    Text("Scale")
                }
            }
            tagSection(device, online: online)
            Section("Station") {
                LabeledContent("Status") {
                    StatusBadge(text: online ? "Online" : "Offline", color: online ? .green : .secondary)
                }
                if device.hasNfc {
                    LabeledContent("NFC Reader", value: device.nfcOk ? "Ready" : "Not responding")
                }
                if device.hasScale {
                    LabeledContent("Scale", value: device.scaleOk ? "Ready" : "Not responding")
                }
                InfoRow("Address", device.ipAddress)
                InfoRow("Daemon Version", device.firmwareVersion)
                InfoRow("Uptime", Fmt.duration(seconds: Double(device.uptimeS)))
                InfoRow("Last Seen", device.lastSeen.map { Fmt.relative($0) })
                if let pending = device.pendingCommand, !pending.isEmpty {
                    InfoRow("Pending Command", pending.replacingOccurrences(of: "_", with: " ").capitalized)
                }
            }
        }
        .refreshable {
            await store.loadDevices(session)
            await store.loadSpools(session)
        }
    }

    @ViewBuilder
    private func tagSection(_ device: SpoolBuddyDevice, online: Bool) -> some View {
        if let m = liveState.matched[deviceId] {
            Section {
                HStack(spacing: 14) {
                    ColorSwatch(hex: currentSpool?.hexColor ?? m.hexColor, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentSpool?.title ?? (m.title.isEmpty ? "Spool #\(m.id)" : m.title)).font(.headline)
                        if let c = currentSpool?.colorName ?? m.colorName { Text(c).font(.subheadline).foregroundStyle(.secondary) }
                        Text("Tag \(m.tagUid)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                let label = currentSpool?.labelWeight ?? m.labelWeight
                let used = currentSpool?.weightUsed ?? m.weightUsed
                if label > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Remaining")
                            Spacer()
                            Text("\(Fmt.grams(max(0, label - used))) of \(Fmt.grams(label))").foregroundStyle(.secondary)
                        }
                        ProgressView(value: min(1, max(0, (label - used) / label)))
                    }
                }
                if let spool = currentSpool, let loc = store.location(of: spool, printers: session.printers) {
                    LabeledContent("Loaded In", value: loc)
                }
                if session.can("inventory:update") {
                    if let r = reading, device.hasScale {
                        Button { Task { await syncWeight(spoolId: m.id, grams: r.grams) } } label: {
                            Label("Save Scale Weight to Spool (\(Fmt.grams(r.grams)))", systemImage: "arrow.down.doc")
                        }
                        .disabled(!r.stable)
                    }
                    Button { showAssign = true } label: { Label("Assign to AMS Slot", systemImage: "tray.and.arrow.down") }
                    NavigationLink(value: SpoolBuddyRoute.writeTag(m.id)) { Label("Rewrite Tag", systemImage: "wave.3.right.circle") }
                }
            } header: {
                Text("Spool on Reader")
            } footer: {
                if let r = reading, !r.stable { Text("Waiting for the scale to settle before saving the weight.") }
            }
        } else if let u = liveState.unknown[deviceId] {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unrecognized Tag").font(.headline)
                        Text(u.identifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let t = u.tagType { Text(t).font(.caption).foregroundStyle(.secondary) }
                    }
                } icon: {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).font(.title2)
                }
                if session.can("inventory:update") {
                    Button { showLink = true } label: { Label("Link to Existing Spool", systemImage: "link") }
                }
                if session.can("inventory:create") {
                    Button { confirmQuickAdd = true } label: { Label("Add as New Spool", systemImage: "plus.circle") }
                }
            } header: {
                Text("Tag on Reader")
            } footer: {
                Text("This tag isn't linked to a spool in your inventory yet.")
            }
        } else if device.hasNfc {
            Section("Tag on Reader") {
                Label(online ? "Place a spool on the station to identify it." : "Waiting for the station to reconnect.", systemImage: "sensor.tag.radiowaves.forward")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func tare() async {
        await runner.run("Tare sent to station") {
            let _: SpoolBuddyAck = try await session.client.send(.post, "spoolbuddy/devices/\(deviceId)/calibration/tare")
        }
    }

    private func syncWeight(spoolId: Int, grams: Double) async {
        await runner.run("Spool weight updated") {
            try await store.syncWeight(session, spoolId: spoolId, grams: grams)
        }
    }

    private func link(_ spool: SpoolBuddySpool) async {
        guard let u = liveState.unknown[deviceId] else { return }
        await runner.run("Tag linked to \(spool.title)") {
            try await store.linkTag(session, spoolId: spool.id, tagUid: u.tagUid, trayUuid: u.tagUid == nil ? u.trayUuid : nil)
        }
    }

    private func quickAdd() async {
        guard let u = liveState.unknown[deviceId] else { return }
        await runner.run("Spool added") {
            try await store.quickAdd(session, tag: u, scaleGrams: reading?.stable == true ? reading?.grams : nil)
        }
    }
}

// MARK: - Spool picker

/// Searchable list of inventory spools.
struct SpoolBuddySpoolPicker: View {
    @Environment(AppSession.self) private var session
    @Environment(SpoolBuddyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let title: String
    var onlyUntagged = false
    var onPick: (SpoolBuddySpool) -> Void

    @State private var search = ""
    @State private var untaggedOnly = true

    private var filtered: [SpoolBuddySpool] {
        store.spools.filter { spool in
            (!onlyUntagged || !untaggedOnly || !spool.isTagged) &&
            (search.isEmpty || [spool.title, spool.colorName ?? "", spool.storageLocation ?? "", "#\(spool.id)"]
                .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if onlyUntagged {
                    Toggle("Only Spools Without a Tag", isOn: $untaggedOnly)
                }
                if store.spoolsLoaded && filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Spools" : "No Matches", systemImage: "circle.circle",
                                           description: Text(search.isEmpty ? "Add spools in Inventory first." : "No spools match “\(search)”."))
                }
                ForEach(filtered) { spool in
                    Button {
                        onPick(spool)
                        dismiss()
                    } label: {
                        SpoolBuddySpoolRow(spool: spool, location: nil)
                    }
                    .tint(.primary)
                }
            }
            .overlay { if !store.spoolsLoaded { ProgressView() } }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Material, brand or color")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { if !store.spoolsLoaded { await store.loadSpools(session) } }
        }
    }
}

struct SpoolBuddySpoolRow: View {
    let spool: SpoolBuddySpool
    let location: String?

    var body: some View {
        HStack(spacing: 12) {
            ColorSwatch(hex: spool.hexColor, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(spool.title).font(.body.weight(.medium)).lineLimit(1)
                    Text("#\(spool.id)").font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    if let c = spool.colorName, !c.isEmpty { Text(c) }
                    if let r = spool.remaining { Text("\(Fmt.grams(r)) left") }
                    if let w = spool.lastScaleWeight { Label(Fmt.grams(w), systemImage: "scalemass").labelStyle(.titleAndIcon) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let location { Label(location, systemImage: "tray").font(.caption).foregroundStyle(.secondary) }
                if let f = spool.remainingFraction {
                    ProgressView(value: f).tint(f < 0.15 ? .red : f < 0.3 ? .orange : .accentColor)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: spool.isTagged ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                .foregroundStyle(spool.isTagged ? Color.accentColor : .secondary.opacity(0.5))
                .accessibilityLabel(spool.isTagged ? "Has NFC tag" : "No NFC tag")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - AMS slot picker

/// Picks a printer AMS / external slot for a spool and assigns it.
struct SpoolBuddySlotPicker: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    @Environment(SpoolBuddyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let spoolId: Int

    @State private var printerId: Int?
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            List {
                Picker("Printer", selection: $printerId) {
                    ForEach(printers.printers) { Text($0.name).tag(Optional($0.id)) }
                }
                if let id = printerId {
                    SpoolBuddySlotSections(printerId: id) { amsId, trayId in
                        Task { await assign(printerId: id, amsId: amsId, trayId: trayId) }
                    }
                }
            }
            .navigationTitle("Assign to Slot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .actionAlerts(runner)
            .onAppear {
                if printerId == nil {
                    printerId = printers.printers.first { printers.statuses[$0.id]?.connected == true }?.id ?? printers.printers.first?.id
                }
            }
        }
    }

    private func assign(printerId: Int, amsId: Int, trayId: Int) async {
        await runner.run {
            let pending = try await store.assign(session, spoolId: spoolId, printerId: printerId, amsId: amsId, trayId: trayId)
            runner.successMessage = pending ? "Assigned — the slot configures when the spool is inserted" : "Assigned"
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }
}

/// Sections listing a printer's AMS units and external spool holders as tappable slots.
struct SpoolBuddySlotSections: View {
    @Environment(PrinterStore.self) private var printers
    @Environment(SpoolBuddyStore.self) private var store
    let printerId: Int
    var onSelect: (Int, Int) -> Void

    var body: some View {
        let status = printers.statuses[printerId]
        let units = status?.ams ?? []
        if status?.connected == false {
            Section { Label("Printer is offline; slot contents may be out of date.", systemImage: "wifi.slash").foregroundStyle(.secondary) }
        }
        ForEach(units) { unit in
            Section(unit.label) {
                ForEach(unit.tray ?? []) { tray in
                    slotButton(amsId: unit.id, trayId: tray.id, tray: tray, label: unit.id >= 128 ? unit.label : "Slot \(tray.id + 1)")
                }
            }
        }
        let externals = status?.vtTray ?? []
        if !externals.isEmpty {
            Section("External Spool") {
                // External holders are addressed as AMS 255, slot (tray id - 254): Ext-L = 254, Ext-R = 255.
                ForEach(externals.sorted { $0.id < $1.id }) { tray in
                    let slot = max(0, tray.id - 254)
                    slotButton(amsId: 255, trayId: slot, tray: tray, label: externals.count > 1 ? (slot == 0 ? "Left" : "Right") : "External")
                }
            }
        } else if units.isEmpty {
            Section { Text("No AMS or external slots reported by this printer.").foregroundStyle(.secondary) }
        }
    }

    private func slotButton(amsId: Int, trayId: Int, tray: AMSTray, label: String) -> some View {
        let assigned = store.assignedSpool(printerId: printerId, amsId: amsId, trayId: trayId)
        return Button {
            onSelect(amsId, trayId)
        } label: {
            HStack(spacing: 12) {
                ColorSwatch(hex: tray.isEmpty ? nil : tray.trayColor, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).foregroundStyle(.primary)
                    Text(tray.isEmpty ? "Empty" : tray.displayName).font(.caption).foregroundStyle(.secondary)
                    if let assigned { Label(assigned.title, systemImage: "link").font(.caption).foregroundStyle(Color.accentColor) }
                }
                Spacer()
                if let r = tray.remain, r >= 0, !tray.isEmpty { Text("\(r)%").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
