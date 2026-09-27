import SwiftUI
import Charts

// MARK: Models

struct PrinterAMSHistory: Codable, Sendable, Hashable {
    var printerId: Int
    var amsId: Int
    var data: [PrinterAMSHistoryPoint]
    var minHumidity: Double?
    var maxHumidity: Double?
    var avgHumidity: Double?
    var minTemperature: Double?
    var maxTemperature: Double?
    var avgTemperature: Double?
}

struct PrinterAMSHistoryPoint: Codable, Sendable, Hashable {
    var recordedAt: String
    var humidity: Double?
    var humidityRaw: Double?
    var temperature: Double?

    var date: Date? { APICoders.parseDate(recordedAt) }
}

struct PrinterSensorHistory: Codable, Sendable, Hashable {
    var printerId: Int
    var series: [PrinterSensorSeries]
}

struct PrinterSensorSeries: Codable, Sendable, Hashable {
    var sensorKind: String
    var data: [PrinterSensorPoint]
    var minValue: Double?
    var maxValue: Double?
    var avgValue: Double?

    var label: String { PrinterSensorSeries.label(for: sensorKind) }

    static func label(for kind: String) -> String {
        switch kind {
        case "nozzle": return "Nozzle"
        case "nozzle_2": return "Nozzle 2"
        case "bed": return "Bed"
        case "chamber": return "Chamber"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct PrinterSensorPoint: Codable, Sendable, Hashable {
    var recordedAt: String
    var value: Double?
    var target: Double?

    var date: Date? { APICoders.parseDate(recordedAt) }
}

/// Time windows offered by the history charts.
enum PrinterHistoryRange: Int, CaseIterable, Identifiable {
    case h6 = 6, h24 = 24, h48 = 48, d7 = 168
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .h6: return "6h"
        case .h24: return "24h"
        case .h48: return "48h"
        case .d7: return "7d"
        }
    }
}

// MARK: AMS humidity / temperature history

struct PrinterAMSHistoryView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    let printerId: Int
    @State var amsId: Int
    @State private var range: PrinterHistoryRange = .h24
    @State private var loader = Loader<PrinterAMSHistory>()
    @State private var runner = ActionRunner()
    @State private var confirmPurge = false

    private var units: [AMSUnit] { store.statuses[printerId]?.ams ?? [] }

