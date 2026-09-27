import SwiftUI

/// Filters for the delivery log (`GET /notifications/logs`).
struct SettingsNotificationLogFilter: Hashable, Sendable {
    enum Status: String, CaseIterable, Hashable, Sendable {
        case all, delivered, failed
        var title: String {
            switch self {
            case .all: "All"
            case .delivered: "Delivered"
            case .failed: "Failed"
            }
        }
    }

    var days = 7
    var status: Status = .all
    var providerId: Int?
    var eventType: String?

    static let periods: [(days: Int, label: String)] = [(1, "24 Hours"), (7, "7 Days"), (30, "30 Days"), (90, "90 Days")]

    var isFiltered: Bool { status != .all || providerId != nil || eventType != nil }

    func query(limit: Int, offset: Int) -> [String: QueryValue?] {
        [
            "limit": .int(limit),
            "offset": .int(offset),
            "days": .int(days),
            "provider_id": .of(providerId),
            "event_type": .of(eventType),
            "success": status == .all ? nil : .bool(status == .delivered),
        ]
    }
}

/// The notification delivery log with stats, filters, paging and clean-up.
struct SettingsNotificationLogView: View {
    @Environment(AppSession.self) private var session

    let providers: [SettingsNotificationProvider]

    @State private var filter = SettingsNotificationLogFilter()
    @State private var entries: [SettingsNotificationLog] = []
    @State private var stats: SettingsNotificationLogStats?
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var canLoadMore = false
    @State private var isLoadingMore = false
    @State private var clearDays: Int?
    @State private var runner = ActionRunner()

