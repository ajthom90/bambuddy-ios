import Foundation

/// Shared JSON coders. The backend is FastAPI/Pydantic: snake_case keys and
/// ISO-8601 timestamps that may or may not carry fractional seconds or a zone
/// (naive timestamps are UTC).
enum APICoders {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try container.decode(String.self)
            if let date = parseDate(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(string)")
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func parseDate(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.count == 10 { s += "T00:00:00" }
        s = s.replacingOccurrences(of: " ", with: "T")
        // Naive timestamps are UTC on the server.
        let hasZone = s.hasSuffix("Z") || s.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        if !hasZone { s += "Z" }
        // Trim fractional seconds beyond milliseconds (Python emits microseconds).
        if let dot = s.firstIndex(of: ".") {
            let fracEnd = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) ?? s.endIndex
            let frac = s[s.index(after: dot)..<fracEnd]
            if frac.count > 3 {
                s = String(s[..<s.index(after: dot)]) + frac.prefix(3) + s[fracEnd...]
            }
        }
        if let d = try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) { return d }
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
