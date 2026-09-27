import SwiftUI

// MARK: Models

/// The subset of a smart plug record this screen needs (the full record has many integration fields).
struct PrinterSmartPlug: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var plugType: String?
    var ipAddress: String?
    var haEntityId: String?
    var printerId: Int?
    var controlsPrinterPower: Bool?
    var enabled: Bool?
    var autoOn: Bool?
    var autoOff: Bool?
    var autoOffPersistent: Bool?
    var offDelayMode: String?
    var offDelayMinutes: Int?
    var offTempThreshold: Int?
    var autoOffExecuted: Bool?
    var powerAlertEnabled: Bool?
    var powerAlertHigh: Double?
    var powerAlertLow: Double?
    var scheduleEnabled: Bool?
    var scheduleOnTime: String?
    var scheduleOffTime: String?
    var showOnPrinterCard: Bool?
    var lastState: String?
    var lastChecked: String?

    var isMonitorOnly: Bool { plugType == "mqtt" }
    var isScript: Bool { (haEntityId ?? "").hasPrefix("script.") }
    var typeLabel: String {
        switch plugType {
        case "tasmota": return "Tasmota"
        case "homeassistant": return "Home Assistant"
        case "mqtt": return "MQTT"
        case "rest": return "REST"
        default: return plugType?.capitalized ?? "Plug"
        }
    }
}

struct PrinterPlugStatus: Codable, Sendable, Hashable {
    var state: String?
    var reachable: Bool?
    var deviceName: String?
    var energy: PrinterPlugEnergy?

    var isOn: Bool { (state ?? "").uppercased() == "ON" }
}

struct PrinterPlugEnergy: Codable, Sendable, Hashable {
    var power: Double?
    var voltage: Double?
    var current: Double?
    var today: Double?
    var yesterday: Double?
    var total: Double?
    var factor: Double?
    var apparentPower: Double?
    var reactivePower: Double?
}

struct PrinterPlugControl: Codable, Sendable { var action: String }

struct PrinterHASensorReading: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var entityId: String
    var kind: String
    var deviceClass: String?
    var unit: String?
    var state: String?
    var value: Double?
    var alerting: Bool?
    var blockPrint: Bool?
    var reachable: Bool?
    var lastChanged: String?

    var displayValue: String {
        guard reachable != false else { return "Unavailable" }
        if kind == "numeric" {
            guard let value else { return state ?? "Unavailable" }
            return [Fmt.number(value), unit].compactMap { $0 }.joined(separator: " ")
        }
        guard let state else { return "Unavailable" }
        let on = state.lowercased() == "on"
        switch deviceClass {
        case "door", "window", "opening", "garage_door": return on ? "Open" : "Closed"
        case "lock": return on ? "Unlocked" : "Locked"
        case "motion", "occupancy", "presence": return on ? "Detected" : "Clear"
        case "moisture": return on ? "Wet" : "Dry"
        case "smoke", "gas", "carbon_monoxide": return on ? "Detected" : "Clear"
        case "problem": return on ? "Problem" : "OK"
        case "power", "plug", "running": return on ? "On" : "Off"
        default: return state.capitalized
        }
    }

    var systemImage: String {
        switch deviceClass {
        case "temperature": return "thermometer.medium"
        case "humidity", "moisture": return "humidity"
        case "door", "window", "opening", "garage_door": return "door.left.hand.open"
        case "lock": return "lock"
        case "motion", "occupancy", "presence": return "figure.walk"
        case "smoke", "gas", "carbon_monoxide": return "smoke"
        case "power", "energy": return "bolt"
        case "problem": return "exclamationmark.triangle"
        default: return kind == "numeric" ? "gauge.with.dots.needle.50percent" : "sensor"
        }
    }
}

// MARK: View

