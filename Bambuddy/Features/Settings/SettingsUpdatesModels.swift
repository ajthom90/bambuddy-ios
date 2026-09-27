import Foundation

// MARK: - Bambuddy software updates

/// `GET /updates/version`
struct SettingsUpdateVersion: Codable, Sendable, Hashable {
    var version: String?
    var repo: String?
}

/// `GET /updates/check`. The server returns one of three shapes: a full release report,
/// `{error, retry_after_seconds}` when GitHub can't be reached, or `{message}` when checks are off.
struct SettingsUpdateCheck: Codable, Sendable, Hashable {
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
    /// "ha_addon", "docker", "windows_installer" or "git".
    var updateMethod: String?
    var installerDownloadUrl: String?
    var composeDirDetected: String?
    var error: String?
    var message: String?
    var retryAfterSeconds: Int?

    /// The deployment shape, falling back to the individual flags for older servers.
    var resolvedMethod: String {
        if let updateMethod, !updateMethod.isEmpty { return updateMethod }
        if isHaAddon == true { return "ha_addon" }
        if isDocker == true { return "docker" }
        if isWindowsInstaller == true { return "windows_installer" }
        return "git"
    }

    /// Only plain git checkouts can be updated in place by the server.
    var canInstallInApp: Bool { updateAvailable == true && resolvedMethod == "git" }
}

/// `GET /updates/status` (also embedded in the apply response).
struct SettingsUpdateStatus: Codable, Sendable, Hashable {
    /// idle, checking, downloading, installing, complete, error
    var status: String?
    var progress: Double?
    var message: String?
    var error: String?

    var isRunning: Bool { status == "downloading" || status == "installing" }
}

/// `POST /updates/apply`
struct SettingsUpdateApplyResult: Codable, Sendable {
    var success: Bool?
    var message: String?
    var status: SettingsUpdateStatus?
    var isDocker: Bool?
    var isHaAddon: Bool?
    var isWindowsInstaller: Bool?
}

enum SettingsUpdateInstructions {
    /// The shell command that updates a Docker Compose install. Prefixed with a `cd` into the
    /// saved (or detected) compose directory, quoted only when the path contains whitespace.
    static func composeCommand(savedDirectory: String?, detectedDirectory: String?) -> String {
        let saved = (savedDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = (detectedDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = saved.isEmpty ? detected : saved
        let update = "docker compose pull && docker compose up -d"
        guard !dir.isEmpty else { return update }
        let quoted = dir.contains(where: \.isWhitespace) ? "\"\(dir)\"" : dir
        return "cd \(quoted) && \(update)"
    }
}

// MARK: - Printer firmware

/// `GET /firmware/updates`
struct SettingsFirmwareUpdates: Codable, Sendable {
    var updates: [SettingsFirmwareUpdateInfo]?
    var updatesAvailable: Int?
}

struct SettingsFirmwareUpdateInfo: Codable, Sendable, Hashable, Identifiable {
    var printerId: Int
    var printerName: String?
    var model: String?
    var currentVersion: String?
    var latestVersion: String?
    var updateAvailable: Bool?
    var downloadUrl: String?
    var releaseNotes: String?
    var availableVersions: [SettingsFirmwareVersion]?

    var id: Int { printerId }
}

struct SettingsFirmwareVersion: Codable, Sendable, Hashable {
    var version: String
    var fileAvailable: Bool?
    var downloadUrl: String?
    var releaseNotes: String?
    var releaseTime: String?
}

/// `GET /firmware/latest`
struct SettingsFirmwareLatest: Codable, Sendable, Hashable, Identifiable {
    var modelKey: String
    var version: String?
    var downloadUrl: String?
    var releaseNotes: String?

    var id: String { modelKey }

    /// Printer family names for the server's model keys.
    var familyName: String {
        switch modelKey.lowercased() {
        case "x1": "X1 Series"
        case "p1": "P1 Series"
        case "a1-mini", "a1mini", "a1_mini": "A1 mini"
        case "h2d-pro", "h2d_pro": "H2D Pro"
        default: modelKey.uppercased().replacingOccurrences(of: "-", with: " ")
        }
    }
}

// MARK: - Release notes

/// A minimal block-level Markdown splitter for release notes (headings, list items,
/// paragraphs); inline styling is left to `AttributedString(markdown:)`.
enum SettingsUpdateMarkdown {
    enum Block: Hashable, Sendable {
        case heading(level: Int, text: String)
        case bullet(text: String, indent: Int)
        case numbered(marker: String, text: String, indent: Int)
        case paragraph(String)
        case rule
    }

    static func blocks(from markdown: String) -> [Block] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for rawLine in normalized.components(separatedBy: "\n") {
            let leading = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let indent = leading / 2
            if line.isEmpty { flush(); continue }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), line.count >= 3 { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6, !text.isEmpty { flush(); blocks.append(.heading(level: level, text: text)); continue }
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush(); blocks.append(.bullet(text: String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces), indent: indent)); continue
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), dot > line.startIndex,
               line[line.startIndex..<dot].allSatisfy(\.isNumber),
               line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                flush()
                let marker = String(line[line.startIndex...dot])
                blocks.append(.numbered(marker: marker, text: String(line[line.index(dot, offsetBy: 2)...]), indent: indent))
                continue
            }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    /// Inline Markdown (bold, italics, code, links) with a plain-text fallback.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
