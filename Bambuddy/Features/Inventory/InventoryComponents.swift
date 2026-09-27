import SwiftUI

/// Color helpers for spool colors (`RRGGBB` / `RRGGBBAA`, alpha `00` = clear).
enum InventoryColors {
    static func color(_ hex: String?) -> Color? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgb = s.count == 8 ? v >> 8 : v
        let alpha = s.count == 8 ? Double(v & 0xFF) / 255 : 1
        return Color(.sRGB,
                     red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255,
                     opacity: max(alpha, 0.35))
    }

    static func isClear(_ hex: String?) -> Bool {
        guard var s = hex?.trimmingCharacters(in: .whitespaces) else { return false }
        if s.hasPrefix("#") { s.removeFirst() }
        return s.count == 8 && s.uppercased().hasSuffix("00")
    }

    /// Normalizes user input into `RRGGBBAA` (uppercase, no `#`).
    static func normalizedRGBA(_ hex: String) -> String? {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, UInt64(s, radix: 16) != nil else { return nil }
        return s.count == 6 ? s + "FF" : s
    }

    static func rgba(from color: Color) -> String {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X%02X", c(r), c(g), c(b), c(a))
    }

    static func stops(rgba: String?, extra: String?) -> [Color] {
        var list: [Color] = []
        if let base = color(rgba) { list.append(base) }
        for token in (extra ?? "").split(separator: ",") {
            if let c = color(String(token)) { list.append(c) }
        }
        return list
    }

    static func effectSymbol(_ effect: String?) -> String? {
        switch effect?.lowercased() {
        case "sparkle", "glitter", "galaxy": "sparkles"
        case "silk", "metal", "metallic", "shimmer": "sun.max"
        case "glow": "lightbulb.max"
        case "marble": "circle.hexagongrid"
        case "wood": "tree"
        case "matte": "circle.lefthalf.filled"
        case nil, "": nil
        default: "wand.and.stars"
        }
    }

    /// Named colors used by the color picker's quick palette.
    static let quickPalette: [(String, String)] = [
        ("Black", "000000FF"), ("White", "FFFFFFFF"), ("Gray", "808080FF"), ("Silver", "C0C0C0FF"),
        ("Red", "FF0000FF"), ("Orange", "FFA500FF"), ("Yellow", "FFFF00FF"), ("Green", "00AE42FF"),
        ("Blue", "0066FFFF"), ("Purple", "8B00FFFF"), ("Pink", "FF69B4FF"), ("Brown", "8B4513FF"),
        ("Navy", "000080FF"), ("Teal", "008080FF"), ("Gold", "FFD700FF"), ("Clear", "00000000"),
    ]
}

/// Circular spool swatch that renders gradient / multi-color spools, clear
/// filament, and a small effect glyph (silk, sparkle, …).
struct InventorySpoolSwatch: View {
    var rgba: String?
    var extraColors: String? = nil
    var effectType: String? = nil
    var size: CGFloat = 28

    init(rgba: String?, extraColors: String? = nil, effectType: String? = nil, size: CGFloat = 28) {
        self.rgba = rgba
        self.extraColors = extraColors
        self.effectType = effectType
        self.size = size
    }

    init(spool: InventorySpool, size: CGFloat = 28) {
        self.init(rgba: spool.rgba, extraColors: spool.extraColors, effectType: spool.effectType, size: size)
    }

    var body: some View {
        let stops = InventoryColors.stops(rgba: rgba, extra: extraColors)
        ZStack {
            if InventoryColors.isClear(rgba) && stops.count <= 1 {
                InventoryCheckerboard().clipShape(Circle())
            } else if stops.count > 1 {
                Circle().fill(AngularGradient(colors: stops + [stops[0]], center: .center))
            } else if let c = stops.first {
                Circle().fill(c)
            } else {
                Circle().fill(.quaternary)
                Image(systemName: "questionmark").font(.system(size: size * 0.4)).foregroundStyle(.secondary)
            }
            Circle().fill(.background).frame(width: size * 0.28, height: size * 0.28)
                .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5) }
            if let symbol = InventoryColors.effectSymbol(effectType), size >= 24 {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.26, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .offset(x: size * 0.3, y: -size * 0.3)
            }
        }
        .overlay { Circle().strokeBorder(.primary.opacity(0.22), lineWidth: 1) }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Wide color banner used at the top of spool cards and the detail view.
struct InventorySpoolBanner: View {
    let spool: InventorySpool
    var height: CGFloat = 56

    var body: some View {
        let stops = InventoryColors.stops(rgba: spool.rgba, extra: spool.extraColors)
        ZStack {
            if InventoryColors.isClear(spool.rgba) && stops.count <= 1 {
                InventoryCheckerboard()
            } else if stops.count > 1 {
                LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
            } else {
                (stops.first ?? Color.gray.opacity(0.3))
            }
            if let symbol = InventoryColors.effectSymbol(spool.effectType) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.white.opacity(0.85)).shadow(radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8)
            }
        }
        .frame(height: height)
    }
}

