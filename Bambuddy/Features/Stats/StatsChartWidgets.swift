import SwiftUI
import Charts

private let panelColumns = [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)]

// MARK: - Printer stats

struct StatsPrinterBreakdownView: View {
    let runs: [StatsPrintRun]
    let printCounts: [String: Double]?
    let printerName: (String) -> String

    @State private var printerMetric: StatsMetricKind = .weight
    @State private var habitsMetric: StatsMetricKind = .weight

    private func tint(_ m: StatsMetricKind) -> Color {
        switch m { case .weight: .green; case .time: .blue; case .prints: .orange }
    }

    var body: some View {
        VStack(spacing: 14) {
            byPrinter
            LazyVGrid(columns: panelColumns, spacing: 14) {
                durations
                habits
                timeOfDay
            }
        }
    }

    private var byPrinter: some View {
        let data = StatsAggregator.byPrinter(runs, counts: printCounts, metric: printerMetric, name: printerName)
        return StatsPanel("By Printer", accessory: { StatsMetricPicker(metric: $printerMetric) }) {
            if data.isEmpty {
                StatsEmptyNote(text: "No printer data for this period.")
            } else {
                Chart(data) { d in
                    BarMark(x: .value(printerMetric.title, d.value), y: .value("Printer", d.name))
                        .foregroundStyle(tint(printerMetric).gradient)
                        .cornerRadius(4)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(printerMetric.format(d.value)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { if let x = v.as(Double.self) { Text(axisLabel(x, printerMetric)) } }
                    }
                }
                .chartXScale(domain: 0...(max(1, data.map(\.value).max() ?? 1) * 1.2))
                .frame(height: max(120, CGFloat(data.count) * 38))
            }
        }
    }

    private var durations: some View {
        let data = StatsAggregator.durationHistogram(runs)
        return StatsPanel("Print Duration") {
            if runs.isEmpty {
                StatsEmptyNote(text: "No prints in this period.", height: 160)
            } else {
                Chart(data) { d in
                    BarMark(x: .value("Duration", d.name), y: .value("Prints", d.value))
                        .foregroundStyle(Color.green.gradient)
                        .cornerRadius(3)
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .frame(height: 170)
            }
        }
    }

    private var habits: some View {
        let data = StatsAggregator.weekdayHabits(runs, metric: habitsMetric)
        return StatsPanel("Average by Weekday", accessory: { StatsMetricPicker(metric: $habitsMetric) }) {
            if runs.isEmpty {
                StatsEmptyNote(text: "No prints in this period.", height: 160)
            } else {
                Chart(data) { d in
                    BarMark(x: .value("Day", d.name), y: .value(habitsMetric.title, d.value))
                        .foregroundStyle(tint(habitsMetric).gradient)
                        .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { if let y = v.as(Double.self) { Text(axisLabel(y, habitsMetric)) } }
                    }
                }
                .frame(height: 170)
            }
        }
    }

    private var timeOfDay: some View {
        let data = StatsAggregator.hourOfDay(runs)
        return StatsPanel("Start Time of Day") {
            if runs.isEmpty {
                StatsEmptyNote(text: "No prints in this period.", height: 160)
            } else {
                Chart {
                    ForEach(data, id: \.hour) { d in
                        BarMark(x: .value("Hour", d.hour), y: .value("Prints", d.total))
                            .foregroundStyle(by: .value("Series", "All prints"))
                            .position(by: .value("Series", "All prints"))
                        BarMark(x: .value("Hour", d.hour), y: .value("Prints", d.failed))
                            .foregroundStyle(by: .value("Series", "Failed"))
                            .position(by: .value("Series", "Failed"))
                    }
                }
                .chartForegroundStyleScale(["All prints": Color.green, "Failed": Color.red])
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18]) { v in
                        AxisGridLine()
                        AxisValueLabel { if let h = v.as(Int.self) { Text(hourLabel(h)) } }
                    }
                }
                .chartLegend(position: .bottom, spacing: 6)
                .frame(height: 190)
            }
        }
    }
}

private func axisLabel(_ value: Double, _ metric: StatsMetricKind) -> String {
    switch metric {
    case .weight: value >= 1000 ? "\(Fmt.number(value / 1000, digits: 1))kg" : "\(Int(value))g"
    case .time: "\(Fmt.number(value, digits: 1))h"
    case .prints: Fmt.number(value, digits: 1)
    }
}

private func hourLabel(_ h: Int) -> String {
    var c = DateComponents(); c.hour = h
    return (Calendar.current.date(from: c) ?? .now).formatted(.dateTime.hour())
}

// MARK: - Filament trends

struct StatsFilamentTrendsView: View {
    let runs: [StatsPrintRun]
    let currencyCode: String
    /// Selected range length in days (`nil` = all time).
    let spanDays: Double?

    @State private var materialMetric: StatsMetricKind = .weight
    @State private var colorMetric: StatsMetricKind = .weight

    var body: some View {
        if runs.isEmpty {
            StatsEmptyNote(text: "No prints in this period.")
        } else {
            content
        }
    }