/// Smart plug power control, energy readings and Home Assistant sensors for one printer.
struct PrinterPowerView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    let printerId: Int

    @State private var plug: PrinterSmartPlug?
    @State private var plugLoaded = false
    @State private var plugStatus: PrinterPlugStatus?
    @State private var scripts: [PrinterSmartPlug] = []
    @State private var sensors: [PrinterHASensorReading] = []
    @State private var runner = ActionRunner()
    @State private var pendingPower: Bool?
    @State private var pendingScript: PrinterSmartPlug?
    @State private var loadError: String?

    private var client: APIClient { session.client }
    private var printing: Bool { store.statuses[printerId]?.isActiveJob ?? false }
    private var canControl: Bool { session.can("smart_plugs:control") }

    var body: some View {
        List {
            if !plugLoaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if let plug {
                plugSection(plug)
                if let energy = plugStatus?.energy { energySection(energy) }
                automationSection(plug)
            } else {
                ContentUnavailableView("No Smart Plug", systemImage: "powerplug",
                                       description: Text(loadError ?? "No smart plug is linked to this printer. Plugs are set up in Settings."))
            }
            if !scripts.isEmpty {
                Section("Home Assistant") {
                    ForEach(scripts) { s in
                        Button {
                            if s.isScript { Task { await control(s, action: "on", message: "\(s.name) triggered") } } else { pendingScript = s }
                        } label: {
                            Label(s.name, systemImage: s.isScript ? "play.circle" : "switch.2")
                        }
                        .disabled(!canControl)
                    }
                }
            }
            if !sensors.isEmpty {
                Section("Sensors") {
                    ForEach(sensors) { sensor in
                        LabeledContent {
                            Text(sensor.displayValue)
                                .foregroundStyle(sensorColor(sensor))
                                .monospacedDigit()
                        } label: {
                            Label(sensor.name, systemImage: sensor.systemImage)
                        }
                    }
                }
            }
        }
        .navigationTitle("Power & Sensors")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .task(id: plug?.id) {
            guard let plug else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                plugStatus = try? await client.get("smart-plugs/\(plug.id)/status")
            }
        }
        .actionAlerts(runner)
        .confirmationDialog(powerTitle, isPresented: Binding(get: { pendingPower != nil }, set: { if !$0 { pendingPower = nil } }), titleVisibility: .visible) {
            if let on = pendingPower, let plug {
                Button(on ? "Turn On" : "Turn Off", role: on ? nil : .destructive) {
                    Task { await control(plug, action: on ? "on" : "off", message: on ? "Power on" : "Power off") }
                }
            }
        } message: {
            Text(powerMessage)
        }
        .confirmationDialog("Toggle \(pendingScript?.name ?? "")?", isPresented: Binding(get: { pendingScript != nil }, set: { if !$0 { pendingScript = nil } }), titleVisibility: .visible) {
            if let s = pendingScript {
                Button("Toggle", role: printing ? .destructive : nil) { Task { await control(s, action: "toggle", message: "\(s.name) toggled") } }
            }
        } message: {
            if printing { Text("The printer is printing.") }
        }
    }

    @ViewBuilder
    private func plugSection(_ plug: PrinterSmartPlug) -> some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "powerplug.fill")
                    .font(.title)
                    .foregroundStyle(plugStatus?.isOn == true ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plug.name).font(.headline)
                    Text([plug.typeLabel, plugStatus?.deviceName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let status = plugStatus {
                    if status.reachable == false {
                        StatusBadge(text: "Unreachable", color: .red)
                    } else {
                        StatusBadge(text: status.state?.uppercased() ?? "Unknown", color: status.isOn ? .green : .secondary)
                    }
                } else {
                    ProgressView()
                }
            }
            if let power = plugStatus?.energy?.power {
                LabeledContent("Power Draw") { Text("\(Int(power.rounded())) W").monospacedDigit() }
            }
            if canControl && !plug.isMonitorOnly {
                HStack {
                    Button { pendingPower = true } label: { Label("On", systemImage: "power").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).tint(.green)
                        .disabled(plugStatus?.isOn == true)
                    Button { pendingPower = false } label: { Label("Off", systemImage: "poweroff").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).tint(.red)
                        .disabled(plugStatus != nil && plugStatus?.isOn == false && plugStatus?.state != nil)
                }
            } else if plug.isMonitorOnly {
                Text("This plug only reports energy; it can't be switched.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Smart Plug")
        }
    }

    @ViewBuilder
    private func energySection(_ e: PrinterPlugEnergy) -> some View {
        Section("Energy") {
            if let v = e.voltage { InfoRow("Voltage", "\(Fmt.number(v)) V") }
            if let c = e.current { InfoRow("Current", "\(Fmt.number(c, digits: 2)) A") }
            if let f = e.factor { InfoRow("Power Factor", Fmt.number(f, digits: 2)) }
            if let t = e.today { InfoRow("Today", "\(Fmt.number(t, digits: 2)) kWh") }
            if let y = e.yesterday { InfoRow("Yesterday", "\(Fmt.number(y, digits: 2)) kWh") }
            if let t = e.total { InfoRow("Total", "\(Fmt.number(t, digits: 1)) kWh") }
        }
    }

    @ViewBuilder
    private func automationSection(_ plug: PrinterSmartPlug) -> some View {
        Section {
            Toggle(isOn: Binding(get: { plug.autoOff ?? false }, set: { on in Task { await setAutoOff(plug, on) } })) {
                VStack(alignment: .leading) {
                    Text("Auto Power-Off")
                    Text(autoOffDetail(plug)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!session.can("smart_plugs:update") || plug.autoOffExecuted == true)
            if let on = plug.autoOn { InfoRow("Auto Power-On", on ? "On print start" : "Off") }
            if plug.scheduleEnabled == true {
                InfoRow("Schedule", "\(plug.scheduleOnTime ?? "—") – \(plug.scheduleOffTime ?? "—")")
            }
            if plug.powerAlertEnabled == true {
                InfoRow("Power Alerts", [plug.powerAlertLow.map { "< \(Int($0)) W" }, plug.powerAlertHigh.map { "> \(Int($0)) W" }].compactMap { $0 }.joined(separator: ", "))
            }
        } header: {
            Text("Automation")
        } footer: {
            if plug.autoOffExecuted == true { Text("Auto power-off already ran for the last print.") }
        }
    }

    private func autoOffDetail(_ plug: PrinterSmartPlug) -> String {
        if plug.offDelayMode == "temperature" { return "After the print, once the nozzle cools below \(plug.offTempThreshold ?? 70)°C" }
        return "\(plug.offDelayMinutes ?? 5) min after the print finishes"
    }

    private func sensorColor(_ sensor: PrinterHASensorReading) -> Color {
        if sensor.reachable == false { return .secondary }
        return sensor.alerting == true ? .red : .primary
    }

    private var powerTitle: String { pendingPower == true ? "Turn On Printer Power?" : "Turn Off Printer Power?" }

    private var powerMessage: String {
        if pendingPower == false && printing { return "Warning: the printer is printing. Cutting power will abort the print." }
        return pendingPower == true ? "“\(plug?.name ?? "")” will be switched on." : "“\(plug?.name ?? "")” will be switched off."
    }

    // MARK: Networking

    private func load() async {
        do {
            let p: PrinterSmartPlug? = try await client.get("smart-plugs/by-printer/\(printerId)")
            plug = p
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        plugLoaded = true
        if let plug { plugStatus = try? await client.get("smart-plugs/\(plug.id)/status") }
        scripts = (try? await client.get("smart-plugs/by-printer/\(printerId)/scripts")) ?? []
        sensors = (try? await client.get("ha-sensors/by-printer/\(printerId)/readings")) ?? []
    }

    private func control(_ plug: PrinterSmartPlug, action: String, message: String) async {
        await runner.run(message) {
            try await client.call(.post, "smart-plugs/\(plug.id)/control", body: PrinterPlugControl(action: action))
            try? await Task.sleep(for: .milliseconds(800))
            if plug.id == self.plug?.id { plugStatus = try? await client.get("smart-plugs/\(plug.id)/status") }
        }
    }

    private func setAutoOff(_ plug: PrinterSmartPlug, _ on: Bool) async {
        struct Body: Encodable { var autoOff: Bool }
        await runner.run(on ? "Auto power-off enabled" : "Auto power-off disabled") {
            let updated: PrinterSmartPlug = try await client.send(.patch, "smart-plugs/\(plug.id)", body: Body(autoOff: on))
            self.plug = updated
        }
    }
}
