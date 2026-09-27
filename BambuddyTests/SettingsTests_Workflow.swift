import Testing
import Foundation
@testable import Bambuddy

struct SettingsWorkflowTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try APICoders.encoder.encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonObject(_ string: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(string.utf8))
    }

    // MARK: - Quick presets

    @Test func presetTripleParsing() {
        let nozzle = SettingsWorkflowPresetCategory.all[0]
        #expect(nozzle.key == "nozzle_temp_presets")
        #expect(nozzle.values(from: "") == [120, 220, 260])
        #expect(nozzle.values(from: "[150,200,250]") == [150, 200, 250])
        // Wrong length, out of range, non-integers and garbage all fall back to the defaults.
        #expect(nozzle.values(from: "[1,2]") == [120, 220, 260])
        #expect(nozzle.values(from: "[100,200,400]") == [120, 220, 260])
        #expect(nozzle.values(from: "[100.5,200,250]") == [120, 220, 260])
        #expect(nozzle.values(from: "not json") == [120, 220, 260])

        let chamber = SettingsWorkflowPresetCategory.all.first { $0.key == "chamber_temp_presets" }!
        #expect(chamber.range == 0...65)
        #expect(chamber.values(from: "") == [35, 45, 60])
        let fan = SettingsWorkflowPresetCategory.all.first { $0.key == "fan_speed_presets" }!
        #expect(fan.values(from: "") == [50, 75, 100])
        let bed = SettingsWorkflowPresetCategory.all.first { $0.key == "bed_temp_presets" }!
        #expect(bed.values(from: "") == [55, 75, 90])
    }

    @Test func presetTripleEncodingIsCompactAndClamped() throws {
        let fan = SettingsWorkflowPresetCategory.all.first { $0.key == "fan_speed_presets" }!
        #expect(fan.encode([10, 20, 30]) == "[10,20,30]")
        #expect(fan.encode([10, 200, -5]) == "[10,100,0]")
        let bed = SettingsWorkflowPresetCategory.all.first { $0.key == "bed_temp_presets" }!
        #expect(bed.values(from: bed.encode([60, 80, 100])) == [60, 80, 100])
    }

    // MARK: - Preheat targets

    @Test func preheatTargetsDefaultsAndParsing() throws {
        let defaults = SettingsPreheatTargets.parse("")
        #expect(defaults["PA-CF"] == 55)
        #expect(defaults["ABS"] == 45)
        #expect(defaults["PLA"] == 0)
        #expect(defaults["default"] == 0)

        // Values are clamped to 0...65, strings accepted, the default row is always present.
        let parsed = SettingsPreheatTargets.parse(#"{"ABS": 80, "PA": "52", "PLA": -3, "CUSTOM": 30}"#)
        #expect(parsed["ABS"] == 65)
        #expect(parsed["PA"] == 52)
        #expect(parsed["PLA"] == 0)
        #expect(parsed["default"] == 0)
        #expect(SettingsPreheatTargets.value(for: "PC", in: parsed) == 50) // from bundled defaults
        #expect(SettingsPreheatTargets.rows(for: parsed).last == "CUSTOM")
        #expect(SettingsPreheatTargets.rows(for: parsed).first == "PA-CF")

        // Malformed input falls back to the bundled defaults.
        #expect(SettingsPreheatTargets.parse("[1,2,3]") == SettingsPreheatTargets.defaults)
    }

    @Test func preheatTargetsRoundTrip() throws {
        var map = SettingsPreheatTargets.parse("")
        map["ABS"] = 50
        let json = SettingsPreheatTargets.serialize(map)
        let object = try #require(try jsonObject(json) as? [String: Int])
        #expect(object["ABS"] == 50)
        #expect(object["default"] == 0)
        #expect(SettingsPreheatTargets.parse(json) == map)
    }

    // MARK: - Drying presets

    @Test func dryingPresetDefaultsMatchServer() {
        let rows = SettingsDryingPresets.parse("")
        #expect(rows.map(\.name) == ["PLA", "PETG", "TPU", "ABS", "ASA", "PA", "PC", "PVA"])
        let tpu = rows.first { $0.name == "TPU" }!.preset
        #expect(tpu == SettingsDryingPreset(n3f: 65, n3s: 75, n3fHours: 12, n3sHours: 18))
        let pla = rows.first { $0.name == "PLA" }!.preset
        #expect(pla == SettingsDryingPreset(n3f: 45, n3s: 45, n3fHours: 12, n3sHours: 12))
    }

    @Test func dryingPresetsMergeStoredValues() {
        // Stored entry replaces the default, missing fields come from that filament's default,
        // and extra filament types are appended.
        let raw = #"{"PLA":{"n3f":50,"n3s":55,"n3f_hours":8,"n3s_hours":6},"ABS":{"n3s":85},"PEEK":{"n3f":60,"n3s":80,"n3f_hours":10,"n3s_hours":10}}"#
        let rows = SettingsDryingPresets.parse(raw)
        #expect(rows.first { $0.name == "PLA" }!.preset == SettingsDryingPreset(n3f: 50, n3s: 55, n3fHours: 8, n3sHours: 6))
        #expect(rows.first { $0.name == "ABS" }!.preset == SettingsDryingPreset(n3f: 65, n3s: 85, n3fHours: 12, n3sHours: 8))
        #expect(rows.last?.name == "PEEK")
        #expect(rows.count == 9)
    }

    @Test func dryingPresetsSerializeFullTableWithSnakeCaseKeys() throws {
        var rows = SettingsDryingPresets.parse("")
        rows[0].preset.n3fHours = 10
        let json = SettingsDryingPresets.serialize(rows)
        let object = try #require(try jsonObject(json) as? [String: [String: Int]])
        #expect(object.count == 8)
        #expect(object["PLA"] == ["n3f": 45, "n3s": 45, "n3f_hours": 10, "n3s_hours": 12])
        #expect(SettingsDryingPresets.parse(json).map(\.preset) == rows.map(\.preset))
    }

    // MARK: - Humidity triggers

    @Test func humidityThresholdsInheritance() throws {
        #expect(SettingsDryingHumidity.parse("").isEmpty)
        let map = SettingsDryingHumidity.parse(#"{"default": 50, "PA": 25, "bad": "x"}"#)
        #expect(map == ["default": 50, "PA": 25])
        #expect(SettingsDryingHumidity.resolved("PA", in: map, fair: 60) == 25)
        #expect(SettingsDryingHumidity.resolved("PLA", in: map, fair: 60) == 50)
        #expect(SettingsDryingHumidity.resolved("PLA", in: [:], fair: 60) == 60)
        #expect(SettingsDryingHumidity.rows(for: map).first == "default")
        #expect(SettingsDryingHumidity.rows(for: ["NYLON": 30]).last == "NYLON")
    }

    @Test func humidityThresholdsSerialization() throws {
        #expect(SettingsDryingHumidity.serialize([:]) == "")
        let json = SettingsDryingHumidity.serialize(["default": 45, "PLA": 55])
        let object = try #require(try jsonObject(json) as? [String: Int])
        #expect(object == ["default": 45, "PLA": 55])
    }

    // MARK: - G-code snippets

    @Test func gcodeSnippetsParseAndSerialize() throws {
        let raw = #"{"P1S":{"start_gcode":"M117 Hello\nG28","end_gcode":""},"X1C":{"start_gcode":null,"end_gcode":"M400"},"junk":5}"#
        let map = SettingsGcodeSnippets.parse(raw)
        #expect(map.count == 2)
        #expect(map["P1S"] == SettingsGcodeSnippet(startGcode: "M117 Hello\nG28", endGcode: ""))
        #expect(map["X1C"] == SettingsGcodeSnippet(startGcode: "", endGcode: "M400"))
        #expect(SettingsGcodeSnippets.parse("").isEmpty)

        var next = map
        next["X1C"] = SettingsGcodeSnippet() // cleared → dropped on save
        let json = SettingsGcodeSnippets.serialize(next)
        let object = try #require(try jsonObject(json) as? [String: [String: String]])
        #expect(object == ["P1S": ["start_gcode": "M117 Hello\nG28", "end_gcode": ""]])
        #expect(SettingsGcodeSnippets.serialize(["A1": SettingsGcodeSnippet(startGcode: "  \n", endGcode: "")]) == "")
    }

    // MARK: - Spool catalog

    @Test func decodesSpoolCatalog() throws {
        let entries = try decode([SettingsCatalogSpoolEntry].self, """
        [{"id":1,"name":"3D FilaPrint - Cardboard","weight":210,"is_default":true},
         {"id":57,"name":"My Spool - Plastic","weight":188,"is_default":false}]
        """)
        #expect(entries.count == 2)
        #expect(entries[0].name == "3D FilaPrint - Cardboard")
        #expect(entries[0].weight == 210)
        #expect(entries[1].isDefault == false)
    }

    @Test func encodesSpoolCatalogBodies() throws {
        let body = try encodedObject(SettingsCatalogSpoolPayload(name: "Bambu Lab - Plastic", weight: 250))
        #expect(body["name"] as? String == "Bambu Lab - Plastic")
        #expect(body["weight"] as? Int == 250)
        let bulk = try encodedObject(SettingsCatalogBulkDelete(ids: [1, 2, 3]))
        #expect(bulk["ids"] as? [Int] == [1, 2, 3])
        let result = try decode(SettingsCatalogBulkDeleteResult.self, #"{"deleted": 3}"#)
        #expect(result.deleted == 3)
    }

    @Test func spoolCatalogImportExportRoundTrip() throws {
        let entries = [SettingsCatalogSpoolEntry(id: 1, name: "A - Plastic", weight: 200, isDefault: true)]
        let data = SettingsCatalog.exportSpools(entries)
        let exported = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(exported.first?["name"] as? String == "A - Plastic")
        #expect(exported.first?["id"] == nil)
        let records = try SettingsCatalog.importSpools(data)
        #expect(records.first?.name == "A - Plastic")
        #expect(records.first?.weight == 200)
    }

    // MARK: - Color catalog

    @Test func decodesColorCatalog() throws {
        let entries = try decode([SettingsCatalogColorEntry].self, """
        [{"id":631,"manufacturer":"3DXTECH","color_name":"Natural","hex_color":"#DED7C6","material":"ASA","is_default":true,"extra_colors":null,"effect_type":null},
         {"id":900,"manufacturer":"Bambu Lab","color_name":"Dawn Radiance","hex_color":"#EC984CFF","material":null,"is_default":false,"extra_colors":"ec984c,6cd4bc","effect_type":"silk"},
         {"id":901,"manufacturer":"Polymaker","color_name":"Teal","hex_color":"#00A0A0","material":"PLA","is_default":false}]
        """)
        #expect(entries.count == 3)
        #expect(entries[0].colorName == "Natural")
        #expect(entries[0].hexColor == "#DED7C6")
        #expect(entries[0].extraColors == nil)
        #expect(entries[1].material == nil)
        #expect(entries[1].extraColors == "ec984c,6cd4bc")
        #expect(entries[1].effectType == "silk")
        #expect(entries[2].effectType == nil)
    }

    @Test func encodesColorPayloadWithExplicitNulls() throws {
        let payload = SettingsCatalogColorPayload(manufacturer: "Bambu Lab", colorName: "Jade White", hexColor: "#FFFFFF",
                                                  material: nil, extraColors: nil, effectType: "matte")
        let body = try encodedObject(payload)
        #expect(body["manufacturer"] as? String == "Bambu Lab")
        #expect(body["color_name"] as? String == "Jade White")
        #expect(body["hex_color"] as? String == "#FFFFFF")
        #expect(body["effect_type"] as? String == "matte")
        #expect(body.keys.contains("material"))
        #expect(body["material"] is NSNull)
        #expect(body["extra_colors"] is NSNull)
    }

    @Test func colorValidationHelpers() {
        #expect(SettingsCatalog.normalizedHex("ff00aa") == "#FF00AA")
        #expect(SettingsCatalog.normalizedHex("#ff00aa80") == "#FF00AA80")
        #expect(SettingsCatalog.normalizedHex("#ff00a") == nil)
        #expect(SettingsCatalog.normalizedHex("zzzzzz") == nil)
        #expect(SettingsCatalog.extraColorsError("") == nil)
        #expect(SettingsCatalog.extraColorsError("ff0000, #00ff00, 0000ffcc") == nil)
        #expect(SettingsCatalog.extraColorsError("ff00") != nil)
        #expect(SettingsCatalog.extraColorsError(Array(repeating: "ffffff", count: 9).joined(separator: ",")) != nil)
        #expect(SettingsCatalog.effectLabel("dual-color") == "Dual Color")
        #expect(SettingsCatalog.effectLabel(nil) == nil)
    }

    @Test func colorCatalogImportExportRoundTrip() throws {
        let entries = [SettingsCatalogColorEntry(id: 1, manufacturer: "Bambu Lab", colorName: "Red", hexColor: "#C12E1F",
                                                 material: "PLA Basic", isDefault: true, extraColors: nil, effectType: nil)]
        let data = SettingsCatalog.exportColors(entries)
        let exported = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(exported.first?["color_name"] as? String == "Red")
        #expect(exported.first?["hex_color"] as? String == "#C12E1F")
        let records = try SettingsCatalog.importColors(data)
        #expect(records.first?.manufacturer == "Bambu Lab")
        #expect(records.first?.material == "PLA Basic")
        // Web-exported files carry nulls for the optional fields.
        let web = try SettingsCatalog.importColors(Data(#"[{"manufacturer":"X","color_name":"Y","hex_color":"#000000","material":null,"extra_colors":null,"effect_type":null}]"#.utf8))
        #expect(web.first?.colorName == "Y")
        #expect(web.first?.material == nil)
    }

    @Test func parsesColorSyncStream() {
        let progress = SettingsCatalog.parseSyncLine(#"data: {"type": "progress", "added": 12, "skipped": 3, "total_fetched": 15, "total_available": 3000}"#)
        #expect(progress?.type == "progress")
        #expect(progress?.totalFetched == 15)
        #expect(progress?.totalAvailable == 3000)
        let complete = SettingsCatalog.parseSyncLine(#"data: {"type": "complete", "added": 0, "skipped": 3000, "total_fetched": 3000, "total_available": 3000}"#)
        #expect(complete?.type == "complete")
        #expect(complete?.added == 0)
        let error = SettingsCatalog.parseSyncLine(#"data: {"type": "error", "error": "Unexpected error during sync"}"#)
        #expect(error?.error == "Unexpected error during sync")
        #expect(SettingsCatalog.parseSyncLine("") == nil)
        #expect(SettingsCatalog.parseSyncLine(": keep-alive") == nil)
    }

    // MARK: - Spoolman

    @Test func decodesSpoolmanSettingsStrings() throws {
        let config = try decode(SettingsSpoolmanConfig.self, """
        {"spoolman_enabled":"false","spoolman_url":"","spoolman_sync_mode":"auto","spoolman_disable_weight_sync":"false","spoolman_report_partial_usage":"true","auto_add_unknown_rfid":"true"}
        """)
        #expect(config.enabled == false)
        #expect(config.url == "")
        #expect(config.syncMode == "auto")
        #expect(config.disablesWeightSync == false)
        #expect(config.reportsPartialUsage == true)
        #expect(config.autoAddsUnknownRfid == true)
    }

    @Test func spoolmanSettingsTolerateBooleansAndBlanks() throws {
        let config = try decode(SettingsSpoolmanConfig.self, """
        {"spoolman_enabled":true,"spoolman_url":"http://10.0.0.5:7912","spoolman_sync_mode":"","spoolman_disable_weight_sync":"TRUE","spoolman_report_partial_usage":"","auto_add_unknown_rfid":"false"}
        """)
        #expect(config.enabled)
        #expect(config.url == "http://10.0.0.5:7912")
        #expect(config.syncMode == "auto")
        #expect(config.disablesWeightSync)
        #expect(config.reportsPartialUsage) // blank = server default (on)
        #expect(!config.autoAddsUnknownRfid)
    }

    @Test func spoolmanUpdateBodiesUseStringFlags() throws {
        let body = SettingsSpoolmanConfig.body("spoolman_enabled", true)
        let data = try APICoders.encoder.encode(body)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["spoolman_enabled": "true"])
        let url = try APICoders.encoder.encode(SettingsSpoolmanConfig.body("spoolman_url", "http://host:7912"))
        #expect(try JSONSerialization.jsonObject(with: url) as? [String: String] == ["spoolman_url": "http://host:7912"])
    }

    @Test func decodesSpoolmanStatus() throws {
        let off = try decode(SettingsSpoolmanStatus.self, #"{"enabled":false,"connected":false,"url":null}"#)
        #expect(off.enabled == false)
        #expect(off.url == nil)
        let on = try decode(SettingsSpoolmanStatus.self, #"{"enabled":true,"connected":true,"url":"http://10.0.0.5:7912"}"#)
        #expect(on.connected == true)
    }

    @Test func decodesSpoolmanSyncResults() throws {
        let result = try decode(SettingsSpoolmanSyncResult.self, """
        {"success":false,"synced_count":2,"skipped_count":1,
         "skipped":[{"location":"Printer A - AMS A1","reason":"No RFID tag and no slot assignment","filament_type":"PLA","color":"FF0000FF"}],
         "errors":["AMS B2: Spoolman returned 500"]}
        """)
        #expect(result.success == false)
        #expect(result.syncedCount == 2)
        #expect(result.skipped?.first?.filamentType == "PLA")
        #expect(result.errors?.count == 1)

        let minimal = try decode(SettingsSpoolmanSyncResult.self, #"{"success":true,"synced_count":0,"skipped_count":0,"skipped":[{"location":"AMS HT","reason":"No RFID tag and no slot assignment","filament_type":null,"color":null}],"errors":[]}"#)
        #expect(minimal.skipped?.first?.color == nil)

        let weights = try decode(SettingsSpoolmanWeightSyncResult.self, #"{"synced":4,"skipped":1}"#)
        #expect(weights.synced == 4)
        let message = try decode(SettingsSpoolmanMessage.self, #"{"success":true,"message":"Connected to Spoolman at http://10.0.0.5:7912"}"#)
        #expect(message.success == true)
    }
}
