import Foundation
import Observation

/// Quick "collections" offered above the archive grid.
enum ArchivesCollection: String, CaseIterable, Codable, Identifiable, Sendable {
    case all, recent, thisWeek, thisMonth, favorites, notPrinted, printed, failed, duplicates
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Archives"
        case .recent: "Last 24 Hours"
        case .thisWeek: "This Week"
        case .thisMonth: "This Month"
        case .favorites: "Favorites"
        case .notPrinted: "Not Printed"
        case .printed: "Printed"
        case .failed: "Failed Prints"
        case .duplicates: "Duplicates"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "archivebox"
        case .recent: "clock"
        case .thisWeek, .thisMonth: "calendar"
        case .favorites: "star"
        case .notPrinted: "tray.and.arrow.up"
        case .printed: "printer"
        case .failed: "exclamationmark.triangle"
        case .duplicates: "square.on.square"
        }
    }
}

enum ArchivesSort: String, CaseIterable, Codable, Identifiable, Sendable {
    case newest, oldest, nameAsc, nameDesc, largest, smallest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .nameAsc: "Name (A–Z)"
        case .nameDesc: "Name (Z–A)"
        case .largest: "Largest File"
        case .smallest: "Smallest File"
        }
    }
}

enum ArchivesFileTypeFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all, sliced, source
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All Files"
        case .sliced: "Sliced (G-code)"
        case .source: "Source Only"
        }
    }
}

/// All list filters; persisted between launches like the web UI's localStorage.
struct ArchivesFilters: Codable, Equatable, Sendable {
    var collection: ArchivesCollection = .all
    var sort: ArchivesSort = .newest
    var printerId: Int?
    var material: String?
    var colors: Set<String> = []
    var colorsMatchAll = false
    var favoritesOnly = false
    var hideFailed = false
    var hideDuplicates = false
    var tag: String?
    var fileType: ArchivesFileTypeFilter = .all
    var user: String?
    var projectId: Int?
    var dateFrom: Date?
    var dateTo: Date?

    /// Number of refinements beyond the collection and sort (for the toolbar badge).
    var activeCount: Int {
        var n = 0
        if printerId != nil { n += 1 }
        if material != nil { n += 1 }
        if !colors.isEmpty { n += 1 }
        if favoritesOnly { n += 1 }
        if hideFailed { n += 1 }
        if hideDuplicates { n += 1 }
        if tag != nil { n += 1 }
        if fileType != .all { n += 1 }
        if user != nil { n += 1 }
        if projectId != nil { n += 1 }
        if dateFrom != nil || dateTo != nil { n += 1 }
        return n
    }

    mutating func resetRefinements() {
        let keep = (collection, sort)
        self = ArchivesFilters()
        collection = keep.0
        sort = keep.1
    }

    static let storageKey = "archivesFilters.v1"

    static func load() -> ArchivesFilters {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let f = try? JSONDecoder().decode(ArchivesFilters.self, from: data) else { return ArchivesFilters() }
        return f
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }

    // MARK: Matching

