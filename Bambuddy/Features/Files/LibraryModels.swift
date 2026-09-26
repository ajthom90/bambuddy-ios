import Foundation
import SwiftUI

// Models for the library file manager (`/library/*`), trash, tags, variant
// groups and slicing. Dates are kept as raw strings and formatted with `Fmt`.
// Durations are decoded as `Double` because the backend copies them out of
// loosely-typed 3MF metadata.

// MARK: Folders

/// A node of `GET library/folders` (FolderTreeItem).
struct LibraryFolderNode: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var parentId: Int?
    var projectId: Int?
    var archiveId: Int?
    var projectName: String?
    var archiveName: String?
    var isExternal: Bool?
    var externalPath: String?
    var externalReadonly: Bool?
    var fileCount: Int?
    var latestActivityAt: String?
    var children: [LibraryFolderNode]?

    var external: Bool { isExternal ?? false }
    var readOnly: Bool { external && (externalReadonly ?? false) }
    var isLinked: Bool { projectId != nil || archiveId != nil }
    var subfolders: [LibraryFolderNode] { children ?? [] }
    var linkDescription: String? {
        if let projectName { return "Project: \(projectName)" }
        if let archiveName { return "Archive: \(archiveName)" }
        if projectId != nil { return "Linked to a project" }
        if archiveId != nil { return "Linked to an archive" }
        return nil
    }
}

/// `FolderResponse` — returned by folder create / update / get.
struct LibraryFolderInfo: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var parentId: Int?
    var projectId: Int?
    var archiveId: Int?
    var projectName: String?
    var archiveName: String?
    var isExternal: Bool?
    var externalPath: String?
    var externalReadonly: Bool?
    var externalShowHidden: Bool?
    var fileCount: Int?
    var latestActivityAt: String?
    var createdAt: String?
    var updatedAt: String?
}

struct LibraryFolderReadme: Decodable, Hashable, Sendable {
    var filename: String?
    var content: String?
    var truncated: Bool?
}

struct LibraryScanResult: Decodable, Sendable {
    var status: String?
    var added: Int?
    var removed: Int?
}

/// Flattened folder entry for pickers.
struct LibraryFlatFolder: Identifiable, Hashable, Sendable {
    let node: LibraryFolderNode
    let depth: Int
    var id: Int { node.id }
}

enum LibraryFolderTree {
    static func flatten(_ nodes: [LibraryFolderNode], depth: Int = 0) -> [LibraryFlatFolder] {
        nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .flatMap { [LibraryFlatFolder(node: $0, depth: depth)] + flatten($0.subfolders, depth: depth + 1) }
    }

    static func find(_ id: Int, in nodes: [LibraryFolderNode]) -> LibraryFolderNode? {
        for node in nodes {
            if node.id == id { return node }
            if let hit = find(id, in: node.subfolders) { return hit }
        }
        return nil
    }

    /// Root-to-node chain (inclusive), for breadcrumbs.
    static func path(to id: Int, in nodes: [LibraryFolderNode]) -> [LibraryFolderNode] {
        for node in nodes {
            if node.id == id { return [node] }
            let sub = path(to: id, in: node.subfolders)
            if !sub.isEmpty { return [node] + sub }
        }
        return []
    }

    /// Ids of a folder and all its descendants (a folder cannot move into these).
    static func descendantIds(of id: Int, in nodes: [LibraryFolderNode]) -> Set<Int> {
        guard let node = find(id, in: nodes) else { return [id] }
        var ids: Set<Int> = [id]
        func walk(_ n: LibraryFolderNode) { for c in n.subfolders { ids.insert(c.id); walk(c) } }
        walk(node)
        return ids
    }
}

// MARK: Files

struct LibraryTagRef: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
}

