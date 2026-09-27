import Foundation

// MARK: - Spools

/// A filament spool, as returned by `GET inventory/spools` and — in Spoolman
/// mode — by `GET spoolman/inventory/spools` (which maps Spoolman data onto the
/// same shape but may emit nulls for timestamps and weights).
struct InventorySpool: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var material: String?
    var subtype: String?
    var colorName: String?
    var colorNameIsSynthesized: Bool?
    var rgba: String?
    var extraColors: String?
    var effectType: String?
    var brand: String?
    var labelWeight: Int?
    var coreWeight: Int?
    var coreWeightCatalogId: Int?
    var weightUsed: Double?
    var weightUsedBaseline: Double?
    var slicerFilament: String?
    var slicerFilamentName: String?
    var nozzleTempMin: Int?
    var nozzleTempMax: Int?
    var note: String?
    var tagUid: String?
    var trayUuid: String?
    var dataOrigin: String?
    var tagType: String?
    var costPerKg: Double?
    var weightLocked: Bool?
    var lastScaleWeight: Double?
    var lastWeighedAt: String?
    var category: String?
    var lowStockThresholdPct: Int?
    var storageLocation: String?
    var locationId: Int?
    var addedFull: Bool?
    var lastUsed: String?
    var encodeTime: String?
    var archivedAt: String?
    var createdAt: String?
    var updatedAt: String?
    var kProfiles: [InventorySpoolKProfile]?

    var materialName: String { (material ?? "").isEmpty ? "Unknown" : material! }
    var label: Double { Double(labelWeight ?? 0) }
    var used: Double { weightUsed ?? 0 }
    var core: Double { Double(coreWeight ?? 0) }
    var remainingGrams: Double { max(0, label - used) }
    /// Remaining filament as a 0–100 percentage of the label weight.
    var remainingPercent: Double { label > 0 ? remainingGrams / label * 100 : 0 }
    var grossGrams: Double { remainingGrams + core }
    /// The resettable "consumed" counter (usage since the last counter reset).
    var consumedGrams: Double { max(0, used - (weightUsedBaseline ?? 0)) }
    var isArchived: Bool { !(archivedAt ?? "").isEmpty }
    var isNew: Bool { used == 0 }
    var hasSlicerPreset: Bool { !(slicerFilament ?? "").isEmpty }
    var hasTag: Bool { !(tagUid ?? "").isEmpty || !(trayUuid ?? "").isEmpty }

    func isLowStock(globalThreshold: Double) -> Bool {
        let threshold = lowStockThresholdPct.map(Double.init) ?? globalThreshold
        return remainingPercent < threshold
    }

    /// "PLA Basic"
    var materialLine: String {
        [materialName, subtype].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Bambu PLA Basic · Jade White"
    var displayName: String {
        var parts = [brand, material, subtype].compactMap { $0 }.filter { !$0.isEmpty }
        if parts.isEmpty { parts = ["Spool #\(id)"] }
        let base = parts.joined(separator: " ")
        if let c = colorName, !c.isEmpty { return "\(base) · \(c)" }
        return base
    }

    /// Extra gradient stops (bare hex tokens).
    var extraColorStops: [String] {
        (extraColors ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "") }.filter { !$0.isEmpty }
    }

    /// Key used by "Group similar": identical, unused spools collapse into one row.
    var similarityKey: String {
        [materialName, subtype ?? "", brand ?? "", colorName ?? "", rgba ?? "", extraColors ?? "", effectType ?? "", String(labelWeight ?? 0)].joined(separator: "|")
    }

    func matches(search query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let fields: [String?] = [String(id), material, brand, colorName, subtype, note, slicerFilamentName, storageLocation]
        return fields.contains { ($0 ?? "").lowercased().contains(q) }
    }
}

struct InventorySpoolKProfile: Codable, Sendable, Hashable, Identifiable {
    var id: Int?
    var spoolId: Int?
    var printerId: Int
    var extruder: Int?
    var nozzleDiameter: String?
    var nozzleType: String?
    var kValue: Double
    var name: String?
    var caliIdx: Int?
    var settingId: String?
    var createdAt: String?

    var stableId: String { "\(printerId)-\(extruder ?? 0)-\(nozzleDiameter ?? "")-\(caliIdx ?? -1)" }
}

/// Body item for `PUT inventory/spools/{id}/k-profiles`.
struct InventoryKProfileInput: Codable, Sendable, Hashable {
    var printerId: Int
    var extruder: Int
    var nozzleDiameter: String
    var nozzleType: String?
    var kValue: Double
    var name: String?
    var caliIdx: Int?
    var settingId: String?
}

struct InventorySpoolFilamentPreset: Codable, Sendable, Hashable, Identifiable {
    var id: Int?
    var spoolId: Int?
    var printerModel: String
    var nozzleDiameter: String?
    var slicerFilament: String?
    var slicerFilamentName: String?
    var createdAt: String?
}

