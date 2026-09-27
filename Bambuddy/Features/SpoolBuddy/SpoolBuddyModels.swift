import Foundation

/// A registered SpoolBuddy station (`GET /spoolbuddy/devices`).
struct SpoolBuddyDevice: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var deviceId: String
    var hostname: String
    var ipAddress: String
    var firmwareVersion: String?
    var hasNfc: Bool
    var hasScale: Bool
    var tareOffset: Int
    var calibrationFactor: Double
    var nfcReaderType: String?
    var nfcConnection: String?
    var backendUrl: String?
    var displayBrightness: Int?
    var displayBlankTimeout: Int?
    var hasBacklight: Bool?
    var lastCalibratedAt: String?
    var lastSeen: String?
    var pendingCommand: String?
    var nfcOk: Bool
    var scaleOk: Bool
    var uptimeS: Int
    var updateStatus: String?
    var updateMessage: String?
    var systemStats: JSONValue?
    var online: Bool?
    var sshPublicKey: String?
    var createdAt: String?
    var updatedAt: String?

    var isOnline: Bool { online ?? false }
    var displayName: String { hostname.isEmpty ? deviceId : hostname }
}

/// `GET /spoolbuddy/devices/{id}/update-check`.
struct SpoolBuddyUpdateCheck: Codable, Sendable {
    var currentVersion: String?
    var latestVersion: String?
    var updateAvailable: Bool?
}

/// `GET /spoolbuddy/devices/{id}/calibration` and calibration mutations.
struct SpoolBuddyCalibration: Codable, Sendable {
    var tareOffset: Int?
    var calibrationFactor: Double?
}

/// `GET /spoolbuddy/diagnostics/{id}/result`.
struct SpoolBuddyDiagnosticResult: Codable, Sendable {
    var diagnostic: String?
    var success: Bool?
    var output: String?
    var exitCode: Int?
}

/// Generic `{status, message}` acknowledgement from the device command routes.
struct SpoolBuddyAck: Codable, Sendable {
    var status: String?
    var message: String?
    var warnings: [String]?
    var weightUsed: Double?
}

/// A spool from the local inventory (`/inventory/spools`) or the Spoolman
/// bridge (`/spoolman/inventory/spools`, mapped to the same shape).
struct SpoolBuddySpool: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var material: String?
    var subtype: String?
    var colorName: String?
    var rgba: String?
    var brand: String?
    var labelWeight: Double?
    var coreWeight: Double?
    var weightUsed: Double?
    var tagUid: String?
    var trayUuid: String?
    var dataOrigin: String?
    var tagType: String?
    var lastScaleWeight: Double?
    var lastWeighedAt: String?
    var storageLocation: String?
    var note: String?
    var archivedAt: String?
    var createdAt: String?

    var title: String {
        let parts = [brand, material, subtype].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Spool #\(id)" : parts.joined(separator: " ")
    }

    var remaining: Double? {
        guard let labelWeight else { return nil }
        return max(0, labelWeight - (weightUsed ?? 0))
    }

    var remainingFraction: Double? {
        guard let labelWeight, labelWeight > 0, let remaining else { return nil }
        return min(1, remaining / labelWeight)
    }

    var hexColor: String? {
        guard let rgba, rgba.count >= 6 else { return nil }
        return String(rgba.prefix(6))
    }

    var isTagged: Bool { !(tagUid ?? "").isEmpty || !(trayUuid ?? "").isEmpty }
}

/// `GET /inventory/assignments`.
struct SpoolBuddyAssignment: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var spoolId: Int
    var printerId: Int
    var printerName: String?
    var amsId: Int
    var trayId: Int
    var fingerprintColor: String?
    var fingerprintType: String?
    var createdAt: String?
    var spool: SpoolBuddySpool?
    var configured: Bool?
    var pendingConfig: Bool?
    var amsLabel: String?
}

/// `GET /spoolman/inventory/slot-assignments` (Spoolman mode).
struct SpoolBuddySpoolmanSlot: Codable, Sendable, Hashable {
    var printerId: Int
    var printerName: String?
    var amsId: Int
    var trayId: Int
    var spoolmanSpoolId: Int
    var amsLabel: String?
}

/// `GET /settings/spoolman` — values are strings ("true"/"false").
struct SpoolBuddySpoolmanSettings: Codable, Sendable {
    var spoolmanEnabled: String?
    var spoolmanUrl: String?

    var isActive: Bool { spoolmanEnabled?.lowercased() == "true" && !(spoolmanUrl ?? "").isEmpty }
}

/// The spool summary carried by a `spoolbuddy_tag_matched` event.
struct SpoolBuddyMatchedSpool: Sendable, Hashable {
    var id: Int
    var tagUid: String
    var material: String
    var subtype: String?
    var colorName: String?
    var rgba: String?
    var brand: String?
    var labelWeight: Double
    var coreWeight: Double
    var weightUsed: Double

    var title: String {
        [brand, material, subtype].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    var hexColor: String? { rgba.map { String($0.prefix(6)) } }
}
