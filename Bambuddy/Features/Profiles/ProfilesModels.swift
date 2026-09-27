import Foundation

// MARK: - Bambu Cloud auth

struct ProfilesCloudStatus: Codable, Sendable, Hashable {
    var isAuthenticated: Bool
    var email: String?
    var region: String?
    var signInExpired: Bool?
}

struct ProfilesCloudLoginRequest: Encodable, Sendable {
    var email: String
    var password: String
    var region: String
}

struct ProfilesCloudVerifyRequest: Encodable, Sendable {
    var email: String
    var code: String
    var tfaKey: String?
    var region: String
}

struct ProfilesCloudTokenRequest: Encodable, Sendable {
    var accessToken: String
    var region: String
}

struct ProfilesCloudLoginResponse: Codable, Sendable {
    var success: Bool
    var needsVerification: Bool?
    var message: String?
    var verificationType: String?
    var tfaKey: String?
    var reason: String?
}

// MARK: - Slicer presets (Bambu Cloud)

/// The three preset kinds. The list endpoints call process presets "process";
/// the create endpoint and field definitions call them "print".
enum ProfilesPresetKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case filament, process, printer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .filament: return "Filament"
        case .process: return "Process"
        case .printer: return "Printer"
        }
    }

    var systemImage: String {
        switch self {
        case .filament: return "drop.fill"
        case .process: return "slider.horizontal.3"
        case .printer: return "printer.fill"
        }
    }

    /// Type name used when creating a cloud preset.
    var apiType: String { self == .process ? "print" : rawValue }

    /// The setting key that carries the preset's own name.
    var settingsIdKey: String {
        switch self {
        case .filament: return "filament_settings_id"
        case .process: return "print_settings_id"
        case .printer: return "printer_settings_id"
        }
    }

    init?(any raw: String?) {
        switch raw?.lowercased() {
        case "filament": self = .filament
        case "process", "print": self = .process
        case "printer", "machine": self = .printer
        default: return nil
        }
    }
}

struct ProfilesSlicerSetting: Codable, Sendable, Hashable, Identifiable {
    var settingId: String
    var name: String
    var type: String
    var version: String?
    var userId: String?
    var updatedTime: String?
    var isCustom: Bool?

    var id: String { settingId }
    var kind: ProfilesPresetKind { ProfilesPresetKind(any: type) ?? .filament }
    /// User-created presets carry IDs like `PFUS…`, `PPUS…`, `PMUS…`, `PF123`, `PP123`.
    var isUserPreset: Bool { ProfilesPresetMeta.isUserPresetId(settingId) }
}

struct ProfilesSlicerSettingsResponse: Codable, Sendable {
    var filament: [ProfilesSlicerSetting]?
    var printer: [ProfilesSlicerSetting]?
    var process: [ProfilesSlicerSetting]?

    func presets(_ kind: ProfilesPresetKind) -> [ProfilesSlicerSetting] {
        switch kind {
        case .filament: return filament ?? []
        case .process: return process ?? []
        case .printer: return printer ?? []
        }
    }

    var all: [ProfilesSlicerSetting] { ProfilesPresetKind.allCases.flatMap { presets($0) } }
}

/// `GET cloud/settings/{id}` passes through Bambu's own payload.
struct ProfilesSlicerSettingDetail: Codable, Sendable {
    var message: String?
    var code: JSONValue?
    var error: String?
    var `public`: Bool?
    var version: String?
    var type: String?
    var name: String?
    var updateTime: String?
    var nickname: String?
    var baseId: String?
    var setting: JSONValue?
    var filamentId: String?
    var settingId: String?

    var settingObject: [String: JSONValue] { setting?.objectValue ?? [:] }
}

struct ProfilesFieldOption: Codable, Sendable, Hashable {
    var value: String
    var label: String?
}

struct ProfilesFieldDefinition: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var label: String?
    var type: String?
    var category: String?
    var description: String?
    var options: [ProfilesFieldOption]?
    var unit: String?
    var min: Double?
    var max: Double?
    var step: Double?

    var id: String { key }
    var displayLabel: String { label ?? ProfilesPresetMeta.humanize(key) }
}

struct ProfilesFieldDefinitions: Codable, Sendable {
    var version: String?
    var description: String?
    var fields: [ProfilesFieldDefinition]?
}

