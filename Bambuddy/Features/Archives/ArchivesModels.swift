import Foundation

// Models for the Archives (print history) section. Every top-level type is
// prefixed `Archives…` to stay clear of other features that decode
// archive-shaped payloads. Dates are kept as raw strings (see `Fmt.date`).

/// A reference to another archive with the same content/name.
struct ArchivesDuplicate: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var printName: String?
    var createdAt: String?
    var matchType: String?
}

/// `ArchiveResponse` — one archived print (or uploaded 3MF).
struct ArchivesRecord: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var printerId: Int?
    var projectId: Int?
    var projectName: String?
    var filename: String?
    var filePath: String?
    var fileSize: Int?
    var contentHash: String?
    var thumbnailPath: String?
    var timelapsePath: String?
    var source3mfPath: String?
    var f3dPath: String?
    var duplicates: [ArchivesDuplicate]?
    var duplicateCount: Int?
    var duplicateSequence: Int?
    var originalArchiveId: Int?
    var objectCount: Int?
    var printName: String?
    var plateId: Int?
    var printTimeSeconds: Int?
    var actualTimeSeconds: Int?
    var timeAccuracy: Double?
    var filamentUsedGrams: Double?
    var filamentType: String?
    var filamentColor: String?
    var layerHeight: Double?
    var totalLayers: Int?
    var nozzleDiameter: Double?
    var bedTemperature: Int?
    var bedType: String?
    var nozzleTemperature: Int?
    var slicedForModel: String?
    var status: String?
    var startedAt: String?
    var completedAt: String?
    var extraData: JSONValue?
    var makerworldUrl: String?
    var designer: String?
    var externalUrl: String?
    var isFavorite: Bool?
    var tags: String?
    var notes: String?
    var cost: Double?
    var photos: [JSONValue]?
    var failureReason: String?
    var quantity: Int?
    var energyKwh: Double?
    var energyCost: Double?
    var createdAt: String?
    var createdById: Int?
    var createdByUsername: String?
    var runCount: Int?
    var lastRunAt: String?
    var totalFilamentActualGrams: Double?
    var successfulRunCount: Int?
    var failedRunCount: Int?

    // `source_3mf_path` contains a digit-led word, which the snake-case
    // strategy camel-cases as `source3MfPath`; spelled out explicitly.
    enum CodingKeys: String, CodingKey {
        case id, printerId, projectId, projectName, filename, filePath, fileSize, contentHash
        case thumbnailPath, timelapsePath
        case source3mfPath = "source3MfPath"
        case f3dPath = "f3dPath"
        case duplicates, duplicateCount, duplicateSequence, originalArchiveId, objectCount
        case printName, plateId, printTimeSeconds, actualTimeSeconds, timeAccuracy
        case filamentUsedGrams, filamentType, filamentColor, layerHeight, totalLayers
        case nozzleDiameter, bedTemperature, bedType, nozzleTemperature, slicedForModel
        case status, startedAt, completedAt, extraData, makerworldUrl, designer, externalUrl
        case isFavorite, tags, notes, cost, photos, failureReason, quantity, energyKwh, energyCost
        case createdAt, createdById, createdByUsername, runCount, lastRunAt
        case totalFilamentActualGrams, successfulRunCount, failedRunCount
    }

    // MARK: Derived values

    var displayName: String {
        let name = printName?.trimmingCharacters(in: .whitespaces) ?? ""
        if !name.isEmpty { return name }
        return filename ?? "Archive #\(id)"
    }

    var favorite: Bool { isFavorite ?? false }
    var statusValue: String { status ?? "" }
    var photoNames: [String] { photos?.compactMap(\.stringValue) ?? [] }

    var tagList: [String] {
        (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var materials: [String] {
        (filamentType ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var colors: [String] {
        (filamentColor ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Sliced (printable) files carry G-code; raw project 3MFs do not.
    var isSliced: Bool {
        if let lower = filename?.lowercased(), lower.hasSuffix(".gcode") || lower.contains(".gcode.") { return true }
        return (totalLayers ?? 0) > 0 || (printTimeSeconds ?? 0) > 0
    }

    var isFailed: Bool { status == "failed" || status == "aborted" }

    /// A print was attempted (regardless of outcome). `archived` means uploaded only.
    var wasPrinted: Bool { ["completed", "failed", "aborted", "cancelled", "stopped"].contains(statusValue) }

    var isDuplicate: Bool { (duplicateCount ?? 0) > 0 }

    var createdDate: Date? { createdAt.flatMap(APICoders.parseDate) }

    var externalLink: URL? {
        for raw in [externalUrl, makerworldUrl] {
            if let raw, !raw.isEmpty, let url = URL(string: raw) { return url }
        }
        return nil
    }

    /// Printer id + name of a saved slicer AMS mapping (from `extra_data`).
    var slicerAmsMappingPrinterId: Int? {
        guard let saved = extraData?["slicer_ams_mapping"], saved["mapping"]?.arrayValue != nil else { return nil }
        return saved["printer_id"]?.intValue
    }

    var no3mfReason: String? { extraData?["no_3mf_reason"]?.stringValue }
}

/// `ArchiveUpdate` PATCH body. Built as a raw JSON object so cleared values
/// are sent as explicit `null` (a synthesized Encodable would omit them).
struct ArchivesUpdate: Encodable, Sendable {
    var fields: [String: JSONValue] = [:]

    mutating func set(_ key: String, _ value: String?) { fields[key] = value.map(JSONValue.string) ?? .null }
    mutating func set(_ key: String, _ value: Int?) { fields[key] = value.map { .number(Double($0)) } ?? .null }
    mutating func set(_ key: String, _ value: Double?) { fields[key] = value.map(JSONValue.number) ?? .null }
    mutating func set(_ key: String, _ value: Bool) { fields[key] = .bool(value) }

    var isEmpty: Bool { fields.isEmpty }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(JSONValue.object(fields))
    }
}

// MARK: Plates

struct ArchivesPlateFilament: Codable, Sendable, Hashable {
    var slotId: Int?
    var type: String?
    var color: String?
    var usedGrams: Double?
    var usedMeters: Double?
    var usedInPlate: Bool?
}

struct ArchivesPlate: Codable, Sendable, Hashable, Identifiable {
    var index: Int
    var name: String?
    var objects: [String]?
    var objectCount: Int?
    var hasThumbnail: Bool?
    var thumbnailUrl: String?
    var printTimeSeconds: Double?
    var filamentUsedGrams: Double?
    var filaments: [ArchivesPlateFilament]?
    var bedType: String?

    var id: Int { index }
}

struct ArchivesPlatesInfo: Codable, Sendable, Hashable {
    var archiveId: Int?
    var filename: String?
    var plates: [ArchivesPlate]?
    var isMultiPlate: Bool?
    var hasGcode: Bool?
    var embeddedPrinter: String?
    var embeddedProcess: String?
}

// MARK: Print log

struct ArchivesLogEntry: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var archiveId: Int?
    var printName: String?
    var printerName: String?
    var printerId: Int?
    var status: String?
    var startedAt: String?
    var completedAt: String?
    var durationSeconds: Int?
    var filamentType: String?
    var filamentColor: String?
    var filamentUsedGrams: Double?
    var cost: Double?
    var energyKwh: Double?
    var energyCost: Double?
    var failureReason: String?
    var thumbnailPath: String?
    var createdById: Int?
    var createdByUsername: String?
    var createdAt: String?

    var colors: [String] {
        (filamentColor ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct ArchivesLogPage: Codable, Sendable, Hashable {
    var items: [ArchivesLogEntry]
    var total: Int?
}

/// `PrintLogEntryUpdate` — both keys optional; `failure_reason` may be null to clear.
struct ArchivesLogEntryUpdate: Encodable, Sendable {
    var status: String?
    var failureReason: String??

    enum CodingKeys: String, CodingKey { case status, failureReason }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(status, forKey: .status)
        if let failureReason {
            if let value = failureReason { try c.encode(value, forKey: .failureReason) } else { try c.encodeNil(forKey: .failureReason) }
        }
    }
}

// MARK: Misc responses

struct ArchivesTagCount: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var count: Int?
    var id: String { name }
}

struct ArchivesAffectedResponse: Codable, Sendable { var affected: Int? }

struct ArchivesDeleteImpact: Codable, Sendable, Hashable {
    var relatedQueueItems: Int?
    var currentlyPrinting: Int?
}

struct ArchivesNo3mfWarning: Codable, Sendable, Hashable {
    var hasFallback: Bool?
    var reason: String?
}

struct ArchivesPhotosResponse: Codable, Sendable {
    var status: String?
    var filename: String?
    var photos: [JSONValue]?
}

struct ArchivesTimelapseFile: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var path: String?
    var size: Int?
    var mtime: String?
    var kind: String?
    var id: String { path ?? name }
}

struct ArchivesTimelapseScanResult: Codable, Sendable {
    var status: String?
    var message: String?
    var filename: String?
    var availableFiles: [ArchivesTimelapseFile]?
}

struct ArchivesStatusMessage: Codable, Sendable {
    var status: String?
    var message: String?
    var filename: String?
}

struct ArchivesPrinterMedia: Codable, Sendable, Hashable {
    struct LocalTimelapse: Codable, Sendable, Hashable { var name: String?; var size: Int? }
    var archiveId: Int?
    var printerId: Int?
    var localTimelapse: LocalTimelapse?
    var remoteFiles: [ArchivesTimelapseFile]?
    var warnings: [String]?
}

struct ArchivesTimelapseInfo: Codable, Sendable, Hashable {
    var duration: Double?
    var width: Int?
    var height: Int?
    var fps: Double?
    var codec: String?
    var fileSize: Int?
    var hasAudio: Bool?
}

struct ArchivesProjectPageImage: Codable, Sendable, Hashable, Identifiable {
    var name: String?
    var path: String
    var url: String?
    var id: String { path }
}

struct ArchivesProjectPage: Codable, Sendable, Hashable {
    var title: String?
    var description: String?
    var designer: String?
    var designerUserId: String?
    var license: String?
    var copyright: String?
    var creationDate: String?
    var modificationDate: String?
    var origin: String?
    var profileTitle: String?
    var profileDescription: String?
    var profileCover: String?
    var profileUserId: String?
    var profileUserName: String?
    var designModelId: String?
    var designProfileId: String?
    var designRegion: String?
    var modelPictures: [ArchivesProjectPageImage]?
    var profilePictures: [ArchivesProjectPageImage]?
    var thumbnails: [ArchivesProjectPageImage]?
}

struct ArchivesSimilar: Codable, Sendable, Hashable, Identifiable {
    struct Brief: Codable, Sendable, Hashable {
        var id: Int
        var printName: String?
        var status: String?
        var createdAt: String?
    }
    var archive: Brief
    var matchReason: String?
    var matchScore: Double?
    var id: Int { archive.id }
}

// MARK: Compare

struct ArchivesComparison: Codable, Sendable, Hashable {
    struct Info: Codable, Sendable, Hashable, Identifiable {
        var id: Int
        var printName: String?
        var status: String?
        var createdAt: String?
        var printerId: Int?
        var projectName: String?
    }
    struct Field: Codable, Sendable, Hashable, Identifiable {
        var field: String
        var label: String?
        var unit: String?
        var values: [JSONValue]?
        var rawValues: [JSONValue]?
        var hasDifference: Bool?
        var id: String { field }
    }
    struct Insight: Codable, Sendable, Hashable {
        var field: String?
        var label: String?
        var insight: String?
        var successAvg: Double?
        var failedAvg: Double?
        var successValues: [JSONValue]?
        var failedValues: [JSONValue]?
    }
    struct Correlation: Codable, Sendable, Hashable {
        var hasBothOutcomes: Bool?
        var message: String?
        var successfulCount: Int?
        var failedCount: Int?
        var insights: [Insight]?
    }
    var archives: [Info]
    var comparison: [Field]?
    var differences: [Field]?
    var successCorrelation: Correlation?
}

// MARK: Purge

struct ArchivesPurgePreview: Codable, Sendable, Hashable {
    var count: Int?
    var totalBytes: Int?
    var sampleFilenames: [String]?
    var olderThanDays: Int?
}

struct ArchivesPurgeRequest: Encodable, Sendable {
    var olderThanDays: Int
    var purgeStats: Bool
}

struct ArchivesPurgeResult: Codable, Sendable {
    var deleted: Int?
    var purgeStats: Bool?
}

struct ArchivesPurgeSettings: Codable, Sendable, Hashable {
    var enabled: Bool?
    var days: Int?
    var purgeStats: Bool?
}

// MARK: Upload

struct ArchivesBulkUploadResult: Codable, Sendable {
    struct Uploaded: Codable, Sendable { var filename: String?; var id: Int?; var status: String? }
    struct Failure: Codable, Sendable { var filename: String?; var error: String? }
    var uploaded: Int?
    var failed: Int?
    var results: [Uploaded]?
    var errors: [Failure]?
}

// MARK: Lookups used by filters/pickers

struct ArchivesProjectOption: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var color: String?
    var status: String?
    var parentId: Int?
}

struct ArchivesUserOption: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var username: String
}

struct ArchivesAddToProjectBody: Encodable, Sendable { var archiveIds: [Int] }

struct ArchivesTagRenameBody: Encodable, Sendable { var newName: String }

// MARK: Vocabulary

enum ArchivesVocabulary {
    /// Failure reason keys accepted by the backend (stored verbatim).
    static let failureReasons: [(key: String, label: String)] = [
        ("adhesionFailure", "Bed adhesion failure"),
        ("spaghettiDetached", "Spaghetti / detached"),
        ("layerShift", "Layer shift"),
        ("cloggedNozzle", "Clogged nozzle"),
        ("filamentRunout", "Filament runout"),
        ("warping", "Warping"),
        ("stringing", "Stringing"),
        ("underExtrusion", "Under-extrusion"),
        ("powerFailure", "Power failure"),
        ("userCancelled", "Cancelled by user"),
        ("noStatusUpdate", "Lost printer status"),
        ("other", "Other"),
    ]

    static func failureLabel(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return failureReasons.first { $0.key == key }?.label ?? key
    }

    /// Statuses an archive can be edited to.
    static let editableStatuses = ["completed", "failed", "aborted", "printing"]
    /// Statuses a print-log entry can have.
    static let logStatuses = ["completed", "failed", "stopped", "cancelled", "skipped"]

    static func statusLabel(_ status: String?) -> String {
        switch status ?? "" {
        case "completed": "Completed"
        case "failed": "Failed"
        case "aborted": "Cancelled"
        case "cancelled": "Cancelled"
        case "stopped": "Stopped"
        case "printing": "Printing"
        case "archived": "Not Printed"
        case "skipped": "Skipped"
        case "": "Unknown"
        case let other: other.capitalized
        }
    }
}
