import Foundation
import Observation

/// Loads and mutates the spool inventory. Transparently targets either
/// Bambuddy's own inventory (`inventory/…`) or the Spoolman proxy
/// (`spoolman/inventory/…`) depending on the server's Spoolman settings.
@MainActor
@Observable
final class InventoryStore {
    enum Mode: Equatable, Sendable { case unknown, local, spoolman }

    private(set) var mode: Mode = .unknown
    private(set) var spools: [InventorySpool] = []
    private(set) var assignments: [InventorySpoolAssignment] = []
    private(set) var spoolmanAssignments: [InventorySpoolmanSlotAssignment] = []
    private(set) var locations: [InventoryLocation] = []
    private(set) var spoolCatalog: [InventorySpoolCatalogEntry] = []
    private(set) var settings: JSONValue?
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var assignmentsError: String?
    /// True when showing synthetic debug data (never talks to the server for reads).
    private(set) var isDemo = false

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private var modeCheckedAt: Date?

    init(session: AppSession) {
        self.session = session
    }

    #if DEBUG
    /// Seeds synthetic data (launch argument `-inventoryDemo YES`) for screenshots.
    init(session: AppSession, demo: Bool) {
        self.session = session
        if demo { seedDemo() }
    }
    #endif

    var client: APIClient { session.client }
    var isSpoolman: Bool { mode == .spoolman }

    // MARK: Derived values

    var lowStockThreshold: Double { settings?["low_stock_threshold"]?.doubleValue ?? 20 }
    var currencyCode: String { settings?["currency"]?.stringValue ?? "USD" }
    var disableFilamentWarnings: Bool { settings?["disable_filament_warnings"]?.boolValue ?? false }
    var forecastLeadTimeDays: Int { settings?["forecast_global_lead_time_days"]?.intValue ?? 0 }

    func spool(_ id: Int) -> InventorySpool? { spools.first { $0.id == id } }

    /// Where each spool is loaded, keyed by spool id.
    var slotMap: [Int: InventorySlotLocation] {
        var map: [Int: InventorySlotLocation] = [:]
        if isSpoolman {
            for a in spoolmanAssignments where a.spoolmanSpoolId > 0 && map[a.spoolmanSpoolId] == nil {
                map[a.spoolmanSpoolId] = InventorySlotLocation(printerId: a.printerId, printerName: a.printerName, amsId: a.amsId, trayId: a.trayId, amsLabel: a.amsLabel)
            }
        } else {
            for a in assignments {
                map[a.spoolId] = InventorySlotLocation(printerId: a.printerId, printerName: a.printerName, amsId: a.amsId, trayId: a.trayId, amsLabel: a.amsLabel, pendingConfig: a.pendingConfig ?? false)
            }
        }
        return map
    }

    func slot(for spoolId: Int) -> InventorySlotLocation? { slotMap[spoolId] }

    func catalogEntry(_ id: Int?) -> InventorySpoolCatalogEntry? {
        guard let id else { return nil }
        return spoolCatalog.first { $0.id == id }
    }

    func location(_ id: Int?) -> InventoryLocation? {
        guard let id else { return nil }
        return locations.first { $0.id == id }
    }

    /// The storage location label for a spool (named location or free text).
    func storageLabel(for spool: InventorySpool) -> String? {
        if let loc = location(spool.locationId) { return loc.name }
        let s = spool.storageLocation?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? nil : s
    }

    // MARK: Paths

    private var spoolsBase: String { isSpoolman ? "spoolman/inventory/spools" : "inventory/spools" }
    func spoolPath(_ id: Int, _ suffix: String = "") -> String { "\(spoolsBase)/\(id)\(suffix)" }

    // MARK: Loading

    func resolveMode(force: Bool = false) async {
        if !force, mode != .unknown, let checked = modeCheckedAt, Date().timeIntervalSince(checked) < 120 { return }
        var newMode: Mode = .local
        if let s = try? await client.get("settings/spoolman", as: InventorySpoolmanSettings.self) {
            newMode = s.isActive ? .spoolman : .local
        } else if let status = try? await client.get("spoolman/status", as: InventorySpoolmanStatus.self) {
            newMode = status.enabled && !(status.url ?? "").isEmpty ? .spoolman : .local
        }
        modeCheckedAt = Date()
        if newMode != mode {
            mode = newMode
            spools = []
        }
    }

