import SwiftUI
import UIKit

/// Settings → Network & Integrations: external URL, FTP retries, Home Assistant,
/// MQTT publishing, Prometheus metrics and the webhook API.
struct SettingsNetworkView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store

    @State private var mqttStatus: SettingsMQTTStatus?
    @State private var haTest: (success: Bool, message: String)?
    @State private var isTestingHA = false
    @State private var runner = ActionRunner()

    var body: some View {
        SettingsForm("Network & Integrations") {
            externalURLSection
            ftpSection
            homeAssistantSection
            mqttSection
            prometheusSection
            webhookSections
        }
        .actionAlerts(runner)
        .task(id: store.saveCount) { await pollMQTTStatus() }
    }

    // MARK: External URL

    private var externalURLSection: some View {
        Section {
            SettingsTextField("Bambuddy URL", key: "external_url", prompt: "http://192.168.1.100:8000", keyboard: .URL)
        } header: {
            Text("External URL")
        } footer: {
            Text("The address other devices use to reach this server. It's used for links in notifications and for printers and integrations that call back into Bambuddy.")
        }
    }

    // MARK: FTP

    @ViewBuilder
    private var ftpSection: some View {
        Section {
            SettingsToggle("Retry Failed Transfers", key: "ftp_retry_enabled",
                           help: "Automatically retry uploads and downloads to the printer when they fail.", default: true)
            if store.bool("ftp_retry_enabled", default: true) {
                SettingsPicker("Attempts", key: "ftp_retry_count",
                               options: (1...10).map { (JSONValue.number(Double($0)), $0 == 1 ? "1 time" : "\($0) times") })
                SettingsPicker("Wait Between Attempts", key: "ftp_retry_delay",
                               options: [1, 2, 3, 5, 10, 15, 20, 30].map { (JSONValue.number(Double($0)), "\($0) s") })
            }
            SettingsPicker("Connection Timeout", key: "ftp_timeout",
                           options: [10, 15, 20, 30, 45, 60, 90, 120, 180, 300].map { (JSONValue.number(Double($0)), "\($0) s") })
        } header: {
            Text("File Transfers (FTP)")
        } footer: {
            Text("Printers on weak Wi-Fi often need more attempts or a longer timeout.")
        }
    }

    // MARK: Home Assistant

    private var haEnvManaged: Bool { store.bool("ha_env_managed") }
    private var haURLFromEnv: Bool { store.bool("ha_url_from_env") }
    private var haTokenFromEnv: Bool { store.bool("ha_token_from_env") }

    @ViewBuilder
    private var homeAssistantSection: some View {
        Section {
            SettingsToggle("Home Assistant", key: "ha_enabled",
                           help: haEnvManaged ? "Turned on by the server's HA_URL and HA_TOKEN environment variables." : "Control Home Assistant switches as smart plugs and read its sensors.")
                .disabled(haEnvManaged)
            if store.bool("ha_enabled") {
                SettingsTextField("URL", key: "ha_url", prompt: "http://homeassistant.local:8123",
                                  help: haURLFromEnv ? "Set by the HA_URL environment variable on the server; change it there." : nil,
                                  keyboard: .URL, readOnly: haURLFromEnv)
                SettingsTextField("Long-Lived Access Token", key: "ha_token", prompt: "Paste the token",
                                  help: haTokenFromEnv
                                      ? "Set by the HA_TOKEN environment variable on the server; change it there."
                                      : "Create one in Home Assistant under your profile → Security → Long-lived access tokens.",
                                  secure: true, readOnly: haTokenFromEnv)
                if session.can("smart_plugs:control") {
                    Button {
                        Task { await testHomeAssistant() }
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "wifi")
                            if isTestingHA { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isTestingHA || store.string("ha_url").isEmpty || store.string("ha_token").isEmpty)
                }
                if let haTest {
                    SettingsTestResultLabel(success: haTest.success, message: haTest.message)
                }
            }
        } header: {
            Text("Home Assistant")
        } footer: {
            if haEnvManaged {
                Label("Managed by environment variables on the server.", systemImage: "lock.fill")
            } else {
                Text("Once connected, add Home Assistant entities under Smart Plugs and Sensors.")
            }
        }
    }

    private func testHomeAssistant() async {
        isTestingHA = true
        defer { isTestingHA = false }
        haTest = nil
        let body = ["url": store.string("ha_url"), "token": store.string("ha_token")]
        do {
            let result: SettingsHATestResult = try await session.client.send(.post, "smart-plugs/ha/test-connection", body: body)
            haTest = result.success
                ? (true, result.message ?? "Connected to Home Assistant.")
                : (false, result.error ?? "Home Assistant didn't accept the connection.")
        } catch {
            haTest = (false, error.localizedDescription)
        }
    }

    // MARK: MQTT

    @ViewBuilder
    private var mqttSection: some View {
        Section {
            SettingsToggle("Publish to MQTT", key: "mqtt_enabled",
                           help: "Send printer status and events to an MQTT broker, e.g. for Home Assistant or Node-RED.")
            if store.bool("mqtt_enabled") {
                SettingsTextField("Broker", key: "mqtt_broker", prompt: "mqtt.example.com or 192.168.1.10", keyboard: .URL)
                SettingsNumberField("Port", key: "mqtt_port", range: 1...65535)
                Toggle(isOn: Binding(get: { store.bool("mqtt_use_tls") }, set: setTLS)) {
                    SettingsLabel("Use TLS", help: "Switching this also moves the default port between 1883 and 8883.")
                }
                .disabled(!store.canEdit)
                SettingsTextField("Username", key: "mqtt_username", prompt: "Leave empty for anonymous")
                SettingsTextField("Password", key: "mqtt_password", prompt: "Leave empty for anonymous", secure: true)
                SettingsTextField("Topic Prefix", key: "mqtt_topic_prefix", prompt: "bambuddy",
                                  help: "Messages are published under \(topicPrefix)/…, for example \(topicPrefix)/printers/<serial>/status.")
            }
            if let mqttStatus, mqttStatus.enabled == true || store.bool("mqtt_enabled") {
                LabeledContent("Status") {
                    if mqttStatus.connected == true {
                        Label("Connected to \(mqttStatus.endpoint)", systemImage: "circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not connected", systemImage: "circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .labelStyle(SettingsMQTTDotLabelStyle())
            }
        } header: {
            Text("MQTT Publishing")
        }
    }

    private var topicPrefix: String {
        let prefix = store.string("mqtt_topic_prefix")
        return prefix.isEmpty ? "bambuddy" : prefix
    }

    private func setTLS(_ useTLS: Bool) {
        var changes: [String: JSONValue] = ["mqtt_use_tls": .bool(useTLS)]
        let port = store.int("mqtt_port") ?? 1883
        if useTLS && port == 1883 { changes["mqtt_port"] = .number(8883) }
        if !useTLS && port == 8883 { changes["mqtt_port"] = .number(1883) }
        Task { await store.save(changes) }
    }

    /// Polls the relay's connection state while the page is visible.
    private func pollMQTTStatus() async {
        while !Task.isCancelled {
            if let status: SettingsMQTTStatus = try? await session.client.get("settings/mqtt/status") {
                mqttStatus = status
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: Prometheus

    private var metricsURL: String {
        (session.serverURL.map { $0.appending(path: "api/v1/metrics").absoluteString }) ?? "/api/v1/metrics"
    }

    @ViewBuilder
    private var prometheusSection: some View {
        Section {
            SettingsToggle("Metrics Endpoint", key: "prometheus_enabled",
                           help: "Expose printer and print statistics for Prometheus to scrape.")
            if store.bool("prometheus_enabled") {
                SettingsTextField("Bearer Token", key: "prometheus_token", prompt: "Leave empty for no authentication",
                                  help: "When set, scrapers must send an Authorization: Bearer <token> header.", secure: true)
                copyRow("Scrape URL", value: metricsURL)
                DisclosureGroup("Available Metrics") {
                    ForEach(Self.metrics, id: \.0) { metric in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.0).font(.caption.monospaced())
                            Text(metric.1).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("…and more, such as layers, fan speeds and chamber temperature.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Prometheus")
        }
    }

    private static let metrics: [(String, String)] = [
        ("bambuddy_printer_connected", "Whether each printer is connected"),
        ("bambuddy_printer_state", "Current printer state"),
        ("bambuddy_print_progress", "Progress of the running print"),
        ("bambuddy_bed_temp_celsius", "Bed temperature"),
        ("bambuddy_nozzle_temp_celsius", "Nozzle temperature"),
        ("bambuddy_prints_total", "Completed prints by result"),
    ]

    // MARK: Webhooks

    private var apiBase: String {
        (session.serverURL.map { $0.appending(path: "api/v1").absoluteString }) ?? "/api/v1"
    }

    @ViewBuilder
    private var webhookSections: some View {
        Section {
            ForEach(SettingsNetworkWebhook.all) { hook in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        StatusBadge(text: hook.method, color: hook.method == "GET" ? .green : .blue)
                        Text(hook.title).font(.subheadline.weight(.medium))
                        Spacer()
                        Button("Copy URL", systemImage: "doc.on.doc") { copy(apiBase + hook.path, label: "URL") }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    Text(apiBase + hook.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(hook.detail).font(.caption).foregroundStyle(.secondary)
                    Text("API key permission: \(hook.permission)").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Copy URL", systemImage: "doc.on.doc") { copy(apiBase + hook.path, label: "URL") }
                    Button("Copy curl Command", systemImage: "terminal") { copy(hook.curl(base: apiBase), label: "Command") }
                }
            }
        } header: {
            Text("Webhooks")
        } footer: {
            Text("Automation tools can call these endpoints with an API key (create one under API Keys), sent as an X-API-Key: <key> header or as Authorization: Bearer <key>. Replace {printer_id} with the printer's ID. Long-press an endpoint to copy a ready-made curl command.")
        }
    }

    private func copy(_ text: String, label: String) {
        UIPasteboard.general.string = text
        runner.successMessage = "\(label) copied"
    }

    private func copyRow(_ title: String, value: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(value)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                Button("Copy", systemImage: "doc.on.doc") { copy(value, label: "URL") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        } label: {
            Text(title)
        }
    }
}

// MARK: - Models

/// MQTT relay state (`GET /settings/mqtt/status`).
struct SettingsMQTTStatus: Codable, Sendable, Equatable {
    var enabled: Bool?
    var connected: Bool?
    var broker: String?
    var port: Int?
    var topicPrefix: String?

    var endpoint: String {
        let host = broker ?? ""
        guard let port, port > 0 else { return host }
        return "\(host):\(port)"
    }
}

/// One of the server's webhook endpoints (`/api/v1/webhook/*`).
struct SettingsNetworkWebhook: Identifiable, Sendable {
    var method: String
    var path: String
    var title: String
    var detail: String
    var permission: String
    var sampleBody: String?
    var id: String { method + path }

    static let all: [SettingsNetworkWebhook] = [
        .init(method: "POST", path: "/webhook/queue/add", title: "Add to Queue",
              detail: "Queues an archived print on a printer. JSON body: archive_id and printer_id; optional project_id, scheduled_time (ISO 8601), require_previous_success, auto_off_after.",
              permission: "Queue", sampleBody: #"{"archive_id": 1, "printer_id": 1}"#),
        .init(method: "POST", path: "/webhook/printer/{printer_id}/start", title: "Start Next Job",
              detail: "Releases the next queued job that's waiting for a manual start on the printer.",
              permission: "Control printer"),
        .init(method: "POST", path: "/webhook/printer/{printer_id}/stop", title: "Stop Print",
              detail: "Stops the printer's current print.", permission: "Control printer"),
        .init(method: "POST", path: "/webhook/printer/{printer_id}/cancel", title: "Cancel Print",
              detail: "Cancels the printer's current print.", permission: "Control printer"),
        .init(method: "GET", path: "/webhook/printer/{printer_id}/status", title: "Printer Status",
              detail: "Returns connection state, print state, current file, progress and remaining time.",
              permission: "Read status"),
        .init(method: "GET", path: "/webhook/queue", title: "Queue Status",
              detail: "Returns pending and printing jobs per printer. Add ?printer_id= to limit it to one printer.",
              permission: "Read status"),
    ]

    func curl(base: String) -> String {
        var parts = ["curl"]
        if method != "GET" { parts.append("-X \(method)") }
        parts.append("-H 'X-API-Key: YOUR_API_KEY'")
        if let sampleBody {
            parts.append("-H 'Content-Type: application/json'")
            parts.append("-d '\(sampleBody)'")
        }
        parts.append("'\(base + path)'")
        return parts.joined(separator: " ")
    }
}

/// Shows the label's icon as a small status dot.
private struct SettingsMQTTDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 8))
            configuration.title.foregroundStyle(.primary)
        }
    }
}