// MARK: - Local (imported) presets

struct ProfilesLocalPreset: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var presetType: String
    var source: String?
    var filamentType: String?
    var filamentVendor: String?
    var nozzleTempMin: Int?
    var nozzleTempMax: Int?
    var pressureAdvance: String?
    var defaultFilamentColour: String?
    var filamentCost: String?
    var filamentDensity: String?
    var compatiblePrinters: String?
    var inherits: String?
    var version: String?
    var createdAt: String?
    var updatedAt: String?

    var kind: ProfilesPresetKind { ProfilesPresetKind(any: presetType) ?? .filament }
    var resolvedMaterial: String? {
        if let filamentType, !filamentType.isEmpty { return filamentType }
        return ProfilesPresetMeta.localMaterial(from: name)
    }
    var resolvedVendor: String? {
        if let filamentVendor, !filamentVendor.isEmpty { return filamentVendor }
        return ProfilesPresetMeta.localVendor(from: name)
    }
    /// Explicit colour from the preset (may be JSON-encoded list), without '#'.
    var explicitColorHex: String? { ProfilesPresetMeta.firstHexColor(defaultFilamentColour) }
    var compatiblePrinterList: String? {
        guard let compatiblePrinters, !compatiblePrinters.isEmpty else { return nil }
        if let data = compatiblePrinters.data(using: .utf8),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            return list.joined(separator: ", ")
        }
        return compatiblePrinters
    }
}

struct ProfilesLocalPresetsResponse: Codable, Sendable {
    var filament: [ProfilesLocalPreset]?
    var printer: [ProfilesLocalPreset]?
    var process: [ProfilesLocalPreset]?

    func presets(_ kind: ProfilesPresetKind) -> [ProfilesLocalPreset] {
        switch kind {
        case .filament: return filament ?? []
        case .process: return process ?? []
        case .printer: return printer ?? []
        }
    }
    var totalCount: Int { ProfilesPresetKind.allCases.reduce(0) { $0 + presets($1).count } }
}

struct ProfilesLocalPresetDetail: Codable, Sendable {
    var id: Int
    var name: String
    var presetType: String
    var source: String?
    var inherits: String?
    var version: String?
    var createdAt: String?
    var updatedAt: String?
    var setting: JSONValue?
}

struct ProfilesImportResult: Codable, Sendable {
    var success: Bool
    var imported: Int
    var skipped: Int
    var errors: [String]?
}

// MARK: - Orca Cloud

struct ProfilesOrcaStatus: Codable, Sendable {
    var connected: Bool
    var email: String?
    var userId: String?
}

struct ProfilesOrcaDeviceStart: Codable, Sendable, Hashable {
    var userCode: String
    var verificationUri: String
    var verificationUriComplete: String?
    var interval: Int?
    var expiresIn: Int?
}

struct ProfilesOrcaPoll: Codable, Sendable {
    var status: String
    var connected: Bool?
    var email: String?
    var userId: String?
}

struct ProfilesOrcaProfileMeta: Codable, Sendable, Hashable, Identifiable {
    var settingId: String
    var name: String
    var type: String
    var version: String?
    var userId: String?
    var updatedTime: String?
    var isCustom: Bool?

    var id: String { settingId }
    var kind: ProfilesPresetKind { ProfilesPresetKind(any: type) ?? .filament }
}

struct ProfilesOrcaProfileList: Codable, Sendable {
    var filament: [ProfilesOrcaProfileMeta]?
    var printer: [ProfilesOrcaProfileMeta]?
    var process: [ProfilesOrcaProfileMeta]?

    func presets(_ kind: ProfilesPresetKind) -> [ProfilesOrcaProfileMeta] {
        switch kind {
        case .filament: return filament ?? []
        case .process: return process ?? []
        case .printer: return printer ?? []
        }
    }
    var all: [ProfilesOrcaProfileMeta] { ProfilesPresetKind.allCases.flatMap { presets($0) } }
}

struct ProfilesOrcaProfileDetail: Codable, Sendable {
    var settingId: String
    var name: String
    var type: String
    var version: String?
    var baseId: String?
    var updateTime: String?
    var setting: JSONValue?
}

