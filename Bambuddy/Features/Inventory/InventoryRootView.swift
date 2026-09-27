import SwiftUI

/// Navigation destinations inside the Inventory section.
enum InventoryRoute: Hashable {
    case spool(Int)
    case similar([Int])
    case forecast
    case locations
    case spoolCatalog
    case colorCatalog
    case filamentCatalog
    case usageLog
}

/// What the spool form sheet should do.
enum InventoryFormRequest: Identifiable, Hashable {
    case create
    case edit(Int)
    case copy(Int)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let id): "edit-\(id)"
        case .copy(let id): "copy-\(id)"
        }
    }
}

/// Spool ids for sheets that act on a set of spools (labels, bulk edit).
struct InventorySpoolIDs: Identifiable, Hashable {
    var ids: [Int]
    var id: String { ids.map(String.init).joined(separator: ",") }
}

struct InventoryRootView: View {
    @Environment(AppSession.self) private var session
    @State private var store: InventoryStore?
    @State private var path = NavigationPath()

    var body: some View {
        if let store {
            NavigationStack(path: $path) {
                InventoryListScreen(path: $path)
                    .navigationDestination(for: InventoryRoute.self) { route in
                        InventoryRouteView(route: route, path: $path)
                    }
            }
            .environment(store)
        } else {
            NavigationStack {
                ProgressView().navigationTitle("Inventory")
            }
            .task {
                #if DEBUG
                store = InventoryStore(session: session, demo: UserDefaults.standard.bool(forKey: "inventoryDemo"))
                if let open = UserDefaults.standard.string(forKey: "inventoryOpen") {
                    if open.hasPrefix("spool:"), let id = Int(open.dropFirst(6)) { path.append(InventoryRoute.spool(id)) }
                    else if open == "forecast" { path.append(InventoryRoute.forecast) }
                    else if open == "locations" { path.append(InventoryRoute.locations) }
                    else if open == "colors" { path.append(InventoryRoute.colorCatalog) }
                    else if open == "filaments" { path.append(InventoryRoute.filamentCatalog) }
                    else if open == "usage" { path.append(InventoryRoute.usageLog) }
                }
                #else
                store = InventoryStore(session: session)
                #endif
            }
        }
    }
}

/// Resolves a route to its screen.
struct InventoryRouteView: View {
    let route: InventoryRoute
    @Binding var path: NavigationPath

    var body: some View {
        switch route {
        case .spool(let id): InventorySpoolDetailView(spoolId: id)
        case .similar(let ids): InventorySimilarSpoolsView(ids: ids)
        case .forecast: InventoryForecastView()
        case .locations: InventoryLocationsView()
        case .spoolCatalog: InventorySpoolCatalogView()
        case .colorCatalog: InventoryColorCatalogView()
        case .filamentCatalog: InventoryFilamentCatalogView()
        case .usageLog: InventoryUsageLogView()
        }
    }
}

// MARK: - Filters, sorting, grouping

private struct InventoryFilters: Equatable {
    enum Status: String, CaseIterable { case active = "Active", archived = "Archived" }
    enum Usage: String, CaseIterable { case all = "All", used = "Used", new = "New", lowStock = "Low Stock" }
    enum Stock: String, CaseIterable { case all = "All", stock = "Stock Only", configured = "Configured" }

    static let none = "__none__"

    var status: Status = .active
    var usage: Usage = .all
    var stock: Stock = .all
    var material = ""
    var brand = ""
    var category = ""
    var spoolType = ""
    var storage = ""

    var isActive: Bool { self != InventoryFilters() }
    var activeCount: Int {
        [status != .active, usage != .all, stock != .all, !material.isEmpty, !brand.isEmpty, !category.isEmpty, !spoolType.isEmpty, !storage.isEmpty].filter { $0 }.count
    }
}

private enum InventorySort: String, CaseIterable, Identifiable {
    case id = "ID", added = "Date Added", lastUsed = "Last Used", material = "Material", brand = "Brand"
    case colorName = "Color Name", color = "Color", remainingPercent = "Remaining %", remainingGrams = "Remaining Weight"
    case used = "Used", labelWeight = "Label Weight", printer = "Printer Slot", storage = "Storage Location"
    case cost = "Cost per kg", category = "Category"
    var id: String { rawValue }
}

