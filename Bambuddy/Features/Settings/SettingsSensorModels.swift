import Foundation

// MARK: - Printer-bound Home Assistant sensors (`/ha-sensors/*`)

/// A Home Assistant entity bound to a printer (`PrinterHASensorResponse`).
struct SettingsHASensor: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var printerId: Int
    var name: String
    var entityId: String
    var kind: String?
    var deviceClass: String?
    var unit: String?
    var alertState: String?
    var alertAbove: Double?
    var alertBelow: Double?
    var blockPrint: Bool?
    var notifyOnAlert: Bool?
    var showOnPrinterCard: Bool?
    var sortOrder: Int?
    var lastState: String?
    var lastChanged: String?
    var lastChecked: String?
    var createdAt: String?
    var updatedAt: String?
}

/// Live reading of a printer sensor (`PrinterHASensorReading`).
struct SettingsHASensorReading: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String?
    var entityId: String?
    var kind: String?
    var deviceClass: String?
    var unit: String?
    var state: String?
    var value: Double?
    var alerting: Bool?
    var blockPrint: Bool?
    var reachable: Bool?
    var lastChanged: String?
}

/// An entity offered by the sensor binding pickers (`HADisplayEntity`).
struct SettingsHADisplayEntity: Codable, Sendable, Identifiable, Hashable {
    var entityId: String
    var friendlyName: String
    var state: String?
    var domain: String?
    var deviceClass: String?
    var unitOfMeasurement: String?
    var id: String { entityId }

    /// Binary sensors report on/off; everything else is numeric.
    var kind: String { (domain ?? entityId.components(separatedBy: ".").first) == "binary_sensor" ? "binary" : "numeric" }
}

// MARK: - Location-bound Home Assistant sensors (`/location-ha-sensors/*`)

/// A Home Assistant entity bound to a storage location (`LocationHASensorResponse`).
struct SettingsLocationSensor: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var locationId: Int
    var name: String
    var entityId: String
    var kind: String?
    var deviceClass: String?
    var unit: String?
    var alertState: String?
    var alertAbove: Double?
    var alertBelow: Double?
    var notifyOnAlert: Bool?
    var showOnCard: Bool?
    var sortOrder: Int?
    var lastState: String?
    var lastChanged: String?
    var lastChecked: String?
    var createdAt: String?
    var updatedAt: String?

    var category: SettingsLocationSensorCategory? { SettingsLocationSensorCategory(deviceClass: deviceClass) }
}

/// Live reading of a location sensor (`LocationHASensorReading`).
struct SettingsLocationSensorReading: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String?
    var entityId: String?
    var kind: String?
    var deviceClass: String?
    var unit: String?
    var state: String?
    var value: Double?
    var alerting: Bool?
    var reachable: Bool?
    var alertState: String?
    var alertAbove: Double?
    var alertBelow: Double?
    var lastChanged: String?
    var showOnCard: Bool?
}

/// A storage location (`GET /inventory/locations`, `LocationResponse`).
struct SettingsLocationSensorPlace: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var identifier: String?
    var spoolCount: Int?
    var createdAt: String?
    var updatedAt: String?
}

/// The three kinds of sensor a storage location can have — one of each.
enum SettingsLocationSensorCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    case temperature, humidity, battery
    var id: String { rawValue }

    /// Only these device classes can be bound to a location. "moisture" is
    /// deliberately excluded: it is a binary wet/dry class, not a humidity reading.
    init?(deviceClass: String?) {
        guard let deviceClass, let value = Self(rawValue: deviceClass) else { return nil }
        self = value
    }

    var title: String {
        switch self {
        case .temperature: "Temperature"
        case .humidity: "Humidity"
        case .battery: "Battery"
        }
    }

    var systemImage: String {
        switch self {
        case .temperature: "thermometer.medium"
        case .humidity: "humidity"
        case .battery: "battery.50percent"
        }
    }

    var unitHint: String {
        switch self {
        case .temperature: "°C"
        case .humidity, .battery: "%"
        }
    }

    /// Display order within a location.
    var order: Int {
        switch self {
        case .temperature: 0
        case .humidity: 1
        case .battery: 2
        }
    }

    /// A battery only ever alerts when it runs low.
    var allowsAlertAbove: Bool { self != .battery }
}

