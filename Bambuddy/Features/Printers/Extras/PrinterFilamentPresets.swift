import SwiftUI

// MARK: Preset source models

struct PrinterCloudSettings: Codable, Sendable, Hashable {
    var filament: [PrinterCloudSetting]?
}

struct PrinterCloudSetting: Codable, Sendable, Hashable {
    var settingId: String
    var name: String
    var type: String?
    var version: String?
    var userId: String?
    var updatedTime: String?
    var isCustom: Bool?
}

struct PrinterLocalPresets: Codable, Sendable, Hashable {
    var filament: [PrinterLocalPreset]?
}

struct PrinterLocalPreset: Codable, Sendable, Hashable {
    var id: Int
    var name: String
    var presetType: String?
    var source: String?
    var filamentType: String?
    var filamentVendor: String?
    var nozzleTempMin: Int?
    var nozzleTempMax: Int?
    var pressureAdvance: String?
    var defaultFilamentColour: String?
    var compatiblePrinters: String?
    var inherits: String?

    /// `compatible_printers` is a JSON-encoded string array.
    var compatiblePrinterNames: [String] {
        guard let raw = compatiblePrinters, let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }
}

struct PrinterBuiltinFilament: Codable, Sendable, Hashable {
    var filamentId: String
    var name: String
}

struct PrinterCloudSettingDetail: Codable, Sendable, Hashable {
    var filamentId: String?
    var name: String?
}

struct PrinterSlotPreset: Codable, Sendable, Hashable {
    var amsId: Int?
    var trayId: Int?
    var presetId: String
    var presetName: String?
    var presetSource: String?
}

struct PrinterSpoolDefaults: Codable, Sendable, Hashable {
    var slicerFilament: String?
    var slicerFilamentName: String?
    var caliIdx: Int?
    var kValue: Double?
    var profileName: String?
    var extruder: Int?
    var nozzleDiameter: String?
}

struct PrinterColorCatalogEntry: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var manufacturer: String
    var colorName: String
    var hexColor: String
    var material: String?
    var isDefault: Bool?
    var extraColors: String?
    var effectType: String?
}

// MARK: Unified preset choice

/// One selectable filament preset, regardless of where it comes from.
struct PrinterFilamentChoice: Hashable, Identifiable, Sendable {
    enum Source: String, Sendable, CaseIterable {
        case local, orcaCloud = "orca_cloud", cloud, builtin

        var label: String {
            switch self {
            case .local: return "Local"
            case .orcaCloud: return "Orca Cloud"
            case .cloud: return "Bambu Cloud"
            case .builtin: return "Built-in"
            }
        }
        var order: Int {
            switch self {
            case .local: return 0
            case .orcaCloud: return 1
            case .cloud: return 2
            case .builtin: return 3
            }
        }
    }

    /// Preset id as stored in slot-presets (`local_12`, `orca_<uuid>`, `<setting_id>`, `builtin_<fid>`).
    var id: String
    var name: String
    var source: Source
    /// Raw cloud / orca setting id, or built-in filament id.
    var rawId: String
    var local: PrinterLocalPreset?

    var isUserPreset: Bool {
        switch source {
        case .orcaCloud: return true
        case .cloud: return !rawId.hasPrefix("GF") && !rawId.hasPrefix("P1")
        default: return false
        }
    }

    var parsed: PrinterFilamentLogic.ParsedName { PrinterFilamentLogic.parse(name) }

    /// Bambu filament id used to match K-profiles (empty for local / Orca presets).
    var filamentId: String? {
        switch source {
        case .cloud: return PrinterFilamentLogic.toFilamentId(rawId)
        case .builtin: return rawId.uppercased()
        case .local, .orcaCloud: return PrinterFilamentLogic.genericId(for: trayType).nilIfEmpty
        }
    }

    var trayType: String {
        let p = parsed
        let known = PrinterFilamentLogic.materials.contains(p.material.uppercased())
        switch source {
        case .local:
            if known { return p.material.uppercased() }
            if let t = local?.filamentType, !t.isEmpty { return t }
            return p.material.isEmpty ? "PLA" : p.material
        case .orcaCloud:
            return p.material.isEmpty ? "PLA" : p.material
        case .cloud, .builtin:
            return p.material.isEmpty ? "PLA" : p.material
        }
    }

    /// `tray_sub_brands` sent to the printer: the preset name without its `@printer` suffix.
    var subBrands: String { PrinterFilamentLogic.stripSuffix(name) }