    func load() async {
        if isDemo { return }
        await resolveMode()
        isLoading = true
        defer { isLoading = false }
        let client = client
        let base = spoolsBase
        let spoolman = isSpoolman
        async let spoolsTask = client.get(base, query: ["include_archived": true], as: [InventorySpool].self)
        async let settingsTask = try? client.get("settings/", as: JSONValue.self)
        async let locationsTask = try? client.get("inventory/locations", as: [InventoryLocation].self)
        async let catalogTask = try? client.get("inventory/catalog", as: [InventorySpoolCatalogEntry].self)
        do {
            spools = try await spoolsTask
            error = nil
        } catch is CancellationError {
            return
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch {
            self.error = error.localizedDescription
        }
        if let s = await settingsTask { settings = s }
        if let l = await locationsTask { locations = l.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        if let c = await catalogTask { spoolCatalog = c }
        await loadAssignments(spoolman: spoolman)
        hasLoaded = true
    }

    func loadAssignments(spoolman: Bool? = nil) async {
        if isDemo { return }
        let spoolman = spoolman ?? isSpoolman
        guard session.can("inventory:view_assignments") else { assignments = []; return }
        do {
            assignments = try await client.get("inventory/assignments")
            assignmentsError = nil
        } catch {
            assignmentsError = error.localizedDescription
        }
        if spoolman {
            spoolmanAssignments = (try? await client.get("spoolman/inventory/slot-assignments/all")) ?? spoolmanAssignments
        } else {
            spoolmanAssignments = []
        }
    }

    func reloadLocations() async {
        if let l: [InventoryLocation] = try? await client.get("inventory/locations") {
            locations = l.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func reloadCatalog() async {
        if let c: [InventorySpoolCatalogEntry] = try? await client.get("inventory/catalog") { spoolCatalog = c }
    }

    func reloadSettings() async {
        if let s: JSONValue = try? await client.get("settings/") { settings = s }
    }

    // MARK: Spool mutations

    /// Keys the Spoolman proxy accepts on create/update.
    private static let spoolmanKeys: Set<String> = [
        "spoolman_filament_id", "material", "subtype", "brand", "color_name", "rgba", "label_weight", "core_weight",
        "weight_used", "note", "cost_per_kg", "storage_location", "location_id", "slicer_filament", "slicer_filament_name",
        "tag_uid", "tray_uuid",
    ]

    private func filtered(_ payload: [String: JSONValue]) -> JSONValue {
        guard isSpoolman else { return .object(payload.filter { $0.key != "spoolman_filament_id" }) }
        return .object(payload.filter { Self.spoolmanKeys.contains($0.key) })
    }

    func create(_ payload: [String: JSONValue], quantity: Int = 1) async throws {
        if quantity > 1 {
            let body: JSONValue = ["spool": filtered(payload), "quantity": .number(Double(quantity))]
            try await client.call(.post, "\(spoolsBase)/bulk", body: body)
        } else {
            try await client.call(.post, spoolsBase, body: filtered(payload))
        }
        await load()
    }

    func update(_ id: Int, _ payload: [String: JSONValue]) async throws {
        try await client.call(.patch, spoolPath(id), body: filtered(payload))
        await load()
    }

    func delete(_ id: Int) async throws {
        try await client.call(.delete, spoolPath(id))
        spools.removeAll { $0.id == id }
        await load()
    }

    func archive(_ id: Int) async throws {
        try await client.call(.post, spoolPath(id, "/archive"))
        await load()
    }

    func restore(_ id: Int) async throws {
        try await client.call(.post, spoolPath(id, "/restore"))
        await load()
    }

    func resetConsumedCounter(_ id: Int) async throws {
        try await client.call(.post, spoolPath(id, "/reset-consumed-counter"))
        await load()
    }

    func clearTag(_ id: Int) async throws {
        var payload: [String: JSONValue] = ["tag_uid": nil, "tray_uuid": nil]
        if !isSpoolman { payload["tag_type"] = nil; payload["data_origin"] = nil }
        try await client.call(.patch, spoolPath(id), body: JSONValue.object(payload))
        await load()
    }

    /// Sets the remaining filament directly (locks the weight against automatic tracking on local spools).
    func setRemaining(_ id: Int, remainingGrams: Double) async throws {
        guard let spool = spool(id) else { return }
        let used = max(0, spool.label - max(0, min(spool.label, remainingGrams)))
        try await update(id, ["weight_used": .number(used.rounded())])
    }

    /// Applies the spool's last scale reading as its current gross weight.
    func syncToScale(_ spool: InventorySpool) async throws {
        guard let weight = spool.lastScaleWeight else { return }
        if isSpoolman {
            try await client.call(.patch, spoolPath(spool.id, "/weight"), body: ["weight_grams": JSONValue.number(weight)] as JSONValue)
        } else {
            try await client.call(.post, "spoolbuddy/scale/update-spool-weight", body: ["spool_id": .number(Double(spool.id)), "weight_grams": .number(weight)] as JSONValue)
        }
        await load()
    }

    func syncAMSWeights() async throws -> String {
        let path = isSpoolman ? "spoolman/inventory/sync-ams-weights" : "inventory/sync-ams-weights"
        let result: JSONValue = try await client.send(.post, path)
        await load()
        let synced = result["synced"]?.intValue ?? 0
        let skipped = result["skipped"]?.intValue ?? 0
        return "Synced \(synced), skipped \(skipped)"
    }

    // MARK: Bulk

    enum BulkAction: String, Sendable { case delete, archive, restore }

    func bulk(_ action: BulkAction, ids: [Int]) async throws -> InventoryBulkResult {
        let result: InventoryBulkResult = try await client.send(.post, "\(spoolsBase)/bulk-\(action.rawValue)", body: ["ids": JSONValue.array(ids.map { .number(Double($0)) })] as JSONValue)
        await load()
        return result
    }

    func bulkUpdate(ids: [Int], patch: [String: JSONValue]) async throws -> InventoryBulkResult {
        let body: JSONValue = ["ids": .array(ids.map { .number(Double($0)) }), "update": filtered(patch)]
        let result: InventoryBulkResult = try await client.send(.post, "\(spoolsBase)/bulk-update", body: body)
        await load()
        return result
    }

    func bulkResetConsumed(ids: [Int]) async throws -> InventoryBulkResult {
        guard !ids.isEmpty else { return InventoryBulkResult() }
        let body: JSONValue = ["spool_ids": .array(ids.map { .number(Double($0)) })]
        let result: InventoryBulkResult = try await client.send(.post, "\(spoolsBase)/reset-consumed-counter-bulk", body: body)
        await load()
        return result
    }

    // MARK: Assignments

    func assign(spoolId: Int, printerId: Int, amsId: Int, trayId: Int) async throws -> InventorySpoolAssignment? {
        var result: InventorySpoolAssignment?
        if isSpoolman {
            let body: JSONValue = ["spoolman_spool_id": .number(Double(spoolId)), "printer_id": .number(Double(printerId)), "ams_id": .number(Double(amsId)), "tray_id": .number(Double(trayId))]
            try await client.call(.post, "spoolman/inventory/slot-assignments", body: body)
        } else {
            let body: JSONValue = ["spool_id": .number(Double(spoolId)), "printer_id": .number(Double(printerId)), "ams_id": .number(Double(amsId)), "tray_id": .number(Double(trayId))]
            result = try await client.send(.post, "inventory/assignments", body: body)
        }
        // Nudge the printer to republish its tray state; failures are harmless.
        try? await client.call(.post, "printers/\(printerId)/refresh-status")
        await loadAssignments()
        return result
    }

    func unassign(spoolId: Int, slot: InventorySlotLocation) async throws {
        if isSpoolman {
            try await client.call(.delete, "spoolman/inventory/slot-assignments/\(spoolId)")
        } else {
            try await client.call(.delete, "inventory/assignments/\(slot.printerId)/\(slot.amsId)/\(slot.trayId)")
        }
        await loadAssignments()
    }

    func createFromSlot(printerId: Int, amsId: Int, trayId: Int) async throws {
        let body: JSONValue = ["printer_id": .number(Double(printerId)), "ams_id": .number(Double(amsId)), "tray_id": .number(Double(trayId))]
        let path = isSpoolman ? "spoolman/spools/from-slot" : "inventory/spools/from-slot"
        try await client.call(.post, path, body: body)
        await load()
    }

    // MARK: Per-spool extras

    func kProfiles(_ id: Int) async throws -> [InventorySpoolKProfile] {
        try await client.get(spoolPath(id, "/k-profiles"))
    }

    func saveKProfiles(_ id: Int, _ profiles: [InventoryKProfileInput]) async throws {
        try await client.call(.put, spoolPath(id, "/k-profiles"), body: profiles)
    }

    func filamentPresets(_ id: Int) async throws -> [InventorySpoolFilamentPreset] {
        try await client.get(spoolPath(id, "/filament-presets"))
    }

    func saveFilamentPresets(_ id: Int, _ presets: [InventoryFilamentPresetInput]) async throws {
        try await client.call(.put, spoolPath(id, "/filament-presets"), body: presets)
    }

    func usage(_ id: Int) async throws -> [InventoryUsageRecord] {
        try await client.get("inventory/spools/\(id)/usage", query: ["limit": 100])
    }

    func clearUsage(_ id: Int) async throws {
        try await client.call(.delete, "inventory/spools/\(id)/usage")
    }

    // MARK: Labels & CSV

    func labelsPDF(ids: [Int], template: InventoryLabelTemplate, monochrome: Bool, startingPosition: Int) async throws -> URL {
        let request = InventoryLabelRequest(spoolIds: ids, template: template.rawValue, monochrome: monochrome, startingPosition: template.sheetCapacity == nil ? 1 : startingPosition)
        let body = try APICoders.encoder.encode(request)
        let path = isSpoolman ? "spoolman/labels" : "inventory/labels"
        let stamp = Date().formatted(.iso8601.year().month().day())
        return try await client.download(path, suggestedName: "spool-labels-\(stamp).pdf", method: .post, body: body)
    }

    func exportCSV() async throws -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day())
        return try await client.download("inventory/spools/export", suggestedName: "bambuddy-spools-\(stamp).csv")
    }

    func importCSV(data: Data, fileName: String, dryRun: Bool) async throws -> InventoryImportResponse {
        let result: InventoryImportResponse = try await client.upload(
            "inventory/spools/import", query: ["dry_run": .bool(dryRun)],
            files: [UploadFile(fieldName: "file", fileName: fileName, mimeType: "text/csv", data: data)])
        if !dryRun { await load() }
        return result
    }

    // MARK: Settings

    func setLowStockThreshold(_ value: Double) async throws {
        try await client.call(.patch, "settings/", body: ["low_stock_threshold": JSONValue.number(value)] as JSONValue)
        await reloadSettings()
    }

    func setForecastLeadTime(_ days: Int) async throws {
        try await client.call(.patch, "settings/", body: ["forecast_global_lead_time_days": JSONValue.number(Double(days))] as JSONValue)
        await reloadSettings()
    }

    // MARK: Locations

    func createLocation(name: String, identifier: String?) async throws -> InventoryLocation {
        var body: [String: JSONValue] = ["name": .string(name)]
        if let identifier, !identifier.isEmpty { body["identifier"] = .string(identifier) }
        let loc: InventoryLocation = try await client.send(.post, "inventory/locations", body: JSONValue.object(body))
        await reloadLocations()
        return loc
    }

    func updateLocation(_ id: Int, name: String, identifier: String?) async throws {
        let body: JSONValue = ["name": .string(name), "identifier": identifier.flatMap { $0.isEmpty ? nil : JSONValue.string($0) } ?? .null]
        try await client.call(.patch, "inventory/locations/\(id)", body: body)
        await reloadLocations()
        await load()
    }

    func deleteLocation(_ id: Int) async throws {
        try await client.call(.delete, "inventory/locations/\(id)")
        await reloadLocations()
    }

    // MARK: Slicer presets

    /// Merged slicer filament presets from the cloud account, local profiles, and built-in filaments.
    func presetOptions() async -> [InventoryPresetOption] {
        let client = client
        async let cloud = try? client.get("cloud/filaments", as: [InventorySlicerSetting].self)
        async let local = try? client.get("local-presets/", as: InventoryLocalPresets.self)
        async let builtin = try? client.get("cloud/builtin-filaments", as: [InventoryBuiltinFilament].self)
        return InventoryPresets.merge(cloud: await cloud ?? [], local: await local?.filament ?? [], builtin: await builtin ?? [])
    }
}

/// Pure helpers for slicer presets (kept separate so they are testable).
enum InventoryPresets {
    static func merge(cloud: [InventorySlicerSetting], local: [InventoryLocalPreset], builtin: [InventoryBuiltinFilament]) -> [InventoryPresetOption] {
        var result: [InventoryPresetOption] = []
        var cloudCodes = Set<String>()
        var seenDefaultNames = Set<String>()
        for preset in cloud {
            cloudCodes.insert(preset.settingId)
            if preset.isCustom == true {
                result.append(InventoryPresetOption(code: preset.settingId, name: preset.name, source: .custom))
            } else {
                // Cloud system presets repeat per printer ("… @BBL A1"); list each base name once.
                let base = baseName(preset.name)
                guard !seenDefaultNames.contains(base.lowercased()) else { continue }
                seenDefaultNames.insert(base.lowercased())
                result.append(InventoryPresetOption(code: preset.settingId, name: preset.name, source: .cloud))
            }
        }
        for preset in local where (preset.presetType ?? "filament") == "filament" {
            var alt: [String] = []
            if let t = preset.filamentType, !t.isEmpty { alt.append(t) }
            result.append(InventoryPresetOption(code: String(preset.id), name: preset.name, source: .local, alternateCodes: alt))
        }
        for filament in builtin {
            let settingId = filament.filamentId.hasPrefix("GF") ? "GFS" + filament.filamentId.dropFirst(2) : filament.filamentId
            if cloudCodes.contains(filament.filamentId) || cloudCodes.contains(settingId) { continue }
            if seenDefaultNames.contains(baseName(filament.name).lowercased()) { continue }
            result.append(InventoryPresetOption(code: filament.filamentId, name: filament.name, source: .builtin, alternateCodes: [settingId]))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Strips the "@printer" qualifier and "(Custom)" marker from a preset name.
    static func baseName(_ name: String) -> String {
        var s = name
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }
        s = s.replacingOccurrences(of: "(Custom)", with: "", options: .caseInsensitive)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "#* ").union(.whitespaces))
    }

    private static let knownMaterials = [
        "PLA-CF", "PETG-CF", "ABS-GF", "ASA-CF", "PA-CF", "PAHT-CF", "PA6-CF", "PA6-GF", "PPA-CF", "PPA-GF",
        "PET-CF", "PPS-CF", "PC-CF", "PC-ABS", "PCTG", "PETG", "PLA", "ABS", "ASA", "PC", "PA", "TPU", "PVA",
        "HIPS", "BVOH", "PPS", "PEEK", "PEI",
    ]

    /// Splits a preset name like "Bambu PLA Matte @BBL X1C" into brand / material / subtype.
    static func parse(_ name: String) -> (brand: String, material: String, subtype: String) {
        let clean = baseName(name)
        for m in knownMaterials {
            guard let range = clean.range(of: m, options: .caseInsensitive) else { continue }
            let brand = String(clean[clean.startIndex..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            let after = String(clean[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            return (brand, m, after)
        }
        return ("", "", "")
    }
}

#if DEBUG
extension InventoryStore {
    /// Synthetic inventory for screenshots and UI iteration (`-inventoryDemo YES`).
    fileprivate func seedDemo() {
        func spool(_ id: Int, _ material: String, _ subtype: String?, _ brand: String, _ color: String, _ rgba: String, label: Int = 1000, used: Double, location: Int? = nil, category: String? = nil, preset: String? = nil, archived: Bool = false, extra: String? = nil, effect: String? = nil) -> InventorySpool {
            InventorySpool(id: id, material: material, subtype: subtype, colorName: color, rgba: rgba, extraColors: extra, effectType: effect,
                           brand: brand, labelWeight: label, coreWeight: 250, weightUsed: used, weightUsedBaseline: 0,
                           slicerFilament: preset == nil ? nil : "GFA00", slicerFilamentName: preset, note: id == 3 ? "Opened for the lamp project" : nil,
                           tagUid: id == 1 ? "A1B2C3D4" : nil, dataOrigin: id == 1 ? "rfid" : "manual", costPerKg: 24.99, weightLocked: false,
                           lastScaleWeight: id == 2 ? 912 : nil, category: category, storageLocation: location == nil ? nil : "Dry Box 1", locationId: location,
                           lastUsed: used > 0 ? "2026-09-20T10:00:00Z" : nil, archivedAt: archived ? "2026-08-01T12:00:00Z" : nil,
                           createdAt: "2026-06-\(10 + id % 18)T09:00:00Z", updatedAt: "2026-09-20T10:00:00Z",
                           kProfiles: id == 1 ? [InventorySpoolKProfile(id: 1, spoolId: 1, printerId: 1, extruder: 0, nozzleDiameter: "0.4", kValue: 0.02, name: "Bambu PLA Basic", caliIdx: 3)] : [])
        }
        mode = .local
        spools = [
            spool(1, "PLA", "Basic", "Bambu", "Jade White", "FFFFFFFF", used: 312, preset: "Bambu PLA Basic"),
            spool(2, "PLA", "Matte", "Bambu", "Charcoal", "000000FF", used: 88, location: 1, preset: "Bambu PLA Matte"),
            spool(3, "PETG", "HF", "Bambu", "Blue", "0A2CA5FF", used: 905, preset: "Bambu PETG HF"),
            spool(4, "PLA", "Silk", "Sunlu", "Rainbow", "FF0000FF", used: 0, location: 1, category: "Stock", extra: "FFA500,FFFF00,00AE42,0066FF", effect: "silk"),
            spool(5, "PLA", "Silk", "Sunlu", "Rainbow", "FF0000FF", used: 0, location: 1, category: "Stock", extra: "FFA500,FFFF00,00AE42,0066FF", effect: "silk"),
            spool(6, "TPU", "95A", "Overture", "Clear", "FFFFFF00", label: 500, used: 120),
            spool(7, "ABS", nil, "eSUN", "Fire Red", "D32F2FFF", used: 1000, archived: true),
            spool(8, "ASA", nil, "Polymaker", "Galaxy Grey", "5A5A6EFF", used: 430, location: 2, effect: "sparkle"),
        ]
        assignments = [
            InventorySpoolAssignment(id: 1, spoolId: 1, printerId: 1, printerName: "X1 Carbon", amsId: 0, trayId: 0, createdAt: "2026-09-01T00:00:00Z", configured: true),
            InventorySpoolAssignment(id: 2, spoolId: 3, printerId: 1, printerName: "X1 Carbon", amsId: 0, trayId: 2, createdAt: "2026-09-01T00:00:00Z", configured: true),
        ]
        locations = [
            InventoryLocation(id: 1, name: "Dry Box 1", identifier: "DB1", spoolCount: 3),
            InventoryLocation(id: 2, name: "Shelf A", identifier: nil, spoolCount: 1),
        ]
        settings = ["low_stock_threshold": 20, "currency": "USD", "forecast_global_lead_time_days": 7]
        hasLoaded = true
        modeCheckedAt = .distantFuture
        isDemo = true
    }
}
#endif
