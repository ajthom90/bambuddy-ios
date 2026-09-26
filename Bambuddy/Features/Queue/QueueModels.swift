import Foundation

// MARK: - Queue items

/// A cross-model alternative on a queue item (the same job sliced for several models).
struct QueueVariantSummary: Codable, Sendable, Hashable {
    var libraryFileId: Int?
    var filename: String?
    var targetModel: String?
    var position: Int?
}

/// One row of `GET /queue/`.
struct QueueItem: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var printerId: Int?
    var targetModel: String?
    var targetLocation: String?
    var requiredFilamentTypes: [String]?
    var filamentOverrides: [JSONValue]?
    var waitingReason: String?
    var archiveId: Int?
    var libraryFileId: Int?
    var costCenterId: Int?
    var estimatedCost: Double?
    var position: Int?
    var scheduledTime: String?
    var requirePreviousSuccess: Bool?
    var autoOffAfter: Bool?
    var manualStart: Bool?
    var filamentShort: Bool?
    var skipFilamentCheck: Bool?
    var amsMapping: [Int]?
    var plateId: Int?
    var bedLevelling: String?
    var flowCali: String?
    var vibrationCali: Bool?
    var layerInspect: Bool?
    var timelapse: Bool?
    var useAms: Bool?
    var nozzleOffsetCali: String?
    var preheatOverride: String?
    var preheatChamberTargetOverride: Int?
    var status: String?
    var startedAt: String?
    var completedAt: String?
    var errorMessage: String?
    var createdAt: String?
    var archiveName: String?
    var archiveThumbnail: String?
    var archiveDeleted: Bool?
    var libraryFileName: String?
    var libraryFileThumbnail: String?
    var printerName: String?
    var printTimeSeconds: Int?
    var filamentUsedGrams: Double?
    var filamentType: String?
    var filamentColor: String?
    var layerHeight: Double?
    var nozzleDiameter: Double?
    var slicedForModel: String?
    var bedType: String?
    var archiveHasSlicerAmsMapping: Bool?
    var createdById: Int?
    var createdByUsername: String?
    var batchId: Int?
    var batchName: String?
    var variants: [QueueVariantSummary]?
    var beenJumped: Bool?
    var gcodeInjection: Bool?
    var cleanupLibraryAfterDispatch: Bool?
    var nozzleMapping: [Int]?
    var nozzleRackChoice: JSONValue?

    // MARK: Derived

    var state: String { status ?? "pending" }
    var isPending: Bool { state == "pending" }
    var isPrinting: Bool { state == "printing" }
    var isHistory: Bool { ["completed", "failed", "skipped", "cancelled"].contains(state) }
    var isStaged: Bool { manualStart == true }
    var isLibraryFile: Bool { libraryFileId != nil && archiveId == nil }

    var displayName: String {
        if let n = archiveName, !n.isEmpty { return n }
        if let n = libraryFileName, !n.isEmpty { return n }
        if let variants, let first = variants.first?.filename {
            return variants.count > 1 ? "\(first) +\(variants.count - 1) more" : first
        }
        if let archiveId { return "Archive #\(archiveId)" }
        if let libraryFileId { return "File #\(libraryFileId)" }
        return "Item #\(id)"
    }

    /// Where this job will run, as shown in rows ("Office Printer", "Any P1S @ Lab", "Unassigned").
    var targetLabel: String {
        if printerId == nil, let variants, variants.count > 1 {
            let models = variants.compactMap(\.targetModel).joined(separator: " / ")
            return "Any \(models)" + (targetLocation.map { " @ \($0)" } ?? "")
        }
        if printerId == nil, let model = targetModel, !model.isEmpty {
            var s = "Any \(model)"
            if let loc = targetLocation, !loc.isEmpty { s += " @ \(loc)" }
            if let types = requiredFilamentTypes, !types.isEmpty { s += " (\(types.joined(separator: ", ")))" }
            return s
        }
        guard let printerId else { return "Unassigned" }
        return printerName ?? "Printer #\(printerId)"
    }

    var isModelBased: Bool { printerId == nil && ((targetModel ?? "").isEmpty == false || (variants?.count ?? 0) > 1) }
    var isUnassigned: Bool { printerId == nil && !isModelBased }

    var scheduledDate: Date? { scheduledTime.flatMap(APICoders.parseDate) }

    /// Far-future placeholder dates (more than ~6 months out) mean "no specific time".
    var hasRealSchedule: Bool {
        guard let d = scheduledDate else { return false }
        return d.timeIntervalSinceNow < 180 * 86400
    }

    /// Thumbnail path (plate-specific when a plate is chosen).
    var thumbnailPath: String? {
        if archiveThumbnail != nil, let archiveId, archiveDeleted != true {
            if let plateId { return "archives/\(archiveId)/plate-thumbnail/\(plateId)" }
            return "archives/\(archiveId)/thumbnail"
        }
        if libraryFileThumbnail != nil, let libraryFileId {
            if let plateId { return "library/files/\(libraryFileId)/plate-thumbnail/\(plateId)" }
            return "library/files/\(libraryFileId)/thumbnail"
        }
        return nil
    }

    var source: PrintSource? {
        if let archiveId { return .archive(id: archiveId, name: displayName) }
        if let libraryFileId { return .libraryFile(id: libraryFileId, name: displayName) }
        return nil
    }

    /// The scheduler's "previous print failed" gate reason (#1818 resume banner).
    static let previousFailedReason = "Previous print failed or was aborted"
}