    private var content: some View {
        let granularity = StatsAggregator.granularity(spanDays: spanDays, runs: runs)
        let series = StatsAggregator.timeSeries(runs, granularity: granularity)
        let filament = runs.reduce(0) { $0 + ($1.filamentUsedGrams ?? 0) }
        let cost = runs.reduce(0) { $0 + ($1.cost ?? 0) }
        let energy = runs.reduce(0) { $0 + ($1.energyKwh ?? 0) }
        let energyCost = runs.reduce(0) { $0 + ($1.energyCost ?? 0) }
        let prints = runs.reduce(0) { $0 + ($1.quantity ?? 1) }
        let printers = Set(runs.compactMap(\.printerId)).count
        return VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                summaryTile("Filament in Period", Fmt.grams(filament), "\(printers) printer\(printers == 1 ? "" : "s")")
                summaryTile("Cost in Period", Fmt.currency(cost, code: currencyCode), "\(prints) print\(prints == 1 ? "" : "s")")
                summaryTile("Average per Print",
                            prints > 0 ? Fmt.grams(filament / Double(prints)) : "0 g",
                            "\(Fmt.currency(prints > 0 ? cost / Double(prints) : 0, code: currencyCode)) average")
            }
            StatsPanel("Filament Usage Over Time") {
                areaChart(series, granularity: granularity, value: \.filament, color: .green) { Fmt.grams($0) }
            }
            if energy > 0 {
                StatsPanel("Energy Over Time", accessory: {
                    Text("\(Fmt.number(energy, digits: 3)) kWh · \(Fmt.currency(energyCost, code: currencyCode))")
                        .font(.caption).foregroundStyle(.secondary)
                }) {
                    areaChart(series, granularity: granularity, value: \.energy, color: .orange) { "\(Fmt.number($0, digits: 3)) kWh" }
                }
            }
            LazyVGrid(columns: panelColumns, spacing: 14) {
                materials
                materialSuccess
                colors
            }
        }
    }

    private func summaryTile(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func areaChart(_ series: [StatsTimePoint], granularity: StatsAggregator.Granularity,
                           value: KeyPath<StatsTimePoint, Double>, color: Color, format: @escaping (Double) -> String) -> some View {
        let unit: Calendar.Component = switch granularity { case .hour: .hour; case .day: .day; case .week: .weekOfYear }
        return StatsTrendChart(series: series, unit: unit, value: value, color: color, format: format)
    }

    private var materials: some View {
        let data = StatsAggregator.byMaterial(runs, metric: materialMetric)
        return StatsPanel("By Material", accessory: { StatsMetricPicker(metric: $materialMetric) }) {
            if data.isEmpty {
                StatsEmptyNote(text: "No material data.", height: 150)
            } else {
                StatsDonut(data: data, color: { i, _ in StatsPalette.color(i) }, format: { materialMetric.format($0) })
            }
        }
    }

    private var materialSuccess: some View {
        let data = StatsAggregator.materialSuccess(runs)
        return StatsPanel("Success by Material") {
            if data.isEmpty {
                StatsEmptyNote(text: "Not enough completed or failed prints per material.", height: 150)
            } else {
                VStack(spacing: 8) {
                    ForEach(data, id: \.name) { d in
                        HStack(spacing: 8) {
                            Text(d.name).font(.subheadline).lineLimit(1).frame(width: 84, alignment: .leading)
                            ProgressView(value: d.rate, total: 100).tint(StatsPalette.rate(d.rate))
                            Text("\(Int(d.rate.rounded()))%").font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(StatsPalette.rate(d.rate)).frame(width: 44, alignment: .trailing)
                            Text("(\(d.total))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var colors: some View {
        let data = StatsAggregator.colors(runs, metric: colorMetric)
        let total = data.reduce(0) { $0 + $1.value }
        return StatsPanel("Colors", accessory: { StatsMetricPicker(metric: $colorMetric, options: [.weight, .prints]) }) {
            if data.isEmpty {
                StatsEmptyNote(text: "No color data.", height: 150)
            } else {
                StatsDonut(
                    data: data,
                    color: { _, e in Color(hex: e.name) ?? .gray },
                    format: { colorMetric.format($0) },
                    legendName: { "#" + $0.name.replacingOccurrences(of: "#", with: "").prefix(6).uppercased() },
                    centerTitle: colorMetric.format(total),
                    centerSubtitle: "\(data.count) color\(data.count == 1 ? "" : "s")"
                )
            }
        }
    }
}

/// Area + line chart over time with a scrubbing selection.
private struct StatsTrendChart: View {
    let series: [StatsTimePoint]
    let unit: Calendar.Component
    let value: KeyPath<StatsTimePoint, Double>
    let color: Color
    let format: (Double) -> String
    @State private var selection: Date?

    private var selected: StatsTimePoint? {
        guard let selection else { return nil }
        return series.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        Chart {
            ForEach(series) { p in
                AreaMark(x: .value("Date", p.date, unit: unit), y: .value("Value", p[keyPath: value]))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", p.date, unit: unit), y: .value("Value", p[keyPath: value]))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
                if series.count == 1 {
                    PointMark(x: .value("Date", p.date, unit: unit), y: .value("Value", p[keyPath: value])).foregroundStyle(color)
                }
            }
            if let s = selected {
                RuleMark(x: .value("Date", s.date, unit: unit))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 2) {
                            Text(format(s[keyPath: value])).font(.caption.weight(.bold)).monospacedDigit()
                            Text(dateLabel(s.date)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    }
            }
        }
        .chartXSelection(value: $selection)
        .frame(height: 220)
    }

    private func dateLabel(_ d: Date) -> String {
        switch unit {
        case .hour: d.formatted(.dateTime.weekday(.abbreviated).hour())
        case .weekOfYear: "Week of " + d.formatted(.dateTime.month(.abbreviated).day())
        default: d.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
