import Foundation
import SwiftUI

// MARK: - List

/// A card in the projects list (`GET projects/`, `GET projects/templates`).
struct ProjectListEntry: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var description: String?
    var color: String?
    var status: String
    var targetCount: Int?
    var targetPartsCount: Int?
    var targetSets: Int?
    var budget: Double?
    var tags: String?
    var dueDate: String?
    var priority: String?
    var createdAt: String?
    var archiveCount: Int?
    var totalItems: Int?
    var completedCount: Int?
    var failedCount: Int?
    var queueCount: Int?
    var progressPercent: Double?
    var parentId: Int?
    var childCount: Int?
    var archives: [ProjectArchivePreview]?
    var url: String?
    var coverImageFilename: String?
}

struct ProjectArchivePreview: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var printName: String?
    var thumbnailPath: String?
    var status: String?
    var filamentType: String?
    var filamentColor: String?
}

// MARK: - Detail

struct ProjectDetail: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var description: String?
    var color: String?
    var status: String
    var targetCount: Int?
    var targetPartsCount: Int?
    var targetSets: Int?
    var notes: String?
    var attachments: [ProjectAttachment]?
    var tags: String?
    var dueDate: String?
    var priority: String?
    var budget: Double?
    var isTemplate: Bool?
    var templateSourceId: Int?
    var parentId: Int?
    var parentName: String?
    var children: [ProjectChildSummary]?
    var descendantCount: Int?
    var createdAt: String?
    var updatedAt: String?
    var stats: ProjectStatsInfo?
    var rollupStats: ProjectStatsInfo?
    var url: String?
    var coverImageFilename: String?
}

struct ProjectStatsInfo: Codable, Sendable, Hashable {
    var totalArchives: Int?
    var totalItems: Int?
    var completedPrints: Int?
    var failedPrints: Int?
    var queuedPrints: Int?
    var inProgressPrints: Int?
    var totalPrintTimeHours: Double?
    var totalFilamentGrams: Double?
    var progressPercent: Double?
    var partsProgressPercent: Double?
    var estimatedCost: Double?
    var totalEnergyKwh: Double?
    var totalEnergyCost: Double?
    var remainingPrints: Int?
    var remainingParts: Int?
    var bomTotalItems: Int?
    var bomCompletedItems: Int?
    var bomCost: Double?

    /// Filament + energy + sourced parts.
    var totalCost: Double { (estimatedCost ?? 0) + (totalEnergyCost ?? 0) + (bomCost ?? 0) }
}

struct ProjectChildSummary: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var color: String?
    var status: String?
    var progressPercent: Double?
    var descendantCount: Int?
    var totalArchives: Int?
    var completedPrints: Int?
    var totalPrintTimeHours: Double?
    var totalFilamentGrams: Double?
    var totalCost: Double?
}

struct ProjectAttachment: Codable, Sendable, Hashable, Identifiable {
    var filename: String?
    var originalName: String?
    var size: Int?
    var uploadedAt: String?

    var id: String { filename ?? originalName ?? UUID().uuidString }
    var displayName: String { originalName ?? filename ?? "Attachment" }
}

struct ProjectFileProgressEntry: Codable, Sendable, Hashable {
    var fileId: Int
    var completedCount: Int
}

// MARK: - Parts (BOM)

struct ProjectBOMItem: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var projectId: Int?
    var name: String
    var quantityNeeded: Int
    var quantityAcquired: Int
    var unitPrice: Double?
    var sourcingUrl: String?
    var archiveId: Int?
    var archiveName: String?
    var stlFilename: String?
    var remarks: String?
    var sortOrder: Int?
    var isComplete: Bool?
    var createdAt: String?
    var updatedAt: String?

    var complete: Bool { isComplete ?? (quantityAcquired >= quantityNeeded) }
}

// MARK: - Timeline

struct ProjectTimelineEvent: Codable, Sendable, Hashable, Identifiable {
    var eventType: String
    var timestamp: String
    var title: String
    var description: String?
    var metadata: JSONValue?

    var id: String { "\(eventType)|\(timestamp)|\(title)" }
}

// MARK: - Linked archives

