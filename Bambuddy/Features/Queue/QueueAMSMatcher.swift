import Foundation

/// A filament currently loaded in one of a printer's AMS / external slots.
struct QueueLoadedTray: Hashable, Identifiable, Sendable {
    var globalTrayId: Int
    var label: String
    var type: String
    var color: String?
    var trayInfoIdx: String
    var subBrands: String
    var remain: Int?
    var extruderId: Int?
    var isExternal: Bool

    var id: Int { globalTrayId }
    var menuTitle: String {
        var s = "\(label) · \(subBrands.isEmpty ? type : subBrands)"
        if let remain, remain >= 0 { s += " · \(remain)%" }
        return s
    }
}

/// How well a loaded tray satisfies one filament slot of the file.
enum QueueSlotMatchQuality: Sendable {
    case match, typeOnly, missing
}

struct QueueSlotMatch: Hashable, Sendable, Identifiable {
    var requirement: QueueFilamentRequirement
    var tray: QueueLoadedTray?
    var quality: QueueSlotMatchQuality
    var isManual: Bool
    var id: Int { requirement.slotId ?? 0 }
}

/// Auto-matches a 3MF's filament slots to the trays loaded on a printer, producing the
/// `ams_mapping` array the server forwards to the printer (index = slot_id - 1,
/// value = global tray id or -1).
///
/// Matching order per slot: identical filament preset id, then type + exact colour,
/// then type + the closest similar colour, then type only. A tray is used at most once.
enum QueueAMSMatcher {
    /// Builds the list of loaded trays from a printer status.
    /// `extruderMap` is the printer's `ams_extruder_map` (AMS id → extruder), when known.
    static func loadedTrays(_ status: PrinterStatus?, extruderMap: [String: Int] = [:]) -> [QueueLoadedTray] {
        guard let status else { return [] }
        var result: [QueueLoadedTray] = []
        let external = (status.vtTray ?? []).filter { !($0.trayType ?? "").isEmpty }
        let dualExternal = (status.vtTray?.count ?? 0) > 1
        let dual = status.isDualNozzle || !extruderMap.isEmpty || dualExternal
        for unit in status.ams ?? [] {
            let trays = unit.tray ?? []
            let isHT = unit.id >= 128 || trays.count == 1
            for tray in trays {
                guard let type = tray.trayType, !type.isEmpty else { continue }
                let letter = Character(UnicodeScalar(65 + min(max(unit.id >= 128 ? unit.id - 128 : unit.id, 0), 25))!)
                result.append(QueueLoadedTray(
                    globalTrayId: unit.id >= 128 ? unit.id : unit.id * 4 + tray.id,
                    label: isHT ? "HT-\(letter)" : "\(letter)\(tray.id + 1)",
                    type: type,
                    color: tray.trayColor,
                    trayInfoIdx: tray.trayInfoIdx ?? "",
                    subBrands: tray.traySubBrands ?? "",
                    remain: tray.remain,
                    extruderId: extruderMap[String(unit.id)],
                    isExternal: false
                ))
            }
        }
        for tray in external {
            let gid = tray.id >= 254 ? tray.id : 254 + tray.id
            result.append(QueueLoadedTray(
                globalTrayId: gid,
                label: dualExternal ? (gid == 254 ? "Ext-L" : "Ext-R") : "External",
                type: tray.trayType ?? "",
                color: tray.trayColor,
                trayInfoIdx: tray.trayInfoIdx ?? "",
                subBrands: tray.traySubBrands ?? "",
                remain: tray.remain,
                extruderId: dual ? 255 - gid : nil,
                isExternal: true
            ))
        }
        return result
    }

