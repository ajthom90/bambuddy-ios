import Foundation

// MARK: - API models (`/smart-plugs/*`)

/// A configured smart plug (`SmartPlugResponse`).
struct SettingsSmartPlug: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var plugType: String?
    // Tasmota
    var ipAddress: String?
    var username: String?
    var password: String?
    // Home Assistant
    var haEntityId: String?
    var haPowerEntity: String?
    var haEnergyTodayEntity: String?
    var haEnergyTotalEntity: String?
    // MQTT (monitor only)
    var mqttTopic: String?
    var mqttPowerTopic: String?
    var mqttPowerPath: String?
    var mqttPowerMultiplier: Double?
    var mqttEnergyTopic: String?
    var mqttEnergyPath: String?
    var mqttEnergyMultiplier: Double?
    var mqttStateTopic: String?
    var mqttStatePath: String?
    var mqttStateOnValue: String?
    var mqttMultiplier: Double?
    // REST / webhook
    var restOnUrl: String?
    var restOnBody: String?
    var restOffUrl: String?
    var restOffBody: String?
    var restMethod: String?
    var restHeaders: String?
    var restStatusUrl: String?
    var restStatusPath: String?
    var restStatusOnValue: String?
    var restPowerUrl: String?
    var restPowerPath: String?
    var restPowerMultiplier: Double?
    var restEnergyUrl: String?
    var restEnergyPath: String?
    var restEnergyMultiplier: Double?
    var restEnergyTotalPath: String?
    var restEnergyTotalMultiplier: Double?
    // Linking & automation
    var printerId: Int?
    var controlsPrinterPower: Bool?
    var enabled: Bool?
    var autoOn: Bool?
    var autoOff: Bool?
    var autoOffPersistent: Bool?
    var offDelayMode: String?
    var offDelayMinutes: Int?
    var offTempThreshold: Int?
    var autoOffAfterDrying: Bool?
    var offDelayAfterDryingMinutes: Int?
    var powerAlertEnabled: Bool?
    var powerAlertHigh: Double?
    var powerAlertLow: Double?
    var scheduleEnabled: Bool?
    var scheduleOnTime: String?
    var scheduleOffTime: String?
    var showInSwitchbar: Bool?
    var showOnPrinterCard: Bool?
    // State
    var lastState: String?
    var lastChecked: String?
    var autoOffExecuted: Bool?
    var powerAlertLastTriggered: String?
    var createdAt: String?
    var updatedAt: String?

    var type: SettingsSmartPlugType { SettingsSmartPlugType(rawValue: plugType ?? "tasmota") ?? .tasmota }
    var isEnabled: Bool { enabled ?? true }

    /// The address-like detail shown under the plug's name.
    var subtitle: String? {
        let value: String?
        switch type {
        case .tasmota: value = ipAddress
        case .homeassistant: value = haEntityId
        case .mqtt: value = mqttPowerTopic ?? mqttTopic ?? mqttEnergyTopic ?? mqttStateTopic
        case .rest: value = (restOnUrl?.isEmpty == false ? restOnUrl : nil) ?? restOffUrl
        }
        return value?.isEmpty == false ? value : nil
    }
}

/// Plug backends supported by the server.
enum SettingsSmartPlugType: String, CaseIterable, Identifiable, Sendable {
    case tasmota, homeassistant, mqtt, rest
    var id: String { rawValue }

    var label: String {
        switch self {
        case .tasmota: "Tasmota"
        case .homeassistant: "Home Assistant"
        case .mqtt: "MQTT"
        case .rest: "REST"
        }
    }

    var shortLabel: String {
        switch self {
        case .tasmota: "Tasmota"
        case .homeassistant: "HA"
        case .mqtt: "MQTT"
        case .rest: "REST"
        }
    }

    var systemImage: String {
        switch self {
        case .tasmota: "powerplug"
        case .homeassistant: "house"
        case .mqtt: "antenna.radiowaves.left.and.right"
        case .rest: "globe"
        }
    }

    /// MQTT plugs only report; they cannot be switched.
    var isControllable: Bool { self != .mqtt }
}