struct QueueBulkUpdateResult: Codable, Sendable {
    var updatedCount: Int?
    var skippedCount: Int?
    var message: String?
}

struct QueueDeleteResult: Codable, Sendable {
    var message: String?
    var deleted: Bool?
}

struct QueueResumeResult: Codable, Sendable {
    var acknowledged: Int?
    var restored: Int?
}

struct QueueUngroupResult: Codable, Sendable {
    var ungroupedCount: Int?
    var message: String?
}

// MARK: - Batches (orders)

struct QueueBatchPlate: Codable, Sendable, Hashable {
    var plateId: Int?
    var plateName: String?
    var quantityTarget: Int?
    var dispatched: Int?
    var remaining: Int?
    var pendingCount: Int?
    var printingCount: Int?
    var completedCount: Int?
    var failedCount: Int?
    var cancelledCount: Int?
    var skippedCount: Int?
    var actualCost: Double?
    var estimatedRemainingCost: Double?
    var filamentUsedGrams: Double?
    var printTimeSeconds: Int?
    var canDispatch: Bool?

    var label: String {
        if let plateName, !plateName.isEmpty { return plateName }
        if let plateId { return "Plate \(plateId)" }
        return "Whole file"
    }
}

struct QueueBatch: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String?
    var archiveId: Int?
    var libraryFileId: Int?
    var quantity: Int?
    var status: String?
    var createdAt: String?
    var completedAt: String?
    var createdById: Int?
    var createdByUsername: String?
    var projectId: Int?
    var dueDate: String?
    var notes: String?
    var pendingCount: Int?
    var printingCount: Int?
    var completedCount: Int?
    var failedCount: Int?
    var cancelledCount: Int?
    var skippedCount: Int?
    var hasTargets: Bool?
    var targetCount: Int?
    var remainingCount: Int?
    var dispatchableCount: Int?
    var actualCost: Double?
    var estimatedRemainingCost: Double?
    var filamentUsedGrams: Double?
    var printTimeSeconds: Int?
    var plates: [QueueBatchPlate]?
}

// MARK: - Plates & filament requirements (archive / library 3MF)

struct QueuePlateFilament: Codable, Sendable, Hashable {
    var slotId: Int?
    var type: String?
    var color: String?
    var usedGrams: Double?
    var usedMeters: Double?
}

struct QueuePlateInfo: Codable, Sendable, Hashable, Identifiable {
    var index: Int
    var name: String?
    var objects: [String]?
    var objectCount: Int?
    var hasThumbnail: Bool?
    var thumbnailUrl: String?
    var printTimeSeconds: Int?
    var filamentUsedGrams: Double?
    var filaments: [QueuePlateFilament]?
    var bedType: String?

    var id: Int { index }
    var label: String {
        if let name, !name.isEmpty { return "Plate \(index) · \(name)" }
        return "Plate \(index)"
    }
}

struct QueuePlatesResponse: Codable, Sendable {
    var plates: [QueuePlateInfo]?
    var isMultiPlate: Bool?
    var hasGcode: Bool?
}

/// One filament slot the 3MF needs (`slot_id` is 1-based, matching `ams_mapping` index + 1).
struct QueueFilamentRequirement: Codable, Sendable, Hashable {
    var slotId: Int?
    var type: String?
    var color: String?
    var usedGrams: Double?
    var usedMeters: Double?
    var trayInfoIdx: String?
    var usedInPlate: Bool?
    var nozzleId: Int?
    var groupId: Int?
}

