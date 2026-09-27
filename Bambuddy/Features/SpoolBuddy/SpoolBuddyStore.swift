import Foundation
import Observation

/// Devices, spools and AMS assignments used across the SpoolBuddy screens.
/// Transparently switches between the local inventory and the Spoolman bridge.
@MainActor
@Observable
final class SpoolBuddyStore {
    var devices = Loader<[SpoolBuddyDevice]>()
    private(set) var spools: [SpoolBuddySpool] = []
    private(set) var spoolsError: String?
    private(set) var spoolsLoaded = false
    private(set) var spoolmanMode = false
    /// Local-inventory assignments (`/inventory/assignments`).
    private(set) var assignments: [SpoolBuddyAssignment] = []
    /// Spoolman-mode assignments.
    private(set) var spoolmanSlots: [SpoolBuddySpoolmanSlot] = []

    // MARK: Loading

    func loadDevices(_ session: AppSession) async {
        await devices.load { try await session.client.get("spoolbuddy/devices") }
    }

    func loadSpools(_ session: AppSession) async {
        guard session.can("inventory:read") else { return }
        let client = session.client
        let settings = try? await client.get("settings/spoolman", as: SpoolBuddySpoolmanSettings.self)
        spoolmanMode = settings?.isActive ?? false
        do {
            let path = spoolmanMode ? "spoolman/inventory/spools" : "inventory/spools"
            // Decode element-wise so one malformed spool doesn't hide the rest.
            let raw: [JSONValue] = try await client.get(path, query: ["include_archived": false])
            spools = raw.compactMap { try? $0.decode(SpoolBuddySpool.self) }.filter { $0.archivedAt == nil }
            spoolsError = nil
        } catch {
            spoolsError = error.localizedDescription
        }
        spoolsLoaded = true
        if session.can("inventory:view_assignments") || session.can("inventory:read") {
            if spoolmanMode {
                spoolmanSlots = (try? await client.get("spoolman/inventory/slot-assignments/all")) ?? []
            } else {
                assignments = (try? await client.get("inventory/assignments")) ?? []
            }
        }
    }

    // MARK: Lookups

    func spool(_ id: Int) -> SpoolBuddySpool? { spools.first { $0.id == id } }

    func spool(tag: String) -> SpoolBuddySpool? {
        let key = Self.normalize(tag)
        guard !key.isEmpty else { return nil }
        return spools.first { Self.normalize($0.tagUid) == key || Self.normalize($0.trayUuid) == key }
    }

    /// Spool assigned to a printer slot.
    func assignedSpool(printerId: Int, amsId: Int, trayId: Int) -> SpoolBuddySpool? {
        if spoolmanMode {
            guard let slot = spoolmanSlots.first(where: { $0.printerId == printerId && $0.amsId == amsId && $0.trayId == trayId }) else { return nil }
            return spool(slot.spoolmanSpoolId)
        }
        guard let a = assignments.first(where: { $0.printerId == printerId && $0.amsId == amsId && $0.trayId == trayId }) else { return nil }
        return a.spool ?? spool(a.spoolId)
    }

    /// Human-readable slot label for where a spool is loaded, if assigned.
    func location(of spool: SpoolBuddySpool, printers: PrinterStore) -> String? {
        let hit: (Int, Int, Int)?
        if spoolmanMode {
            hit = spoolmanSlots.first { $0.spoolmanSpoolId == spool.id }.map { ($0.printerId, $0.amsId, $0.trayId) }
        } else {
            hit = assignments.first { $0.spoolId == spool.id }.map { ($0.printerId, $0.amsId, $0.trayId) }
        }
        guard let (p, ams, tray) = hit else { return nil }
        let name = printers.printer(p)?.name ?? "Printer \(p)"
        return "\(name) · \(Self.slotLabel(amsId: ams, trayId: tray))"
    }

    static func slotLabel(amsId: Int, trayId: Int) -> String {
        switch amsId {
        case 254, 255: return trayId == 0 ? "External" : "External R"
        case 128...135: return "AMS HT \(Character(UnicodeScalar(65 + amsId - 128)!))"
        default: return "AMS \(Character(UnicodeScalar(65 + min(max(amsId, 0), 25))!)) · Slot \(trayId + 1)"
        }
    }

    static func normalize(_ tag: String?) -> String {
        (tag ?? "").uppercased().filter { $0.isHexDigit }
    }

