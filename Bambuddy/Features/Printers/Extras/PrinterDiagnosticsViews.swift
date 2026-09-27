import SwiftUI

// MARK: Models

struct PrinterDiagnosticReport: Codable, Sendable, Hashable {
    var printerId: Int?
    var ipAddress: String
    var overall: String
    var checks: [PrinterDiagnosticCheck]
}

struct PrinterDiagnosticCheck: Codable, Sendable, Hashable {
    var id: String
    var status: String
    var params: [String: JSONValue]?

    /// Params are free-form; decode them without key conversion.
    enum CodingKeys: String, CodingKey { case id, status, params }
    init(id: String, status: String, params: [String: JSONValue]? = nil) {
        self.id = id; self.status = status; self.params = params
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decode(String.self, forKey: .status)
        params = (try? c.decodeIfPresent(JSONValue.self, forKey: .params))?.objectValue
    }

    func param(_ key: String) -> String? { params?[key]?.stringValue }
    var reason: String? { param("reason") }
}

struct PrinterCameraDiagnosis: Codable, Sendable, Hashable {
    var printerId: Int?
    var protocol_: String?
    var port: Int?
    var profile: String?
    var overallStatus: String
    var summaryCode: String?
    var stages: [PrinterCameraStage]

    enum CodingKeys: String, CodingKey {
        case printerId, protocol_ = "protocol", port, profile, overallStatus, summaryCode, stages
    }
}

struct PrinterCameraStage: Codable, Sendable, Hashable {
    var name: String
    var status: String
    var durationMs: Int?
    var code: String?
}

struct PrinterCameraStatus: Codable, Sendable, Hashable {
    var active: Bool?
    var hasFrames: Bool?
    var secondsSinceFrame: Double?
    var streamUptime: Double?
    var stalled: Bool?
}

struct PrinterCameraTest: Codable, Sendable, Hashable {
    var success: Bool
    var message: String?
    var error: String?
}

struct PrinterRuntimeDebug: Codable, Sendable, Hashable {
    struct MQTTState: Codable, Sendable, Hashable {
        var connected: Bool?
        var state: String?
        var progress: Double?
        var gcodeFile: String?
    }
    var printerName: String?
    var runtimeSeconds: Int?
    var runtimeHours: Double?
    var printHoursOffset: Double?
    var totalHours: Double?
    var lastRuntimeUpdate: String?
    var mqttState: MQTTState?
    var isActive: Bool?
}