// MARK: - Alert defaults (`location_sensor_alert_defaults`)

/// Default alert rules seeded onto new location sensors. Stored on the server as
/// a JSON string: `{"temperature": {"alertAbove": "30", "alertBelow": "20",
/// "notifyOnAlert": false}, ...}` (values kept as strings; empty = no threshold).
/// An empty setting means the built-in defaults.
struct SettingsLocationSensorDefaults: Equatable, Sendable {
    struct Rule: Equatable, Sendable {
        var alertAbove: String
        var alertBelow: String
        var notifyOnAlert: Bool
    }

    var rules: [SettingsLocationSensorCategory: Rule]

    static let builtIn = SettingsLocationSensorDefaults(rules: [
        .temperature: Rule(alertAbove: "30", alertBelow: "20", notifyOnAlert: false),
        .humidity: Rule(alertAbove: "30", alertBelow: "10", notifyOnAlert: false),
        .battery: Rule(alertAbove: "", alertBelow: "10", notifyOnAlert: false),
    ])

    subscript(category: SettingsLocationSensorCategory) -> Rule {
        get { rules[category] ?? Self.builtIn.rules[category]! }
        set { rules[category] = newValue }
    }

    /// Parses the stored setting, falling back to the built-ins for anything
    /// missing, mistyped or unparseable.
    static func parse(_ json: String?) -> SettingsLocationSensorDefaults {
        var result = builtIn
        guard let json, !json.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return result }
        for category in SettingsLocationSensorCategory.allCases {
            guard let stored = object[category.rawValue] as? [String: Any] else { continue }
            var rule = result[category]
            if let above = stored["alertAbove"] as? String { rule.alertAbove = above }
            if let below = stored["alertBelow"] as? String { rule.alertBelow = below }
            if let notify = stored["notifyOnAlert"] as? Bool { rule.notifyOnAlert = notify }
            result[category] = rule
        }
        return result
    }

    /// Compact JSON for the setting. A battery never stores an upper threshold.
    func serialized() -> String {
        var object: [String: [String: JSONValue]] = [:]
        for category in SettingsLocationSensorCategory.allCases {
            let rule = self[category]
            object[category.rawValue] = [
                "alertAbove": .string(category.allowsAlertAbove ? rule.alertAbove : ""),
                "alertBelow": .string(rule.alertBelow),
                "notifyOnAlert": .bool(rule.notifyOnAlert),
            ]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(object), let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }
}

// MARK: - Display helpers

enum SettingsSensorDisplay {
    /// Home Assistant's own wording for binary states of common device classes.
    static let binaryLabels: [String: (on: String, off: String)] = [
        "door": ("Open", "Closed"), "garage_door": ("Open", "Closed"), "window": ("Open", "Closed"),
        "opening": ("Open", "Closed"), "lock": ("Unlocked", "Locked"),
        "motion": ("Detected", "Clear"), "occupancy": ("Detected", "Clear"), "presence": ("Detected", "Clear"),
        "smoke": ("Detected", "Clear"), "gas": ("Detected", "Clear"),
        "moisture": ("Wet", "Dry"), "problem": ("Problem", "OK"), "safety": ("Problem", "OK"),
        "running": ("Running", "Stopped"),
    ]

    static func stateLabel(_ state: String, deviceClass: String?) -> String {
        let lower = state.lowercased()
        if let labels = binaryLabels[deviceClass ?? ""] {
            if lower == "on" { return labels.on }
            if lower == "off" { return labels.off }
        }
        switch lower {
        case "on": return "On"
        case "off": return "Off"
        case "unavailable": return "Unavailable"
        case "unknown": return "Unknown"
        default: return state
        }
    }