/// The subset of an archive record the project screen renders
/// (`GET projects/{id}/archives`, `GET archives/`).
struct ProjectArchiveEntry: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var printerId: Int?
    var projectId: Int?
    var projectName: String?
    var filename: String?
    var thumbnailPath: String?
    var printName: String?
    var plateId: Int?
    var printTimeSeconds: Int?
    var filamentUsedGrams: Double?
    var filamentType: String?
    var filamentColor: String?
    var status: String?
    var startedAt: String?
    var completedAt: String?
    var quantity: Int?
    var cost: Double?
    var createdAt: String?
    var createdByUsername: String?

    var displayName: String { printName ?? filename ?? "Print #\(id)" }
}

// MARK: - Linked library folders & files

struct ProjectLibraryFolder: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var parentId: Int?
    var projectId: Int?
    var projectName: String?
    var isExternal: Bool?
    var fileCount: Int?
    var createdAt: String?
    var updatedAt: String?
}

/// `GET library/folders/` returns a tree; flattened for the folder picker.
struct ProjectLibraryFolderNode: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var parentId: Int?
    var projectId: Int?
    var projectName: String?
    var fileCount: Int?
    var children: [ProjectLibraryFolderNode]?

    func flattened(depth: Int = 0) -> [(node: ProjectLibraryFolderNode, depth: Int)] {
        [(self, depth)] + (children ?? []).flatMap { $0.flattened(depth: depth + 1) }
    }
}

struct ProjectLibraryFile: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var folderId: Int?
    var filename: String
    var fileType: String?
    var fileSize: Int?
    var thumbnailPath: String?
    var printCount: Int?
    var createdAt: String?
    var printName: String?
    var printTimeSeconds: Int?
    var filamentUsedGrams: Double?

    var displayName: String { printName ?? filename }

    /// Sliced output (gcode / gcode.3mf) can be sent to a printer directly.
    var isPrintable: Bool {
        let type = (fileType ?? "").lowercased()
        if type == "gcode" || type == "gcode.3mf" { return true }
        let lower = filename.lowercased()
        return lower.hasSuffix(".gcode") || lower.hasSuffix(".gcode.3mf")
    }
}

// MARK: - Uploads

struct ProjectUploadResult: Decodable, Sendable {
    var status: String?
    var filename: String?
    var originalName: String?
    var attachments: [ProjectAttachment]?
}

// MARK: - Request bodies

/// Builds the JSON body for `POST projects/` and `PATCH projects/{id}`.
///
/// The server distinguishes a field sent as `null` (clear it) from one that is
/// left out (keep it) for tags, due date, budget, URL and copies-per-file, so
/// the body is assembled as a raw JSON object instead of a synthesized struct.
struct ProjectEditForm: Equatable, Sendable {
    var name = ""
    var description = ""
    var color = ProjectPalette.colors[5]
    var url = ""
    var parentId: Int?
    var targetPlates = ""
    var targetParts = ""
    var targetSets = ""
    var tags = ""
    var hasDueDate = false
    var dueDate = Date()
    var priority = "normal"
    var budget = ""
    var status = "active"

    init() {}

    init(project: ProjectDetail) {
        name = project.name
        description = project.description ?? ""
        color = project.color ?? ProjectPalette.colors[5]
        url = project.url ?? ""
        parentId = project.parentId
        targetPlates = project.targetCount.map(String.init) ?? ""
        targetParts = project.targetPartsCount.map(String.init) ?? ""
        targetSets = project.targetSets.map(String.init) ?? ""
        tags = project.tags ?? ""
        if let d = ProjectDates.calendarDate(project.dueDate) { hasDueDate = true; dueDate = d }
        priority = project.priority ?? "normal"
        budget = project.budget.map { ProjectEditForm.plain($0) } ?? ""
        status = project.status
    }

    init(entry: ProjectListEntry) {
        name = entry.name
        description = entry.description ?? ""
        color = entry.color ?? ProjectPalette.colors[5]
        url = entry.url ?? ""
        parentId = entry.parentId
        targetPlates = entry.targetCount.map(String.init) ?? ""
        targetParts = entry.targetPartsCount.map(String.init) ?? ""
        targetSets = entry.targetSets.map(String.init) ?? ""
        tags = entry.tags ?? ""
        if let d = ProjectDates.calendarDate(entry.dueDate) { hasDueDate = true; dueDate = d }
        priority = entry.priority ?? "normal"
        budget = entry.budget.map { ProjectEditForm.plain($0) } ?? ""
        status = entry.status
    }

    private static func plain(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(v)
    }

