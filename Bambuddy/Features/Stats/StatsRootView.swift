import SwiftUI
import Charts
import QuickLook

struct StatsRootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        NavigationStack {
            if session.can("stats:read") {
                StatsDashboardView()
            } else {
                ContentUnavailableView("No Access", systemImage: "lock", description: Text("You don't have permission to view statistics."))
                    .navigationTitle("Statistics")
            }
        }
    }
}

// MARK: - Dashboard layout

enum StatsWidgetKind: String, CaseIterable, Identifiable, Sendable {
    case quickStats = "quick-stats"
    case successRate = "success-rate"
    case timeAccuracy = "time-accuracy"
    case failureAnalysis = "failure-analysis"
    case printActivity = "print-activity"
    case records
    case printerStats = "printer-stats"
    case filamentTrends = "filament-trends"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickStats: "Quick Stats"
        case .successRate: "Success Rate"
        case .timeAccuracy: "Time Accuracy"
        case .failureAnalysis: "Failure Analysis"
        case .printActivity: "Print Activity"
        case .records: "Records"
        case .printerStats: "Printer Stats"
        case .filamentTrends: "Filament Trends"
        }
    }

    var systemImage: String {
        switch self {
        case .quickStats: "square.grid.2x2.fill"
        case .successRate: "checkmark.seal.fill"
        case .timeAccuracy: "timer"
        case .failureAnalysis: "exclamationmark.triangle.fill"
        case .printActivity: "calendar"
        case .records: "trophy.fill"
        case .printerStats: "printer.fill"
        case .filamentTrends: "chart.xyaxis.line"
        }
    }

    var tint: Color {
        switch self {
        case .quickStats: .green
        case .successRate: .green
        case .timeAccuracy: .blue
        case .failureAnalysis: .orange
        case .printActivity: .green
        case .records: .yellow
        case .printerStats: .blue
        case .filamentTrends: .purple
        }
    }

    /// Wide widgets take the full row; compact ones share an adaptive grid.
    var isWide: Bool { self == .printerStats || self == .filamentTrends }
}

/// Persisted order + visibility of dashboard widgets.
struct StatsLayout: Equatable, Sendable {
    var order: [StatsWidgetKind]
    var hidden: Set<StatsWidgetKind>

    static let standard = StatsLayout(order: StatsWidgetKind.allCases, hidden: [])

    init(order: [StatsWidgetKind], hidden: Set<StatsWidgetKind>) {
        self.order = order
        self.hidden = hidden
    }

    init(orderRaw: String, hiddenRaw: String) {
        var order = orderRaw.split(separator: ",").compactMap { StatsWidgetKind(rawValue: String($0)) }
        var seen = Set<StatsWidgetKind>()
        order = order.filter { seen.insert($0).inserted }
        order += StatsWidgetKind.allCases.filter { !seen.contains($0) }
        self.order = order
        self.hidden = Set(hiddenRaw.split(separator: ",").compactMap { StatsWidgetKind(rawValue: String($0)) })
    }

    var orderRaw: String { order.map(\.rawValue).joined(separator: ",") }
    var hiddenRaw: String { order.filter { hidden.contains($0) }.map(\.rawValue).joined(separator: ",") }
    var visible: [StatsWidgetKind] { order.filter { !hidden.contains($0) } }
}

// MARK: - Loaded data

private struct StatsBundle {
    var summary: StatsSummary
    var runs: [StatsPrintRun]
    var runsError: String?
    var failures: StatsFailureAnalysis?
}

private struct StatsLoadKey: Hashable {
    var from: String?
    var to: String?
    var user: Int?
    var printer: Int?
    var revision: Int
    var manual: Int
}

private struct StatsExportRequest: Identifiable, Hashable {
    var format: String
    var days: Int
    var id: String { "\(format)-\(days)" }
}