    var tempRange: (min: Int, max: Int) {
        if source == .local, let l = local, l.nozzleTempMin != nil || l.nozzleTempMax != nil {
            return (l.nozzleTempMin ?? 190, l.nozzleTempMax ?? 230)
        }
        return PrinterFilamentLogic.defaultTemps(for: trayType)
    }

    /// `(tray_info_idx, setting_id)` before any cloud-detail lookup.
    var baseIdentifiers: (trayInfoIdx: String, settingId: String) {
        switch source {
        case .cloud: return (PrinterFilamentLogic.convertToTrayInfoIdx(rawId), rawId)
        case .builtin: return (rawId, "")
        case .local, .orcaCloud:
            let material: String
            if source == .local, !PrinterFilamentLogic.materials.contains(parsed.material.uppercased()), let t = local?.filamentType, !t.isEmpty {
                material = t
            } else {
                material = parsed.material
            }
            return (PrinterFilamentLogic.genericId(for: material), "")
        }
    }
}

enum PrinterFilamentLogic {
    static let materials = ["PLA", "PETG", "PCTG", "ABS", "ASA", "TPU", "PC", "PA", "NYLON", "PVA", "HIPS", "PP", "PET"]

    static let genericIds: [String: String] = [
        "PLA": "GFL99", "PLA-CF": "GFL98", "PLA SILK": "GFL96", "PLA HIGH SPEED": "GFL95",
        "PETG": "GFG99", "PETG HF": "GFG96", "PETG-CF": "GFG98", "PCTG": "GFG97",
        "ABS": "GFB99", "ASA": "GFB98", "PC": "GFC99", "PA": "GFN99", "PA-CF": "GFN98", "NYLON": "GFN99",
        "TPU": "GFU99", "PVA": "GFS99", "HIPS": "GFS98", "PE": "GFP99", "PP": "GFP97",
    ]

    struct ParsedName: Hashable, Sendable {
        var material: String
        var brand: String
        var variant: String
    }

    static func stripSuffix(_ name: String) -> String {
        guard let at = name.firstIndex(of: "@") else { return name.trimmingCharacters(in: .whitespaces) }
        return String(name[..<at]).trimmingCharacters(in: .whitespaces)
    }

