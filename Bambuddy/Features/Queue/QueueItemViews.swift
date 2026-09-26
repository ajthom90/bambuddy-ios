import SwiftUI

/// Compact row for a queue item (pending, printing or history).
struct QueueItemRow: View {
    let item: QueueItem
    var status: PrinterStatus?
    var uploadPct: Int?
    var showETA = false
    var compact = false

    private var effectiveStatusLabel: (String, Color, String) {
        if item.isPending, let _ = item.waitingReason { return ("Waiting", .purple, "clock") }
        if item.isPrinting, status?.state == "PAUSE" { return ("Paused", .yellow, "pause.circle") }
        let s = item.state
        return (QueueStatusStyle.label(s), QueueItemRow.color(s), QueueStatusStyle.systemImage(s))
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "pending": .orange
        case "printing": .blue
        case "completed": .green
        case "failed": .red
        case "skipped": .orange
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(path: item.thumbnailPath, systemImage: "square.stack.3d.up")
                .frame(width: compact ? 40 : 52, height: compact ? 40 : 52)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.displayName + (item.plateId.map { $0 > 1 ? " · Plate \($0)" : "" } ?? ""))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(compact ? 1 : 2)
                    Spacer(minLength: 4)
                    let s = effectiveStatusLabel
                    StatusBadge(text: s.0, color: s.1)
                }
                metaLine
                if !compact { badges }
                if item.isPrinting, let status { progress(status) }
                if let uploadPct {
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView(value: Double(uploadPct), total: 100)
                        Text("Uploading to printer… \(uploadPct)%").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if item.isPending, let reason = item.waitingReason, !reason.isEmpty {
                    Label(reason, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.purple)
                }
                if item.isPending, item.filamentShort == true {
                    Label("Not enough filament on the assigned spool", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.yellow)
                }
                if !compact, item.archiveHasSlicerAmsMapping == true {
                    Label("Uses the slicer's saved AMS slots", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                }
                if let error = item.errorMessage, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).lineLimit(compact ? 2 : 4)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var targetColor: Color {
        if item.isUnassigned { return .orange }
        if item.isModelBased { return .blue }
        return .secondary
    }

    private var metaLine: some View {
        let parts = HStack(spacing: 10) {
            Label(item.targetLabel, systemImage: "printer").foregroundStyle(targetColor).lineLimit(1)
            if let t = item.printTimeSeconds, t > 0 {
                Label(Fmt.duration(seconds: Double(t)), systemImage: "timer")
            }
            if showETA, let t = item.printTimeSeconds {
                Text("ETA " + Date().addingTimeInterval(Double(t)).formatted(date: .omitted, time: .shortened)).foregroundStyle(.green)
            }
            if let g = item.filamentUsedGrams, g > 0, !compact {
                Label(Fmt.grams(g), systemImage: "scalemass")
            }
            if item.isPending, !item.isStaged {
                Label(scheduleText, systemImage: "clock")
            }
            if item.isHistory, let done = item.completedAt ?? item.createdAt {
                Text(Fmt.relative(done))
            }
        }
        return ViewThatFits(in: .horizontal) {
            parts
            VStack(alignment: .leading, spacing: 2) { parts }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(QueueCompactLabelStyle())
    }

    private var scheduleText: String {
        guard item.hasRealSchedule, let d = item.scheduledDate else { return "ASAP" }
        if d.timeIntervalSinceNow < -60 { return "Overdue" }
        return d.formatted(.relative(presentation: .named))
    }

    @ViewBuilder
    private var badges: some View {
        let tags: [(String, String, Color)] = [
            item.batchName.map { ($0, "shippingbox", Color.cyan) },
            item.isStaged ? ("Staged", "hand.raised", .purple) : nil,
            item.requirePreviousSuccess == true ? ("Requires previous", "arrow.turn.down.right", .orange) : nil,
            item.autoOffAfter == true ? ("Auto power off", "power", .blue) : nil,
            item.gcodeInjection == true ? ("G-code", "chevron.left.forwardslash.chevron.right", .green) : nil,
            item.bedType.flatMap { $0.isEmpty ? nil : ($0, "square.grid.3x3", Color.secondary) },
            item.createdByUsername.flatMap { $0.isEmpty ? nil : ($0, "person", Color.secondary) },
        ].compactMap { $0 }
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.0) { tag in
                        Label(tag.0, systemImage: tag.1)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(tag.2.opacity(0.15), in: .capsule)
                            .foregroundStyle(tag.2)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private func progress(_ status: PrinterStatus) -> some View {
        let active = status.state == "RUNNING" || status.state == "PAUSE"
        let pct = active ? (status.progress ?? 0) : 0
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: min(max(pct, 0), 100), total: 100)
            HStack(spacing: 10) {
                Text("\(Int(pct))%")
                if active, let r = status.remainingTime, r > 0 {
                    Text(Fmt.minutes(r) + " left")
                    Text("ETA " + Date().addingTimeInterval(Double(r) * 60).formatted(date: .omitted, time: .shortened)).foregroundStyle(.green)
                }
                if active, let l = status.layerNum, let t = status.totalLayers, t > 0 { Text("Layer \(l)/\(t)") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct QueueCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - Detail

/// Full details and actions for one queue item.
struct QueueItemDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(LiveUpdates.self) private var live
    @Environment(QueueViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var item: QueueItem
    @State private var editing = false
    @State private var requeueing = false
    @State private var confirm: QueueConfirmAction?
    @State private var plates: QueuePlatesResponse?

    private var client: APIClient { session.client }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    RemoteImage(path: item.thumbnailPath, systemImage: "square.stack.3d.up")
                        .frame(width: 88, height: 88)
                        .clipShape(.rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.displayName).font(.headline)
                        StatusBadge(text: QueueStatusStyle.label(item.state), color: QueueItemRow.color(item.state))
                        if item.archiveDeleted == true {
                            Label("Source archive was deleted", systemImage: "trash").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if item.isPrinting, let pid = item.printerId, let status = store.statuses[pid] {
                    QueueItemRow(item: item, status: status, compact: true)
                }
                if let reason = item.waitingReason, item.isPending { Label(reason, systemImage: "clock").foregroundStyle(.purple) }
                if let error = item.errorMessage, !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            Section("Assignment") {
                InfoRow("Printer", item.targetLabel, systemImage: "printer")
                if let plate = item.plateId {
                    InfoRow("Plate", plates?.plates?.first { $0.index == plate }?.label ?? "Plate \(plate)", systemImage: "square.stack.3d.up")
                }
                if let batch = item.batchName { InfoRow("Batch", batch, systemImage: "shippingbox") }
                if let pos = item.position, item.isPending { InfoRow("Position", "#\(pos)", systemImage: "list.number") }
                if let user = item.createdByUsername { InfoRow("Added by", user, systemImage: "person") }
                if let v = item.variants, v.count > 1 {
                    ForEach(Array(v.enumerated()), id: \.offset) { i, variant in
                        InfoRow("Alternative \(i + 1)", "\(variant.filename ?? "?") · \(variant.targetModel ?? "?")")
                    }
                }
            }
            Section("Timing") {
                if item.isPending { InfoRow("Start", item.isStaged ? "Manual start" : (item.hasRealSchedule ? Fmt.date(item.scheduledTime) : "As soon as possible"), systemImage: "calendar") }
                InfoRow("Added", Fmt.date(item.createdAt), systemImage: "plus.circle")
                if item.startedAt != nil { InfoRow("Started", Fmt.date(item.startedAt), systemImage: "play") }
                if item.completedAt != nil { InfoRow("Finished", Fmt.date(item.completedAt), systemImage: "flag.checkered") }
                if let t = item.printTimeSeconds { InfoRow("Estimated time", Fmt.duration(seconds: Double(t)), systemImage: "timer") }
                if let g = item.filamentUsedGrams { InfoRow("Filament", Fmt.grams(g), systemImage: "scalemass") }
                if let c = item.estimatedCost { InfoRow("Estimated cost", Fmt.number(c, digits: 2), systemImage: "dollarsign.circle") }
            }
            Section("File") {
                if let model = item.slicedForModel { InfoRow("Sliced for", model) }
                if let f = item.filamentType { InfoRow("Filament type", f) }
                if let lh = item.layerHeight { InfoRow("Layer height", "\(Fmt.number(lh, digits: 2)) mm") }
                if let nd = item.nozzleDiameter { InfoRow("Nozzle", "\(Fmt.number(nd, digits: 2)) mm") }
                if let bed = item.bedType { InfoRow("Build plate", bed) }
            }
            Section("Options") {
                InfoRow("Bed leveling", (item.bedLevelling ?? "auto").capitalized)
                InfoRow("Flow calibration", (item.flowCali ?? "auto").capitalized)
                InfoRow("Vibration calibration", (item.vibrationCali ?? true) ? "On" : "Off")
                InfoRow("First layer inspection", (item.layerInspect ?? false) ? "On" : "Off")
                InfoRow("Timelapse", (item.timelapse ?? false) ? "On" : "Off")
                InfoRow("Use AMS", (item.useAms ?? true) ? "On" : "Off")
                if let n = item.nozzleOffsetCali, n != "auto" { InfoRow("Nozzle offset calibration", n.capitalized) }
                if let p = item.preheatOverride, p != "inherit" {
                    InfoRow("Preheat", p.capitalized + (item.preheatChamberTargetOverride.map { " · \($0)°C" } ?? ""))
                }
                InfoRow("Requires previous success", (item.requirePreviousSuccess ?? false) ? "Yes" : "No")
                InfoRow("Power off when done", (item.autoOffAfter ?? false) ? "Yes" : "No")
                if item.gcodeInjection == true { InfoRow("G-code injection", "On") }
            }
            if let mapping = item.amsMapping, !mapping.isEmpty {
                Section("AMS Mapping") {
                    ForEach(Array(mapping.enumerated()), id: \.offset) { i, tray in
                        InfoRow("Slot \(i + 1)", tray < 0 ? "Unmapped" : Self.trayLabel(tray))
                    }
                }
            }
            if let overrides = item.filamentOverrides, !overrides.isEmpty {
                Section("Filament Overrides") {
                    ForEach(Array(overrides.enumerated()), id: \.offset) { _, o in
                        HStack {
                            Text("Slot \(o["slot_id"]?.intValue ?? 0)")
                            Spacer()
                            ColorSwatch(hex: o["color"]?.stringValue, size: 16)
                            Text(o["type"]?.stringValue ?? "?")
                            if o["force_color_match"]?.boolValue == true { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            actionsSection
        }
        .navigationTitle("Queue Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if item.isPending && QueuePermissions.canUpdate(item, session) && item.source != nil {
                Button("Edit") { editing = true }
            }
        }
        .refreshable { await reload() }
        .task(id: live.revision("queue_item_acked", "queue_item_failed", "print_start", "print_complete")) { await reload() }
        .task {
            if let source = item.source, item.archiveDeleted != true {
                plates = try? await client.get("\(source.queueAPIPath)/plates")
            }
        }
        .sheet(isPresented: $editing) {
            if let source = item.source {
                QueueJobForm(source: source, context: .edit(item)) { Task { await reload(); await model.load(client) } }
            }
        }
        .sheet(isPresented: $requeueing) {
            if let source = item.source {
                PrintJobSheet(source: source, mode: .addToQueue) { Task { await model.load(client) } }
            }
        }
        .queueConfirmations($confirm, model: model, client: client, after: { removed in
            if removed { dismiss() } else { Task { await reload() } }
        })
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if item.isPending && item.isStaged && QueuePermissions.canUpdate(item, session) {
                Button { Task { await model.start(item, client: client); await reload() } } label: { Label("Start Print", systemImage: "play.fill") }
            }
            if item.isPending && QueuePermissions.canUpdate(item, session) && item.source != nil {
                Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
            }
            if item.isPending, session.can("queue:reorder") {
                Button { Task { await moveToTop() } } label: { Label("Move to Top", systemImage: "arrow.up.to.line") }
            }
            if item.isPending, let batch = item.batchId, session.can("queue:update_own") || session.can("queue:update_all") {
                Button { Task { await model.ungroup(batchId: batch, client: client); await reload() } } label: { Label("Ungroup Batch", systemImage: "square.stack.3d.down.forward") }
            }
            if item.isHistory, session.can("queue:create"), item.source != nil {
                Button { requeueing = true } label: { Label("Queue Again", systemImage: "arrow.clockwise") }
            }
            if item.isPrinting && QueuePermissions.canUpdate(item, session) {
                Button(role: .destructive) { confirm = .stop(item) } label: { Label("Stop Print", systemImage: "stop.circle") }
            }
            if item.isPending && QueuePermissions.canDelete(item, session) {
                Button(role: .destructive) { confirm = .cancel([item]) } label: { Label("Cancel", systemImage: "xmark.circle") }
            }
            if item.isHistory && QueuePermissions.canDelete(item, session) {
                Button(role: .destructive) { confirm = .remove([item]) } label: { Label("Remove from History", systemImage: "trash") }
            }
        }
    }

    static func trayLabel(_ tray: Int) -> String {
        if tray >= 254 { return tray == 254 ? "External" : "External R" }
        if tray >= 128 { return "AMS HT \(Character(UnicodeScalar(65 + min(tray - 128, 25))!))" }
        let unit = tray / 4, slot = tray % 4
        return "AMS \(Character(UnicodeScalar(65 + min(unit, 25))!)) · Slot \(slot + 1)"
    }

    private func moveToTop() async {
        let pending = (model.items ?? []).filter(\.isPending).sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        guard let first = pending.first, first.id != item.id else { return }
        await model.move([item.id], anchor: first.id, after: false, client: client)
        await reload()
    }

    private func reload() async {
        if let fresh: QueueItem = try? await client.get("queue/\(item.id)") { item = fresh }
    }
}

// MARK: - Confirmations

enum QueueConfirmAction: Identifiable {
    case cancel([QueueItem])
    case stop(QueueItem)
    case remove([QueueItem])

    var id: String {
        switch self {
        case .cancel(let items): "c" + items.map { String($0.id) }.joined(separator: ",")
        case .stop(let item): "s\(item.id)"
        case .remove(let items): "r" + items.map { String($0.id) }.joined(separator: ",")
        }
    }

    var title: String {
        switch self {
        case .cancel(let items): items.count > 1 ? "Cancel \(items.count) queued prints?" : "Cancel queued print?"
        case .stop: "Stop this print?"
        case .remove(let items): items.count > 1 ? "Remove \(items.count) items?" : "Remove from history?"
        }
    }

    var message: String {
        switch self {
        case .cancel(let items): items.count > 1 ? "They will be removed from the queue." : "\"\(items[0].displayName)\" will be removed from the queue."
        case .stop(let item): "\"\(item.displayName)\" will be stopped on the printer. This cannot be undone."
        case .remove(let items): items.count > 1 ? "The items will be deleted from the queue history." : "\"\(items[0].displayName)\" will be deleted from the queue history."
        }
    }

    var button: String {
        switch self {
        case .cancel: "Cancel Print"
        case .stop: "Stop Print"
        case .remove: "Remove"
        }
    }
}

extension View {
    /// Destructive confirmations and the "not enough filament" prompt for queue actions.
    func queueConfirmations(_ action: Binding<QueueConfirmAction?>, model: QueueViewModel, client: APIClient, after: @escaping (_ removed: Bool) -> Void = { _ in }) -> some View {
        modifier(QueueConfirmModifier(action: action, model: model, client: client, after: after))
    }
}

private struct QueueConfirmModifier: ViewModifier {
    @Binding var action: QueueConfirmAction?
    @Bindable var model: QueueViewModel
    let client: APIClient
    let after: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(action?.title ?? "", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible, presenting: action) { a in
                Button(a.button, role: .destructive) {
                    Task {
                        switch a {
                        case .cancel(let items): await model.cancel(items.map(\.id), client: client); after(true)
                        case .stop(let item): await model.stop(item, client: client); after(false)
                        case .remove(let items): await model.remove(items.map(\.id), client: client); after(true)
                        }
                    }
                }
                Button("Keep", role: .cancel) {}
            } message: { a in Text(a.message) }
    }
}

/// Shared alerts for the Queue section's view model (errors, toasts, low-filament prompt).
/// Attached once, at the Queue navigation stack.
struct QueueModelAlerts: ViewModifier {
    @Bindable var model: QueueViewModel
    let client: APIClient

    func body(content: Content) -> some View {
        content
            .alert("Not enough filament", isPresented: Binding(get: { model.filamentShort != nil }, set: { if !$0 { model.filamentShort = nil } })) {
                Button("Print Anyway", role: .destructive) {
                    guard let short = model.filamentShort, let item = model.items?.first(where: { $0.id == short.itemId }) else { return }
                    Task { await model.start(item, skipFilamentCheck: true, client: client) }
                }
                Button("Cancel", role: .cancel) { model.filamentShort = nil }
            } message: {
                let lines = (model.filamentShort?.deficit ?? []).map { d in
                    "Slot \(d.slotId ?? 0)\(d.filamentType.map { " (\($0))" } ?? ""): needs \(Int(d.requiredGrams ?? 0)) g, " +
                        (d.remainingGrams.map { "\(Int($0)) g left" } ?? "remaining unknown")
                }
                Text((["The assigned spools may run out during this print."] + lines).joined(separator: "\n"))
            }
            .actionAlerts(model.runner)
    }
}
