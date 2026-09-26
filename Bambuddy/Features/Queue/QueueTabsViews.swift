import SwiftUI
import Charts

// MARK: - History

enum QueueHistorySort: String, CaseIterable, Identifiable {
    case date, name, printer
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct QueueHistoryTab: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(QueueViewModel.self) private var model
    @AppStorage("queue.historySort") private var sort: QueueHistorySort = .date
    @AppStorage("queue.historyNewestFirst") private var newestFirst = true
    @State private var visibleCount = 50
    @State private var confirm: QueueConfirmAction?
    @State private var confirmClear = false
    @State private var requeue: QueueItem?

    private var client: APIClient { session.client }

    private var items: [QueueItem] {
        let list = model.visible(store).filter(\.isHistory)
        let sorted = list.sorted { a, b in
            switch sort {
            case .date:
                let ad = APICoders.parseDate(a.completedAt ?? a.createdAt ?? "") ?? .distantPast
                let bd = APICoders.parseDate(b.completedAt ?? b.createdAt ?? "") ?? .distantPast
                return ad > bd
            case .name: return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            case .printer: return a.targetLabel.localizedStandardCompare(b.targetLabel) == .orderedAscending
            }
        }
        return newestFirst ? sorted : sorted.reversed()
    }

    var body: some View {
        let all = items
        let rows = QueueRow.group(Array(all.prefix(visibleCount)))
        List {
            ForEach(rows) { row in
                switch row {
                case .item(let item):
                    historyRow(item)
                case .batch(_, let name, let children):
                    DisclosureGroup {
                        ForEach(children) { historyRow($0) }
                    } label: {
                        HStack {
                            Label(name, systemImage: "shippingbox").foregroundStyle(.cyan)
                            Spacer()
                            let done = children.filter { $0.state == "completed" }.count
                            let failed = children.filter { $0.state == "failed" }.count
                            if done > 0 { Label("\(done)", systemImage: "checkmark.circle").foregroundStyle(.green) }
                            if failed > 0 { Label("\(failed)", systemImage: "xmark.circle").foregroundStyle(.red) }
                        }
                        .font(.subheadline)
                    }
                }
            }
            if all.count > visibleCount {
                Button("Show More (\(visibleCount) of \(all.count))") { visibleCount += 50 }
            }
        }
        .overlay {
            if model.items == nil { ProgressView() }
            else if all.isEmpty { ContentUnavailableView("No History", systemImage: "clock.arrow.circlepath", description: Text("Finished, failed and cancelled queue items appear here.")) }
        }
        .refreshable { await model.load(client) }
        .onChange(of: sort) { _, _ in visibleCount = 50 }
        .onChange(of: model.locationFilter) { _, _ in visibleCount = 50 }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(QueueHistorySort.allCases) { Text($0.title).tag($0) } }
                    Button { newestFirst.toggle() } label: {
                        Label(newestFirst ? "Descending" : "Ascending", systemImage: newestFirst ? "arrow.down" : "arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) { confirmClear = true } label: { Label("Clear History", systemImage: "trash") }
                        .disabled(all.isEmpty || !session.can("queue:delete_all"))
                } label: { Label("Options", systemImage: "ellipsis.circle") }
            }
        }
        .confirm("Clear history?", isPresented: $confirmClear, message: "Deletes \(all.count) finished queue items. Items a batch order still needs are kept.", action: "Clear History") {
            Task { await model.remove(all.map(\.id), client: client) }
        }
        .queueConfirmations($confirm, model: model, client: client)
        .sheet(item: $requeue) { item in
            if let source = item.source {
                PrintJobSheet(source: source, mode: .addToQueue) { Task { await model.load(client) } }
            }
        }
    }

    private func historyRow(_ item: QueueItem) -> some View {
        NavigationLink(value: QueueRoute.item(item)) {
            QueueItemRow(item: item, compact: true)
        }
        .swipeActions(edge: .trailing) {
            if QueuePermissions.canDelete(item, session) {
                Button(role: .destructive) { confirm = .remove([item]) } label: { Label("Remove", systemImage: "trash") }
            }
        }
        .swipeActions(edge: .leading) {
            if session.can("queue:create"), item.source != nil {
                Button { requeue = item } label: { Label("Queue Again", systemImage: "arrow.clockwise") }.tint(.green)
            }
        }
        .contextMenu {
            if session.can("queue:create"), item.source != nil {
                Button { requeue = item } label: { Label("Queue Again", systemImage: "arrow.clockwise") }
            }
            if QueuePermissions.canDelete(item, session) {
                Button(role: .destructive) { confirm = .remove([item]) } label: { Label("Remove", systemImage: "trash") }
            }
        }
    }
}

