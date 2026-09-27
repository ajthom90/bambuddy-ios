import SwiftUI

// MARK: - Models

/// `GET /obico/status` — detection scheduler state, live classifications and recent history.
struct SettingsObicoStatus: Codable, Sendable {
    var isRunning: Bool?
    var lastError: String?
    /// Keyed by printer id (as a string).
    var perPrinter: [String: SettingsObicoPrinterState]?
    var thresholds: SettingsObicoThresholds?
    var history: [SettingsObicoHistoryEntry]?
    var enabled: Bool?
    var mlUrl: String?
    var sensitivity: String?
    var action: String?
    var pollInterval: Int?
    var externalUrlConfigured: Bool?
}

/// Live classification of one monitored print.
struct SettingsObicoPrinterState: Codable, Sendable, Hashable {
    /// `safe`, `warning`, `failure`, `unknown` (no verdict yet) or `error` (last poll failed).
    var verdict: String?
    var frameCount: Int?
    var score: Double?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case verdict = "class"
        case frameCount, score, error
    }
}

struct SettingsObicoThresholds: Codable, Sendable, Hashable {
    var low: Double?
    var high: Double?
}

struct SettingsObicoHistoryEntry: Codable, Sendable, Hashable {
    var printerId: Int?
    var taskName: String?
    var timestamp: String?
    var currentP: Double?
    var score: Double?
    var verdict: String?
    var detections: Int?

    enum CodingKeys: String, CodingKey {
        case verdict = "class"
        case printerId, taskName, timestamp, currentP, score, detections
    }
}

/// `GET /obico/printer-status`.
struct SettingsObicoPrinterStatus: Codable, Sendable {
    var enabled: Bool?
    /// `nil` = every printer is monitored.
    var monitoredPrinters: [Int]?
    var perPrinter: [String: SettingsObicoPrinterState]?
    var lastError: String?
}

/// Body for `POST /obico/test-connection`. Omitting `token` tests with the saved token.
struct SettingsObicoTestRequest: Encodable, Sendable {
    var url: String
    var token: String?
}

/// `POST /obico/test-connection` response.
struct SettingsObicoTestResult: Codable, Sendable {
    var ok: Bool?
    var statusCode: Int?
    var body: String?
    var error: String?
    /// `nil` when the token could not be verified.
    var authOk: Bool?
}

/// Encodes/decodes the `obico_enabled_printers` setting: an empty string means every printer,
/// otherwise a JSON array of printer ids.
enum SettingsObicoPrinterSelection {
    static func parse(_ raw: String) -> [Int]? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "None", let data = trimmed.data(using: .utf8),
              let ids = try? JSONDecoder().decode([Int].self, from: data) else { return nil }
        return ids
    }

    static func encode(_ ids: [Int]?) -> String {
        guard let ids else { return "" }
        let unique = Array(Set(ids)).sorted()
        return "[" + unique.map(String.init).joined(separator: ",") + "]"
    }

    /// Turning one printer on or off; switching away from "all" starts from every known printer.
    static func toggled(_ current: [Int]?, printer id: Int, on: Bool, allPrinters: [Int]) -> [Int] {
        var ids = current ?? allPrinters
        if on { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
        return ids.sorted()
    }
}

// MARK: - Page

