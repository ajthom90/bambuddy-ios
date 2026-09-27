import Testing
import Foundation
import UIKit
@testable import Bambuddy

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try APICoders.decoder.decode(T.self, from: Data(json.utf8))
}

struct PrinterExtrasDecodingTests {
    // MARK: Files

    @Test func fileListingFromLiveServer() throws {
        let json = #"{"path":"/","files":[{"name":"cache","is_directory":true,"size":0,"path":"/cache","mtime":"2026-01-11T00:00:00"},{"name":"fuel_funnel.stl.gcode.3mf","is_directory":false,"size":2538111,"path":"/fuel_funnel.stl.gcode.3mf","mtime":"2026-01-14T00:00:00"},{"name":"weird","is_directory":false,"size":16,"path":"/weird"}],"warnings":[]}"#
        let listing = try decode(PrinterFileListing.self, json)
        #expect(listing.files.count == 3)
        #expect(listing.files[0].isDirectory)
        #expect(listing.files[1].is3MF)
        #expect(listing.files[1].size == 2538111)
        #expect(listing.files[1].date != nil)
        #expect(listing.files[2].mtime == nil)
        #expect(!listing.printerUnavailable)
    }

    @Test func fileListingUnavailable() throws {
        let listing = try decode(PrinterFileListing.self, #"{"path":"/","files":[],"warnings":["printer_unavailable"]}"#)
        #expect(listing.printerUnavailable)
    }

    @Test func storageShapes() throws {
        #expect(try decode(PrinterStorageInfo.self, #"{"used_bytes":1507721328}"#).freeBytes == nil)
        let both = try decode(PrinterStorageInfo.self, #"{"used_bytes":1073741824,"free_bytes":3221225472}"#)
        #expect(both.freeBytes == 3221225472)
        let none = try decode(PrinterStorageInfo.self, #"{"used_bytes":null,"free_bytes":null}"#)
        #expect(none.usedBytes == nil)
    }

    @Test func platesDecode() throws {
        let json = ##"{"printer_id":1,"path":"/fuel_funnel.stl.gcode.3mf","filename":"fuel_funnel.stl.gcode.3mf","plates":[{"index":1,"name":"fuel_funnel.stl","objects":["fuel_funnel.stl"],"object_count":1,"has_thumbnail":true,"thumbnail_url":"/api/v1/printers/1/files/plate-thumbnail/1?path=/fuel_funnel.stl.gcode.3mf","print_time_seconds":9137,"filament_used_grams":35.38,"filaments":[{"slot_id":1,"type":"PLA","color":"#FFFFFF","used_grams":35.4,"used_meters":11.86}]},{"index":2,"name":null,"objects":[],"object_count":0,"has_thumbnail":false,"thumbnail_url":"/x","print_time_seconds":null,"filament_used_grams":null,"filaments":[]}],"is_multi_plate":true}"##
        let plates = try decode(PrinterFilePlates.self, json)
        #expect(plates.plates.count == 2)
        #expect(plates.plates[0].filaments?.first?.usedGrams == 35.4)
        #expect(plates.plates[1].name == nil)
    }

    @Test func downloadJobDecodeAndEncode() throws {
        let job = try decode(PrinterFilesJob.self, #"{"job_id":"job-id","printer_id":3,"state":"queued","requested":2,"successful":0,"failed":0,"token":null,"filename":"Test Printer videos.zip","message":null}"#)
        #expect(job.isPending)
        #expect(job.fraction == 0)
        let ready = try decode(PrinterFilesJob.self, #"{"job_id":"job-id","state":"ready","token":"download-token","requested":2,"successful":1,"failed":1,"message":null}"#)
        #expect(!ready.isPending)
        #expect(ready.fraction == 1)

        let body = PrinterFilesJobRequest(paths: ["/a.3mf"], sizes: ["/a.3mf": 10], filename: "X-files.zip", asZip: true)
        let encoded = try JSONValue.from(body)
        #expect(encoded["as_zip"]?.boolValue == true)
        #expect(encoded["sizes"]?["/a.3mf"]?.intValue == 10)
    }

    @Test func fileSortingAndParents() {
        let files = [
            PrinterFileEntry(name: "b.3mf", isDirectory: false, size: 5, path: "/b.3mf", mtime: "2026-01-02T00:00:00"),
            PrinterFileEntry(name: "a.gcode", isDirectory: false, size: 50, path: "/a.gcode", mtime: nil),
            PrinterFileEntry(name: "zdir", isDirectory: true, size: 0, path: "/zdir", mtime: nil),
        ]
        #expect(PrinterFileSort.nameAsc.sorted(files).map(\.name) == ["zdir", "a.gcode", "b.3mf"])
        #expect(PrinterFileSort.sizeDesc.sorted(files).map(\.name) == ["zdir", "a.gcode", "b.3mf"])
        #expect(PrinterFileSort.dateDesc.sorted(files).map(\.name) == ["zdir", "b.3mf", "a.gcode"])
        #expect(PrinterFileEntry.parent(of: "/cache/sub/x.3mf") == "/cache/sub")
        #expect(PrinterFileEntry.parent(of: "/cache") == "/")
        #expect(PrinterFileEntry.parent(of: "/") == "/")
    }

    // MARK: Skip objects

    @Test func printObjectsDecode() throws {
        let live = try decode(PrintableObjectsResponse.self, #"{"objects":[{"id":305,"name":"水獺3.obj_A","x":128.99,"y":95.68,"skipped":false}],"total":1,"skipped_count":0,"is_printing":true,"bbox_all":[117.8,52.7,159.7,223.5]}"#)
        #expect(live.objects.first?.id == 305)
        #expect(live.bboxAll?.count == 4)
        let legacy = try decode(PrintableObjectsResponse.self, #"{"objects":[{"id":100,"name":"Part A","x":null,"y":null,"skipped":false},{"id":200,"name":"Part B","x":150.0,"y":100.0,"skipped":true}],"total":2,"skipped_count":1,"is_printing":true,"bbox_all":null}"#)
        #expect(legacy.objects[1].isSkipped)
        #expect(legacy.bboxAll == nil)
        let result = try decode(SkipObjectsResult.self, #"{"success":true,"message":"Skipped 2 object(s): Part A, Part C","skipped_objects":[100,300]}"#)
        #expect(result.skippedObjects == [100, 300])
    }

    @Test func pickMaskDecodesObjectIds() throws {
        // 2x1 image: object 305 (R=0x31, G=0x01) and transparent background.
        #expect(PrintObjectPickMask.decode(r: 52, g: 18, b: 1, a: 255) == 65536 + 18 * 256 + 52)
        #expect(PrintObjectPickMask.decode(r: 10, g: 0, b: 0, a: 0) == 0)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 1), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false; return f
        }())
        let png = renderer.pngData { ctx in
            UIColor(red: 0x31 / 255.0, green: 0x01 / 255.0, blue: 0, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let mask = try #require(PrintObjectPickMask(pngData: png))
        #expect(mask.width == 2 && mask.height == 1)
        #expect(mask.id(atX: 0, y: 0) == 305)
        #expect(mask.id(atX: 1, y: 0) == nil)
        // Aspect-fit mapping: a 2x1 mask in a 200x200 box is letterboxed vertically.
        let px = mask.pixel(for: CGPoint(x: 150, y: 100), in: CGSize(width: 200, height: 200))
        #expect(px?.x == 1 && px?.y == 0)
        #expect(mask.pixel(for: CGPoint(x: 150, y: 10), in: CGSize(width: 200, height: 200)) == nil)
    }

    // MARK: K-profiles

    @Test func kProfilesDecode() throws {
        let json = #"{"profiles":[{"slot_id":16,"extruder_id":1,"nozzle_id":"HH00-0.4","nozzle_diameter":"0.4","filament_id":"GFA00","name":"Bambu PLA Basic","k_value":"0.018900","n_coef":"0.000000","ams_id":0,"tray_id":-1,"setting_id":null},{"slot_id":0,"nozzle_id":"","nozzle_diameter":"0.4","filament_id":"GFL99","name":"","k_value":"0.020000"}],"nozzle_diameter":"0.4"}"#
        let r = try decode(PrinterKProfilesResponse.self, json)
        #expect(r.profiles.count == 2)
        #expect(r.profiles[0].isHighFlow)
        #expect(r.profiles[0].kDisplay == "0.018")
        #expect(r.profiles[1].extruder == 0)
        #expect(r.profiles[1].displayName == "Unnamed")
        #expect(r.profiles[0].noteKeys == ["slot_16_GFA00_1", "name_Bambu PLA Basic_GFA00"])
        #expect(try decode(PrinterKProfilesResponse.self, #"{"profiles":[],"nozzle_diameter":"0.4"}"#).profiles.isEmpty)
    }

    @Test func kProfileNotesKeepRawKeys() throws {
        let notes = try decode(PrinterKProfileNotes.self, #"{"notes":{"PFUS123":"Dried first","slot_3_GFA00_0":"old","name_My PLA_GFL99":"x"}}"#)
        #expect(notes.notes["PFUS123"] == "Dried first")
        #expect(notes.notes["slot_3_GFA00_0"] == "old")
        let p = PrinterKProfile(slotId: 3, extruderId: 0, nozzleId: "HS00-0.4", nozzleDiameter: "0.4", filamentId: "GFA00", name: "PLA", kValue: "0.02", settingId: nil)
        #expect(notes.note(for: p)?.text == "old")
        #expect(try decode(PrinterKProfileNotes.self, #"{"notes":{}}"#).notes.isEmpty)
    }

    @Test func kProfileWriteEncodesSnakeCase() throws {
        let body = PrinterKProfileWrite(slotId: 0, extruderId: 1, nozzleId: "HS00-0.4", nozzleDiameter: "0.4", filamentId: "GFL99", name: "S PLA", kValue: "0.020000", settingId: nil)
        let v = try JSONValue.from(body)
        #expect(v["slot_id"]?.intValue == 0)
        #expect(v["k_value"]?.stringValue == "0.020000")
        #expect(v["nozzle_diameter"]?.stringValue == "0.4")
    }

    @Test func kProfileExportRoundTrip() throws {
        let json = #"{"version":1,"exported_at":"2026-09-26T00:00:00Z","printer":"X1C","nozzle_diameter":"0.4","profiles":[{"name":"PLA","k_value":"0.020000","filament_id":"GFA00","nozzle_id":"HS00-0.4","nozzle_diameter":"0.4","extruder_id":0},{"name":"broken"}]}"#
        let file = try decode(PrinterKProfileExport.self, json)
        #expect(file.profiles.count == 2)
        #expect(file.profiles[1].kValue == nil)
    }

    // MARK: Slot configuration

    @Test func slotPresetSourcesDecode() throws {
        let cloud = try decode(PrinterCloudSettings.self, #"{"filament":[{"setting_id":"PFUS62fd75c3c2e199","name":"INLAND PLA Pro @Bambu Lab P1S 0.4 nozzle","type":"filament","version":"2.4.0.10","user_id":null,"updated_time":null,"is_custom":true},{"setting_id":"GFSB00_07","name":"Bambu ABS @BBL A1","type":"filament","version":"02.08.00.06","user_id":null,"updated_time":null,"is_custom":false}],"printer":[],"process":[]}"#)
        #expect(cloud.filament?.count == 2)
        let local = try decode(PrinterLocalPresets.self, ##"{"filament":[{"id":12,"name":"eSUN PLA+ @Bambu Lab X1 Carbon 0.4 nozzle","preset_type":"filament","source":"orcaslicer","filament_type":"PLA","filament_vendor":"eSUN","nozzle_temp_min":null,"nozzle_temp_max":230,"pressure_advance":null,"default_filament_colour":"#FFFFFF","filament_cost":null,"filament_density":null,"compatible_printers":"[\"Bambu Lab X1 Carbon 0.4 nozzle\"]","inherits":null,"version":null,"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}],"printer":[],"process":[]}"##)
        #expect(local.filament?.first?.compatiblePrinterNames == ["Bambu Lab X1 Carbon 0.4 nozzle"])
        let builtin = try decode([PrinterBuiltinFilament].self, #"[{"filament_id":"GFA00","name":"Bambu PLA Basic"}]"#)
        #expect(builtin.first?.filamentId == "GFA00")
        let detail = try decode(PrinterCloudSettingDetail.self, #"{"public":false,"type":"filament","name":"x","setting":{"a":1},"filament_id":null,"base_id":"GFSL99"}"#)
        #expect(detail.filamentId == nil)
    }

    @Test func slotPresetMapAndDefaultsDecode() throws {
        let map = try decode([String: PrinterSlotPreset].self, #"{"3":{"ams_id":0,"tray_id":3,"preset_id":"GFSL05_09","preset_name":"Bambu PLA Basic"},"1020":{"ams_id":255,"tray_id":0,"preset_id":"local_12","preset_name":"eSUN PLA+"}}"#)
        #expect(map["1020"]?.presetId == "local_12")
        #expect(try decode([String: PrinterSlotPreset].self, "{}").isEmpty)
        let d = try decode(PrinterSpoolDefaults.self, #"{"slicer_filament":"GFSA21","slicer_filament_name":"Bambu PLA Basic @BBL H2D 0.2 nozzle","cali_idx":16,"k_value":0.018,"profile_name":"PLA left","extruder":1,"nozzle_diameter":"0.2"}"#)
        #expect(d.caliIdx == 16)
        let empty = try decode(PrinterSpoolDefaults.self, #"{"slicer_filament":null,"slicer_filament_name":null,"cali_idx":null,"k_value":null,"profile_name":null,"extruder":0,"nozzle_diameter":"0.4"}"#)
        #expect(empty.slicerFilament == nil)
        let colors = try decode([PrinterColorCatalogEntry].self, ##"[{"id":631,"manufacturer":"3DXTECH","color_name":"Natural","hex_color":"#DED7C6","material":"ASA","is_default":true,"extra_colors":null,"effect_type":null}]"##)
        #expect(colors.first?.hexColor == "#DED7C6")
    }

    @Test func presetNameParsing() {
        let a = PrinterFilamentLogic.parse("Bambu PLA Matte @BBL X1C")
        #expect(a.material == "PLA" && a.brand == "Bambu" && a.variant == "Matte")
        let b = PrinterFilamentLogic.parse("PLA Support for PETG PETG Basic @BBL X1C")
        #expect(b.material == "PETG" && b.variant == "Support")
        let c = PrinterFilamentLogic.parse("Generic Foo")
        #expect(c.material == "Foo" && c.brand == "Generic")
        #expect(PrinterFilamentLogic.stripSuffix("INLAND PLA Pro @Bambu Lab P1S 0.4 nozzle") == "INLAND PLA Pro")
    }

    @Test func presetIdConversions() {
        #expect(PrinterFilamentLogic.convertToTrayInfoIdx("GFSL05_09") == "GFL05")
        #expect(PrinterFilamentLogic.convertToTrayInfoIdx("PFUScd84f663d2c2ef") == "PFUScd84f663d2c2ef")
        #expect(PrinterFilamentLogic.toFilamentId("GFSA00_02") == "GFA00")
        #expect(PrinterFilamentLogic.genericId(for: "PLA") == "GFL99")
        #expect(PrinterFilamentLogic.genericId(for: "PETG-CF") == "GFG98")
        #expect(PrinterFilamentLogic.genericId(for: "ABS+") == "GFB99")
        #expect(PrinterFilamentLogic.genericId(for: "UNOBTAINIUM") == "")
        #expect(PrinterFilamentLogic.defaultTemps(for: "PETG") == (220, 260))
        #expect(PrinterFilamentLogic.defaultTemps(for: "PC") == (260, 300))
        #expect(PrinterFilamentLogic.modelCode("C11") == "P1S")
        #expect(PrinterFilamentLogic.modelCode("X1C") == "X1C")
    }

    @Test func presetModelMatching() {
        let map = ["Bambu Lab X1 Carbon": "X1C", "Bambu Lab P1S": "P1S", "Bambu Lab A1 mini": "A1 Mini", "Bambu Lab A1": "A1"]
        #expect(PrinterFilamentLogic.presetModel("Bambu ABS @BBL A1 0.2 nozzle", longToShort: map) == "A1")
        #expect(PrinterFilamentLogic.presetModel("INLAND PLA Pro @Bambu Lab P1S 0.4 nozzle", longToShort: map) == "P1S")
        #expect(PrinterFilamentLogic.presetModel("X1C eSUN PETG-Basic", longToShort: map) == "X1C")
        #expect(PrinterFilamentLogic.presetModel("Plain PLA", longToShort: map) == nil)
        #expect(PrinterFilamentLogic.modelsMatch("A1M", "A1 Mini"))
        #expect(!PrinterFilamentLogic.modelsMatch("A1", "P1S"))
    }

    @Test @MainActor func catalogChoicesFilterAndOrder() {
        let catalog = { () -> [PrinterFilamentChoice] in
            let c = PrinterFilamentCatalog()
            c.longToShort = ["Bambu Lab P1S": "P1S", "Bambu Lab A1": "A1"]
            c.cloud = [
                PrinterCloudSetting(settingId: "GFSA00_01", name: "Bambu PLA Basic @BBL P1S"),
                PrinterCloudSetting(settingId: "GFSB00_07", name: "Bambu ABS @BBL A1"),
                PrinterCloudSetting(settingId: "PFUS1", name: "My PLA @Bambu Lab P1S 0.4 nozzle"),
            ]
            c.builtin = [PrinterBuiltinFilament(filamentId: "GFA00", name: "Bambu PLA Basic"), PrinterBuiltinFilament(filamentId: "GFG00", name: "Bambu PETG Basic")]
            return c.choices(printerModel: "P1S", nozzle: "0.4")
        }()
        #expect(catalog.map(\.id) == ["PFUS1", "GFSA00_01", "builtin_GFG00"])
        let pfus = catalog[0]
        #expect(pfus.isUserPreset)
        #expect(pfus.baseIdentifiers.trayInfoIdx == "PFUS1")
        let basic = catalog[1]
        #expect(basic.baseIdentifiers == ("GFA00", "GFSA00_01"))
        #expect(basic.subBrands == "Bambu PLA Basic")
        #expect(basic.trayType == "PLA")
        #expect(basic.tempRange == (190, 230))
        #expect(catalog[2].baseIdentifiers == ("GFG00", ""))
    }

    @Test func kProfileMatchingForPreset() {
        let profiles = [
            PrinterKProfile(slotId: 1, extruderId: 0, nozzleId: "HS00-0.4", nozzleDiameter: "0.4", filamentId: "GFA00", name: "Bambu PLA Basic", kValue: "0.02"),
            PrinterKProfile(slotId: 2, extruderId: 0, nozzleId: "HS00-0.4", nozzleDiameter: "0.4", filamentId: "GFG99", name: "Generic PETG", kValue: "0.04"),
            PrinterKProfile(slotId: 3, extruderId: 1, nozzleId: "HS00-0.4", nozzleDiameter: "0.4", filamentId: "GFA00", name: "Bambu PLA Basic L", kValue: "0.02"),
        ]
        let preset = PrinterFilamentChoice(id: "GFSA00_01", name: "Bambu PLA Basic @BBL X1C", source: .cloud, rawId: "GFSA00_01")
        let m = PrinterFilamentLogic.matchingProfiles(profiles, preset: preset, activeCaliIdx: nil, extruder: 0)
        #expect(m.map(\.slotId) == [1])
        let active = PrinterFilamentLogic.matchingProfiles(profiles, preset: nil, activeCaliIdx: 2, extruder: 0)
        #expect(active.map(\.slotId) == [2])
    }

    // MARK: More tools

    @Test func historyDecode() throws {
        let ams = try decode(PrinterAMSHistory.self, #"{"printer_id":1,"ams_id":0,"data":[{"recorded_at":"2026-09-26T19:01:37","humidity":36.0,"humidity_raw":36.0,"temperature":27.3},{"recorded_at":"2026-09-26T19:06:37.123456","humidity":null,"humidity_raw":null,"temperature":null}],"min_humidity":36.0,"max_humidity":36.0,"avg_humidity":null,"min_temperature":null,"max_temperature":null,"avg_temperature":null}"#)
        #expect(ams.data.count == 2)
        #expect(ams.data[0].date != nil && ams.data[1].date != nil)
        let sensors = try decode(PrinterSensorHistory.self, #"{"printer_id":1,"series":[{"sensor_kind":"bed","data":[{"recorded_at":"2026-09-26T18:59:40","value":54.875,"target":55.0}],"min_value":54.8,"max_value":55.0,"avg_value":54.9},{"sensor_kind":"chamber","data":[],"min_value":null,"max_value":null,"avg_value":null}]}"#)
        #expect(sensors.series[0].label == "Bed")
        #expect(sensors.series[1].data.isEmpty)
    }

    @Test func firmwareDecode() throws {
        let info = try decode(PrinterFirmwareInfo.self, ##"{"printer_id":1,"printer_name":"Office Printer","model":"P1S","current_version":"01.09.01.00","latest_version":"01.10.00.00","update_available":true,"download_url":"https://x/y.zip","release_notes":"# Notes","available_versions":[{"version":"01.10.00.00","file_available":true,"download_url":null,"release_notes":null,"release_time":"2026-03-30T09:07:48"}]}"##)
        #expect(info.updateAvailable)
        #expect(info.availableVersions?.first?.fileAvailable == true)
        let offline = try decode(PrinterFirmwareInfo.self, #"{"printer_id":1,"printer_name":"P","model":"Unknown","current_version":null,"latest_version":null,"update_available":false}"#)
        #expect(offline.availableVersions == nil)
        let prep = try decode(PrinterFirmwarePrepare.self, #"{"can_proceed":true,"sd_card_present":true,"sd_card_free_space":-1,"firmware_size":104857600,"space_sufficient":true,"update_available":true,"current_version":"01.09.01.00","latest_version":"01.10.00.00","target_version":null,"firmware_filename":"a.zip","errors":[]}"#)
        #expect(prep.sdCardFreeSpace == -1)
        let st = try decode(PrinterFirmwareUploadStatus.self, #"{"status":"uploading","progress":42,"message":"Uploading","error":null,"firmware_filename":null,"firmware_version":"01.10.00.00"}"#)
        #expect(st.isActive)
        #expect(try decode(PrinterFirmwareUploadStart.self, #"{"started":false,"message":"Firmware upload already in progress"}"#).started == false)
    }

    @Test func loggingDecode() throws {
        let logs = try decode(PrinterMQTTLogs.self, #"{"logging_enabled":true,"logs":[{"timestamp":"2026-09-26T19:00:00+00:00","topic":"device/X/report","direction":"in","payload":{"print":{"command":"push_status","nozzle_temper":210.5}}},{"timestamp":"2026-09-26T19:00:01+00:00","topic":"device/X/request","direction":"out","payload":{"pushing":{"command":"pushall"}}}]}"#)
        #expect(logs.logs.count == 2)
        #expect(logs.logs[0].summary == "print.push_status")
        #expect(logs.logs[1].isOutgoing)
        // Payload keys stay snake_case.
        #expect(logs.logs[0].payload["print"]?["nozzle_temper"]?.doubleValue == 210.5)
        #expect(try decode(PrinterMQTTLogs.self, #"{"logging_enabled":false,"logs":[]}"#).logs.isEmpty)
    }

    @Test func diagnosticsDecode() throws {
        let report = try decode(PrinterDiagnosticReport.self, #"{"printer_id":1,"ip_address":"192.168.1.50","overall":"warnings","checks":[{"id":"port_mqtt","status":"pass","params":{}},{"id":"port_rtsps","status":"warn","params":{"port":322,"protocol":"RTSPS"}},{"id":"subnet","status":"warn","params":{"printer_ip":"10.0.0.2","host_ip":"192.168.1.5"}},{"id":"mqtt_auth","status":"fail","params":{"reason":"auth_rejected"}},{"id":"developer_mode","status":"skip"}]}"#)
        #expect(report.checks.count == 5)
        #expect(report.checks[1].param("port") == "322")
        #expect(report.checks[2].param("printer_ip") == "10.0.0.2")
        #expect(report.checks[3].reason == "auth_rejected")
        #expect(PrinterDiagnosticText.title(report.checks[1]) == "Camera (RTSPS port 322)")
        let cam = try decode(PrinterCameraDiagnosis.self, #"{"printer_id":1,"protocol":"rtsp","port":322,"profile":"default","overall_status":"failed","summary_code":"camera_port_closed","stages":[{"name":"tcp_reachable","status":"failed","duration_ms":3001,"code":"tcp_timeout"},{"name":"first_frame","status":"skipped","duration_ms":0,"code":null}]}"#)
        #expect(cam.protocol_ == "rtsp")
        #expect(cam.stages.count == 2)
        let status = try decode(PrinterCameraStatus.self, #"{"active":true,"has_frames":true,"seconds_since_frame":0.179,"stream_uptime":421.8,"stalled":false}"#)
        #expect(status.stalled == false)
        #expect(try decode(PrinterCameraTest.self, #"{"success":false,"error":"Failed to capture frame"}"#).error != nil)
        let runtime = try decode(PrinterRuntimeDebug.self, #"{"printer_name":"Office Printer","runtime_seconds":2881,"runtime_hours":0.8,"print_hours_offset":0.0,"total_hours":0.8,"last_runtime_update":"2026-09-26T19:47:22.895311","mqtt_state":{"connected":true,"state":"RUNNING","progress":37.0,"gcode_file":"Toy.3mf"},"is_active":true}"#)
        #expect(runtime.mqttState?.state == "RUNNING")
        #expect(try decode(PrinterRuntimeDebug.self, #"{"printer_name":"P","runtime_seconds":null,"runtime_hours":0,"print_hours_offset":null,"total_hours":0,"last_runtime_update":null,"mqtt_state":null,"is_active":false}"#).mqttState == nil)
    }

    @Test func smartPlugDecode() throws {
        let none = try decode(PrinterSmartPlug?.self, "null")
        #expect(none == nil)
        let plug = try decode(PrinterSmartPlug.self, #"{"name":"P1S Plug","plug_type":"tasmota","ip_address":"192.168.1.20","username":null,"password":"secret","ha_entity_id":null,"mqtt_power_multiplier":1.0,"printer_id":1,"controls_printer_power":true,"enabled":true,"auto_on":true,"auto_off":false,"auto_off_persistent":false,"off_delay_mode":"time","off_delay_minutes":5,"off_temp_threshold":70,"auto_off_after_drying":false,"off_delay_after_drying_minutes":0,"power_alert_enabled":false,"power_alert_high":null,"power_alert_low":null,"schedule_enabled":false,"schedule_on_time":null,"schedule_off_time":null,"show_in_switchbar":false,"show_on_printer_card":true,"id":4,"last_state":"ON","last_checked":"2026-09-26T19:00:00.123456","auto_off_executed":false,"power_alert_last_triggered":null,"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}"#)
        #expect(plug.id == 4 && plug.typeLabel == "Tasmota")
        let script = try decode(PrinterSmartPlug.self, #"{"id":9,"name":"Vent","plug_type":"homeassistant","ha_entity_id":"script.vent_on"}"#)
        #expect(script.isScript)
        let status = try decode(PrinterPlugStatus.self, #"{"state":"ON","reachable":true,"device_name":"Tasmota","energy":{"power":142.3,"voltage":229.0,"current":0.62,"today":1.23,"yesterday":2.1,"total":150.4,"factor":0.95,"apparent_power":150.0,"reactive_power":40.0}}"#)
        #expect(status.isOn && status.energy?.power == 142.3)
        #expect(try decode(PrinterPlugStatus.self, #"{"state":null,"reachable":false,"device_name":null,"energy":null}"#).isOn == false)
        let sensors = try decode([PrinterHASensorReading].self, #"[{"id":1,"name":"Enclosure","entity_id":"sensor.enclosure_temp","kind":"numeric","device_class":"temperature","unit":"°C","state":"31.5","value":31.5,"alerting":false,"block_print":false,"reachable":true,"last_changed":null},{"id":2,"name":"Door","entity_id":"binary_sensor.door","kind":"binary","device_class":"door","unit":null,"state":"on","value":null,"alerting":true,"block_print":true,"reachable":true,"last_changed":"2026-09-26T19:00:00Z"}]"#)
        #expect(sensors[0].displayValue == "31.5 °C")
        #expect(sensors[1].displayValue == "Open")
    }

    @Test func scheduledDryingDecodeAndEncode() throws {
        let items = try decode([PrinterScheduledDrying].self, #"[{"id":3,"printer_id":1,"ams_id":0,"temp":55,"duration_hours":8,"filament":"PLA","rotate_tray":false,"start_after":"2026-09-27T02:00:00Z","status":"pending","waiting_reason":"printer_busy","error_message":null,"created_at":"2026-09-26T19:00:00Z","started_at":null,"completed_at":null},{"id":4,"printer_id":1,"ams_id":128,"temp":65,"duration_hours":4,"filament":"","rotate_tray":true,"start_after":null,"status":"failed","waiting_reason":null,"error_message":"AMS not found","created_at":null,"started_at":null,"completed_at":null}]"#)
        #expect(items[0].waitingText?.contains("finish printing") == true)
        #expect(items[1].startAfter == nil)
        let body = PrinterScheduledDryingCreate(printerId: 1, amsId: 0, temp: 55, durationHours: 8, filament: "PLA", rotateTray: false, startAfter: nil)
        let v = try JSONValue.from(body)
        #expect(v["start_after"]?.isNull == true)
        #expect(v["duration_hours"]?.intValue == 8)
    }

    @Test func plateDetectionDecode() throws {
        let check = try decode(PrinterPlateCheck.self, #"{"is_empty":true,"confidence":0.95,"difference_percent":0.5,"message":"Plate appears empty","has_debug_image":false,"needs_calibration":false,"light_warning":false,"reference_count":1,"max_references":5,"roi":{"x":0.15,"y":0.35,"w":0.7,"h":0.55}}"#)
        #expect(check.isEmpty && check.roi?.w == 0.7)
        #expect(check.debugImage == nil)
        let status = try decode(PrinterPlateStatus.self, #"{"available":true,"calibrated":false,"reference_count":0,"max_references":5,"message":"Not calibrated - please calibrate with empty plate","chamber_light":true}"#)
        #expect(status.calibrated == false)
        let unavailable = try decode(PrinterPlateStatus.self, #"{"available":false,"calibrated":false,"plate_type":null,"chamber_light":false,"message":"OpenCV missing"}"#)
        #expect(unavailable.available == false)
        let refs = try decode(PrinterPlateReferences.self, #"{"references":[{"index":0,"label":"Textured PEI","timestamp":"2026-09-26T14:00:00.123456","has_image":true,"thumbnail_url":"/api/v1/printers/1/camera/plate-detection/references/0/thumbnail"}],"max_references":5}"#)
        #expect(refs.references.first?.label == "Textured PEI")
        #expect(try decode(PrinterPlateCalibrateResult.self, #"{"success":false,"message":"No frame","index":-1}"#).index == -1)
        let roi = try JSONValue.from(PrinterPlateROI.default)
        #expect(roi["w"]?.doubleValue == 0.7)
    }

    @Test func obicoAndPrintUserDecode() throws {
        let off = try decode(PrinterObicoStatus.self, #"{"enabled":false,"monitored_printers":null,"per_printer":{},"last_error":null}"#)
        #expect(!off.monitors(1))
        let on = try decode(PrinterObicoStatus.self, #"{"enabled":true,"monitored_printers":[2],"per_printer":{"2":{"class":"warning","frame_count":1,"score":0.52,"error":null}},"last_error":null}"#)
        #expect(on.monitors(2) && !on.monitors(1))
        #expect(on.perPrinter?["2"]?.class == "warning")
        #expect(try decode(PrinterCurrentUser.self, "{}").username == nil)
        #expect(try decode(PrinterCurrentUser.self, #"{"user_id":3,"username":"alice"}"#).username == "alice")
    }
}