// MARK: - K-profiles (pressure advance calibration)

struct ProfilesKProfile: Codable, Sendable, Hashable, Identifiable {
    var slotId: Int
    var extruderId: Int?
    var nozzleId: String
    var nozzleDiameter: String
    var filamentId: String
    var name: String
    var kValue: String
    var nCoef: String?
    var amsId: Int?
    var trayId: Int?
    var settingId: String?

    var id: String { "\(slotId)_\(extruderId ?? 0)_\(filamentId)_\(nozzleId)" }
    var extruder: Int { extruderId ?? 0 }
    var kDouble: Double { Double(kValue) ?? 0 }
    var displayK: String { ProfilesKMath.truncated(kValue) }

    /// nozzle_id looks like "HS00-0.4" (standard) or "HH00-0.4" (high flow); missing means standard.
    var flowPrefix: String {
        let prefix = nozzleId.prefix(4)
        if prefix.count == 4, prefix.prefix(2).allSatisfy(\.isUppercase), prefix.suffix(2).allSatisfy(\.isNumber) {
            return String(prefix)
        }
        return ProfilesKMath.standardFlow
    }
    var isHighFlow: Bool { flowPrefix == ProfilesKMath.highFlow }
    var flowLabel: String { isHighFlow ? "HF" : "S" }

    /// Keys a note may be stored under, most specific first.
    var noteKeys: [String] {
        var keys: [String] = []
        if let settingId, !settingId.isEmpty { keys.append(settingId) }
        keys.append("slot_\(slotId)_\(filamentId)_\(extruder)")
        keys.append("name_\(name)_\(filamentId)")
        return keys
    }

    /// Filament name derived from the profile name ("HF_Brand PLA" → "Brand PLA").
    var nameWithoutFlowPrefix: String {
        for prefix in ["High Flow_", "High Flow ", "Standard_", "Standard ", "HF_", "HF ", "S_", "S "] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        if let idx = name.firstIndex(of: "_"), idx != name.startIndex {
            return String(name[name.index(after: idx)...])
        }
        return name
    }
}

struct ProfilesKProfilesResponse: Codable, Sendable {
    var profiles: [ProfilesKProfile]
    var nozzleDiameter: String?
}

struct ProfilesKProfileCreate: Codable, Sendable {
    var slotId: Int = 0
    var extruderId: Int = 0
    var nozzleId: String
    var nozzleDiameter: String
    var filamentId: String
    var name: String
    var kValue: String
    var settingId: String?
}

struct ProfilesKProfileDelete: Codable, Sendable {
    var slotId: Int
    var extruderId: Int
    var nozzleId: String
    var nozzleDiameter: String
    var filamentId: String
    var settingId: String?
}

struct ProfilesKProfileNotes: Codable, Sendable {
    var notes: [String: String]?
}

struct ProfilesKProfileNoteBody: Codable, Sendable {
    var settingId: String
    var note: String
}

/// Export/import file format for K-profiles.
struct ProfilesKProfileExport: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var name: String?
        var kValue: String?
        var filamentId: String?
        var nozzleId: String?
        var nozzleDiameter: String?
        var extruderId: Int?
    }
    var version: Int?
    var exportedAt: String?
    var printer: String?
    var nozzleDiameter: String?
    var profiles: [Entry]?
}

struct ProfilesBuiltinFilament: Codable, Sendable, Hashable {
    var filamentId: String
    var name: String
}

enum ProfilesKMath {
    static let standardFlow = "HS00"
    static let highFlow = "HH00"
    static let diameters = ["0.2", "0.4", "0.6", "0.8"]

    /// Truncates (not rounds) to three decimals, like the slicer displays it.
    static func truncated(_ raw: String) -> String {
        guard let v = Double(raw.trimmingCharacters(in: .whitespaces)) else { return raw }
        return String(format: "%.3f", (v * 1000).rounded(.towardZero) / 1000)
    }

    /// Six decimals are what the printer protocol expects.
    static func wire(_ raw: String) -> String? {
        guard let v = Double(raw.trimmingCharacters(in: .whitespaces)), v.isFinite, v >= 0 else { return nil }
        return String(format: "%.6f", v)
    }
}

// MARK: - Preset name heuristics

