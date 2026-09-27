import SwiftUI

// MARK: - Write tag

/// Encodes a spool's details onto a blank NFC tag using a station's reader.
struct SpoolBuddyWriteTagView: View {
    @Environment(AppSession.self) private var session
    @Environment(SpoolBuddyLiveState.self) private var liveState
    @Environment(SpoolBuddyStore.self) private var store
    let initialSpoolId: Int?

    @State private var deviceId: String?
    @State private var spoolId: Int?
    @State private var showPicker = false
    @State private var waiting = false
    @State private var runner = ActionRunner()

    private var writers: [SpoolBuddyDevice] { (store.devices.value ?? []).filter(\.hasNfc) }
    private var device: SpoolBuddyDevice? { writers.first { $0.deviceId == deviceId } }
    private var spool: SpoolBuddySpool? { spoolId.flatMap { store.spool($0) } }
    private var outcome: SpoolBuddyLiveState.WriteOutcome? { deviceId.flatMap { liveState.writeOutcomes[$0] } }

    var body: some View {
        Form {
            Section {
                if writers.isEmpty {
                    Text("No stations with an NFC reader are registered.").foregroundStyle(.secondary)
                } else {
                    Picker("Station", selection: $deviceId) {
                        ForEach(writers) { d in
                            Text(d.displayName + (liveState.isOnline(d) ? "" : " (offline)")).tag(Optional(d.deviceId))
                        }
                    }
                    .disabled(waiting)
                }
            } header: {
                Text("Station")
            }

            Section("Spool") {
                Button { showPicker = true } label: {
                    if let spool {
                        SpoolBuddySpoolRow(spool: spool, location: store.location(of: spool, printers: session.printers))
                    } else {
                        Label("Choose Spool", systemImage: "circle.circle")
                    }
                }
                .tint(.primary)
                .disabled(waiting)
                if let spool, spool.isTagged {
                    Label("This spool already has a tag. Writing links the new tag instead.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                if waiting {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text("Place a blank NTAG on the reader").font(.headline)
                            Text("Keep it still until writing finishes.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Cancel", role: .cancel) { Task { await cancel() } }
                } else {
                    Button { Task { await write() } } label: { Label("Write Tag", systemImage: "wave.3.right.circle.fill") }
                        .disabled(device == nil || spool == nil || !(device.map(liveState.isOnline) ?? false) || runner.isRunning)
                }
                switch outcome {
                case .written(let id, let uid)?:
                    Label("Tag written\(uid.map { " (\($0))" } ?? "")\(id.map { " for spool #\($0)" } ?? "")", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                case .failed(let message)?:
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case nil:
                    EmptyView()
                }
            } footer: {
                Text("Writes an OpenPrintTag-compatible NDEF record so SpoolBuddy recognizes the spool when it's placed on any station.")
            }
        }
        .navigationTitle("Write Tag")
        .navigationBarTitleDisplayMode(.inline)
        .actionAlerts(runner)
        .sheet(isPresented: $showPicker) {
            SpoolBuddySpoolPicker(title: "Choose Spool") { spoolId = $0.id }
        }
        .onAppear {
            if spoolId == nil { spoolId = initialSpoolId }
            if deviceId == nil { deviceId = (writers.first(where: liveState.isOnline) ?? writers.first)?.deviceId }
        }
        .onChange(of: outcome) { _, new in if new != nil { waiting = false } }
        .onDisappear { if waiting { Task { await cancel() } } }
    }

    private func write() async {
        guard let deviceId, let spoolId else { return }
        struct Body: Encodable { var deviceId: String; var spoolId: Int }
        liveState.clearWriteOutcome(deviceId)
        await runner.run {
            let _: JSONValue = try await session.client.send(.post, "spoolbuddy/nfc/write-tag", body: Body(deviceId: deviceId, spoolId: spoolId))
            waiting = true
        }
    }

    private func cancel() async {
        guard let deviceId else { return }
        waiting = false
        try? await session.client.call(.post, "spoolbuddy/devices/\(deviceId)/cancel-write")
    }
}

// MARK: - AMS slots

/// Printer slot overview for assigning inventory spools to AMS trays.
struct SpoolBuddyAMSView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    @Environment(SpoolBuddyLiveState.self) private var liveState
    @Environment(SpoolBuddyStore.self) private var store

    @State private var printerId: Int?
    @State private var slot: SelectedSlot?

    struct SelectedSlot: Identifiable {
        var printerId: Int, amsId: Int, trayId: Int
        var id: String { "\(printerId)-\(amsId)-\(trayId)" }
    }

    var body: some View {
        List {
            if printers.printers.isEmpty {
                ContentUnavailableView("No Printers", systemImage: "printer", description: Text("Add a printer to assign spools to its slots."))
            } else {
                Picker("Printer", selection: $printerId) {
                    ForEach(printers.printers) { Text($0.name).tag(Optional($0.id)) }
                }
                if let printerId {
                    SpoolBuddySlotSections(printerId: printerId) { amsId, trayId in
                        slot = SelectedSlot(printerId: printerId, amsId: amsId, trayId: trayId)
                    }
                }
            }
        }
        .navigationTitle("AMS Slots")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await printers.refresh()
            await store.loadSpools(session)
        }
        .sheet(item: $slot) { s in
            SpoolBuddySlotSheet(printerId: s.printerId, amsId: s.amsId, trayId: s.trayId)
        }
        .onAppear {
            if printerId == nil {
                printerId = printers.printers.first { printers.statuses[$0.id]?.connected == true }?.id ?? printers.printers.first?.id
            }
        }
    }
}