    var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    var urlIsValid: Bool {
        let u = trimmedURL.lowercased()
        return u.isEmpty || u.hasPrefix("http://") || u.hasPrefix("https://")
    }

    private static func int(_ s: String) -> Int? {
        Int(s.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }
    private static func decimal(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// `isEdit` switches to "send null to clear" semantics.
    func body(isEdit: Bool) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        body["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines))
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty || isEdit { body["description"] = .string(desc) }
        body["color"] = .string(color)
        if let v = Self.int(targetPlates) { body["target_count"] = .number(Double(v)) }
        if let v = Self.int(targetParts) { body["target_parts_count"] = .number(Double(v)) }
        func setOrClear(_ key: String, _ value: JSONValue?) {
            if let value { body[key] = value } else if isEdit { body[key] = .null }
        }
        setOrClear("target_sets", Self.int(targetSets).map { .number(Double($0)) })
        let t = tags.trimmingCharacters(in: .whitespacesAndNewlines)
        setOrClear("tags", t.isEmpty ? nil : .string(t))
        setOrClear("due_date", hasDueDate ? .string(ProjectDates.wireString(dueDate)) : nil)
        body["priority"] = .string(priority)
        setOrClear("budget", Self.decimal(budget).map { .number($0) })
        setOrClear("url", trimmedURL.isEmpty ? nil : .string(trimmedURL))
        if isEdit {
            // 0 tells the server to detach from the parent.
            body["parent_id"] = .number(Double(parentId ?? 0))
            body["status"] = .string(status)
        } else if let parentId {
            body["parent_id"] = .number(Double(parentId))
        }
        return body
    }
}

struct ProjectBOMForm: Equatable, Sendable {
    var name = ""
    var quantity = 1
    var unitPrice = ""
    var sourcingURL = ""
    var remarks = ""

    init() {}
    init(item: ProjectBOMItem) {
        name = item.name
        quantity = item.quantityNeeded
        unitPrice = item.unitPrice.map { $0.rounded() == $0 ? String(Int($0)) : String($0) } ?? ""
        sourcingURL = item.sourcingUrl ?? ""
        remarks = item.remarks ?? ""
    }

    var body: [String: JSONValue] {
        var b: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "quantity_needed": .number(Double(max(1, quantity))),
        ]
        if let p = Double(unitPrice.replacingOccurrences(of: ",", with: ".")) { b["unit_price"] = .number(p) }
        let u = sourcingURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.isEmpty { b["sourcing_url"] = .string(u) }
        let r = remarks.trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.isEmpty { b["remarks"] = .string(r) }
        return b
    }
}

// MARK: - Helpers

enum ProjectPalette {
    static let colors = ["#ef4444", "#f97316", "#eab308", "#22c55e", "#06b6d4", "#3b82f6", "#8b5cf6", "#ec4899", "#6b7280"]

    static func color(_ hex: String?) -> Color { Color(hex: hex) ?? .gray }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "active": "Active"
        case "completed": "Completed"
        case "archived": "Archived"
        default: status.capitalized
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "active": .green
        case "completed": .blue
        default: .secondary
        }
    }

    static func priorityLabel(_ p: String?) -> String {
        switch p {
        case "low": "Low"
        case "high": "High"
        case "urgent": "Urgent"
        default: "Normal"
        }
    }

    static func priorityColor(_ p: String?) -> Color {
        switch p {
        case "low": .gray
        case "high": .orange
        case "urgent": .red
        default: .blue
        }
    }

    static func tagList(_ tags: String?) -> [String] {
        (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    static func splitList(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

enum ProjectDates {
    /// Due dates are calendar days stored as naive midnight timestamps; read
    /// the date part only so time zones can't shift them by a day.
    static func calendarDate(_ raw: String?) -> Date? {
        guard let raw, raw.count >= 10 else { return nil }
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func wireString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02dT00:00:00", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    /// Whole days from today until the due date (negative = overdue).
    static func daysUntil(_ raw: String?, now: Date = Date()) -> Int? {
        guard let due = calendarDate(raw) else { return nil }
        let today = Calendar.current.startOfDay(for: now)
        return Calendar.current.dateComponents([.day], from: today, to: due).day
    }
}

enum ProjectMoney {
    static func format(_ value: Double?, code: String) -> String {
        guard let value else { return "—" }
        return value.formatted(.currency(code: code))
    }
}
