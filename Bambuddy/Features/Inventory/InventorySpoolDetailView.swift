import SwiftUI
import Charts

struct InventorySpoolDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(InventoryStore.self) private var store
    @Environment(PrinterStore.self) private var printers
    @Environment(LiveUpdates.self) private var live
    @Environment(\.dismiss) private var dismiss
    let spoolId: Int

    @State private var runner = ActionRunner()
    @State private var usage = Loader<[InventoryUsageRecord]>()
    @State private var presets = Loader<[InventorySpoolFilamentPreset]>()
    @State private var formRequest: InventoryFormRequest?
    @State private var showLabels = false
    @State private var showAdjust = false
    @State private var showAssign = false
    @State private var confirmDelete = false
    @State private var confirmArchive = false
    @State private var confirmReset = false
    @State private var confirmClearHistory = false
    @State private var confirmClearTag = false
    @State private var confirmUnassign = false

    private var canEdit: Bool { session.can("inventory:update") }

    var body: some View {
        Group {
            if let spool = store.spool(spoolId) {
                content(spool)
            } else if store.isLoading || !store.hasLoaded {
                ProgressView()
            } else {
                ContentUnavailableView("Spool Not Found", systemImage: "questionmark.circle", description: Text("Spool #\(spoolId) no longer exists."))
            }
        }
        .navigationTitle(store.spool(spoolId).map { "#\($0.id) \($0.materialLine)" } ?? "Spool")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: live.revision("inventory_changed", "spool_usage_logged")) { await loadExtras() }
        .refreshable { await store.load(); await loadExtras() }
        .actionAlerts(runner)
    }

    private func loadExtras() async {
        guard store.spool(spoolId) != nil, !store.isDemo else { return }
        if !store.isSpoolman {
            await usage.load { try await store.usage(spoolId) }
        }
        await presets.load { try await store.filamentPresets(spoolId) }
    }

    @ViewBuilder
    private func content(_ spool: InventorySpool) -> some View {
        let slot = store.slot(for: spool.id)
        List {
            Section {
                header(spool)
                    .listRowInsets(EdgeInsets())
            }
            if canEdit {
                Section {
                    HStack(spacing: 10) {
                        quickAction("Edit", "pencil") { formRequest = .edit(spool.id) }
                        quickAction("Weight", "scalemass") { showAdjust = true }
                        quickAction("Label", "printer") { showLabels = true }
                        if !spool.isArchived {
                            quickAction(slot == nil ? "Assign" : "Move", "tray.and.arrow.down") { showAssign = true }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                }
            }
            slotSection(spool, slot: slot)
            filamentSection(spool)
            weightSection(spool)
            inventorySection(spool)
            tagSection(spool)
            profilesSection(spool)
            if !store.isSpoolman { usageSection(spool) }
            datesSection(spool)
            if let note = spool.note, !note.isEmpty {
                Section("Note") { Text(note).textSelection(.enabled) }
            }
            if canEdit { dangerSection(spool) }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if canEdit {
                        Button { formRequest = .edit(spool.id) } label: { Label("Edit", systemImage: "pencil") }
                        Button { formRequest = .copy(spool.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button { showAdjust = true } label: { Label("Adjust Remaining…", systemImage: "scalemass") }
                    }
                    Button { showLabels = true } label: { Label("Print Label…", systemImage: "printer") }
                    if canEdit && !spool.isArchived {
                        Button { showAssign = true } label: { Label("Assign to Printer Slot…", systemImage: "tray.and.arrow.down") }
                    }
                } label: { Label("Actions", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: $formRequest) { InventorySpoolFormView(request: $0) }
        .sheet(isPresented: $showLabels) { InventoryLabelSheet(spoolIds: [spool.id]) }
        .sheet(isPresented: $showAdjust) { InventoryAdjustWeightSheet(spool: spool) }
        .sheet(isPresented: $showAssign) { InventoryAssignSlotSheet(spool: spool) }
        .confirm("Delete this spool?", isPresented: $confirmDelete, message: "The spool and its usage history are removed permanently.") {
            Task {
                await runner.run { try await store.delete(spool.id) }
                if runner.errorMessage == nil { dismiss() }
            }
        }
        .confirm("Archive this spool?", isPresented: $confirmArchive, message: "Archived spools are hidden from the active list and can be restored later.", action: "Archive") {
            Task { await runner.run("Spool archived") { try await store.archive(spool.id) } }
        }
        .confirm("Reset the consumed counter?", isPresented: $confirmReset, message: "The counter restarts at zero; the remaining weight is unchanged.", action: "Reset") {
            Task { await runner.run("Counter reset") { try await store.resetConsumedCounter(spool.id) } }
        }
        .confirm("Clear usage history?", isPresented: $confirmClearHistory, message: "All usage records for this spool are deleted.", action: "Clear") {
            Task {
                await runner.run("History cleared") { try await store.clearUsage(spool.id) }
                await loadExtras()
            }
        }
        .confirm("Clear the RFID tag link?", isPresented: $confirmClearTag, message: "The spool will no longer be recognized automatically when the tag is scanned.", action: "Clear Tag") {
            Task { await runner.run("RFID tag cleared") { try await store.clearTag(spool.id) } }
        }
        .confirm("Unassign this spool?", isPresented: $confirmUnassign, message: "The spool is removed from its printer slot. The slot's filament settings on the printer are not changed.", action: "Unassign") {
            if let slot {
                Task { await runner.run("Spool unassigned") { try await store.unassign(spoolId: spool.id, slot: slot) } }
            }
        }
    }

    // MARK: Sections

    private func header(_ spool: InventorySpool) -> some View {
        VStack(spacing: 0) {
            ZStack {
                InventorySpoolBanner(spool: spool, height: 72)
                Text(spool.colorName?.isEmpty == false ? spool.colorName! : "No color name")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(.white.opacity(0.9), in: .capsule)
                    .foregroundStyle(.black)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spool.materialLine).font(.title2.weight(.bold))
                        Text(InventoryFormat.joined([spool.brand, spool.slicerFilamentName])).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        if spool.isArchived { StatusBadge(text: "Archived", color: .secondary) }
                        if spool.isLowStock(globalThreshold: store.lowStockThreshold) && !spool.isArchived { StatusBadge(text: "Low Stock", color: .red) }
                        if spool.weightLocked == true { StatusBadge(text: "Weight Locked", color: .orange) }
                    }
                }
                InventoryRemainingBar(percent: spool.remainingPercent, height: 10)
                HStack {
                    metric("Remaining", InventoryFormat.grams(spool.remainingGrams))
                    Spacer()
                    metric("Percent", "\(Int(spool.remainingPercent.rounded()))%")
                    Spacer()
                    metric("Used", InventoryFormat.grams(spool.used))
                    Spacer()
                    metric("Label", InventoryFormat.grams(spool.label))
                }
            }
            .padding()
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
    }

    private func quickAction(_ title: String, _ image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: image).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func slotSection(_ spool: InventorySpool, slot: InventorySlotLocation?) -> some View {
        Section("Printer Slot") {
            if let slot {
                let tray = trayFor(slot)
                HStack(spacing: 12) {
                    InventorySpoolSwatch(rgba: tray?.trayColor ?? spool.rgba, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.printerName ?? printers.printer(slot.printerId)?.name ?? "Printer \(slot.printerId)").font(.headline)
                        Text(InventoryFormat.joined([slot.slotLabel, slot.amsLabel, tray.map { $0.isEmpty ? "Slot empty" : "\($0.trayType ?? "") \($0.remain.map { $0 >= 0 ? "· \($0)% AMS" : "" } ?? "")" }]))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if slot.pendingConfig { StatusBadge(text: "Pending", color: .orange) }
                }
                if slot.pendingConfig {
                    Text("The slot will be configured on the printer once filament is inserted.").font(.footnote).foregroundStyle(.secondary)
                }
                if canEdit {
                    Button("Unassign", role: .destructive) { confirmUnassign = true }
                }
            } else {
                Text(spool.isArchived ? "Archived spools can't be assigned." : "Not loaded in any printer.").foregroundStyle(.secondary)
                if canEdit && !spool.isArchived {
                    Button { showAssign = true } label: { Label("Assign to Printer Slot…", systemImage: "tray.and.arrow.down") }
                }
            }
        }
    }

    private func trayFor(_ slot: InventorySlotLocation) -> AMSTray? {
        guard let status = printers.statuses[slot.printerId] else { return nil }
        if slot.isExternal { return status.vtTray?.first { $0.id == 254 + slot.trayId } ?? status.vtTray?.first }
        return status.ams?.first { $0.id == slot.amsId }?.tray?.first { $0.id == slot.trayId }
    }

    private func filamentSection(_ spool: InventorySpool) -> some View {
        Section("Filament") {
            InfoRow("Material", spool.material)
            InfoRow("Subtype", spool.subtype)
            InfoRow("Brand", spool.brand)
            LabeledContent("Color") {
                HStack(spacing: 8) {
                    Text(InventoryFormat.joined([spool.colorName, spool.rgba.map { "#\($0)" }]))
                        .textSelection(.enabled)
                    InventorySpoolSwatch(spool: spool, size: 22)
                }
            }
            if !spool.extraColorStops.isEmpty {
                LabeledContent("Gradient") {
                    HStack(spacing: 4) {
                        ForEach(spool.extraColorStops, id: \.self) { InventorySpoolSwatch(rgba: $0, size: 18) }
                    }
                }
            }
            if let effect = spool.effectType, !effect.isEmpty { InfoRow("Effect", effect.capitalized) }
            InfoRow("Slicer Preset", InventoryFormat.joined([spool.slicerFilamentName, spool.slicerFilament.map { "(\($0))" }], separator: " "))
            if spool.nozzleTempMin != nil || spool.nozzleTempMax != nil {
                InfoRow("Nozzle Temperature", "\(spool.nozzleTempMin.map(String.init) ?? "?")–\(spool.nozzleTempMax.map(String.init) ?? "?") °C")
            }
        }
    }

    private func weightSection(_ spool: InventorySpool) -> some View {
        Section {
            InfoRow("Label Weight", InventoryFormat.grams(spool.label))
            InfoRow("Empty Spool", InventoryFormat.joined([InventoryFormat.grams(spool.core), store.catalogEntry(spool.coreWeightCatalogId)?.name]))
            InfoRow("Used", InventoryFormat.grams(spool.used))
            InfoRow("Remaining", "\(InventoryFormat.grams(spool.remainingGrams)) (\(Int(spool.remainingPercent.rounded()))%)")
            InfoRow("Expected Gross Weight", InventoryFormat.grams(spool.grossGrams))
            InfoRow("Consumed Counter", InventoryFormat.grams(spool.consumedGrams))
            if let scale = spool.lastScaleWeight {
                InfoRow("Last Scale Reading", "\(InventoryFormat.grams(scale))\(spool.lastWeighedAt.map { " · \(Fmt.relative($0))" } ?? "")")
                let delta = scale - spool.grossGrams
                if abs(delta) >= 1 {
                    LabeledContent("Scale Difference") {
                        Text("\(delta > 0 ? "+" : "")\(Int(delta.rounded())) g").foregroundStyle(abs(delta) > 20 ? .orange : .secondary)
                    }
                    if canEdit {
                        Button { Task { await runner.run("Synced to scale weight") { try await store.syncToScale(spool) } } } label: {
                            Label("Apply Scale Reading", systemImage: "scalemass.fill")
                        }
                    }
                }
            }
            if spool.addedFull != nil { InfoRow("Added Full", spool.addedFull == true ? "Yes" : "No") }
        } header: {
            Text("Weight")
        } footer: {
            if spool.weightLocked == true {
                Text("The weight was set manually and is locked against automatic AMS updates.")
            }
        }
    }

    private func inventorySection(_ spool: InventorySpool) -> some View {
        Section("Inventory") {
            InfoRow("Category", spool.category)
            InfoRow("Low Stock Below", spool.lowStockThresholdPct.map { "\($0)% (spool)" } ?? "\(Int(store.lowStockThreshold))% (global)")
            InfoRow("Storage Location", store.storageLabel(for: spool))
            InfoRow("Cost per kg", spool.costPerKg.map { Fmt.currency($0, code: store.currencyCode) })
            if let cost = spool.costPerKg, cost > 0 {
                InfoRow("Remaining Value", Fmt.currency(cost * spool.remainingGrams / 1000, code: store.currencyCode))
            }
        }
    }

    @ViewBuilder
    private func tagSection(_ spool: InventorySpool) -> some View {
        if spool.hasTag || spool.dataOrigin != nil || spool.tagType != nil {
            Section("Tag") {
                InfoRow("Tag UID", spool.tagUid)
                if let uuid = spool.trayUuid, !uuid.isEmpty { InfoRow("Tray UUID", uuid) }
                InfoRow("Tag Type", spool.tagType)
                InfoRow("Data Origin", spool.dataOrigin)
                if canEdit && spool.hasTag {
                    Button("Clear RFID Tag", role: .destructive) { confirmClearTag = true }
                }
            }
        }
    }

    @ViewBuilder
    private func profilesSection(_ spool: InventorySpool) -> some View {
        let kProfiles = spool.kProfiles ?? []
        let filamentPresets = presets.value ?? []
        if !kProfiles.isEmpty || !filamentPresets.isEmpty {
            Section {
                ForEach(kProfiles, id: \.stableId) { k in
                    LabeledContent {
                        Text("K \(k.kValue.formatted(.number.precision(.fractionLength(3))))").monospacedDigit()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.name ?? "Pressure Advance")
                            Text(InventoryFormat.joined([printers.printer(k.printerId)?.name ?? "Printer \(k.printerId)", k.nozzleDiameter.map { "\($0) mm" }, (k.extruder ?? 0) == 1 ? "Left" : nil]))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(filamentPresets, id: \.self) { p in
                    LabeledContent {
                        Text(p.slicerFilamentName ?? p.slicerFilament ?? "—").multilineTextAlignment(.trailing)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.printerModel)
                            if let d = p.nozzleDiameter { Text("\(d) mm nozzle").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            } header: {
                Text("Printer Profiles")
            } footer: {
                Text("Edit the spool to change its pressure-advance profiles and per-printer presets.")
            }
        }
    }

    @ViewBuilder
    private func usageSection(_ spool: InventorySpool) -> some View {
        Section {
            if let records = usage.value {
                if records.isEmpty {
                    Text("No usage recorded yet.").foregroundStyle(.secondary)
                } else {
                    if records.count > 1 {
                        Chart(records) { r in
                            if let date = APICoders.parseDate(r.createdAt) {
                                BarMark(x: .value("Date", date, unit: .day), y: .value("Grams", r.weightUsed))
                                    .foregroundStyle(by: .value("Status", (r.status ?? "completed").capitalized))
                            }
                        }
                        .chartForegroundStyleScale(["Completed": Color.green, "Failed": Color.red, "Aborted": Color.orange, "Cancelled": Color.orange])
                        .frame(height: 140)
                        .padding(.vertical, 4)
                    }
                    ForEach(records.prefix(25)) { r in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.printName ?? "Print").lineLimit(1)
                                Text(InventoryFormat.joined([Fmt.date(r.createdAt), r.printerId.flatMap { printers.printer($0)?.name }]))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(InventoryFormat.grams(r.weightUsed)).monospacedDigit()
                                HStack(spacing: 4) {
                                    if let cost = r.cost { Text(Fmt.currency(cost, code: store.currencyCode)).font(.caption).foregroundStyle(.secondary) }
                                    StatusBadge(text: (r.status ?? "—").capitalized, color: usageColor(r.status))
                                }
                            }
                        }
                    }
                    if canEdit {
                        Button("Clear History", role: .destructive) { confirmClearHistory = true }
                    }
                }
            } else if let error = usage.error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        } header: {
            Text("Usage History")
        }
    }

    private func usageColor(_ status: String?) -> Color {
        switch status {
        case "completed": .green
        case "failed": .red
        case "aborted", "cancelled": .orange
        default: .secondary
        }
    }

    private func datesSection(_ spool: InventorySpool) -> some View {
        Section("Dates") {
            InfoRow("Added", spool.createdAt.map { Fmt.date($0) })
            if let t = spool.encodeTime { InfoRow("Tag Encoded", Fmt.date(t)) }
            InfoRow("Last Used", spool.lastUsed.map { Fmt.date($0) })
            if let t = spool.updatedAt { InfoRow("Updated", Fmt.date(t)) }
            if let t = spool.archivedAt { InfoRow("Archived", Fmt.date(t)) }
        }
    }

    private func dangerSection(_ spool: InventorySpool) -> some View {
        Section {
            Button { confirmReset = true } label: { Label("Reset Consumed Counter", systemImage: "eraser") }
            if spool.isArchived {
                Button { Task { await runner.run("Spool restored") { try await store.restore(spool.id) } } } label: {
                    Label("Restore Spool", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button { confirmArchive = true } label: { Label("Archive Spool", systemImage: "archivebox") }
            }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Spool", systemImage: "trash") }
        }
    }
}

/// Set a spool's remaining filament directly or from a measured gross weight.
struct InventoryAdjustWeightSheet: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let spool: InventorySpool

    private enum Mode: String, CaseIterable { case remaining = "Remaining", gross = "Scale Weight", used = "Used" }
    @State private var mode: Mode = .gross
    @State private var value: Double?
    @State private var runner = ActionRunner()

    private var computedRemaining: Double? {
        guard let value else { return nil }
        switch mode {
        case .remaining: return value
        case .gross: return value - spool.core
        case .used: return spool.label - value
        }
    }

    private var isValid: Bool {
        guard let r = computedRemaining else { return false }
        return r >= 0 && r <= spool.label
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Enter", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField(placeholder, value: $value, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .font(.title2.monospacedDigit())
                        Text("g").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(footer)
                }
                Section("Result") {
                    InfoRow("Currently Remaining", InventoryFormat.grams(spool.remainingGrams))
                    if let r = computedRemaining {
                        LabeledContent("New Remaining") {
                            Text(isValid ? "\(InventoryFormat.grams(r)) (\(Int((r / max(spool.label, 1) * 100).rounded()))%)" : "Out of range")
                                .foregroundStyle(isValid ? Color.primary : Color.red)
                        }
                    }
                }
            }
            .navigationTitle("Adjust Remaining")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let r = computedRemaining else { return }
                        Task {
                            await runner.run { try await store.setRemaining(spool.id, remainingGrams: r) }
                            if runner.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(!isValid || runner.isRunning)
                }
            }
            .actionAlerts(runner)
        }
        .presentationDetents([.medium, .large])
    }

    private var placeholder: String {
        switch mode {
        case .remaining: "Remaining filament"
        case .gross: "Weight on scale"
        case .used: "Filament used"
        }
    }

    private var footer: String {
        switch mode {
        case .remaining: "Grams of filament left on the spool (0–\(Int(spool.label)) g)."
        case .gross: "Weigh the spool including its empty core (\(Int(spool.core)) g). Valid range \(Int(spool.core))–\(Int(spool.core + spool.label)) g."
        case .used: "Grams consumed so far (0–\(Int(spool.label)) g)."
        }
    }
}
