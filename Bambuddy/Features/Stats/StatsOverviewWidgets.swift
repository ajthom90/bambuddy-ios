import SwiftUI
import Charts

// MARK: - Quick stats

struct StatsQuickStatsView: View {
    let summary: StatsSummary
    let currencyCode: String
    var printerFiltered = false

    var body: some View {
        let warming = summary.energyDataWarmingUp == true
        let note = warming ? "Energy history is still being collected for this range, so the total may be low." : nil
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .topLeading)], alignment: .leading, spacing: 14) {
                StatsValueTile(label: "Total Prints", value: "\(summary.totalPrints ?? 0)", systemImage: "shippingbox.fill", tint: .green)
                StatsValueTile(label: "Print Time", value: "\(Fmt.number(summary.totalPrintTimeHours ?? 0, digits: 1)) h", systemImage: "clock.fill", tint: .blue)
                StatsValueTile(label: "Filament Used", value: Fmt.grams(summary.totalFilamentGrams ?? 0), systemImage: "scalemass.fill", tint: .orange)
                StatsValueTile(label: "Filament Cost", value: Fmt.currency(summary.totalCost ?? 0, code: currencyCode), systemImage: "dollarsign.circle.fill", tint: .green)
                StatsValueTile(label: "Energy Used", value: "\(Fmt.number(summary.totalEnergyKwh ?? 0, digits: 3)) kWh", systemImage: "bolt.fill", tint: .yellow, warning: note)
                StatsValueTile(label: "Energy Cost", value: Fmt.currency(summary.totalEnergyCost ?? 0, code: currencyCode), systemImage: "bolt.circle.fill", tint: .yellow, warning: note)
            }
            if let note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }
            if printerFiltered {
                Text("Totals for the selected printer are computed from individual print runs; energy includes per-print measurements only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Success rate

struct StatsSuccessRateView: View {
    let summary: StatsSummary
    let printerName: (String) -> String

    var body: some View {
        let ok = summary.successfulPrints ?? 0, bad = summary.failedPrints ?? 0
        let outcome = ok + bad
        let rate = outcome > 0 ? Double(ok) / Double(outcome) * 100 : 0
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                StatsRing(fraction: rate / 100, color: .green) {
                    Text("\(Int(rate.rounded()))%").font(.title2.weight(.bold)).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 8) {
                    row("Successful", ok, "checkmark.circle.fill", .green)
                    row("Failed", bad, "xmark.circle.fill", .red)
                    row("Cancelled", summary.cancelledPrints ?? 0, "slash.circle.fill", .orange)
                }
            }
            Text("Cancelled prints are not counted against the success rate.")
                .font(.caption2).foregroundStyle(.secondary)
            let byPrinter = (summary.printsByPrinter ?? [:]).sorted { $0.value > $1.value }
            if byPrinter.count > 1 {
                Divider()
                Text("Prints by Printer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(byPrinter, id: \.key) { key, count in
                        HStack(spacing: 6) {
                            Text(printerName(key)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Int(count))").font(.caption.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: Int, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("\(value)").fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline)
    }
}

// MARK: - Time accuracy

struct StatsTimeAccuracyView: View {
    let summary: StatsSummary
    let printerName: (String) -> String
    var selectedPrinter: Int?

    static func color(_ accuracy: Double) -> Color {
        if (95...105).contains(accuracy) { return .green }
        return accuracy > 105 ? .blue : .orange
    }

    var body: some View {
        let accuracy = selectedPrinter.flatMap { summary.timeAccuracyByPrinter?[String($0)] } ?? (selectedPrinter == nil ? summary.averageTimeAccuracy : nil)
        if let accuracy {
            let deviation = accuracy - 100
            let perPrinter = selectedPrinter == nil ? (summary.timeAccuracyByPrinter ?? [:]).sorted { $0.key < $1.key } : []
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) {
                    StatsRing(fraction: (min(150, max(50, accuracy)) - 50) / 100, color: Self.color(accuracy)) {
                        VStack(spacing: 0) {
                            Text("\(Int(accuracy.rounded()))%").font(.title2.weight(.bold)).monospacedDigit()
                            Text("\(deviation >= 0 ? "+" : "")\(Int(deviation.rounded()))%")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(deviation >= 0 ? .blue : .orange)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Label("100% means the slicer estimate matched the actual print time.", systemImage: "target")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Above 100%: prints finished faster than estimated.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !perPrinter.isEmpty {
                    Divider()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 4) {
                        ForEach(perPrinter, id: \.key) { key, value in
                            HStack(spacing: 6) {
                                Text(key == "unknown" ? "Unknown" : printerName(key)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(Int(value.rounded()))%").font(.caption.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(Self.color(value))
                            }
                        }
                    }
                }
            }
        } else {
            StatsEmptyNote(text: "No completed prints with a slicer estimate in this period.")
        }
    }
}

// MARK: - Failure analysis

struct StatsFailureSummaryView: View {
    let analysis: StatsFailureAnalysis?
    let hasDateRange: Bool
    let printerName: (Int) -> String

    var body: some View {
        if let a = analysis, (a.totalPrints ?? 0) > 0 {
            let rate = a.failureRate ?? 0
            let reasons = (a.failuresByReason ?? [:]).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(rate > 20 ? .red : rate > 10 ? .orange : .green)
                    Text("\(Fmt.number(rate, digits: 1))%").font(.largeTitle.weight(.bold)).monospacedDigit()
                }
                Text("\(a.failedPrints ?? 0) of \(a.totalPrints ?? 0) prints failed")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let trend = a.trend, trend.count >= 2 {
                    let last = trend[trend.count - 1].failureRate ?? 0
                    let prev = trend[trend.count - 2].failureRate ?? 0
                    Label("Last week: \(Fmt.number(last, digits: 1))%", systemImage: last <= prev ? "arrow.down.right" : "arrow.up.right")
                        .font(.subheadline)
                        .foregroundStyle(last <= prev ? .green : .red)
                }
                if !reasons.isEmpty {
                    Divider()
                    Text("Top Failure Reasons").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(reasons.prefix(5), id: \.key) { key, count in
                        HStack {
                            Text(StatsAggregator.reasonLabel(key)).font(.subheadline).lineLimit(1)
                            Spacer()
                            Text("\(Int(count))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                NavigationLink {
                    StatsFailureDetailView(analysis: a, printerName: printerName)
                } label: {
                    Label("Failure Details", systemImage: "chevron.right.circle")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderless)
            }
        } else {
            StatsEmptyNote(text: hasDateRange ? "No prints in this period." : "No prints in the last 30 days.")
        }
    }
}

/// Full breakdown of the failure analysis response.
struct StatsFailureDetailView: View {
    let analysis: StatsFailureAnalysis
    let printerName: (Int) -> String

    private func sorted(_ d: [String: Double]?) -> [(key: String, value: Double)] {
        (d ?? [:]).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Period", value: "\(analysis.periodDays ?? 0) days")
                LabeledContent("Total Prints", value: "\(analysis.totalPrints ?? 0)")
                LabeledContent("Failed Prints", value: "\(analysis.failedPrints ?? 0)")
                LabeledContent("Failure Rate", value: "\(Fmt.number(analysis.failureRate ?? 0, digits: 1))%")
            }
            if let trend = analysis.trend, !trend.isEmpty {
                Section("Weekly Trend") {
                    Chart(Array(trend.enumerated()), id: \.offset) { _, p in
                        let date = APICoders.parseDate(p.weekStart ?? "") ?? .now
                        LineMark(x: .value("Week", date, unit: .weekOfYear), y: .value("Failure Rate", p.failureRate ?? 0))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.red)
                        PointMark(x: .value("Week", date, unit: .weekOfYear), y: .value("Failure Rate", p.failureRate ?? 0))
                            .foregroundStyle(.red)
                    }
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } } } }
                    .frame(height: 180)
                    .padding(.vertical, 6)
                }
            }
            if let hours = analysis.failuresByHour, hours.values.contains(where: { $0 > 0 }) {
                Section("Failures by Start Hour") {
                    Chart(0..<24, id: \.self) { h in
                        BarMark(x: .value("Hour", h), y: .value("Failures", hours[String(h)] ?? 0))
                            .foregroundStyle(.red.gradient)
                    }
                    .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
                    .frame(height: 150)
                    .padding(.vertical, 6)
                }
            }
            breakdown("By Reason", sorted(analysis.failuresByReason)) { StatsAggregator.reasonLabel($0) }
            breakdown("By Material", sorted(analysis.failuresByFilament)) { $0 }
            breakdown("By Printer", sorted(analysis.failuresByPrinter)) { $0 }
            if let recent = analysis.recentFailures, !recent.isEmpty {
                Section("Recent Failures") {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.printName ?? "Untitled").font(.subheadline.weight(.medium))
                            HStack(spacing: 6) {
                                if let r = f.failureReason, !r.isEmpty { StatusBadge(text: StatsAggregator.reasonLabel(r), color: .red) }
                                if let t = f.filamentType, !t.isEmpty { StatusBadge(text: t, color: .secondary) }
                            }
                            HStack(spacing: 6) {
                                if let pid = f.printerId { Text(printerName(pid)) }
                                if f.createdAt != nil { Text(Fmt.date(f.createdAt)) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Failure Analysis")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func breakdown(_ title: String, _ rows: [(key: String, value: Double)], label: @escaping (String) -> String) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows, id: \.key) { key, value in
                    LabeledContent(label(key), value: "\(Int(value))")
                }
            }
        }
    }
}