enum ProfilesPresetMeta {
    struct Info: Sendable, Hashable {
        var printer: String?
        var nozzle: String?
        var layerHeight: String?
        var filamentType: String?
    }

    static func isUserPresetId(_ id: String) -> Bool {
        id.range(of: #"^(P[FPM]US|PF\d|PP\d)"#, options: .regularExpression) != nil
    }

    static func extract(_ name: String, inherits: String? = nil) -> Info {
        let text = name + " " + (inherits ?? "")
        var info = Info()
        if let m = firstMatch(#"@?\s*(?:BBL\s+)?(?:Bambu\s+Lab\s+)?([XPAH][1-9][A-Z]?(?:\s*(?:Carbon|mini))?|H2D)"#, in: text) {
            info.printer = m[1]?.trimmingCharacters(in: .whitespaces)
        }
        if let m = firstMatch(#"(\d+\.?\d*)\s*(?:mm\s*)?nozzle|nozzle\s*(\d+\.?\d*)"#, in: text), let v = m[1] ?? m[2] {
            info.nozzle = v + "mm"
        }
        if let m = firstMatch(#"(\d+\.?\d*)mm"#, in: text), let v = m[1] {
            info.layerHeight = v + "mm"
        }
        if let m = firstMatch(#"\b(PLA|PETG|ABS|ASA|TPU|PC|PA|PVA|HIPS|PP|PET(?:-?CF)?|PA(?:-?CF)?|PLA(?:-?CF)?)\b"#, in: text), let v = m[1] {
            info.filamentType = v.uppercased()
        }
        return info
    }

    /// Returns capture groups (index 0 = whole match); nil entries for groups that did not participate.
    private static func firstMatch(_ pattern: String, in text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<max(3, m.numberOfRanges)).map { i in
            guard i < m.numberOfRanges else { return nil }
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    static func humanize(_ key: String) -> String {
        key.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static let localMaterials = ["PLA", "PETG", "PCTG", "ABS", "ASA", "TPU", "PC", "PA", "PVA", "HIPS", "PP", "PET", "NYLON"]

    static func localMaterial(from name: String) -> String? {
        let upper = name.uppercased()
        for m in localMaterials where upper.range(of: "\\b\(m)\\b", options: .regularExpression) != nil { return m }
        return nil
    }

    static func localVendor(from name: String) -> String? {
        let clean = name.replacingOccurrences(of: #"@.+$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let upper = clean.uppercased()
        for m in localMaterials {
            if let r = upper.range(of: m), r.lowerBound != upper.startIndex {
                let offset = upper.distance(from: upper.startIndex, to: r.lowerBound)
                let vendor = String(clean.prefix(offset)).trimmingCharacters(in: .whitespaces)
                if vendor.count > 1 { return vendor }
            }
        }
        return nil
    }

    /// Fallback swatch colours by material when a preset has no explicit colour.
    static func materialColorHex(_ material: String?) -> String? {
        let table: [String: String] = [
            "PLA": "E8E8E8", "PETG": "4A90D9", "ABS": "E67E22", "ASA": "D35400",
            "TPU": "9B59B6", "PC": "BDC3C7", "PA": "2ECC71", "NYLON": "2ECC71",
            "PVA": "F1C40F", "HIPS": "95A5A6", "PP": "ECF0F1", "PET": "3498DB",
        ]
        return material.flatMap { table[$0.uppercased()] }
    }

    /// Parses `"#FF0000"`, `FF0000FF`, or a JSON list like `["#FF0000"]`.
    static func firstHexColor(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let data = s.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let first = json.arrayValue?.first?.stringValue { s = first } else if let str = json.stringValue { s = str }
        }
        s = s.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "\"", with: "")
        guard s.count == 6 || s.count == 8, UInt64(s, radix: 16) != nil else { return nil }
        return String(s.prefix(6))
    }

    /// Brand/material/variant heuristics for filament preset names.
    static func material(fromPresetName name: String) -> String {
        var clean = name.replacingOccurrences(of: #"@.*$"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "(Custom)", with: "", options: .caseInsensitive)
        clean = clean.replacingOccurrences(of: #"^[#*]+\s*"#, with: "", options: .regularExpression).uppercased()
        let materials = ["PLA-CF", "PETG-CF", "ABS-GF", "ASA-CF", "PA-CF", "PAHT-CF", "PA6-CF", "PA6-GF", "PPA-CF", "PPA-GF",
                         "PET-CF", "PPS-CF", "PC-CF", "PC-ABS", "PCTG", "PETG", "PLA", "ABS", "ASA", "PC", "PA", "TPU",
                         "PVA", "HIPS", "BVOH", "PPS", "PEEK", "PEI"]
        return materials.first { clean.contains($0) } ?? ""
    }

    /// Display name without the "@printer" suffix and leading "# ".
    static func displayName(_ name: String) -> String {
        let stripped = name.replacingOccurrences(of: #"@.+$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return stripped.hasPrefix("# ") ? String(stripped.dropFirst(2)).trimmingCharacters(in: .whitespaces) : stripped
    }

    /// Generic Bambu filament ids by material (used for presets without their own id).
    static func genericFilamentId(for material: String?) -> String {
        let table: [String: String] = [
            "PLA": "GFL99", "PLA-CF": "GFL98", "PLA SILK": "GFL96", "PLA HIGH SPEED": "GFL95",
            "PETG": "GFG99", "PETG HF": "GFG96", "PETG-CF": "GFG98", "PCTG": "GFG97",
            "ABS": "GFB99", "ASA": "GFB98", "PC": "GFC99",
            "PA": "GFN99", "PA-CF": "GFN98", "NYLON": "GFN99",
            "TPU": "GFU99", "PVA": "GFS99", "HIPS": "GFS98", "PE": "GFP99", "PP": "GFP97",
        ]
        let m = (material ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return "" }
        if let v = table[m] { return v }
        if let v = table[m.replacingOccurrences(of: #"[-\s]?CF$"#, with: "", options: .regularExpression)] { return v }
        if let v = table[m.replacingOccurrences(of: #"\+$"#, with: "", options: .regularExpression)] { return v }
        if let first = m.split(whereSeparator: { $0 == "-" || $0 == " " }).first, let v = table[String(first)] { return v }
        return ""
    }

    /// "GFSG98_01" → "GFG98".
    static func filamentId(fromSettingId id: String) -> String {
        var s = String(id.split(separator: "_").first ?? "")
        if s.uppercased().hasPrefix("GFS") { s = String(s.prefix(2) + s.dropFirst(3)) }
        return s.uppercased()
    }
}

// MARK: - Filament choices for new K-profiles

struct ProfilesFilamentOption: Sendable, Hashable, Identifiable {
    enum Source: Int, Sendable, CaseIterable {
        case local, orca, cloud, builtin
        var title: String {
            switch self {
            case .local: return "Imported"
            case .orca: return "Orca Cloud"
            case .cloud: return "Bambu Cloud"
            case .builtin: return "Built-in"
            }
        }
    }
    var id: String
    var name: String
    var source: Source
    /// Empty when it must be resolved from the cloud preset detail.
    var filamentId: String
    var material: String

    /// Merges every known filament source, de-duplicating by id and name with
    /// the priority imported → Orca → Bambu Cloud → built-in.
    static func build(local: [ProfilesLocalPreset], orca: [ProfilesOrcaProfileMeta], cloud: [ProfilesSlicerSetting], builtin: [ProfilesBuiltinFilament]) -> [ProfilesFilamentOption] {
        var options: [ProfilesFilamentOption] = []
        var claimedIds = Set<String>()
        var namesInTier = Set<String>()
        var namesOffered = Set<String>()
        func take(_ source: Source, _ name: String, _ ids: [String]) -> Bool {
            let usable = ids.filter { !$0.isEmpty }
            if usable.contains(where: claimedIds.contains) { return false }
            let scoped = "\(source.rawValue)|\(name.lowercased())"
            if namesInTier.contains(scoped) { return false }
            usable.forEach { claimedIds.insert($0) }
            namesInTier.insert(scoped)
            namesOffered.insert(name.lowercased())
            return true
        }
        for lp in local {
            let name = ProfilesPresetMeta.displayName(lp.name)
            let material = lp.filamentType.flatMap { $0.isEmpty ? nil : $0 } ?? ProfilesPresetMeta.material(fromPresetName: name)
            guard take(.local, name, []) else { continue }
            options.append(.init(id: "local_\(lp.id)", name: name, source: .local, filamentId: ProfilesPresetMeta.genericFilamentId(for: material), material: material))
        }
        for op in orca {
            let name = ProfilesPresetMeta.displayName(op.name)
            let material = ProfilesPresetMeta.material(fromPresetName: name)
            guard take(.orca, name, [op.settingId]) else { continue }
            options.append(.init(id: "orca_\(op.settingId)", name: name, source: .orca, filamentId: ProfilesPresetMeta.genericFilamentId(for: material), material: material))
        }
        for cp in cloud {
            let name = ProfilesPresetMeta.displayName(cp.name)
            let fid = cp.settingId.hasPrefix("GFS") ? ProfilesPresetMeta.filamentId(fromSettingId: cp.settingId) : ""
            guard take(.cloud, name, [cp.settingId, fid]) else { continue }
            options.append(.init(id: cp.settingId, name: name, source: .cloud, filamentId: fid, material: ProfilesPresetMeta.material(fromPresetName: name)))
        }
        for bf in builtin {
            if namesOffered.contains(bf.name.lowercased()) { continue }
            let asSetting = bf.filamentId.hasPrefix("GF") ? "GFS" + bf.filamentId.dropFirst(2) : bf.filamentId
            guard take(.builtin, bf.name, [bf.filamentId, asSetting]) else { continue }
            options.append(.init(id: "builtin_\(bf.filamentId)", name: bf.name, source: .builtin, filamentId: bf.filamentId, material: ProfilesPresetMeta.material(fromPresetName: bf.name)))
        }
        return options.sorted { a, b in
            a.source != b.source ? a.source.rawValue < b.source.rawValue : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - JSON helpers

enum ProfilesJSON {
    /// Pretty JSON with the server's keys preserved (not snake-cased).
    static func pretty(_ value: JSONValue) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// A compact human representation for list rows.
    static func summary(_ value: JSONValue?) -> String {
        guard let value else { return "—" }
        switch value {
        case .string(let s):
            let unescaped = s.replacingOccurrences(of: "\\n", with: "\n")
            let lines = unescaped.split(separator: "\n", omittingEmptySubsequences: false).count
            if lines > 1 { return "\(lines) lines" }
            return s.count > 80 ? String(s.prefix(80)) + "…" : s
        case .array(let a):
            if a.isEmpty { return "[]" }
            let items = a.map { $0.stringValue ?? summary($0) }
            if Set(items).count == 1 { return items[0] }
            return items.joined(separator: ", ")
        case .object:
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            return (try? enc.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        case .null: return "null"
        default: return value.stringValue ?? ""
        }
    }

    /// Readable multi-line value for detail screens (expands escaped newlines in scripts).
    static func full(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
        case .array(let a) where a.allSatisfy({ $0.stringValue != nil }): return a.compactMap(\.stringValue).joined(separator: "\n")
        default: return pretty(value)
        }
    }
}

extension APIClient {
    /// Sends a JSON body encoded without key conversion, so free-form preset keys survive verbatim.
    fileprivate func profilesRaw<T: Decodable>(_ method: HTTPMethod, _ path: String, json: JSONValue, as: T.Type = T.self) async throws -> T {
        let data = try JSONEncoder().encode(json)
        return try await perform(makeRequest(method, path, body: data))
    }
}

/// Network calls for the Profiles section.
enum ProfilesAPI {
    static func createCloudPreset(_ client: APIClient, kind: ProfilesPresetKind, name: String, baseId: String, setting: [String: JSONValue]) async throws {
        let body: JSONValue = ["type": .string(kind.apiType), "name": .string(name), "base_id": .string(baseId), "setting": .object(setting)]
        let _: JSONValue = try await client.profilesRaw(.post, "cloud/settings", json: body)
    }

    static func updateCloudPreset(_ client: APIClient, id: String, name: String, setting: [String: JSONValue]) async throws {
        let body: JSONValue = ["name": .string(name), "setting": .object(setting)]
        let _: JSONValue = try await client.profilesRaw(.put, "cloud/settings/\(ProfilesAPI.escape(id))", json: body)
    }

    static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }
}
