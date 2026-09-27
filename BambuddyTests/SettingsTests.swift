import Testing
import Foundation
@testable import Bambuddy

/// Core settings infrastructure: the `/settings/` blob store and its request bodies.
@MainActor
struct SettingsStoreTests {
    /// Excerpt of a real `GET /api/v1/settings/` response (v1.2.5.5), including nulls.
    static let settingsJSON = """
    {"auto_archive":true,"save_thumbnails":true,"default_filament_cost":25.0,"currency":"USD",
     "energy_cost_per_kwh":0.15,"energy_tracking_mode":"total","spoolman_enabled":false,"spoolman_url":"",
     "language":"en","bed_cooled_threshold":35.0,"ams_humidity_good":40,"ams_humidity_fair":60,
     "ams_temp_good":28.0,"ams_temp_alarm":null,"drying_presets":"","gcode_snippets":"{\\"X1C\\":{\\"start_gcode\\":\\"M117 hi\\",\\"end_gcode\\":\\"\\"}}",
     "local_backup_time":"03:00","date_format":"system","default_printer_id":null,"pipeline_max_copies":50,
     "ftp_timeout":30,"mqtt_port":1883,"ha_url_from_env":false,"library_disk_warning_gb":5.0,
     "camera_view_mode":"embedded","open_in_slicer":null,"slicer_stall_timeout_minutes":15,
     "default_bed_levelling":"auto","ldap_user_filter":"(sAMAccountName={username})","obico_enabled_printers":"",
     "location_sensor_poll_interval":120,"default_sidebar_order":""}
    """

    private func makeStore() throws -> ServerSettingsStore {
        let raw = try APICoders.decoder.decode(JSONValue.self, from: Data(Self.settingsJSON.utf8))
        let store = ServerSettingsStore()
        store.apply(serverResponse: raw)
        return store
    }

    @Test func decodesSettingsBlobKeepingSnakeCaseKeys() throws {
        let store = try makeStore()
        #expect(store.hasLoaded)
        #expect(store["auto_archive"] == .bool(true))
        #expect(store.bool("auto_archive"))
        #expect(!store.bool("spoolman_enabled", default: true))
        #expect(store.bool("missing_key", default: true))
        #expect(store.string("currency") == "USD")
        #expect(store.int("ams_humidity_good") == 40)
        #expect(store.double("energy_cost_per_kwh") == 0.15)
        #expect(store.double("default_filament_cost") == 25)
        #expect(store.string("local_backup_time") == "03:00")
        #expect(store.string("ldap_user_filter") == "(sAMAccountName={username})")
    }

    @Test func nullableSettingsReadAsNil() throws {
        let store = try makeStore()
        #expect(store.int("default_printer_id") == nil)
        #expect(store.double("ams_temp_alarm") == nil)
        #expect(store.string("open_in_slicer", default: "inherit") == "inherit")
    }

    @Test func literalNoneStringIsTreatedAsUnset() {
        let store = ServerSettingsStore(values: ["open_in_slicer": "None", "default_printer_id": "None"])
        #expect(store.string("open_in_slicer", default: "") == "")
        #expect(store.int("default_printer_id") == nil)
    }

    @Test func parsesJSONStringSettings() throws {
        let store = try makeStore()
        #expect(store.jsonString("drying_presets") == nil)
        let snippets = try #require(store.jsonString("gcode_snippets"))
        #expect(snippets["X1C"]?["start_gcode"]?.stringValue == "M117 hi")
    }

    @Test func stagedEditIsVisibleImmediately() throws {
        let store = try makeStore()
        store.stage("ftp_timeout", .number(60))
        #expect(store.int("ftp_timeout") == 60)
        // A reload that arrives while the edit is queued keeps the pending value.
        store.apply(serverResponse: ["ftp_timeout": 30, "mqtt_port": 8883])
        #expect(store.int("ftp_timeout") == 60)
        #expect(store.int("mqtt_port") == 8883)
    }

    @Test func updateBodyKeepsServerKeys() throws {
        let body: JSONValue = ["default_printer_id": .null, "ams_temp_good": 30.5, "ftp_timeout": 45, "auto_archive": false]
        let data = try APICoders.encoder.encode(body)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["default_printer_id", "ams_temp_good", "ftp_timeout", "auto_archive"])
        #expect(object["default_printer_id"] is NSNull)
        #expect((object["ftp_timeout"] as? NSNumber)?.intValue == 45)
        #expect((object["ams_temp_good"] as? NSNumber)?.doubleValue == 30.5)
        #expect(String(data: data, encoding: .utf8)?.contains("\"ftp_timeout\":45") == true)
    }

    @Test func numberFieldFormatting() {
        #expect(SettingsNumberField.format(nil, integer: true) == "")
        #expect(SettingsNumberField.format(30, integer: true) == "30")
        #expect(SettingsNumberField.format(29.6, integer: true) == "30")
        #expect(SettingsNumberField.format(25, integer: false) == "25")
        #expect(SettingsNumberField.format(0.15, integer: false) == "0.15")
        #expect(SettingsNumberField.format(1234.5, integer: false) == "1234.5")
    }

    @Test func destinationsAreComplete() {
        let listed = Set([SettingsDestination.server, .accountSecurity] + SettingsDestination.serverPages + SettingsDestination.adminPages)
        #expect(listed == Set(SettingsDestination.allCases))
        for page in SettingsDestination.allCases {
            #expect(!page.title.isEmpty)
            #expect(!page.systemImage.isEmpty)
        }
    }
}