/// Row of `GET library/files` (FileListResponse).
struct LibraryFileSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var folderId: Int?
    var isExternal: Bool?
    var filename: String
    var fileType: String?
    var fileSize: Int64?
    var thumbnailPath: String?
    var printCount: Int?
    var duplicateCount: Int?
    var createdById: Int?
    var createdByUsername: String?
    var createdAt: String?
    var fsModifiedAt: String?
    var printName: String?
    var printTimeSeconds: Double?
    var filamentUsedGrams: Double?
    var slicedForModel: String?
    var tags: [LibraryTagRef]?
    var variantGroupId: Int?
    var variantCount: Int?

    var displayName: String {
        if let printName, !printName.isEmpty { return printName }
        return filename
    }
    var modifiedAt: String? { fsModifiedAt ?? createdAt }
    var isSliced: Bool { LibraryFileKind.isSliced(filename: filename, fileType: fileType) }
    var type: String { fileType ?? LibraryFileKind.type(of: filename) }
}

struct LibraryFileDuplicate: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var filename: String?
    var folderId: Int?
    var folderName: String?
    var createdAt: String?
}

/// `GET library/files/{id}` (FileResponse).
struct LibraryFileDetail: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var folderId: Int?
    var folderName: String?
    var projectId: Int?
    var projectName: String?
    var isExternal: Bool?
    var filename: String
    var filePath: String?
    var fileType: String?
    var fileSize: Int64?
    var fileHash: String?
    var thumbnailPath: String?
    var metadata: JSONValue?
    var printCount: Int?
    var lastPrintedAt: String?
    var notes: String?
    var duplicates: [LibraryFileDuplicate]?
    var duplicateCount: Int?
    var createdById: Int?
    var createdByUsername: String?
    var createdAt: String?
    var updatedAt: String?
    var printName: String?
    var printTimeSeconds: Double?
    var filamentUsedGrams: Double?
    var slicedForModel: String?

    var displayName: String {
        if let printName, !printName.isEmpty { return printName }
        return filename
    }
    var isSliced: Bool { LibraryFileKind.isSliced(filename: filename, fileType: fileType) }
    var type: String { fileType ?? LibraryFileKind.type(of: filename) }
}

/// Classification helpers mirroring the server's file-type rules.
enum LibraryFileKind {
    static func type(of filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".gcode.3mf") { return "gcode.3mf" }
        return (lower as NSString).pathExtension
    }

    /// A sliced file carries printer-ready G-code (either by content-derived
    /// type or by name).
    static func isSliced(filename: String, fileType: String?) -> Bool {
        let t = (fileType ?? "").lowercased()
        if t == "gcode" || t == "gcode.3mf" { return true }
        let lower = filename.lowercased()
        return lower.hasSuffix(".gcode") || lower.hasSuffix(".gcode.3mf")
    }

    /// Can the server-side slicer take this file as input (STL / 3MF, not already sliced)?
    static func isSliceable(filename: String, fileType: String?) -> Bool {
        if isSliced(filename: filename, fileType: fileType) { return false }
        let lower = filename.lowercased()
        return lower.hasSuffix(".stl") || lower.hasSuffix(".3mf")
    }

    /// Mesh formats the on-device 3D preview can render.
    static func isMesh(filename: String) -> Bool {
        ["stl", "obj", "ply"].contains((filename as NSString).pathExtension.lowercased())
    }

    static func color(for type: String) -> Color {
        switch type.lowercased() {
        case "3mf": .green
        case "gcode", "gcode.3mf": .blue
        case "stl": .purple
        case "zip": .orange
        default: .gray
        }
    }

    static func icon(for type: String) -> String {
        switch type.lowercased() {
        case "gcode", "gcode.3mf": "printer"
        case "3mf", "stl", "obj", "step", "stp": "cube"
        case "zip": "doc.zipper"
        case "png", "jpg", "jpeg": "photo"
        case "md", "txt": "doc.text"
        default: "doc"
        }
    }

    /// Characters Bambu Studio refuses in file names (FAT32/exFAT-illegal).
    static func invalidCharacter(in name: String) -> Character? {
        name.first { "<>:\"/\\|?*".contains($0) || ($0.asciiValue.map { $0 < 0x20 } ?? false) }
    }

    /// Splits `name.gcode.3mf` into ("name", ".gcode.3mf").
    static func splitExtension(_ filename: String) -> (base: String, ext: String) {
        let lower = filename.lowercased()
        for ext in [".gcode.3mf", ".3mf", ".gcode", ".stl", ".step", ".stp", ".obj", ".zip"] where lower.hasSuffix(ext) && lower.count > ext.count {
            return (String(filename.dropLast(ext.count)), String(filename.suffix(ext.count)))
        }
        return (filename, "")
    }
}