struct QueueFilamentRequirements: Codable, Sendable {
    var filaments: [QueueFilamentRequirement]?
}

/// A filament currently loaded on some printer of a model (`GET printers/available-filaments`).
struct QueueAvailableFilament: Codable, Sendable, Hashable {
    var type: String?
    var color: String?
    var trayInfoIdx: String?
    var traySubBrands: String?
    var extruderId: Int?
}

// MARK: - Slicer pipelines

struct QueuePipelinePresetRef: Codable, Sendable, Hashable {
    var source: String
    var id: String
}

struct QueuePipeline: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var description: String?
    var printerPreset: QueuePipelinePresetRef?
    var processPreset: QueuePipelinePresetRef?
    var filamentPresets: [QueuePipelinePresetRef]?
    var bedType: String?
    var createdBy: Int?
    var createdAt: String?
    var updatedAt: String?
    var targetKind: String?
    var targetPrinterId: Int?
    var targetModelClass: String?
    var fanoutStrategy: String?

    var hasTarget: Bool {
        if targetKind == "printer_class" { return !(targetModelClass ?? "").isEmpty }
        return targetPrinterId != nil
    }
}

struct QueuePipelineList: Codable, Sendable {
    var pipelines: [QueuePipeline]?
}

struct QueuePipelineJob: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var pipelineRunId: Int?
    var copyIndex: Int?
    var assignedPrinterId: Int?
    var assignedPrinterName: String?
    var queueEntryId: Int?
    var status: String?
    var errorMessage: String?
    var dispatchedAt: String?
    var completedAt: String?
}

struct QueuePipelineRun: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var pipelineId: Int?
    var pipelineName: String?
    var sourceLibraryFileId: Int?
    var sourceArchiveId: Int?
    var sourceFilename: String?
    var parentRunId: Int?
    var copies: Int?
    var copiesCompleted: Int?
    var copiesFailed: Int?
    var copiesCancelled: Int?
    var copiesInProgress: Int?
    var status: String?
    var sliceJobId: Int?
    var slicedLibraryFileId: Int?
    var eligibilityOverridden: Bool?
    var errorMessage: String?
    var createdBy: Int?
    var createdAt: String?
    var startedAt: String?
    var completedAt: String?
    var jobs: [QueuePipelineJob]?
    var targetKind: String?
    var targetPrinterId: Int?
    var targetModelClass: String?
    var fanoutStrategy: String?

    static let inFlightStatuses: Set<String> = ["queued", "slicing", "dispatching", "in_progress"]
    var isInFlight: Bool { Self.inFlightStatuses.contains(status ?? "") }
    var canRetryFailed: Bool { status == "partial_failure" || status == "failed" }
    var cancelledByUser: Bool { status == "cancelled" && errorMessage == "Cancelled by user" }
}

struct QueuePipelineRunList: Codable, Sendable {
    var runs: [QueuePipelineRun]?
    var total: Int?
}

struct QueuePipelineClearResult: Codable, Sendable {
    var deleted: Int?
}

struct QueuePipelineIssue: Codable, Sendable, Hashable {
    var kind: String?
    var slotIndex: Int?
    var expected: String?
    var actual: String?

    var summary: String {
        let base: String
        switch kind {
        case "printer_not_set": base = "No target printer is set"
        case "printer_not_found": base = "Target printer not found"
        case "printer_disabled": base = "Target printer is disabled"
        case "printer_offline": base = "Target printer is offline"
        case "filament_type_mismatch": base = "Filament type mismatch"
        case "filament_color_mismatch": base = "Filament color mismatch"
        case "ams_slot_missing": base = "AMS slot is empty or missing"
        case "filament_unverified": base = "Loaded filament could not be verified"
        case "no_class_matches": base = "No printer of this class is eligible"
        case "class_not_set": base = "No printer class is set"
        default: base = (kind ?? "Issue").replacingOccurrences(of: "_", with: " ").capitalized
        }
        var parts = [base]
        if let slotIndex { parts.append("slot \(slotIndex + 1)") }
        if let expected, !expected.isEmpty { parts.append("expected \(expected)") }
        if let actual, !actual.isEmpty { parts.append("found \(actual)") }
        return parts.joined(separator: " · ")
    }
}

