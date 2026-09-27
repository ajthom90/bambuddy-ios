import SwiftUI

// MARK: Models

struct PrinterMQTTLogs: Codable, Sendable, Hashable {
    var loggingEnabled: Bool
    var logs: [PrinterMQTTLogEntry]
}

struct PrinterMQTTLogEntry: Codable, Sendable, Hashable {
    var timestamp: String
    var topic: String
    var direction: String
    var payload: JSONValue

    var isOutgoing: Bool { direction == "out" }

    var prettyPayload: String {
        guard let data = try? JSONEncoder.prettySorted.encode(payload) else { return payload.displayString }
        return String(decoding: data, as: UTF8.self)
    }

    /// Top-level command name (e.g. `push_status`, `print.gcode_line`) for list rows.
    var summary: String {
        guard case .object(let o) = payload else { return payload.displayString }
        for (key, value) in o.sorted(by: { $0.key < $1.key }) {
            if let cmd = value["command"]?.stringValue { return "\(key).\(cmd)" }
        }
        return o.keys.sorted().joined(separator: ", ")
    }
}

private extension JSONEncoder {
    static let prettySorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

// MARK: View

/// Raw MQTT traffic capture for debugging a printer connection.
struct PrinterLoggingView: View {
    @Environment(AppSession.self) private var session
    let printerId: Int

    @State private var loader = Loader<PrinterMQTTLogs>()
    @State private var runner = ActionRunner()
    @State private var search = ""
    @State private var direction = "all"
    @State private var autoRefresh = true
    @State private var confirmClear = false

    private var client: APIClient { session.client }
    private var canControl: Bool { session.can("printers:control") }

    var body: some View {
        LoadingContent(loader: loader, retry: load) { logs in
            List {
                Section {
                    Toggle(isOn: Binding(get: { logs.loggingEnabled }, set: { on in Task { await setLogging(on) } })) {
                        Label("Capture MQTT Messages", systemImage: "record.circle")
                    }
                    .disabled(!canControl || runner.isRunning)
                    Toggle("Auto-Refresh", isOn: $autoRefresh)
                    Picker("Direction", selection: $direction) {
                        Text("All").tag("all")
                        Text("Incoming").tag("in")
                        Text("Outgoing").tag("out")
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Logging keeps recent messages in the server's memory until disabled or cleared.")
                }
                let entries = filtered(logs.logs)
                Section("\(entries.count) Message\(entries.count == 1 ? "" : "s")") {
                    if entries.isEmpty {
                        Text(logs.loggingEnabled ? "Waiting for messages…" : "Enable capture to record messages.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        NavigationLink {
                            ScrollView {
                                Text(entry.prettyPayload)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                            }
                            .navigationTitle(entry.summary)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .primaryAction) {
                                    ShareLink(item: entry.prettyPayload) { Image(systemName: "square.and.arrow.up") }
                                }
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: entry.isOutgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .foregroundStyle(entry.isOutgoing ? .orange : .blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.summary).font(.subheadline.monospaced()).lineLimit(1)
                                    Text("\(Fmt.date(entry.timestamp, style: .dateTime.hour().minute().second())) · \(entry.topic)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("MQTT Log")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search payloads")
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let logs = loader.value, !logs.logs.isEmpty {
                        ShareLink(item: exportText(logs.logs)) { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                    if canControl {
                        Button(role: .destructive) { confirmClear = true } label: { Label("Clear Log", systemImage: "trash") }
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .task { await load() }
        .task(id: autoRefresh) {
            while autoRefresh, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if autoRefresh, loader.value?.loggingEnabled == true { await load() }
            }
        }
        .actionAlerts(runner)
        .confirm("Clear the MQTT log?", isPresented: $confirmClear, action: "Clear") {
            Task { await runner.run { try await client.call(.delete, "printers/\(printerId)/logging"); await load() } }
        }
    }

    private func filtered(_ logs: [PrinterMQTTLogEntry]) -> [PrinterMQTTLogEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return logs.reversed().filter { e in
            (direction == "all" || e.direction == direction)
                && (q.isEmpty || e.topic.localizedCaseInsensitiveContains(q) || e.prettyPayload.localizedCaseInsensitiveContains(q))
        }
    }

    private func exportText(_ logs: [PrinterMQTTLogEntry]) -> String {
        logs.map { "[\($0.timestamp)] \($0.direction.uppercased()) \($0.topic)\n\($0.prettyPayload)" }.joined(separator: "\n\n")
    }

    private func load() async {
        await loader.load { try await client.get("printers/\(printerId)/logging") }
    }

    private func setLogging(_ on: Bool) async {
        await runner.run(on ? "Logging enabled" : "Logging disabled") {
            try await client.call(.post, "printers/\(printerId)/logging/\(on ? "enable" : "disable")")
            await load()
        }
    }
}

// MARK: Calibration

struct PrinterCalibrationView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let printerId: Int

    @State private var bedLeveling = true
    @State private var vibration = false
    @State private var motorNoise = false
    @State private var nozzleOffset = false
    @State private var highTempBed = false
    @State private var confirm = false
    @State private var runner = ActionRunner()

    private var status: PrinterStatus? { store.statuses[printerId] }
    private var model: String { PrinterFilamentLogic.modelCode(store.printer(printerId)?.model).uppercased() }
    private var isDual: Bool { (store.printer(printerId)?.nozzleCount ?? 1) >= 2 || (status?.isDualNozzle ?? false) }
    private var isH2: Bool { model.hasPrefix("H2") || model.hasPrefix("X2") }
    private var supportsMotorNoise: Bool { !model.hasPrefix("A1") }
    private var busy: Bool { status?.isActiveJob ?? false }
    private var anySelected: Bool { bedLeveling || vibration || motorNoise || nozzleOffset || highTempBed }

    var body: some View {
        Form {
            if busy {
                Section {
                    Label("Calibration is unavailable while a print is running.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if status?.connected == false {
                Section {
                    Label("The printer is offline.", systemImage: "wifi.slash").foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Bed Leveling", isOn: $bedLeveling)
                Toggle("Vibration Compensation", isOn: $vibration)
                if supportsMotorNoise { Toggle("Motor Noise Cancellation", isOn: $motorNoise) }
                if isDual { Toggle("Nozzle Offset", isOn: $nozzleOffset) }
                if isH2 { Toggle("High-Temperature Heatbed", isOn: $highTempBed) }
            } footer: {
                Text("The printer runs the selected routines in sequence. Make sure the build plate is empty and installed.")
            }
            Section {
                Button("Start Calibration") { confirm = true }
                    .disabled(!anySelected || busy || status?.connected == false || !session.can("printers:control") || runner.isRunning)
            }
        }
        .navigationTitle("Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .actionAlerts(runner)
        .confirm("Start calibration?", isPresented: $confirm, message: "The printer will move and heat up. Keep the build plate clear.", action: "Start", role: nil) {
            Task {
                await runner.run("Calibration started") {
                    try await session.client.call(.post, "printers/\(printerId)/calibration", query: [
                        "bed_leveling": .bool(bedLeveling),
                        "vibration": .bool(vibration),
                        "motor_noise": .bool(motorNoise && supportsMotorNoise),
                        "nozzle_offset": .bool(nozzleOffset && isDual),
                        "high_temp_heatbed": .bool(highTempBed && isH2),
                    ])
                }
            }
        }
    }
}