/// Energy readings reported with a plug's status (`SmartPlugEnergy`).
struct SettingsSmartPlugEnergy: Codable, Sendable, Hashable {
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

/// Live device status (`GET /smart-plugs/{id}/status`).
struct SettingsSmartPlugStatus: Codable, Sendable, Hashable {
    var state: String?
    var reachable: Bool?
    var deviceName: String?
    var energy: SettingsSmartPlugEnergy?

    var isOn: Bool { state?.uppercased() == "ON" }
}

/// Result of `POST /smart-plugs/test-connection` (Tasmota).
struct SettingsSmartPlugTestResult: Codable, Sendable {
    var success: Bool?
    var state: String?
    var deviceName: String?
}

/// Result of `POST /smart-plugs/ha/test-connection`.
struct SettingsHATestResult: Codable, Sendable {
    var success: Bool
    var message: String?
    var error: String?
}

/// Result of `POST /smart-plugs/rest/test-connection`.
struct SettingsSmartPlugRESTTestResult: Codable, Sendable {
    var success: Bool
    var error: String?
}

/// Tasmota network scan progress (`TasmotaScanStatus`).
struct SettingsTasmotaScanStatus: Codable, Sendable, Hashable {
    var running: Bool
    var scanned: Int
    var total: Int
}

/// A Tasmota device found by the network scan (`DiscoveredTasmotaDevice`).
struct SettingsTasmotaDevice: Codable, Sendable, Hashable, Identifiable {
    var ipAddress: String
    var name: String
    var module: Int?
    var state: String?
    var discoveredAt: String?
    var id: String { ipAddress }
}

/// A switchable Home Assistant entity (`HAEntity`).
struct SettingsHAEntity: Codable, Sendable, Hashable, Identifiable {
    var entityId: String
    var friendlyName: String
    var state: String?
    var domain: String?
    var id: String { entityId }
}

/// A Home Assistant sensor usable for power/energy readings (`HASensorEntity`).
struct SettingsHASensorEntity: Codable, Sendable, Hashable, Identifiable {
    var entityId: String
    var friendlyName: String
    var state: String?
    var unitOfMeasurement: String?
    var id: String { entityId }

    static let powerUnits: Set<String> = ["W", "kW", "mW"]
    static let energyUnits: Set<String> = ["kWh", "Wh", "MWh"]
}

// MARK: - Energy summary

/// Totals across enabled plugs, computed the same way the web dashboard does:
/// only reachable plugs contribute, and an MQTT plug counts as reachable as
/// soon as it has reported a power value.
struct SettingsSmartPlugEnergySummary: Equatable, Sendable {
    var totalPower: Double = 0
    var today: Double = 0
    var yesterday: Double = 0
    var lifetime: Double = 0
    var reachable = 0
    var total = 0

    static func isReachable(_ plug: SettingsSmartPlug, _ status: SettingsSmartPlugStatus?) -> Bool {
        if status?.reachable == true { return true }
        return plug.type == .mqtt && status?.energy?.power != nil
    }

    init() {}