    private static let pageSize = 50

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $filter.days) {
                    ForEach(SettingsNotificationLogFilter.periods, id: \.days) { period in
                        Text(period.label).tag(period.days)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if let stats { statsSection(stats) }

            if filter.isFiltered {
                Section {
                    Button("Clear Filters", systemImage: "xmark.circle") {
                        filter.status = .all
                        filter.providerId = nil
                        filter.eventType = nil
                    }
                } footer: {
                    Text(activeFilterDescription)
                }
            }

            Section {
                ForEach(entries) { entry in
                    NavigationLink {
                        SettingsNotificationLogDetailView(entry: entry)
                    } label: {
                        SettingsNotificationLogRow(entry: entry)
                    }
                }
                if canLoadMore {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack {
                            Text("Load More")
                            Spacer()
                            if isLoadingMore { ProgressView() }
                        }
                    }
                    .disabled(isLoadingMore)
                }
            } header: {
                if !entries.isEmpty { Text("Deliveries") }
            }
        }
        .overlay {
            if !hasLoaded {
                ProgressView()
            } else if let loadError, entries.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                } description: { Text(loadError) } actions: {
                    Button("Try Again") { Task { await reload() } }.buttonStyle(.bordered)
                }
            } else if entries.isEmpty {
                ContentUnavailableView(
                    filter.status == .failed ? "No Failures" : "No Notifications",
                    systemImage: filter.status == .failed ? "checkmark.seal" : "tray",
                    description: Text(filter.isFiltered
                        ? "Nothing matches these filters in the selected period."
                        : "Nothing was sent in the selected period.")
                )
            }
        }
        .navigationTitle("Delivery Log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { filterMenu }
            if session.can("notifications:delete") {
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        ForEach([7, 30, 90], id: \.self) { days in
                            Button("Older Than \(days) Days", role: .destructive) { clearDays = days }
                        }
                    } label: {
                        Label("Delete Old Entries", systemImage: "trash")
                    }
                }
            }
        }
        .task(id: filter) { await reload() }
        .refreshable { await reload() }
        .confirm("Delete Old Entries?", isPresented: Binding(get: { clearDays != nil }, set: { if !$0 { clearDays = nil } }),
                 message: clearDays.map { "Log entries older than \($0) days will be permanently deleted. Newer entries are kept." }) {
            if let days = clearDays { Task { await clear(olderThan: days) } }
        }
        .actionAlerts(runner)
    }

    // MARK: Pieces

    private var filterMenu: some View {
        Menu {
            Picker("Status", selection: $filter.status) {
                ForEach(SettingsNotificationLogFilter.Status.allCases, id: \.self) { status in
                    Text(status.title).tag(status)
                }
            }
            .pickerStyle(.inline)
            if !providers.isEmpty || filter.providerId != nil {
                Picker("Provider", selection: $filter.providerId) {
                    Text("All Providers").tag(Int?.none)
                    ForEach(providers) { provider in
                        Text(provider.name).tag(Int?.some(provider.id))
                    }
                    if let id = filter.providerId, !providers.contains(where: { $0.id == id }) {
                        Text("Provider \(id)").tag(Int?.some(id))
                    }
                }
                .pickerStyle(.menu)
            }
            Picker("Event", selection: $filter.eventType) {
                Text("All Events").tag(String?.none)
                ForEach(eventTypeChoices, id: \.self) { type in
                    Text(SettingsNotificationEventNames.name(for: type)).tag(String?.some(type))
                }
            }
            .pickerStyle(.menu)
        } label: {
            Label("Filter", systemImage: filter.isFiltered
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private var eventTypeChoices: [String] {
        var types = Set(stats?.byEventType?.keys.map { $0 } ?? [])
        if types.isEmpty { types = Set(SettingsNotificationEventNames.knownEventTypes) }
        if let selected = filter.eventType { types.insert(selected) }
        return types.sorted { SettingsNotificationEventNames.name(for: $0) < SettingsNotificationEventNames.name(for: $1) }
    }

    private var activeFilterDescription: String {
        var parts: [String] = []
        if filter.status != .all { parts.append(filter.status.title) }
        if let id = filter.providerId { parts.append(providers.first { $0.id == id }?.name ?? "Provider \(id)") }
        if let type = filter.eventType { parts.append(SettingsNotificationEventNames.name(for: type)) }
        return "Showing: " + parts.joined(separator: " · ")
    }

    private func statsSection(_ stats: SettingsNotificationLogStats) -> some View {
        Section {
            HStack(spacing: 0) {
                statTile("Sent", value: stats.total ?? 0, color: .primary)
                Divider()
                statTile("Delivered", value: stats.successCount ?? 0, color: .green)
                Divider()
                statTile("Failed", value: stats.failureCount ?? 0, color: (stats.failureCount ?? 0) > 0 ? .red : .secondary)
            }
            .padding(.vertical, 4)
            if let byProvider = stats.byProvider, !byProvider.isEmpty {
                DisclosureGroup("By Provider") {
                    ForEach(byProvider.sorted { $0.value > $1.value }, id: \.key) { name, count in
                        LabeledContent(name, value: count, format: .number)
                    }
                }
            }
            if let byEvent = stats.byEventType, !byEvent.isEmpty {
                DisclosureGroup("By Event") {
                    ForEach(byEvent.sorted { $0.value > $1.value }, id: \.key) { type, count in
                        Button {
                            filter.eventType = type
                        } label: {
                            LabeledContent(SettingsNotificationEventNames.name(for: type), value: count, format: .number)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        } header: {
            Text("Last \(SettingsNotificationLogFilter.periods.first { $0.days == filter.days }?.label.lowercased() ?? "\(filter.days) days")")
        }
    }

    private func statTile(_ title: String, value: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Loading

    private func reload() async {
        let client = session.client
        let current = filter
        async let statsResult: SettingsNotificationLogStats? = try? client.get("notifications/logs/stats", query: ["days": .int(current.days)])
        do {
            let page: [SettingsNotificationLog] = try await client.get("notifications/logs", query: current.query(limit: Self.pageSize, offset: 0))
            guard current == filter else { return }
            entries = page
            canLoadMore = page.count == Self.pageSize
            loadError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            loadError = error.localizedDescription
        }
        if let s = await statsResult, current.days == filter.days { stats = s }
        hasLoaded = true
    }

    private func loadMore() async {
        isLoadingMore = true
        defer { isLoadingMore = false }
        let current = filter
        await runner.run {
            let page: [SettingsNotificationLog] = try await session.client.get(
                "notifications/logs", query: current.query(limit: Self.pageSize, offset: entries.count))
            guard current == filter else { return }
            let known = Set(entries.map(\.id))
            entries += page.filter { !known.contains($0.id) }
            canLoadMore = page.count == Self.pageSize
        }
    }

    private func clear(olderThan days: Int) async {
        var message = "Old entries deleted"
        await runner.run {
            let result: SettingsNotificationLogClearResult = try await session.client.send(
                .delete, "notifications/logs", query: ["older_than_days": .int(days)])
            if let deleted = result.deleted {
                message = deleted == 1 ? "Deleted 1 entry" : "Deleted \(deleted) entries"
            }
        }
        if runner.errorMessage == nil {
            runner.successMessage = message
            await reload()
        }
    }
}

// MARK: - Row & detail

private struct SettingsNotificationLogRow: View {
    let entry: SettingsNotificationLog

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.success == true ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(entry.success == true ? .green : .red)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.title?.isEmpty == false ? entry.title! : SettingsNotificationEventNames.name(for: entry.eventType ?? ""))
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = entry.createdAt {
                        Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text([entry.providerName ?? "Deleted provider",
                      entry.eventType.map(SettingsNotificationEventNames.name(for:)),
                      entry.printerName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if entry.success != true, let error = entry.errorMessage, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if let message = entry.message, !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
        }
    }
}

private struct SettingsNotificationLogDetailView: View {
    let entry: SettingsNotificationLog

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    if entry.success == true {
                        Label("Delivered", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                InfoRow("Event", entry.eventType.map(SettingsNotificationEventNames.name(for:)))
                InfoRow("Provider", entry.providerName ?? "Deleted provider")
                InfoRow("Type", entry.providerType.map(SettingsNotificationProviderKind.title(for:)))
                InfoRow("Printer", entry.printerName)
                InfoRow("Sent", entry.createdAt?.formatted(date: .abbreviated, time: .standard))
            }
            if let error = entry.errorMessage, !error.isEmpty {
                Section("Error") {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section("Title") {
                Text(entry.title ?? "—").textSelection(.enabled)
            }
            Section("Message") {
                Text(entry.message ?? "—").textSelection(.enabled)
            }
        }
        .navigationTitle(entry.eventType.map(SettingsNotificationEventNames.name(for:)) ?? "Notification")
        .navigationBarTitleDisplayMode(.inline)
    }
}