// MARK: Plates & filaments

struct LibraryPlateFilament: Decodable, Hashable, Sendable {
    var slotId: Int?
    var type: String?
    var color: String?
    var usedGrams: Double?
    var usedMeters: Double?
    var usedInPlate: Bool?
}

struct LibraryPlate: Decodable, Identifiable, Hashable, Sendable {
    var index: Int
    var name: String?
    var objects: [String]?
    var objectCount: Int?
    var hasThumbnail: Bool?
    var thumbnailUrl: String?
    var printTimeSeconds: Double?
    var filamentUsedGrams: Double?
    var filaments: [LibraryPlateFilament]?
    var id: Int { index }
}

/// `GET library/files/{id}/plates` (untyped dict on the server).
struct LibraryPlatesResponse: Decodable, Hashable, Sendable {
    var fileId: Int?
    var filename: String?
    var plates: [LibraryPlate]?
    var isMultiPlate: Bool?
    var embeddedPrinter: String?
    var embeddedProcess: String?
}

/// `GET library/files/{id}/filament-requirements`.
struct LibraryFilamentRequirements: Decodable, Hashable, Sendable {
    var fileId: Int?
    var filename: String?
    var plateId: Int?
    var filaments: [LibraryPlateFilament]?
}

// MARK: Stats

struct LibraryStats: Decodable, Hashable, Sendable {
    var totalFiles: Int?
    var totalFolders: Int?
    var totalSizeBytes: Int64?
    var filesByType: JSONValue?
    var totalPrints: Int?
    var diskFreeBytes: Int64?
    var diskTotalBytes: Int64?
    var diskUsedBytes: Int64?
}

// MARK: Tags

struct LibraryTag: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var fileCount: Int?
    var createdAt: String?
    var updatedAt: String?
}

struct LibraryTagAssignResult: Decodable, Sendable {
    var filesUpdated: Int?
    var associationsAdded: Int?
    var associationsRemoved: Int?
}

// MARK: Uploads

struct LibraryUploadResult: Decodable, Sendable {
    let id: Int
    var filename: String?
    var fileType: String?
    var fileSize: Int64?
    var thumbnailPath: String?
    var duplicateOf: Int?
    var metadata: JSONValue?
}

struct LibraryZipExtracted: Decodable, Hashable, Sendable {
    var filename: String?
    var fileId: Int?
    var folderId: Int?
}

struct LibraryZipFailure: Decodable, Hashable, Sendable {
    var filename: String?
    var error: String?
}

struct LibraryZipResult: Decodable, Sendable {
    var extracted: Int?
    var foldersCreated: Int?
    var files: [LibraryZipExtracted]?
    var errors: [LibraryZipFailure]?
}

// MARK: Bulk operations

struct LibraryBulkDeleteResult: Decodable, Sendable {
    var deletedFiles: Int?
    var deletedFolders: Int?
}

struct LibraryMoveResult: Decodable, Sendable {
    var status: String?
    var moved: Int?
}

struct LibraryQueueAddResult: Decodable, Sendable {
    struct Added: Decodable, Hashable, Sendable {
        var fileId: Int?
        var filename: String?
        var queueItemId: Int?
    }
    struct Failure: Decodable, Hashable, Sendable {
        var fileId: Int?
        var filename: String?
        var error: String?
    }
    var added: [Added]?
    var errors: [Failure]?
}