    init(plugs: [SettingsSmartPlug], statuses: [Int: SettingsSmartPlugStatus]) {
        let enabled = plugs.filter(\.isEnabled)
        total = enabled.count
        for plug in enabled {
            let status = statuses[plug.id]
            guard Self.isReachable(plug, status) else { continue }
            reachable += 1
            totalPower += status?.energy?.power ?? 0
            today += status?.energy?.today ?? 0
            yesterday += status?.energy?.yesterday ?? 0
            lifetime += status?.energy?.total ?? 0
        }
    }
}

// MARK: - Editable draft

/// Form state for the add/edit sheet. Everything is kept as the user typed it
/// and converted to the request body in `body()`.
struct SettingsSmartPlugDraft: Equatable, Sendable {
    var type: SettingsSmartPlugType = .tasmota
    var name = ""
    // Tasmota
    var ipAddress = ""
    var username = ""
    var password = ""
    // Home Assistant
    var haEntityId = ""
    var haPowerEntity = ""
    var haEnergyTodayEntity = ""
    var haEnergyTotalEntity = ""
    // MQTT
    var mqttPowerTopic = ""
    var mqttPowerPath = ""
    var mqttPowerMultiplier = "1"
    var mqttEnergyTopic = ""
    var mqttEnergyPath = ""
    var mqttEnergyMultiplier = "1"
    var mqttStateTopic = ""
    var mqttStatePath = ""
    var mqttStateOnValue = ""
    // REST
    var restMethod = "POST"
    var restOnUrl = ""
    var restOnBody = ""
    var restOffUrl = ""
    var restOffBody = ""
    var restHeaders = ""
    var restStatusUrl = ""
    var restStatusPath = ""
    var restStatusOnValue = ""
    var restPowerUrl = ""
    var restPowerPath = ""
    var restPowerMultiplier = "1"
    var restEnergyUrl = ""
    var restEnergyPath = ""
    var restEnergyMultiplier = "1"
    var restEnergyTotalPath = ""
    var restEnergyTotalMultiplier = "1"
    // Linking
    var printerId: Int?
    var controlsPrinterPower = true
    // Automation
    var enabled = true
    var autoOn = true
    var autoOff = true
    var autoOffPersistent = false
    var offDelayMode = "time"
    var offDelayMinutes = 5
    var offTempThreshold = 70
    var autoOffAfterDrying = false
    var offDelayAfterDryingMinutes = 10
    // Alerts
    var powerAlertEnabled = false
    var powerAlertHigh = ""
    var powerAlertLow = ""
    // Schedule ("HH:MM" or empty)
    var scheduleEnabled = false
    var scheduleOnTime = ""
    var scheduleOffTime = ""
    // Visibility
    var showInSwitchbar = false
    var showOnPrinterCard = true

    static let restMethods = ["GET", "POST", "PUT", "PATCH"]

    init() {}

    init(plug: SettingsSmartPlug) {
        type = plug.type
        name = plug.name
        ipAddress = plug.ipAddress ?? ""
        username = plug.username ?? ""
        password = plug.password ?? ""
        haEntityId = plug.haEntityId ?? ""
        haPowerEntity = plug.haPowerEntity ?? ""
        haEnergyTodayEntity = plug.haEnergyTodayEntity ?? ""
        haEnergyTotalEntity = plug.haEnergyTotalEntity ?? ""
        mqttPowerTopic = (plug.mqttPowerTopic?.isEmpty == false ? plug.mqttPowerTopic : plug.mqttTopic) ?? ""
        mqttPowerPath = plug.mqttPowerPath ?? ""
        mqttPowerMultiplier = Self.format(plug.mqttPowerMultiplier ?? plug.mqttMultiplier ?? 1)
        mqttEnergyTopic = plug.mqttEnergyTopic ?? ""
        mqttEnergyPath = plug.mqttEnergyPath ?? ""
        mqttEnergyMultiplier = Self.format(plug.mqttEnergyMultiplier ?? 1)
        mqttStateTopic = plug.mqttStateTopic ?? ""
        mqttStatePath = plug.mqttStatePath ?? ""
        mqttStateOnValue = plug.mqttStateOnValue ?? ""
        restMethod = plug.restMethod ?? "POST"
        restOnUrl = plug.restOnUrl ?? ""
        restOnBody = plug.restOnBody ?? ""
        restOffUrl = plug.restOffUrl ?? ""
        restOffBody = plug.restOffBody ?? ""
        restHeaders = plug.restHeaders ?? ""
        restStatusUrl = plug.restStatusUrl ?? ""
        restStatusPath = plug.restStatusPath ?? ""
        restStatusOnValue = plug.restStatusOnValue ?? ""
        restPowerUrl = plug.restPowerUrl ?? ""
        restPowerPath = plug.restPowerPath ?? ""
        restPowerMultiplier = Self.format(plug.restPowerMultiplier ?? 1)
        restEnergyUrl = plug.restEnergyUrl ?? ""
        restEnergyPath = plug.restEnergyPath ?? ""
        restEnergyMultiplier = Self.format(plug.restEnergyMultiplier ?? 1)
        restEnergyTotalPath = plug.restEnergyTotalPath ?? ""
        restEnergyTotalMultiplier = Self.format(plug.restEnergyTotalMultiplier ?? 1)
        printerId = plug.printerId
        controlsPrinterPower = plug.controlsPrinterPower ?? true
        enabled = plug.enabled ?? true
        autoOn = plug.autoOn ?? true
        autoOff = plug.autoOff ?? true
        autoOffPersistent = plug.autoOffPersistent ?? false
        offDelayMode = plug.offDelayMode ?? "time"
        offDelayMinutes = plug.offDelayMinutes ?? 5
        offTempThreshold = plug.offTempThreshold ?? 70
        autoOffAfterDrying = plug.autoOffAfterDrying ?? false
        offDelayAfterDryingMinutes = plug.offDelayAfterDryingMinutes ?? 10
        powerAlertEnabled = plug.powerAlertEnabled ?? false
        powerAlertHigh = plug.powerAlertHigh.map(Self.format) ?? ""
        powerAlertLow = plug.powerAlertLow.map(Self.format) ?? ""
        scheduleEnabled = plug.scheduleEnabled ?? false
        scheduleOnTime = plug.scheduleOnTime ?? ""
        scheduleOffTime = plug.scheduleOffTime ?? ""
        showInSwitchbar = plug.showInSwitchbar ?? false
        showOnPrinterCard = plug.showOnPrinterCard ?? true
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e12 { return String(Int(value)) }
        return String(value)
    }

    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return trimmed.isEmpty ? nil : Double(trimmed)
    }

