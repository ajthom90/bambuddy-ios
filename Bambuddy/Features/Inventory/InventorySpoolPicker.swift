import SwiftUI

/// Helpers for matching spools against AMS slots.
enum InventorySlotMatching {
    enum MaterialMatch { case exact, partial, none }

    static func tray(in status: PrinterStatus?, amsId: Int, trayId: Int) -> AMSTray? {
        guard let status else { return nil }
        if amsId == 254 || amsId == 255 {
            return status.vtTray?.first { $0.id == 254 + trayId } ?? (trayId == 0 ? status.vtTray?.first : nil)
        }
        return status.ams?.first { $0.id == amsId }?.tray?.first { $0.id == trayId }
    }

    private static func norm(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespaces).uppercased() }

    static func materialMatch(spool: String?, tray: String?) -> MaterialMatch {
        let a = norm(spool), b = norm(tray)
        guard !a.isEmpty, !b.isEmpty else { return .none }
        if a == b { return .exact }
        if a.contains(b) || b.contains(a) { return .partial }
        return .none
    }

    /// Whether a spool is a plausible fit for the slot's current filament.
    static func fits(_ spool: InventorySpool, tray: AMSTray?) -> Bool {
        guard let tray, !tray.isEmpty else { return true }
        let trayProfile = norm(InventoryPresets.baseName(tray.traySubBrands ?? ""))
        let trayMaterial = norm(tray.trayType)
        guard !trayProfile.isEmpty || !trayMaterial.isEmpty else { return true }
        let spoolProfile = norm(InventoryPresets.baseName(spool.slicerFilamentName ?? spool.slicerFilament ?? ""))
        let spoolMaterial = norm(spool.material)
        if !trayProfile.isEmpty, !spoolProfile.isEmpty, trayProfile == spoolProfile { return true }
        if !trayMaterial.isEmpty, !spoolMaterial.isEmpty { return materialMatch(spool: spoolMaterial, tray: trayMaterial) != .none }
        return spoolProfile.isEmpty && spoolMaterial.isEmpty
    }

    static func slotName(amsId: Int, trayId: Int, status: PrinterStatus?) -> String {
        if amsId == 254 || amsId == 255 { return trayId == 1 ? "External (Right)" : "External Spool" }
        if let unit = status?.ams?.first(where: { $0.id == amsId }) {
            return unit.id >= 128 ? unit.label : "\(unit.label) · Slot \(trayId + 1)"
        }
        return InventorySlotLocation(printerId: 0, amsId: amsId, trayId: trayId).slotLabel
    }
}

/// Picks a spool from the inventory and assigns it to one printer AMS slot.
///
/// Self-contained sheet with its own `NavigationStack`, usable from any feature:
/// `InventorySpoolPicker(printerId: 1, amsId: 0, trayId: 2) { dismiss() }`.
struct InventorySpoolPicker: View {
    @Environment(AppSession.self) private var session
    let printerId: Int
    let amsId: Int
    let trayId: Int
    let onDone: () -> Void

    @State private var store: InventoryStore?

    init(printerId: Int, amsId: Int, trayId: Int, onDone: @escaping () -> Void) {
        self.printerId = printerId
        self.amsId = amsId
        self.trayId = trayId
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            if let store {
                InventorySlotSpoolList(printerId: printerId, amsId: amsId, trayId: trayId, onDone: onDone)
                    .environment(store)
            } else {
                ProgressView()
                    .navigationTitle("Assign Spool")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) } }
                    .task {
                        let s = InventoryStore(session: session)
                        store = s
                    }
            }
        }
    }
}

/// Spool list for one slot (used by `InventorySpoolPicker`).
private struct InventorySlotSpoolList: View {
    @Environment(AppSession.self) private var session
    @Environment(InventoryStore.self) private var store
    @Environment(PrinterStore.self) private var printers
    @Environment(LiveUpdates.self) private var live
    let printerId: Int
    let amsId: Int
    let trayId: Int
    let onDone: () -> Void

    @State private var search = ""
    @State private var showAll = false
    @State private var pending: InventorySpool?
    @State private var confirmUnassign = false
    @State private var confirmCreate = false
    @State private var runner = ActionRunner()

    private var status: PrinterStatus? { printers.statuses[printerId] }
    private var tray: AMSTray? { InventorySlotMatching.tray(in: status, amsId: amsId, trayId: trayId) }
    private var canEdit: Bool { session.can("inventory:update") }

    private var currentSpoolId: Int? {
        store.slotMap.first { $0.value.printerId == printerId && $0.value.amsId == amsId && $0.value.trayId == trayId }?.key
    }

