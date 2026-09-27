import Testing
import Foundation
@testable import Bambuddy

struct InventoryTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: Spools

    static let localSpoolJSON = #"""
    {
      "material": "PLA", "subtype": "Basic", "color_name": "Jade White", "rgba": "FFFFFFFF",
      "extra_colors": "ec984c,6cd4bc", "effect_type": "silk", "brand": "Bambu",
      "label_weight": 1000, "core_weight": 250, "core_weight_catalog_id": 12,
      "weight_used": 312.5, "weight_used_baseline": 12.5,
      "slicer_filament": "GFA00", "slicer_filament_name": "Bambu PLA Basic",
      "nozzle_temp_min": 190, "nozzle_temp_max": 230, "note": "Lamp project",
      "tag_uid": "A1B2C3D4", "tray_uuid": "0123456789ABCDEF0123456789ABCDEF",
      "data_origin": "rfid", "tag_type": "bambulab", "cost_per_kg": 24.99,
      "weight_locked": false, "last_scale_weight": 912, "last_weighed_at": "2026-09-20T10:00:00",
      "category": "Stock", "low_stock_threshold_pct": 15, "storage_location": "Dry Box 1", "location_id": 3,
      "id": 7, "added_full": true, "last_used": "2026-09-21T08:15:00.123456",
      "encode_time": null, "archived_at": null,
      "created_at": "2026-06-10T09:00:00", "updated_at": "2026-09-21T08:15:00",
      "k_profiles": [
        {"printer_id": 1, "extruder": 0, "nozzle_diameter": "0.4", "nozzle_type": null, "k_value": 0.02,
         "name": "Bambu PLA Basic", "cali_idx": 3, "setting_id": null, "id": 4, "spool_id": 7,
         "created_at": "2026-07-01T00:00:00"}
      ]
    }
    """#

    @Test func decodesLocalSpool() throws {
        let s = try decode(InventorySpool.self, Self.localSpoolJSON)
        #expect(s.id == 7)
        #expect(s.remainingGrams == 687.5)
        #expect(s.consumedGrams == 300)
        #expect(s.grossGrams == 937.5)
        #expect(s.kProfiles?.first?.kValue == 0.02)
        #expect(s.extraColorStops == ["ec984c", "6cd4bc"])
        #expect(s.isLowStock(globalThreshold: 20) == false)
        #expect(s.hasSlicerPreset)
        #expect(s.matches(search: "jade"))
        #expect(s.matches(search: "dry box"))
        #expect(!s.matches(search: "petg"))
    }

    @Test func decodesSpoolmanMappedSpool() throws {
        // Shape produced by `_map_spoolman_spool`: null timestamps, synthesized color name.
        let json = #"""
        [{"id": 42, "material": "PETG", "subtype": "HF", "color_name": "HF", "color_name_is_synthesized": true,
          "rgba": "0A2CA5FF", "extra_colors": null, "effect_type": null, "brand": null, "label_weight": 1000,
          "core_weight": 250, "core_weight_catalog_id": null, "weight_used": 905.0, "weight_used_baseline": 0.0,
          "weight_locked": false, "last_scale_weight": null, "last_weighed_at": null, "slicer_filament": null,
          "slicer_filament_name": "PETG HF", "nozzle_temp_min": null, "nozzle_temp_max": null, "note": null,
          "added_full": null, "last_used": null, "encode_time": null, "tag_uid": null, "tray_uuid": null,
          "data_origin": "spoolman", "tag_type": "spoolman", "archived_at": null, "created_at": null,
          "updated_at": null, "cost_per_kg": null, "storage_location": null, "location_id": null, "k_profiles": []}]
        """#
        let spools = try decode([InventorySpool].self, json)
        #expect(spools.count == 1)
        #expect(spools[0].createdAt == nil)
        #expect(spools[0].remainingPercent.rounded() == 10)
        #expect(spools[0].isLowStock(globalThreshold: 20))
    }

    @Test func minimalSpoolDecodes() throws {
        let s = try decode(InventorySpool.self, #"{"id": 1, "material": "PLA", "created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00"}"#)
        #expect(s.remainingGrams == 0)
        #expect(s.remainingPercent == 0)
        #expect(s.materialLine == "PLA")
    }

    // MARK: Assignments & usage

    @Test func decodesAssignmentsWithNestedSpool() throws {
        let json = """
        [{"id": 3, "spool_id": 7, "printer_id": 1, "printer_name": "X1C", "ams_id": 0, "tray_id": 2,
          "fingerprint_color": "FFFFFFFF", "fingerprint_type": "PLA", "created_at": "2026-09-01T12:00:00",
          "spool": \(Self.localSpoolJSON), "configured": true, "pending_config": false, "ams_label": null},
         {"id": 4, "spool_id": 8, "printer_id": 2, "printer_name": null, "ams_id": 255, "tray_id": 0,
          "fingerprint_color": null, "fingerprint_type": null, "created_at": "2026-09-01T12:00:00",
          "spool": null, "configured": false, "pending_config": true, "ams_label": "Left"}]
        """
        let list = try decode([InventorySpoolAssignment].self, json)
        #expect(list.count == 2)
        #expect(list[0].spool?.id == 7)
        #expect(list[1].pendingConfig == true)
        let slot = InventorySlotLocation(printerId: 1, printerName: "X1C", amsId: 0, trayId: 2)
        #expect(slot.slotLabel == "A3")
        #expect(InventorySlotLocation(printerId: 1, amsId: 128, trayId: 0).slotLabel == "HT-A")
        #expect(InventorySlotLocation(printerId: 1, amsId: 255, trayId: 0).slotLabel == "Ext")
    }

    @Test func decodesSpoolmanSlotAssignments() throws {
        let json = #"[{"printer_id": 1, "printer_name": "P1S", "ams_id": 1, "tray_id": 3, "spoolman_spool_id": 42, "ams_label": null}]"#
        let list = try decode([InventorySpoolmanSlotAssignment].self, json)
        #expect(list[0].spoolmanSpoolId == 42)
    }

    @Test func decodesUsageHistory() throws {
        let json = #"""
        [{"id": 1, "spool_id": 7, "printer_id": 1, "print_name": "Benchy", "weight_used": 12.4, "percent_used": 1,
          "status": "completed", "cost": 0.31, "created_at": "2026-09-20T10:00:00"},
         {"id": 2, "spool_id": 7, "printer_id": null, "print_name": null, "weight_used": 3, "percent_used": 0,
          "status": "failed", "cost": null, "created_at": "2026-09-21T10:00:00"}]
        """#
        let list = try decode([InventoryUsageRecord].self, json)
        #expect(list.count == 2)
        #expect(list[1].printerId == nil)
    }

    // MARK: Catalogs

    @Test func decodesCatalogs() throws {
        let catalog = try decode([InventorySpoolCatalogEntry].self, #"[{"id":1,"name":"3D FilaPrint - Cardboard","weight":210,"is_default":true}]"#)
        #expect(catalog[0].weight == 210)
        let colors = try decode([InventoryColorEntry].self, #"""
        [{"id":631,"manufacturer":"3DXTECH","color_name":"Natural","hex_color":"#DED7C6","material":"ASA","is_default":true,"extra_colors":null,"effect_type":null},
         {"id":632,"manufacturer":"Generic","color_name":"Rainbow","hex_color":"#FF0000","material":null,"is_default":false,"extra_colors":"00FF00,0000FF","effect_type":"silk"}]
        """#)
        #expect(colors[1].material == nil)
        #expect(InventoryColors.normalizedRGBA(colors[0].hexColor) == "DED7C6FF")
        let locations = try decode([InventoryLocation].self, #"[{"id":1,"name":"Dry Box","identifier":null,"spool_count":3,"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}]"#)
        #expect(locations[0].spoolCount == 3)
        let filaments = try decode([InventoryFilamentType].self, #"""
        [{"name":"PLA Basic","type":"PLA","brand":"Bambu","color":"White","color_hex":"#FFFFFF","cost_per_kg":25.0,
          "spool_weight_g":1000.0,"currency":"USD","density":1.24,"print_temp_min":190,"print_temp_max":230,
          "bed_temp_min":null,"bed_temp_max":null,"id":1,"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}]
        """#)
        #expect(filaments[0].density == 1.24)
        let cost = try decode(InventoryFilamentCost.self, #"{"filament_id":1,"filament_name":"PLA Basic","weight_grams":100,"cost":2.5,"currency":"USD"}"#)
        #expect(cost.cost == 2.5)
    }

    // MARK: Forecast

    @Test func decodesForecastModels() throws {
        let sku = try decode([InventorySkuSettings].self, #"[{"id":1,"material":"PLA","subtype":null,"brand":"Bambu","color_name":null,"lead_time_days":7,"safety_margin_value":14,"safety_margin_unit":"days","alerts_snoozed":false}]"#)
        #expect(sku[0].leadTimeDays == 7)
        let items = try decode([InventoryShoppingItem].self, #"[{"id":1,"material":"PLA","subtype":"Basic","brand":"Bambu","color_name":"Black","quantity_spools":2,"note":null,"status":"pending","purchased_at":null,"added_at":"2026-09-20T10:00:00"}]"#)
        #expect(items[0].label == "Bambu PLA Basic Black")
    }

    @Test func forecastUsesHistoryRate() {
        let now = Date()
        func day(_ offset: Int) -> String {
            ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(-offset) * 86400))
        }
        let spool = InventorySpool(id: 1, material: "PLA", brand: "Bambu", labelWeight: 1000, weightUsed: 300, weightUsedBaseline: 0, createdAt: day(60))
        let records = [
            InventoryUsageRecord(id: 1, spoolId: 1, weightUsed: 100, createdAt: day(20)),
            InventoryUsageRecord(id: 2, spoolId: 1, weightUsed: 100, createdAt: day(10)),
            InventoryUsageRecord(id: 3, spoolId: 1, weightUsed: 100, createdAt: day(0)),
        ]
        let forecasts = InventoryForecastEngine.forecasts(spools: [spool], usage: records, skuSettings: [], globalLeadTime: 7, now: now)
        #expect(forecasts.count == 1)
        let f = forecasts[0]
        #expect(f.rateTier == .history)
        #expect(abs((f.dailyRate ?? 0) - 10) < 0.01)
        #expect(f.daysRemaining == 70)
        #expect(f.remaining == 700)
    }

    @Test func forecastFallsBackToDeltaRate() {
        let created = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-10 * 86400))
        let spool = InventorySpool(id: 1, material: "PETG", labelWeight: 1000, weightUsed: 900, weightUsedBaseline: 0, createdAt: created)
        let f = InventoryForecastEngine.forecasts(spools: [spool], usage: [], skuSettings: [], globalLeadTime: 14)[0]
        #expect(f.rateTier == .delta)
        #expect(abs((f.dailyRate ?? 0) - 90) < 0.5)
        #expect(f.stockBreakAlert)
    }

    // MARK: Import & bulk

    @Test func decodesImportPreviewAndResult() throws {
        let preview = try decode(InventoryImportResponse.self, #"""
        {"columns":["material","brand","color_name"],"total":2,"valid_count":1,"error_count":1,"skipped_count":0,
         "rows":[{"row_number":2,"status":"valid","reason":null,"material":"PLA","brand":"Bambu","color_name":"Black","rgba":"000000FF",
                  "resolved_color":true,"cross_material_color":false,"duplicate_of_existing":false,"spool":{"material":"PLA","label_weight":1000}},
                 {"row_number":3,"status":"error","reason":"material is required","material":null,"brand":null,"color_name":null,"rgba":null,"spool":null}],
         "warnings":["Unknown column: foo"]}
        """#)
        #expect(preview.rows?.count == 2)
        #expect(preview.rows?[0].spool?["label_weight"]?.intValue == 1000)
        let result = try decode(InventoryImportResponse.self, #"{"created":1,"skipped":0,"errors":1,"error_rows":[{"row_number":3,"status":"error","reason":"bad"}]}"#)
        #expect(result.created == 1)
        #expect(result.errorRows?.first?.reason == "bad")
    }

    @Test func decodesBulkResults() throws {
        let local = try decode(InventoryBulkResult.self, #"{"archived":2,"already_archived":[5],"not_found":[9]}"#)
        #expect(local.succeeded == 2)
        #expect(local.failedCount == 1)
        let spoolman = try decode(InventoryBulkResult.self, #"{"updated":1,"errors":[{"id":4,"status":404,"detail":"Not found"}]}"#)
        #expect(spoolman.failedCount == 1)
        let reset = try decode(InventoryBulkResult.self, #"{"reset":3}"#)
        #expect(reset.succeeded == 3)
    }

    // MARK: Spoolman

    @Test func decodesSpoolmanModels() throws {
        let settings = try decode(InventorySpoolmanSettings.self, #"{"spoolman_enabled":"true","spoolman_url":"http://spoolman:7912","spoolman_sync_mode":"auto","spoolman_disable_weight_sync":"false","spoolman_report_partial_usage":"true","auto_add_unknown_rfid":"true"}"#)
        #expect(settings.isActive)
        let off = try decode(InventorySpoolmanSettings.self, #"{"spoolman_enabled":"false","spoolman_url":""}"#)
        #expect(!off.isActive)
        let status = try decode(InventorySpoolmanStatus.self, #"{"enabled":true,"connected":false,"url":null}"#)
        #expect(!status.connected)
        let filaments = try decode([InventorySpoolmanFilament].self, #"[{"id":3,"name":"PLA Matte","material":"PLA","color_hex":"222222","color_name":null,"weight":1000,"spool_weight":null,"vendor":{"id":1,"name":"Bambu"}},{"id":4,"name":"Generic","material":null,"color_hex":null,"color_name":null,"weight":null,"spool_weight":180.5,"vendor":null}]"#)
        #expect(filaments[0].label == "Bambu PLA Matte")
        let sync = try decode(InventorySpoolmanSyncResult.self, #"{"success":true,"synced_count":3,"skipped_count":1,"skipped":[{"location":"A1","reason":"empty"}],"errors":[]}"#)
        #expect(sync.syncedCount == 3)
    }

    // MARK: Presets & K profiles

    @Test func mergesPresetsWithoutDuplicates() throws {
        let cloud = try decode([InventorySlicerSetting].self, #"""
        [{"setting_id":"PFUS62fd","name":"INLAND PLA Pro @Bambu Lab P1S 0.4 nozzle","type":"filament","version":"2.4.0.10","user_id":null,"updated_time":null,"is_custom":true},
         {"setting_id":"GFSB00_07","name":"Bambu ABS @BBL A1","type":"filament","version":"02.08.00.06","user_id":null,"updated_time":null,"is_custom":false},
         {"setting_id":"GFSB00_08","name":"Bambu ABS @BBL A1 0.2 nozzle","type":"filament","is_custom":false}]
        """#)
        let builtin = try decode([InventoryBuiltinFilament].self, #"[{"filament_id":"GFA00","name":"Bambu PLA Basic"},{"filament_id":"GFB00","name":"Bambu ABS"}]"#)
        let local = try decode(InventoryLocalPresets.self, #"{"filament":[{"id":5,"name":"My PETG","preset_type":"filament","source":"orcaslicer","filament_type":"PETG","created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}],"printer":[],"process":[]}"#)
        let options = InventoryPresets.merge(cloud: cloud, local: local.filament ?? [], builtin: builtin)
        #expect(options.filter { $0.name.hasPrefix("Bambu ABS") }.count == 1)
        #expect(options.contains { $0.code == "GFA00" && $0.source == .builtin })
        #expect(options.contains { $0.code == "5" && $0.source == .local })
        let parsed = InventoryPresets.parse("Bambu PLA Matte @BBL X1C")
        #expect(parsed.brand == "Bambu")
        #expect(parsed.material == "PLA")
        #expect(parsed.subtype == "Matte")
    }

    @Test func decodesPrinterKProfiles() throws {
        let r = try decode(InventoryPrinterKProfiles.self, #"{"profiles":[{"slot_id":3,"extruder_id":0,"nozzle_id":"HS00-0.4","nozzle_diameter":"0.4","filament_id":"GFA00","name":"Bambu PLA Basic","k_value":"0.020000","n_coef":"1.400000","ams_id":0,"tray_id":0,"setting_id":null}],"nozzle_diameter":"0.4"}"#)
        #expect(r.profiles[0].kValue == "0.020000")
        let presets = try decode([InventorySpoolFilamentPreset].self, #"[{"printer_model":"X1C","nozzle_diameter":"0.4","slicer_filament":"GFA00","slicer_filament_name":"Bambu PLA Basic","id":1,"spool_id":7,"created_at":"2026-01-01T00:00:00"}]"#)
        #expect(presets[0].printerModel == "X1C")
    }

    // MARK: Encoding

    @Test func labelRequestEncodesSnakeCase() throws {
        let data = try APICoders.encoder.encode(InventoryLabelRequest(spoolIds: [1, 2], template: InventoryLabelTemplate.averyL7160.rawValue, monochrome: true, startingPosition: 4))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json["spool_ids"]?.arrayValue?.count == 2)
        #expect(json["starting_position"]?.intValue == 4)
        #expect(json["template"]?.stringValue == "avery_l7160")
    }

    @Test func patchPayloadKeepsExplicitNulls() throws {
        let payload: JSONValue = ["note": nil, "tag_uid": nil, "weight_used": 12]
        let data = try APICoders.encoder.encode(payload)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"note\":null"))
        #expect(text.contains("\"tag_uid\":null"))
    }

    @Test func colorHelpers() {
        #expect(InventoryColors.isClear("FFFFFF00"))
        #expect(!InventoryColors.isClear("FFFFFFFF"))
        #expect(InventoryColors.normalizedRGBA("#abc123") == "ABC123FF")
        #expect(InventoryColors.normalizedRGBA("zz") == nil)
    }
}
