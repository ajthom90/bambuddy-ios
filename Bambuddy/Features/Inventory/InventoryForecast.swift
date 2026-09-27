import SwiftUI
import Charts

// MARK: - Engine

/// Consumption forecast for one filament SKU (material + subtype + brand + color).
struct InventorySkuForecast: Identifiable, Sendable {
    enum RateTier: Sendable { case history, delta, none }

    var key: String
    var material: String
    var subtype: String?
    var brand: String?
    var colorName: String?
    var spools: [InventorySpool]
    var settings: InventorySkuSettings?
    var remaining: Double
    var labelTotal: Double
    var consumed: Double
    var dailyRate: Double?
    var dailyStdDev: Double?
    var rateTier: RateTier
    var leadTimeDays: Int
    var safetyStock: Double
    var reorderPoint: Double
    var daysRemaining: Int?
    var daysUntilReorder: Int?
    var emptyDate: Date?
    var reorderDate: Date?
    var reorderAlert: Bool
    var stockBreakAlert: Bool

    var id: String { key }
    var label: String { InventoryFormat.joined([brand, material, subtype, colorName], separator: " ") }
    var isSnoozed: Bool { settings?.alertsSnoozed == true }
    var hasAlert: Bool { !isSnoozed && (reorderAlert || stockBreakAlert) }
    var remainingPercent: Double { labelTotal > 0 ? remaining / labelTotal * 100 : 0 }
    var averageSpoolWeight: Double { spools.isEmpty ? 1000 : spools.reduce(0) { $0 + $1.label } / Double(spools.count) }
    var rgba: String? { spools.first?.rgba }

    /// Projected stock level `day` days from now.
    func projectedStock(day: Int) -> Double {
        guard let dailyRate else { return remaining }
        return max(0, remaining - dailyRate * Double(day))
    }
}

/// Reorder-point forecasting over the inventory, mirroring the server UI's model:
/// a time-weighted daily usage rate from print history (30-day half-life), falling
/// back to lifetime average consumption, plus a 95% statistical safety stock.
enum InventoryForecastEngine {
    static let z95 = 1.65

    static func key(material: String, subtype: String?, brand: String?, colorName: String?) -> String {
        [material, subtype ?? "", brand ?? "", colorName ?? ""].joined(separator: "||")
    }