private enum InventoryGrouping: String, CaseIterable, Identifiable {
    case none = "None", material = "Material", brand = "Brand", storage = "Storage Location", status = "Printer Status", category = "Category"
    var id: String { rawValue }
}

private enum InventoryConfirmAction: Identifiable {
    case delete(Int), archive(Int), resetCounter(Int)
    case bulkDelete([Int]), bulkArchive([Int]), bulkRestore([Int]), bulkReset([Int])
    case resetAll([Int])
    case syncAMS

    var id: String { String(describing: self) }

    var title: String {
        switch self {
        case .delete: "Delete this spool?"
        case .archive: "Archive this spool?"
        case .resetCounter: "Reset the consumed counter?"
        case .bulkDelete(let ids): "Delete \(ids.count) spools?"
        case .bulkArchive(let ids): "Archive \(ids.count) spools?"
        case .bulkRestore(let ids): "Restore \(ids.count) spools?"
        case .bulkReset(let ids): "Reset usage for \(ids.count) spools?"
        case .resetAll(let ids): "Reset consumed counters for all \(ids.count) spools?"
        case .syncAMS: "Sync weights from AMS?"
        }
    }

    var message: String {
        switch self {
        case .delete, .bulkDelete: "Deleted spools and their usage history are removed permanently."
        case .archive, .bulkArchive: "Archived spools are hidden from the active list and can be restored later."
        case .bulkRestore: "The spools return to the active inventory."
        case .resetCounter, .bulkReset, .resetAll: "The consumed counter restarts at zero. Remaining weight is not changed."
        case .syncAMS: "Remaining weights of assigned spools are updated from the AMS remaining percentage."
        }
    }

    var button: String {
        switch self {
        case .delete, .bulkDelete: "Delete"
        case .archive, .bulkArchive: "Archive"
        case .bulkRestore: "Restore"
        case .resetCounter, .bulkReset, .resetAll: "Reset"
        case .syncAMS: "Sync"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .delete, .bulkDelete, .archive, .bulkArchive, .resetCounter, .bulkReset, .resetAll: true
        default: false
        }
    }
}

/// A row in the displayed list: a single spool or a collapsed set of identical unused spools.
private struct InventoryDisplayItem: Identifiable {
    var spools: [InventorySpool]
    var representative: InventorySpool { spools[0] }
    var id: String { spools.count == 1 ? "s\(spools[0].id)" : "g\(spools.map(\.id).map(String.init).joined(separator: "-"))" }
}

private struct InventorySection: Identifiable {
    var title: String?
    var items: [InventoryDisplayItem]
    var id: String { title ?? "_all" }
}

// MARK: - List screen

private struct InventoryListScreen: View {
    @Environment(AppSession.self) private var session
    @Environment(InventoryStore.self) private var store
    @Environment(LiveUpdates.self) private var live
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var path: NavigationPath

    @State private var search = ""
    @State private var filters = InventoryFilters()
    @AppStorage("inventory.sort") private var sortRaw = InventorySort.id.rawValue
    @AppStorage("inventory.sortAscending") private var ascending = true
    @AppStorage("inventory.grouping") private var groupingRaw = InventoryGrouping.none.rawValue
    @AppStorage("inventory.groupSimilar") private var groupSimilar = false
    @AppStorage("inventory.grid") private var gridMode = false
    @AppStorage("inventory.showStats") private var showStats = true

    @State private var selecting = false
    @State private var selection = Set<Int>()
    @State private var showFilters = false
    @State private var formRequest: InventoryFormRequest?
    @State private var labelIDs: InventorySpoolIDs?
    @State private var bulkEditIDs: InventorySpoolIDs?
    @State private var assignSpool: InventorySpool?
    @State private var confirm: InventoryConfirmAction?
    @State private var showImport = false
    @State private var exportURL: URL?
    @State private var showThreshold = false
    @State private var thresholdText = ""
    @State private var showSpoolman = false
    @State private var runner = ActionRunner()

    private var sort: InventorySort { InventorySort(rawValue: sortRaw) ?? .id }
    private var grouping: InventoryGrouping { InventoryGrouping(rawValue: groupingRaw) ?? .none }
    private var canEdit: Bool { session.can("inventory:update") }
    private var canForecast: Bool { session.can("inventory:forecast_read") }