struct LibraryThumbnailBatchResult: Decodable, Sendable {
    struct Entry: Decodable, Hashable, Sendable {
        var fileId: Int?
        var filename: String?
        var success: Bool?
        var error: String?
    }
    var processed: Int?
    var succeeded: Int?
    var failed: Int?
    var results: [Entry]?
}

struct LibraryDeleteFileResult: Decodable, Sendable {
    var status: String?
    var message: String?
    var trashed: Bool?
}

// MARK: Variant groups

struct LibraryVariantMember: Decodable, Identifiable, Hashable, Sendable {
    var libraryFileId: Int
    var filename: String?
    var targetModel: String?
    var position: Int?
    var id: Int { libraryFileId }
}

struct LibraryVariantGroup: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String?
    var members: [LibraryVariantMember]?
}

// MARK: Trash & purge

struct LibraryTrashItem: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var filename: String
    var fileSize: Int64?
    var thumbnailPath: String?
    var folderId: Int?
    var folderName: String?
    var createdById: Int?
    var createdByUsername: String?
    var deletedAt: String?
    var autoPurgeAt: String?
}

struct LibraryTrashPage: Decodable, Sendable {
    var items: [LibraryTrashItem]
    var total: Int?
    var retentionDays: Int?
}

struct LibraryTrashSettings: Codable, Hashable, Sendable {
    var retentionDays: Int
    var autoPurgeEnabled: Bool?
    var autoPurgeDays: Int?
    var autoPurgeIncludeNeverPrinted: Bool?
}

struct LibraryEmptyTrashResult: Decodable, Sendable {
    var deleted: Int?
}

struct LibraryPurgePreview: Decodable, Hashable, Sendable {
    var count: Int
    var totalBytes: Int64?
    var sampleFilenames: [String]?
    var olderThanDays: Int?
    var includeNeverPrinted: Bool?
}

struct LibraryPurgeResult: Decodable, Sendable {
    var movedToTrash: Int?
}

// MARK: Slicing

struct LibrarySlicerPreset: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var source: String
    var filamentType: String?
    var filamentColour: String?
    var compatiblePrinters: [String]?

    /// Unique across tiers (ids are only unique within a source).
    var key: String { "\(source):\(id)" }
}

struct LibrarySlicerPresetSlots: Decodable, Hashable, Sendable {
    var printer: [LibrarySlicerPreset]?
    var process: [LibrarySlicerPreset]?
    var filament: [LibrarySlicerPreset]?
}

/// `GET slicer/presets`.
struct LibrarySlicerPresetCatalog: Decodable, Sendable {
    var orcaCloud: LibrarySlicerPresetSlots?
    var cloud: LibrarySlicerPresetSlots?
    var local: LibrarySlicerPresetSlots?
    var standard: LibrarySlicerPresetSlots?
    var cloudStatus: String?
    var orcaCloudStatus: String?

    private var tiers: [LibrarySlicerPresetSlots] { [orcaCloud, cloud, local, standard].compactMap { $0 } }
    var printers: [LibrarySlicerPreset] { tiers.flatMap { $0.printer ?? [] } }
    var processes: [LibrarySlicerPreset] { tiers.flatMap { $0.process ?? [] } }
    var filaments: [LibrarySlicerPreset] { tiers.flatMap { $0.filament ?? [] } }
}

struct LibrarySliceEnqueued: Decodable, Sendable {
    var jobId: Int
    var status: String?
    var statusUrl: String?
}

struct LibrarySliceProgress: Decodable, Hashable, Sendable {
    var stage: String?
    var totalPercent: Double?
    var platePercent: Double?
    var plateIndex: Int?
    var plateCount: Int?
    var multiPlateIndex: Int?
    var multiPlateCount: Int?
}