    // MARK: Mutations

    func linkTag(_ session: AppSession, spoolId: Int, tagUid: String?, trayUuid: String?) async throws {
        struct Local: Encodable { var tagUid: String?; var trayUuid: String?; var tagType: String?; var dataOrigin: String? }
        struct Remote: Encodable { var tagUid: String?; var trayUuid: String? }
        if spoolmanMode {
            try await session.client.call(.patch, "spoolman/inventory/spools/\(spoolId)/tag", body: Remote(tagUid: tagUid, trayUuid: trayUuid))
        } else {
            try await session.client.call(.patch, "inventory/spools/\(spoolId)/link-tag",
                                          body: Local(tagUid: tagUid, trayUuid: trayUuid, tagType: tagUid != nil ? "generic" : nil, dataOrigin: "nfc_link"))
        }
        await loadSpools(session)
    }

    /// Creates a basic spool for an unrecognized tag (details can be edited later in Inventory).
    func quickAdd(_ session: AppSession, tag: SpoolBuddyLiveState.UnknownTag, scaleGrams: Double?) async throws {
        struct Body: Encodable {
            var material = "PLA"
            var labelWeight = 1000
            var coreWeight = 250
            var weightUsed = 0
            var tagUid: String?
            var trayUuid: String?
            var dataOrigin: String?
            var tagType: String?
            var lastScaleWeight: Int?
            var lastWeighedAt: Date?
        }
        let weight = scaleGrams.map { Int($0.rounded()) }
        if spoolmanMode {
            let created: JSONValue = try await session.client.send(.post, "spoolman/inventory/spools",
                                                                   body: Body(lastScaleWeight: weight, lastWeighedAt: weight == nil ? nil : Date()))
            if let id = created["id"]?.intValue {
                try await linkTag(session, spoolId: id, tagUid: tag.tagUid, trayUuid: tag.tagUid == nil ? tag.trayUuid : nil)
            }
        } else {
            try await session.client.call(.post, "inventory/spools",
                                          body: Body(tagUid: tag.tagUid ?? tag.trayUuid, dataOrigin: "spoolbuddy", tagType: "generic",
                                                     lastScaleWeight: weight, lastWeighedAt: weight == nil ? nil : Date()))
        }
        await loadSpools(session)
    }

    @discardableResult
    func syncWeight(_ session: AppSession, spoolId: Int, grams: Double) async throws -> SpoolBuddyAck {
        struct Body: Encodable { var spoolId: Int; var weightGrams: Double }
        let ack: SpoolBuddyAck = try await session.client.send(.post, "spoolbuddy/scale/update-spool-weight", body: Body(spoolId: spoolId, weightGrams: grams))
        await loadSpools(session)
        return ack
    }

    /// Assigns a spool to a slot. Returns true when the slot configures later (spool not inserted yet).
    @discardableResult
    func assign(_ session: AppSession, spoolId: Int, printerId: Int, amsId: Int, trayId: Int) async throws -> Bool {
        var pending = false
        if spoolmanMode {
            struct Body: Encodable { var spoolmanSpoolId: Int; var printerId: Int; var amsId: Int; var trayId: Int }
            try await session.client.call(.post, "spoolman/inventory/slot-assignments",
                                          body: Body(spoolmanSpoolId: spoolId, printerId: printerId, amsId: amsId, trayId: trayId))
        } else {
            struct Body: Encodable { var spoolId: Int; var printerId: Int; var amsId: Int; var trayId: Int }
            let a: SpoolBuddyAssignment = try await session.client.send(.post, "inventory/assignments",
                                                                        body: Body(spoolId: spoolId, printerId: printerId, amsId: amsId, trayId: trayId))
            pending = a.pendingConfig ?? false
        }
        await loadSpools(session)
        return pending
    }

    func unassign(_ session: AppSession, printerId: Int, amsId: Int, trayId: Int) async throws {
        if spoolmanMode {
            guard let slot = spoolmanSlots.first(where: { $0.printerId == printerId && $0.amsId == amsId && $0.trayId == trayId }) else { return }
            try await session.client.call(.delete, "spoolman/inventory/slot-assignments/\(slot.spoolmanSpoolId)")
        } else {
            try await session.client.call(.delete, "inventory/assignments/\(printerId)/\(amsId)/\(trayId)")
        }
        await loadSpools(session)
    }
}