// MARK: - Batch orders

struct QueueBatchesTab: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @AppStorage("queue.batchFilter") private var filter = "active"
    @State private var loader = Loader<[QueueBatch]>()
    @State private var runner = ActionRunner()
    @State private var cancelling: QueueBatch?

    var body: some View {
        List {
            Picker("Status", selection: $filter) {
                Text("Active").tag("active")
                Text("Completed").tag("completed")
                Text("Cancelled").tag("cancelled")
                Text("All").tag("all")
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            ForEach(loader.value ?? []) { batch in
                NavigationLink(value: QueueRoute.batchOrder(batch)) {
                    QueueBatchOrderRow(batch: batch)
                }
                .swipeActions {
                    if batch.status == "active", session.can("queue:delete_all") {
                        Button(role: .destructive) { cancelling = batch } label: { Label("Cancel Order", systemImage: "xmark.circle") }
                    }
                    if batch.hasTargets == true, (batch.dispatchableCount ?? 0) > 0, batch.status != "cancelled", session.can("queue:create") {
                        Button { Task { await dispatch(batch) } } label: { Label("Queue Remaining", systemImage: "play.fill") }.tint(.green)
                    }
                }
            }
        }
        .overlay {
            if loader.value == nil, let error = loader.error {
                ContentUnavailableView("Couldn't Load", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if loader.value == nil {
                ProgressView()
            } else if loader.value?.isEmpty == true {
                ContentUnavailableView("No Orders", systemImage: "shippingbox", description: Text("Printing several copies or plates of one file creates an order that tracks progress toward the target."))
            }
        }
        .refreshable { await load() }
        .task(id: "\(filter)|\(live.revision("queue_item_acked", "queue_item_failed", "print_complete", "print_start"))") { await load() }
        .confirmationDialog("Cancel this order?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible, presenting: cancelling) { batch in
            Button("Cancel Order", role: .destructive) {
                Task { await runner.run("Order cancelled") { try await session.client.call(.delete, "queue/batches/\(batch.id)"); await load() } }
            }
        } message: { _ in Text("Pending prints in this order are cancelled. Finished prints are kept.") }
        .actionAlerts(runner)
    }

    private func load() async {
        await loader.load { try await session.client.get("queue/batches", query: ["status": filter == "all" ? nil : .string(filter)]) }
    }

    private func dispatch(_ batch: QueueBatch) async {
        await runner.run("Queued remaining runs for \(batch.name ?? "order")") {
            let _: QueueBatch = try await session.client.send(.post, "queue/batches/\(batch.id)/dispatch", body: JSONValue.object([:]))
            await load()
        }
    }
}

extension QueueBatch {
    var progressDenominator: Int {
        if hasTargets == true { return targetCount ?? 0 }
        return (completedCount ?? 0) + (pendingCount ?? 0) + (printingCount ?? 0) + (failedCount ?? 0)
    }
    var strandedCount: Int { hasTargets == true ? max(0, (remainingCount ?? 0) - (dispatchableCount ?? 0)) : 0 }
    var dueDateValue: Date? { dueDate.flatMap(APICoders.parseDate) }
    var isOverdue: Bool { status == "active" && (dueDateValue.map { $0 < Date() } ?? false) }
}

struct QueueBatchOrderRow: View {
    let batch: QueueBatch

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "shippingbox.fill").foregroundStyle(.cyan)
                Text(batch.name ?? "Order #\(batch.id)").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                StatusBadge(text: (batch.status ?? "active").capitalized, color: batch.status == "completed" ? .green : batch.status == "cancelled" ? .secondary : .blue)
            }
            let total = batch.progressDenominator
            ProgressView(value: Double(batch.completedCount ?? 0), total: Double(max(total, 1)))
                .tint(batch.status == "completed" ? .green : .blue)
            HStack(spacing: 10) {
                Text("\(batch.completedCount ?? 0) of \(total) done")
                if let p = batch.printingCount, p > 0 { Text("\(p) printing") }
                if let p = batch.pendingCount, p > 0 { Text("\(p) queued") }
                if let f = batch.failedCount, f > 0 { Text("\(f) failed").foregroundStyle(.red) }
                if let d = batch.dueDateValue { Text("Due \(d.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(batch.isOverdue ? .red : .secondary) }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if batch.hasTargets == false {
                Text("Tracks queued runs only (no per-plate target)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct QueueBatchOrderDetail: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Environment(\.dismiss) private var dismiss
    @State var batch: QueueBatch
    @State private var runner = ActionRunner()
    @State private var confirmCancel = false

    private var canDispatch: Bool { session.can("queue:create") && batch.status != "cancelled" }

    var body: some View {
        List {
            Section { QueueBatchOrderRow(batch: batch) }
            Section("Details") {
                if let user = batch.createdByUsername { InfoRow("Created by", user, systemImage: "person") }
                InfoRow("Created", Fmt.date(batch.createdAt), systemImage: "calendar")
                if batch.completedAt != nil { InfoRow("Completed", Fmt.date(batch.completedAt), systemImage: "flag.checkered") }
                if let r = batch.remainingCount { InfoRow("Remaining", "\(r)", systemImage: "hourglass") }
                if let t = batch.printTimeSeconds, t > 0 { InfoRow("Print time", Fmt.duration(seconds: Double(t)), systemImage: "timer") }
                if let g = batch.filamentUsedGrams { InfoRow("Filament used", Fmt.grams(g), systemImage: "scalemass") }
                if let c = batch.actualCost { InfoRow("Cost so far", Fmt.number(c, digits: 2), systemImage: "dollarsign.circle") }
                if let c = batch.estimatedRemainingCost { InfoRow("Est. remaining cost", Fmt.number(c, digits: 2)) }
                if let notes = batch.notes, !notes.isEmpty { Text(notes).font(.callout) }
            }
            if batch.strandedCount > 0 && batch.status != "cancelled" {
                Section {
                    Label("\(batch.strandedCount) of the \(batch.remainingCount ?? 0) runs still owed can't be queued: that plate has no queued or finished run left to copy settings from. Queue the plate once from the file, or cancel the order.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            if let plates = batch.plates, !plates.isEmpty {
                Section("Plates") {
                    ForEach(Array(plates.enumerated()), id: \.offset) { _, plate in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(plate.label).font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(plate.completedCount ?? 0)/\(plate.quantityTarget ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(plate.completedCount ?? 0), total: Double(max(plate.quantityTarget ?? 1, 1)))
                            HStack(spacing: 8) {
                                if let f = plate.failedCount, f > 0 { Text("\(f) failed").foregroundStyle(.red) }
                                if let r = plate.remaining, r > 0 { Text("\(r) remaining") }
                                if plate.canDispatch == false, (plate.remaining ?? 0) > 0 { Text("Nothing left to copy settings from").foregroundStyle(.orange) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            if canDispatch, plate.canDispatch == true, (plate.remaining ?? 0) > 0 {
                                Button("Queue This Plate") { Task { await dispatch(plate: plate.plateId) } }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
            }
            Section {
                if batch.hasTargets == true, (batch.dispatchableCount ?? 0) > 0, canDispatch {
                    Button { Task { await dispatch(plate: nil) } } label: { Label("Queue \(batch.dispatchableCount ?? 0) Remaining", systemImage: "play.fill") }
                }
                if batch.status == "active", session.can("queue:delete_all") {
                    Button(role: .destructive) { confirmCancel = true } label: { Label("Cancel Order", systemImage: "xmark.circle") }
                }
            }
        }
        .navigationTitle(batch.name ?? "Order")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task(id: live.revision("queue_item_acked", "queue_item_failed", "print_complete")) { await reload() }
        .confirm("Cancel this order?", isPresented: $confirmCancel, message: "Pending prints in this order are cancelled. Finished prints are kept.", action: "Cancel Order") {
            Task { await runner.run("Order cancelled") { try await session.client.call(.delete, "queue/batches/\(batch.id)"); await reload() } }
        }
        .actionAlerts(runner)
    }

    private func reload() async {
        if let fresh: QueueBatch = try? await session.client.get("queue/batches/\(batch.id)") { batch = fresh }
    }

    private func dispatch(plate: Int?) async {
        var body: [String: JSONValue] = [:]
        if let plate { body["plate_id"] = .number(Double(plate)); body["only_plate"] = true }
        await runner.run("Queued") {
            batch = try await session.client.send(.post, "queue/batches/\(batch.id)/dispatch", body: JSONValue.object(body))
        }
    }
}

// MARK: - Timeline

/// One bar on the queue timeline.
struct QueueTimelineEvent: Identifiable, Hashable {
    var item: QueueItem
    var lane: String
    var start: Date
    var end: Date
    var printing: Bool
    var id: Int { item.id }
}

enum QueueTimelinePlanner {
    /// Forecasts start/end times: printing jobs from live progress, then queued jobs chained
    /// behind them per printer. Lanes with neither a running job nor a scheduled first job are
    /// omitted (a forecast there would be a guess). Staged and waiting items never appear.
    static func events(items: [QueueItem], statuses: [Int: PrinterStatus], now: Date = Date()) -> [QueueTimelineEvent] {
        func lane(_ i: QueueItem) -> String {
            if let pid = i.printerId { return i.printerName ?? "Printer #\(pid)" }
            if let m = i.targetModel, !m.isEmpty { return "Any \(m)" }
            return "Unassigned"
        }
        var result: [QueueTimelineEvent] = []
        var chainEnd: [String: Date] = [:]
        var activeLanes = Set<String>()
        for item in items where item.isPrinting {
            let status = item.printerId.flatMap { statuses[$0] }
            let start = item.startedAt.flatMap(APICoders.parseDate) ?? now
            let end: Date
            if let r = status?.remainingTime, r > 0 {
                end = now.addingTimeInterval(Double(r) * 60)
            } else if let t = item.printTimeSeconds {
                end = now.addingTimeInterval(Double(t) * max(0, 1 - (status?.progress ?? 0) / 100))
            } else {
                end = now.addingTimeInterval(3600)
            }
            let l = lane(item)
            result.append(QueueTimelineEvent(item: item, lane: l, start: start, end: end, printing: true))
            activeLanes.insert(l)
            chainEnd[l] = max(chainEnd[l] ?? now, end)
        }
        let pending = items.filter { $0.isPending && !$0.isStaged && $0.waitingReason == nil }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        let byLane = Dictionary(grouping: pending, by: lane)
        for (l, laneItems) in byLane {
            let firstScheduled = laneItems.first.flatMap { $0.hasRealSchedule ? $0.scheduledDate : nil }
            guard activeLanes.contains(l) || firstScheduled != nil else { continue }
            var cursor = chainEnd[l] ?? now
            for item in laneItems {
                if item.hasRealSchedule, let s = item.scheduledDate { cursor = max(cursor, s) }
                let duration = Double(item.printTimeSeconds ?? 3600)
                result.append(QueueTimelineEvent(item: item, lane: l, start: cursor, end: cursor.addingTimeInterval(duration), printing: false))
                cursor = cursor.addingTimeInterval(duration)
            }
        }
        return result
    }
}

struct QueueTimelineTab: View {
    @Environment(PrinterStore.self) private var store
    @Environment(QueueViewModel.self) private var model
    @State private var offsetHours = 0
    @State private var now = Date()

    var body: some View {
        let items = model.visible(store)
        let events = QueueTimelinePlanner.events(items: items, statuses: store.statuses, now: now)
        let start = Calendar.current.dateInterval(of: .hour, for: now.addingTimeInterval(Double(offsetHours) * 3600))?.start ?? now
        let end = start.addingTimeInterval(24 * 3600)
        let lanes = Array(Set(store.printers.map(\.name) + events.map(\.lane))).sorted()
        List {
            Section {
                HStack {
                    Button { offsetHours -= 12 } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text("\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { offsetHours += 12 } label: { Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless)
                if offsetHours != 0 {
                    Button("Back to Now") { offsetHours = 0 }.font(.caption)
                }
                Chart {
                    ForEach(events) { e in
                        BarMark(
                            xStart: .value("Start", max(e.start, start)),
                            xEnd: .value("End", min(max(e.end, e.start.addingTimeInterval(600)), end)),
                            y: .value("Printer", e.lane)
                        )
                        .foregroundStyle(e.printing ? Color.blue : Color.orange.opacity(0.75))
                        .cornerRadius(4)
                        .annotation(position: .overlay, alignment: .leading) {
                            Text(e.item.displayName).font(.system(size: 9)).foregroundStyle(.white).lineLimit(1).padding(.leading, 3)
                        }
                    }
                    RuleMark(x: .value("Now", now))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartXScale(domain: start...end)
                .chartYScale(domain: lanes)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: max(160, CGFloat(lanes.count) * 44 + 40))
                .padding(.vertical, 6)
            } footer: {
                Text("Blue: printing. Orange: forecast from queue order and estimated print times. Staged and waiting prints are not shown.")
            }
            Section("Upcoming") {
                let upcoming = events.filter { $0.end > now }.sorted { $0.start < $1.start }
                if upcoming.isEmpty { Text("Nothing scheduled in the forecast.").foregroundStyle(.secondary) }
                ForEach(upcoming) { e in
                    NavigationLink(value: QueueRoute.item(e.item)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Circle().fill(e.printing ? Color.blue : .orange).frame(width: 8, height: 8)
                                Text(e.item.displayName).font(.subheadline).lineLimit(1)
                            }
                            Text("\(e.lane) · \(e.start.formatted(date: .omitted, time: .shortened)) → \(e.end.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
    }
}
