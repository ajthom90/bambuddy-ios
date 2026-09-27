import SwiftUI

// Printer sub-tools. The screens themselves live in `Features/Printers/Extras/`:
// PrinterFilesView, SkipObjectsView, ConfigureSlotView, and the tools listed below.

struct PrinterObicoStatus: Codable, Sendable, Hashable {
    struct Entry: Codable, Sendable, Hashable {
        var `class`: String?
        var frameCount: Int?
        var score: Double?
        var error: String?
    }
    var enabled: Bool
    var monitoredPrinters: [Int]?
    var perPrinter: [String: Entry]?
    var lastError: String?

    func monitors(_ printerId: Int) -> Bool { enabled && (monitoredPrinters == nil || monitoredPrinters!.contains(printerId)) }
}

struct PrinterCurrentUser: Codable, Sendable, Hashable {
    var userId: Int?
    var username: String?
}

/// Menu of per-printer tools: K-profiles, history charts, diagnostics, power, calibration, firmware…
struct PrinterMoreView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    let printerId: Int

    @State private var firmware: PrinterFirmwareInfo?
    @State private var obico: PrinterObicoStatus?
    @State private var printUser: PrinterCurrentUser?
    @State private var dryings: [PrinterScheduledDrying] = []
    @State private var plugName: String?

    private var status: PrinterStatus? { store.statuses[printerId] }
    private var printer: Printer? { store.printer(printerId) }

    var body: some View {
        List {
            if status?.isActiveJob == true, printUser?.username != nil || obico?.monitors(printerId) == true {
                Section("Current Print") {
                    if let name = printUser?.username { InfoRow("Started By", name, systemImage: "person") }
                    if let obico, obico.monitors(printerId) { obicoRow(obico) }
                }
            }

            Section("Filament") {
                if session.can("kprofiles:read") {
                    NavigationLink { PrinterKProfilesView(printerId: printerId) } label: {
                        Label("K-Profiles", systemImage: "gauge.with.dots.needle.33percent")
                    }
                }
                if session.can("ams_history:read") {
                    ForEach(status?.ams ?? []) { unit in
                        NavigationLink { PrinterAMSHistoryView(printerId: printerId, amsId: unit.id) } label: {
                            LabeledContent {
                                if let h = unit.humidity { Text("\(h)%").monospacedDigit() }
                            } label: {
                                Label("\(unit.label) Humidity & Temperature", systemImage: "humidity")
                            }
                        }
                    }
                }
                if status?.supportsDrying == true || !dryings.isEmpty {
                    NavigationLink { PrinterScheduledDryingsView(printerId: printerId) } label: {
                        LabeledContent {
                            if !dryings.isEmpty { Text("\(dryings.count)") }
                        } label: {
                            Label("Scheduled Drying", systemImage: "sun.max")
                        }
                    }
                }
            }

            Section("Monitoring") {
                if session.can("printer_sensor_history:read") {
                    NavigationLink { PrinterSensorHistoryView(printerId: printerId) } label: {
                        Label("Temperature History", systemImage: "chart.xyaxis.line")
                    }
                }
                if session.can("camera:view") {
                    NavigationLink { PrinterPlateDetectionView(printerId: printerId) } label: {
                        LabeledContent {
                            Text(printer?.plateDetectionEnabled == true ? "On" : "Off")
                        } label: {
                            Label("Plate Detection", systemImage: "camera.viewfinder")
                        }
                    }
                }
                if session.can("smart_plugs:read") {
                    NavigationLink { PrinterPowerView(printerId: printerId) } label: {
                        LabeledContent {
                            if let plugName { Text(plugName).lineLimit(1) }
                        } label: {
                            Label("Power & Sensors", systemImage: "powerplug")
                        }
                    }
                }
            }

            Section("Maintenance") {
                if session.can("printers:control") {
                    NavigationLink { PrinterCalibrationView(printerId: printerId) } label: {
                        Label("Calibration", systemImage: "scope")
                    }
                }
                if session.can("firmware:read") {
                    NavigationLink { PrinterFirmwareView(printerId: printerId) } label: {
                        LabeledContent {
                            HStack(spacing: 6) {
                                Text(firmware?.currentVersion ?? status?.firmwareVersion ?? "")
                                    .monospacedDigit()
                                if firmware?.updateAvailable == true { StatusBadge(text: "Update", color: .orange) }
                            }
                        } label: {
                            Label("Firmware", systemImage: "cpu")
                        }
                    }
                }
            }

            Section("Diagnostics") {
                NavigationLink { PrinterInfoView(printerId: printerId) } label: {
                    Label("Printer Information", systemImage: "info.circle")
                }
                NavigationLink { PrinterConnectionDiagnosticView(printerId: printerId) } label: {
                    Label("Connection Diagnostic", systemImage: "stethoscope")
                }
                if session.can("camera:view") {
                    NavigationLink { PrinterCameraDiagnosticView(printerId: printerId) } label: {
                        Label("Camera Diagnostic", systemImage: "video.badge.checkmark")
                    }
                }
                NavigationLink { PrinterLoggingView(printerId: printerId) } label: {
                    Label("MQTT Log", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle("More Tools")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func obicoRow(_ obico: PrinterObicoStatus) -> some View {
        let entry = obico.perPrinter?[String(printerId)]
        let (label, color, icon): (String, Color, String) = switch entry?.class {
        case "failure": ("Failure detected", .red, "exclamationmark.octagon.fill")
        case "warning": ("Possible issue", .orange, "exclamationmark.triangle.fill")
        case "safe": ("Looks good", .green, "checkmark.shield.fill")
        case "error": ("Detection error", .orange, "eye.slash")
        case nil: ("Idle", .secondary, "eye")
        default: ("Unknown", .secondary, "questionmark.circle")
        }
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                Label(label, systemImage: icon).foregroundStyle(color)
            } label: {
                Label("AI Failure Detection", systemImage: "sparkles")
            }
            if let score = entry?.score, entry?.class != "error" {
                Text("Score \(String(format: "%.3f", score)) · \(entry?.frameCount ?? 0) frames").font(.caption).foregroundStyle(.secondary)
            }
            if let err = entry?.error ?? obico.lastError { Text(err).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func load() async {
        let client = session.client
        let printerId = printerId
        async let fw: PrinterFirmwareInfo? = session.can("firmware:read") ? try? client.get("firmware/updates/\(printerId)") : nil
        async let ob: PrinterObicoStatus? = try? client.get("obico/printer-status")
        async let user: PrinterCurrentUser? = try? client.get("printers/\(printerId)/current-print-user")
        async let dry: [PrinterScheduledDrying]? = try? client.get("scheduled-dryings", query: ["printer_id": .int(printerId)])
        async let plug: PrinterSmartPlug?? = session.can("smart_plugs:read") ? try? client.get("smart-plugs/by-printer/\(printerId)") : nil
        let (f, o, u, d, p) = await (fw, ob, user, dry, plug)
        firmware = f
        obico = o
        printUser = u
        dryings = d ?? []
        plugName = p??.name
    }
}