    var body: some View {
        content
            .navigationTitle("Inventory")
            .searchable(text: $search, prompt: "Search spools")
            .refreshable { await store.load() }
            .task(id: live.revision("inventory_changed", "spool_assignment_changed", "spool_usage_logged", "spool_auto_assigned")) {
                await store.load()
            }
            .toolbar { toolbar }
            .onChange(of: filters) { selection.removeAll() }
            .onChange(of: search) { selection.removeAll() }
            .sheet(isPresented: $showFilters) { filterSheet }
            .sheet(item: $formRequest) { InventorySpoolFormView(request: $0) }
            .sheet(item: $labelIDs) { InventoryLabelSheet(spoolIds: $0.ids) }
            .sheet(item: $bulkEditIDs) { ids in
                InventoryBulkEditView(spoolIds: ids.ids) { selection.removeAll(); selecting = false }
            }
            .sheet(item: $assignSpool) { InventoryAssignSlotSheet(spool: $0) }
            .sheet(isPresented: $showImport) { InventoryImportSheet() }
            .sheet(isPresented: $showSpoolman) { InventorySpoolmanStatusSheet() }
            .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { action in
                Button(action.button, role: action.isDestructive ? .destructive : nil) { perform(action) }
            } message: { Text($0.message) }
            .alert("Low Stock Threshold", isPresented: $showThreshold) {
                TextField("Percent", text: $thresholdText).keyboardType(.decimalPad)
                Button("Save") {
                    guard let v = Double(thresholdText.replacingOccurrences(of: ",", with: ".")), v > 0, v < 100 else {
                        runner.errorMessage = "Enter a percentage between 1 and 99."
                        return
                    }
                    Task { await runner.run("Threshold saved") { try await store.setLowStockThreshold(v) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Spools below this percentage of their label weight count as low stock.")
            }
            .actionAlerts(runner)
            .overlay(alignment: .bottom) {
                if let exportURL {
                    InventoryShareBar(url: exportURL, title: "Spool export ready") { self.exportURL = nil }
                        .padding()
                }
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded {
            if let error = store.error {
                ContentUnavailableView {
                    Label("Couldn't Load Inventory", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await store.load() } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if store.spools.isEmpty {
            ContentUnavailableView {
                Label("No Spools", systemImage: "circle.circle")
            } description: {
                Text(store.isSpoolman ? "Your Spoolman inventory is empty." : "Add spools to track filament, weights and usage.")
            } actions: {
                if canEdit {
                    Button("Add Spool") { formRequest = .create }.buttonStyle(.borderedProminent)
                    if !store.isSpoolman { Button("Import CSV") { showImport = true } }
                }
            }
        } else if gridMode {
            gridContent
        } else {
            listContent
        }
    }

    private var sections: [InventorySection] {
        let spools = sortedSpools
        let slotMap = store.slotMap
        func items(_ list: [InventorySpool]) -> [InventoryDisplayItem] {
            guard groupSimilar, !selecting else { return list.map { InventoryDisplayItem(spools: [$0]) } }
            var groups: [String: [InventorySpool]] = [:]
            for s in list where s.used == 0 && slotMap[s.id] == nil { groups[s.similarityKey, default: []].append(s) }
            var seen = Set<String>()
            var out: [InventoryDisplayItem] = []
            for s in list {
                if s.used > 0 || slotMap[s.id] != nil { out.append(InventoryDisplayItem(spools: [s])); continue }
                let key = s.similarityKey
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                out.append(InventoryDisplayItem(spools: groups[key] ?? [s]))
            }
            return out
        }
        guard grouping != .none else { return [InventorySection(title: nil, items: items(spools))] }
        var order: [String] = []
        var buckets: [String: [InventorySpool]] = [:]
        for s in spools {
            let key: String
            switch grouping {
            case .none: key = ""
            case .material: key = s.materialName
            case .brand: key = (s.brand ?? "").isEmpty ? "No Brand" : s.brand!
            case .storage: key = store.storageLabel(for: s) ?? "No Storage Location"
            case .status: key = slotMap[s.id].map { $0.printerName ?? "Printer \($0.printerId)" }.map { "Loaded · \($0)" } ?? "Not Loaded"
            case .category: key = (s.category ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "Uncategorized" : s.category!
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(s)
        }
        order.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return order.map { InventorySection(title: "\($0) (\(buckets[$0]!.count))", items: items(buckets[$0]!)) }
    }

    private var listContent: some View {
        let slotMap = store.slotMap
        let secs = sections
        return List(selection: $selection) {
            if showStats && !selecting && search.isEmpty {
                Section { statsStrip }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            filterSummary
            if secs.allSatisfy({ $0.items.isEmpty }) {
                noResults
            }
            ForEach(secs) { section in
                Section {
                    ForEach(section.items) { item in
                        if item.spools.count > 1 {
                            DisclosureGroup {
                                ForEach(item.spools) { spool in
                                    spoolLink(spool, slot: slotMap[spool.id])
                                }
                            } label: {
                                InventorySpoolRow(spool: item.representative, storage: store.storageLabel(for: item.representative), lowStockThreshold: store.lowStockThreshold, groupCount: item.spools.count)
                            }
                        } else {
                            spoolLink(item.representative, slot: slotMap[item.representative.id])
                        }
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
    }

    private func spoolLink(_ spool: InventorySpool, slot: InventorySlotLocation?) -> some View {
        NavigationLink(value: InventoryRoute.spool(spool.id)) {
            InventorySpoolRow(spool: spool, slot: slot, storage: store.storageLabel(for: spool), lowStockThreshold: store.lowStockThreshold)
        }
        .tag(spool.id)
        .contextMenu { spoolMenu(spool) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canEdit {
                Button(role: .destructive) { confirm = .delete(spool.id) } label: { Label("Delete", systemImage: "trash") }
                if spool.isArchived {
                    Button { Task { await runner.run("Spool restored") { try await store.restore(spool.id) } } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                        .tint(.green)
                } else {
                    Button { confirm = .archive(spool.id) } label: { Label("Archive", systemImage: "archivebox") }
                        .tint(.orange)
                }
            }
        }
        .swipeActions(edge: .leading) {
            if canEdit {
                Button { formRequest = .edit(spool.id) } label: { Label("Edit", systemImage: "pencil") }.tint(.accentColor)
                Button { formRequest = .copy(spool.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.tint(.indigo)
            }
        }
    }

    private var gridContent: some View {
        let slotMap = store.slotMap
        let secs = sections
        let columns = [GridItem(.adaptive(minimum: sizeClass == .compact ? 160 : 220), spacing: 12)]
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showStats && !selecting && search.isEmpty { statsStrip }
                if filters.isActive {
                    filterSummary.padding(.horizontal)
                }
                if secs.allSatisfy({ $0.items.isEmpty }) { noResults }
                ForEach(secs) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if let title = section.title {
                            Text(title).font(.headline).padding(.horizontal)
                        }
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(section.items) { item in
                                gridCell(item, slot: slotMap[item.representative.id])
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
    }

    @ViewBuilder
    private func gridCell(_ item: InventoryDisplayItem, slot: InventorySlotLocation?) -> some View {
        let spool = item.representative
        let card = InventorySpoolCard(spool: spool, slot: slot, storage: store.storageLabel(for: spool), lowStockThreshold: store.lowStockThreshold,
                                      groupCount: item.spools.count, isSelected: selecting ? selection.contains(spool.id) : nil)
        if selecting {
            Button {
                if selection.contains(spool.id) { selection.remove(spool.id) } else { selection.insert(spool.id) }
            } label: { card }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: item.spools.count > 1 ? InventoryRoute.similar(item.spools.map(\.id)) : InventoryRoute.spool(spool.id)) { card }
                .buttonStyle(.plain)
                .contextMenu { spoolMenu(spool) }
        }
    }

    @ViewBuilder
    private var noResults: some View {
        ContentUnavailableView {
            Label(filters.status == .archived ? "No Archived Spools" : "No Matching Spools", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(search.isEmpty ? "Try changing the filters." : "No spools match “\(search)”.")
        } actions: {
            if filters.isActive || !search.isEmpty {
                Button("Clear Filters") { filters = InventoryFilters(); search = "" }.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var filterSummary: some View {
        if filters.isActive || !sortedSpools.isEmpty {
            HStack {
                Text(countText).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if filters.isActive {
                    Button("Clear Filters") { filters = InventoryFilters() }.font(.footnote)
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    private var countText: String {
        let n = sortedSpools.count
        var s = "\(n) \(n == 1 ? "spool" : "spools")"
        if filters.status == .archived { s += " archived" }
        if filters.activeCount > 0 { s += " · \(filters.activeCount) filter\(filters.activeCount == 1 ? "" : "s")" }
        return s
    }

    // MARK: Filtering & sorting

    private var filteredSpools: [InventorySpool] {
        let threshold = store.lowStockThreshold
        return store.spools.filter { s in
            if filters.status == .active ? s.isArchived : !s.isArchived { return false }
            switch filters.usage {
            case .all: break
            case .used: if s.used <= 0 { return false }
            case .new: if s.used != 0 { return false }
            case .lowStock: if !s.isLowStock(globalThreshold: threshold) { return false }
            }
            switch filters.stock {
            case .all: break
            case .stock: if s.hasSlicerPreset { return false }
            case .configured: if !s.hasSlicerPreset { return false }
            }
            if !filters.material.isEmpty && s.material != filters.material { return false }
            if !filters.brand.isEmpty && s.brand != filters.brand { return false }
            if !filters.category.isEmpty {
                let cat = (s.category ?? "").trimmingCharacters(in: .whitespaces)
                if filters.category == InventoryFilters.none ? !cat.isEmpty : cat != filters.category { return false }
            }
            if !filters.spoolType.isEmpty && String(s.coreWeightCatalogId ?? -1) != filters.spoolType { return false }
            if !filters.storage.isEmpty {
                if filters.storage == InventoryFilters.none {
                    if s.locationId != nil || !(s.storageLocation ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return false }
                } else {
                    let locId = Int(filters.storage)
                    if let id = s.locationId {
                        if id != locId { return false }
                    } else {
                        let name = store.location(locId)?.name.lowercased() ?? ""
                        if name.isEmpty || (s.storageLocation ?? "").trimmingCharacters(in: .whitespaces).lowercased() != name { return false }
                    }
                }
            }
            return s.matches(search: search)
        }
    }

    private var sortedSpools: [InventorySpool] {
        let slotMap = store.slotMap
        let list = filteredSpools
        func key(_ s: InventorySpool) -> InventorySortKey {
            switch sort {
            case .id: .number(Double(s.id))
            case .added: .text(s.createdAt ?? "")
            case .lastUsed: .text(s.lastUsed ?? "")
            case .material: .text(s.materialLine.lowercased())
            case .brand: .text((s.brand ?? "").lowercased())
            case .colorName: .text((s.colorName ?? "").lowercased())
            case .color: .number(InventorySortKey.hue(s.rgba))
            case .remainingPercent: .number(s.remainingPercent)
            case .remainingGrams: .number(s.remainingGrams)
            case .used: .number(s.used)
            case .labelWeight: .number(s.label)
            case .printer: .text(slotMap[s.id]?.description.lowercased() ?? "")
            case .storage: .text((store.storageLabel(for: s) ?? "").lowercased())
            case .cost: .number(s.costPerKg ?? 0)
            case .category: .text((s.category ?? "").lowercased())
            }
        }
        let keyed = list.map { ($0, key($0)) }
        return keyed.sorted { a, b in
            if a.1 == b.1 { return a.0.id < b.0.id }
            return ascending ? a.1 < b.1 : b.1 < a.1
        }.map(\.0)
    }

    // MARK: Stats

    private var statsStrip: some View {
        let active = store.spools.filter { !$0.isArchived }
        let total = active.reduce(0) { $0 + $1.remainingGrams }
        let consumed = store.spools.reduce(0) { $0 + $1.consumedGrams }
        let low = active.filter { $0.isLowStock(globalThreshold: store.lowStockThreshold) }.count
        var byMaterial: [String: Double] = [:]
        for s in active { byMaterial[s.materialName, default: 0] += s.remainingGrams }
        let top = byMaterial.sorted { $0.value > $1.value }.prefix(4)
        let inPrinter = store.isSpoolman ? store.spoolmanAssignments.count : store.assignments.count
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                InventoryStatTile(title: "Total Inventory", value: InventoryFormat.grams(total), detail: "\(active.count) \(active.count == 1 ? "spool" : "spools")", systemImage: "shippingbox", tint: .green)
                InventoryStatTile(title: "Consumed", value: InventoryFormat.grams(consumed), detail: "Since tracking began", systemImage: "chart.line.downtrend.xyaxis", tint: .blue) {
                    if canEdit && consumed > 0 {
                        Button { confirm = .resetAll(store.spools.map(\.id)) } label: { Image(systemName: "eraser") }
                            .buttonStyle(.borderless).accessibilityLabel("Reset all consumed counters")
                    }
                }
                InventoryStatTile(title: "By Material", value: top.first.map { $0.key } ?? "—", detail: top.map { "\($0.key) \(InventoryFormat.grams($0.value))" }.joined(separator: " · "), systemImage: "square.stack.3d.up", tint: .teal)
                InventoryStatTile(title: "In Printers", value: "\(inPrinter)", detail: "Loaded in AMS", systemImage: "printer", tint: .purple)
                InventoryStatTile(title: "Low Stock", value: "\(low)", detail: "Below \(Int(store.lowStockThreshold))%", systemImage: "exclamationmark.triangle", tint: .yellow) {
                    if session.can("settings:update") {
                        Button { thresholdText = String(Int(store.lowStockThreshold)); showThreshold = true } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless).accessibilityLabel("Edit low stock threshold")
                    }
                }
                .onTapGesture { filters.usage = .lowStock }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func spoolMenu(_ spool: InventorySpool) -> some View {
        if canEdit {
            Button { formRequest = .edit(spool.id) } label: { Label("Edit", systemImage: "pencil") }
            Button { formRequest = .copy(spool.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        }
        Button { labelIDs = InventorySpoolIDs(ids: [spool.id]) } label: { Label("Print Label…", systemImage: "printer") }
        if canEdit && !spool.isArchived {
            Button { assignSpool = spool } label: { Label("Assign to Printer Slot…", systemImage: "tray.and.arrow.down") }
        }
        if canEdit {
            Button { confirm = .resetCounter(spool.id) } label: { Label("Reset Consumed Counter", systemImage: "eraser") }
            Divider()
            if spool.isArchived {
                Button { Task { await runner.run("Spool restored") { try await store.restore(spool.id) } } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            } else {
                Button { confirm = .archive(spool.id) } label: { Label("Archive", systemImage: "archivebox") }
            }
            Button(role: .destructive) { confirm = .delete(spool.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == sortedSpools.count ? "Deselect All" : "Select All") {
                    if selection.count == sortedSpools.count { selection.removeAll() } else { selection = Set(sortedSpools.map(\.id)) }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { selecting = false; selection.removeAll() }
            }
            ToolbarItemGroup(placement: .bottomBar) { bulkBar }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button { showFilters = true } label: {
                    Label("Filters", systemImage: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if canEdit {
                    Button { formRequest = .create } label: { Label("Add Spool", systemImage: "plus") }
                }
            }
            ToolbarItem(placement: .secondaryAction) { moreMenu }
        }
    }

    @ViewBuilder
    private var bulkBar: some View {
        let ids = Array(selection).sorted()
        let showingArchived = filters.status == .archived
        Text("\(ids.count) selected").font(.footnote).foregroundStyle(.secondary)
        Spacer()
        Menu {
            if canEdit {
                Button { bulkEditIDs = InventorySpoolIDs(ids: ids) } label: { Label("Edit Fields…", systemImage: "pencil") }
            }
            Button { labelIDs = InventorySpoolIDs(ids: ids) } label: { Label("Print Labels…", systemImage: "printer") }
            if canEdit {
                Button { confirm = .bulkReset(ids) } label: { Label("Reset Usage", systemImage: "eraser") }
                if showingArchived {
                    Button { confirm = .bulkRestore(ids) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                } else {
                    Button { confirm = .bulkArchive(ids) } label: { Label("Archive", systemImage: "archivebox") }
                }
                Button(role: .destructive) { confirm = .bulkDelete(ids) } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .disabled(ids.isEmpty)
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button { selecting = true } label: { Label("Select Spools", systemImage: "checkmark.circle") }
                Picker(selection: $gridMode) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Cards", systemImage: "square.grid.2x2").tag(true)
                } label: { Label("View", systemImage: "rectangle.grid.1x2") }
                    .pickerStyle(.menu)
            }
            Section {
                Picker(selection: $sortRaw) {
                    ForEach(InventorySort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                } label: { Label("Sort By", systemImage: "arrow.up.arrow.down") }
                    .pickerStyle(.menu)
                Picker(selection: $ascending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                } label: { Label("Order", systemImage: ascending ? "arrow.up" : "arrow.down") }
                    .pickerStyle(.menu)
                Picker(selection: $groupingRaw) {
                    ForEach(InventoryGrouping.allCases) { Text($0.rawValue).tag($0.rawValue) }
                } label: { Label("Group By", systemImage: "rectangle.3.group") }
                    .pickerStyle(.menu)
                Toggle(isOn: $groupSimilar) { Label("Collapse Identical Spools", systemImage: "square.stack") }
                Toggle(isOn: $showStats) { Label("Show Summary", systemImage: "chart.bar.xaxis") }
            }
            Section {
                if canForecast {
                    Button { path.append(InventoryRoute.forecast) } label: { Label("Forecast & Shopping List", systemImage: "chart.line.uptrend.xyaxis") }
                }
                if !store.isSpoolman {
                    Button { path.append(InventoryRoute.usageLog) } label: { Label("Usage Log", systemImage: "clock.arrow.circlepath") }
                }
                Button { labelIDs = InventorySpoolIDs(ids: sortedSpools.map(\.id)) } label: { Label("Print Labels…", systemImage: "printer") }
                    .disabled(sortedSpools.isEmpty)
            }
            Section("Manage") {
                Button { path.append(InventoryRoute.locations) } label: { Label("Storage Locations", systemImage: "mappin.and.ellipse") }
                Button { path.append(InventoryRoute.spoolCatalog) } label: { Label("Empty Spool Weights", systemImage: "scalemass") }
                Button { path.append(InventoryRoute.colorCatalog) } label: { Label("Color Catalog", systemImage: "paintpalette") }
                if session.can("filaments:read") {
                    Button { path.append(InventoryRoute.filamentCatalog) } label: { Label("Filament Types", systemImage: "list.bullet.rectangle") }
                }
            }
            if canEdit {
                Section {
                    if !store.isSpoolman {
                        Button { showImport = true } label: { Label("Import CSV…", systemImage: "square.and.arrow.down") }
                        Button {
                            Task { await runner.run { exportURL = try await store.exportCSV() } }
                        } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    }
                    Button { confirm = .syncAMS } label: { Label("Sync Weights from AMS", systemImage: "arrow.triangle.2.circlepath") }
                }
            }
            if store.isSpoolman {
                Section("Spoolman") {
                    Button { showSpoolman = true } label: { Label("Spoolman Status", systemImage: "link") }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    // MARK: Filter sheet

    private var filterSheet: some View {
        let spools = store.spools
        let materials = Set(spools.compactMap(\.material).filter { !$0.isEmpty }).sorted()
        let brands = Set(spools.compactMap(\.brand).filter { !$0.isEmpty }).sorted()
        let categories = Set(spools.compactMap { $0.category?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).sorted()
        let catalogIds = Set(spools.compactMap(\.coreWeightCatalogId))
        return NavigationStack {
            Form {
                Section {
                    Picker("Status", selection: $filters.status) {
                        ForEach(InventoryFilters.Status.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Usage", selection: $filters.usage) {
                        ForEach(InventoryFilters.Usage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Slicer Preset", selection: $filters.stock) {
                        ForEach(InventoryFilters.Stock.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } footer: {
                    Text("“Stock Only” spools have no slicer preset yet; “Configured” spools do.")
                }
                Section("Filament") {
                    Picker("Material", selection: $filters.material) {
                        Text("Any").tag("")
                        ForEach(materials, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Brand", selection: $filters.brand) {
                        Text("Any").tag("")
                        ForEach(brands, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Category", selection: $filters.category) {
                        Text("Any").tag("")
                        Text("Uncategorized").tag(InventoryFilters.none)
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    if !catalogIds.isEmpty {
                        Picker("Spool Type", selection: $filters.spoolType) {
                            Text("Any").tag("")
                            ForEach(store.spoolCatalog.filter { catalogIds.contains($0.id) }) { Text($0.name).tag(String($0.id)) }
                        }
                    }
                }
                Section("Storage") {
                    Picker("Location", selection: $filters.storage) {
                        Text("Any").tag("")
                        Text("No Location").tag(InventoryFilters.none)
                        ForEach(store.locations) { Text($0.name).tag(String($0.id)) }
                    }
                }
                if filters.isActive {
                    Section {
                        Button("Clear All Filters", role: .destructive) { filters = InventoryFilters() }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showFilters = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Actions

    private func perform(_ action: InventoryConfirmAction) {
        Task {
            switch action {
            case .delete(let id):
                await runner.run("Spool deleted") { try await store.delete(id) }
            case .archive(let id):
                await runner.run("Spool archived") { try await store.archive(id) }
            case .resetCounter(let id):
                await runner.run("Counter reset") { try await store.resetConsumedCounter(id) }
            case .bulkDelete(let ids):
                await runBulk("deleted") { try await store.bulk(.delete, ids: ids) }
            case .bulkArchive(let ids):
                await runBulk("archived") { try await store.bulk(.archive, ids: ids) }
            case .bulkRestore(let ids):
                await runBulk("restored") { try await store.bulk(.restore, ids: ids) }
            case .bulkReset(let ids), .resetAll(let ids):
                await runBulk("reset") { try await store.bulkResetConsumed(ids: ids) }
            case .syncAMS:
                await runner.run {
                    let message = try await store.syncAMSWeights()
                    runner.successMessage = message
                }
            }
        }
    }

    private func runBulk(_ verb: String, _ work: () async throws -> InventoryBulkResult) async {
        await runner.run {
            let result = try await work()
            let failed = result.failedCount
            if result.succeeded == 0 && failed > 0 {
                runner.errorMessage = "None of the \(failed) spools could be \(verb)."
                return
            }
            runner.successMessage = failed > 0 ? "\(result.succeeded) \(verb), \(failed) failed" : "\(result.succeeded) spools \(verb)"
            selection.removeAll()
            selecting = false
        }
    }
}

/// Comparable sort key mixing text and numbers.
private enum InventorySortKey: Comparable {
    case text(String)
    case number(Double)

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): a.localizedStandardCompare(b) == .orderedAscending
        case (.number(let a), .number(let b)): a < b
        case (.number, .text): true
        case (.text, .number): false
        }
    }

    static func hue(_ rgba: String?) -> Double {
        guard let c = InventoryColors.color(rgba) else { return 10 }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Greys sort before hues, ordered by brightness.
        if s < 0.12 { return Double(b) - 2 }
        return Double(h)
    }
}

private struct InventoryStatTile<Accessory: View>: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    @ViewBuilder var accessory: Accessory

    init(title: String, value: String, detail: String, systemImage: String, tint: Color, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.value = value
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Spacer(minLength: 4)
                accessory.font(.caption)
            }
            Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(width: 170, alignment: .leading)
        .frame(minHeight: 78, alignment: .top)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

/// A floating bar offering to share a generated file.
struct InventoryShareBar: View {
    let url: URL
    let title: String
    var onDismiss: () -> Void

    var body: some View {
        HStack {
            Label(title, systemImage: "doc").font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer()
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
            Button { onDismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Spools collapsed together by "Collapse Identical Spools".
struct InventorySimilarSpoolsView: View {
    @Environment(InventoryStore.self) private var store
    let ids: [Int]

    var body: some View {
        let spools = ids.compactMap { store.spool($0) }
        List(spools) { spool in
            NavigationLink(value: InventoryRoute.spool(spool.id)) {
                InventorySpoolRow(spool: spool, slot: store.slot(for: spool.id), storage: store.storageLabel(for: spool), lowStockThreshold: store.lowStockThreshold)
            }
        }
        .navigationTitle(spools.first?.materialLine ?? "Spools")
        .overlay {
            if spools.isEmpty { ContentUnavailableView("No Spools", systemImage: "circle.circle") }
        }
    }
}
