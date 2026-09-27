import SwiftUI
import UniformTypeIdentifiers

// MARK: Permissions

/// Ownership-aware permission checks for archives, mirroring the server's
/// `*_all` / `*_own` split. With auth disabled `session.can` is always true.
enum ArchivesPermissions {
    /// `action` is `update`, `delete` or `reprint`.
    @MainActor
    static func canModify(_ session: AppSession, _ action: String, ownerId: Int?) -> Bool {
        guard session.isAuthEnabled else { return true }
        if session.user?.isAdmin == true { return true }
        if session.can("archives:\(action)_all") { return true }
        if session.can("archives:\(action)_own") {
            guard let ownerId, let me = session.user?.id else { return false }
            return ownerId == me
        }
        return false
    }

    @MainActor static func canUpdate(_ session: AppSession, _ archive: ArchivesRecord) -> Bool {
        canModify(session, "update", ownerId: archive.createdById)
    }

    @MainActor static func canDelete(_ session: AppSession, _ archive: ArchivesRecord) -> Bool {
        canModify(session, "delete", ownerId: archive.createdById)
    }

    /// Reprinting needs both the reprint grant and permission to create queue items.
    @MainActor static func canReprint(_ session: AppSession, _ archive: ArchivesRecord) -> Bool {
        session.can("queue:create") && canModify(session, "reprint", ownerId: archive.createdById)
    }

    /// Endpoints gated on `archives:update_all` only (timelapse scan/upload/process, tags, rescan).
    @MainActor static func canAdminister(_ session: AppSession) -> Bool {
        session.can("archives:update_all")
    }

    @MainActor static func canUpdateAny(_ session: AppSession) -> Bool {
        session.can("archives:update_all") || session.can("archives:update_own")
    }

    @MainActor static func canDeleteAny(_ session: AppSession) -> Bool {
        session.can("archives:delete_all") || session.can("archives:delete_own")
    }
}

// MARK: Shared lookups

/// Data shared by the Archives screens: projects, currency, known tags.
@MainActor
@Observable
final class ArchivesLookups {
    var projects: [ArchivesProjectOption] = []
    var currency = "USD"
    var tags: [ArchivesTagCount] = []

    /// Projects an archive may be filed under (archived projects excluded unless current).
    func assignableProjects(keeping id: Int? = nil) -> [ArchivesProjectOption] {
        projects.filter { $0.status != "archived" || $0.id == id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func project(_ id: Int?) -> ArchivesProjectOption? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func refresh(client: APIClient) async {
        async let projects: [ArchivesProjectOption]? = try? client.get("projects/")
        async let settings: JSONValue? = try? client.get("settings/")
        async let tags: [ArchivesTagCount]? = try? client.get("archives/tags")
        if let p = await projects { self.projects = p }
        if let c = await settings?["currency"]?.stringValue, !c.isEmpty { currency = c }
        if let t = await tags { self.tags = t }
    }

    func refreshTags(client: APIClient) async {
        if let t: [ArchivesTagCount] = try? await client.get("archives/tags") { tags = t }
    }

    func money(_ value: Double?) -> String { Fmt.currency(value, code: currency) }
}

// MARK: Presentation helpers

/// A file downloaded to a temp location, ready for a share sheet.
struct ArchivesSharedFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}

/// Request to open the shared print sheet.
struct ArchivesPrintRequest: Identifiable, Hashable {
    let archiveId: Int
    let name: String
    let mode: PrintJobSheet.Mode
    var id: String { "\(archiveId)-\(mode)" }
}

enum ArchivesStyle {
    static func statusColor(_ status: String?) -> Color {
        switch status ?? "" {
        case "completed": .green
        case "failed": .red
        case "aborted", "cancelled": .orange
        case "stopped": .yellow
        case "printing": .blue
        case "skipped": .teal
        case "archived": .secondary
        default: .gray
        }
    }

    static func accuracyColor(_ accuracy: Double) -> Color {
        if (95...105).contains(accuracy) { return .green }
        return accuracy > 105 ? .blue : .orange
    }

    static func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        return Fmt.duration(seconds: Double(seconds))
    }

    static func number(_ value: Double?, suffix: String, digits: Int = 2) -> String {
        guard let value else { return "—" }
        return "\(Fmt.number(value, digits: digits)) \(suffix)"
    }

    static func gramsPrecise(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + " g"
    }

    /// Bambu plate type identifiers → readable names.
    static func bedTypeName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "cool_plate", "cool plate", "pc": return "Cool Plate"
        case "eng_plate", "engineering plate", "ep": return "Engineering Plate"
        case "hot_plate", "high temp plate", "pei": return "High Temp Plate"
        case "textured_plate", "textured pei plate", "pte": return "Textured PEI Plate"
        case "supertack_plate", "cool plate (supertack)": return "Cool Plate (SuperTack)"
        default: return raw
        }
    }
}

/// Status capsule for archives and log entries.
struct ArchivesStatusBadge: View {
    let status: String?
    var body: some View {
        StatusBadge(text: ArchivesVocabulary.statusLabel(status), color: ArchivesStyle.statusColor(status))
    }
}

/// A row of small filament color dots.
struct ArchivesColorDots: View {
    let colors: [String]
    var size: CGFloat = 12
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(colors.prefix(8).enumerated()), id: \.offset) { _, hex in
                Circle()
                    .fill(Color(hex: hex) ?? .gray)
                    .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5) }
                    .frame(width: size, height: size)
                    .accessibilityLabel(hex)
            }
            if colors.count > 8 {
                Text("+\(colors.count - 8)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Wrapping row of tag capsules.
struct ArchivesTagChips: View {
    let tags: [String]
    var body: some View {
        ArchivesFlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
            }
        }
    }
}

/// Simple wrapping layout for chips.
struct ArchivesFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Archive thumbnail with a placeholder for archives without one.
struct ArchivesThumbnail: View {
    let archive: ArchivesRecord
    var plateIndex: Int? = nil

    var body: some View {
        if let plateIndex {
            RemoteImage(path: "archives/\(archive.id)/plate-thumbnail/\(plateIndex)", contentMode: .fit, systemImage: "cube")
        } else if archive.thumbnailPath != nil {
            RemoteImage(path: "archives/\(archive.id)/thumbnail", contentMode: .fit, reloadKey: archive.thumbnailPath, systemImage: "cube")
        } else {
            ImagePlaceholder(systemImage: archive.isSliced ? "cube" : "doc")
        }
    }
}

enum ArchivesFileTypes {
    static let threeMF: UTType = UTType(filenameExtension: "3mf") ?? .data
    static let f3d: UTType = UTType(filenameExtension: "f3d") ?? .data
    static let video: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
}

/// Reads a security-scoped file picked with `fileImporter`.
func archivesReadPickedFile(_ url: URL) throws -> Data {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try Data(contentsOf: url)
}

/// Guesses a MIME type from a file extension.
func archivesMimeType(for url: URL) -> String {
    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
}
