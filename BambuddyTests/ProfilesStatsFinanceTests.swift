import Testing
import Foundation
@testable import Bambuddy

struct ProfilesDecodeTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func cloudStatusVariants() throws {
        let live = try decode(ProfilesCloudStatus.self, #"{"is_authenticated":true,"email":"token-auth","region":"global","sign_in_expired":false}"#)
        #expect(live.isAuthenticated)
        #expect(live.email == "token-auth")
        let expired = try decode(ProfilesCloudStatus.self, #"{"is_authenticated":false,"email":null,"region":null,"sign_in_expired":true}"#)
        #expect(!expired.isAuthenticated)
        #expect(expired.signInExpired == true)
        let minimal = try decode(ProfilesCloudStatus.self, #"{"is_authenticated":true,"email":"token-auth"}"#)
        #expect(minimal.region == nil)
    }

    @Test func cloudLoginResponses() throws {
        let verify = try decode(ProfilesCloudLoginResponse.self,
            #"{"success":false,"needs_verification":true,"message":"Verification code sent","verification_type":"totp","tfa_key":"abc123","reason":null}"#)
        #expect(verify.needsVerification == true)
        #expect(verify.verificationType == "totp")
        #expect(verify.tfaKey == "abc123")
        let captcha = try decode(ProfilesCloudLoginResponse.self,
            #"{"success":false,"needs_verification":false,"message":"Blocked","verification_type":null,"tfa_key":null,"reason":"captcha"}"#)
        #expect(captcha.reason == "captcha")
    }

    @Test func cloudLoginRequestsEncodeSnakeCase() throws {
        let data = try APICoders.encoder.encode(ProfilesCloudVerifyRequest(email: "a@b.c", code: "123456", tfaKey: nil, region: "china"))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json["code"]?.stringValue == "123456")
        #expect(json["tfa_key"] == nil)
        let token = try JSONDecoder().decode(JSONValue.self, from: APICoders.encoder.encode(ProfilesCloudTokenRequest(accessToken: "eyJ", region: "global")))
        #expect(token["access_token"]?.stringValue == "eyJ")
    }

    @Test func slicerSettingsList() throws {
        let r = try decode(ProfilesSlicerSettingsResponse.self, #"""
        {"filament":[{"setting_id":"PFUS62fd75c3c2e199","name":"INLAND PLA Pro @Bambu Lab P1S 0.4 nozzle","type":"filament","version":"2.4.0.10","user_id":null,"updated_time":null,"is_custom":true},
                     {"setting_id":"GFSA00","name":"Bambu PLA Basic @BBL X1C","type":"filament","version":null,"user_id":null,"updated_time":null,"is_custom":false}],
         "printer":[{"setting_id":"GM030","name":"Bambu Lab A1 0.4 nozzle","type":"printer","version":"02.08.00.06","user_id":null,"updated_time":null,"is_custom":false}],
         "process":[{"setting_id":"GP139","name":"0.08mm Extra Fine @BBL H2D 0.2 nozzle","type":"process","version":"02.08.00.06","user_id":null,"updated_time":"2026-01-01 00:00:00","is_custom":false}]}
        """#)
        #expect(r.all.count == 4)
        #expect(r.presets(.filament)[0].isUserPreset)
        #expect(!r.presets(.filament)[1].isUserPreset)
        #expect(r.presets(.process)[0].kind == .process)
        let empty = try decode(ProfilesSlicerSettingsResponse.self, #"{"filament":[],"printer":[],"process":[]}"#)
        #expect(empty.all.isEmpty)
    }

    @Test func slicerSettingDetailKeepsRawKeys() throws {
        let d = try decode(ProfilesSlicerSettingDetail.self, #"""
        {"message":"success","code":null,"error":null,"public":false,"version":"2.4.0.10","type":"filament",
         "name":"INLAND PLA Pro @Bambu Lab P1S 0.4 nozzle","update_time":"2026-01-19 03:28:26","nickname":null,"base_id":null,
         "setting":{"activate_air_filtration":"0","compatible_printers":"\"Bambu Lab P1S 0.4 nozzle\"","bed_exclude_area":[],
                    "nozzle_temperature":["220","220"],"inherits":"Generic PLA @BBL P1S"},
         "filament_id":"P2c1be5e"}
        """#)
        #expect(d.public == false)
        #expect(d.filamentId == "P2c1be5e")
        #expect(d.settingObject["activate_air_filtration"]?.stringValue == "0")
        #expect(d.settingObject["nozzle_temperature"]?.arrayValue?.count == 2)
        #expect(d.settingObject["inherits"]?.stringValue == "Generic PLA @BBL P1S")
        // Bambu may return a numeric code on errors.
        let err = try decode(ProfilesSlicerSettingDetail.self, #"{"message":"not found","code":4,"error":"x","setting":null}"#)
        #expect(err.settingObject.isEmpty)
    }

    @Test func fieldDefinitions() throws {
        let f = try decode(ProfilesFieldDefinitions.self, #"""
        {"version":"1.0.0","description":"Filament preset field definitions","fields":[
          {"key":"filament_vendor","label":"Vendor","type":"text","category":"basic","description":"Filament manufacturer name"},
          {"key":"filament_type","label":"Filament Type","type":"select","category":"basic","options":[{"value":"PLA","label":"PLA"},{"value":"PA","label":"PA (Nylon)"}]},
          {"key":"nozzle_temperature","label":"Nozzle Temperature","type":"number","category":"temperature","unit":"°C","min":150,"max":350,"step":1},
          {"key":"enable_pressure_advance","label":"Enable PA","type":"boolean","category":"advanced"}]}
        """#)
        #expect(f.fields?.count == 4)
        #expect(f.fields?[1].options?.last?.label == "PA (Nylon)")
        #expect(f.fields?[2].max == 350)
    }

    @Test func localPresets() throws {
        let r = try decode(ProfilesLocalPresetsResponse.self, #"""
        {"filament":[{"id":3,"name":"Polymaker PLA Pro @BBL X1C","preset_type":"filament","source":"orcaslicer","filament_type":"PLA",
          "filament_vendor":null,"nozzle_temp_min":190,"nozzle_temp_max":230,"pressure_advance":"0.02","default_filament_colour":"[\"#FF0000\"]",
          "filament_cost":"25","filament_density":"1.24","compatible_printers":"[\"Bambu Lab X1 Carbon 0.4 nozzle\",\"Bambu Lab P1S 0.4 nozzle\"]",
          "inherits":"Generic PLA","version":"2.1.0.0","created_at":"2026-09-20T10:11:12.123456","updated_at":"2026-09-20T10:11:12"}],
         "printer":[{"id":4,"name":"My X1C","preset_type":"printer","source":"bambustudio","filament_type":null,"filament_vendor":null,
          "nozzle_temp_min":null,"nozzle_temp_max":null,"pressure_advance":null,"default_filament_colour":null,"filament_cost":null,
          "filament_density":null,"compatible_printers":null,"inherits":null,"version":null,"created_at":"2026-09-20T10:11:12","updated_at":"2026-09-20T10:11:12"}],
         "process":[]}
        """#)
        #expect(r.totalCount == 2)
        let p = r.presets(.filament)[0]
        #expect(p.explicitColorHex == "FF0000")
        #expect(p.resolvedVendor == "Polymaker")
        #expect(p.compatiblePrinterList == "Bambu Lab X1 Carbon 0.4 nozzle, Bambu Lab P1S 0.4 nozzle")
        #expect(r.presets(.printer)[0].kind == .printer)
        let detail = try decode(ProfilesLocalPresetDetail.self, #"""
        {"id":3,"name":"Polymaker PLA Pro","preset_type":"filament","source":"orcaslicer","filament_type":"PLA","filament_vendor":null,
         "nozzle_temp_min":null,"nozzle_temp_max":null,"pressure_advance":null,"default_filament_colour":null,"filament_cost":null,
         "filament_density":null,"compatible_printers":null,"inherits":null,"version":null,"created_at":"2026-09-20T10:11:12",
         "updated_at":"2026-09-20T10:11:12","setting":{"filament_type":["PLA"],"nozzle_temperature":["220"]}}
        """#)
        #expect(detail.setting?["filament_type"]?[0]?.stringValue == "PLA")
        let imp = try decode(ProfilesImportResult.self, #"{"success":true,"imported":2,"skipped":1,"errors":["bad.json: invalid"]}"#)
        #expect(imp.imported == 2 && imp.errors?.count == 1)
    }

    @Test func orcaCloud() throws {
        let status = try decode(ProfilesOrcaStatus.self, #"{"connected":false,"email":null,"user_id":null}"#)
        #expect(!status.connected)
        let start = try decode(ProfilesOrcaDeviceStart.self, #"{"user_code":"ABCD-EFGH","verification_uri":"https://auth.orcaslicer.com/device","verification_uri_complete":"https://auth.orcaslicer.com/device?code=ABCD-EFGH","interval":5,"expires_in":900}"#)
        #expect(start.userCode == "ABCD-EFGH")
        let poll = try decode(ProfilesOrcaPoll.self, #"{"status":"complete","connected":true,"email":"me@example.com","user_id":"u1"}"#)
        #expect(poll.status == "complete")
        let pending = try decode(ProfilesOrcaPoll.self, #"{"status":"authorization_pending"}"#)
        #expect(pending.connected == nil)
        let list = try decode(ProfilesOrcaProfileList.self, #"""
        {"filament":[{"setting_id":"7c1e7a4b-uuid","name":"My PETG @Bambu Lab P1S 0.4 nozzle","type":"filament","version":null,"user_id":"u1","updated_time":"2026-09-01T10:00:00Z","is_custom":true}],
         "printer":[],"process":[{"setting_id":"p1","name":"0.20mm Standard @BBL P1S","type":"process"}]}
        """#)
        #expect(list.all.count == 2)
        let detail = try decode(ProfilesOrcaProfileDetail.self, #"{"setting_id":"p1","name":"0.20mm Standard","type":"process","version":null,"base_id":null,"update_time":null,"setting":{"layer_height":"0.2"}}"#)
        #expect(detail.setting?["layer_height"]?.stringValue == "0.2")
    }

    @Test func kProfiles() throws {
        let r = try decode(ProfilesKProfilesResponse.self, #"""
        {"profiles":[
          {"slot_id":3,"extruder_id":1,"nozzle_id":"HH00-0.4","nozzle_diameter":"0.4","filament_id":"GFA00","name":"HF_Bambu PLA Basic","k_value":"0.024000","n_coef":"1.400000","ams_id":0,"tray_id":0,"setting_id":"PFUS123"},
          {"slot_id":5,"extruder_id":0,"nozzle_id":"","nozzle_diameter":"0.4","filament_id":"P2c1be5e","name":"S INLAND PLA Pro","k_value":"0.0199","n_coef":"0.000000","ams_id":0,"tray_id":0,"setting_id":null},
          {"slot_id":6,"nozzle_id":"HS00-0.4","nozzle_diameter":"0.4","filament_id":"GFL99","name":"Generic","k_value":"0.02"}],
         "nozzle_diameter":"0.4"}
        """#)
        #expect(r.profiles.count == 3)
        let hf = r.profiles[0]
        #expect(hf.isHighFlow && hf.flowLabel == "HF")
        #expect(hf.displayK == "0.024")
        #expect(hf.nameWithoutFlowPrefix == "Bambu PLA Basic")
        #expect(hf.noteKeys.first == "PFUS123")
        let std = r.profiles[1]
        #expect(!std.isHighFlow)
        #expect(std.displayK == "0.019")
        #expect(std.nameWithoutFlowPrefix == "INLAND PLA Pro")
        #expect(r.profiles[2].extruder == 0)
        let empty = try decode(ProfilesKProfilesResponse.self, #"{"profiles":[],"nozzle_diameter":"0.4"}"#)
        #expect(empty.profiles.isEmpty)
    }

    @Test func kProfileNotesKeepKeys() throws {
        let n = try decode(ProfilesKProfileNotes.self, #"{"notes":{"slot_3_GFA00_1":"Tuned on satin plate","name_S PLA_GFL99":"x","PFUS123":"y"}}"#)
        #expect(n.notes?["slot_3_GFA00_1"] == "Tuned on satin plate")
        #expect(n.notes?["name_S PLA_GFL99"] == "x")
        let empty = try decode(ProfilesKProfileNotes.self, #"{"notes":{}}"#)
        #expect(empty.notes?.isEmpty == true)
    }

    @Test func kProfileBodiesEncodeForTheWire() throws {
        let create = ProfilesKProfileCreate(slotId: 0, extruderId: 1, nozzleId: "HH00-0.4", nozzleDiameter: "0.4",
                                            filamentId: "GFA00", name: "HF PLA", kValue: ProfilesKMath.wire("0.02")!)
        let json = try JSONDecoder().decode(JSONValue.self, from: APICoders.encoder.encode(create))
        #expect(json["k_value"]?.stringValue == "0.020000")
        #expect(json["slot_id"]?.intValue == 0)
        #expect(json["nozzle_id"]?.stringValue == "HH00-0.4")
        #expect(json["setting_id"] == nil)
        let del = ProfilesKProfileDelete(slotId: 3, extruderId: 0, nozzleId: "HS00-0.4", nozzleDiameter: "0.4", filamentId: "GFL99", settingId: "PFUS1")
        let dj = try JSONDecoder().decode(JSONValue.self, from: APICoders.encoder.encode(del))
        #expect(dj["filament_id"]?.stringValue == "GFL99")
        #expect(dj["setting_id"]?.stringValue == "PFUS1")
    }

    @Test func kProfileExportRoundTrip() throws {
        let file = try decode(ProfilesKProfileExport.self, #"""
        {"version":1,"exported_at":"2026-09-26T12:00:00Z","printer":"Office Printer","nozzle_diameter":"0.4",
         "profiles":[{"name":"HF PLA","k_value":"0.024000","filament_id":"GFA00","nozzle_id":"HH00-0.4","nozzle_diameter":"0.4","extruder_id":0},
                     {"name":"Partial","k_value":"0.02","filament_id":"GFL99"}]}
        """#)
        #expect(file.profiles?.count == 2)
        #expect(file.profiles?[1].extruderId == nil)
        let back = try JSONValue.from(file)
        #expect(back["profiles"]?[0]?["k_value"]?.stringValue == "0.024000")
    }

    @Test func builtinFilamentsAndIdMap() throws {
        let b = try decode([ProfilesBuiltinFilament].self, #"[{"filament_id":"GFA00","name":"Bambu PLA Basic"},{"filament_id":"GFL99","name":"Generic PLA"}]"#)
        #expect(b.count == 2)
        let map = try decode([String: String].self, #"{"P2c1be5e":"INLAND PLA Pro","P510aba0":"INLAND PLA Mystic Silk"}"#)
        #expect(map["P2c1be5e"] == "INLAND PLA Pro")
    }
}

struct ProfilesLogicTests {
    @Test func presetMetadataFromNames() {
        let f = ProfilesPresetMeta.extract("Bambu PLA Basic @BBL X1C 0.4 nozzle")
        #expect(f.printer == "X1C")
        #expect(f.nozzle == "0.4mm")
        #expect(f.filamentType == "PLA")
        let p = ProfilesPresetMeta.extract("0.20mm Standard @BBL P1S")
        #expect(p.layerHeight == "0.20mm")
        #expect(p.printer == "P1S")
        #expect(ProfilesPresetMeta.isUserPresetId("PFUS62fd75c3c2e199"))
        #expect(ProfilesPresetMeta.isUserPresetId("PP123"))
        #expect(!ProfilesPresetMeta.isUserPresetId("GFSA00"))
    }

    @Test func filamentIdHelpers() {
        #expect(ProfilesPresetMeta.filamentId(fromSettingId: "GFSG98_01") == "GFG98")
        #expect(ProfilesPresetMeta.genericFilamentId(for: "PETG") == "GFG99")
        #expect(ProfilesPresetMeta.genericFilamentId(for: "ABS-CF") == "GFB99")
        #expect(ProfilesPresetMeta.genericFilamentId(for: "") == "")
        #expect(ProfilesPresetMeta.material(fromPresetName: "Polymaker PETG-CF @BBL X1C") == "PETG-CF")
        #expect(ProfilesPresetMeta.displayName("# Overture PLA @BBL P1S") == "Overture PLA")
    }

    @Test func filamentOptionsDedupeAcrossSources() {
        let local = [ProfilesLocalPreset(id: 1, name: "Overture PLA @BBL X1C", presetType: "filament", filamentType: "PLA")]
        let cloud = [ProfilesSlicerSetting(settingId: "GFSA00", name: "Bambu PLA Basic @BBL X1C", type: "filament"),
                     ProfilesSlicerSetting(settingId: "PFUS1", name: "Overture PLA @BBL P1S", type: "filament")]
        let builtin = [ProfilesBuiltinFilament(filamentId: "GFA00", name: "Bambu PLA Basic"),
                       ProfilesBuiltinFilament(filamentId: "GFL99", name: "Generic PLA")]
        let opts = ProfilesFilamentOption.build(local: local, orca: [], cloud: cloud, builtin: builtin)
        #expect(opts.first?.source == .local)
        #expect(opts.first?.filamentId == "GFL99")
        // Cloud user preset has no id yet (resolved from detail later).
        #expect(opts.first { $0.id == "PFUS1" }?.filamentId == "")
        // Built-in "Bambu PLA Basic" is already offered by the cloud tier.
        #expect(!opts.contains { $0.source == .builtin && $0.filamentId == "GFA00" })
        #expect(opts.contains { $0.source == .builtin && $0.filamentId == "GFL99" })
        #expect(opts.first { $0.id == "GFSA00" }?.filamentId == "GFA00")
    }

    @Test func kValueFormatting() {
        #expect(ProfilesKMath.truncated("0.0249") == "0.024")
        #expect(ProfilesKMath.wire("0.02") == "0.020000")
        #expect(ProfilesKMath.wire("abc") == nil)
        #expect(ProfilesKMath.wire("-1") == nil)
    }

    @Test func fieldControlKeepsArrayShape() {
        let v = ProfilesFieldControl.value(from: "220, 225", like: .array(["210", "210"]))
        #expect(v == .array(["220", "225"]))
        #expect(ProfilesFieldControl.value(from: "1", like: .string("0")) == .string("1"))
        #expect(ProfilesFieldControl.editText(.array(["a", "b"])) == "a, b")
    }

    @Test func templatesRoundTrip() throws {
        let t = ProfilesPresetTemplate(id: "1", name: "Silk", description: "Slow & hot", type: "filament",
                                       settings: ["nozzle_temperature": ["230"]], showInModal: true)
        let data = try JSONEncoder().encode([t])
        let back = try JSONDecoder().decode([ProfilesPresetTemplate].self, from: data)
        #expect(back.first?.settings["nozzle_temperature"] == ["230"])
        #expect(back.first?.kind == .filament)
    }

    @Test func presetFilterMatches() {
        let a = ProfilesSlicerSetting(settingId: "PFUS1", name: "My PETG @BBL P1S 0.4 nozzle", type: "filament")
        let meta = ProfilesPresetMeta.extract(a.name)
        var f = ProfilesPresetFilter()
        #expect(f.matches(a, meta: meta, search: "petg"))
        f.owner = .builtin
        #expect(!f.matches(a, meta: meta, search: ""))
        f = ProfilesPresetFilter(kind: .process)
        #expect(!f.matches(a, meta: meta, search: ""))
        f = ProfilesPresetFilter(printerModel: "P1S", printerId: 1)
        #expect(f.matches(a, meta: meta, search: ""))
        f.printerModel = "X1C"
        #expect(!f.matches(a, meta: meta, search: ""))
    }
}

// MARK: - Statistics


struct StatsDecodeTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesEmptyStatsFromLiveServer() throws {
        let s = try decode(StatsSummary.self, #"""
        {"total_prints":0,"successful_prints":0,"failed_prints":0,"cancelled_prints":0,"total_print_time_hours":0.0,
         "total_filament_grams":0.0,"total_cost":0.0,"prints_by_filament_type":{},"prints_by_printer":{},"printer_names":{},
         "average_time_accuracy":null,"time_accuracy_by_printer":null,"total_energy_kwh":0.0,"total_energy_cost":0.0,
         "energy_data_warming_up":false}
        """#)
        #expect(s.totalPrints == 0)
        #expect(s.averageTimeAccuracy == nil)
        #expect(s.timeAccuracyByPrinter == nil)
        #expect(s.printsByPrinter?.isEmpty == true)
    }

    @Test func decodesPopulatedStatsKeepingDictionaryKeys() throws {
        let s = try decode(StatsSummary.self, #"""
        {"total_prints":12,"successful_prints":9,"failed_prints":2,"cancelled_prints":1,"total_print_time_hours":41.3,
         "total_filament_grams":1520.4,"total_cost":38.02,"prints_by_filament_type":{"PLA_Basic":7,"PETG":4},
         "prints_by_printer":{"1":8,"2":4,"None":0},"printer_names":{"1":"X1C_Lab","2":"P1S"},
         "average_time_accuracy":97.3,"time_accuracy_by_printer":{"1":101.5,"unknown":88.0},
         "total_energy_kwh":4.125,"total_energy_cost":0.619,"energy_data_warming_up":true}
        """#)
        #expect(s.printsByFilamentType?["PLA_Basic"] == 7)
        #expect(s.printerNames?["1"] == "X1C_Lab")
        #expect(s.timeAccuracyByPrinter?["unknown"] == 88)
        #expect(s.energyDataWarmingUp == true)
    }

    @Test func decodesStatsFromOlderServerWithoutOptionalFields() throws {
        let s = try decode(StatsSummary.self, #"""
        {"total_prints":3,"successful_prints":3,"failed_prints":0,"total_print_time_hours":2,"total_filament_grams":50,
         "total_cost":1,"prints_by_filament_type":{},"prints_by_printer":{"1":3}}
        """#)
        #expect(s.cancelledPrints == nil)
        #expect(s.totalEnergyKwh == nil)
    }

    @Test func decodesSlimRuns() throws {
        let runs = try decode([StatsPrintRun].self, #"""
        [{"printer_id":1,"print_name":"Benchy","print_time_seconds":3600,"actual_time_seconds":3720,
          "filament_used_grams":14.2,"filament_type":"PLA, PETG","filament_color":"#FF0000,00AE42FF","status":"completed",
          "started_at":"2026-09-20T10:00:00","completed_at":"2026-09-20T11:02:00","cost":0.36,"energy_kwh":0.12,
          "energy_cost":0.02,"quantity":1,"created_at":"2026-09-20T10:00:00.123456"},
         {"printer_id":null,"print_name":null,"print_time_seconds":null,"actual_time_seconds":null,
          "filament_used_grams":null,"filament_type":null,"filament_color":null,"status":"aborted",
          "started_at":null,"completed_at":null,"cost":null,"energy_kwh":null,"energy_cost":null,"quantity":1,
          "created_at":"2026-09-21T08:00:00Z"}]
        """#)
        #expect(runs.count == 2)
        #expect(runs[0].materials == ["PLA", "PETG"])
        #expect(runs[0].colors == ["#FF0000", "00AE42FF"])
        #expect(runs[0].effectiveSeconds == 3720)
        #expect(runs[0].createdDate != nil)
        #expect(runs[1].materials == ["Unknown"])
        #expect(runs[1].isFailed)
        #expect(runs[1].effectiveSeconds == 0)
    }

    @Test func decodesFailureAnalysis() throws {
        let a = try decode(StatsFailureAnalysis.self, #"""
        {"period_days":30,"total_prints":10,"failed_prints":2,"failure_rate":22.2,
         "failures_by_reason":{"spaghettiDetached":1,"Unknown":1},"failures_by_filament":{"PETG":2},
         "failures_by_printer":{"P1S":2},"failures_by_hour":{"0":0,"13":1,"23":1},
         "recent_failures":[{"id":null,"print_name":"Clip","failure_reason":null,"filament_type":null,"printer_id":2,"created_at":null},
                            {"id":7,"print_name":"Box","failure_reason":"layerShift","filament_type":"PETG","printer_id":null,"created_at":"2026-09-19T12:00:00+00:00"}],
         "trend":[{"week_start":"2026-08-29","total_prints":0,"failed_prints":0,"failure_rate":0},
                  {"week_start":"2026-09-05","total_prints":10,"failed_prints":2,"failure_rate":22.2}]}
        """#)
        #expect(a.failureRate == 22.2)
        #expect(a.failuresByHour?["13"] == 1)
        #expect(a.recentFailures?.first?.id == nil)
        #expect(a.trend?.count == 2)
    }

    @Test func decodesEmptyFailureAnalysisFromLiveServer() throws {
        let a = try decode(StatsFailureAnalysis.self, #"""
        {"period_days":30,"total_prints":0,"failed_prints":0,"failure_rate":0,"failures_by_reason":{},"failures_by_filament":{},
         "failures_by_printer":{},"failures_by_hour":{"0":0,"1":0},"recent_failures":[],
         "trend":[{"week_start":"2026-08-29","total_prints":0,"failed_prints":0,"failure_rate":0}]}
        """#)
        #expect(a.totalPrints == 0)
        #expect(a.recentFailures?.isEmpty == true)
    }

    @Test func decodesUsersAndRecalculateResult() throws {
        let users = try decode([StatsUserOption].self, #"[{"id":1,"username":"admin"},{"id":4,"username":"maker"}]"#)
        #expect(users.map(\.id) == [1, 4])
        let r = try decode(StatsRecalculateResult.self, #"{"message":"Recalculated costs for 5 archives","updated":5}"#)
        #expect(r.updated == 5)
    }
}

struct StatsAggregatorTests {
    private func run(_ status: String, grams: Double = 10, seconds: Int = 3600, type: String? = "PLA",
                     color: String? = nil, printer: Int? = 1, created: String = "2026-09-20T10:00:00") -> StatsPrintRun {
        StatsPrintRun(printerId: printer, printName: "p", printTimeSeconds: seconds, actualTimeSeconds: seconds,
                      filamentUsedGrams: grams, filamentType: type, filamentColor: color, status: status,
                      startedAt: created, completedAt: created, cost: grams / 10, energyKwh: nil, energyCost: nil,
                      quantity: 1, createdAt: created)
    }

    @Test func outcomesTreatCancelledAsNeutral() {
        let c = StatsAggregator.outcomes([run("completed"), run("completed"), run("failed"), run("aborted"), run("cancelled")])
        #expect(c.total == 5)
        #expect(c.failed == 2)
        #expect(c.cancelled == 1)
        #expect(c.successRate == 50)
    }

    @Test func summaryFromRunsForPrinterFilter() {
        let s = StatsAggregator.summary(from: [run("completed", grams: 20, type: "PLA, PETG"), run("failed", grams: 5)], printerId: 1)
        #expect(s.totalPrints == 2)
        #expect(s.totalFilamentGrams == 25)
        #expect(s.printsByFilamentType?["PLA"] == 2)
        #expect(s.printsByFilamentType?["PETG"] == 1)
        #expect(s.totalPrintTimeHours == 2)
    }

    @Test func materialWeightIsSplitAcrossMultiMaterialPrints() {
        let data = StatsAggregator.byMaterial([run("completed", grams: 30, type: "PLA, PETG"), run("completed", grams: 10, type: nil)], metric: .weight)
        #expect(data.first { $0.name == "PLA" }?.value == 15)
        #expect(data.first { $0.name == "Unknown" }?.value == 10)
    }

    @Test func colorsAndDurations() {
        let runs = [run("completed", grams: 20, seconds: 1200, color: "FF0000,00FF00"), run("completed", grams: 10, seconds: 90000, color: "FF0000")]
        let colors = StatsAggregator.colors(runs, metric: .weight)
        #expect(colors.first?.name == "FF0000")
        #expect(colors.first?.value == 20)
        let hist = StatsAggregator.durationHistogram(runs)
        #expect(hist.first?.value == 1)
        #expect(hist.last?.value == 1)
    }

    @Test func recordsAndStreak() {
        let runs = [
            run("completed", grams: 50, created: "2026-09-21T10:00:00"),
            run("completed", grams: 80, created: "2026-09-21T12:00:00"),
            run("failed", grams: 5, created: "2026-09-19T10:00:00"),
        ]
        let records = StatsAggregator.records(runs, currencyCode: "USD")
        #expect(records.contains { $0.kind == .heaviest })
        #expect(records.contains { $0.kind == .busiestDay && $0.value == "2 prints" })
        #expect(records.first { $0.kind == .streak }?.value == "2")
    }

    @Test func materialSuccessNeedsTwoDecidedRuns() {
        let data = StatsAggregator.materialSuccess([run("completed"), run("failed"), run("completed", type: "ABS")])
        #expect(data.count == 1)
        #expect(data.first?.rate == 50)
    }

    @Test func reasonLabels() {
        #expect(StatsAggregator.reasonLabel("spaghettiDetached") == "Spaghetti detached")
        #expect(StatsAggregator.reasonLabel("layer_shift") == "Layer shift")
        #expect(StatsAggregator.reasonLabel("Unknown") == "Unknown")
        #expect(StatsAggregator.reasonLabel("Nozzle clog on layer 3") == "Nozzle clog on layer 3")
    }

    @Test func timeframeRangesAndApiDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 15))!
        let last7 = StatsTimeframe.last7.range(now: now, calendar: cal)
        #expect(StatsTimeframe.apiDay(last7.from, calendar: cal) == "2026-09-20")
        #expect(StatsTimeframe.apiDay(last7.to, calendar: cal) == "2026-09-26")
        let week = StatsTimeframe.thisWeek.range(now: now, calendar: cal)
        #expect(StatsTimeframe.apiDay(week.from, calendar: cal) == "2026-09-21") // Monday
        #expect(StatsTimeframe.allTime.range(now: now, calendar: cal).from == nil)
        #expect(StatsTimeframe.apiDay(StatsTimeframe.thisYear.range(now: now, calendar: cal).from, calendar: cal) == "2026-01-01")
    }

    @Test func layoutParsingIsTolerant() {
        let l = StatsLayout(orderRaw: "records,bogus,quick-stats,records", hiddenRaw: "filament-trends,nope")
        #expect(l.order.first == .records)
        #expect(l.order.count == StatsWidgetKind.allCases.count)
        #expect(l.hidden == [.filamentTrends])
        #expect(!l.visible.contains(.filamentTrends))
        #expect(StatsLayout(orderRaw: "", hiddenRaw: "") == .standard)
    }
}

// MARK: - Finance


struct FinanceDecodeTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func walletBalanceWithAndWithoutTimestamp() throws {
        let stored = try decode(FinanceWalletBalance.self,
            #"{"user_id": 3, "balance": 20.0, "currency": "USD", "updated_at": "2026-09-20T10:11:12.123456"}"#)
        #expect(stored.balance == 20)
        #expect(stored.currency == "USD")
        #expect(stored.updatedAt != nil)
        // GET me/balance for a user without a wallet row returns updated_at: null.
        let computed = try decode(FinanceWalletBalance.self,
            #"{"user_id": 4, "balance": 0, "currency": "EUR", "updated_at": null}"#)
        #expect(computed.updatedAt == nil)
    }

    @Test func transactionPageWithNulls() throws {
        let json = """
        {"items": [
          {"id": 12, "user_id": 2, "cost_center_id": 5, "transaction_type": "print_charge", "amount": -3.4,
           "balance_after": 16.6, "description": "Benchy.3mf [cancelled: 40% printed]", "created_by_user_id": null,
           "print_run_id": "a1b2c3", "print_archive_id": 99, "print_queue_id": 7, "created_at": "2026-09-24T16:02:11.000123"},
          {"id": 11, "user_id": 2, "cost_center_id": null, "transaction_type": "deposit", "amount": 20.0,
           "balance_after": null, "description": null, "created_by_user_id": 1, "print_run_id": null,
           "print_archive_id": null, "print_queue_id": null, "created_at": "2026-09-20T08:00:00+00:00"},
          {"id": 10, "user_id": 2, "cost_center_id": 5, "transaction_type": "manual_adjustment", "amount": -4.0,
           "balance_after": 0.0, "description": "Manual print charge (Admin edit)", "created_by_user_id": 1,
           "print_run_id": null, "print_archive_id": null, "print_queue_id": null, "created_at": "2026-09-01T00:00:00Z"},
          {"id": 9, "user_id": 2, "transaction_type": "refund", "amount": 1.0, "created_at": "2026-08-01T00:00:00"}
        ], "total": 57, "limit": 50, "offset": 0}
        """
        let page = try decode(FinanceTransactionPage.self, json)
        #expect(page.total == 57)
        #expect(page.items.count == 4)
        let charge = page.items[0]
        #expect(charge.kind == .printCharge)
        #expect(charge.partialStatus == "cancelled")
        #expect(charge.displayDescription == "Benchy.3mf")
        #expect(charge.printArchiveId == 99)
        #expect(page.items[1].costCenterId == nil)
        #expect(page.items[1].balanceAfter == nil)
        #expect(page.items[2].kind == .manualAdjustment)
        #expect(page.items[2].partialStatus == nil)
        #expect(page.items[3].kind == .other)
    }

    @Test func costCenterSummaryAndDetail() throws {
        let list = try decode([FinanceCostCenter].self, """
        [{"id": 1, "name": "alice", "is_private": true, "owner_user_id": 2, "is_active": true, "total_balance": 25.0,
          "total_budget": 0.0, "monthly_budget": null, "budget_mode": "total", "budget_limit": 0.0, "budget_used": 0.0,
          "budget_available": 0.0, "can_print": true},
         {"id": 2, "name": "Lab", "is_private": false, "owner_user_id": null, "is_active": true, "total_balance": 0.0,
          "total_budget": null, "monthly_budget": null, "budget_mode": "none", "budget_limit": null, "budget_used": null,
          "budget_available": null, "can_print": false}]
        """)
        #expect(list.count == 2)
        #expect(list[0].budgetFraction == 1)
        #expect(list[1].hasBudget == false)
        #expect(list[1].budgetFraction == nil)
        #expect(list[1].canPrint == false)

        let detail = try decode(FinanceCostCenter.self, """
        {"id": 3, "name": "Robotics", "is_private": false, "owner_user_id": null, "is_active": false, "total_balance": -12.5,
         "total_budget": null, "monthly_budget": 50.0, "budget_mode": "monthly", "budget_limit": 50.0, "budget_used": 12.5,
         "budget_available": 37.5, "can_print": true,
         "members": [{"id": 8, "cost_center_id": 3, "user_id": 4, "can_print": false, "created_at": "2026-09-01T12:00:00"}]}
        """)
        #expect(detail.members?.first?.userId == 4)
        #expect(detail.members?.first?.canPrint == false)
        #expect(detail.budgetFraction == 0.25)
        #expect(detail.budgetModeLabel == "Monthly budget")
    }

    @Test func minimalCostCenterUsesDefaults() throws {
        // Only the schema's required fields.
        let c = try decode(FinanceCostCenter.self, #"{"id": 9, "name": "X", "is_private": false, "is_active": true}"#)
        #expect(c.totalBalance == nil)
        #expect(c.budgetMode == nil)
        #expect(c.hasBudget == false)
    }

    @Test func adjustmentResponse() throws {
        let r = try decode(FinanceAdjustmentResult.self, """
        {"transaction": {"id": 30, "user_id": 2, "cost_center_id": 1, "transaction_type": "withdraw", "amount": -5.0,
          "balance_after": 20.0, "description": null, "created_by_user_id": 1, "print_run_id": null,
          "print_archive_id": null, "print_queue_id": null, "created_at": "2026-09-25T09:00:00"},
         "balance": {"user_id": 2, "balance": 20.0, "currency": "EUR", "updated_at": "2026-09-25T09:00:00"}}
        """)
        #expect(r.transaction.kind == .withdraw)
        #expect(r.balance.balance == 20)
    }

    @Test func memberAndUsers() throws {
        let m = try decode(FinanceCostCenterMember.self,
            #"{"id": 1, "cost_center_id": 2, "user_id": 3, "can_print": true, "created_at": "2026-09-25T09:00:00.5"}"#)
        #expect(m.canPrint)
        let users = try decode([FinanceUserSlim].self, #"[{"id": 1, "username": "admin"}, {"id": 2, "username": "bob"}]"#)
        #expect(users.map(\.username) == ["admin", "bob"])
    }

    @Test func requestBodiesUseSnakeCase() throws {
        let create = try JSONValue.from(FinanceCostCenterCreate(name: "Lab", totalBudget: nil, monthlyBudget: 25))
        #expect(create["monthly_budget"]?.doubleValue == 25)
        #expect(create["is_active"]?.boolValue == true)
        let manual = try JSONValue.from(FinanceManualCharge(userId: 2, costCenterId: 3, amount: 4, description: nil,
                                                            createdAt: Date(timeIntervalSince1970: 0)))
        #expect(manual["cost_center_id"]?.intValue == 3)
        #expect(manual["created_at"]?.stringValue == "1970-01-01T00:00:00Z")
        let adjust = try JSONValue.from(FinanceWalletAdjustment(amount: 5, description: "x", costCenterId: nil))
        #expect(adjust["amount"]?.doubleValue == 5)
        // Explicit nulls survive encoding (used to clear budgets / move a transaction to the personal account).
        let patch: JSONValue = ["cost_center_id": nil, "monthly_budget": nil]
        let data = try APICoders.encoder.encode(patch)
        let raw = String(decoding: data, as: UTF8.self)
        #expect(raw.contains("\"cost_center_id\":null"))
    }

    @Test func chargeNoteParsing() {
        #expect(FinanceChargeNote.parse("Part.3mf [failed: 12%]").status == "failed")
        #expect(FinanceChargeNote.parse("Part.3mf [failed: 12%]").text == "Part.3mf")
        #expect(FinanceChargeNote.parse("[aborted: early]").text == nil)
        #expect(FinanceChargeNote.parse("Plain [note]").status == nil)
        #expect(FinanceChargeNote.parse("Other [paused: 1]").status == nil)
        #expect(FinanceChargeNote.parse(nil).text == nil)
    }

    @Test @MainActor func previewFixtureDecodes() throws {
        #if DEBUG
        let bundle = try APICoders.decoder.decode(FinancePreviewData.self, from: Data(FinancePreviewData.json.utf8))
        #expect(bundle.centers.count == 3)
        #expect(bundle.transactions.count == 6)
        #endif
    }

    @Test func permissionsGating() {
        let own = FinancePermissions(readOwn: true, readAll: false, create: false, modify: false, readUsers: false)
        #expect(own.canAccess)
        #expect(!own.hasAdminView)
        let billing = FinancePermissions(readOwn: false, readAll: false, create: false, modify: true, readUsers: true)
        #expect(billing.canAccess)
        #expect(billing.accessAllCenters)
        #expect(billing.canAdjustWallets)
        let none = FinancePermissions(readOwn: false, readAll: false, create: false, modify: false, readUsers: true)
        #expect(!none.canAccess)
    }
}
