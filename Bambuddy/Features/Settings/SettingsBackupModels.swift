import Foundation

// MARK: - Full backup / local scheduled backups

/// `{success, message, filename?}` returned by restore, local-backup run/restore/delete.
struct SettingsBackupActionResult: Codable, Sendable {
    var success: Bool?
    var message: String?
    var filename: String?
}

/// `GET /local-backup/status`.
struct SettingsLocalBackupStatus: Codable, Sendable, Equatable {
    var isRunning: Bool?
    var lastBackupAt: String?
    /// `success` or `failed`.
    var lastStatus: String?
    var lastMessage: String?
    var nextRun: String?
    var enabled: Bool?
    var schedule: String?
    var time: String?
    var retention: Int?
    var path: String?
    var defaultPath: String?
    var timezone: String?
}

/// `GET /local-backup/path-check` — whether the output directory is writable.
struct SettingsLocalBackupPathCheck: Codable, Sendable, Equatable {
    var writable: Bool?
    var path: String?
    var code: String?
    var detail: String?
    var remedy: String?
    var message: String?
    /// e.g. `container_ephemeral` when the directory is only inside the container.
    var warning: String?
}

/// One entry of `GET /local-backup/backups`.
struct SettingsLocalBackupFile: Codable, Sendable, Identifiable, Hashable {
    var filename: String
    var size: Int64?
    var createdAt: String?

    var id: String { filename }
}

// MARK: - Git backup

/// `GET/POST/PATCH /github-backup/config`.
struct SettingsGitHubBackupConfig: Codable, Sendable, Equatable {
    var id: Int
    var repositoryUrl: String?
    var hasToken: Bool?
    var branch: String?
    /// `github`, `gitlab`, `gitea` or `forgejo`.
    var provider: String?
    var allowInsecureHttp: Bool?
    var scheduleEnabled: Bool?
    /// `hourly`, `daily` or `weekly`.
    var scheduleType: String?
    var backupKprofiles: Bool?
    var backupCloudProfiles: Bool?
    var backupSettings: Bool?
    var backupSpools: Bool?
    var backupArchives: Bool?
    var enabled: Bool?
    var lastBackupAt: String?
    var lastBackupStatus: String?
    var lastBackupMessage: String?
    var lastBackupCommitSha: String?
    var nextScheduledRun: String?
    var createdAt: String?
    var updatedAt: String?
}

/// `GET /github-backup/status`.
struct SettingsGitHubBackupStatus: Codable, Sendable, Equatable {
    var configured: Bool?
    var enabled: Bool?
    var isRunning: Bool?
    var restoreRunning: Bool?
    var progress: String?
    var lastBackupAt: String?
    var lastBackupStatus: String?
    var nextScheduledRun: String?
}

/// `POST /github-backup/test` and `/test-stored`.
struct SettingsGitHubTestResult: Codable, Sendable, Equatable {
    var success: Bool?
    var message: String?
    var repoName: String?
    var permissions: JSONValue?
    /// `true` confirmed private, `false` public, `nil` unknown.
    var isPrivate: Bool?
}

/// `POST /github-backup/run`.
struct SettingsGitHubTriggerResult: Codable, Sendable {
    var success: Bool?
    var message: String?
    var logId: Int?
    var commitSha: String?
    var filesChanged: Int?
}

/// One row of `GET /github-backup/logs`.
struct SettingsGitHubBackupLog: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var configId: Int?
    var startedAt: String?
    var completedAt: String?
    var status: String?
    /// `manual`, `scheduled`, `restore`…
    var trigger: String?
    var commitSha: String?
    var filesChanged: Int?
    var errorMessage: String?
}

/// `GET /github-backup/cloud-accounts`.
struct SettingsGitHubCloudAccounts: Codable, Sendable, Equatable {
    var bambu: Int?
    var orca: Int?

    var total: Int { (bambu ?? 0) + (orca ?? 0) }
}

/// One backup commit.
struct SettingsGitHubCommit: Codable, Sendable, Identifiable, Hashable {
    var sha: String
    var message: String?
    var author: String?
    var date: String?

    var id: String { sha }
    var shortSha: String { String(sha.prefix(7)) }
    var title: String { (message ?? "").split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }
}

/// `GET /github-backup/commits`.
struct SettingsGitHubCommitList: Codable, Sendable {
    var success: Bool?
    var message: String?
    var branch: String?
    var commits: [SettingsGitHubCommit]?
}