    static func match(
        requirements: [QueueFilamentRequirement],
        trays: [QueueLoadedTray],
        manual: [Int: Int] = [:]
    ) -> [QueueSlotMatch] {
        var used = Set(manual.values)
        return requirements.map { req in
            let slot = req.slotId ?? 0
            if slot > 0, let manualId = manual[slot] {
                if let tray = trays.first(where: { $0.globalTrayId == manualId }) {
                    let typeOK = typesCompatible(tray.type, req.type)
                    let colorOK = colorsMatch(tray.color, req.color)
                    return QueueSlotMatch(requirement: req, tray: tray, quality: typeOK && colorOK ? .match : (typeOK ? .typeOnly : .missing), isManual: true)
                }
            }
            var available = trays.filter { !used.contains($0.globalTrayId) }
            if let nozzle = req.nozzleId, available.contains(where: { $0.extruderId != nil }) {
                available = available.filter { $0.extruderId == nozzle }
            }
            let typed = available.filter { typesCompatible($0.type, req.type) }
            var pick: QueueLoadedTray?
            if let idx = req.trayInfoIdx, !idx.isEmpty {
                let sameIdx = available.filter { $0.trayInfoIdx == idx }
                if sameIdx.count == 1 {
                    pick = sameIdx[0]
                } else if sameIdx.count > 1 {
                    let sameIdxTyped = sameIdx.filter { typesCompatible($0.type, req.type) }
                    pick = sameIdxTyped.first { normalizedHex($0.color) == normalizedHex(req.color) }
                        ?? nearestSimilar(sameIdxTyped, to: req.color)
                        ?? sameIdxTyped.first
                }
            }
            if pick == nil {
                pick = typed.first { normalizedHex($0.color) == normalizedHex(req.color) }
                    ?? nearestSimilar(typed, to: req.color)
                    ?? typed.first
            }
            if let pick { used.insert(pick.globalTrayId) }
            let quality: QueueSlotMatchQuality = pick == nil ? .missing : (colorsMatch(pick?.color, req.color) ? .match : .typeOnly)
            return QueueSlotMatch(requirement: req, tray: pick, quality: quality, isManual: false)
        }
    }

    /// `ams_mapping` for the matches, or nil when there is nothing to map.
    static func mapping(_ matches: [QueueSlotMatch]) -> [Int]? {
        let maxSlot = matches.compactMap(\.requirement.slotId).max() ?? 0
        guard maxSlot > 0 else { return nil }
        var result = Array(repeating: -1, count: maxSlot)
        for m in matches {
            guard let slot = m.requirement.slotId, slot > 0 else { continue }
            result[slot - 1] = m.tray?.globalTrayId ?? -1
        }
        return result
    }

    /// Inverse of `mapping`: manual overrides keyed by 1-based slot id.
    static func manualOverrides(from mapping: [Int]?) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (i, tray) in (mapping ?? []).enumerated() where tray >= 0 { result[i + 1] = tray }
        return result
    }

    // MARK: Comparison helpers

    private static let typeFamilies: [Set<String>] = [["PA-CF", "PA12-CF", "PAHT-CF"]]

    static func typesCompatible(_ a: String?, _ b: String?) -> Bool {
        let x = (a ?? "").uppercased(), y = (b ?? "").uppercased()
        if x == y { return true }
        return typeFamilies.contains { $0.contains(x) && $0.contains(y) }
    }

    static func normalizedHex(_ color: String?) -> String {
        guard let color else { return "" }
        return String(color.replacingOccurrences(of: "#", with: "").lowercased().prefix(6))
    }

    private static func rgb(_ color: String?) -> (Int, Int, Int)? {
        let hex = normalizedHex(color)
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    /// Within 40 per RGB channel counts as "the same colour" for matching purposes.
    static func colorsSimilar(_ a: String?, _ b: String?, threshold: Int = 40) -> Bool {
        guard let x = rgb(a), let y = rgb(b) else { return false }
        return abs(x.0 - y.0) <= threshold && abs(x.1 - y.1) <= threshold && abs(x.2 - y.2) <= threshold
    }

    static func colorsMatch(_ loaded: String?, _ required: String?) -> Bool {
        if normalizedHex(required).isEmpty { return true }
        return normalizedHex(loaded) == normalizedHex(required) || colorsSimilar(loaded, required)
    }

    private static func distance(_ a: String?, _ b: String?) -> Double? {
        guard let x = rgb(a), let y = rgb(b) else { return nil }
        // Weighted RGB ("redmean") approximation of perceived distance.
        let rMean = Double(x.0 + y.0) / 2
        let dr = Double(x.0 - y.0), dg = Double(x.1 - y.1), db = Double(x.2 - y.2)
        return ((2 + rMean / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rMean) / 256) * db * db).squareRoot()
    }

    private static func nearestSimilar(_ candidates: [QueueLoadedTray], to color: String?) -> QueueLoadedTray? {
        var best: QueueLoadedTray?
        var bestDistance = Double.infinity
        for c in candidates where colorsSimilar(c.color, color) {
            guard let d = distance(c.color, color) else { continue }
            if d < bestDistance { best = c; bestDistance = d }
        }
        return best
    }
}
