import Foundation

/// `GET /system/info`. Every field is optional: the route builds a plain dict.
struct SystemInfo: Codable, Sendable {
    var app: SystemAppInfo?
    var database: SystemDatabaseInfo?
    var printers: SystemPrintersInfo?
    var storage: SystemStorageInfo?
    var system: SystemHostInfo?
    var memory: SystemMemoryInfo?
    var cpu: SystemCPUInfo?
}

struct SystemAppInfo: Codable, Sendable {
    var version: String?
    var baseDir: String?
    var archiveDir: String?
}

struct SystemDatabaseInfo: Codable, Sendable {
    var engine: String?
    var version: String?
    var archives: Int?
    var archivesCompleted: Int?
    var archivesFailed: Int?
    var archivesPrinting: Int?
    var printers: Int?
    var filaments: Int?
    var projects: Int?
    var smartPlugs: Int?
    var totalPrintTimeSeconds: Double?
    var totalPrintTimeFormatted: String?
    var totalFilamentGrams: Double?
    var totalFilamentKg: Double?
}

struct SystemPrintersInfo: Codable, Sendable {
    var total: Int?
    var connected: Int?
    var connectedList: [SystemConnectedPrinter]?
}

struct SystemConnectedPrinter: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String?
    var state: String?
    var model: String?
}

struct SystemStorageInfo: Codable, Sendable {
    var archiveSizeBytes: Double?
    var archiveSizeFormatted: String?
    var databaseSizeBytes: Double?
    var databaseSizeFormatted: String?
    var diskTotalBytes: Double?
    var diskTotalFormatted: String?
    var diskUsedBytes: Double?
    var diskUsedFormatted: String?
    var diskFreeBytes: Double?
    var diskFreeFormatted: String?
    var diskPercentUsed: Double?
}

struct SystemHostInfo: Codable, Sendable {
    var platform: String?
    var platformRelease: String?
    var platformVersion: String?
    var architecture: String?
    var hostname: String?
    var pythonVersion: String?
    var uptimeSeconds: Double?
    var uptimeFormatted: String?
    var bootTime: String?
}

struct SystemMemoryInfo: Codable, Sendable {
    var totalBytes: Double?
    var totalFormatted: String?
    var availableBytes: Double?
    var availableFormatted: String?
    var usedBytes: Double?
    var usedFormatted: String?
    var percentUsed: Double?
}

struct SystemCPUInfo: Codable, Sendable {
    var count: Int?
    var countLogical: Int?
    var percent: Double?
}

/// `GET /system/storage-usage`.
struct SystemStorageUsage: Codable, Sendable {
    var roots: [String]?
    var totalBytes: Double?
    var totalFormatted: String?
    var categories: [SystemStorageCategory]?
    var otherBreakdown: [SystemStorageCategory]?
    var scanErrors: Int?
    var generatedAt: String?
}

struct SystemStorageCategory: Codable, Sendable, Identifiable, Hashable {
    var key: String?
    var label: String?
    var bucket: String?
    var kind: String?
    var deletable: Bool?
    var bytes: Double?
    var formatted: String?
    var percentOfTotal: Double?
    var id: String { (key ?? bucket ?? label ?? "?") + "|" + (kind ?? "") }
}

/// `GET /system/health` — known-issue scan of recent logs.
struct SystemHealthScan: Codable, Sendable {
    var findings: [SystemHealthFinding]
    var scannedEntries: Int?
    var logAvailable: Bool?
    var summary: [String: Int]?
}

struct SystemHealthFinding: Codable, Sendable, Identifiable, Hashable {
    var signatureId: String
    var severity: String?
    var category: String?
    var wikiAnchor: String?
    var count: Int?
    var firstSeen: String?
    var lastSeen: String?
    var sample: String?
    var id: String { signatureId }

    var title: String {
        signatureId.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }

    var wikiURL: URL? {
        guard let wikiAnchor, !wikiAnchor.isEmpty else { return nil }
        return URL(string: "https://wiki.bambuddy.cool/reference/troubleshooting/#\(wikiAnchor)")
    }
}

/// `GET/POST /support/debug-logging`.
struct SystemDebugLogging: Codable, Sendable {
    var enabled: Bool
    var enabledAt: String?
    var durationSeconds: Int?
}

/// `GET /support/logs`.
struct SystemLogsResponse: Codable, Sendable {
    var entries: [SystemLogEntry]
    var totalInFile: Int?
    var filteredCount: Int?
}

struct SystemLogEntry: Codable, Sendable, Hashable {
    /// Python logging format, e.g. `2026-09-26 14:47:28,578` (kept as text).
    var timestamp: String
    var level: String
    var loggerName: String?
    var message: String
}

/// `GET /updates/check`.
struct SystemUpdateCheck: Codable, Sendable {
    var updateAvailable: Bool?
    var currentVersion: String?
    var latestVersion: String?
    var releaseName: String?
    var releaseNotes: String?
    var releaseUrl: String?
    var publishedAt: String?
    var isDocker: Bool?
    var isHaAddon: Bool?
    var isWindowsInstaller: Bool?
    var updateMethod: String?
    var installerDownloadUrl: String?
    var error: String?
    var message: String?
}

/// `POST /updates/apply` and `GET /updates/status`.
struct SystemUpdateStatus: Codable, Sendable {
    var status: String?
    var progress: Double?
    var message: String?
    var error: String?
    var success: Bool?
    var isDocker: Bool?
    var isHaAddon: Bool?
    var isWindowsInstaller: Bool?
}

/// `GET /printers/{id}/diagnostic`.
struct SystemPrinterDiagnostic: Codable, Sendable {
    var printerId: Int?
    var ipAddress: String?
    var overall: String?
    var checks: [SystemDiagnosticCheck]
}

struct SystemDiagnosticCheck: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var status: String
    var params: [String: JSONValue]?

    var title: String {
        switch id {
        case "port_mqtt": "MQTT port (8883)"
        case "port_ftps": "FTPS port (990)"
        case "port_rtsps": "Camera port (322)"
        case "network_mode": "LAN mode"
        case "subnet": "Same network"
        case "mqtt_auth": "Access code"
        case "developer_mode": "Developer mode"
        default: id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Bug report submission.
struct SystemBugReportRequest: Encodable, Sendable {
    var description: String
    var email: String?
    var screenshotBase64: String?
    var includeSupportInfo: Bool
    var debugLogs: String?
}

struct SystemBugReportResponse: Codable, Sendable {
    var success: Bool
    var message: String?
    var issueUrl: String?
    var issueNumber: Int?
}

struct SystemStartLogging: Codable, Sendable {
    var started: Bool?
    var wasDebug: Bool?
}

struct SystemStopLogging: Codable, Sendable {
    var logs: String?
}
