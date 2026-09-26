import Foundation

// MARK: - API models

/// `GET archives/stats` — aggregate totals over print runs.
struct StatsSummary: Decodable, Sendable, Hashable {
    var totalPrints: Int?
    var successfulPrints: Int?
    var failedPrints: Int?
    var cancelledPrints: Int?
    var totalPrintTimeHours: Double?
    var totalFilamentGrams: Double?
    var totalCost: Double?
    var printsByFilamentType: [String: Double]?
    var printsByPrinter: [String: Double]?
    var printerNames: [String: String]?
    var averageTimeAccuracy: Double?
    var timeAccuracyByPrinter: [String: Double]?
    var totalEnergyKwh: Double?
    var totalEnergyCost: Double?
    var energyDataWarmingUp: Bool?
}

/// `GET archives/slim` — one row per print run (reprints count separately).
struct StatsPrintRun: Decodable, Sendable, Hashable {
    var printerId: Int?
    var printName: String?
    var printTimeSeconds: Int?
    var actualTimeSeconds: Int?
    var filamentUsedGrams: Double?
    var filamentType: String?
    var filamentColor: String?
    var status: String?
    var startedAt: String?
    var completedAt: String?
    var cost: Double?
    var energyKwh: Double?
    var energyCost: Double?
    var quantity: Int?
    var createdAt: String?

    /// Measured duration, falling back to the slicer estimate.
    var effectiveSeconds: Double {
        if let a = actualTimeSeconds, a > 0 { return Double(a) }
        return Double(printTimeSeconds ?? 0)
    }
    /// Timestamp the run is bucketed under in trend charts.
    var trendDate: Date? { APICoders.parseDate(completedAt ?? createdAt ?? "") }
    var createdDate: Date? { APICoders.parseDate(createdAt ?? "") }
    var startedDate: Date? { APICoders.parseDate(startedAt ?? "") }
    var isCompleted: Bool { status == "completed" }
    var isFailed: Bool { status == "failed" || status == "aborted" }
    var isCancelled: Bool { ["stopped", "cancelled", "skipped"].contains(status ?? "") }

    /// Comma-separated material list (multi-material prints), "Unknown" when empty.
    var materials: [String] {
        let parts = (filamentType ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? ["Unknown"] : parts
    }
    var colors: [String] {
        (filamentColor ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// `GET archives/analysis/failures`.
struct StatsFailureAnalysis: Decodable, Sendable, Hashable {
    var periodDays: Int?
    var totalPrints: Int?
    var failedPrints: Int?
    var failureRate: Double?
    var failuresByReason: [String: Double]?
    var failuresByFilament: [String: Double]?
    var failuresByPrinter: [String: Double]?
    var failuresByHour: [String: Double]?
    var recentFailures: [StatsRecentFailure]?
    var trend: [StatsFailureTrendPoint]?
}

struct StatsRecentFailure: Decodable, Sendable, Hashable {
    var id: Int?
    var printName: String?
    var failureReason: String?
    var filamentType: String?
    var printerId: Int?
    var createdAt: String?
}

struct StatsFailureTrendPoint: Decodable, Sendable, Hashable {
    var weekStart: String?
    var totalPrints: Int?
    var failedPrints: Int?
    var failureRate: Double?
}

/// `GET users/slim` — minimal user listing for the user filter.
struct StatsUserOption: Decodable, Sendable, Hashable, Identifiable {
    var id: Int
    var username: String?
}

/// `POST archives/recalculate-costs`.
struct StatsRecalculateResult: Decodable, Sendable {
    var message: String?
    var updated: Int?
}

// MARK: - Timeframe

enum StatsTimeframe: String, CaseIterable, Identifiable, Sendable {
    case today, thisWeek = "this-week", thisMonth = "this-month"
    case last7 = "last-7", last30 = "last-30", last90 = "last-90"
    case thisYear = "this-year", allTime = "all-time", custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .thisWeek: "This Week"
        case .thisMonth: "This Month"
        case .last7: "Last 7 Days"
        case .last30: "Last 30 Days"
        case .last90: "Last 90 Days"
        case .thisYear: "This Year"
        case .allTime: "All Time"
        case .custom: "Custom Range"
        }
    }

    /// Inclusive day range; `nil` bounds mean unbounded.
    func range(now: Date = Date(), calendar: Calendar = .current, customFrom: Date? = nil, customTo: Date? = nil) -> (from: Date?, to: Date?) {
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today) ?? today }
        switch self {
        case .today: return (today, today)
        case .thisWeek:
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            let start = iso.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            return (start, today)
        case .thisMonth: return (calendar.dateInterval(of: .month, for: today)?.start ?? today, today)
        case .last7: return (daysAgo(6), today)
        case .last30: return (daysAgo(29), today)
        case .last90: return (daysAgo(89), today)
        case .thisYear: return (calendar.dateInterval(of: .year, for: today)?.start ?? today, today)
        case .allTime: return (nil, nil)
        case .custom: return (customFrom.map { calendar.startOfDay(for: $0) }, customTo.map { calendar.startOfDay(for: $0) })
        }
    }