/// One category in a restore preview.
struct SettingsGitHubRestorePreviewCategory: Codable, Sendable, Hashable, Identifiable {
    /// `kprofiles`, `settings`, `spools` or `archives`.
    var category: String
    var available: Bool?
    var itemCount: Int?
    var detail: String?
    var detailCode: String?

    var id: String { category }
}

/// `GET /github-backup/restore/preview`.
struct SettingsGitHubRestorePreview: Codable, Sendable {
    var success: Bool?
    var message: String?
    /// The concrete SHA inspected (restore this exact commit).
    var ref: String?
    var commit: SettingsGitHubCommit?
    var metadataVersion: String?
    var categories: [SettingsGitHubRestorePreviewCategory]?
}

/// `POST /github-backup/restore` body.
struct SettingsGitHubRestoreRequest: Encodable, Sendable {
    var ref: String
    var categories: [String]
    var overwriteExisting: Bool
}

/// A note attached to a restore tally.
struct SettingsGitHubRestoreNote: Codable, Sendable, Hashable {
    var code: String?
    var message: String?
}

/// Per-category outcome of a restore.
struct SettingsGitHubRestoreTally: Codable, Sendable, Hashable {
    var restored: Int?
    var skipped: Int?
    var failed: Int?
    var notes: [SettingsGitHubRestoreNote]?
}

/// `POST /github-backup/restore` response.
struct SettingsGitHubRestoreResult: Codable, Sendable {
    var success: Bool?
    var message: String?
    var logId: Int?
    var ref: String?
    var results: [String: SettingsGitHubRestoreTally]?
}

/// Editable Git backup configuration.
struct SettingsGitHubBackupDraft: Equatable, Sendable {
    var provider = "github"
    var repositoryUrl = ""
    var accessToken = ""
    var branch = "main"
    var allowInsecureHttp = false
    /// `manual` (no schedule), `hourly`, `daily`, `weekly`.
    var schedule = "manual"
    var backupKprofiles = true
    var backupCloudProfiles = true
    var backupSettings = false
    var backupSpools = false
    var backupArchives = false
    var enabled = true

    init() {}

    init(_ config: SettingsGitHubBackupConfig) {
        provider = config.provider ?? "github"
        repositoryUrl = config.repositoryUrl ?? ""
        branch = config.branch ?? "main"
        allowInsecureHttp = config.allowInsecureHttp ?? false
        schedule = config.scheduleEnabled == true ? (config.scheduleType ?? "daily") : "manual"
        backupKprofiles = config.backupKprofiles ?? true
        backupCloudProfiles = config.backupCloudProfiles ?? true
        backupSettings = config.backupSettings ?? false
        backupSpools = config.backupSpools ?? false
        backupArchives = config.backupArchives ?? false
        enabled = config.enabled ?? true
    }

    private var trimmedURL: String { repositoryUrl.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBranch: String {
        let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? "main" : b
    }
    private var scheduleEnabled: Bool { schedule != "manual" }
    private var scheduleType: String { scheduleEnabled ? schedule : "daily" }

    /// Plain HTTP URLs need the insecure-HTTP opt-in.
    var needsInsecureOptIn: Bool { trimmedURL.lowercased().hasPrefix("http://") && !allowInsecureHttp }

    /// Full body for `POST /github-backup/config` (create, or replace including the token).
    func createBody() -> JSONValue {
        var body = fields()
        body["access_token"] = .string(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))
        return .object(body)
    }

    /// Only the changed fields, for `PATCH /github-backup/config`.
    func patchBody(from base: SettingsGitHubBackupDraft) -> [String: JSONValue] {
        let mine = fields(), theirs = base.fields()
        var out: [String: JSONValue] = [:]
        for (key, value) in mine where theirs[key] != value { out[key] = value }
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { out["access_token"] = .string(token) }
        return out
    }

    private func fields() -> [String: JSONValue] {
        [
            "repository_url": .string(trimmedURL),
            "branch": .string(trimmedBranch),
            "provider": .string(provider),
            "allow_insecure_http": .bool(allowInsecureHttp),
            "schedule_enabled": .bool(scheduleEnabled),
            "schedule_type": .string(scheduleType),
            "backup_kprofiles": .bool(backupKprofiles),
            "backup_cloud_profiles": .bool(backupCloudProfiles),
            "backup_settings": .bool(backupSettings),
            "backup_spools": .bool(backupSpools),
            "backup_archives": .bool(backupArchives),
            "enabled": .bool(enabled),
        ]
    }
}