    private var candidates: [InventorySpool] {
        let map = store.slotMap
        return store.spools.filter { spool in
            guard !spool.isArchived else { return false }
            if !showAll {
                if let slot = map[spool.id], !(slot.printerId == printerId && slot.amsId == amsId && slot.trayId == trayId) { return false }
                if !InventorySlotMatching.fits(spool, tray: tray) { return false }
            }
            return spool.matches(search: search)
        }
        .sorted { a, b in
            if (a.id == currentSpoolId) != (b.id == currentSpoolId) { return a.id == currentSpoolId }
            return a.remainingPercent < b.remainingPercent
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    InventorySpoolSwatch(rgba: tray?.isEmpty == false ? tray?.trayColor : nil, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(printers.printer(printerId)?.name ?? "Printer \(printerId)").font(.headline)
                        Text(InventoryFormat.joined([InventorySlotMatching.slotName(amsId: amsId, trayId: trayId, status: status),
                                                     tray.map { $0.isEmpty ? "Empty" : "\($0.displayName) (\($0.trayType ?? "?"))" }]))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let id = currentSpoolId, let spool = store.spool(id) {
                    LabeledContent("Assigned") {
                        Text("#\(spool.id) \(spool.displayName)").lineLimit(1)
                    }
                    if canEdit {
                        Button("Unassign Spool", role: .destructive) { confirmUnassign = true }
                    }
                }
            }
            Section {
                Toggle("Show All Spools", isOn: $showAll)
            } footer: {
                Text(showAll ? "Showing every active spool, including ones assigned to other slots." : "Showing unassigned spools that match the slot's material.")
            }
            Section {
                if !store.hasLoaded {
                    ProgressView()
                } else if candidates.isEmpty {
                    Text(store.spools.isEmpty ? "The inventory is empty." : "No matching spools. Turn on “Show All Spools” to see everything.")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { spool in
                    Button { choose(spool) } label: {
                        HStack {
                            InventorySpoolRow(spool: spool, slot: store.slot(for: spool.id), storage: store.storageLabel(for: spool), lowStockThreshold: store.lowStockThreshold)
                            if spool.id == currentSpoolId { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canEdit || runner.isRunning)
                }
            } header: {
                Text("Spools")
            }
        }
        .searchable(text: $search, prompt: "Search spools")
        .navigationTitle("Assign Spool")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
            if canEdit, let tray, !tray.isEmpty, currentSpoolId == nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { confirmCreate = true } label: { Label("Create Spool from Slot", systemImage: "plus.circle") }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                }
            }
        }
        .overlay { if runner.isRunning { ProgressView().controlSize(.large) } }
        .task(id: live.revision("inventory_changed", "spool_assignment_changed", "spool_auto_assigned")) { await store.load() }
        .confirmationDialog("Material Mismatch", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { spool in
            Button("Assign Anyway") { assign(spool) }
        } message: { spool in
            Text("The spool is \(spool.materialLine) but the slot reports \(tray?.trayType ?? "another material"). The printer may refuse prints that don't match.")
        }
        .confirm("Unassign this spool?", isPresented: $confirmUnassign, message: "The slot's filament settings on the printer are not changed.", action: "Unassign") {
            guard let id = currentSpoolId, let slot = store.slot(for: id) else { return }
            Task { await runner.run("Spool unassigned") { try await store.unassign(spoolId: id, slot: slot) } }
        }
        .confirm("Create a spool from this slot?", isPresented: $confirmCreate, message: "A new inventory spool is created from the filament the printer reports in this slot, and assigned to it.", action: "Create", role: nil) {
            Task {
                await runner.run("Spool created") { try await store.createFromSlot(printerId: printerId, amsId: amsId, trayId: trayId) }
                if runner.errorMessage == nil { await store.loadAssignments() }
            }
        }
        .actionAlerts(runner)
    }

    private func choose(_ spool: InventorySpool) {
        guard spool.id != currentSpoolId else { onDone(); return }
        if let tray, !tray.isEmpty, !store.disableFilamentWarnings,
           InventorySlotMatching.materialMatch(spool: spool.material, tray: tray.trayType) != .exact {
            pending = spool
        } else {
            assign(spool)
        }
    }

    private func assign(_ spool: InventorySpool) {
        Task {
            var pendingConfig = false
            await runner.run {
                let result = try await store.assign(spoolId: spool.id, printerId: printerId, amsId: amsId, trayId: trayId)
                pendingConfig = result?.pendingConfig == true
            }
            guard runner.errorMessage == nil else { return }
            if pendingConfig {
                runner.successMessage = "Assigned — the slot is configured once filament is inserted"
                try? await Task.sleep(for: .seconds(1.2))
            }
            onDone()
        }
    }
}

/// Assign one spool to a printer slot chosen from the printers' AMS layout.
struct InventoryAssignSlotSheet: View {
    @Environment(InventoryStore.self) private var store
    @Environment(PrinterStore.self) private var printers
    @Environment(\.dismiss) private var dismiss
    let spool: InventorySpool