/// Human-readable descriptions for connection-diagnostic checks.
enum PrinterDiagnosticText {
    static func title(_ c: PrinterDiagnosticCheck) -> String {
        switch c.id {
        case "port_mqtt": return "Control connection (MQTT, port 8883)"
        case "port_ftps": return "File transfer (FTPS, port 990)"
        case "port_rtsps": return "Camera (\(c.param("protocol") ?? "RTSPS") port \(c.param("port") ?? "322"))"
        case "network_mode": return "Docker networking"
        case "subnet": return "Same network subnet"
        case "external_storage": return "Store sent files on external storage"
        case "mqtt_auth": return "Access code & serial number"
        case "developer_mode": return "LAN developer mode"
        case "printer_publishing": return "Printer reports status"
        default: return c.id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func detail(_ c: PrinterDiagnosticCheck) -> String {
        let s = c.status, r = c.reason
        switch (c.id, s) {
        case ("port_mqtt", "pass"): return "The printer accepts control connections."
        case ("port_mqtt", _): return "Port 8883 can't be reached. Check that the printer is on, its IP address is correct, and no firewall blocks the port."
        case ("port_ftps", "pass"): return "File transfers to the printer will work."
        case ("port_ftps", _) where r == "no_tls": return "The file service answers but never completes its secure handshake, so covers, timelapses and print files can't be fetched. Restarting the printer usually helps."
        case ("port_ftps", _): return "Port 990 can't be reached. Status monitoring may work, but sending prints will fail."
        case ("port_rtsps", "pass"): return "The camera stream should work."
        case ("port_rtsps", _): return "The camera port can't be reached, so live video won't work. Printing is unaffected."
        case ("network_mode", "pass"): return "The server uses host networking."
        case ("network_mode", "warn"): return "The server runs with Docker bridge networking. Discovery and virtual printers need host networking."
        case ("network_mode", _): return "The server isn't running in Docker."
        case ("subnet", "pass"): return "The printer and the server share a subnet."
        case ("subnet", "warn"): return "The printer (\(c.param("printer_ip") ?? "?")) and server (\(c.param("host_ip") ?? "?")) are on different subnets; routing between them must be set up."
        case ("subnet", _): return "The subnet couldn't be determined."
        case ("external_storage", "pass"): return "Sent files are kept on the SD card, so archives get thumbnails and metadata."
        case ("external_storage", "fail") where r == "no_media": return "The option is on, but no SD card or USB stick is inserted."
        case ("external_storage", "fail"): return "The option is off on the printer. Turn on “Store sent files on external storage” so prints can be archived."
        case ("external_storage", "warn") where r == "internal_storage": return "The last print went to internal storage, which the server can't read."
        case ("external_storage", "warn") where r == "internal_history": return "The last print was started from a file already on the printer."
        case ("external_storage", "warn") where r == "ftps_cooloff": return "Temporarily not checked while the file service recovers."
        case ("external_storage", _) where r == "unsupported_model": return "This model offers no way to change the option; nothing to do."
        case ("external_storage", _): return "Needs a live connection to check."
        case ("mqtt_auth", "pass"): return "The printer accepted the credentials."
        case ("mqtt_auth", "fail") where r == "auth_rejected": return "The printer rejected the credentials. The access code changes whenever LAN mode or developer mode is toggled — update it in the printer settings."
        case ("mqtt_auth", "fail"): return "The printer is reachable but not connected. The access code or serial number is probably wrong."
        case ("mqtt_auth", _): return "Skipped because the printer couldn't be reached."
        case ("developer_mode", "pass"): return "Developer mode is on."
        case ("developer_mode", "fail"): return "Developer mode is off. Enable it in the printer's LAN settings, otherwise prints won't start."
        case ("developer_mode", _): return "Needs a live connection to check."
        case ("printer_publishing", "pass"): return "Status reports are arriving."
        case ("printer_publishing", "fail"): return "Connected, but no status reports arrived. This usually means the serial number is wrong or mis-cased."
        case ("printer_publishing", _): return "Needs a live connection to check."
        default: return s.capitalized
        }
    }

    static func overall(_ o: String) -> (String, String, Color) {
        switch o {
        case "ok": return ("No problems found", "checkmark.seal.fill", .green)
        case "warnings": return ("Works, with warnings", "exclamationmark.triangle.fill", .orange)
        default: return ("Problems found", "xmark.octagon.fill", .red)
        }
    }

    static func icon(_ status: String) -> (String, Color) {
        switch status {
        case "pass", "ok": return ("checkmark.circle.fill", .green)
        case "warn": return ("exclamationmark.triangle.fill", .orange)
        case "fail", "failed": return ("xmark.circle.fill", .red)
        default: return ("minus.circle", .secondary)
        }
    }

    static func cameraStage(_ name: String) -> String {
        switch name {
        case "tcp_reachable": return "Camera port reachable"
        case "first_frame": return "First frame received"
        case "live_stream_active": return "Live stream running"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func cameraSummary(_ code: String?) -> String {
        switch code {
        case "all_ok": return "The camera works."
        case "live_stream_active_healthy": return "A live stream is running and delivering frames."
        case "printer_unreachable": return "The printer couldn't be reached on the network."
        case "camera_port_closed": return "The camera port is closed. On some models LAN liveview must be enabled on the printer."
        case "no_frame": return "Connected, but the camera sent no image. Try restarting the printer."
        default: return "The camera check failed for an unknown reason."
        }
    }
}

// MARK: Printer info

struct PrinterInfoView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    let printerId: Int
    @State private var runtime: PrinterRuntimeDebug?
    @State private var printUser: JSONValue?

    var body: some View {
        let printer = store.printer(printerId)
        let status = store.statuses[printerId]
        List {
            Section {
                InfoRow("Name", printer?.name)
                InfoRow("Model", printer?.model)
                LabeledContent("Status") {
                    StatusBadge(text: status?.connected == true ? "Online" : "Offline", color: status?.connected == true ? .green : .secondary)
                }
                InfoRow("State", status?.stateLabel)
                if let user = printUser?["username"]?.stringValue, status?.isActiveJob == true {
                    InfoRow("Started By", user)
                }
            }
            Section("Network") {
                copyRow("IP Address", printer?.ipAddress)
                copyRow("Serial Number", printer?.serialNumber)
                if status?.wiredNetwork == true {
                    InfoRow("Connection", "Ethernet")
                } else if let wifi = status?.wifiSignal {
                    InfoRow("Wi-Fi", "\(wifiQuality(wifi)) (\(wifi) dBm)")
                }
            }
            Section("Hardware") {
                InfoRow("Firmware", status?.firmwareVersion)
                if let dev = status?.developerMode { InfoRow("Developer Mode", dev ? "On" : "Off") }
                InfoRow("Nozzles", printer?.nozzleCount.map(String.init))
                ForEach(Array((status?.nozzles ?? []).enumerated()), id: \.offset) { i, n in
                    if let d = n.nozzleDiameter, !d.isEmpty {
                        InfoRow((status?.nozzles?.count ?? 0) > 1 ? "Nozzle \(i + 1)" : "Nozzle", "\(d) mm \((n.nozzleType ?? "").replacingOccurrences(of: "_", with: " "))")
                    }
                }
                InfoRow("SD Card", status?.sdcard == true ? "Inserted" : "Not inserted")
            }
            Section("Bambuddy") {
                InfoRow("Location", printer?.location)
                InfoRow("Auto-Archive", printer?.autoArchive == true ? "On" : "Off")
                if let hours = runtime?.totalHours, hours > 0 { InfoRow("Total Print Time", Fmt.duration(seconds: hours * 3600)) }
                if let offset = runtime?.printHoursOffset, offset != 0 { InfoRow("Hours Offset", Fmt.number(offset)) }
                InfoRow("Added", Fmt.date(printer?.createdAt, style: .dateTime.month().day().year()))
            }
        }
        .navigationTitle("Printer Info")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            runtime = try? await session.client.get("printers/\(printerId)/runtime-debug")
            printUser = try? await session.client.get("printers/\(printerId)/current-print-user")
        }
    }

    private func copyRow(_ label: String, _ value: String?) -> some View {
        InfoRow(label, value)
            .contextMenu {
                if let value { Button { UIPasteboard.general.string = value } label: { Label("Copy", systemImage: "doc.on.doc") } }
            }
    }

    private func wifiQuality(_ dbm: Int) -> String {
        switch dbm {
        case (-50)...: return "Excellent"
        case (-60)...: return "Good"
        case (-70)...: return "Fair"
        case (-80)...: return "Weak"
        default: return "Very weak"
        }
    }
}

// MARK: Connection diagnostic

struct PrinterConnectionDiagnosticView: View {
    @Environment(AppSession.self) private var session
    let printerId: Int
    @State private var loader = Loader<PrinterDiagnosticReport>()
    @State private var started = Date()

    var body: some View {
        List {
            if loader.isLoading {
                Section {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading) {
                                Text("Running diagnostic… \(Int(context.date.timeIntervalSince(started)))s")
                                Text("Waiting for the printer to report its status can take up to 10 seconds.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if let error = loader.error, loader.value == nil {
                Section { Label("The diagnostic couldn't run: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            if let report = loader.value {
                let o = PrinterDiagnosticText.overall(report.overall)
                Section {
                    Label(o.0, systemImage: o.1).foregroundStyle(o.2).font(.headline)
                    InfoRow("IP Address", report.ipAddress)
                }
                Section("Checks") {
                    ForEach(report.checks, id: \.id) { check in
                        let icon = PrinterDiagnosticText.icon(check.status)
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon.0).foregroundStyle(icon.1).font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(PrinterDiagnosticText.title(check)).font(.subheadline.weight(.semibold))
                                Text(PrinterDiagnosticText.detail(check)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .opacity(check.status == "skip" ? 0.55 : 1)
                    }
                }
            }
        }
        .navigationTitle("Connection Diagnostic")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Run Again") { Task { await run() } }.disabled(loader.isLoading)
            }
        }
        .task { await run() }
    }

    private func run() async {
        started = Date()
        await loader.load {
            var req = session.client.makeRequest(.get, "printers/\(printerId)/diagnostic")
            req.timeoutInterval = 60
            return try await session.client.perform(req)
        }
    }
}

// MARK: Camera diagnostic

struct PrinterCameraDiagnosticView: View {
    @Environment(AppSession.self) private var session
    let printerId: Int
    @State private var loader = Loader<PrinterCameraDiagnosis>()
    @State private var status: PrinterCameraStatus?
    @State private var test: PrinterCameraTest?
    @State private var testing = false

    var body: some View {
        List {
            if let status {
                Section("Stream") {
                    InfoRow("Live Stream", status.active == true ? (status.stalled == true ? "Stalled" : "Active") : "Not running")
                    if let s = status.secondsSinceFrame { InfoRow("Last Frame", "\(Fmt.number(s)) s ago") }
                    if let up = status.streamUptime { InfoRow("Uptime", Fmt.duration(seconds: up)) }
                }
            }
            Section {
                if loader.isLoading {
                    HStack { ProgressView(); Text("Checking the camera…") }
                } else if let error = loader.error, loader.value == nil {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if let d = loader.value {
                    Label(PrinterDiagnosticText.cameraSummary(d.summaryCode), systemImage: d.overallStatus == "ok" ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(d.overallStatus == "ok" ? .green : .red)
                    ForEach(d.stages, id: \.name) { stage in
                        let icon = PrinterDiagnosticText.icon(stage.status)
                        HStack {
                            Image(systemName: icon.0).foregroundStyle(icon.1)
                            VStack(alignment: .leading) {
                                Text(PrinterDiagnosticText.cameraStage(stage.name))
                                if let code = stage.code { Text(code).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let ms = stage.durationMs { Text("\(ms) ms").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        }
                    }
                    InfoRow("Protocol", d.protocol_?.uppercased())
                    InfoRow("Port", d.port.map(String.init))
                    InfoRow("Profile", d.profile)
                }
            } header: {
                Text("Diagnosis")
            }
            Section {
                Button {
                    Task {
                        testing = true
                        test = try? await session.client.get("printers/\(printerId)/camera/test")
                        testing = false
                    }
                } label: {
                    HStack { Text("Capture Test Frame"); Spacer(); if testing { ProgressView() } }
                }
                .disabled(testing)
                if let test {
                    Label(test.success ? (test.message ?? "Camera connection successful") : (test.error ?? "Capture failed"),
                          systemImage: test.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(test.success ? .green : .red)
                }
            }
        }
        .navigationTitle("Camera Diagnostic")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Run Again") { Task { await run() } }.disabled(loader.isLoading)
            }
        }
        .task { await run() }
    }

    private func run() async {
        status = try? await session.client.get("printers/\(printerId)/camera/status")
        await loader.load {
            var req = session.client.makeRequest(.post, "printers/\(printerId)/camera/diagnose")
            req.timeoutInterval = 60
            return try await session.client.perform(req)
        }
    }
}