    static func apiDay(_ date: Date?, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

// MARK: - Aggregations (pure; unit-tested)

enum StatsMetricKind: String, CaseIterable, Identifiable, Sendable {
    case weight, prints, time
    var id: String { rawValue }
    var title: String {
        switch self { case .weight: "Weight"; case .prints: "Prints"; case .time: "Time" }
    }
    func format(_ value: Double) -> String {
        switch self {
        case .weight: Fmt.grams(value)
        case .prints: Fmt.number(value, digits: 1)
        case .time: "\(Fmt.number(value, digits: 1)) h"
        }
    }
}

struct StatsNamedValue: Identifiable, Hashable, Sendable {
    var name: String
    var value: Double
    var id: String { name }
}

struct StatsTimePoint: Identifiable, Hashable, Sendable {
    var date: Date
    var filament: Double
    var cost: Double
    var energy: Double
    var prints: Int
    var id: Date { date }
}

struct StatsRecord: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case longest, heaviest, costliest, busiestDay, streak }
    var kind: Kind
    var value: String
    var detail: String?
    var id: String { kind.rawValue }
}

struct StatsOutcomeCounts: Hashable, Sendable {
    var total = 0, successful = 0, failed = 0, cancelled = 0
    /// Success rate over completed + failed (cancelled runs are neutral).
    var successRate: Double? {
        let outcome = successful + failed
        return outcome > 0 ? Double(successful) / Double(outcome) * 100 : nil
    }
}

enum StatsAggregator {
    static let durationBuckets: [(label: String, max: Double)] = [
        ("<30m", 1800), ("30m–1h", 3600), ("1–2h", 7200), ("2–4h", 14400),
        ("4–8h", 28800), ("8–12h", 43200), ("12–24h", 86400), ("24h+", .infinity),
    ]

    static func outcomes(_ runs: [StatsPrintRun]) -> StatsOutcomeCounts {
        var c = StatsOutcomeCounts()
        for r in runs {
            c.total += 1
            if r.isCompleted { c.successful += 1 } else if r.isFailed { c.failed += 1 } else if r.isCancelled { c.cancelled += 1 }
        }
        return c
    }

    /// Totals computed from runs (used when a printer filter is active, since
    /// the summary endpoint cannot filter by printer).
    static func summary(from runs: [StatsPrintRun], printerId: Int?) -> StatsSummary {
        let o = outcomes(runs)
        var byType: [String: Double] = [:]
        for r in runs where r.filamentType?.isEmpty == false {
            for m in r.materials { byType[m, default: 0] += 1 }
        }
        let seconds = runs.reduce(0.0) { $0 + Double(max(0, $1.actualTimeSeconds ?? 0)) }
        return StatsSummary(
            totalPrints: o.total, successfulPrints: o.successful, failedPrints: o.failed, cancelledPrints: o.cancelled,
            totalPrintTimeHours: seconds / 3600,
            totalFilamentGrams: runs.reduce(0) { $0 + ($1.filamentUsedGrams ?? 0) },
            totalCost: runs.reduce(0) { $0 + ($1.cost ?? 0) },
            printsByFilamentType: byType,
            printsByPrinter: printerId.map { [String($0): Double(o.total)] },
            printerNames: nil, averageTimeAccuracy: nil, timeAccuracyByPrinter: nil,
            totalEnergyKwh: runs.reduce(0) { $0 + ($1.energyKwh ?? 0) },
            totalEnergyCost: runs.reduce(0) { $0 + ($1.energyCost ?? 0) },
            energyDataWarmingUp: false
        )
    }