    static func forecasts(spools: [InventorySpool], usage: [InventoryUsageRecord], skuSettings: [InventorySkuSettings], globalLeadTime: Int, now: Date = Date()) -> [InventorySkuForecast] {
        var settingsMap: [String: InventorySkuSettings] = [:]
        for s in skuSettings { settingsMap[key(material: s.material, subtype: s.subtype, brand: s.brand, colorName: s.colorName)] = s }
        var usageBySpool: [Int: [InventoryUsageRecord]] = [:]
        for r in usage { usageBySpool[r.spoolId, default: []].append(r) }

        var order: [String] = []
        var groups: [String: [InventorySpool]] = [:]
        for spool in spools where !spool.isArchived {
            let k = key(material: spool.material ?? "", subtype: spool.subtype, brand: spool.brand, colorName: spool.colorName)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(spool)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)

        return order.map { k in
            let members = groups[k]!
            let first = members[0]
            let settings = settingsMap[k] ?? (first.colorName != nil ? settingsMap[key(material: first.material ?? "", subtype: first.subtype, brand: first.brand, colorName: nil)] : nil)
            let leadTime = max(globalLeadTime, settings?.leadTimeDays ?? 0)
            let marginValue = Double(settings?.safetyMarginValue ?? 14)
            let marginUnit = settings?.safetyMarginUnit ?? "days"

            let remaining = members.reduce(0) { $0 + $1.remainingGrams }
            let labelTotal = members.reduce(0) { $0 + $1.label }
            let consumed = members.reduce(0) { $0 + $1.consumedGrams }

            // Pre-reset history has no anchor, so only spools without a baseline contribute.
            var history: [InventoryUsageRecord] = []
            for s in members where (s.weightUsedBaseline ?? 0) == 0 { history += usageBySpool[s.id] ?? [] }

            var rate: Double?
            var stdDev: Double?
            var tier = InventorySkuForecast.RateTier.none
            if let h = historyRate(history, now: now) {
                rate = h.rate; stdDev = h.stdDev; tier = .history
            } else if let d = deltaRate(members, now: now) {
                rate = d; tier = .delta
            }

            let sigma = stdDev ?? (rate.map { $0 * 0.2 } ?? 0)
            let statistical = z95 * sigma * Double(leadTime).squareRoot()
            let margin = marginUnit == "g" ? marginValue : (rate.map { $0 * marginValue } ?? marginValue * 5)
            let safety = statistical + margin
            let rop = rate.map { $0 * Double(leadTime) + safety } ?? 0

            var daysRemaining: Int?
            var daysUntilROP: Int?
            if let rate, rate > 0 {
                daysRemaining = Int((remaining / rate).rounded(.down))
                daysUntilROP = Int(((remaining - rop) / rate).rounded(.down))
            }
            let emptyDate = daysRemaining.flatMap { calendar.date(byAdding: .day, value: $0, to: today) }
            let reorderDate = daysUntilROP.flatMap { calendar.date(byAdding: .day, value: max(0, $0), to: today) }
            let stockBreak = daysRemaining != nil && leadTime > 0 && daysRemaining! <= leadTime
            let reorder = !stockBreak && daysUntilROP != nil && daysUntilROP! <= 0

            return InventorySkuForecast(
                key: k, material: first.material ?? "", subtype: first.subtype, brand: first.brand, colorName: first.colorName,
                spools: members, settings: settings, remaining: remaining, labelTotal: labelTotal, consumed: consumed,
                dailyRate: rate, dailyStdDev: stdDev, rateTier: tier, leadTimeDays: leadTime, safetyStock: safety,
                reorderPoint: rop, daysRemaining: daysRemaining, daysUntilReorder: daysUntilROP, emptyDate: emptyDate,
                reorderDate: reorderDate, reorderAlert: reorder, stockBreakAlert: stockBreak)
        }
    }

    /// Weighted mean/std-dev of daily usage between UTC calendar days that saw prints.
    static func historyRate(_ records: [InventoryUsageRecord], now: Date) -> (rate: Double, stdDev: Double)? {
        guard records.count >= 2 else { return nil }
        var byDay: [String: Double] = [:]
        for r in records {
            let day = String(r.createdAt.prefix(10))
            guard day.count == 10 else { continue }
            byDay[day, default: 0] += r.weightUsed
        }
        guard byDay.count >= 2 else { return nil }
        let days = byDay.compactMap { day, grams -> (Date, Double)? in
            guard let d = APICoders.parseDate(day) else { return nil }
            return (d, grams)
        }.sorted { $0.0 < $1.0 }
        guard days.count >= 2 else { return nil }
        let lambda = log(2.0) / 30
        var observations: [(rate: Double, weight: Double)] = []
        for i in 1..<days.count {
            let gap = max(days[i].0.timeIntervalSince(days[i - 1].0) / 86400, 1)
            let age = now.timeIntervalSince(days[i].0) / 86400
            observations.append((days[i].1 / gap, exp(-lambda * age)))
        }
        let total = observations.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        let mean = observations.reduce(0) { $0 + $1.rate * $1.weight } / total
        let variance = observations.reduce(0) { $0 + $1.weight * pow($1.rate - mean, 2) } / total
        return (mean, variance.squareRoot())
    }

    /// Lifetime average consumption since the oldest spool in the group was added.
    static func deltaRate(_ spools: [InventorySpool], now: Date) -> Double? {
        let used = spools.reduce(0) { $0 + $1.consumedGrams }
        guard used > 0 else { return nil }
        let oldest = spools.compactMap { $0.createdAt.flatMap(APICoders.parseDate) }.min() ?? now
        let days = now.timeIntervalSince(oldest) / 86400
        guard days >= 1 else { return nil }
        return used / days
    }
}

// MARK: - Views

private enum InventoryForecastSort: String, CaseIterable, Identifiable {
    case material = "Material", used = "Consumed", daysLeft = "Days Left", stock = "Stock"
    var id: String { rawValue }
}

