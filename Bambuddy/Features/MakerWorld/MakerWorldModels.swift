import Foundation

// MakerWorld URL-paste import (`/makerworld/*`). The design / instance payloads
// are MakerWorld's own camelCase JSON passed through verbatim, so they stay as
// `JSONValue` and are read through the typed accessors below.

struct MakerWorldStatus: Decodable, Hashable, Sendable {
    var hasCloudToken: Bool?
    var canDownload: Bool?
    var signInExpired: Bool?
}

struct MakerWorldResolvedModel: Decodable, Sendable {
    var modelId: Int
    var profileId: Int?
    var design: JSONValue?
    var instances: [JSONValue]?
    var alreadyImportedLibraryIds: [Int]?

    var title: String? { design?["title"]?.stringValue }
    var creatorName: String? { design?["designCreator"]?["name"]?.stringValue }
    var coverURL: String? { design?["coverUrl"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    var summaryHTML: String? { design?["summary"]?.stringValue }
    var license: String? { design?["license"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    var downloadCount: Int? { design?["downloadCount"]?.intValue }
    var likeCount: Int? { design?["likeCount"]?.intValue }
    var printCount: Int? { design?["printCount"]?.intValue }
    var tags: [String] { design?["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    var plates: [MakerWorldInstance] { (instances ?? []).compactMap(MakerWorldInstance.init) }

    var webURL: URL? {
        var s = "https://makerworld.com/models/\(modelId)"
        if let profileId { s += "#profileId-\(profileId)" }
        return URL(string: s)
    }
}

/// One printable configuration ("plate"/profile) of a MakerWorld model.
struct MakerWorldInstance: Identifiable, Hashable, Sendable {
    let id: Int
    var profileId: Int?
    var title: String?
    var cover: String?
    var materialCount: Int?
    var needsAMS: Bool
    var downloadCount: Int?
    var primaryPrinter: String?
    var otherPrinters: [String]
    var pictures: [MakerWorldPicture]

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.intValue else { return nil }
        self.id = id
        profileId = json["profileId"]?.intValue
        title = json["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        cover = json["cover"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        materialCount = json["materialCnt"]?.intValue
        needsAMS = json["needAms"]?.boolValue ?? false
        downloadCount = json["downloadCount"]?.intValue
        primaryPrinter = json["compatibility"]?["devProductName"]?.stringValue
        otherPrinters = json["otherCompatibility"]?.arrayValue?.compactMap { $0["devProductName"]?.stringValue }.filter { !$0.isEmpty } ?? []
        let pics = json["pictures"]?.arrayValue?.compactMap { p -> MakerWorldPicture? in
            guard let url = p["url"]?.stringValue, !url.isEmpty else { return nil }
            return MakerWorldPicture(name: p["name"]?.stringValue ?? "image", url: url)
        } ?? []
        if pics.isEmpty, let cover {
            pictures = [MakerWorldPicture(name: "cover", url: cover)]
        } else {
            pictures = pics
        }
    }
}

struct MakerWorldPicture: Hashable, Sendable, Identifiable {
    var name: String
    var url: String
    var id: String { url }
}

struct MakerWorldImportResult: Decodable, Hashable, Sendable {
    var libraryFileId: Int
    var filename: String
    var folderId: Int?
    var profileId: Int?
    var wasExisting: Bool?
}

struct MakerWorldRecentImport: Decodable, Identifiable, Hashable, Sendable {
    var libraryFileId: Int
    var filename: String
    var folderId: Int?
    var thumbnailPath: String?
    var sourceUrl: String?
    var createdAt: String?
    var id: Int { libraryFileId }
}

struct MakerWorldResolveBody: Encodable, Sendable {
    var url: String
}

struct MakerWorldImportBody: Encodable, Sendable {
    var modelId: Int
    var profileId: Int?
    var instanceId: Int?
    var folderId: Int?
}

enum MakerWorldMedia {
    /// MakerWorld's CDN can't be hot-linked; the server proxies it (no auth needed).
    static func proxied(_ url: String?, client: APIClient) -> String? {
        guard let url, !url.isEmpty else { return nil }
        guard url.range(of: #"^https?://(makerworld|public-cdn)\.bblmw\.com/"#, options: [.regularExpression, .caseInsensitive]) != nil else { return url }
        return client.url("makerworld/thumbnail", query: ["url": .string(url)]).absoluteString
    }

    /// Converts the design summary HTML to readable plain text (images and
    /// scripts are dropped before parsing so nothing is fetched).
    @MainActor
    static func plainText(fromHTML html: String) -> String {
        var cleaned = html
        for pattern in [#"<img[^>]*>"#, #"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<iframe[\s\S]*?</iframe>"#, #"<video[\s\S]*?</video>"#] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        if let data = cleaned.data(using: .utf8),
           let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            cleaned = attributed.string
        } else {
            cleaned = cleaned.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        }
        return cleaned
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Accepts anything that looks like a MakerWorld model link.
    static func looksLikeModelURL(_ s: String) -> Bool {
        s.range(of: #"makerworld\.com(\.cn)?/.*models/\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
