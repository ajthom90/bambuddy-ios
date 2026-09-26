import SwiftUI

struct QueueRootView: View {
    @Environment(AppSession.self) private var session
    @State private var model = QueueViewModel()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            QueueHomeView()
                .navigationDestination(for: QueueRoute.self) { route in
                    switch route {
                    case .item(let item): QueueItemDetailView(item: item)
                    case .batchGroup(let id): QueueBatchGroupView(batchId: id)
                    case .batchOrder(let batch): QueueBatchOrderDetail(batch: batch)
                    case .pipelineRun(let id): QueuePipelineRunDetail(runId: id)
                    }
                }
        }
        .environment(model)
        .modifier(QueueModelAlerts(model: model, client: session.client))
    }
}

enum QueueTab: String, CaseIterable, Identifiable {
    case queue, batches, history, timeline, pipelines
    var id: String { rawValue }
    var title: String {
        switch self {
        case .queue: "Queue"
        case .batches: "Orders"
        case .history: "History"
        case .timeline: "Timeline"
        case .pipelines: "Pipelines"
        }
    }
}

/// Tab host: segmented tabs, shared filters, loading and live refresh.
private struct QueueHomeView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(LiveUpdates.self) private var live
    @Environment(QueueViewModel.self) private var model
    @AppStorage("queue.tab") private var tab: QueueTab = .queue
    @State private var pickingSource = false
    @State private var newJobSource: PrintSource?

    private var client: APIClient { session.client }
    private var tabs: [QueueTab] {
        QueueTab.allCases.filter { $0 != .pipelines || session.can("pipelines:read") }
    }
    private var hasFilter: Bool { model.printerFilter != nil || !model.statusFilter.isEmpty || !model.locationFilter.isEmpty }

    var body: some View {
        Group {
            switch tab {
            case .queue: QueueActiveTab()
            case .batches: QueueBatchesTab()
            case .history: QueueHistoryTab()
            case .timeline: QueueTimelineTab()
            case .pipelines: QueuePipelinesView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(tabs) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .navigationTitle("Queue")
        .toolbar {
            if tab != .pipelines && tab != .batches {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            if session.can("queue:create") {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { pickingSource = true } label: { Label("Add to Queue", systemImage: "plus") }
                }
            }
        }
        .sheet(isPresented: $pickingSource) {
            QueueSourcePicker { source in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    newJobSource = source
                }
            }
        }
        .sheet(item: Binding(get: { newJobSource.map(QueueSourceBox.init) }, set: { newJobSource = $0?.source })) { box in
            PrintJobSheet(source: box.source, mode: .addToQueue) { Task { await model.load(client) } }
        }
        .task { model.attach(live); await model.loadSettings(client) }
        .task(id: "\(model.printerFilter ?? 0)|\(model.statusFilter)") { await model.load(client) }
        .task(id: live.revision("queue_item_acked", "queue_item_failed", "queue_item_uploading", "print_start", "print_complete", "archive_created")) {
            await model.load(client)
        }
        .task(id: "poll") {
            // The server does not broadcast every queue change, so poll lightly while visible.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { await model.load(client) }
            }
        }
        #if DEBUG
        .task {
            if let raw = UserDefaults.standard.string(forKey: "queueTab"), let t = QueueTab(rawValue: raw) { tab = t }
        }
        #endif
    }

    private var filterMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Printer", selection: $model.printerFilter) {
                Text("All Printers").tag(Int?.none)
                Text("Unassigned").tag(Int?.some(-1))
                ForEach(store.printers) { Text($0.name).tag(Int?.some($0.id)) }
            }
            .pickerStyle(.menu)
            Picker("Status", selection: $model.statusFilter) {
                Text("All Statuses").tag("")
                ForEach(["pending", "printing", "completed", "failed", "skipped", "cancelled"], id: \.self) {
                    Text(QueueStatusStyle.label($0)).tag($0)
                }
            }
            .pickerStyle(.menu)
            let locations = model.locations(store)
            if !locations.isEmpty {
                Picker("Location", selection: $model.locationFilter) {
                    Text("All Locations").tag("")
                    ForEach(locations, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if hasFilter {
                Button("Clear Filters") {
                    model.printerFilter = nil
                    model.statusFilter = ""
                    model.locationFilter = ""
                }
            }
        } label: {
            Label("Filter", systemImage: hasFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }
}

private struct QueueSourceBox: Identifiable {
    let source: PrintSource
    var id: String { "\(source)" }
}

// MARK: - Active queue tab

enum QueuePendingSort: String, CaseIterable, Identifiable {
    case position, name, printer, schedule
    var id: String { rawValue }
    var title: String {
        switch self {
        case .position: "Queue Position"
        case .name: "Name"
        case .printer: "Printer"
        case .schedule: "Scheduled Time"
        }
    }
}

private struct QueueActiveTab: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(QueueViewModel.self) private var model
    @AppStorage("queue.pendingSort") private var sort: QueuePendingSort = .position
    @AppStorage("queue.pendingAscending") private var ascending = true
    @AppStorage("queue.groupByPrinter") private var groupByPrinter = false
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var confirm: QueueConfirmAction?
    @State private var showBulkEdit = false
    @State private var showGroup = false
    @State private var resumeTarget: (printerId: Int, name: String, count: Int)?
    @State private var editingItem: QueueItem?

    private var client: APIClient { session.client }

    private var visible: [QueueItem] { model.visible(store) }
    private var active: [QueueItem] { visible.filter(\.isPrinting) }

    private var pending: [QueueItem] {
        let items = visible.filter(\.isPending)
        if model.shortestFirst { return QueueViewModel.shortestFirstOrder(items) }
        let sorted = items.sorted { a, b in
            switch sort {
            case .position: return (a.position ?? 0) < (b.position ?? 0)
            case .name: return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            case .printer: return a.targetLabel.localizedStandardCompare(b.targetLabel) == .orderedAscending
            case .schedule:
                let at = a.hasRealSchedule ? (a.scheduledDate ?? .distantPast) : .distantPast
                let bt = b.hasRealSchedule ? (b.scheduledDate ?? .distantPast) : .distantPast
                return at < bt
            }
        }
        return ascending ? sorted : sorted.reversed()
    }

    private var canReorder: Bool {
        session.can("queue:reorder") && sort == .position && ascending && !model.shortestFirst
    }

    private var selectedItems: [QueueItem] {
        let rows = QueueRow.group(pending)
        return rows.filter { selection.contains($0.id) }.flatMap(\.items)
    }

    private var buckets: [(key: String, label: String, color: Color, rows: [QueueRow])] {
        var order: [String] = []
        var map: [String: (String, Color, [QueueRow])] = [:]
        for row in QueueRow.group(pending) {
            guard let rep = row.items.first else { continue }
            let key: String
            let color: Color
            if let pid = rep.printerId { key = "p\(pid)"; color = .green }
            else if rep.isModelBased { key = "m\(rep.targetLabel)"; color = .blue }
            else { key = "~unassigned"; color = .orange }
            if map[key] == nil { order.append(key); map[key] = (rep.targetLabel, color, []) }
            map[key]!.2.append(row)
        }
        return order.map { (key: $0, label: map[$0]!.0, color: map[$0]!.1, rows: map[$0]!.2) }
            .sorted { a, b in
                if a.key == "~unassigned" { return false }
                if b.key == "~unassigned" { return true }
                return a.label.localizedStandardCompare(b.label) == .orderedAscending
            }
    }

    var body: some View {
        let eta = model.etaEligible()
        List(selection: $selection) {
            if let items = model.items, !items.isEmpty || model.error == nil {
                QueueStatsHeader(active: active.count, pending: pending.count,
                                 seconds: pending.reduce(0) { $0 + ($1.printTimeSeconds ?? 0) },
                                 grams: pending.reduce(0) { $0 + ($1.filamentUsedGrams ?? 0) },
                                 history: visible.filter(\.isHistory).count)
                    .selectionDisabled()
            }
            if session.can("queue:update_all") {
                ForEach(model.gateBlockedPrinters(), id: \.printerId) { gate in
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(gate.name): \(gate.count) queued \(gate.count == 1 ? "print was" : "prints were") skipped because a previous print failed.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("Resume Queue") { resumeTarget = gate }
                                .buttonStyle(.bordered)
                        }
                        .selectionDisabled()
                    }
                }
            }
            if !active.isEmpty {
                Section("Printing") {
                    ForEach(active) { item in
                        NavigationLink(value: QueueRoute.item(item)) {
                            QueueItemRow(item: item, status: item.printerId.flatMap { store.statuses[$0] }, uploadPct: model.uploadProgress[item.id])
                        }
                        .selectionDisabled()
                        .swipeActions {
                            if QueuePermissions.canUpdate(item, session) {
                                Button(role: .destructive) { confirm = .stop(item) } label: { Label("Stop", systemImage: "stop.circle") }
                            }
                        }
                    }
                }
            }
            if !pending.isEmpty {
                if groupByPrinter {
                    ForEach(buckets, id: \.key) { bucket in
                        Section {
                            rows(bucket.rows, eta: eta)
                        } header: {
                            let all = bucket.rows.flatMap(\.items)
                            HStack {
                                Label(bucket.label, systemImage: "printer").foregroundStyle(bucket.color)
                                Spacer()
                                Text("\(all.count) · \(Fmt.duration(seconds: Double(all.reduce(0) { $0 + ($1.printTimeSeconds ?? 0) })))")
                            }
                        }
                    }
                } else {
                    Section {
                        rows(QueueRow.group(pending), eta: eta)
                    } header: {
                        HStack {
                            Text("Queued (\(pending.count))")
                            if model.shortestFirst { Text("· Shortest first").foregroundStyle(.green) }
                        }
                    } footer: {
                        if canReorder && editMode == .inactive && pending.count > 1 {
                            Text("Tap Select to reorder or act on several prints.")
                        }
                    }
                }
            }
        }
        .overlay {
            if model.items == nil, let error = model.error {
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await model.load(client) } }.buttonStyle(.bordered)
                }
            } else if model.items == nil {
                ProgressView()
            } else if active.isEmpty && pending.isEmpty {
                ContentUnavailableView("Queue is Empty", systemImage: "calendar.badge.clock",
                                       description: Text("Print an archive or a file from the library to add it here."))
            }
        }
        .environment(\.editMode, $editMode)
        .refreshable { await model.load(client) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !pending.isEmpty {
                    Button(editMode.isEditing ? "Done" : "Select") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        selection = []
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { optionsMenu }
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) { bulkBar }
            }
        }
        .queueConfirmations($confirm, model: model, client: client) { _ in selection = [] }
        .confirmationDialog("Resume queue?", isPresented: Binding(get: { resumeTarget != nil }, set: { if !$0 { resumeTarget = nil } }), titleVisibility: .visible, presenting: resumeTarget) { gate in
            Button("Resume \(gate.name)") { Task { await model.resume(printerId: gate.printerId, client: client) } }
        } message: { gate in
            Text("Clears the failure gate on \(gate.name) and restores \(gate.count) skipped \(gate.count == 1 ? "print" : "prints") to the queue.")
        }
        .sheet(isPresented: $showBulkEdit) {
            QueueBulkEditSheet(itemIds: selectedItems.map(\.id)) { selection = []; editMode = .inactive }
        }
        .sheet(isPresented: $showGroup) {
            QueueGroupBatchSheet(items: selectedItems) { selection = []; editMode = .inactive }
        }
        .sheet(item: $editingItem) { item in
            if let source = item.source {
                QueueJobForm(source: source, context: .edit(item)) { Task { await model.load(client) } }
            }
        }
    }

    @ViewBuilder
    private func rows(_ rows: [QueueRow], eta: Set<Int>) -> some View {
        ForEach(rows) { row in
            Group {
                switch row {
                case .item(let item):
                    NavigationLink(value: QueueRoute.item(item)) {
                        QueueItemRow(item: item, uploadPct: model.uploadProgress[item.id], showETA: eta.contains(item.id))
                    }
                    .swipeActions(edge: .trailing) { itemSwipe(item) }
                    .swipeActions(edge: .leading) {
                        if item.isStaged && QueuePermissions.canUpdate(item, session) {
                            Button { Task { await model.start(item, client: client) } } label: { Label("Start", systemImage: "play.fill") }.tint(.green)
                        }
                    }
                    .contextMenu { itemMenu(item) }
                case .batch(let id, let name, let items):
                    NavigationLink(value: QueueRoute.batchGroup(id)) {
                        QueueBatchSummaryRow(name: name, items: items)
                    }
                    .contextMenu {
                        Button { Task { await model.ungroup(batchId: id, client: client) } } label: { Label("Ungroup", systemImage: "square.stack.3d.down.forward") }
                        if items.allSatisfy({ QueuePermissions.canDelete($0, session) }) {
                            Button(role: .destructive) { confirm = .cancel(items) } label: { Label("Cancel All", systemImage: "xmark.circle") }
                        }
                    }
                }
            }
            .tag(row.id)
        }
        .onMove(perform: canReorder ? { from, to in move(rows, from: from, to: to) } : nil)
    }

    @ViewBuilder
    private func itemSwipe(_ item: QueueItem) -> some View {
        if QueuePermissions.canDelete(item, session) {
            Button(role: .destructive) { confirm = .cancel([item]) } label: { Label("Cancel", systemImage: "xmark") }
        }
        if QueuePermissions.canUpdate(item, session), item.source != nil {
            Button { editingItem = item } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: QueueItem) -> some View {
        if item.isStaged && QueuePermissions.canUpdate(item, session) {
            Button { Task { await model.start(item, client: client) } } label: { Label("Start Print", systemImage: "play.fill") }
        }
        if QueuePermissions.canUpdate(item, session), item.source != nil {
            Button { editingItem = item } label: { Label("Edit", systemImage: "pencil") }
        }
        if canReorder, let first = pending.first, first.id != item.id {
            Button { Task { await model.move([item.id], anchor: first.id, after: false, client: client) } } label: { Label("Move to Top", systemImage: "arrow.up.to.line") }
        }
        if canReorder, let last = pending.last, last.id != item.id {
            Button { Task { await model.move([item.id], anchor: last.id, after: true, client: client) } } label: { Label("Move to Bottom", systemImage: "arrow.down.to.line") }
        }
        if QueuePermissions.canDelete(item, session) {
            Button(role: .destructive) { confirm = .cancel([item]) } label: { Label("Cancel", systemImage: "xmark.circle") }
        }
    }

    /// Applies a drag-to-reorder within a displayed list of rows to the global pending order.
    private func move(_ rows: [QueueRow], from: IndexSet, to: Int) {
        var reordered = rows
        reordered.move(fromOffsets: from, toOffset: to)
        let moving = from.map { rows[$0] }.flatMap(\.items).map(\.id)
        guard let firstMoved = reordered.firstIndex(where: { r in r.items.contains { moving.contains($0.id) } }) else { return }
        Task {
            if firstMoved > 0, let anchor = reordered[firstMoved - 1].items.last {
                await model.move(moving, anchor: anchor.id, after: true, client: client)
            } else if let next = reordered.dropFirst(firstMoved).first(where: { r in !r.items.contains { moving.contains($0.id) } })?.items.first {
                await model.move(moving, anchor: next.id, after: false, client: client)
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Layout", selection: $groupByPrinter) {
                Label("Single List", systemImage: "list.bullet").tag(false)
                Label("By Printer", systemImage: "printer").tag(true)
            }
            Section("Sort Queued") {
                Picker("Sort", selection: $sort) {
                    ForEach(QueuePendingSort.allCases) { Text($0.title).tag($0) }
                }
                Button { ascending.toggle() } label: {
                    Label(ascending ? "Ascending" : "Descending", systemImage: ascending ? "arrow.up" : "arrow.down")
                }
            }
            .disabled(model.shortestFirst)
            if session.can("settings:update") {
                Toggle(isOn: Binding(get: { model.shortestFirst }, set: { on in Task { await model.setShortestFirst(on, client: client) } })) {
                    Label("Shortest Job First", systemImage: "tortoise")
                }
            }
        } label: {
            Label("Options", systemImage: "arrow.up.arrow.down.circle")
        }
    }

    @ViewBuilder
    private var bulkBar: some View {
        let allIds = Set(QueueRow.group(pending).map(\.id))
        Button(selection.isSuperset(of: allIds) && !allIds.isEmpty ? "Deselect All" : "Select All") {
            selection = selection.isSuperset(of: allIds) ? [] : allIds
        }
        Spacer()
        let items = selectedItems
        if items.count >= 2, items.allSatisfy({ $0.batchId == nil }), session.can("queue:create") {
            Button { showGroup = true } label: { Label("Group", systemImage: "shippingbox") }
        }
        Button { showBulkEdit = true } label: { Label("Edit", systemImage: "slider.horizontal.3") }
            .disabled(items.isEmpty || !(session.can("queue:update_own") || session.can("queue:update_all")))
        Button(role: .destructive) { confirm = .cancel(items) } label: { Label("Cancel", systemImage: "xmark.circle") }
            .disabled(items.isEmpty || !(session.can("queue:delete_own") || session.can("queue:delete_all")))
    }
}