    var body: some View {
        List {
            Section {
                if units.count > 1 {
                    Picker("AMS Unit", selection: $amsId) {
                        ForEach(units) { unit in Text(unit.label).tag(unit.id) }
                    }
                }
                Picker("Range", selection: $range) {
                    ForEach(PrinterHistoryRange.allCases) { r in Text(r.label).tag(r) }
                }
                .pickerStyle(.segmented)
            }
            LoadingContent(loader: loader, retry: load) { history in
                if history.data.isEmpty {
                    ContentUnavailableView("No History", systemImage: "chart.xyaxis.line", description: Text("No humidity or temperature readings were recorded in this period."))
                } else {
                    Section("Humidity") {
                        humidityChart(history)
                        statsRow(min: history.minHumidity, avg: history.avgHumidity, max: history.maxHumidity, unit: "%")
                    }
                    Section("Temperature") {
                        temperatureChart(history)
                        statsRow(min: history.minTemperature, avg: history.avgTemperature, max: history.maxTemperature, unit: "°C")
                    }
                }
            }
            if session.can("ams_history:read") {
                Section {
                    Button("Delete History Older Than 7 Days", role: .destructive) { confirmPurge = true }
                }
            }
        }
        .navigationTitle("AMS History")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: "\(amsId)-\(range.rawValue)") { await load() }
        .actionAlerts(runner)
        .confirm("Delete old AMS history?", isPresented: $confirmPurge, message: "Readings older than 7 days are removed for all AMS units of this printer.") {
            Task {
                await runner.run("History cleaned up") {
                    try await session.client.call(.delete, "ams-history/\(printerId)", query: ["days": 7])
                    await load()
                }
            }
        }
    }

    private func load() async {
        await loader.load { try await session.client.get("ams-history/\(printerId)/\(amsId)", query: ["hours": .int(range.rawValue)]) }
    }

    @ViewBuilder
    private func humidityChart(_ history: PrinterAMSHistory) -> some View {
        Chart {
            ForEach(Array(history.data.enumerated()), id: \.offset) { _, point in
                if let date = point.date, let h = point.humidity {
                    AreaMark(x: .value("Time", date), y: .value("Humidity", h))
                        .foregroundStyle(.linearGradient(colors: [.blue.opacity(0.35), .blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", date), y: .value("Humidity", h))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                }
            }
            RuleMark(y: .value("Dry", 40)).foregroundStyle(.green.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("Humid", 60)).foregroundStyle(.orange.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .chartYScale(domain: 0...100)
        .chartYAxisLabel("%")
        .frame(height: 200)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func temperatureChart(_ history: PrinterAMSHistory) -> some View {
        let temps = history.data.compactMap(\.temperature)
        let lo = (temps.min() ?? 0) - 2, hi = (temps.max() ?? 40) + 2
        Chart {
            ForEach(Array(history.data.enumerated()), id: \.offset) { _, point in
                if let date = point.date, let t = point.temperature {
                    LineMark(x: .value("Time", date), y: .value("Temperature", t))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: lo...max(hi, lo + 1))
        .chartYAxisLabel("°C")
        .frame(height: 180)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func statsRow(min: Double?, avg: Double?, max: Double?, unit: String) -> some View {
        HStack {
            stat("Min", min, unit)
            Spacer()
            stat("Average", avg, unit)
            Spacer()
            stat("Max", max, unit)
        }
    }

    private func stat(_ title: String, _ value: Double?, _ unit: String) -> some View {
        VStack {
            Text(value.map { Fmt.number($0) + unit } ?? "—").font(.headline).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Printer sensor history (nozzle / bed / chamber)

struct PrinterSensorHistoryView: View {
    @Environment(AppSession.self) private var session
    let printerId: Int
    @State private var range: PrinterHistoryRange = .h24
    @State private var loader = Loader<PrinterSensorHistory>()
    @State private var runner = ActionRunner()
    @State private var hidden: Set<String> = []
    @State private var showTargets = true
    @State private var confirmPurge = false

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(PrinterHistoryRange.allCases) { r in Text(r.label).tag(r) }
                }
                .pickerStyle(.segmented)
                Toggle("Show Targets", isOn: $showTargets)
            }
            LoadingContent(loader: loader, retry: load) { history in
                let series = history.series.filter { !$0.data.isEmpty }
                if series.isEmpty {
                    ContentUnavailableView("No History", systemImage: "thermometer.medium", description: Text("No temperature readings were recorded in this period."))
                } else {
                    Section {
                        chart(series.filter { !hidden.contains($0.sensorKind) })
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(series, id: \.sensorKind) { s in
                                    Button {
                                        if hidden.contains(s.sensorKind) { hidden.remove(s.sensorKind) } else { hidden.insert(s.sensorKind) }
                                    } label: {
                                        Label(s.label, systemImage: hidden.contains(s.sensorKind) ? "circle" : "circle.fill")
                                            .foregroundStyle(color(s.sensorKind))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    Section("Statistics") {
                        ForEach(series, id: \.sensorKind) { s in
                            LabeledContent(s.label) {
                                Text("min \(Fmt.temp(s.minValue)) · avg \(Fmt.temp(s.avgValue)) · max \(Fmt.temp(s.maxValue))")
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            if session.can("printer_sensor_history:read") {
                Section {
                    Button("Delete History Older Than 7 Days", role: .destructive) { confirmPurge = true }
                }
            }
        }
        .navigationTitle("Temperature History")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: range) { await load() }
        .actionAlerts(runner)
        .confirm("Delete old temperature history?", isPresented: $confirmPurge, message: "Readings older than 7 days are removed for this printer.") {
            Task {
                await runner.run("History cleaned up") {
                    try await session.client.call(.delete, "printer-sensor-history/\(printerId)", query: ["days": 7])
                    await load()
                }
            }
        }
    }

    private func load() async {
        await loader.load { try await session.client.get("printer-sensor-history/\(printerId)", query: ["hours": .int(range.rawValue)]) }
    }

    private func color(_ kind: String) -> Color {
        switch kind {
        case "nozzle": return .red
        case "nozzle_2": return .pink
        case "bed": return .orange
        case "chamber": return .teal
        default: return .gray
        }
    }

    @ViewBuilder
    private func chart(_ series: [PrinterSensorSeries]) -> some View {
        Chart {
            ForEach(series, id: \.sensorKind) { s in
                ForEach(Array(s.data.enumerated()), id: \.offset) { _, p in
                    if let date = p.date, let v = p.value {
                        LineMark(x: .value("Time", date), y: .value("°C", v), series: .value("Sensor", s.label))
                            .foregroundStyle(by: .value("Sensor", s.label))
                            .interpolationMethod(.monotone)
                    }
                }
                if showTargets {
                    ForEach(Array(s.data.enumerated()), id: \.offset) { _, p in
                        if let date = p.date, let t = p.target {
                            LineMark(x: .value("Time", date), y: .value("°C", t), series: .value("Target", s.label + " target"))
                                .foregroundStyle(by: .value("Sensor", s.label))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .opacity(0.6)
                        }
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.label), range: series.map { color($0.sensorKind) })
        .chartLegend(.hidden)
        .chartYAxisLabel("°C")
        .frame(height: 260)
        .padding(.vertical, 6)
    }
}