private struct SpoolBuddySlotSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    @Environment(SpoolBuddyLiveState.self) private var liveState
    @Environment(SpoolBuddyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let printerId: Int, amsId: Int, trayId: Int

    @State private var showPicker = false
    @State private var runner = ActionRunner()

    private var assigned: SpoolBuddySpool? { store.assignedSpool(printerId: printerId, amsId: amsId, trayId: trayId) }

    /// Spools currently sitting on a station's reader — the fastest thing to assign.
    private var onReaders: [SpoolBuddySpool] {
        liveState.matched.values.compactMap { store.spool($0.id) }.filter { $0.id != assigned?.id }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Assigned Spool") {
                    if let assigned {
                        SpoolBuddySpoolRow(spool: assigned, location: nil)
                        if session.can("inventory:update") {
                            Button("Unassign", role: .destructive) { Task { await unassign() } }
                        }
                    } else {
                        Text("No spool assigned").foregroundStyle(.secondary)
                    }
                }
                if session.can("inventory:update") {
                    if !onReaders.isEmpty {
                        Section("On a SpoolBuddy Reader") {
                            ForEach(onReaders) { spool in
                                Button { Task { await assign(spool) } } label: { SpoolBuddySpoolRow(spool: spool, location: nil) }
                                    .tint(.primary)
                            }
                        }
                    }
                    Section {
                        Button { showPicker = true } label: { Label(assigned == nil ? "Assign Spool" : "Replace Spool", systemImage: "circle.circle") }
                    }
                }
            }
            .navigationTitle("\(printers.printer(printerId)?.name ?? "Printer") · \(SpoolBuddyStore.slotLabel(amsId: amsId, trayId: trayId))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .actionAlerts(runner)
            .sheet(isPresented: $showPicker) {
                SpoolBuddySpoolPicker(title: "Choose Spool") { spool in Task { await assign(spool) } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func assign(_ spool: SpoolBuddySpool) async {
        await runner.run {
            let pending = try await store.assign(session, spoolId: spool.id, printerId: printerId, amsId: amsId, trayId: trayId)
            runner.successMessage = pending ? "Assigned — the slot configures when the spool is inserted" : "Assigned \(spool.title)"
        }
    }

    private func unassign() async {
        await runner.run("Unassigned") {
            try await store.unassign(session, printerId: printerId, amsId: amsId, trayId: trayId)
        }
    }
}

// MARK: - Inventory

/// Spool list focused on what SpoolBuddy cares about: weights, tags and where each spool is loaded.
struct SpoolBuddyInventoryView: View {
    @Environment(AppSession.self) private var session
    @Environment(SpoolBuddyStore.self) private var store

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", tagged = "Tagged", untagged = "No Tag", low = "Low"
        var id: String { rawValue }
    }

    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var selected: SpoolBuddySpool?

    private var filtered: [SpoolBuddySpool] {
        store.spools.filter { spool in
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .tagged: spool.isTagged
            case .untagged: !spool.isTagged
            case .low: (spool.remainingFraction ?? 1) < 0.2
            }
            return matchesFilter && (search.isEmpty || [spool.title, spool.colorName ?? "", spool.storageLocation ?? "", "#\(spool.id)"]
                .contains { $0.localizedCaseInsensitiveContains(search) })
        }
        .sorted { ($0.remaining ?? .infinity) < ($1.remaining ?? .infinity) }
    }

    var body: some View {
        List {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            if let error = store.spoolsError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if store.spoolmanMode {
                Label("Showing spools from Spoolman", systemImage: "link").font(.footnote).foregroundStyle(.secondary)
            }
            if store.spoolsLoaded && filtered.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No Spools" : "No Matches", systemImage: "circle.circle")
            }
            ForEach(filtered) { spool in
                Button { selected = spool } label: {
                    SpoolBuddySpoolRow(spool: spool, location: store.location(of: spool, printers: session.printers))
                }
                .tint(.primary)
            }
        }
        .overlay { if !store.spoolsLoaded { ProgressView() } }
        .searchable(text: $search, prompt: "Material, brand or color")
        .navigationTitle("Spools")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.loadSpools(session) }
        .sheet(item: $selected) { spool in
            SpoolBuddySpoolDetailSheet(spoolId: spool.id)
        }
    }
}

private struct SpoolBuddySpoolDetailSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(SpoolBuddyLiveState.self) private var liveState
    @Environment(SpoolBuddyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let spoolId: Int

    @State private var showAssign = false
    @State private var writeTag = false
    @State private var runner = ActionRunner()

    private var spool: SpoolBuddySpool? { store.spool(spoolId) }

    /// A station whose reader currently holds this spool, with a stable weight.
    private var stableReading: (String, Double)? {
        for (deviceId, m) in liveState.matched where m.id == spoolId {
            if let r = liveState.readings[deviceId], r.stable { return (deviceId, r.grams) }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                if let spool {
                    Section {
                        HStack(spacing: 14) {
                            ColorSwatch(hex: spool.hexColor, size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(spool.title).font(.headline)
                                if let c = spool.colorName { Text(c).foregroundStyle(.secondary) }
                            }
                        }
                        if let label = spool.labelWeight {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text("Remaining"); Spacer(); Text("\(Fmt.grams(spool.remaining)) of \(Fmt.grams(label))").foregroundStyle(.secondary) }
                                ProgressView(value: spool.remainingFraction ?? 0)
                            }
                        }
                        InfoRow("Spool Weight", spool.coreWeight.map { Fmt.grams($0) })
                        InfoRow("Last Scale Weight", spool.lastScaleWeight.map { Fmt.grams($0) })
                        InfoRow("Last Weighed", spool.lastWeighedAt.map { Fmt.relative($0) })
                        InfoRow("Loaded In", store.location(of: spool, printers: session.printers))
                        InfoRow("Storage", spool.storageLocation)
                        InfoRow("Tag", spool.tagUid ?? spool.trayUuid)
                        InfoRow("Tag Type", spool.tagType)
                        if let note = spool.note, !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary) }
                    }
                    if session.can("inventory:update") {
                        Section {
                            if let (_, grams) = stableReading {
                                Button { Task { await sync(grams) } } label: {
                                    Label("Save Scale Weight (\(Fmt.grams(grams)))", systemImage: "scalemass")
                                }
                            }
                            Button { showAssign = true } label: { Label("Assign to AMS Slot", systemImage: "tray.and.arrow.down") }
                            Button { writeTag = true } label: { Label(spool.isTagged ? "Write New Tag" : "Write Tag", systemImage: "wave.3.right.circle") }
                        } footer: {
                            if stableReading == nil { Text("Place this spool on a SpoolBuddy station to update its weight from the scale.") }
                        }
                    }
                } else {
                    ContentUnavailableView("Spool Not Found", systemImage: "circle.circle")
                }
            }
            .navigationTitle(spool.map { "Spool #\($0.id)" } ?? "Spool")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .actionAlerts(runner)
            .sheet(isPresented: $showAssign) { SpoolBuddySlotPicker(spoolId: spoolId) }
            .navigationDestination(isPresented: $writeTag) { SpoolBuddyWriteTagView(initialSpoolId: spoolId) }
        }
    }

    private func sync(_ grams: Double) async {
        await runner.run("Spool weight updated") { try await store.syncWeight(session, spoolId: spoolId, grams: grams) }
    }
}
