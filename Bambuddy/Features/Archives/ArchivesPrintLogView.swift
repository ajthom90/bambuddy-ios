import SwiftUI

/// Sortable columns accepted by `GET /print-log/?sort_by=`.
enum ArchivesLogSort: String, CaseIterable, Identifiable {
    case date, printName = "print_name", printer, user, status, duration, completedAt = "completed_at"
    case filament, filamentUsed = "filament_used", cost, energy, energyCost = "energy_cost"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .date: "Date"
        case .printName: "Print Name"
        case .printer: "Printer"
        case .user: "User"
        case .status: "Status"
        case .duration: "Duration"
        case .completedAt: "Completed"
        case .filament: "Filament Type"
        case .filamentUsed: "Filament Used"
        case .cost: "Cost"
        case .energy: "Energy"
        case .energyCost: "Energy Cost"
        }
    }
    /// Numbers and dates start descending, text ascending.
    var defaultDescending: Bool {
        [.date, .completedAt, .duration, .filamentUsed, .cost, .energy, .energyCost].contains(self)
    }
}

/// The server-side print log (every run, independent of archives) with
/// filters, sorting, infinite scroll, per-entry edit/delete and clear.
struct ArchivesPrintLogView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Environment(PrinterStore.self) private var printers
    let search: String

    @AppStorage("archivesLogSort") private var sort: ArchivesLogSort = .date
    @AppStorage("archivesLogSortDescending") private var descending = true
    @State private var printerId: Int?
    @State private var user: String?
    @State private var status: String?
    @State private var dateFrom: Date?
    @State private var dateTo: Date?
    @State private var users: [ArchivesUserOption] = []

    @State private var entries: [ArchivesLogEntry] = []
    @State private var total = 0
    @State private var loaded = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var runner = ActionRunner()
    @State private var editing: ArchivesLogEntry?
    @State private var deleting: ArchivesLogEntry?
    @State private var showClear = false
    @State private var showFilters = false

    private static let pageSize = 50

    private struct QueryKey: Hashable {
        var search: String, sort: String, desc: Bool, printer: Int?, user: String?, status: String?
        var from: Date?, to: Date?, revision: Int
    }

    private var key: QueryKey {
        QueryKey(search: search, sort: sort.rawValue, desc: descending, printer: printerId, user: user, status: status,
                 from: dateFrom, to: dateTo, revision: live.revision("print_complete", "archive_created", "archive_updated", "print_start"))
    }

    private var filterCount: Int {
        [printerId != nil, user != nil, status != nil, dateFrom != nil || dateTo != nil].filter { $0 }.count
    }

    var body: some View {
        List {
            Section {
                filterBar
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            if !loaded {
                if let error {
                    ContentUnavailableView {
                        Label("Couldn't Load Print Log", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Try Again") { Task { await reload() } }.buttonStyle(.bordered)
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
            } else if entries.isEmpty {
                ContentUnavailableView("No Log Entries", systemImage: "list.clipboard", description: Text(filterCount > 0 || !search.isEmpty ? "No prints match these filters." : "Every print run is logged here, even after its archive is deleted."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(entries) { entry in
                        row(entry)
                            .onAppear { if entry.id == entries.last?.id { Task { await loadMore() } } }
                    }
                } header: {
                    Text("\(entries.count) of \(total) entries")
                } footer: {
                    if loadingMore { HStack { Spacer(); ProgressView(); Spacer() } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await reload() }
        .task(id: key) { await reload() }
        .task { users = (try? await session.client.get("users/slim")) ?? [] }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: Binding(get: { sort }, set: { newValue in
                        if newValue == sort { descending.toggle() } else { sort = newValue; descending = newValue.defaultDescending }
                    })) {
                        ForEach(ArchivesLogSort.allCases) { s in
                            if s == sort { Label(s.title, systemImage: descending ? "chevron.down" : "chevron.up").tag(s) } else { Text(s.title).tag(s) }
                        }
                    }
                    Button { descending.toggle() } label: {
                        Label(descending ? "Descending" : "Ascending", systemImage: descending ? "arrow.down" : "arrow.up")
                    }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(role: .destructive) { showClear = true } label: { Label("Clear Print Log", systemImage: "trash") }
                        .disabled(!session.can("archives:delete_all"))
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: $editing) { entry in
            ArchivesLogEntryEditor(entry: entry) { updated in
                if let i = entries.firstIndex(where: { $0.id == updated.id }) { entries[i] = updated }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showFilters) { filterSheet }
        .confirmationDialog("Delete this log entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Entry", role: .destructive) { if let e = deleting { Task { await delete(e) } } }
        } message: {
            Text("Its filament, time and cost drop out of statistics. The archive is not affected.")
        }
        .confirmationDialog("Clear the entire print log?", isPresented: $showClear, titleVisibility: .visible) {
            Button("Clear Print Log", role: .destructive) { Task { await clear() } }
        } message: {
            Text("All log entries are deleted. Archives and queue items are not touched.")
        }
        .actionAlerts(runner)
    }

    // MARK: Rows

    private func row(_ entry: ArchivesLogEntry) -> some View {
        let label = ArchivesLogRow(entry: entry, showThumbnail: true)
        return Group {
            if let archiveId = entry.archiveId {
                NavigationLink(value: ArchivesDetailRoute(id: archiveId)) { label }
            } else {
                label
            }
        }
        .swipeActions(edge: .trailing) {
            if ArchivesPermissions.canDeleteAny(session) {
                Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
            }
            if ArchivesPermissions.canUpdateAny(session) {
                Button { editing = entry } label: { Label("Classify", systemImage: "pencil") }.tint(.blue)
            }
        }
        .contextMenu {
            if ArchivesPermissions.canUpdateAny(session) {
                Button { editing = entry } label: { Label("Edit Status & Reason", systemImage: "pencil") }
            }
            if ArchivesPermissions.canDeleteAny(session) {
                Button(role: .destructive) { deleting = entry } label: { Label("Delete Entry", systemImage: "trash") }
            }
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Printer", selection: $printerId) {
                        Text("All Printers").tag(Int?.none)
                        ForEach(printers.printers) { p in Text(p.name).tag(Int?.some(p.id)) }
                    }
                } label: { chip(printerId.flatMap { printers.printer($0)?.name } ?? "All Printers", "printer", printerId != nil) }
                Menu {
                    Picker("Status", selection: $status) {
                        Text("All Statuses").tag(String?.none)
                        ForEach(ArchivesVocabulary.logStatuses, id: \.self) { s in Text(ArchivesVocabulary.statusLabel(s)).tag(String?.some(s)) }
                    }
                } label: { chip(status.map { ArchivesVocabulary.statusLabel($0) } ?? "All Statuses", "flag", status != nil) }
                if !users.isEmpty {
                    Menu {
                        Picker("User", selection: $user) {
                            Text("All Users").tag(String?.none)
                            ForEach(users) { u in Text(u.username).tag(String?.some(u.username)) }
                        }
                    } label: { chip(user ?? "All Users", "person", user != nil) }
                }
                Button { showFilters = true } label: {
                    chip(dateLabel, "calendar", dateFrom != nil || dateTo != nil)
                }
                .buttonStyle(.plain)
                if filterCount > 0 {
                    Button { printerId = nil; user = nil; status = nil; dateFrom = nil; dateTo = nil } label: { chip("Reset", "xmark", false) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private var dateLabel: String {
        let f = Date.FormatStyle.dateTime.month(.abbreviated).day()
        switch (dateFrom, dateTo) {
        case let (from?, to?): return "\(from.formatted(f)) – \(to.formatted(f))"
        case let (from?, nil): return "From \(from.formatted(f))"
        case let (nil, to?): return "Until \(to.formatted(f))"
        default: return "Any Date"
        }
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                ArchivesOptionalDatePicker(title: "From", date: $dateFrom)
                ArchivesOptionalDatePicker(title: "To", date: $dateTo)
            }
            .navigationTitle("Date Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFilters = false } } }
        }
        .presentationDetents([.medium])
    }

    private func chip(_ title: String, _ image: String, _ active: Bool) -> some View {
        Label(title, systemImage: image)
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(active ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.quaternary), in: .capsule)
            .foregroundStyle(active ? Color.accentColor : .primary)
    }

    // MARK: Loading

    private func query(offset: Int) -> [String: QueryValue?] {
        // The backend takes naive datetimes, like the web's date inputs.
        func day(_ d: Date, _ time: String) -> String {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02dT%@", c.year ?? 1970, c.month ?? 1, c.day ?? 1, time)
        }
        let from = dateFrom.map { day($0, "00:00:00") }
        let to = dateTo.map { day($0, "23:59:59") }
        return [
            "search": search.isEmpty ? nil : .string(search),
            "printer_id": .of(printerId),
            "created_by_username": .of(user),
            "status": .of(status),
            "date_from": .of(from),
            "date_to": .of(to),
            "limit": .int(Self.pageSize),
            "offset": .int(offset),
            "sort_by": .string(sort.rawValue),
            "sort_dir": descending ? "desc" : "asc",
        ]
    }

    private func reload() async {
        do {
            let page: ArchivesLogPage = try await session.client.get("print-log/", query: query(offset: 0))
            entries = page.items
            total = page.total ?? page.items.count
            loaded = true
            error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loadingMore, entries.count < total else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let page: ArchivesLogPage = try? await session.client.get("print-log/", query: query(offset: entries.count)) {
            let known = Set(entries.map(\.id))
            entries += page.items.filter { !known.contains($0.id) }
            total = page.total ?? total
        }
    }

    private func delete(_ entry: ArchivesLogEntry) async {
        await runner.run("Entry deleted") {
            try await session.client.call(.delete, "print-log/\(entry.id)")
            entries.removeAll { $0.id == entry.id }
            total = max(0, total - 1)
        }
        deleting = nil
    }

    private func clear() async {
        await runner.run {
            let result: ArchivesPurgeResult = try await session.client.send(.delete, "print-log/")
            runner.successMessage = "Cleared \(result.deleted ?? 0) entries"
        }
        await reload()
    }
}

/// One print-log entry row.
struct ArchivesLogRow: View {
    @Environment(ArchivesLookups.self) private var lookups
    let entry: ArchivesLogEntry
    var showThumbnail = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showThumbnail {
                Group {
                    if entry.thumbnailPath != nil {
                        RemoteImage(path: "print-log/\(entry.id)/thumbnail", contentMode: .fit, systemImage: "cube")
                    } else {
                        ImagePlaceholder(systemImage: "cube")
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.printName ?? "Untitled print").font(.subheadline.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    ArchivesStatusBadge(status: entry.status)
                }
                Text([Fmt.date(entry.startedAt ?? entry.createdAt), entry.printerName, entry.createdByUsername].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let reason = ArchivesVocabulary.failureLabel(entry.failureReason) {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
                ArchivesFlowLayout(spacing: 10) {
                    if let d = entry.durationSeconds, d > 0 { Label(ArchivesStyle.duration(d), systemImage: "clock") }
                    if entry.filamentType != nil || !entry.colors.isEmpty {
                        HStack(spacing: 4) {
                            ArchivesColorDots(colors: entry.colors.filter { $0.hasPrefix("#") || $0.count >= 6 }, size: 9)
                            Text(entry.filamentType ?? "")
                        }
                    }
                    if let g = entry.filamentUsedGrams { Label(ArchivesStyle.gramsPrecise(g), systemImage: "scalemass") }
                    if let c = entry.cost { Label(lookups.money(c), systemImage: "dollarsign.circle") }
                    if let e = entry.energyKwh { Label("\(Fmt.number(e, digits: 2)) kWh", systemImage: "bolt") }
                    if let ec = entry.energyCost { Label(lookups.money(ec), systemImage: "bolt.circle") }
                    if let done = entry.completedAt { Label(Fmt.date(done, style: .dateTime.hour().minute()), systemImage: "flag.checkered") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Re-classify a print-log entry (status and failure reason).
struct ArchivesLogEntryEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let entry: ArchivesLogEntry
    var onSaved: (ArchivesLogEntry) -> Void
    @State private var status: String
    @State private var reason: String
    @State private var runner = ActionRunner()

    init(entry: ArchivesLogEntry, onSaved: @escaping (ArchivesLogEntry) -> Void) {
        self.entry = entry
        self.onSaved = onSaved
        _status = State(initialValue: entry.status ?? "completed")
        _reason = State(initialValue: entry.failureReason ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Status", selection: $status) {
                        ForEach(statusOptions, id: \.self) { s in Text(ArchivesVocabulary.statusLabel(s)).tag(s) }
                    }
                    Picker("Failure Reason", selection: $reason) {
                        Text("Not specified").tag("")
                        ForEach(ArchivesVocabulary.failureReasons, id: \.key) { r in Text(r.label).tag(r.key) }
                        if !reason.isEmpty, !ArchivesVocabulary.failureReasons.contains(where: { $0.key == reason }) {
                            Text(reason).tag(reason)
                        }
                    }
                } footer: {
                    Text("Corrects how this run counts in statistics and failure analysis.")
                }
            }
            .navigationTitle(entry.printName ?? "Log Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { ProgressView() } else { Button("Save") { Task { await save() } } }
                }
            }
            .actionAlerts(runner)
        }
    }

    private var statusOptions: [String] {
        var list = ArchivesVocabulary.logStatuses
        if let s = entry.status, !list.contains(s) { list.insert(s, at: 0) }
        return list
    }

    private func save() async {
        var body = ArchivesLogEntryUpdate()
        if status != entry.status { body.status = status }
        if reason != (entry.failureReason ?? "") { body.failureReason = .some(reason.isEmpty ? nil : reason) }
        if body.status == nil && body.failureReason == nil { dismiss(); return }
        await runner.run {
            let updated: ArchivesLogEntry = try await session.client.send(.patch, "print-log/\(entry.id)", body: body)
            onSaved(updated)
            dismiss()
        }
    }
}

/// A date row that can be switched off (nil).
struct ArchivesOptionalDatePicker: View {
    let title: String
    @Binding var date: Date?

    var body: some View {
        Section {
            Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? Date()) : nil }))
            if let value = date {
                DatePicker(title, selection: Binding(get: { value }, set: { date = $0 }), displayedComponents: .date)
                    .datePickerStyle(.compact)
            }
        }
    }
}