/// Body item for `PUT inventory/spools/{id}/filament-presets`.
struct InventoryFilamentPresetInput: Codable, Sendable, Hashable {
    var printerModel: String
    var nozzleDiameter: String
    var slicerFilament: String?
    var slicerFilamentName: String?
}

// MARK: - Assignments & usage

struct InventorySpoolAssignment: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var spoolId: Int
    var printerId: Int
    var printerName: String?
    var amsId: Int
    var trayId: Int
    var fingerprintColor: String?
    var fingerprintType: String?
    var createdAt: String?
    var spool: InventorySpool?
    var configured: Bool?
    var pendingConfig: Bool?
    var amsLabel: String?
}

/// `GET spoolman/inventory/slot-assignments/all` row.
struct InventorySpoolmanSlotAssignment: Codable, Sendable, Hashable {
    var printerId: Int
    var printerName: String?
    var amsId: Int
    var trayId: Int
    var spoolmanSpoolId: Int
    var amsLabel: String?
}

/// Where a spool currently sits in a printer (merged from both assignment kinds).
struct InventorySlotLocation: Sendable, Hashable {
    var printerId: Int
    var printerName: String?
    var amsId: Int
    var trayId: Int
    var amsLabel: String?
    var pendingConfig: Bool = false

    var isExternal: Bool { amsId == 254 || amsId == 255 }
    var isHT: Bool { !isExternal && amsId >= 128 }

    /// "A1", "HT-A", "Ext"
    var slotLabel: String {
        if isExternal { return trayId == 1 ? "Ext R" : "Ext" }
        let letterIndex = isHT ? amsId - 128 : amsId
        let letter = Character(UnicodeScalar(65 + max(0, min(letterIndex, 25)))!)
        if isHT { return "HT-\(letter)" }
        return "\(letter)\(trayId + 1)"
    }

    var description: String {
        var s = "\(printerName ?? "Printer \(printerId)") · \(slotLabel)"
        if let amsLabel, !amsLabel.isEmpty { s += " (\(amsLabel))" }
        return s
    }
}

struct InventoryUsageRecord: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var spoolId: Int
    var printerId: Int?
    var printName: String?
    var weightUsed: Double
    var percentUsed: Int?
    var status: String?
    var cost: Double?
    var createdAt: String
}

// MARK: - Catalogs

/// Empty-spool weight catalog entry (`inventory/catalog`).
struct InventorySpoolCatalogEntry: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var weight: Int
    var isDefault: Bool?
}

struct InventoryLocation: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var identifier: String?
    var spoolCount: Int?
    var createdAt: String?
    var updatedAt: String?
}

/// Color catalog entry (`inventory/colors`).
struct InventoryColorEntry: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var manufacturer: String
    var colorName: String
    var hexColor: String
    var material: String?
    var isDefault: Bool?
    var extraColors: String?
    var effectType: String?
}

/// Filament type catalog entry (`filament-catalog/`), used for cost tracking.
struct InventoryFilamentType: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var type: String
    var brand: String?
    var color: String?
    var colorHex: String?
    var costPerKg: Double?
    var spoolWeightG: Double?
    var currency: String?
    var density: Double?
    var printTempMin: Int?
    var printTempMax: Int?
    var bedTempMin: Int?
    var bedTempMax: Int?
    var createdAt: String?
    var updatedAt: String?
}

struct InventoryFilamentCost: Codable, Sendable, Hashable {
    var filamentId: Int
    var filamentName: String
    var weightGrams: Double
    var cost: Double
    var currency: String
}

// MARK: - Forecast / shopping list

struct InventorySkuSettings: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var material: String
    var subtype: String?
    var brand: String?
    var colorName: String?
    var leadTimeDays: Int?
    var safetyMarginValue: Int?
    var safetyMarginUnit: String?
    var alertsSnoozed: Bool?
}