struct QueuePipelinePrinterReport: Codable, Sendable, Hashable {
    var printerId: Int?
    var printerName: String?
    var ok: Bool?
    var issues: [QueuePipelineIssue]?
}

struct QueuePipelineEligibility: Codable, Sendable {
    var ok: Bool?
    var targetKind: String?
    var targetPrinterId: Int?
    var targetPrinterName: String?
    var targetModelClass: String?
    var issues: [QueuePipelineIssue]?
    var printerReports: [QueuePipelinePrinterReport]?
}

/// A slicer preset as listed by `GET slicer/presets`.
struct QueueSlicerPreset: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var source: String?
    var filamentType: String?
    var filamentColour: String?
}

struct QueueSlicerPresetSlots: Codable, Sendable {
    var printer: [QueueSlicerPreset]?
    var process: [QueueSlicerPreset]?
    var filament: [QueueSlicerPreset]?
}

struct QueueSlicerPresetCatalog: Codable, Sendable {
    var orcaCloud: QueueSlicerPresetSlots?
    var cloud: QueueSlicerPresetSlots?
    var local: QueueSlicerPresetSlots?
    var standard: QueueSlicerPresetSlots?
    var cloudStatus: String?
    var orcaCloudStatus: String?

    static let sources: [(key: String, label: String)] = [
        ("local", "Imported"), ("orca_cloud", "Orca Cloud"), ("cloud", "Bambu Cloud"), ("standard", "Standard"),
    ]

    func slots(for source: String) -> QueueSlicerPresetSlots? {
        switch source {
        case "local": local
        case "orca_cloud": orcaCloud
        case "cloud": cloud
        case "standard": standard
        default: nil
        }
    }

    /// All presets of a slot kind ("printer", "process", "filament") in priority order.
    func all(_ slot: String) -> [QueueSlicerPreset] {
        Self.sources.flatMap { src -> [QueueSlicerPreset] in
            let bucket = slots(for: src.key)
            let list: [QueueSlicerPreset]
            switch slot {
            case "printer": list = bucket?.printer ?? []
            case "process": list = bucket?.process ?? []
            default: list = bucket?.filament ?? []
            }
            return list.map { var p = $0; if p.source == nil { p.source = src.key }; return p }
        }
    }

    func name(for ref: QueuePipelinePresetRef?, slot: String) -> String? {
        guard let ref else { return nil }
        let bucket = slots(for: ref.source)
        let list: [QueueSlicerPreset]?
        switch slot {
        case "printer": list = bucket?.printer
        case "process": list = bucket?.process
        default: list = bucket?.filament
        }
        return list?.first { $0.id == ref.id }?.name
    }

    static func sourceLabel(_ key: String) -> String {
        sources.first { $0.key == key }?.label ?? key
    }
}

// MARK: - Display helpers

enum QueueStatusStyle {
    static func label(_ status: String) -> String {
        switch status {
        case "pending": "Pending"
        case "printing": "Printing"
        case "completed": "Completed"
        case "failed": "Failed"
        case "skipped": "Skipped"
        case "cancelled": "Cancelled"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func systemImage(_ status: String) -> String {
        switch status {
        case "pending": "clock"
        case "printing": "play.circle"
        case "completed": "checkmark.circle"
        case "failed": "xmark.circle"
        case "skipped": "forward.end"
        case "cancelled": "xmark"
        default: "circle"
        }
    }

    static func pipelineLabel(_ status: String) -> String {
        switch status {
        case "in_progress": "In Progress"
        case "partial_failure": "Partial Failure"
        case "awaiting_printer": "Awaiting Printer"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

enum QueueCalibrationMode: String, CaseIterable, Identifiable, Sendable {
    case off, auto, on
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Mirrors the server's G-code interchange families: a file sliced for one model may
/// only be dispatched to the same model or one in its family.
enum QueueModelCompat {
    private static let families: [Set<String>] = [["X1", "X1C", "X1E", "P1P", "P1S"]]
    static let dualNozzleModels: Set<String> = ["H2D", "H2DPRO", "H2C", "X2D"]

    static func normalize(_ m: String) -> String {
        m.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
    }

    static func isCompatible(slicedFor: String?, target: String?) -> Bool {
        guard let slicedFor, let target, !slicedFor.isEmpty, !target.isEmpty else { return true }
        let a = normalize(slicedFor), b = normalize(target)
        if a == b { return true }
        return families.contains { $0.contains(a) && $0.contains(b) }
    }
}
