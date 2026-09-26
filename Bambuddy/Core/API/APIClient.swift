import Foundation

/// Error surfaced from the Bambuddy API. Mirrors FastAPI's `detail` payloads:
/// a plain string, a `{code, message, ...}` object, or a validation error list.
struct APIError: LocalizedError, Sendable {
    let status: Int
    let message: String
    let code: String?
    let detail: JSONValue?

    var errorDescription: String? { message }

    static func from(status: Int, data: Data) -> APIError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        let detail = json?["detail"]
        var code: String?
        var message: String
        switch detail {
        case .string(let s)?:
            message = s
        case .object(let o)?:
            code = o["code"]?.stringValue
            message = o["message"]?.stringValue ?? o["detail"]?.stringValue ?? code ?? "Request failed"
        case .array(let items)?:
            message = items.compactMap { item -> String? in
                guard let msg = item["msg"]?.stringValue else { return nil }
                let loc = item["loc"]?.arrayValue?.compactMap(\.stringValue).filter { $0 != "body" && $0 != "query" }.joined(separator: ".")
                return loc.map { $0.isEmpty ? msg : "\($0): \(msg)" } ?? msg
            }.joined(separator: "\n")
        default:
            message = json?["message"]?.stringValue
                ?? String(data: data.prefix(300), encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
                ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }
        if message.isEmpty { message = "Request failed (\(status))" }
        return APIError(status: status, message: message, code: code, detail: detail)
    }
}

/// Decodes any response body (or none). Use for endpoints whose body is irrelevant.
struct EmptyResponse: Decodable, Sendable {
    init() {}
    init(from decoder: Decoder) throws {}
}

enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

/// A single file part for multipart uploads.
struct UploadFile: Sendable {
    var fieldName: String = "file"
    var fileName: String
    var mimeType: String = "application/octet-stream"
    var data: Data
}

extension Notification.Name {
    /// Posted when the server rejects the stored token (HTTP 401).
    static let bambuddyUnauthorized = Notification.Name("bambuddyUnauthorized")
}

