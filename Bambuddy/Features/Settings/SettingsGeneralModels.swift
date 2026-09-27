import Foundation

// MARK: - Storage usage (`GET /system/storage-usage`)

struct SettingsGeneralStorageUsage: Codable, Sendable {
    var roots: [String]?
    var totalBytes: Double?
    var totalFormatted: String?
    var categories: [SettingsGeneralStorageCategory]?
    var otherBreakdown: [SettingsGeneralStorageOtherItem]?
    var scanErrors: Int?
    var generatedAt: String?
    var cache: SettingsGeneralStorageCache?

    /// Categories that actually hold data, largest first (the server already sorts them).
    var visibleCategories: [SettingsGeneralStorageCategory] {
        (categories ?? []).filter { ($0.bytes ?? 0) > 0 }
    }
}

struct SettingsGeneralStorageCategory: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var label: String?
    var bytes: Double?
    var formatted: String?
    var percentOfTotal: Double?

    var id: String { key }
    var displayName: String { (label?.isEmpty == false ? label : nil) ?? key }
}

struct SettingsGeneralStorageOtherItem: Codable, Sendable, Hashable {
    var bucket: String?
    var label: String?
    /// "system" or "data".
    var kind: String?
    var deletable: Bool?
    var bytes: Double?
    var formatted: String?
    var percentOfTotal: Double?
}

struct SettingsGeneralStorageCache: Codable, Sendable, Hashable {
    var hit: Bool?
    var ageSeconds: Double?
    var maxAgeSeconds: Double?
}

// MARK: - Misc responses

/// `GET /settings/check-ffmpeg`
struct SettingsGeneralFfmpegStatus: Codable, Sendable, Hashable {
    var installed: Bool?
    var path: String?
}

/// `DELETE /notifications/logs?older_than_days=N`
struct SettingsGeneralClearLogsResult: Codable, Sendable {
    var deleted: Int?
    var message: String?
}

/// `GET/PUT /archives/purge/settings` (request and response share the shape).
struct SettingsGeneralArchivePurge: Codable, Sendable, Hashable {
    var enabled: Bool?
    var days: Int?
    var purgeStats: Bool?
}

/// `GET/PUT /library/trash/settings` (request and response share the shape;
/// `retention_days` is required on PUT).
struct SettingsGeneralTrashSettings: Codable, Sendable, Hashable {
    var retentionDays: Int?
    var autoPurgeEnabled: Bool?
    var autoPurgeDays: Int?
    var autoPurgeIncludeNeverPrinted: Bool?
}

// MARK: - Choices

enum SettingsGeneralChoices {
    /// Interface languages the server/web UI ships translations for.
    static let languageCodes = ["en", "de", "es", "fr", "it", "ja", "ko", "nl", "pt-BR", "ru", "tr", "uk", "zh-CN", "zh-TW"]

    /// "Deutsch (German)" style label built from the system's locale data.
    static func languageLabel(_ code: String, displayLocale: Locale = .current) -> String {
        let native = Locale(identifier: code).localizedString(forIdentifier: code)
        let local = displayLocale.localizedString(forIdentifier: code)
        switch (native, local) {
        case let (n?, l?) where n.caseInsensitiveCompare(l) != .orderedSame:
            return "\(n.prefix(1).uppercased() + n.dropFirst()) (\(l))"
        case let (n?, _): return n.prefix(1).uppercased() + n.dropFirst()
        case let (nil, l?): return l
        default: return code
        }
    }

    /// Clamps a purge age to the range the server accepts.
    static func clampPurgeDays(_ value: Int) -> Int { min(max(value, 7), 3650) }
}
