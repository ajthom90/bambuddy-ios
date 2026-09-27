import Testing
import Foundation
@testable import Bambuddy

struct SpoolBuddyTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesDevice() throws {
        let json = #"""
        [{"id":1,"device_id":"sb-a1b2c3","hostname":"spoolbuddy","ip_address":"192.168.1.40",
          "firmware_version":"1.2.0","has_nfc":true,"has_scale":true,"tare_offset":-8123,
          "calibration_factor":0.0023,"nfc_reader_type":"PN5180","nfc_connection":"spi",
          "backend_url":null,"display_brightness":80,"display_blank_timeout":300,"has_backlight":true,
          "last_calibrated_at":"2026-09-01T10:00:00","last_seen":"2026-09-26T18:00:00",
          "pending_command":null,"nfc_ok":true,"scale_ok":false,"uptime_s":3600,
          "update_status":null,"update_message":null,
          "system_stats":{"cpu_temp_c":51.2,"memory":{"percent":42.0,"used_mb":400,"total_mb":950}},
          "online":true,"created_at":"2026-08-01T00:00:00","updated_at":"2026-09-26T18:00:00"},
         {"id":2,"device_id":"sb-min","hostname":"","ip_address":"10.0.0.2","has_nfc":false,"has_scale":true,
          "tare_offset":0,"calibration_factor":1,"nfc_ok":false,"scale_ok":true,"uptime_s":0,
          "created_at":"2026-08-01T00:00:00","updated_at":"2026-08-01T00:00:00"}]
        """#
        let devices = try decode([SpoolBuddyDevice].self, json)
        #expect(devices.count == 2)
        #expect(devices[0].uptimeS == 3600)
        #expect(devices[0].tareOffset == -8123)
        #expect(devices[0].isOnline)
        #expect(devices[0].systemStats?["cpu_temp_c"]?.doubleValue == 51.2)
        #expect(devices[1].isOnline == false)
        #expect(devices[1].displayName == "sb-min")
    }

    @Test func decodesSpoolsAndAssignments() throws {
        let spools = try decode([SpoolBuddySpool].self, #"""
        [{"id":7,"material":"PLA","subtype":"Matte","color_name":"Charcoal","rgba":"333333FF","brand":"Bambu",
          "label_weight":1000,"core_weight":250,"weight_used":400.5,"tag_uid":"04AABBCCDD","tray_uuid":null,
          "data_origin":"nfc_link","tag_type":"generic","last_scale_weight":850,"last_weighed_at":null,
          "storage_location":"Shelf A","note":null,"archived_at":null,"created_at":"2026-09-01T00:00:00",
          "updated_at":"2026-09-01T00:00:00","extra_colors":null},
         {"id":8,"material":"PETG","created_at":"2026-09-01T00:00:00","updated_at":"2026-09-01T00:00:00"}]
        """#)
        #expect(spools[0].title == "Bambu PLA Matte")
        #expect(spools[0].remaining == 599.5)
        #expect(spools[0].hexColor == "333333")
        #expect(spools[0].isTagged)
        #expect(spools[1].remaining == nil)
        #expect(!spools[1].isTagged)

        let a = try decode([SpoolBuddyAssignment].self, #"""
        [{"id":1,"spool_id":7,"printer_id":2,"printer_name":"X1C","ams_id":0,"tray_id":3,
          "fingerprint_color":null,"fingerprint_type":null,"created_at":"2026-09-01T00:00:00",
          "spool":null,"configured":true,"pending_config":false,"ams_label":"AMS-A"}]
        """#)
        #expect(a[0].trayId == 3)

        let slots = try decode([SpoolBuddySpoolmanSlot].self, #"""
        [{"printer_id":2,"printer_name":null,"ams_id":255,"tray_id":0,"spoolman_spool_id":44,"ams_label":null}]
        """#)
        #expect(slots[0].spoolmanSpoolId == 44)
    }

    @Test func decodesSmallResponses() throws {
        #expect(try decode(SpoolBuddySpoolmanSettings.self, #"{"spoolman_enabled":"true","spoolman_url":"http://s:7912"}"#).isActive)
        #expect(!(try decode(SpoolBuddySpoolmanSettings.self, #"{"spoolman_enabled":"true","spoolman_url":""}"#).isActive))
        let u = try decode(SpoolBuddyUpdateCheck.self, #"{"current_version":"1.0","latest_version":null,"update_available":false}"#)
        #expect(u.updateAvailable == false)
        let c = try decode(SpoolBuddyCalibration.self, #"{"tare_offset":12,"calibration_factor":0.5}"#)
        #expect(c.tareOffset == 12)
        let d = try decode(SpoolBuddyDiagnosticResult.self, #"{"diagnostic":"scale","success":true,"output":"ok","exit_code":0}"#)
        #expect(d.exitCode == 0)
        let ack = try decode(SpoolBuddyAck.self, #"{"status":"ok","weight_used":120.5}"#)
        #expect(ack.weightUsed == 120.5)
    }

    @Test func slotLabelsAndTagNormalization() {
        #expect(SpoolBuddyStore.slotLabel(amsId: 0, trayId: 2) == "AMS A · Slot 3")
        #expect(SpoolBuddyStore.slotLabel(amsId: 128, trayId: 0) == "AMS HT A")
        #expect(SpoolBuddyStore.slotLabel(amsId: 255, trayId: 0) == "External")
        #expect(SpoolBuddyStore.normalize("04:aa:bb") == "04AABB")
    }

    @MainActor @Test func liveStateTracksEvents() {
        let state = SpoolBuddyLiveState()
        func send(_ raw: JSONValue) {
            state.handle(LiveEvent(type: raw["type"]?.stringValue ?? "", printerId: nil, data: nil, raw: raw))
        }
        send(["type": "spoolbuddy_weight", "device_id": "d1", "weight_grams": 812.4, "stable": true, "raw_adc": 123456])
        #expect(state.readings["d1"]?.grams == 812.4)
        #expect(state.readings["d1"]?.stable == true)

        send(["type": "spoolbuddy_tag_matched", "device_id": "d1", "tag_uid": "04AA",
              "spool": ["id": 7, "material": "PLA", "label_weight": 1000, "core_weight": 250, "weight_used": 100, "brand": nil]])
        #expect(state.matched["d1"]?.id == 7)
        #expect(state.currentTagIdentifier("d1") == "04AA")

        send(["type": "spoolbuddy_unknown_tag", "device_id": "d1", "tag_uid": nil, "tray_uuid": "ABCDEF"])
        #expect(state.matched["d1"] == nil)
        #expect(state.unknown["d1"]?.identifier == "ABCDEF")

        send(["type": "spoolbuddy_tag_removed", "device_id": "d1"])
        #expect(state.unknown["d1"] == nil)

        send(["type": "spoolbuddy_tag_write_failed", "device_id": "d1", "message": "Tag not writable"])
        #expect(state.writeOutcomes["d1"] == .failed("Tag not writable"))

        let before = state.deviceRevision
        send(["type": "spoolbuddy_offline", "device_id": "d1"])
        #expect(state.deviceRevision == before + 1)
        #expect(state.readings["d1"] == nil)
        #expect(!state.activity.isEmpty)

        // Nested `data` payloads are read too.
        send(["type": "spoolbuddy_weight", "data": ["device_id": "d2", "weight_grams": 5, "stable": false]])
        #expect(state.readings["d2"]?.grams == 5)
    }
}
