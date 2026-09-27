import Foundation
import CoreTransferable
import UniformTypeIdentifiers

// Models for the empty-spool weight catalog (`/inventory/catalog`) and the filament color
// catalog (`/inventory/colors`).

/// An empty-spool weight entry (`CatalogEntryResponse`).
struct SettingsCatalogSpoolEntry: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var weight: Double
    var isDefault: Bool?
}

/// Body for creating/updating a spool weight entry (`CatalogEntryCreate` / `CatalogEntryUpdate`).
struct SettingsCatalogSpoolPayload: Codable, Sendable, Hashable {
    var name: String
    var weight: Int
}

/// A named filament color (`ColorEntryResponse`).
struct SettingsCatalogColorEntry: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var manufacturer: String
    var colorName: String
    var hexColor: String
    var material: String?
    var isDefault: Bool?
    /// Comma-separated extra gradient stops (hex without `#`), e.g. "ff0000,00ff00".
    var extraColors: String?
    var effectType: String?
}

/// Body for creating/updating a color entry (`ColorEntryCreate` / `ColorEntryUpdate`).
/// Optional fields are always sent (as null when empty) so an update can clear them.
struct SettingsCatalogColorPayload: Codable, Sendable, Hashable {
    var manufacturer: String
    var colorName: String
    var hexColor: String
    var material: String?
    var extraColors: String?
    var effectType: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(manufacturer, forKey: .manufacturer)
        try c.encode(colorName, forKey: .colorName)
        try c.encode(hexColor, forKey: .hexColor)
        try c.encode(material, forKey: .material)
        try c.encode(extraColors, forKey: .extraColors)
        try c.encode(effectType, forKey: .effectType)
    }
}

/// Body for the catalogs' bulk-delete endpoints.
struct SettingsCatalogBulkDelete: Codable, Sendable {
    var ids: [Int]
}

/// Response of the catalogs' bulk-delete endpoints.
struct SettingsCatalogBulkDeleteResult: Codable, Sendable {
    var deleted: Int?
}

/// One `data:` event of the color catalog sync stream (`POST /inventory/colors/sync`).
struct SettingsCatalogSyncEvent: Codable, Sendable {
    var type: String
    var added: Int?
    var skipped: Int?
    var totalFetched: Int?
    var totalAvailable: Int?
    var error: String?
}

enum SettingsCatalog {
    /// Visual effects accepted by the server for color entries.
    static let effectTypes: [(value: String, label: String)] = [
        ("sparkle", "Sparkle"), ("wood", "Wood"), ("marble", "Marble"), ("glow", "Glow in the Dark"),
        ("matte", "Matte"), ("silk", "Silk"), ("galaxy", "Galaxy"), ("rainbow", "Rainbow"),
        ("metal", "Metallic"), ("translucent", "Translucent"), ("gradient", "Gradient"),
        ("dual-color", "Dual Color"), ("tri-color", "Tri Color"), ("multicolor", "Multicolor"),
    ]

    static let maxExtraColorStops = 8

    static func effectLabel(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return effectTypes.first { $0.value == value }?.label ?? value.capitalized
    }

    /// `#RRGGBB` or `#RRGGBBAA` (the server's accepted format), normalised to upper case.
    static func normalizedHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, s.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + s.uppercased()
    }

    /// Validates a comma-separated list of 6/8-digit hex stops. Returns nil when valid.
    static func extraColorsError(_ raw: String) -> String? {
        let tokens = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if tokens.count > maxExtraColorStops { return "Use at most \(maxExtraColorStops) extra colors." }
        for token in tokens {
            let hex = token.hasPrefix("#") ? String(token.dropFirst()) : token
            if !(hex.count == 6 || hex.count == 8) || !hex.allSatisfy(\.isHexDigit) {
                return "\"\(token)\" isn't a 6- or 8-digit hex color."
            }
        }
        return nil
    }

    /// Parses one line of the sync event stream (`data: {...}`).
    static func parseSyncLine(_ line: String) -> SettingsCatalogSyncEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? APICoders.decoder.decode(SettingsCatalogSyncEvent.self, from: data)
    }

    // MARK: Import / export (same JSON shape as the web interface's files)

    struct SpoolRecord: Codable, Sendable {
        var name: String?
        var weight: Double?
    }

    struct ColorRecord: Codable, Sendable {
        var manufacturer: String?
        var colorName: String?
        var hexColor: String?
        var material: String?
        var extraColors: String?
        var effectType: String?
    }

    static func exportSpools(_ entries: [SettingsCatalogSpoolEntry]) -> Data {
        let records = entries.map { SpoolRecord(name: $0.name, weight: $0.weight) }
        return exportData(records)
    }

    static func exportColors(_ entries: [SettingsCatalogColorEntry]) -> Data {
        let records = entries.map {
            ColorRecord(manufacturer: $0.manufacturer, colorName: $0.colorName, hexColor: $0.hexColor,
                        material: $0.material, extraColors: $0.extraColors, effectType: $0.effectType)
        }
        return exportData(records)
    }

    private static func exportData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("[]".utf8)
    }

    static func importSpools(_ data: Data) throws -> [SpoolRecord] {
        try APICoders.decoder.decode([SpoolRecord].self, from: data)
    }

    static func importColors(_ data: Data) throws -> [ColorRecord] {
        try APICoders.decoder.decode([ColorRecord].self, from: data)
    }
}

/// Shareable JSON export of the spool weight catalog.
struct SettingsCatalogSpoolExport: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName("spool-catalog.json")
    }
}

/// Shareable JSON export of the color catalog.
struct SettingsCatalogColorExport: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName("color-catalog.json")
    }
}
