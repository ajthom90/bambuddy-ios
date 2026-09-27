import Foundation

// Pure parsing/serialisation helpers for the settings that the server stores as
// JSON-encoded strings (quick presets, preheat targets, drying presets, humidity
// triggers, g-code snippets). An empty string always means "use the built-in defaults".

/// Encodes a JSON-compatible value compactly with stable (sorted) keys.
private func settingsWorkflowCompactJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

/// Decodes a JSON string into a loosely typed value, or nil when empty/invalid.
private func settingsWorkflowParseJSON(_ raw: String) -> JSONValue? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

/// Integer value of a JSON number (also accepts numeric strings), rejecting booleans.
private func settingsWorkflowInt(_ value: JSONValue?) -> Int? {
    switch value {
    case .number(let n)?: return n.isFinite ? Int(n.rounded()) : nil
    case .string(let s)?: return Double(s).flatMap { $0.isFinite ? Int($0.rounded()) : nil }
    default: return nil
    }
}

// MARK: - Temperature / fan quick presets

/// One of the four "three quick values" settings shown in the printer-card popovers.
struct SettingsWorkflowPresetCategory: Identifiable, Sendable, Hashable {
    let key: String
    let title: String
    let unit: String
    let range: ClosedRange<Int>
    let defaults: [Int]
    var id: String { key }

    static let maxChamberTemp = 65

    static let all: [SettingsWorkflowPresetCategory] = [
        .init(key: "nozzle_temp_presets", title: "Nozzle Temperature", unit: "°C", range: 0...320, defaults: [120, 220, 260]),
        .init(key: "bed_temp_presets", title: "Bed Temperature", unit: "°C", range: 0...140, defaults: [55, 75, 90]),
        .init(key: "chamber_temp_presets", title: "Chamber Temperature", unit: "°C", range: 0...maxChamberTemp, defaults: [35, 45, 60]),
        .init(key: "fan_speed_presets", title: "Fan Speed", unit: "%", range: 0...100, defaults: [50, 75, 100]),
    ]

    /// The stored triple, or the defaults when empty, malformed or out of range.
    func values(from raw: String) -> [Int] {
        guard let items = settingsWorkflowParseJSON(raw)?.arrayValue, items.count == 3 else { return defaults }
        var out: [Int] = []
        for item in items {
            guard case .number(let n) = item, n.rounded() == n, range.contains(Int(n)) else { return defaults }
            out.append(Int(n))
        }
        return out
    }

    /// Serialises a triple (values are clamped into range). The backend requires exactly three integers.
    func encode(_ values: [Int]) -> String {
        let clamped = (0..<3).map { i in
            min(max(i < values.count ? values[i] : defaults[i], range.lowerBound), range.upperBound)
        }
        return settingsWorkflowCompactJSON(clamped)
    }
}

// MARK: - Preheat chamber targets

/// Per-filament chamber target temperatures used by the queue's preheat stage.
enum SettingsPreheatTargets {
    static let maxTemp = SettingsWorkflowPresetCategory.maxChamberTemp

    static let defaults: [String: Int] = [
        "PLA": 0, "PETG": 0, "PETG-CF": 40, "ABS": 45, "ASA": 45, "PA": 50, "PA-CF": 55,
        "PC": 50, "PC-FR": 50, "TPU": 0, "PVA": 0, "default": 0,
    ]

    /// Display order (engineering filaments first, the catch-all row last).
    static let order = ["PA-CF", "PA", "PC", "PC-FR", "ABS", "ASA", "PETG-CF", "PETG", "PLA", "TPU", "PVA", "default"]

    static func parse(_ raw: String) -> [String: Int] {
        guard let object = settingsWorkflowParseJSON(raw)?.objectValue else { return defaults }
        var out: [String: Int] = [:]
        for (key, value) in object {
            if let n = settingsWorkflowInt(value) { out[key] = min(max(n, 0), maxTemp) }
        }
        if out["default"] == nil { out["default"] = defaults["default"] }
        return out
    }

    /// Value shown for a row (falls back to the bundled default for that filament).
    static func value(for key: String, in map: [String: Int]) -> Int {
        map[key] ?? defaults[key] ?? 0
    }

    /// Rows to display: the canonical order plus any custom keys already stored.
    static func rows(for map: [String: Int]) -> [String] {
        order + map.keys.filter { !order.contains($0) }.sorted()
    }

    static func serialize(_ map: [String: Int]) -> String {
        settingsWorkflowCompactJSON(map.mapValues { min(max($0, 0), maxTemp) })
    }
}

// MARK: - Drying presets

/// Drying temperature/duration for one filament type, per dryer model
/// (`n3f` = AMS 2 Pro, `n3s` = AMS-HT).
struct SettingsDryingPreset: Codable, Sendable, Hashable {
    var n3f: Int
    var n3s: Int
    var n3fHours: Int
    var n3sHours: Int

    // Encoded with a plain JSONEncoder, so the stored key names are spelled out.
    enum CodingKeys: String, CodingKey {
        case n3f, n3s
        case n3fHours = "n3f_hours"
        case n3sHours = "n3s_hours"
    }

    static let amsProTempRange = 30...65
    static let amsHTTempRange = 30...85
    static let hoursRange = 1...24
}