private struct StatsDashboardView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printerStore
    @Environment(LiveUpdates.self) private var live
    @Environment(\.horizontalSizeClass) private var sizeClass

    @AppStorage("stats.timeframe") private var timeframeRaw = StatsTimeframe.allTime.rawValue
    @AppStorage("stats.customFrom") private var customFromRaw: Double = 0
    @AppStorage("stats.customTo") private var customToRaw: Double = 0
    @AppStorage("stats.layout.order") private var layoutOrderRaw = ""
    @AppStorage("stats.layout.hidden") private var layoutHiddenRaw = ""

    @State private var loader = Loader<StatsBundle>()
    @State private var runner = ActionRunner()
    @State private var userFilter: Int?
    @State private var printerFilter: Int?
    @State private var users: [StatsUserOption] = []
    @State private var currencyCode = "USD"
    @State private var manualReload = 0
    @State private var showCustomRange = false
    @State private var showCustomize = false
    @State private var confirmRecalculate = false
    @State private var exportURL: URL?
    @State private var isExporting = false

    private var timeframe: StatsTimeframe { StatsTimeframe(rawValue: timeframeRaw) ?? .allTime }
    private var customFrom: Date? { customFromRaw > 0 ? Date(timeIntervalSince1970: customFromRaw) : nil }
    private var customTo: Date? { customToRaw > 0 ? Date(timeIntervalSince1970: customToRaw) : nil }
    private var range: (from: Date?, to: Date?) { timeframe.range(customFrom: customFrom, customTo: customTo) }
    private var layout: StatsLayout { StatsLayout(orderRaw: layoutOrderRaw, hiddenRaw: layoutHiddenRaw) }
    private var canFilterByUser: Bool { session.isAuthEnabled && session.can("stats:filter_by_user") }

    private var spanDays: Double? {
        guard let from = range.from else { return nil }
        let end = range.to ?? Calendar.current.startOfDay(for: .now)
        return max(0, end.timeIntervalSince(from) / 86400) + 1
    }

    private var loadKey: StatsLoadKey {
        StatsLoadKey(from: StatsTimeframe.apiDay(range.from), to: StatsTimeframe.apiDay(range.to),
                     user: userFilter, printer: printerFilter,
                     revision: live.revision("print_complete", "archive_created", "archive_updated"),
                     manual: manualReload)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterBar
                LoadingContent(loader: loader, retry: { await load(loadKey) }) { bundle in
                    dashboard(bundle)
                }
                .frame(minHeight: loader.value == nil ? 300 : nil)
            }
            .padding(.horizontal, sizeClass == .regular ? 24 : 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Statistics")
        .toolbar { toolbar }
        .refreshable { await load(loadKey) }
        .task(id: loadKey) { await load(loadKey) }
        .task { await loadAuxiliary() }
        .sheet(isPresented: $showCustomRange) {
            StatsCustomRangeSheet(from: customFrom ?? Calendar.current.date(byAdding: .day, value: -29, to: .now) ?? .now,
                                  to: customTo ?? .now) { from, to in
                customFromRaw = from.timeIntervalSince1970
                customToRaw = to.timeIntervalSince1970
                timeframeRaw = StatsTimeframe.custom.rawValue
            }
        }
        .sheet(isPresented: $showCustomize) {
            StatsCustomizeSheet(layout: layout) { new in
                layoutOrderRaw = new.orderRaw
                layoutHiddenRaw = new.hiddenRaw
            }
        }
        .quickLookPreview($exportURL)
        .confirmationDialog("Recalculate Costs?", isPresented: $confirmRecalculate, titleVisibility: .visible) {
            Button("Recalculate") { Task { await recalculate() } }
        } message: {
            Text("Every archived print's cost will be recomputed from current filament prices and spool usage.")
        }
        .actionAlerts(runner)
        #if DEBUG
        .onAppear(perform: applyDebugArguments)
        #endif
    }

    // MARK: Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Timeframe", selection: Binding(get: { timeframe }, set: { timeframeRaw = $0.rawValue })) {
                        ForEach(StatsTimeframe.allCases.filter { $0 != .custom }) { t in Text(t.title).tag(t) }
                    }
                    Divider()
                    Button { showCustomRange = true } label: {
                        Label(timeframe == .custom ? "Edit Custom Range…" : "Custom Range…", systemImage: "calendar.badge.clock")
                    }
                } label: {
                    chip(timeframeLabel, systemImage: "calendar", active: timeframe != .allTime)
                }

                Menu {
                    Picker("Printer", selection: $printerFilter) {
                        Text("All Printers").tag(Int?.none)
                        ForEach(printerOptions, id: \.id) { p in Text(p.name).tag(Int?.some(p.id)) }
                    }
                } label: {
                    chip(printerFilter.map { printerName(String($0)) } ?? "All Printers", systemImage: "printer", active: printerFilter != nil)
                }

                if canFilterByUser && !users.isEmpty {
                    Menu {
                        Picker("User", selection: $userFilter) {
                            Text("All Users").tag(Int?.none)
                            Text("No User (System)").tag(Int?.some(-1))
                            Divider()
                            ForEach(users) { u in Text(u.username ?? "User \(u.id)").tag(Int?.some(u.id)) }
                        }
                    } label: {
                        chip(userLabel, systemImage: "person.2", active: userFilter != nil)
                    }
                }

                if loader.isLoading && loader.value != nil {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                }
            }
        }
        .scrollClipDisabled()
    }

    private func chip(_ text: String, systemImage: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(active ? Color.white : Color.primary)
        .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: .capsule)
        .contentShape(.capsule)
    }

    private var timeframeLabel: String {
        guard timeframe == .custom else { return timeframe.title }
        let f = range.from?.formatted(.dateTime.month(.abbreviated).day()) ?? "…"
        let t = range.to?.formatted(.dateTime.month(.abbreviated).day()) ?? "Today"
        return "\(f) – \(t)"
    }

    private var userLabel: String {
        guard let id = userFilter else { return "All Users" }
        if id == -1 { return "No User" }
        return users.first(where: { $0.id == id })?.username ?? "User \(id)"
    }

    private var printerOptions: [(id: Int, name: String)] {
        var map: [Int: String] = [:]
        for (k, v) in loader.value?.summary.printerNames ?? [:] { if let id = Int(k) { map[id] = v } }
        for p in printerStore.printers { map[p.id] = p.name }
        return map.map { ($0.key, $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func printerName(_ key: String) -> String {
        if let id = Int(key), let p = printerStore.printer(id) { return p.name }
        if let n = loader.value?.summary.printerNames?[key], !n.isEmpty { return n }
        return key == "unknown" || key.isEmpty ? "Unknown" : "Printer \(key)"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Menu {
                    exportButtons(format: "csv")
                } label: { Label("Export as CSV", systemImage: "doc.text") }
                Menu {
                    exportButtons(format: "xlsx")
                } label: { Label("Export as Excel", systemImage: "tablecells") }
                Divider()
                Button { confirmRecalculate = true } label: {
                    Label("Recalculate Costs", systemImage: "function")
                }
                .disabled(!session.can("archives:update_all"))
                Divider()
                Button { showCustomize = true } label: {
                    Label("Customize Dashboard", systemImage: "slider.horizontal.3")
                }
                if layout != .standard {
                    Button { layoutOrderRaw = ""; layoutHiddenRaw = ""; runner.successMessage = "Layout reset" } label: {
                        Label("Reset Layout", systemImage: "arrow.counterclockwise")
                    }
                }
            } label: {
                if isExporting || runner.isRunning {
                    ProgressView()
                } else {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }

    @ViewBuilder
    private func exportButtons(format: String) -> some View {
        ForEach([30, 90, 365], id: \.self) { days in
            Button("Last \(days) Days") { Task { await export(StatsExportRequest(format: format, days: days)) } }
        }
    }

    // MARK: Dashboard

    @ViewBuilder
    private func dashboard(_ bundle: StatsBundle) -> some View {
        let runs = printerFilter.map { id in bundle.runs.filter { $0.printerId == id } } ?? bundle.runs
        let summary: StatsSummary = {
            guard let id = printerFilter else { return bundle.summary }
            var s = StatsAggregator.summary(from: runs, printerId: id)
            s.printerNames = bundle.summary.printerNames
            s.timeAccuracyByPrinter = bundle.summary.timeAccuracyByPrinter
            return s
        }()
        let visible = layout.visible
        VStack(alignment: .leading, spacing: 16) {
            if let err = bundle.runsError {
                Label("Per-print data unavailable: \(err)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if visible.isEmpty {
                ContentUnavailableView {
                    Label("All Widgets Hidden", systemImage: "eye.slash")
                } actions: {
                    Button("Customize") { showCustomize = true }.buttonStyle(.bordered)
                }
            }
            ForEach(segments(visible), id: \.first) { segment in
                if segment.count == 1, segment[0].isWide {
                    widget(segment[0], bundle: bundle, runs: runs, summary: summary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(segment) { kind in widget(kind, bundle: bundle, runs: runs, summary: summary) }
                    }
                }
            }
        }
    }

    /// Groups consecutive compact widgets; wide widgets stand alone.
    private func segments(_ kinds: [StatsWidgetKind]) -> [[StatsWidgetKind]] {
        var out: [[StatsWidgetKind]] = []
        var current: [StatsWidgetKind] = []
        for k in kinds {
            if k.isWide {
                if !current.isEmpty { out.append(current); current = [] }
                out.append([k])
            } else {
                current.append(k)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    @ViewBuilder
    private func widget(_ kind: StatsWidgetKind, bundle: StatsBundle, runs: [StatsPrintRun], summary: StatsSummary) -> some View {
        StatsCard(kind.title, systemImage: kind.systemImage, tint: kind.tint) {
            switch kind {
            case .quickStats:
                StatsQuickStatsView(summary: summary, currencyCode: currencyCode, printerFiltered: printerFilter != nil)
            case .successRate:
                StatsSuccessRateView(summary: summary, printerName: printerName)
            case .timeAccuracy:
                StatsTimeAccuracyView(summary: summary, printerName: printerName, selectedPrinter: printerFilter)
            case .failureAnalysis:
                StatsFailureSummaryView(analysis: bundle.failures, hasDateRange: range.from != nil || range.to != nil) { printerName(String($0)) }
            case .printActivity:
                StatsActivityView(runs: runs, from: range.from, to: range.to)
            case .records:
                StatsRecordsView(records: StatsAggregator.records(runs, currencyCode: currencyCode))
            case .printerStats:
                StatsPrinterBreakdownView(runs: runs, printCounts: printerFilter == nil ? bundle.summary.printsByPrinter : summary.printsByPrinter, printerName: printerName)
            case .filamentTrends:
                StatsFilamentTrendsView(runs: runs, currencyCode: currencyCode, spanDays: spanDays)
            }
        }
        .contextMenu {
            Button { hide(kind) } label: { Label("Hide Widget", systemImage: "eye.slash") }
            Button { showCustomize = true } label: { Label("Customize Dashboard", systemImage: "slider.horizontal.3") }
        }
    }

    private func hide(_ kind: StatsWidgetKind) {
        var l = layout
        l.hidden.insert(kind)
        layoutOrderRaw = l.orderRaw
        layoutHiddenRaw = l.hiddenRaw
    }

    // MARK: Loading & actions

    private func load(_ key: StatsLoadKey) async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-statsSampleData") {
            loader.value = StatsBundle(summary: StatsSampleData.summary, runs: StatsSampleData.runs, failures: StatsSampleData.failures)
            return
        }
        #endif
        let client = session.client
        await loader.load {
            let base: [String: QueryValue?] = ["date_from": .of(key.from), "date_to": .of(key.to), "created_by_id": .of(key.user)]
            var failureQuery = base
            if key.from == nil && key.to == nil { failureQuery["days"] = 30 }
            failureQuery["printer_id"] = .of(key.printer)
            async let summaryTask: StatsSummary = client.get("archives/stats", query: base)
            async let runsTask: [StatsPrintRun] = client.get("archives/slim", query: base)
            async let failuresTask: StatsFailureAnalysis = client.get("archives/analysis/failures", query: failureQuery)
            let summary = try await summaryTask
            var runs: [StatsPrintRun] = []
            var runsError: String?
            do { runs = try await runsTask } catch { runsError = error.localizedDescription }
            let failures = try? await failuresTask
            return StatsBundle(summary: summary, runs: runs, runsError: runsError, failures: failures)
        }
    }

    private func loadAuxiliary() async {
        let client = session.client
        if let settings = try? await client.get("settings/", as: JSONValue.self),
           let code = settings["currency"]?.stringValue, !code.isEmpty {
            currencyCode = code.uppercased()
        }
        if canFilterByUser, let list: [StatsUserOption] = try? await client.get("users/slim") {
            users = list.sorted { ($0.username ?? "").localizedStandardCompare($1.username ?? "") == .orderedAscending }
        }
    }

    private func export(_ request: StatsExportRequest) async {
        isExporting = true
        defer { isExporting = false }
        await runner.run {
            let ext = request.format == "xlsx" ? "xlsx" : "csv"
            let stamp = Date.now.formatted(.iso8601.year().month().day())
            exportURL = try await session.client.download("archives/stats/export", query: [
                "format": .string(request.format),
                "days": .int(request.days),
                "printer_id": .of(printerFilter),
                "created_by_id": .of(userFilter),
            ], suggestedName: "bambuddy-stats-\(request.days)d-\(stamp).\(ext)")
        }
    }

    private func recalculate() async {
        await runner.run {
            let result: StatsRecalculateResult = try await session.client.send(.post, "archives/recalculate-costs")
            runner.successMessage = "Recalculated costs for \(result.updated ?? 0) prints"
            manualReload += 1
        }
    }

    #if DEBUG
    private func applyDebugArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-statsTimeframe"), i + 1 < args.count, StatsTimeframe(rawValue: args[i + 1]) != nil {
            timeframeRaw = args[i + 1]
        }
        if args.contains("-statsCustomize") { showCustomize = true }
    }
    #endif
}

// MARK: - Sheets

private struct StatsCustomRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var from: Date
    @State var to: Date
    let apply: (Date, Date) -> Void

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
                DatePicker("To", selection: $to, in: from...Date.now, displayedComponents: .date)
            }
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply(from, to); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct StatsCustomizeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var layout: StatsLayout
    let save: (StatsLayout) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(layout.order) { kind in
                        Toggle(isOn: Binding(
                            get: { !layout.hidden.contains(kind) },
                            set: { if $0 { layout.hidden.remove(kind) } else { layout.hidden.insert(kind) } }
                        )) {
                            Label(kind.title, systemImage: kind.systemImage)
                        }
                    }
                    .onMove { layout.order.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Drag to reorder. Hidden widgets can be shown again here. The layout is stored on this device.")
                }
                Section {
                    Button("Reset to Default") { layout = .standard }
                        .disabled(layout == .standard)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(layout); dismiss() }
                }
            }
        }
    }
}