    @State private var printerId: Int?
    @State private var pendingSlot: (amsId: Int, trayId: Int)?
    @State private var showMismatch = false
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        InventorySpoolSwatch(spool: spool, size: 32)
                        VStack(alignment: .leading) {
                            Text("#\(spool.id) \(spool.materialLine)").font(.headline)
                            Text(InventoryFormat.joined([spool.brand, spool.colorName])).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if let slot = store.slot(for: spool.id) {
                        LabeledContent("Currently", value: slot.description)
                    }
                }
                Section {
                    Picker("Printer", selection: $printerId) {
                        Text("Choose…").tag(Int?.none)
                        ForEach(printers.printers) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                }
                if let printerId {
                    slots(printerId)
                }
            }
            .navigationTitle("Assign to Slot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                if printerId == nil { printerId = store.slot(for: spool.id)?.printerId ?? (printers.printers.count == 1 ? printers.printers.first?.id : nil) }
            }
            .confirmationDialog("Material Mismatch", isPresented: $showMismatch, titleVisibility: .visible) {
                Button("Assign Anyway") { if let pendingSlot, let printerId { assign(printerId, pendingSlot.amsId, pendingSlot.trayId) } }
            } message: {
                Text("The slot reports a different material than this \(spool.materialName) spool.")
            }
            .overlay { if runner.isRunning { ProgressView().controlSize(.large) } }
            .actionAlerts(runner)
        }
    }

    @ViewBuilder
    private func slots(_ printerId: Int) -> some View {
        let status = printers.statuses[printerId]
        if let status {
            let units = status.ams ?? []
            if units.isEmpty && (status.vtTray ?? []).isEmpty {
                Section { Text("This printer reports no AMS or external spool holder.").foregroundStyle(.secondary) }
            }
            ForEach(units) { unit in
                Section(unit.label) {
                    ForEach(unit.tray ?? []) { tray in
                        slotButton(printerId: printerId, amsId: unit.id, trayId: tray.id, tray: tray, title: unit.id >= 128 ? unit.label : "Slot \(tray.id + 1)")
                    }
                }
            }
            if let ext = status.vtTray, !ext.isEmpty {
                Section("External") {
                    ForEach(ext) { tray in
                        let t = max(0, tray.id - 254)
                        slotButton(printerId: printerId, amsId: 255, trayId: t, tray: tray, title: ext.count > 1 ? (t == 0 ? "Left" : "Right") : "External Spool")
                    }
                }
            }
        } else {
            Section { Text("Printer status unavailable.").foregroundStyle(.secondary) }
        }
    }

    private func slotButton(printerId: Int, amsId: Int, trayId: Int, tray: AMSTray, title: String) -> some View {
        let occupant = store.slotMap.first { $0.value.printerId == printerId && $0.value.amsId == amsId && $0.value.trayId == trayId }?.key
        return Button {
            if !tray.isEmpty, !store.disableFilamentWarnings, InventorySlotMatching.materialMatch(spool: spool.material, tray: tray.trayType) != .exact {
                pendingSlot = (amsId, trayId)
                showMismatch = true
            } else {
                assign(printerId, amsId, trayId)
            }
        } label: {
            HStack(spacing: 12) {
                InventorySpoolSwatch(rgba: tray.isEmpty ? nil : tray.trayColor, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(tray.isEmpty ? "Empty" : "\(tray.displayName) · \(tray.trayType ?? "")").font(.caption).foregroundStyle(.secondary)
                    if let occupant, let s = store.spool(occupant) {
                        Text("Assigned: #\(s.id) \(s.displayName)").font(.caption).foregroundStyle(occupant == spool.id ? Color.accentColor : .orange).lineLimit(1)
                    }
                }
                Spacer()
                if occupant == spool.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .disabled(occupant == spool.id || runner.isRunning)
    }

    private func assign(_ printerId: Int, _ amsId: Int, _ trayId: Int) {
        Task {
            await runner.run {
                let result = try await store.assign(spoolId: spool.id, printerId: printerId, amsId: amsId, trayId: trayId)
                if result?.pendingConfig == true { runner.successMessage = "Assigned — configured once filament is inserted" }
            }
            if runner.errorMessage == nil {
                try? await Task.sleep(for: .milliseconds(600))
                dismiss()
            }
        }
    }
}