    func matches(_ a: ArchivesRecord, search: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let created = a.createdDate ?? .distantPast
        switch collection {
        case .all: break
        case .recent: if now.timeIntervalSince(created) >= 86_400 { return false }
        case .thisWeek: if now.timeIntervalSince(created) >= 7 * 86_400 { return false }
        case .thisMonth: if !calendar.isDate(created, equalTo: now, toGranularity: .month) { return false }
        case .favorites: if !a.favorite { return false }
        case .notPrinted: if a.status != "archived" { return false }
        case .printed: if !a.wasPrinted { return false }
        case .failed: if !a.isFailed { return false }
        case .duplicates: if !a.isDuplicate { return false }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let haystack = [a.printName, a.filename, a.tags, a.notes, a.designer, a.filamentType, a.projectName]
                .compactMap { $0 }.joined(separator: " ")
            if haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        }
        if let printerId, a.printerId != printerId { return false }
        if let material, !a.materials.contains(material) { return false }
        if !colors.isEmpty {
            let own = Set(a.colors)
            if colorsMatchAll ? !colors.isSubset(of: own) : colors.isDisjoint(with: own) { return false }
        }
        if collection != .favorites, favoritesOnly, !a.favorite { return false }
        if collection != .failed, hideFailed, a.isFailed { return false }
        if collection != .duplicates, hideDuplicates, a.isDuplicate, (a.duplicateSequence ?? 0) != 0 { return false }
        if let tag, !a.tagList.contains(tag) { return false }
        switch fileType {
        case .all: break
        case .sliced: if !a.isSliced { return false }
        case .source: if a.isSliced { return false }
        }
        if let user, a.createdByUsername != user { return false }
        if let projectId, a.projectId != projectId { return false }
        if let dateFrom, created < calendar.startOfDay(for: dateFrom) { return false }
        if let dateTo, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dateTo)), created >= end { return false }
        return true
    }

    func sorted(_ list: [ArchivesRecord]) -> [ArchivesRecord] {
        func date(_ a: ArchivesRecord) -> Date { a.createdDate ?? .distantPast }
        switch sort {
        case .newest: return list.sorted { date($0) > date($1) }
        case .oldest: return list.sorted { date($0) < date($1) }
        case .nameAsc: return list.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .nameDesc: return list.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedDescending }
        case .largest: return list.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .smallest: return list.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        }
    }
}

/// Loads every visible archive page by page (so the first page shows quickly)
/// and filters/sorts client-side, like the web UI.
@MainActor
@Observable
final class ArchivesBrowserModel {
    private(set) var archives: [ArchivesRecord] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    var error: String?
    var no3mfWarning: ArchivesNo3mfWarning?

    var filters = ArchivesFilters.load() { didSet { if filters != oldValue { filters.save() } } }

    static let pageSize = 200
    @ObservationIgnored private var generation = 0

    /// Fetches all pages. The first page replaces the list only on the initial
    /// load; reloads swap atomically once complete so the grid never flashes empty.
    func load(client: APIClient) async {
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false; isLoadingMore = false } }
        var collected: [ArchivesRecord] = []
        var offset = 0
        do {
            while true {
                let page: [ArchivesRecord] = try await client.get("archives/", query: ["limit": .int(Self.pageSize), "offset": .int(offset)])
                guard gen == generation else { return }
                collected += page
                offset += page.count
                if !hasLoaded {
                    archives = collected
                    isLoadingMore = page.count == Self.pageSize
                }
                if page.count < Self.pageSize { break }
            }
            var seen = Set<Int>()
            archives = collected.filter { seen.insert($0.id).inserted }
            hasLoaded = true
            error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            if gen == generation { self.error = error.localizedDescription }
        }
        if gen == generation, no3mfWarning == nil || no3mfWarning?.hasFallback == true {
            no3mfWarning = try? await client.get("archives/no-3mf-warning")
        }
    }

    func replace(_ archive: ArchivesRecord) {
        if let i = archives.firstIndex(where: { $0.id == archive.id }) { archives[i] = archive }
    }

    func remove(_ ids: Set<Int>) {
        archives.removeAll { ids.contains($0.id) }
    }

    func visible(search: String) -> [ArchivesRecord] {
        let f = filters
        let now = Date()
        return f.sorted(archives.filter { f.matches($0, search: search, now: now) })
    }

    // MARK: Facets for the filter sheet

    var materials: [String] { Set(archives.flatMap(\.materials)).sorted() }
    var colors: [String] {
        var seen = Set<String>(), out: [String] = []
        for c in archives.flatMap(\.colors) where seen.insert(c.uppercased()).inserted { out.append(c) }
        return out
    }
    var tags: [String] { Set(archives.flatMap(\.tagList)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
    var users: [String] { Set(archives.compactMap(\.createdByUsername)).sorted() }
}