    /// A reading as text: "Unavailable", a binary label, or a number with its unit.
    static func describe(kind: String?, deviceClass: String?, unit: String?, state: String?, value: Double?, reachable: Bool?, decimals: Int? = nil) -> String {
        guard reachable ?? false, let state else { return "Unavailable" }
        if kind == "numeric" {
            guard let value else { return state }
            let formatted: String
            if let decimals {
                formatted = value.formatted(.number.precision(.fractionLength(decimals)).grouping(.never))
            } else {
                formatted = value.formatted(.number.precision(.fractionLength(0...4)).grouping(.never))
            }
            return [formatted, unit].compactMap { $0 }.joined(separator: " ")
        }
        return stateLabel(state, deviceClass: deviceClass)
    }

    static func systemImage(deviceClass: String?, kind: String?, state: String?) -> String {
        let off = state?.lowercased() == "off"
        switch deviceClass ?? "" {
        case "door", "garage_door", "window", "opening": return off ? "door.left.hand.closed" : "door.left.hand.open"
        case "lock": return off ? "lock.fill" : "lock.open.fill"
        case "temperature": return "thermometer.medium"
        case "humidity", "moisture": return "humidity"
        case "battery": return "battery.50percent"
        case "motion", "occupancy", "presence": return "figure.walk.motion"
        case "smoke", "gas", "problem", "safety": return "exclamationmark.triangle"
        case "running": return "fan"
        default: return kind == "numeric" ? "gauge.with.dots.needle.33percent" : "sensor"
        }
    }

    /// Whether a location reading is above, below, or within its thresholds.
    static func alertStatus(_ reading: SettingsLocationSensorReading) -> String? {
        guard reading.reachable ?? false, let state = reading.state else { return nil }
        if reading.kind == "numeric" {
            guard reading.alertAbove != nil || reading.alertBelow != nil, let value = reading.value else { return nil }
            if let above = reading.alertAbove, value > above { return "above" }
            if let below = reading.alertBelow, value < below { return "below" }
            return "ok"
        }
        guard let alertState = reading.alertState else { return nil }
        return state.lowercased() == alertState ? "above" : "ok"
    }
}

// MARK: - Request bodies

/// Validated alert fields shared by both binding editors.
struct SettingsSensorAlertDraft: Equatable, Sendable {
    var kind = "binary"
    var alertState = ""        // "", "on", "off"
    var alertAbove = ""
    var alertBelow = ""

    var hasCondition: Bool {
        kind == "binary" ? !alertState.isEmpty : !(alertAbove.trimmingCharacters(in: .whitespaces).isEmpty && alertBelow.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// Returns a message when the thresholds can't be sent as typed.
    func validationError(allowsAbove: Bool = true) -> String? {
        guard kind == "numeric" else { return nil }
        if !alertAbove.trimmingCharacters(in: .whitespaces).isEmpty, allowsAbove, Self.number(alertAbove) == nil { return "The upper threshold isn't a number." }
        if !alertBelow.trimmingCharacters(in: .whitespaces).isEmpty, Self.number(alertBelow) == nil { return "The lower threshold isn't a number." }
        if allowsAbove, let above = Self.number(alertAbove), let below = Self.number(alertBelow), below >= above {
            return "The lower threshold must be below the upper threshold."
        }
        return nil
    }

    /// `alert_state` / `alert_above` / `alert_below`, with the fields that don't
    /// apply to this kind sent as null (the backend rejects mixed rules).
    func fields(allowsAbove: Bool = true) -> [String: JSONValue] {
        [
            "alert_state": kind == "binary" && !alertState.isEmpty ? .string(alertState) : .null,
            "alert_above": kind == "numeric" && allowsAbove ? (Self.number(alertAbove).map { .number($0) } ?? .null) : .null,
            "alert_below": kind == "numeric" ? (Self.number(alertBelow).map { .number($0) } ?? .null) : .null,
        ]
    }
}
