import Foundation

/// `GET/POST /support/debug-logging`.
struct SettingsSupportDebugState: Codable, Sendable, Equatable {
    var enabled: Bool
    var enabledAt: String?
    var durationSeconds: Int?
}

/// `POST /support/debug-logging` body.
struct SettingsSupportDebugToggle: Encodable, Sendable {
    var enabled: Bool
}

/// One parsed line (or multi-line record) of the application log.
struct SettingsSupportLogEntry: Codable, Sendable, Hashable {
    /// Server format: `2026-09-26 14:55:46,116`.
    var timestamp: String?
    /// `DEBUG`, `INFO`, `WARNING`, `ERROR` (others possible).
    var level: String?
    var loggerName: String?
    var message: String?

    /// Just the time-of-day part of the timestamp.
    var timeText: String {
        guard let timestamp else { return "" }
        let parts = timestamp.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : timestamp
    }

    var isMultiline: Bool { (message ?? "").contains("\n") }
}

/// `GET /support/logs`.
struct SettingsSupportLogsResponse: Codable, Sendable {
    var entries: [SettingsSupportLogEntry]?
    var totalInFile: Int?
    var filteredCount: Int?
}
