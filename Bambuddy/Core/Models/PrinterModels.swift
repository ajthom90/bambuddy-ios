import Foundation

struct Printer: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var serialNumber: String
    var ipAddress: String
    var model: String?
    var location: String?
    var autoArchive: Bool?
    var externalCameraUrl: String?
    var externalCameraType: String?
    var externalCameraEnabled: Bool?
    var externalCameraSnapshotUrl: String?
    var cameraRotation: Int?
    var isActive: Bool
    var nozzleCount: Int?
    var supportsNozzleFlowType: Bool?
    var printHoursOffset: Double?
    var plateDetectionEnabled: Bool?
    var accessCode: String?
    var createdAt: String?
    var updatedAt: String?
}

struct PrinterCreate: Codable, Sendable {
    var name: String
    var serialNumber: String
    var ipAddress: String
    var accessCode: String
    var model: String?
    var location: String?
    var autoArchive: Bool = true
}

struct HMSError: Codable, Sendable, Hashable {
    var code: String
    var attr: Int?
    var module: Int
    var severity: Int
    var actions: [String]?
    var jobId: String?
    var fullCode: String?
    var description: String?

    var severityLabel: String {
        switch severity {
        case 1: return "Fatal"
        case 2: return "Serious"
        case 3: return "Common"
        case 4: return "Info"
        default: return "Notice"
        }
    }
}

struct AMSTray: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var trayColor: String?
    var trayType: String?
    var traySubBrands: String?
    var trayIdName: String?
    var trayInfoIdx: String?
    var remain: Int?
    var k: Double?
    var caliIdx: Int?
    var tagUid: String?
    var trayUuid: String?
    var nozzleTempMin: Int?
    var nozzleTempMax: Int?
    var dryingTemp: Int?
    var dryingTime: Int?
    var state: Int?
    var exists: Bool?

    var isEmpty: Bool { (trayType ?? "").isEmpty }
    var displayName: String {
        let sub = (traySubBrands ?? "").trimmingCharacters(in: .whitespaces)
        if !sub.isEmpty { return sub }
        return (trayType ?? "").isEmpty ? "Empty" : trayType!
    }
}

struct AMSUnit: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var humidity: Int?
    var temp: Double?
    var isAmsHt: Bool?
    var tray: [AMSTray]?
    var serialNumber: String?
    var swVer: String?
    var dryTime: Int?
    var dryStatus: Int?
    var drySubStatus: Int?
    var dryTargetTemp: Int?
    var dryFilament: String?
    var moduleType: String?

    /// Global tray index as used by `ams/load` (`ams_id * 4 + tray`; AMS-HT ids start at 128).
    func globalTrayId(_ trayId: Int) -> Int { id >= 128 ? id : id * 4 + trayId }
    var label: String {
        if id >= 128 { return "AMS HT \(id - 127)" }
        return "AMS \(Character(UnicodeScalar(65 + min(id, 25))!))"
    }
    var isDrying: Bool { (dryStatus ?? 0) != 0 }
}

struct NozzleInfo: Codable, Sendable, Hashable {
    var nozzleType: String?
    var nozzleDiameter: String?
}

struct PrintOptions: Codable, Sendable, Hashable {
    var spaghettiDetector: Bool?
    var printHalt: Bool?
    var haltPrintSensitivity: String?
    var firstLayerInspector: Bool?
    var printingMonitor: Bool?
    var buildplateMarkerDetector: Bool?
    var allowSkipParts: Bool?
    var nozzleClumpingDetector: Bool?
    var nozzleClumpingSensitivity: String?
    var pileupDetector: Bool?
    var pileupSensitivity: String?
    var airprintDetector: Bool?
    var airprintSensitivity: String?
    var autoRecoveryStepLoss: Bool?
    var filamentTangleDetect: Bool?
}

/// Live printer state from `GET /printers/{id}/status` merged with WebSocket deltas.
struct PrinterStatus: Codable, Sendable, Hashable {
    var id: Int
    var name: String
    var connected: Bool
    var state: String?
    var currentPrint: String?
    var subtaskName: String?
    var gcodeFile: String?
    var progress: Double?
    var remainingTime: Int?
    var layerNum: Int?
    var totalLayers: Int?
    var temperatures: [String: JSONValue]?
    var coverUrl: String?
    var hmsErrors: [HMSError]?
    var ams: [AMSUnit]?
    var amsExists: Bool?
    var vtTray: [AMSTray]?
    var sdcard: Bool?
    var storeToSdcard: Bool?
    var timelapse: Bool?
    var ipcam: Bool?
    var wifiSignal: Int?
    var wiredNetwork: Bool?
    var doorOpen: Bool?
    var nozzles: [NozzleInfo]?
    var printOptions: PrintOptions?
    var stgCur: Int?
    var stgCurName: String?
    var airductMode: Int?
    var speedLevel: Int?
    var chamberLight: Bool?
    var activeExtruder: Int?
    var trayNow: Int?
    var printableObjectsCount: Int?
    var coolingFanSpeed: Int?
    var bigFan1Speed: Int?
    var bigFan2Speed: Int?
    var heatbreakFanSpeed: Int?
    var exhaustFanPresent: Bool?
    var firmwareVersion: String?
    var developerMode: Bool?
    var amsFilamentBackup: Bool?
    var awaitingPlateClear: Bool?
    var supportsDrying: Bool?
    var supportsDryingWhilePrinting: Bool?
    var supportsChamberHeater: Bool?
    var currentArchiveId: Int?
    var currentPlateId: Int?

    func temp(_ key: String) -> Double? { temperatures?[key]?.doubleValue }

    var isPrinting: Bool { state == "RUNNING" || state == "PREPARE" || state == "SLICING" }
    var isPaused: Bool { state == "PAUSE" }
    var isActiveJob: Bool { isPrinting || isPaused }
    var isDualNozzle: Bool { temperatures?["nozzle_2"] != nil || (nozzles?.count ?? 0) > 1 && !(nozzles?[1].nozzleDiameter ?? "").isEmpty }
    var hasChamberTemp: Bool { temperatures?["chamber"] != nil }

    var stateLabel: String {
        guard connected else { return "Offline" }
        switch state {
        case "RUNNING": return "Printing"
        case "PAUSE": return "Paused"
        case "FINISH": return "Finished"
        case "FAILED": return "Failed"
        case "PREPARE": return "Preparing"
        case "SLICING": return "Slicing"
        case "IDLE", nil: return "Idle"
        default: return state!.capitalized
        }
    }

    var jobName: String? {
        let n = subtaskName ?? currentPrint ?? gcodeFile
        return (n?.isEmpty ?? true) ? nil : n
    }

    /// Speed level names used by Bambu firmware.
    static let speedLevels: [(Int, String)] = [(1, "Silent"), (2, "Standard"), (3, "Sport"), (4, "Ludicrous")]
}