/// Thin, stateless HTTP client for the Bambuddy REST API (`/api/v1`).
/// It is a value type: when the server or token changes, a new client is made.
struct APIClient: Sendable {
    let baseURL: URL
    let token: String?

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }

    func withToken(_ token: String?) -> APIClient { APIClient(baseURL: baseURL, token: token) }

    // MARK: URL building

    /// Builds an absolute URL. `path` may be relative to `/api/v1` (`"printers/"`),
    /// absolute on the server (`"/api/v1/printers/1/cover"`), or a full URL.
    func url(_ path: String, query: [String: QueryValue?] = [:]) -> URL {
        var base: URL
        if path.hasPrefix("http://") || path.hasPrefix("https://"), let u = URL(string: path) {
            base = u
        } else if path.hasPrefix("/") {
            base = URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL
        } else {
            base = URL(string: "/api/v1/" + path, relativeTo: baseURL)?.absoluteURL ?? baseURL
        }
        let items = query.compactMap { key, value -> [URLQueryItem]? in
            guard let value else { return nil }
            return value.queryItems(key: key)
        }.flatMap { $0 }.sorted { $0.name < $1.name }
        guard !items.isEmpty, var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        var existing = comps.percentEncodedQueryItems ?? []
        existing += items.map { URLQueryItem(name: Self.encode($0.name), value: $0.value.map(Self.encode)) }
        comps.percentEncodedQueryItems = existing
        return comps.url ?? base
    }

    private static let allowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?/#:;,@$!'()*")
        return set
    }()
    private static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }

    // MARK: Requests

    func makeRequest(_ method: HTTPMethod, _ path: String, query: [String: QueryValue?] = [:], body: Data? = nil, contentType: String? = "application/json") -> URLRequest {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method.rawValue
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        return req
    }

    @discardableResult
    func send<T: Decodable>(_ method: HTTPMethod, _ path: String, query: [String: QueryValue?] = [:], as type: T.Type = T.self) async throws -> T {
        try await perform(makeRequest(method, path, query: query))
    }

    @discardableResult
    func send<T: Decodable, B: Encodable>(_ method: HTTPMethod, _ path: String, query: [String: QueryValue?] = [:], body: B, as type: T.Type = T.self) async throws -> T {
        let data = try APICoders.encoder.encode(body)
        return try await perform(makeRequest(method, path, query: query, body: data))
    }

    func get<T: Decodable>(_ path: String, query: [String: QueryValue?] = [:], as type: T.Type = T.self) async throws -> T {
        try await send(.get, path, query: query)
    }

    /// Fire-and-forget style call that ignores the response body.
    func call(_ method: HTTPMethod, _ path: String, query: [String: QueryValue?] = [:]) async throws {
        let _: EmptyResponse = try await send(method, path, query: query)
    }

    func call<B: Encodable>(_ method: HTTPMethod, _ path: String, query: [String: QueryValue?] = [:], body: B) async throws {
        let _: EmptyResponse = try await send(method, path, query: query, body: body)
    }

    func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await rawData(request)
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        if T.self == Data.self { return data as! T }
        if data.isEmpty, let empty = JSONValue.null as? T { return empty }
        // Untyped payloads keep the server's original (snake_case) keys.
        if T.self == JSONValue.self || T.self == [JSONValue].self || T.self == [String: JSONValue].self {
            return try JSONDecoder().decode(T.self, from: data)
        }
        do {
            return try APICoders.decoder.decode(T.self, from: data)
        } catch {
            #if DEBUG
            print("[API] Decode \(T.self) from \(request.url?.path ?? "") failed: \(error)")
            #endif
            throw error
        }
    }

    func rawData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request)
        try check(response, data: data)
        return data
    }

    func data(_ path: String, query: [String: QueryValue?] = [:]) async throws -> Data {
        try await rawData(makeRequest(.get, path, query: query))
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401, token != nil {
                NotificationCenter.default.post(name: .bambuddyUnauthorized, object: nil)
            }
            throw APIError.from(status: http.statusCode, data: data)
        }
    }

    // MARK: Uploads & downloads

    func upload<T: Decodable>(_ path: String, query: [String: QueryValue?] = [:], files: [UploadFile], fields: [String: String] = [:], method: HTTPMethod = .post, as type: T.Type = T.self) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        for file in files {
            let safeName = file.fileName.replacingOccurrences(of: "\"", with: "'")
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(safeName)\"\r\nContent-Type: \(file.mimeType)\r\n\r\n")
            body.append(file.data)
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")
        var req = makeRequest(method, path, query: query)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60 * 30
        let (data, response) = try await Self.session.upload(for: req, from: body)
        try check(response, data: data)
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        return try APICoders.decoder.decode(T.self, from: data)
    }

    /// Downloads a file to a temporary location, preserving the server's file name when available.
    func download(_ path: String, query: [String: QueryValue?] = [:], suggestedName: String? = nil, method: HTTPMethod = .get, body: Data? = nil) async throws -> URL {
        var req = makeRequest(method, path, query: query, body: body)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 60 * 30
        let (tmp, response) = try await Self.session.download(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            throw APIError.from(status: http.statusCode, data: data)
        }
        let name = suggestedName ?? response.suggestedFilename ?? req.url?.lastPathComponent ?? "download"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

/// Values accepted in query strings.
enum QueryValue: Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case list([String])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .double(value) }

    static func of(_ s: String?) -> QueryValue? { s.map { .string($0) } }
    static func of(_ i: Int?) -> QueryValue? { i.map { .int($0) } }
    static func of(_ d: Double?) -> QueryValue? { d.map { .double($0) } }
    static func of(_ b: Bool?) -> QueryValue? { b.map { .bool($0) } }

    func queryItems(key: String) -> [URLQueryItem] {
        switch self {
        case .string(let s): return [URLQueryItem(name: key, value: s)]
        case .int(let i): return [URLQueryItem(name: key, value: String(i))]
        case .double(let d): return [URLQueryItem(name: key, value: d.rounded() == d ? String(Int(d)) : String(d))]
        case .bool(let b): return [URLQueryItem(name: key, value: b ? "true" : "false")]
        case .list(let l): return l.map { URLQueryItem(name: key, value: $0) }
        }
    }
}

extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}
