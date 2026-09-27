import Foundation
import UniformTypeIdentifiers

/// `ExternalLinkResponse` — a custom link shown in the web interface's sidebar.
struct SettingsExternalLink: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var url: String
    /// Name from the server's icon set (see `SettingsExternalLinkIcons`).
    var icon: String?
    var openInNewTab: Bool?
    /// File name of an uploaded icon, served from `external-links/{id}/icon`.
    var customIcon: String?
    var sortOrder: Int?
    var createdAt: String?
    var updatedAt: String?

    var customIconPath: String? {
        guard let customIcon, !customIcon.isEmpty else { return nil }
        return "external-links/\(id)/icon"
    }
}

/// Body for `POST /external-links/` and `PATCH /external-links/{id}`.
struct SettingsExternalLinkBody: Codable, Sendable, Hashable {
    var name: String
    var url: String
    var icon: String
    var openInNewTab: Bool
}

/// Body for `PUT /external-links/reorder`.
struct SettingsExternalLinkReorder: Codable, Sendable, Hashable {
    var ids: [Int]
}

enum SettingsExternalLinkIcons {
    /// The server's icon names (Lucide identifiers) paired with the closest SF Symbol.
    static let all: [(name: String, symbol: String)] = [
        ("globe", "globe"), ("link", "link"), ("external-link", "arrow.up.right.square"), ("book", "book"),
        ("file-text", "doc.text"), ("home", "house"), ("star", "star"), ("heart", "heart"), ("bookmark", "bookmark"),
        ("shopping-cart", "cart"), ("music", "music.note"), ("video", "video"), ("image", "photo"), ("camera", "camera"),
        ("map", "map"), ("compass", "safari"), ("coffee", "cup.and.saucer"), ("gift", "gift"), ("wrench", "wrench.adjustable"),
        ("zap", "bolt"), ("cloud", "cloud"), ("database", "cylinder.split.1x2"), ("folder", "folder"), ("mail", "envelope"),
        ("phone", "phone"), ("user", "person"), ("users", "person.2"), ("server", "server.rack"), ("terminal", "terminal"),
        ("code", "chevron.left.forwardslash.chevron.right"),
    ]

    static func symbol(for name: String?) -> String {
        all.first { $0.name == name }?.symbol ?? "link"
    }

    /// File extensions the upload endpoint accepts.
    static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico"]
    static let maxUploadBytes = 1_024 * 1_024

    static var importableTypes: [UTType] {
        [.png, .jpeg, .gif, .svg, .webP, .ico]
    }

    /// Name validation mirroring the server (1–50 characters).
    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 50
    }

    /// URL validation mirroring the server (http/https, at most 500 characters).
    static func isValidURL(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) && trimmed.count > 8 && trimmed.count <= 500
    }
}