enum SettingsDryingPresets {
    /// Built-in presets, in display order (mirrors the server's defaults).
    static let defaults: [(name: String, preset: SettingsDryingPreset)] = [
        ("PLA", .init(n3f: 45, n3s: 45, n3fHours: 12, n3sHours: 12)),
        ("PETG", .init(n3f: 65, n3s: 65, n3fHours: 12, n3sHours: 12)),
        ("TPU", .init(n3f: 65, n3s: 75, n3fHours: 12, n3sHours: 18)),
        ("ABS", .init(n3f: 65, n3s: 80, n3fHours: 12, n3sHours: 8)),
        ("ASA", .init(n3f: 65, n3s: 80, n3fHours: 12, n3sHours: 8)),
        ("PA", .init(n3f: 65, n3s: 85, n3fHours: 12, n3sHours: 12)),
        ("PC", .init(n3f: 65, n3s: 80, n3fHours: 12, n3sHours: 8)),
        ("PVA", .init(n3f: 65, n3s: 85, n3fHours: 12, n3sHours: 18)),
    ]

    private static let fallback = SettingsDryingPreset(n3f: 65, n3s: 65, n3fHours: 12, n3sHours: 12)

    /// Stored presets merged over the defaults (a stored filament entry replaces the default
    /// one; missing fields are filled from that filament's default). Defaults come first, then
    /// any extra filament types in alphabetical order.
    static func parse(_ raw: String) -> [(name: String, preset: SettingsDryingPreset)] {
        let stored = settingsWorkflowParseJSON(raw)?.objectValue ?? [:]
        func merged(_ name: String, base: SettingsDryingPreset) -> SettingsDryingPreset {
            guard let entry = stored[name] else { return base }
            return SettingsDryingPreset(
                n3f: settingsWorkflowInt(entry["n3f"]) ?? base.n3f,
                n3s: settingsWorkflowInt(entry["n3s"]) ?? base.n3s,
                n3fHours: settingsWorkflowInt(entry["n3f_hours"]) ?? base.n3fHours,
                n3sHours: settingsWorkflowInt(entry["n3s_hours"]) ?? base.n3sHours
            )
        }
        var rows = defaults.map { ($0.name, merged($0.name, base: $0.preset)) }
        let known = Set(defaults.map(\.name))
        for name in stored.keys.sorted() where !known.contains(name) && stored[name]?.objectValue != nil {
            rows.append((name, merged(name, base: fallback)))
        }
        return rows.map { (name: $0.0, preset: $0.1) }
    }

    /// Serialises the full table (the server reads it as a complete map).
    static func serialize(_ rows: [(name: String, preset: SettingsDryingPreset)]) -> String {
        var map: [String: SettingsDryingPreset] = [:]
        for row in rows { map[row.name] = row.preset }
        return settingsWorkflowCompactJSON(map)
    }
}

// MARK: - Per-filament humidity triggers

/// Humidity (%) above which auto-drying/alarms fire, per filament type. Keys that are
/// absent inherit from `default`, which itself inherits from `ams_humidity_fair`.
enum SettingsDryingHumidity {
    static let filamentTypes = ["PLA", "PETG", "TPU", "ABS", "ASA", "PA", "PC", "PVA"]
    static let range = 5...95

    static func parse(_ raw: String) -> [String: Int] {
        guard let object = settingsWorkflowParseJSON(raw)?.objectValue else { return [:] }
        var out: [String: Int] = [:]
        for (key, value) in object {
            if let n = settingsWorkflowInt(value) { out[key] = n }
        }
        return out
    }

    /// Effective threshold for a row, following the inheritance chain.
    static func resolved(_ key: String, in map: [String: Int], fair: Int) -> Int {
        map[key] ?? map["default"] ?? fair
    }

    /// Rows to display: the default row, the common types, then any custom keys already stored.
    static func rows(for map: [String: Int]) -> [String] {
        let fixed = ["default"] + filamentTypes
        return fixed + map.keys.filter { !fixed.contains($0) }.sorted()
    }

    /// Serialises the overrides; an empty map clears the setting.
    static func serialize(_ map: [String: Int]) -> String {
        map.isEmpty ? "" : settingsWorkflowCompactJSON(map)
    }
}

// MARK: - G-code snippets

/// Start/end g-code injected into queued prints for one printer model.
struct SettingsGcodeSnippet: Codable, Sendable, Hashable {
    var startGcode: String
    var endGcode: String

    enum CodingKeys: String, CodingKey {
        case startGcode = "start_gcode"
        case endGcode = "end_gcode"
    }

    init(startGcode: String = "", endGcode: String = "") {
        self.startGcode = startGcode
        self.endGcode = endGcode
    }

    var isEmpty: Bool {
        startGcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && endGcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The `gcode_snippets` setting: a JSON object keyed by printer model.
enum SettingsGcodeSnippets {
    static func parse(_ raw: String) -> [String: SettingsGcodeSnippet] {
        guard let object = settingsWorkflowParseJSON(raw)?.objectValue else { return [:] }
        var out: [String: SettingsGcodeSnippet] = [:]
        for (model, value) in object {
            guard value.objectValue != nil else { continue }
            let start = value["start_gcode"].flatMap { $0.isNull ? nil : $0.stringValue } ?? ""
            let end = value["end_gcode"].flatMap { $0.isNull ? nil : $0.stringValue } ?? ""
            out[model] = SettingsGcodeSnippet(startGcode: start, endGcode: end)
        }
        return out
    }

    /// Serialises the map, dropping models whose snippets are both empty. An empty map
    /// becomes an empty string (no injection configured).
    static func serialize(_ map: [String: SettingsGcodeSnippet]) -> String {
        let kept = map.filter { !$0.value.isEmpty }
        return kept.isEmpty ? "" : settingsWorkflowCompactJSON(kept)
    }
}