/// `GET slice-jobs/{id}`.
struct LibrarySliceJob: Decodable, Sendable {
    var jobId: Int
    var status: String
    var kind: String?
    var sourceId: Int?
    var sourceName: String?
    var createdAt: String?
    var startedAt: String?
    var completedAt: String?
    var progress: LibrarySliceProgress?
    /// SliceResponse (raw keys): library_file_id, name, print_time_seconds, filament_used_g, …
    var result: JSONValue?
    var errorStatus: Int?
    var errorDetail: String?

    var isFinished: Bool { status == "completed" || status == "failed" }
    var resultFileId: Int? { result?["library_file_id"]?.intValue }
}

/// Subset of server settings the file manager needs.
struct LibraryServerSettings: Decodable, Sendable {
    var useSlicerApi: Bool?
    var libraryDiskWarningGb: Double?
    var preferredSlicer: String?
}

/// Minimal project / archive rows used for linking pickers.
struct LibraryProjectOption: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var status: String?
    var color: String?
}

struct LibraryArchiveOption: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var printName: String?
    var filename: String?
    var displayName: String { printName?.isEmpty == false ? printName! : (filename ?? "Archive #\(id)") }
}

// MARK: Request bodies

struct LibraryFolderCreateBody: Encodable, Sendable {
    var name: String
    var parentId: Int?
}

struct LibraryFolderUpdateBody: Encodable, Sendable {
    var name: String?
    /// `0` moves to the root.
    var parentId: Int?
    /// `0` unlinks.
    var projectId: Int?
    /// `0` unlinks.
    var archiveId: Int?
}

struct LibraryExternalFolderBody: Encodable, Sendable {
    var name: String
    var externalPath: String
    var readonly: Bool
    var showHidden: Bool
    var parentId: Int?
}

struct LibraryFileUpdateBody: Encodable, Sendable {
    var filename: String?
    /// `0` moves to the root.
    var folderId: Int?
    /// `0` unlinks.
    var projectId: Int?
    /// Empty string clears the notes.
    var notes: String?
}

struct LibraryFileMoveBody: Encodable, Sendable {
    var fileIds: [Int]
    var folderId: Int?

    // `folder_id: null` means "root" and must be sent explicitly.
    enum CodingKeys: String, CodingKey { case fileIds, folderId }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fileIds, forKey: .fileIds)
        try c.encode(folderId, forKey: .folderId)
    }
}

struct LibraryBulkDeleteBody: Encodable, Sendable {
    var fileIds: [Int]
    var folderIds: [Int]
}

struct LibraryFileIdsBody: Encodable, Sendable {
    var fileIds: [Int]
}

struct LibraryTagNameBody: Encodable, Sendable {
    var name: String
}

struct LibraryTagAssignBody: Encodable, Sendable {
    var fileIds: [Int]
    var tagIds: [Int]
    /// `add`, `remove` or `replace`.
    var action: String
}

struct LibraryThumbnailBatchBody: Encodable, Sendable {
    var fileIds: [Int]?
    var folderId: Int?
    var allMissing: Bool?
}

struct LibraryPurgeBody: Encodable, Sendable {
    var olderThanDays: Int
    var includeNeverPrinted: Bool
}

struct LibraryVariantGroupCreateBody: Encodable, Sendable {
    struct Member: Encodable, Sendable { var libraryFileId: Int }
    var members: [Member]
}

struct LibraryPresetRefBody: Encodable, Hashable, Sendable {
    var source: String
    var id: String
}

struct LibrarySliceBody: Encodable, Sendable {
    var printerPreset: LibraryPresetRefBody
    var processPreset: LibraryPresetRefBody
    var filamentPreset: LibraryPresetRefBody
    var filamentPresets: [LibraryPresetRefBody]
    var filamentColours: [String]?
    var plate: Int?
    var bedType: String?
    var useEmbeddedSettings: Bool?
    var autoOrient: Bool?
    var autoArrange: Bool?
}