struct SettingsFailureDetectionView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store
    @Environment(PrinterStore.self) private var printerStore
    @State private var status: SettingsObicoStatus?
    @State private var printerStatus: SettingsObicoPrinterStatus?
    @State private var statusError: String?
    @State private var testing = false
    @State private var testResult: (success: Bool, message: String)?

    private var enabled: Bool { store.bool("obico_enabled") }
    private var selection: [Int]? { SettingsObicoPrinterSelection.parse(store.string("obico_enabled_printers")) }

    var body: some View {
        SettingsForm("Failure Detection") {
            Section {
                SettingsToggle("AI Failure Detection", key: "obico_enabled")
            } footer: {
                Text("While a print runs, Bambuddy sends camera snapshots to your self-hosted Obico ML server, which scores them for spaghetti and other failures. Snapshots only go to your own server.")
            }

            if enabled, status?.externalUrlConfigured == false {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("External URL not set").fontWeight(.semibold)
                            Text("The ML server fetches snapshots from Bambuddy, so it needs Bambuddy's External URL. Set it in Bambuddy's server settings.")
                                .font(.footnote)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            serverSection.disabled(!enabled)
            detectionSection.disabled(!enabled)
            printersSection.disabled(!enabled)
            statusSection
            activeSection
            historySection
        }
        .task {
            if printerStore.printers.isEmpty { await printerStore.refresh() }
        }
        .task {
            while !Task.isCancelled {
                await loadStatus()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onChange(of: store.saveCount) { _, _ in Task { await loadStatus() } }
    }

    // MARK: Sections

    private var serverSection: some View {
        Section {
            SettingsTextField("ML Server URL", key: "obico_ml_url", prompt: "http://192.168.1.10:3333", keyboard: .URL)
            SettingsTextField("API Token", key: "obico_ml_token", prompt: "Leave empty if not required",
                              help: "Only needed when the ML server was started with ML_API_TOKEN.", secure: true)
            if session.can("settings:update") {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Label("Test Connection", systemImage: "bolt.horizontal.circle")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || store.string("obico_ml_url").isEmpty)
            }
            if let testResult {
                SettingsTestResultLabel(success: testResult.success, message: testResult.message)
            }
        } header: {
            Text("ML Server")
        } footer: {
            Text("The base URL of the Obico ML API container (it listens on port 3333 by default). The test checks that it's healthy and accepts the saved token.")
        }
    }

    private var detectionSection: some View {
        Section {
            SettingsPicker("Sensitivity", key: "obico_sensitivity",
                           choices: [("low", "Low"), ("medium", "Medium"), ("high", "High")])
            SettingsPicker("When a Failure Is Detected", key: "obico_action",
                           choices: [("notify", "Notify Only"), ("pause", "Pause Print"), ("pause_and_off", "Pause and Turn Off Printer")])
            SettingsStepper("Check Every", key: "obico_poll_interval", range: 5...120, step: 5, unit: "s", default: 10)
        } header: {
            Text("Detection")
        } footer: {
            Text("Higher sensitivity flags problems sooner but raises more false alarms. Turning the printer off switches off its linked smart plugs. Shorter intervals react faster but put more load on the ML server.")
        }
    }

    private var printersSection: some View {
        Section {
            Toggle("Monitor All Printers", isOn: Binding(
                get: { selection == nil },
                set: { all in saveSelection(all ? nil : printerStore.printers.map(\.id)) }))
                .disabled(!store.canEdit)
            if let selection {
                ForEach(printerStore.printers) { printer in
                    Toggle(printer.name, isOn: Binding(
                        get: { selection.contains(printer.id) },
                        set: { on in
                            saveSelection(SettingsObicoPrinterSelection.toggled(
                                selection, printer: printer.id, on: on, allPrinters: printerStore.printers.map(\.id)))
                        }))
                        .disabled(!store.canEdit)
                }
            }
        } header: {
            Text("Printers")
        } footer: {
            Text("Monitoring needs a working camera on the printer. Printers added later are included automatically when monitoring all printers.")
        }
    }

    private var statusSection: some View {
        Section {
            if let status {
                LabeledContent("Detection Service") {
                    StatusBadge(text: status.isRunning == true ? "Running" : "Stopped",
                                color: status.isRunning == true ? .green : .red)
                }
                if let t = status.thresholds, let low = t.low, let high = t.high {
                    LabeledContent("Warning / Failure Thresholds",
                                   value: "\(low.formatted(.number.precision(.fractionLength(2)))) / \(high.formatted(.number.precision(.fractionLength(2))))")
                }
                if let error = status.lastError ?? printerStatus?.lastError, !error.isEmpty {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } else if let statusError {
                Label(statusError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Scores are smoothed over several frames; a score above the failure threshold triggers the action you chose.")
        }
    }

    private var activeSection: some View {
        let entries = (printerStatus?.perPrinter ?? status?.perPrinter ?? [:])
            .sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
        return Section("Active Prints") {
            if entries.isEmpty {
                Text("No prints are being monitored right now.").foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.key) { key, state in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(printerName(Int(key)))
                            Spacer()
                            SettingsObicoVerdictBadge(verdict: state.verdict)
                        }
                        HStack(spacing: 8) {
                            if let score = state.score {
                                Text("Score \(score.formatted(.number.precision(.fractionLength(3))))")
                            }
                            if let frames = state.frameCount { Text("\(frames) frames") }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        if let error = state.error, !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var historySection: some View {
        Section {
            let history = status?.history ?? []
            if history.isEmpty {
                Text("Nothing detected yet.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(printerName(entry.printerId)).lineLimit(1)
                            Spacer()
                            SettingsObicoVerdictBadge(verdict: entry.verdict)
                        }
                        if let task = entry.taskName, !task.isEmpty {
                            Text(task).font(.caption).lineLimit(1)
                        }
                        HStack(spacing: 8) {
                            Text(Fmt.date(entry.timestamp, style: .dateTime.hour().minute().second()))
                            if let score = entry.score {
                                Text("Score \(score.formatted(.number.precision(.fractionLength(3))))")
                            }
                            if let n = entry.detections { Text("\(n) detection\(n == 1 ? "" : "s")") }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Recent Detections")
        } footer: {
            Text("Only frames with a finding are listed. History is kept in memory and cleared when the server restarts.")
        }
    }

    // MARK: Helpers

    private func printerName(_ id: Int?) -> String {
        guard let id else { return "Unknown Printer" }
        return printerStore.printer(id)?.name ?? "Printer #\(id)"
    }

    private func saveSelection(_ ids: [Int]?) {
        let value = SettingsObicoPrinterSelection.encode(ids)
        Task { await store.save(["obico_enabled_printers": .string(value)]) }
    }

    private func loadStatus() async {
        async let s: SettingsObicoStatus = session.client.get("obico/status")
        async let p: SettingsObicoPrinterStatus = session.client.get("obico/printer-status")
        do {
            status = try await s
            statusError = nil
        } catch is CancellationError {
        } catch {
            if status == nil { statusError = error.localizedDescription }
        }
        if let value = try? await p { printerStatus = value }
    }

    private func testConnection() async {
        testing = true
        testResult = nil
        defer { testing = false }
        // Let a URL/token edit that is being committed (focus just left the field) reach the server first,
        // so the test describes the configuration detection actually uses.
        try? await Task.sleep(for: .milliseconds(200))
        await store.flush()
        while store.isSaving { try? await Task.sleep(for: .milliseconds(100)) }
        let url = store.string("obico_ml_url")
        guard !url.isEmpty else { return }
        do {
            let result: SettingsObicoTestResult = try await session.client.send(
                .post, "obico/test-connection", body: SettingsObicoTestRequest(url: url, token: nil))
            testResult = SettingsObicoTestText.describe(result)
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }
}

/// Wording for a test-connection result.
enum SettingsObicoTestText {
    static func describe(_ result: SettingsObicoTestResult) -> (success: Bool, message: String) {
        if result.ok == true {
            return result.authOk == nil
                ? (true, "The ML server is reachable and healthy, but the token couldn't be verified.")
                : (true, "The ML server is reachable, healthy and accepts the token.")
        }
        if let error = result.error, !error.isEmpty { return (false, error) }
        let code = result.statusCode.map(String.init) ?? "?"
        let body = (result.body ?? "").isEmpty ? "The server didn't respond as expected." : result.body!
        return (false, "HTTP \(code) — \(body)")
    }
}

private struct SettingsObicoVerdictBadge: View {
    let verdict: String?
    var body: some View {
        switch verdict {
        case "failure": StatusBadge(text: "Failure", color: .red)
        case "warning": StatusBadge(text: "Warning", color: .orange)
        case "safe": StatusBadge(text: "Looks Good", color: .green)
        case "error": StatusBadge(text: "Not Checked", color: .orange)
        case "unknown", nil: StatusBadge(text: "Waiting", color: .secondary)
        default: StatusBadge(text: verdict?.capitalized ?? "—", color: .secondary)
        }
    }
}