struct InventoryForecastView: View {
    @Environment(AppSession.self) private var session
    @Environment(InventoryStore.self) private var store
    @Environment(LiveUpdates.self) private var live

    @State private var skuSettings: [InventorySkuSettings] = []
    @State private var usage: [InventoryUsageRecord] = []
    @State private var shopping: [InventoryShoppingItem] = []
    @State private var loaded = false
    @State private var sort = InventoryForecastSort.daysLeft
    @State private var material = ""
    @State private var brand = ""
    @State private var chartDays = 30
    @State private var showShopping = false
    @State private var cartTarget: InventorySkuForecast?
    @State private var showLeadTime = false
    @State private var leadTimeText = ""
    @State private var runner = ActionRunner()

    private var canRead: Bool { session.can("inventory:forecast_read") }
    private var canWrite: Bool { session.can("inventory:forecast_write") || session.can("inventory:update") }

    private var forecasts: [InventorySkuForecast] {
        InventoryForecastEngine.forecasts(spools: store.spools, usage: usage, skuSettings: skuSettings, globalLeadTime: store.forecastLeadTimeDays)
    }

    var body: some View {
        Group {
            if !canRead {
                ContentUnavailableView("No Access", systemImage: "lock", description: Text("You don't have permission to view the forecast."))
            } else if !loaded {
                ProgressView()
            } else {
                content
            }
        }
        .navigationTitle("Forecast")
        .task(id: live.revision("inventory_changed", "spool_usage_logged")) { await load() }
        .refreshable { await store.load(); await load() }
        .toolbar {
            if canRead {
                ToolbarItem(placement: .primaryAction) {
                    Button { showShopping = true } label: {
                        Label("Shopping List", systemImage: shopping.isEmpty ? "cart" : "cart.fill")
                    }
                    .badge(shopping.count)
                }
            }
        }
        .sheet(isPresented: $showShopping) {
            InventoryShoppingListSheet(items: shopping, forecasts: forecasts, canWrite: canWrite) { await load() }
        }
        .sheet(item: $cartTarget) { f in
            InventoryAddToCartSheet(forecast: f) { await load() }
        }
        .alert("Global Lead Time", isPresented: $showLeadTime) {
            TextField("Days", text: $leadTimeText).keyboardType(.numberPad)
            Button("Save") {
                guard let days = Int(leadTimeText), days >= 0, days <= 365 else { runner.errorMessage = "Enter 0–365 days."; return }
                Task { await runner.run("Lead time saved") { try await store.setForecastLeadTime(days) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Days between ordering filament and it arriving. Applies to every SKU unless a longer per-SKU lead time is set.")
        }
        .actionAlerts(runner)
    }

    private func load() async {
        guard canRead, !store.isDemo else { loaded = true; return }
        let client = store.client
        async let s = try? client.get("inventory/sku-settings", as: [InventorySkuSettings].self)
        async let u = try? client.get("inventory/usage", query: ["limit": 5000], as: [InventoryUsageRecord].self)
        async let l = try? client.get("inventory/shopping-list", as: [InventoryShoppingItem].self)
        skuSettings = await s ?? skuSettings
        usage = await u ?? usage
        shopping = await l ?? shopping
        loaded = true
    }

    private var content: some View {
        let all = forecasts
        let alerts = all.filter(\.hasAlert)
        let materials = Set(all.map(\.material)).filter { !$0.isEmpty }.sorted()
        let brands = Set(all.compactMap(\.brand)).filter { !$0.isEmpty }.sorted()
        let shown = sorted(all.filter { (material.isEmpty || $0.material == material) && (brand.isEmpty || $0.brand == brand) })
        return List {
            if all.isEmpty {
                ContentUnavailableView("Nothing to Forecast", systemImage: "chart.line.downtrend.xyaxis", description: Text("Add active spools to see consumption forecasts."))
            }
            if !alerts.isEmpty {
                Section {
                    ForEach(alerts) { f in
                        HStack(spacing: 10) {
                            Image(systemName: f.stockBreakAlert ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(f.stockBreakAlert ? .red : .yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.label).font(.subheadline.weight(.semibold))
                                Text(f.stockBreakAlert
                                     ? "Runs out in \(f.daysRemaining ?? 0) days — within the \(f.leadTimeDays)-day lead time"
                                     : "At or below reorder point (\(InventoryFormat.grams(f.reorderPoint)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if canWrite {
                                Button { cartTarget = f } label: { Image(systemName: "cart.badge.plus") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Add to shopping list")
                            }
                        }
                    }
                } header: {
                    Text("\(alerts.count) Reorder \(alerts.count == 1 ? "Alert" : "Alerts")")
                }
            }
            if !all.isEmpty {
                Section {
                    projectionChart(all)
                } header: {
                    HStack {
                        Text("Projected Stock")
                        Spacer()
                        Picker("Range", selection: $chartDays) {
                            Text("7d").tag(7); Text("30d").tag(30); Text("180d").tag(180)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                } footer: {
                    Text("Top five SKUs by consumption. Dashed lines mark reorder points.")
                }
                Section {
                    LabeledContent("Global Lead Time") {
                        HStack {
                            Text("\(store.forecastLeadTimeDays) days")
                            if session.can("settings:update") {
                                Button("Edit") { leadTimeText = String(store.forecastLeadTimeDays); showLeadTime = true }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    Picker("Sort By", selection: $sort) {
                        ForEach(InventoryForecastSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if materials.count > 1 {
                        Picker("Material", selection: $material) {
                            Text("All").tag("")
                            ForEach(materials, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if brands.count > 1 {
                        Picker("Brand", selection: $brand) {
                            Text("All").tag("")
                            ForEach(brands, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                Section("SKUs (\(shown.count))") {
                    ForEach(shown) { f in
                        NavigationLink {
                            InventorySkuDetailView(forecast: f, canWrite: canWrite, onChange: { await load() }, onCart: { cartTarget = f })
                        } label: {
                            InventoryForecastRow(forecast: f)
                        }
                        .swipeActions {
                            if canWrite {
                                Button { cartTarget = f } label: { Label("Add to List", systemImage: "cart.badge.plus") }.tint(.green)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sorted(_ list: [InventorySkuForecast]) -> [InventorySkuForecast] {
        switch sort {
        case .material: list.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        case .used: list.sorted { $0.consumed > $1.consumed }
        case .daysLeft: list.sorted { ($0.daysRemaining ?? .max) < ($1.daysRemaining ?? .max) }
        case .stock: list.sorted { $0.remaining < $1.remaining }
        }
    }

    private func projectionChart(_ all: [InventorySkuForecast]) -> some View {
        let top = Array(all.filter { $0.dailyRate != nil }.sorted { $0.consumed > $1.consumed }.prefix(5))
        let points: [(sku: String, day: Int, grams: Double)] = top.flatMap { f in
            stride(from: 0, through: chartDays, by: max(1, chartDays / 30)).map { (f.label, $0, f.projectedStock(day: $0)) }
        }
        return Group {
            if top.isEmpty {
                Text("Not enough usage yet to project consumption.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Day", p.day), y: .value("Grams", p.grams))
                            .foregroundStyle(by: .value("SKU", p.sku))
                    }
                    ForEach(top.filter { $0.reorderPoint > 0 }) { f in
                        RuleMark(y: .value("Reorder point", f.reorderPoint))
                            .foregroundStyle(by: .value("SKU", f.label))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartXAxisLabel("Days from today")
                .chartYAxisLabel("g")
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 220)
                .padding(.vertical, 6)
            }
        }
    }
}

private struct InventoryForecastRow: View {
    let forecast: InventorySkuForecast

    var body: some View {
        let f = forecast
        HStack(spacing: 12) {
            InventorySpoolSwatch(rgba: f.rgba, extraColors: f.spools.first?.extraColors, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(f.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if f.isSnoozed { Image(systemName: "bell.slash").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 6) {
                    InventoryRemainingBar(percent: f.remainingPercent).frame(width: 70)
                    Text("\(InventoryFormat.grams(f.remaining)) · \(f.spools.count) \(f.spools.count == 1 ? "spool" : "spools")")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(rateText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(f.daysRemaining.map { "\($0)d" } ?? "—").font(.headline.monospacedDigit()).foregroundStyle(daysColor)
                if let d = f.emptyDate { Text(d.formatted(.dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private var rateText: String {
        guard let r = forecast.dailyRate else { return "No usage yet" }
        let tier = forecast.rateTier == .history ? "trend" : "average"
        return "\(Fmt.number(r)) g/day (\(tier))"
    }

    private var daysColor: Color {
        let f = forecast
        if f.isSnoozed || f.daysRemaining == nil { return .secondary }
        if f.stockBreakAlert { return .red }
        if f.reorderAlert || (f.daysRemaining ?? 0) < 30 { return .orange }
        return .green
    }
}

/// Details and reorder settings for one SKU.
private struct InventorySkuDetailView: View {
    @Environment(InventoryStore.self) private var store
    let forecast: InventorySkuForecast
    let canWrite: Bool
    let onChange: () async -> Void
    let onCart: () -> Void

    @State private var leadTime = 0
    @State private var marginValue = 14
    @State private var marginUnit = "days"
    @State private var snoozed = false
    @State private var runner = ActionRunner()

    var body: some View {
        let f = forecast
        List {
            Section {
                Chart {
                    ForEach(Array(stride(from: 0, through: min(f.daysRemaining ?? 60, 180) + 1, by: 1)), id: \.self) { day in
                        AreaMark(x: .value("Day", day), y: .value("Grams", f.projectedStock(day: day)))
                            .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.4), .accentColor.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Day", day), y: .value("Grams", f.projectedStock(day: day)))
                    }
                    if f.reorderPoint > 0 {
                        RuleMark(y: .value("Reorder point", f.reorderPoint))
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) { Text("Reorder point").font(.caption2).foregroundStyle(.orange) }
                    }
                }
                .chartXAxisLabel("Days from today")
                .frame(height: 200)
                .padding(.vertical, 6)
            }
            Section("Stock") {
                InfoRow("Remaining", "\(InventoryFormat.grams(f.remaining)) of \(InventoryFormat.grams(f.labelTotal))")
                InfoRow("Spools", "\(f.spools.count)")
                InfoRow("Consumed", InventoryFormat.grams(f.consumed))
                InfoRow("Daily Usage", f.dailyRate.map { "\(Fmt.number($0)) g/day" + (f.dailyStdDev.map { " ± \(Fmt.number($0))" } ?? "") })
                InfoRow("Rate Source", f.rateTier == .history ? "Print history (recent weighted)" : f.rateTier == .delta ? "Lifetime average" : "Not enough data")
                InfoRow("Days Remaining", f.daysRemaining.map { "\($0) days" })
                InfoRow("Projected Empty", f.emptyDate.map { $0.formatted(date: .abbreviated, time: .omitted) })
            }
            Section("Reorder") {
                InfoRow("Lead Time", "\(f.leadTimeDays) days")
                InfoRow("Safety Stock", InventoryFormat.grams(f.safetyStock))
                InfoRow("Reorder Point", InventoryFormat.grams(f.reorderPoint))
                InfoRow("Reorder By", f.reorderDate.map { $0.formatted(date: .abbreviated, time: .omitted) })
                if f.hasAlert {
                    Label(f.stockBreakAlert ? "Stock runs out before a new order would arrive." : "Stock is at or below the reorder point.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(f.stockBreakAlert ? .red : .orange)
                }
                if canWrite {
                    Button { onCart() } label: { Label("Add to Shopping List…", systemImage: "cart.badge.plus") }
                }
            }
            if canWrite {
                Section {
                    Stepper("SKU Lead Time: \(leadTime) days", value: $leadTime, in: 0...365)
                    Stepper("Safety Margin: \(marginValue) \(marginUnit == "g" ? "g" : "days")", value: $marginValue, in: 0...(marginUnit == "g" ? 10000 : 365), step: marginUnit == "g" ? 50 : 1)
                    Picker("Margin Unit", selection: $marginUnit) {
                        Text("Days of usage").tag("days")
                        Text("Grams").tag("g")
                    }
                    Toggle("Snooze Alerts", isOn: $snoozed)
                    Button("Save Settings") { save() }.disabled(runner.isRunning)
                } header: {
                    Text("Settings")
                } footer: {
                    Text("The effective lead time is the longer of the global and SKU lead times. The safety margin is added on top of the statistical safety stock.")
                }
            }
            Section("Spools") {
                ForEach(f.spools) { spool in
                    NavigationLink(value: InventoryRoute.spool(spool.id)) {
                        InventorySpoolRow(spool: spool, slot: store.slot(for: spool.id), storage: store.storageLabel(for: spool), lowStockThreshold: store.lowStockThreshold)
                    }
                }
            }
        }
        .navigationTitle(f.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            leadTime = f.settings?.leadTimeDays ?? 0
            marginValue = f.settings?.safetyMarginValue ?? 14
            marginUnit = f.settings?.safetyMarginUnit ?? "days"
            snoozed = f.settings?.alertsSnoozed ?? false
        }
        .actionAlerts(runner)
    }

    private func save() {
        let body: JSONValue = [
            "material": .string(forecast.material),
            "subtype": forecast.subtype.map { .string($0) } ?? .null,
            "brand": forecast.brand.map { .string($0) } ?? .null,
            "color_name": forecast.colorName.map { .string($0) } ?? .null,
            "lead_time_days": .number(Double(leadTime)),
            "safety_margin_value": .number(Double(marginValue)),
            "safety_margin_unit": .string(marginUnit),
            "alerts_snoozed": .bool(snoozed),
        ]
        Task {
            await runner.run("Settings saved") { try await store.client.call(.post, "inventory/sku-settings", body: body) }
            await onChange()
        }
    }
}

/// Add a SKU to the shopping list by quantity or by days of coverage.
private struct InventoryAddToCartSheet: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let forecast: InventorySkuForecast
    let onAdded: () async -> Void

    @State private var byDuration = false
    @State private var quantity = 1
    @State private var days = 30
    @State private var note = ""
    @State private var runner = ActionRunner()

    private var durationQuantity: Int? {
        guard let rate = forecast.dailyRate, rate > 0 else { return nil }
        return max(1, Int((rate * Double(days) / forecast.averageSpoolWeight).rounded(.up)))
    }

    private var finalQuantity: Int { byDuration ? (durationQuantity ?? 1) : quantity }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(forecast.label).font(.headline) }
                Section {
                    Picker("Order By", selection: $byDuration) {
                        Text("Quantity").tag(false)
                        Text("Coverage").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if byDuration {
                        Stepper("Cover \(days) days", value: $days, in: 1...365, step: days < 30 ? 1 : 15)
                        if let q = durationQuantity {
                            LabeledContent("Spools Needed", value: "\(q)")
                        } else {
                            Text("No usage rate yet — one spool will be added.").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Stepper("\(quantity) \(quantity == 1 ? "spool" : "spools")", value: $quantity, in: 1...99)
                    }
                    TextField("Note", text: $note)
                }
            }
            .navigationTitle("Add to Shopping List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(runner.isRunning)
                }
            }
            .actionAlerts(runner)
        }
        .presentationDetents([.medium])
    }

    private func add() {
        let trimmed = note.trimmingCharacters(in: .whitespaces)
        let body: JSONValue = [
            "material": .string(forecast.material),
            "subtype": forecast.subtype.map { .string($0) } ?? .null,
            "brand": forecast.brand.map { .string($0) } ?? .null,
            "color_name": forecast.colorName.map { .string($0) } ?? .null,
            "quantity_spools": .number(Double(finalQuantity)),
            "note": trimmed.isEmpty ? .null : .string(trimmed),
        ]
        Task {
            await runner.run { try await store.client.call(.post, "inventory/shopping-list", body: body) }
            if runner.errorMessage == nil {
                await onAdded()
                dismiss()
            }
        }
    }
}

/// Shopping list with purchase tracking; receiving items adds spools to stock.
private struct InventoryShoppingListSheet: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var items: [InventoryShoppingItem]
    let forecasts: [InventorySkuForecast]
    let canWrite: Bool
    let onChange: () async -> Void

    @State private var confirmClear = false
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    ContentUnavailableView("Shopping List Empty", systemImage: "cart", description: Text("Add SKUs from the forecast when they need reordering."))
                }
                ForEach(["pending", "purchased"], id: \.self) { status in
                    let group = items.filter { ($0.status ?? "pending") == status }
                    if !group.isEmpty {
                        Section(status == "pending" ? "To Buy" : "Ordered") {
                            ForEach(group) { item in row(item) }
                        }
                    }
                }
            }
            .navigationTitle("Shopping List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if canWrite && !items.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .confirm("Clear the shopping list?", isPresented: $confirmClear, message: "All items are removed.", action: "Clear") {
                Task {
                    await runner.run { try await store.client.call(.delete, "inventory/shopping-list") }
                    await refresh()
                }
            }
            .overlay { if runner.isRunning { ProgressView() } }
            .actionAlerts(runner)
        }
    }

    private func row(_ item: InventoryShoppingItem) -> some View {
        let forecast = forecasts.first { $0.key == InventoryForecastEngine.key(material: item.material, subtype: item.subtype, brand: item.brand, colorName: item.colorName) }
        return HStack(spacing: 12) {
            InventorySpoolSwatch(rgba: forecast?.rgba, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.subheadline.weight(.semibold))
                Text(InventoryFormat.joined(["\(item.quantitySpools ?? 1) × spool", forecast?.daysRemaining.map { "\($0) days left" }, item.note]))
                    .font(.caption).foregroundStyle(.secondary)
                if let purchased = item.purchasedAt { Text("Ordered \(Fmt.relative(purchased))").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            if canWrite {
                Menu {
                    if (item.status ?? "pending") == "pending" {
                        Button { setStatus(item, "purchased", forecast: forecast) } label: { Label("Mark Ordered", systemImage: "shippingbox") }
                    } else {
                        Button { setStatus(item, "pending", forecast: forecast) } label: { Label("Mark Not Ordered", systemImage: "arrow.uturn.backward") }
                    }
                    Button { setStatus(item, "received", forecast: forecast) } label: { Label("Received — Add to Stock", systemImage: "checkmark.circle") }
                    Button(role: .destructive) { remove(item) } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
        }
        .swipeActions {
            if canWrite {
                Button(role: .destructive) { remove(item) } label: { Label("Remove", systemImage: "trash") }
                Button { setStatus(item, "received", forecast: forecast) } label: { Label("Received", systemImage: "checkmark") }.tint(.green)
            }
        }
    }

    private func setStatus(_ item: InventoryShoppingItem, _ status: String, forecast: InventorySkuForecast?) {
        Task {
            await runner.run(status == "received" ? "Added \(item.quantitySpools ?? 1) spools to stock" : nil) {
                try await store.client.call(.patch, "inventory/shopping-list/\(item.id)/status", body: ["status": JSONValue.string(status)] as JSONValue)
                if status == "received" {
                    let spool: [String: JSONValue] = [
                        "material": .string(item.material),
                        "subtype": item.subtype.map { .string($0) } ?? .null,
                        "brand": item.brand.map { .string($0) } ?? .null,
                        "color_name": item.colorName.map { .string($0) } ?? .null,
                        "rgba": forecast?.rgba.map { .string($0) } ?? .null,
                        "label_weight": .number((forecast?.averageSpoolWeight ?? 1000).rounded()),
                        "core_weight": 0,
                        "weight_used": 0,
                        "data_origin": "manual",
                        "note": item.note.map { .string($0) } ?? .null,
                        "category": "Stock",
                    ]
                    try await store.create(spool, quantity: max(1, item.quantitySpools ?? 1))
                    try await store.client.call(.delete, "inventory/shopping-list/\(item.id)")
                }
            }
            await refresh()
        }
    }

    private func remove(_ item: InventoryShoppingItem) {
        Task {
            await runner.run { try await store.client.call(.delete, "inventory/shopping-list/\(item.id)") }
            await refresh()
        }
    }

    private func refresh() async {
        if let list = try? await store.client.get("inventory/shopping-list", as: [InventoryShoppingItem].self) { items = list }
        await onChange()
    }
}