    private static func multiplier(_ text: String) -> Double {
        guard let value = parse(text), value > 0 else { return 1 }
        return value
    }

    private static let ipPattern = #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#
    private static let timePattern = #"^([01]\d|2[0-3]):[0-5]\d$"#

    /// Client-side checks that mirror the backend's validators, so the user
    /// gets a readable message instead of a 422.
    func validationError() -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty { return "Enter a name for the plug." }
        if trimmedName.count > 100 { return "The name can be at most 100 characters." }
        switch type {
        case .tasmota:
            let ip = ipAddress.trimmingCharacters(in: .whitespaces)
            if ip.isEmpty { return "Enter the plug's IP address." }
            if ip.range(of: Self.ipPattern, options: .regularExpression) == nil { return "Enter an IPv4 address such as 192.168.1.50." }
        case .homeassistant:
            if haEntityId.isEmpty { return "Choose a Home Assistant entity." }
        case .mqtt:
            if [mqttPowerTopic, mqttEnergyTopic, mqttStateTopic].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return "Enter at least one MQTT topic (power, energy or state)."
            }
        case .rest:
            if restOnUrl.trimmingCharacters(in: .whitespaces).isEmpty && restOffUrl.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Enter an ON URL, an OFF URL, or both."
            }
            let headers = restHeaders.trimmingCharacters(in: .whitespacesAndNewlines)
            if !headers.isEmpty {
                let parsed = try? JSONSerialization.jsonObject(with: Data(headers.utf8))
                if !(parsed is [String: Any]) { return "Headers must be a JSON object, e.g. {\"Authorization\": \"Bearer …\"}." }
            }
        }
        if powerAlertEnabled {
            for (label, text) in [("upper", powerAlertHigh), ("lower", powerAlertLow)] where !text.isEmpty {
                guard let value = Self.parse(text), (0...5000).contains(value) else {
                    return "The \(label) power alert must be between 0 and 5000 W."
                }
            }
        }
        if scheduleEnabled {
            for time in [scheduleOnTime, scheduleOffTime] where !time.isEmpty {
                if time.range(of: Self.timePattern, options: .regularExpression) == nil { return "Schedule times must use the HH:MM format." }
            }
        }
        return nil
    }

    /// The request body for `POST /smart-plugs/` and `PATCH /smart-plugs/{id}`.
    /// Fields that don't belong to the selected type are sent as null so a
    /// type's leftovers never linger on the server.
    func body() -> [String: JSONValue] {
        func text(_ value: String, when active: Bool) -> JSONValue {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return active && !trimmed.isEmpty ? .string(trimmed) : .null
        }
        func number(_ value: Double) -> JSONValue { .number(value) }
        let tasmota = type == .tasmota, ha = type == .homeassistant, mqtt = type == .mqtt, rest = type == .rest

        var b: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "plug_type": .string(type.rawValue),
            "ip_address": text(ipAddress, when: tasmota),
            "username": text(username, when: tasmota),
            "password": text(password, when: tasmota),
            "ha_entity_id": ha && !haEntityId.isEmpty ? .string(haEntityId) : .null,
            "ha_power_entity": text(haPowerEntity, when: ha),
            "ha_energy_today_entity": text(haEnergyTodayEntity, when: ha),
            "ha_energy_total_entity": text(haEnergyTotalEntity, when: ha),
            "mqtt_power_topic": text(mqttPowerTopic, when: mqtt),
            "mqtt_power_path": text(mqttPowerPath, when: mqtt),
            "mqtt_power_multiplier": number(mqtt ? Self.multiplier(mqttPowerMultiplier) : 1),
            "mqtt_energy_topic": text(mqttEnergyTopic, when: mqtt),
            "mqtt_energy_path": text(mqttEnergyPath, when: mqtt),
            "mqtt_energy_multiplier": number(mqtt ? Self.multiplier(mqttEnergyMultiplier) : 1),
            "mqtt_state_topic": text(mqttStateTopic, when: mqtt),
            "mqtt_state_path": text(mqttStatePath, when: mqtt),
            "mqtt_state_on_value": text(mqttStateOnValue, when: mqtt),
            "rest_on_url": text(restOnUrl, when: rest),
            "rest_on_body": text(restOnBody, when: rest),
            "rest_off_url": text(restOffUrl, when: rest),
            "rest_off_body": text(restOffBody, when: rest),
            "rest_method": rest ? .string(restMethod) : .null,
            "rest_headers": text(restHeaders, when: rest),
            "rest_status_url": text(restStatusUrl, when: rest),
            "rest_status_path": text(restStatusPath, when: rest),
            "rest_status_on_value": text(restStatusOnValue, when: rest),
            "rest_power_url": text(restPowerUrl, when: rest),
            "rest_power_path": text(restPowerPath, when: rest),
            "rest_power_multiplier": number(rest ? Self.multiplier(restPowerMultiplier) : 1),
            "rest_energy_url": text(restEnergyUrl, when: rest),
            "rest_energy_path": text(restEnergyPath, when: rest),
            "rest_energy_multiplier": number(rest ? Self.multiplier(restEnergyMultiplier) : 1),
            "rest_energy_total_path": text(restEnergyTotalPath, when: rest),
            "rest_energy_total_multiplier": number(rest ? Self.multiplier(restEnergyTotalMultiplier) : 1),
            "printer_id": printerId.map { .number(Double($0)) } ?? .null,
            "controls_printer_power": .bool(controlsPrinterPower),
            "power_alert_enabled": .bool(powerAlertEnabled),
            "power_alert_high": Self.parse(powerAlertHigh).map { .number($0) } ?? .null,
            "power_alert_low": Self.parse(powerAlertLow).map { .number($0) } ?? .null,
            "schedule_enabled": .bool(scheduleEnabled),
            "schedule_on_time": scheduleOnTime.isEmpty ? .null : .string(scheduleOnTime),
            "schedule_off_time": scheduleOffTime.isEmpty ? .null : .string(scheduleOffTime),
            "show_in_switchbar": .bool(showInSwitchbar),
            "show_on_printer_card": .bool(showOnPrinterCard),
        ]
        // Automation only applies to plugs that can be switched.
        if type.isControllable {
            b["enabled"] = .bool(enabled)
            b["auto_on"] = .bool(autoOn)
            b["auto_off"] = .bool(autoOff)
            b["auto_off_persistent"] = .bool(autoOffPersistent)
            b["off_delay_mode"] = .string(offDelayMode)
            b["off_delay_minutes"] = .number(Double(min(max(offDelayMinutes, 0), 60)))
            b["off_temp_threshold"] = .number(Double(min(max(offTempThreshold, 30), 150)))
            b["auto_off_after_drying"] = .bool(autoOffAfterDrying)
            b["off_delay_after_drying_minutes"] = .number(Double(min(max(offDelayAfterDryingMinutes, 0), 120)))
        }
        return b
    }
}