// MARK: - Records

struct StatsRecordsView: View {
    let records: [StatsRecord]

    private func style(_ kind: StatsRecord.Kind) -> (String, String, Color) {
        switch kind {
        case .longest: ("Longest Print", "clock.fill", .blue)
        case .heaviest: ("Heaviest Print", "scalemass.fill", .orange)
        case .costliest: ("Most Expensive Print", "dollarsign.circle.fill", .green)
        case .busiestDay: ("Busiest Day", "calendar", .purple)
        case .streak: ("Current Success Streak", "bolt.fill", .yellow)
        }
    }

    var body: some View {
        if records.isEmpty {
            StatsEmptyNote(text: "No prints in this period.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(records) { r in
                    let (label, icon, tint) = style(r.kind)
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .foregroundStyle(tint)
                            .frame(width: 30, height: 30)
                            .background(tint.opacity(0.14), in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label).font(.caption).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(r.value).font(.subheadline.weight(.bold)).monospacedDigit()
                                if let d = r.detail, !d.isEmpty {
                                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Print activity

struct StatsActivityView: View {
    let runs: [StatsPrintRun]
    let from: Date?
    let to: Date?
    private let calendar = Calendar.current

    var body: some View {
        let dates = runs.compactMap(\.createdDate)
        let span = spanDays
        VStack(alignment: .leading, spacing: 10) {
            if let from, let to, span <= 7 {
                StatsHourlyHeatmap(dates: dates, from: from, to: to)
            } else {
                StatsCalendarHeatmap(dates: dates, months: months(span: span, dates: dates))
            }
            HStack {
                Text("\(dates.count) prints").font(.caption).foregroundStyle(.secondary)
                Spacer()
                StatsHeatLegend()
            }
        }
    }

    private var spanDays: Double {
        guard let from else { return .infinity }
        let end = to ?? calendar.startOfDay(for: .now)
        return max(0, end.timeIntervalSince(from) / 86400) + 1
    }

    private func months(span: Double, dates: [Date]) -> Int {
        if span.isFinite { return max(1, min(24, Int((span / 30).rounded(.up)))) }
        guard let first = dates.min() else { return 6 }
        let m = calendar.dateComponents([.month], from: first, to: .now).month ?? 0
        return max(3, min(12, m + 1))
    }
}

private struct StatsHeatCell: Identifiable {
    var x: Int
    var row: String
    var count: Int
    var label: String
    var id: String { "\(x)-\(row)" }
}

/// GitHub-style calendar: one column per week, one row per weekday.
struct StatsCalendarHeatmap: View {
    let dates: [Date]
    let months: Int
    private let calendar = Calendar.current

    var body: some View {
        let model = build()
        Chart(model.cells) { c in
            RectangleMark(xStart: .value("Week", c.x), xEnd: .value("Week", c.x + 1), y: .value("Day", c.row))
                .foregroundStyle(StatsPalette.heat(c.count, max: model.max))
                .cornerRadius(2)
        }
        .chartYScale(domain: model.rows)
        .chartXScale(domain: 0...max(1, model.weeks))
        .chartXAxis {
            AxisMarks(values: model.monthMarks.map(\.week)) { v in
                AxisValueLabel(anchor: .topLeading) {
                    if let w = v.as(Int.self), let m = model.monthMarks.first(where: { $0.week == w }) { Text(m.label) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: model.rows.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)) { _ in
                AxisValueLabel()
            }
        }
        .chartPlotStyle { $0.padding(.horizontal, 1) }
        .frame(height: 150)
        .accessibilityLabel("Print calendar for the last \(months) months")
    }

    private struct Model {
        var cells: [StatsHeatCell] = []
        var rows: [String] = []
        var monthMarks: [(week: Int, label: String)] = []
        var weeks = 0
        var max = 1
    }

    private func build() -> Model {
        var m = Model()
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        m.rows = (0..<7).map { symbols[(first + $0) % 7] }
        var counts: [Date: Int] = [:]
        for d in dates { counts[calendar.startOfDay(for: d), default: 0] += 1 }
        m.max = Swift.max(1, counts.values.max() ?? 1)
        let today = calendar.startOfDay(for: .now)
        let back = calendar.date(byAdding: .month, value: -months, to: today) ?? today
        let start = calendar.dateInterval(of: .weekOfYear, for: back)?.start ?? back
        var day = start
        var week = 0
        var lastMonth = -1
        while day <= today {
            let wdIndex = (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
            if wdIndex == 0 && day != start { week += 1 }
            let month = calendar.component(.month, from: day)
            if month != lastMonth {
                if calendar.component(.day, from: day) <= 7 || lastMonth == -1 {
                    m.monthMarks.append((week, day.formatted(.dateTime.month(.abbreviated))))
                }
                lastMonth = month
            }
            m.cells.append(StatsHeatCell(x: week, row: m.rows[wdIndex], count: counts[day] ?? 0, label: day.formatted(date: .abbreviated, time: .omitted)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        m.weeks = week + 1
        // Drop labels that would collide.
        var filtered: [(week: Int, label: String)] = []
        for mark in m.monthMarks where filtered.last.map({ mark.week - $0.week >= 3 }) ?? true { filtered.append(mark) }
        m.monthMarks = filtered
        return m
    }
}

/// Day × hour grid for short ranges (≤ 7 days).
struct StatsHourlyHeatmap: View {
    let dates: [Date]
    let from: Date
    let to: Date
    private let calendar = Calendar.current

    var body: some View {
        let (cells, rows, maxCount) = build()
        Chart(cells) { c in
            RectangleMark(xStart: .value("Hour", c.x), xEnd: .value("Hour", c.x + 1), y: .value("Day", c.row))
                .foregroundStyle(StatsPalette.heat(c.count, max: maxCount))
                .cornerRadius(2)
        }
        .chartYScale(domain: rows)
        .chartXScale(domain: 0...24)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { v in
                AxisValueLabel {
                    if let h = v.as(Int.self) { Text(hourLabel(h % 24)) }
                }
            }
        }
        .frame(height: CGFloat(max(1, rows.count)) * 24 + 30)
    }

    private func hourLabel(_ h: Int) -> String {
        var c = DateComponents(); c.hour = h
        return (calendar.date(from: c) ?? .now).formatted(.dateTime.hour())
    }

    private func build() -> ([StatsHeatCell], [String], Int) {
        var rows: [String] = []
        var keys: [Date] = []
        var day = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        while day <= end {
            keys.append(day)
            rows.append(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        var counts: [String: Int] = [:]
        for d in dates {
            let k = calendar.startOfDay(for: d)
            guard let idx = keys.firstIndex(of: k) else { continue }
            counts["\(idx)-\(calendar.component(.hour, from: d))", default: 0] += 1
        }
        let maxCount = max(1, counts.values.max() ?? 1)
        var cells: [StatsHeatCell] = []
        for (i, row) in rows.enumerated() {
            for h in 0..<24 {
                cells.append(StatsHeatCell(x: h, row: row, count: counts["\(i)-\(h)"] ?? 0, label: row))
            }
        }
        return (cells, rows, maxCount)
    }
}