private struct InventoryCheckerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = max(4, min(size.width, size.height) / 6)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(.gray.opacity(0.35)))
                    x += cell * 2
                }
                y += cell; row += 1
            }
        }
    }
}

/// Remaining-filament bar with traffic-light coloring.
struct InventoryRemainingBar: View {
    let percent: Double
    var height: CGFloat = 6

    static func tint(_ percent: Double) -> Color {
        percent > 50 ? .green : percent > 20 ? .yellow : .red
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Self.tint(percent))
                    .frame(width: geo.size.width * max(0, min(1, percent / 100)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Remaining")
        .accessibilityValue("\(Int(percent.rounded())) percent")
    }
}

enum InventoryFormat {
    static func grams(_ g: Double?) -> String {
        guard let g else { return "—" }
        if abs(g) >= 1000 { return String(format: "%.2f kg", g / 1000) }
        return "\(Int(g.rounded())) g"
    }

    static func materialTint(_ material: String?) -> Color {
        let m = (material ?? "").uppercased()
        if m.hasPrefix("PLA") { return .green }
        if m.hasPrefix("PETG") || m.hasPrefix("PET") { return .blue }
        if m.hasPrefix("ABS") { return .red }
        if m.hasPrefix("ASA") { return .orange }
        if m.hasPrefix("TPU") { return .purple }
        if m.hasPrefix("PA") || m.hasPrefix("PC") { return .indigo }
        return .secondary
    }

    static func joined(_ parts: [String?], separator: String = " · ") -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: separator)
    }
}

/// Compact list row for a spool.
struct InventorySpoolRow: View {
    let spool: InventorySpool
    var slot: InventorySlotLocation?
    var storage: String?
    var lowStockThreshold: Double = 20
    var groupCount: Int = 1

    var body: some View {
        HStack(spacing: 12) {
            InventorySpoolSwatch(spool: spool, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(spool.materialLine).font(.headline).lineLimit(1)
                    if groupCount > 1 {
                        StatusBadge(text: "×\(groupCount)", color: .accentColor)
                    }
                    if spool.isArchived { StatusBadge(text: "Archived", color: .secondary) }
                    Spacer(minLength: 4)
                    Text("#\(spool.id)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(InventoryFormat.joined([spool.brand, spool.colorName])).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    InventoryRemainingBar(percent: spool.remainingPercent).frame(maxWidth: 140)
                    Text("\(InventoryFormat.grams(spool.remainingGrams)) · \(Int(spool.remainingPercent.rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(spool.isLowStock(globalThreshold: lowStockThreshold) ? .red : .secondary)
                }
                if slot != nil || storage != nil {
                    HStack(spacing: 10) {
                        if let slot {
                            Label(slot.description, systemImage: "printer").lineLimit(1)
                        }
                        if let storage {
                            Label(storage, systemImage: "shippingbox").lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(spool.isArchived ? 0.6 : 1)
    }
}

/// Grid card for a spool.
struct InventorySpoolCard: View {
    let spool: InventorySpool
    var slot: InventorySlotLocation?
    var storage: String?
    var lowStockThreshold: Double = 20
    var groupCount: Int = 1
    var isSelected: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                InventorySpoolBanner(spool: spool, height: 52)
                Text(spool.colorName?.isEmpty == false ? spool.colorName! : "—")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(.white.opacity(0.9), in: .capsule)
                    .foregroundStyle(.black)
            }
            .overlay(alignment: .topLeading) {
                if let isSelected {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .background(Circle().fill(.black.opacity(0.25)))
                        .padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spool.materialLine).font(.headline).lineLimit(1)
                        Text(spool.brand ?? "—").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("#\(spool.id)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if groupCount > 1 { StatusBadge(text: "×\(groupCount)", color: .accentColor) }
                    }
                }
                VStack(spacing: 4) {
                    HStack {
                        Text("Remaining").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(spool.remainingPercent.rounded()))%").font(.caption.monospacedDigit())
                            .foregroundStyle(spool.isLowStock(globalThreshold: lowStockThreshold) ? .red : .secondary)
                    }
                    InventoryRemainingBar(percent: spool.remainingPercent)
                    HStack {
                        Text("\(InventoryFormat.grams(spool.remainingGrams)) of \(InventoryFormat.grams(spool.label))")
                        Spacer()
                        if spool.used > 0 { Text("Used \(InventoryFormat.grams(spool.used))") }
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let slot {
                    Label(slot.description, systemImage: "printer").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let storage {
                    Label(storage, systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let note = spool.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(12)
        }
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isSelected == true ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected == true ? 2 : 1)
        }
        .opacity(spool.isArchived ? 0.6 : 1)
    }
}
