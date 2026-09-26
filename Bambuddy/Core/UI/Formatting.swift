import SwiftUI

enum Fmt {
    /// Formats minutes as "1h 23m".
    static func minutes(_ minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return "—" }
        return duration(seconds: Double(minutes) * 60)
    }

    static func duration(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    static func bytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    static func bytes(_ bytes: Int?) -> String { self.bytes(bytes.map(Int64.init)) }
    static func bytes(_ bytes: Double?) -> String { self.bytes(bytes.map { Int64($0) }) }

    static func temp(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))°"
    }

    static func grams(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1000 { return String(format: "%.2f kg", value / 1000) }
        return String(format: value < 10 ? "%.1f g" : "%.0f g", value)
    }

    static func number(_ value: Double?, digits: Int = 1) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    static func currency(_ value: Double?, code: String = "USD") -> String {
        guard let value else { return "—" }
        return value.formatted(.currency(code: code))
    }

    static func date(_ raw: String?, style: Date.FormatStyle = .dateTime.month(.abbreviated).day().year().hour().minute()) -> String {
        guard let raw, let d = APICoders.parseDate(raw) else { return raw ?? "—" }
        return d.formatted(style)
    }

    static func relative(_ raw: String?) -> String {
        guard let raw, let d = APICoders.parseDate(raw) else { return raw ?? "—" }
        return d.formatted(.relative(presentation: .named))
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }
}

extension Color {
    /// Parses Bambu-style hex colors (`RRGGBB` or `RRGGBBAA`, optional `#`).
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a == 0 ? 1 : a)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
}