struct QueueStatsHeader: View {
    let active: Int
    let pending: Int
    let seconds: Int
    let grams: Double
    let history: Int

    var body: some View {
        HStack(spacing: 0) {
            stat("\(active)", "Printing", "play.circle", .blue)
            stat("\(pending)", "Queued", "clock", .orange)
            stat(seconds > 0 ? Fmt.duration(seconds: Double(seconds)) : "—", "Total Time", "timer", .purple)
            stat(grams > 0 ? Fmt.grams(grams) : "—", "Filament", "scalemass", .green)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
    }

    private func stat(_ value: String, _ label: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct QueueBatchSummaryRow: View {
    let name: String
    let items: [QueueItem]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title2).foregroundStyle(.cyan)
                .frame(width: 52, height: 52)
                .background(Color.cyan.opacity(0.12), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    StatusBadge(text: "\(items.count) copies", color: .cyan)
                }
                HStack(spacing: 10) {
                    let seconds = items.reduce(0) { $0 + ($1.printTimeSeconds ?? 0) }
                    let grams = items.reduce(0) { $0 + ($1.filamentUsedGrams ?? 0) }
                    if seconds > 0 { Label(Fmt.duration(seconds: Double(seconds)), systemImage: "timer") }
                    if grams > 0 { Label(Fmt.grams(grams), systemImage: "scalemass") }
                    if let first = items.first { Label(first.targetLabel, systemImage: "printer").lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(QueueCompactLabelStyle())
            }
        }
    }
}

/// The pending members of one batch, with per-item actions and ungrouping.
struct QueueBatchGroupView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(QueueViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let batchId: Int
    @State private var confirm: QueueConfirmAction?
    @State private var confirmUngroup = false

    private var items: [QueueItem] {
        (model.items ?? []).filter { $0.batchId == batchId && ($0.isPending || $0.isPrinting) }.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
    }

    var body: some View {
        List {
            ForEach(items) { item in
                NavigationLink(value: QueueRoute.item(item)) {
                    QueueItemRow(item: item, status: item.printerId.flatMap { store.statuses[$0] }, uploadPct: model.uploadProgress[item.id])
                }
                .swipeActions {
                    if item.isPending && QueuePermissions.canDelete(item, session) {
                        Button(role: .destructive) { confirm = .cancel([item]) } label: { Label("Cancel", systemImage: "xmark") }
                    }
                }
            }
            .onMove(perform: session.can("queue:reorder") && !model.shortestFirst ? { from, to in
                var ids = items.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                let moved = from.map { items[$0].id }
                guard let idx = ids.firstIndex(where: { moved.contains($0) }) else { return }
                Task {
                    if idx > 0 { await model.move(moved, anchor: ids[idx - 1], after: true, client: session.client) }
                    else if let next = ids.first(where: { !moved.contains($0) }) { await model.move(moved, anchor: next, after: false, client: session.client) }
                }
            } : nil)
        }
        .overlay { if items.isEmpty { ContentUnavailableView("Batch is Empty", systemImage: "shippingbox") } }
        .navigationTitle(items.first?.batchName ?? "Batch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    EditButton()
                    Button { confirmUngroup = true } label: { Label("Ungroup", systemImage: "square.stack.3d.down.forward") }
                    if !items.isEmpty, items.allSatisfy({ $0.isPending && QueuePermissions.canDelete($0, session) }) {
                        Button(role: .destructive) { confirm = .cancel(items) } label: { Label("Cancel All", systemImage: "xmark.circle") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirm("Ungroup this batch?", isPresented: $confirmUngroup, message: "The prints stay in the queue as individual items.", action: "Ungroup", role: nil) {
            Task { await model.ungroup(batchId: batchId, client: session.client); dismiss() }
        }
        .queueConfirmations($confirm, model: model, client: session.client)
        .refreshable { await model.load(session.client) }
    }
}

// MARK: - Bulk edit

private enum QueueTri: Hashable { case keep, off, on }

/// Applies the same settings to several pending items at once (`PATCH queue/bulk`).
struct QueueBulkEditSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(QueueViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemIds: [Int]
    var onDone: () -> Void

    @State private var printer: Int? = -2 // -2 = unchanged, -1 = unassigned
    @State private var manualStart = QueueTri.keep
    @State private var autoOff = QueueTri.keep
    @State private var requirePrevious = QueueTri.keep
    @State private var bedLevelling = ""
    @State private var flowCali = ""
    @State private var nozzleOffset = ""
    @State private var vibration = QueueTri.keep
    @State private var layerInspect = QueueTri.keep
    @State private var timelapse = QueueTri.keep
    @State private var useAms = QueueTri.keep
    @State private var runner = ActionRunner()

    private var body_: [String: JSONValue] {
        var b: [String: JSONValue] = [:]
        if printer != -2 { b["printer_id"] = printer == -1 ? .null : .number(Double(printer ?? 0)) }
        func tri(_ key: String, _ v: QueueTri) { if v != .keep { b[key] = .bool(v == .on) } }
        tri("manual_start", manualStart)
        tri("auto_off_after", autoOff)
        tri("require_previous_success", requirePrevious)
        tri("vibration_cali", vibration)
        tri("layer_inspect", layerInspect)
        tri("timelapse", timelapse)
        tri("use_ams", useAms)
        if !bedLevelling.isEmpty { b["bed_levelling"] = .string(bedLevelling) }
        if !flowCali.isEmpty { b["flow_cali"] = .string(flowCali) }
        if !nozzleOffset.isEmpty { b["nozzle_offset_cali"] = .string(nozzleOffset) }
        return b
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Printer", selection: $printer) {
                        Text("No Change").tag(Int?.some(-2))
                        Text("Unassigned").tag(Int?.some(-1))
                        ForEach(store.printers) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                } footer: { Text("Only the settings you change are applied to the \(itemIds.count) selected items.") }
                Section("Queue Options") {
                    triPicker("Staged (manual start)", $manualStart)
                    triPicker("Power off when done", $autoOff).disabled(!session.can("printers:control"))
                    triPicker("Require previous success", $requirePrevious)
                }
                Section("Print Options") {
                    modePicker("Bed Leveling", $bedLevelling)
                    modePicker("Flow Calibration", $flowCali)
                    triPicker("Vibration Calibration", $vibration)
                    triPicker("First Layer Inspection", $layerInspect)
                    triPicker("Timelapse", $timelapse)
                    triPicker("Use AMS", $useAms)
                    if store.printers.contains(where: { $0.nozzleCount == 2 }) { modePicker("Nozzle Offset Calibration", $nozzleOffset) }
                }
            }
            .navigationTitle("Edit \(itemIds.count) Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        Task {
                            var b = body_
                            b["item_ids"] = .array(itemIds.map { .number(Double($0)) })
                            await runner.run {
                                let r: QueueBulkUpdateResult = try await session.client.send(.patch, "queue/bulk", body: JSONValue.object(b))
                                model.runner.successMessage = r.message ?? "Updated \(r.updatedCount ?? 0) items"
                                await model.load(session.client)
                                onDone()
                                dismiss()
                            }
                        }
                    }
                    .disabled(body_.isEmpty || runner.isRunning)
                }
            }
            .actionAlerts(runner)
        }
    }

    private func triPicker(_ title: String, _ value: Binding<QueueTri>) -> some View {
        Picker(title, selection: value) {
            Text("—").tag(QueueTri.keep)
            Text("Off").tag(QueueTri.off)
            Text("On").tag(QueueTri.on)
        }
    }

    private func modePicker(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            Text("—").tag("")
            ForEach(QueueCalibrationMode.allCases) { Text($0.label).tag($0.rawValue) }
        }
    }
}

/// Names a new batch made from selected pending items.
struct QueueGroupBatchSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(QueueViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [QueueItem]
    var onDone: () -> Void
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Batch name", text: $name)
                } footer: {
                    Text("Groups \(items.count) queued prints so they can be reordered and tracked together.")
                }
            }
            .navigationTitle("Group as Batch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        Task {
                            await model.createBatch(name: trimmed, ids: items.map(\.id), client: session.client)
                            onDone()
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                let raw = items.first?.displayName ?? "Batch"
                name = raw.replacingOccurrences(of: ".gcode.3mf", with: "", options: .caseInsensitive).replacingOccurrences(of: ".3mf", with: "", options: .caseInsensitive)
            }
        }
        .presentationDetents([.medium])
    }
}