struct InventoryShoppingItem: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var material: String
    var subtype: String?
    var brand: String?
    var colorName: String?
    var quantitySpools: Int?
    var note: String?
    var status: String?
    var purchasedAt: String?
    var addedAt: String?

    var label: String {
        [brand, material, subtype, colorName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Import

struct InventoryImportRow: Codable, Sendable, Hashable, Identifiable {
    var rowNumber: Int
    var status: String?
    var reason: String?
    var material: String?
    var brand: String?
    var colorName: String?
    var rgba: String?
    var resolvedColor: Bool?
    var crossMaterialColor: Bool?
    var duplicateOfExisting: Bool?
    var spool: JSONValue?
    var id: Int { rowNumber }
}

/// Union of `ImportPreview` (dry run) and `ImportResult` (commit).
struct InventoryImportResponse: Codable, Sendable, Hashable {
    // Preview
    var columns: [String]?
    var total: Int?
    var validCount: Int?
    var errorCount: Int?
    var skippedCount: Int?
    var rows: [InventoryImportRow]?
    var warnings: [String]?
    // Result
    var created: Int?
    var skipped: Int?
    var errors: Int?
    var errorRows: [InventoryImportRow]?
}

// MARK: - Spoolman

struct InventorySpoolmanStatus: Codable, Sendable, Hashable {
    var enabled: Bool
    var connected: Bool
    var url: String?
}

struct InventorySpoolmanSettings: Codable, Sendable, Hashable {
    var spoolmanEnabled: String?
    var spoolmanUrl: String?
    var spoolmanSyncMode: String?

    var isActive: Bool { spoolmanEnabled?.lowercased() == "true" && !(spoolmanUrl ?? "").isEmpty }
}

struct InventorySpoolmanFilament: Codable, Sendable, Hashable, Identifiable {
    struct Vendor: Codable, Sendable, Hashable { var id: Int?; var name: String? }
    var id: Int
    var name: String
    var material: String?
    var colorHex: String?
    var colorName: String?
    var weight: Int?
    var spoolWeight: Double?
    var vendor: Vendor?

    var label: String {
        [vendor?.name, name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct InventorySpoolmanSyncResult: Codable, Sendable, Hashable {
    var success: Bool?
    var syncedCount: Int?
    var skippedCount: Int?
    var errors: [String]?
}

// MARK: - Bulk responses

/// Covers the bulk update/delete/archive/restore/reset responses of both modes.
struct InventoryBulkResult: Codable, Sendable, Hashable {
    struct Failure: Codable, Sendable, Hashable { var id: Int?; var status: Int?; var detail: String? }
    var updated: Int?
    var deleted: Int?
    var archived: Int?
    var restored: Int?
    var reset: Int?
    var notFound: [Int]?
    var alreadyArchived: [Int]?
    var alreadyActive: [Int]?
    var errors: [Failure]?

    var failedCount: Int { (notFound?.count ?? 0) + (errors?.count ?? 0) }
    var succeeded: Int { updated ?? deleted ?? archived ?? restored ?? reset ?? 0 }
}

// MARK: - Slicer presets & printer K profiles

struct InventorySlicerSetting: Codable, Sendable, Hashable {
    var settingId: String
    var name: String
    var type: String?
    var isCustom: Bool?
}

struct InventoryBuiltinFilament: Codable, Sendable, Hashable {
    var filamentId: String
    var name: String
}

struct InventoryLocalPreset: Codable, Sendable, Hashable {
    var id: Int
    var name: String
    var presetType: String?
    var filamentType: String?
    var filamentVendor: String?
}

struct InventoryLocalPresets: Codable, Sendable, Hashable {
    var filament: [InventoryLocalPreset]?
}

/// A K (pressure advance) calibration stored on a printer.
struct InventoryPrinterKProfile: Codable, Sendable, Hashable {
    var slotId: Int
    var extruderId: Int?
    var nozzleId: String?
    var nozzleDiameter: String
    var filamentId: String?
    var name: String
    var kValue: String
    var nCoef: String?
    var amsId: Int?
    var trayId: Int?
    var settingId: String?
}

struct InventoryPrinterKProfiles: Codable, Sendable, Hashable {
    var profiles: [InventoryPrinterKProfile]
    var nozzleDiameter: String
}

/// A selectable slicer filament preset (merged from cloud, local and built-in sources).
struct InventoryPresetOption: Sendable, Hashable, Identifiable {
    enum Source: String, Sendable { case custom = "Custom", cloud = "Cloud", local = "Local", builtin = "Built-in" }
    var code: String
    var name: String
    var source: Source
    var alternateCodes: [String] = []
    var id: String { "\(source.rawValue):\(code)" }
}

// MARK: - Label printing

enum InventoryLabelTemplate: String, CaseIterable, Identifiable, Sendable {
    case amsHolderSmall = "ams_holder_74x33"
    case amsHolderLarge = "ams_holder_75x55"
    case box40x30 = "box_40x30"
    case box62x29 = "box_62x29"
    case averyL7160 = "avery_l7160"
    case avery5160 = "avery_5160"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .amsHolderSmall: "AMS Holder, Small"
        case .amsHolderLarge: "AMS Holder, Large"
        case .box40x30: "Box Label 40×30"
        case .box62x29: "Box Label 62×29"
        case .averyL7160: "Avery L7160 (A4)"
        case .avery5160: "Avery 5160 (Letter)"
        }
    }

    var detail: String {
        switch self {
        case .amsHolderSmall: "74 × 33 mm, one label per page"
        case .amsHolderLarge: "75 × 55 mm, one label per page"
        case .box40x30: "40 × 30 mm thermal label"
        case .box62x29: "62 × 29 mm continuous tape"
        case .averyL7160: "21 labels per A4 sheet (38.1 × 63.5 mm)"
        case .avery5160: "30 labels per US Letter sheet (25.4 × 66.7 mm)"
        }
    }

    /// Labels per sheet for sheet templates (nil for single-label printers).
    var sheetCapacity: Int? {
        switch self {
        case .averyL7160: 21
        case .avery5160: 30
        default: nil
        }
    }
}

struct InventoryLabelRequest: Codable, Sendable {
    var spoolIds: [Int]
    var template: String
    var monochrome: Bool
    var startingPosition: Int
}