    static func byPrinter(_ runs: [StatsPrintRun], counts: [String: Double]?, metric: StatsMetricKind, name: (String) -> String) -> [StatsNamedValue] {
        var prints: [String: Double] = counts ?? [:]
        var weight: [String: Double] = [:], hours: [String: Double] = [:]
        for r in runs {
            guard let pid = r.printerId else { continue }
            let key = String(pid)
            weight[key, default: 0] += r.filamentUsedGrams ?? 0
            hours[key, default: 0] += r.effectiveSeconds / 3600
            if counts == nil { prints[key, default: 0] += 1 }
            else if prints[key] == nil { prints[key] = 0 }
        }
        let source: [String: Double] = switch metric { case .prints: prints; case .weight: weight; case .time: hours }
        let keys = Set(prints.keys).union(weight.keys)
        return keys.map { StatsNamedValue(name: name($0), value: source[$0] ?? 0) }
            .sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }
    }

    static func durationHistogram(_ runs: [StatsPrintRun]) -> [StatsNamedValue] {
        var counts = Array(repeating: 0.0, count: durationBuckets.count)
        for r in runs {
            let s = r.effectiveSeconds
            guard s > 0, let i = durationBuckets.firstIndex(where: { s <= $0.max }) else { continue }
            counts[i] += 1
        }
        return durationBuckets.enumerated().map { StatsNamedValue(name: $1.label, value: counts[$0]) }
    }

    /// Average per weekday (Monday first) across the distinct weeks that had prints.
    static func weekdayHabits(_ runs: [StatsPrintRun], metric: StatsMetricKind, calendar: Calendar = .current) -> [StatsNamedValue] {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        var totals = Array(repeating: 0.0, count: 7)
        var weeks = Set<Date>()
        for r in runs {
            guard let d = r.createdDate else { continue }
            let wd = calendar.component(.weekday, from: d) // 1 = Sunday
            let idx = (wd + 5) % 7 // Monday = 0
            switch metric {
            case .prints: totals[idx] += 1
            case .weight: totals[idx] += r.filamentUsedGrams ?? 0
            case .time: totals[idx] += r.effectiveSeconds / 3600
            }
            if let ws = iso.dateInterval(of: .weekOfYear, for: d)?.start { weeks.insert(ws) }
        }
        let n = Double(max(weeks.count, 1))
        let symbols = calendar.shortWeekdaySymbols // Sunday first
        return (0..<7).map { i in StatsNamedValue(name: symbols[(i + 1) % 7], value: totals[i] / n) }
    }

    /// Prints started per hour of day, with failed runs split out.
    static func hourOfDay(_ runs: [StatsPrintRun], calendar: Calendar = .current) -> [(hour: Int, total: Int, failed: Int)] {
        var total = Array(repeating: 0, count: 24), failed = Array(repeating: 0, count: 24)
        for r in runs {
            guard let d = r.startedDate else { continue }
            let h = calendar.component(.hour, from: d)
            total[h] += 1
            if r.isFailed { failed[h] += 1 }
        }
        return (0..<24).map { ($0, total[$0], failed[$0]) }
    }

    enum Granularity: Sendable { case hour, day, week }

    static func granularity(spanDays: Double?, runs: [StatsPrintRun], calendar: Calendar = .current) -> Granularity {
        let span: Double
        if let spanDays { span = spanDays } else {
            let dates = runs.compactMap(\.trendDate)
            guard let lo = dates.min(), let hi = dates.max() else { return .day }
            span = hi.timeIntervalSince(lo) / 86400
        }
        if span <= 7 { return .hour }
        let days = Set(runs.compactMap { $0.trendDate.map { calendar.startOfDay(for: $0) } })
        return days.count > 60 ? .week : .day
    }

    static func timeSeries(_ runs: [StatsPrintRun], granularity: Granularity, calendar: Calendar = .current) -> [StatsTimePoint] {
        var map: [Date: StatsTimePoint] = [:]
        for r in runs {
            guard let d = r.trendDate else { continue }
            let key: Date
            switch granularity {
            case .hour: key = calendar.dateInterval(of: .hour, for: d)?.start ?? d
            case .day: key = calendar.startOfDay(for: d)
            case .week: key = calendar.dateInterval(of: .weekOfYear, for: d)?.start ?? d
            }
            var p = map[key] ?? StatsTimePoint(date: key, filament: 0, cost: 0, energy: 0, prints: 0)
            p.filament += r.filamentUsedGrams ?? 0
            p.cost += r.cost ?? 0
            p.energy += r.energyKwh ?? 0
            p.prints += r.quantity ?? 1
            map[key] = p
        }
        return map.values.sorted { $0.date < $1.date }
    }

    static func byMaterial(_ runs: [StatsPrintRun], metric: StatsMetricKind) -> [StatsNamedValue] {
        var map: [String: Double] = [:]
        for r in runs {
            let mats = r.materials
            let share = 1.0 / Double(mats.count)
            for m in mats {
                switch metric {
                case .weight: map[m, default: 0] += (r.filamentUsedGrams ?? 0) * share
                case .prints: map[m, default: 0] += 1
                case .time: map[m, default: 0] += r.effectiveSeconds * share / 3600
                }
            }
        }
        return map.map { StatsNamedValue(name: $0.key, value: $0.value) }
            .filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }
    }

    /// Success rate per material for materials with at least two decided runs.
    static func materialSuccess(_ runs: [StatsPrintRun]) -> [(name: String, rate: Double, total: Int)] {
        var map: [String: (ok: Int, bad: Int)] = [:]
        for r in runs where r.isCompleted || r.status == "failed" {
            for m in r.materials {
                var e = map[m] ?? (0, 0)
                if r.isCompleted { e.ok += 1 } else { e.bad += 1 }
                map[m] = e
            }
        }
        return map.compactMap { name, v in
            let total = v.ok + v.bad
            guard total >= 2 else { return nil }
            return (name, Double(v.ok) / Double(total) * 100, total)
        }.sorted { $0.rate == $1.rate ? $0.name < $1.name : $0.rate > $1.rate }
    }

    /// Color usage keyed by hex string.
    static func colors(_ runs: [StatsPrintRun], metric: StatsMetricKind) -> [StatsNamedValue] {
        var map: [String: Double] = [:]
        for r in runs {
            let cs = r.colors
            guard !cs.isEmpty else { continue }
            for hex in cs {
                map[hex, default: 0] += metric == .prints ? 1 : (r.filamentUsedGrams ?? 0) / Double(cs.count)
            }
        }
        return map.map { StatsNamedValue(name: $0.key, value: $0.value) }
            .filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }
    }

    static func records(_ runs: [StatsPrintRun], currencyCode: String, calendar: Calendar = .current) -> [StatsRecord] {
        var out: [StatsRecord] = []
        func best(_ value: (StatsPrintRun) -> Double?) -> (StatsPrintRun, Double)? {
            var result: (StatsPrintRun, Double)?
            for r in runs { if let v = value(r), v > 0, v > (result?.1 ?? 0) { result = (r, v) } }
            return result
        }
        if let (r, v) = best({ $0.isCompleted ? $0.actualTimeSeconds.map(Double.init) : nil }) {
            out.append(StatsRecord(kind: .longest, value: Fmt.duration(seconds: v), detail: r.printName))
        }
        if let (r, v) = best({ $0.filamentUsedGrams }) {
            out.append(StatsRecord(kind: .heaviest, value: Fmt.grams(v), detail: r.printName))
        }
        if let (r, v) = best({ ($0.cost ?? 0) + ($0.energyCost ?? 0) }) {
            out.append(StatsRecord(kind: .costliest, value: Fmt.currency(v, code: currencyCode), detail: r.printName))
        }
        var perDay: [Date: Int] = [:]
        for r in runs { if let d = r.createdDate { perDay[calendar.startOfDay(for: d), default: 0] += 1 } }
        if let top = perDay.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }), top.value > 1 {
            out.append(StatsRecord(kind: .busiestDay, value: "\(top.value) prints", detail: top.key.formatted(date: .abbreviated, time: .omitted)))
        }
        let decided = runs.filter { $0.isCompleted || $0.status == "failed" }
            .sorted { ($0.trendDate ?? .distantPast) > ($1.trendDate ?? .distantPast) }
        let streak = decided.prefix { $0.isCompleted }.count
        if streak > 0 {
            out.append(StatsRecord(kind: .streak, value: "\(streak)", detail: streak == 1 ? "successful print in a row" : "successful prints in a row"))
        }
        return out
    }

    /// Converts a stored failure-reason key (`camelCase`, `snake_case` or free
    /// text) into a readable label: "spaghettiDetached" → "Spaghetti detached".
    static func reasonLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Unknown" }
        if trimmed.contains(" ") { return trimmed }
        var words = ""
        var previous: Character?
        for ch in trimmed {
            if ch == "_" || ch == "-" { words.append(" ") }
            else if ch.isUppercase, let p = previous, p.isLowercase { words.append(" "); words.append(Character(ch.lowercased())) }
            else { words.append(ch) }
            previous = ch
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