    private static func wordRange(_ word: String, in text: String) -> Range<String.Index>? {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: [.regularExpression, .caseInsensitive])
    }

    /// Splits a preset name into brand / material / variant.
    static func parse(_ name: String) -> ParsedName {
        let base = stripSuffix(name)
        let upper = base.uppercased()
        if let support = upper.range(of: "\\bSUPPORT\\s+FOR\\s+", options: .regularExpression) {
            let after = String(upper[support.upperBound...])
            for mat in materials where wordRange(mat, in: after) != nil {
                let offset = upper.distance(from: upper.startIndex, to: support.lowerBound)
                let brand = String(base.prefix(offset)).trimmingCharacters(in: .whitespaces)
                return ParsedName(material: mat, brand: brand, variant: "Support")
            }
        }
        for mat in materials {
            if let r = wordRange(mat, in: base) {
                let brand = String(base[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                var rest = String(base[r.upperBound...])
                if let next = wordRange(mat, in: rest) { rest = String(rest[..<next.lowerBound]) }
                return ParsedName(material: mat, brand: brand, variant: rest.trimmingCharacters(in: .whitespaces))
            }
        }
        let parts = base.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count >= 2 {
            return ParsedName(material: parts[1], brand: parts[0], variant: parts.dropFirst(2).joined(separator: " "))
        }
        return ParsedName(material: base, brand: "", variant: "")
    }

    /// `GFSL05_09` → `GFL05`; user presets keep their base id.
    static func convertToTrayInfoIdx(_ settingId: String) -> String {
        let base = settingId.split(separator: "_", maxSplits: 1).first.map(String.init) ?? settingId
        if base.hasPrefix("GFS") { return "GF" + base.dropFirst(3) }
        return base
    }

    /// Normalizes any preset / setting id to the Bambu filament id used by K-profiles.
    static func toFilamentId(_ id: String) -> String {
        var base = id.split(separator: "_", maxSplits: 1).first.map(String.init) ?? id
        if base.hasPrefix("GFS") { base = "GF" + base.dropFirst(3) }
        return base.uppercased()
    }

    static func genericId(for material: String) -> String {
        let m = material.uppercased().trimmingCharacters(in: .whitespaces)
        if let v = genericIds[m] { return v }
        if let v = genericIds[m.replacingOccurrences(of: "-CF", with: "")] { return v }
        if let v = genericIds[m.replacingOccurrences(of: "+", with: "")] { return v }
        if let first = m.split(separator: " ").first, let v = genericIds[String(first)] { return v }
        return ""
    }

    static func defaultTemps(for material: String) -> (min: Int, max: Int) {
        let m = material.uppercased()
        if m.contains("PLA") { return (190, 230) }
        if m.contains("PETG") { return (220, 260) }
        if m.contains("ABS") || m.contains("ASA") { return (240, 280) }
        if m.contains("TPU") { return (200, 240) }
        if m == "PCTG" { return (220, 260) }
        if m.contains("PC") { return (260, 300) }
        if m.contains("PA") || m.contains("NYLON") { return (250, 290) }
        return (190, 230)
    }

    // MARK: Printer model matching

    /// Normalizes SSDP / internal model codes (`C11`, `BL-P001`, …) to display codes (`P1S`, `X1C`).
    static func modelCode(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let map: [String: String] = [
            "O1D": "H2D", "O1E": "H2D Pro", "O2D": "H2D Pro", "O1C": "H2C", "O1C2": "H2C", "O1S": "H2S",
            "BL-P001": "X1C", "BL-P002": "X1", "BL-P003": "X1E", "N6": "X2D", "N9": "A2L",
            "C11": "P1S", "C12": "P1P", "C13": "P2S", "N2S": "A1", "N1": "A1 Mini",
        ]
        return map[raw] ?? raw
    }

    /// Resolves the Bambu filament id for a preset; Bambu Cloud user presets need their detail record.
    @MainActor
    static func resolveFilamentId(_ choice: PrinterFilamentChoice, client: APIClient) async -> String? {
        if choice.source == .cloud, !choice.rawId.hasPrefix("GFS") {
            let detail: PrinterCloudSettingDetail? = try? await client.get("cloud/settings/\(choice.rawId)")
            if let fid = detail?.filamentId, !fid.isEmpty { return fid }
            return nil
        }
        return choice.filamentId
    }

    private static let modelAliases: [String: [String]] = ["A1 MINI": ["A1M"], "A1M": ["A1 MINI"], "H2D PRO": ["H2DP"], "H2DP": ["H2D PRO"]]

    static func modelsMatch(_ presetModel: String, _ printerModel: String) -> Bool {
        let p = presetModel.uppercased(), m = printerModel.uppercased()
        return p == m || (modelAliases[m]?.contains(p) ?? false) || (modelAliases[p]?.contains(m) ?? false)
    }

    /// Extracts the printer model a preset targets (`@BBL X1C`, `@Bambu Lab P1S 0.4 nozzle`, or a model token in the name).
    static func presetModel(_ name: String, longToShort: [String: String]) -> String? {
        if let at = name.firstIndex(of: "@") {
            var suffix = String(name[name.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            if let nozzle = suffix.range(of: "\\s+[\\d.]+\\s*nozzle$", options: [.regularExpression, .caseInsensitive]) {
                suffix = String(suffix[..<nozzle.lowerBound])
            }
            if let r = suffix.range(of: "^BBL\\s+", options: [.regularExpression, .caseInsensitive]) {
                return String(suffix[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if let r = suffix.range(of: "^Bambu Lab\\s+", options: [.regularExpression, .caseInsensitive]) {
                let fragment = String(suffix[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                let key = "Bambu Lab \(fragment)".lowercased()
                if let hit = longToShort.first(where: { $0.key.lowercased() == key }) { return hit.value }
                return fragment
            }
        }
        var tokens: [(String, String)] = []
        var seen = Set<String>()
        for (long, short) in longToShort {
            let fragment = long.replacingOccurrences(of: "Bambu Lab ", with: "")
            if seen.insert(fragment.lowercased()).inserted { tokens.append((fragment, short)) }
            if seen.insert(short.lowercased()).inserted { tokens.append((short, short)) }
        }
        tokens.sort { $0.0.count > $1.0.count }
        for (token, short) in tokens {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: token).replacingOccurrences(of: " ", with: "\\s+") + "\\b"
            if name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return short }
        }
        return nil
    }

    /// Local preset compatibility with "Bambu Lab <model> <d> nozzle"; nil = unknown.
    static func localPresetCompatible(_ preset: PrinterLocalPreset, printerFullName: String?, printerModel: String, nozzle: String, longToShort: [String: String]) -> Bool? {
        guard let printerFullName else { return nil }
        let strip: (String) -> String = { $0.hasPrefix("# ") ? String($0.dropFirst(2)) : $0 }
        let compat = preset.compatiblePrinterNames
        if !compat.isEmpty { return compat.contains { strip($0) == strip(printerFullName) } }
        guard let model = presetModel(preset.name, longToShort: longToShort) else { return nil }
        guard modelsMatch(model, printerModel) else { return false }
        if let r = preset.name.range(of: "([\\d.]+)\\s*nozzle", options: [.regularExpression, .caseInsensitive]) {
            let d = preset.name[r].replacingOccurrences(of: "nozzle", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
            return Double(d) == Double(nozzle)
        }
        return Double(nozzle) == 0.4
    }

    // MARK: K-profile matching

    /// Profiles that plausibly belong to the chosen filament preset.
    static func matchingProfiles(_ profiles: [PrinterKProfile], preset: PrinterFilamentChoice?, activeCaliIdx: Int?, extruder: Int?) -> [PrinterKProfile] {
        var out: [PrinterKProfile] = []
        if let preset {
            let parsed = parse(preset.name.hasPrefix("# ") ? String(preset.name.dropFirst(2)) : preset.name)
            let fid = (preset.source == .cloud || preset.source == .builtin) ? preset.filamentId ?? "" : ""
            let brand = parsed.brand.caseInsensitiveCompare("Generic") == .orderedSame ? "" : parsed.brand.uppercased()
            let material = parsed.material.uppercased()
            let fullName = stripSuffix(preset.name).uppercased()
            let aliases: [String] = material == "NYLON" ? ["PA", "PA-CF", "PA6"] : (["PA", "PA-CF", "PA6"].contains(material) ? ["NYLON"] : [])
            out = profiles.filter { p in
                if !fid.isEmpty, toFilamentId(p.filamentId) == fid { return true }
                guard material.count >= 2 else { return false }
                let n = p.name.uppercased()
                if !brand.isEmpty { return n.contains(brand) && n.contains(material) }
                return n.contains(fullName) || n.contains(material) || aliases.contains { n.contains($0) }
            }
        }
        if let extruder { out = out.filter { $0.extruder == extruder } }
        out = dedupe(out)
        if let cali = activeCaliIdx, cali > 0,
           let active = profiles.first(where: { $0.slotId == cali && (extruder == nil || $0.extruder == extruder) }),
           !out.contains(where: { $0.slotId == active.slotId && $0.extruder == active.extruder }) {
            out.insert(active, at: 0)
        }
        return out
    }

    static func dedupe(_ profiles: [PrinterKProfile]) -> [PrinterKProfile] {
        var seen = Set<String>()
        return profiles.filter { seen.insert("\($0.extruder)|\($0.name)|\($0.kValue)").inserted }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: Catalog loader

@MainActor
@Observable
final class PrinterFilamentCatalog {
    var cloud: [PrinterCloudSetting] = []
    var orca: [PrinterCloudSetting] = []
    var local: [PrinterLocalPreset] = []
    var builtin: [PrinterBuiltinFilament] = []
    var longToShort: [String: String] = [:]
    var isLoading = false
    var cloudUnavailable = false
    var loaded = false

    func load(client: APIClient) async {
        guard !loaded else { return }
        isLoading = true
        defer { isLoading = false; loaded = true }
        async let cloudReq: PrinterCloudSettings? = try? client.get("cloud/settings", query: ["version": "02.04.00.70"])
        async let orcaReq: PrinterCloudSettings? = try? client.get("orca-cloud/profiles")
        async let localReq: PrinterLocalPresets? = try? client.get("local-presets/")
        async let builtinReq: [PrinterBuiltinFilament]? = try? client.get("cloud/builtin-filaments")
        async let modelsReq: [String: String]? = try? client.get("slicer/printer-models")
        let (c, o, l, b, m) = await (cloudReq, orcaReq, localReq, builtinReq, modelsReq)
        cloud = c?.filament ?? []
        cloudUnavailable = c == nil
        orca = o?.filament ?? []
        local = l?.filament ?? []
        builtin = b ?? []
        longToShort = m ?? [:]
    }

    /// Builds the ordered, model-filtered preset list the pickers show.
    func choices(printerModel: String?, nozzle: String, keepIds: Set<String> = [], search: String = "") -> [PrinterFilamentChoice] {
        let model = printerModel ?? ""
        let q = search.trimmingCharacters(in: .whitespaces)
        func visible(_ name: String) -> Bool { q.isEmpty || name.localizedCaseInsensitiveContains(q) }
        func modelOK(_ name: String) -> Bool {
            guard !model.isEmpty, let pm = PrinterFilamentLogic.presetModel(name, longToShort: longToShort) else { return true }
            return PrinterFilamentLogic.modelsMatch(pm, model)
        }
        var out: [PrinterFilamentChoice] = []
        var seenCloud = Set<String>()
        for p in orca where visible(p.name) {
            seenCloud.insert(p.settingId)
            guard modelOK(p.name) || keepIds.contains("orca_\(p.settingId)") || keepIds.contains(p.settingId) else { continue }
            out.append(.init(id: "orca_\(p.settingId)", name: p.name, source: .orcaCloud, rawId: p.settingId))
        }
        for p in cloud where visible(p.name) && !seenCloud.contains(p.settingId) {
            seenCloud.insert(p.settingId)
            let keep = keepIds.contains(p.settingId) || keepIds.contains(PrinterFilamentLogic.convertToTrayInfoIdx(p.settingId))
            guard modelOK(p.name) || keep else { continue }
            out.append(.init(id: p.settingId, name: p.name, source: .cloud, rawId: p.settingId))
        }
        let fullName = longToShort.first(where: { $0.value == model }).map { "\($0.key) \(nozzle) nozzle" }
        for p in local where visible(p.name) {
            let compat = PrinterFilamentLogic.localPresetCompatible(p, printerFullName: fullName, printerModel: model, nozzle: nozzle, longToShort: longToShort)
            guard compat != false || keepIds.contains("local_\(p.id)") else { continue }
            out.append(.init(id: "local_\(p.id)", name: p.name, source: .local, rawId: String(p.id), local: p))
        }
        let coveredFilamentIds = Set(seenCloud.map { PrinterFilamentLogic.toFilamentId($0) })
        for f in builtin where visible(f.name) {
            let fid = f.filamentId.uppercased()
            let gfs = fid.hasPrefix("GF") ? "GFS" + fid.dropFirst(2) : fid
            if seenCloud.contains(fid) || seenCloud.contains(gfs) || coveredFilamentIds.contains(fid) { continue }
            out.append(.init(id: "builtin_\(f.filamentId)", name: f.name, source: .builtin, rawId: f.filamentId))
        }
        out.sort { a, b in
            if a.source.order != b.source.order { return a.source.order < b.source.order }
            if a.isUserPreset != b.isUserPreset { return a.isUserPreset }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return out
    }

    /// Finds a choice by any id form a slot may carry (preset id, setting id, tray_info_idx, bare orca uuid).
    func find(_ id: String, in choices: [PrinterFilamentChoice]) -> PrinterFilamentChoice? {
        if let hit = choices.first(where: { $0.id == id }) { return hit }
        if let hit = choices.first(where: { $0.source == .orcaCloud && $0.rawId == id }) { return hit }
        if let hit = choices.first(where: { $0.source == .cloud && $0.rawId == id }) { return hit }
        if let hit = choices.first(where: { $0.source == .cloud && PrinterFilamentLogic.convertToTrayInfoIdx($0.rawId) == id }) { return hit }
        return nil
    }
}

// MARK: Picker

/// Searchable list of filament presets grouped by source.
struct PrinterFilamentPresetPicker: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let printerId: Int
    @Binding var selection: PrinterFilamentChoice?
    var nozzle: String = "0.4"
    var catalog: PrinterFilamentCatalog? = nil

    @State private var ownCatalog = PrinterFilamentCatalog()
    @State private var search = ""

    private var activeCatalog: PrinterFilamentCatalog { catalog ?? ownCatalog }

    var body: some View {
        NavigationStack {
            let choices = activeCatalog.choices(printerModel: PrinterFilamentLogic.modelCode(store.printer(printerId)?.model), nozzle: nozzle,
                                                keepIds: selection.map { [$0.id] } ?? [], search: search)
            List {
                if activeCatalog.isLoading && choices.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if choices.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Presets" : "No Matching Presets", systemImage: "list.bullet",
                                           description: Text(search.isEmpty ? "Connect Bambu Cloud or import local presets to see more filaments." : "Try a different search."))
                }
                ForEach(PrinterFilamentChoice.Source.allCases, id: \.self) { source in
                    let group = choices.filter { $0.source == source }
                    if !group.isEmpty {
                        Section(source.label) {
                            ForEach(group) { choice in
                                Button {
                                    selection = choice
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(choice.name).foregroundStyle(.primary)
                                            if choice.isUserPreset { Text("Custom preset").font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        if selection?.id == choice.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search presets")
            .navigationTitle("Filament Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await activeCatalog.load(client: session.client) }
        }
    }
}
