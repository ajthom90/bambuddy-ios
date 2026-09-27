import Foundation
import Testing
@testable import Bambuddy

struct SettingsPlugsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func object(_ value: JSONValue) -> [String: JSONValue] { value.objectValue ?? [:] }

    // MARK: Smart plugs

    static let tasmotaPlugJSON = """
    {
      "name": "Workshop X1C", "plug_type": "tasmota", "ip_address": "192.168.1.50",
      "username": "admin", "password": "secret",
      "ha_entity_id": null, "ha_power_entity": null, "ha_energy_today_entity": null, "ha_energy_total_entity": null,
      "mqtt_topic": null, "mqtt_power_topic": null, "mqtt_power_path": null, "mqtt_power_multiplier": 1.0,
      "mqtt_energy_topic": null, "mqtt_energy_path": null, "mqtt_energy_multiplier": 1.0,
      "mqtt_state_topic": null, "mqtt_state_path": null, "mqtt_state_on_value": null, "mqtt_multiplier": 1.0,
      "rest_on_url": null, "rest_on_body": null, "rest_off_url": null, "rest_off_body": null, "rest_method": null,
      "rest_headers": null, "rest_status_url": null, "rest_status_path": null, "rest_status_on_value": null,
      "rest_power_url": null, "rest_power_path": null, "rest_power_multiplier": 1.0,
      "rest_energy_url": null, "rest_energy_path": null, "rest_energy_multiplier": 1.0,
      "rest_energy_total_path": null, "rest_energy_total_multiplier": 1.0,
      "printer_id": 3, "controls_printer_power": true, "enabled": true, "auto_on": true, "auto_off": false,
      "auto_off_persistent": false, "off_delay_mode": "temperature", "off_delay_minutes": 5, "off_temp_threshold": 70,
      "auto_off_after_drying": true, "off_delay_after_drying_minutes": 15,
      "power_alert_enabled": true, "power_alert_high": 250.5, "power_alert_low": null,
      "schedule_enabled": true, "schedule_on_time": "08:00", "schedule_off_time": null,
      "show_in_switchbar": false, "show_on_printer_card": true,
      "id": 7, "last_state": "ON", "last_checked": "2026-09-20T10:15:30.123456", "auto_off_executed": false,
      "power_alert_last_triggered": null, "created_at": "2026-01-01T00:00:00", "updated_at": "2026-09-20T10:15:30"
    }
    """

    @Test func decodesTasmotaPlug() throws {
        let plug = try decode(SettingsSmartPlug.self, Self.tasmotaPlugJSON)
        #expect(plug.id == 7)
        #expect(plug.type == .tasmota)
        #expect(plug.ipAddress == "192.168.1.50")
        #expect(plug.offDelayMode == "temperature")
        #expect(plug.offDelayAfterDryingMinutes == 15)
        #expect(plug.powerAlertHigh == 250.5)
        #expect(plug.powerAlertLow == nil)
        #expect(plug.scheduleOnTime == "08:00")
        #expect(plug.subtitle == "192.168.1.50")
        #expect(plug.controlsPrinterPower == true)
    }

    @Test func decodesMinimalMQTTAndRESTPlugs() throws {
        let plugs = try decode([SettingsSmartPlug].self, """
        [
          {"id": 1, "name": "Shelly", "plug_type": "mqtt", "mqtt_topic": "legacy/topic", "mqtt_power_topic": null,
           "mqtt_power_multiplier": 0.001, "enabled": true, "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z"},
          {"id": 2, "name": "openHAB", "plug_type": "rest", "rest_on_url": "", "rest_off_url": "http://oh/off",
           "rest_method": "PUT", "rest_headers": "{\\"X\\": \\"1\\"}", "enabled": false,
           "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z"}
        ]
        """)
        #expect(plugs[0].type == .mqtt)
        #expect(plugs[0].subtitle == "legacy/topic")
        #expect(plugs[1].subtitle == "http://oh/off")
        #expect(plugs[1].isEnabled == false)
        let draft = SettingsSmartPlugDraft(plug: plugs[0])
        #expect(draft.mqttPowerTopic == "legacy/topic")
        #expect(draft.mqttPowerMultiplier == "0.001")
    }

    @Test func decodesStatusesAndDiscovery() throws {
        let status = try decode(SettingsSmartPlugStatus.self, """
        {"state": "ON", "reachable": true, "device_name": "Tasmota",
         "energy": {"power": 123.4, "voltage": 230, "current": 0.5, "today": 1.234, "yesterday": 2.5, "total": 100.0,
                    "factor": 0.9, "apparent_power": 130, "reactive_power": null}}
        """)
        #expect(status.isOn)
        #expect(status.energy?.apparentPower == 130)
        let offline = try decode(SettingsSmartPlugStatus.self, #"{"state": null, "reachable": false, "device_name": null, "energy": null}"#)
        #expect(offline.energy == nil)
        #expect(!offline.isOn)

        let test = try decode(SettingsSmartPlugTestResult.self, #"{"success": true, "state": "OFF", "device_name": null}"#)
        #expect(test.state == "OFF")
        let ha = try decode(SettingsHATestResult.self, #"{"success": false, "message": null, "error": "401 Unauthorized"}"#)
        #expect(ha.error == "401 Unauthorized")
        let rest = try decode(SettingsSmartPlugRESTTestResult.self, #"{"success": true, "error": null}"#)
        #expect(rest.success)
        let scan = try decode(SettingsTasmotaScanStatus.self, #"{"running": true, "scanned": 12, "total": 254}"#)
        #expect(scan.total == 254)
        let devices = try decode([SettingsTasmotaDevice].self, """
        [{"ip_address": "192.168.1.60", "name": "Plug 2", "module": 18, "state": "OFF", "discovered_at": "2026-09-20T10:00:00"},
         {"ip_address": "192.168.1.61", "name": "Plug 3", "module": null, "state": null, "discovered_at": null}]
        """)
        #expect(devices.map(\.id) == ["192.168.1.60", "192.168.1.61"])
        let entities = try decode([SettingsHAEntity].self, """
        [{"entity_id": "switch.printer", "friendly_name": "Printer", "state": "on", "domain": "switch"}]
        """)
        #expect(entities.first?.entityId == "switch.printer")
        let sensors = try decode([SettingsHASensorEntity].self, """
        [{"entity_id": "sensor.printer_power", "friendly_name": "Printer Power", "state": "120", "unit_of_measurement": "W"},
         {"entity_id": "sensor.x", "friendly_name": "X", "state": null, "unit_of_measurement": null}]
        """)
        #expect(sensors[0].unitOfMeasurement == "W")
        #expect(SettingsHASensorEntity.powerUnits.contains(sensors[0].unitOfMeasurement ?? ""))
    }

    @Test func energySummaryCountsReachableEnabledPlugs() throws {
        let base = try decode(SettingsSmartPlug.self, Self.tasmotaPlugJSON)
        var a = base; a.id = 1
        var b = base; b.id = 2
        var mqtt = base; mqtt.id = 3; mqtt.plugType = "mqtt"
        var disabled = base; disabled.id = 4; disabled.enabled = false
        var offline = base; offline.id = 5
        let statuses: [Int: SettingsSmartPlugStatus] = [
            1: SettingsSmartPlugStatus(state: "ON", reachable: true, energy: SettingsSmartPlugEnergy(power: 100, today: 1, yesterday: 2, total: 10)),
            2: SettingsSmartPlugStatus(state: "OFF", reachable: true, energy: nil),
            3: SettingsSmartPlugStatus(state: nil, reachable: false, energy: SettingsSmartPlugEnergy(power: 50, today: 0.5)),
            4: SettingsSmartPlugStatus(state: "ON", reachable: true, energy: SettingsSmartPlugEnergy(power: 999)),
            5: SettingsSmartPlugStatus(state: nil, reachable: false, energy: SettingsSmartPlugEnergy(power: 77)),
        ]
        let summary = SettingsSmartPlugEnergySummary(plugs: [a, b, mqtt, disabled, offline], statuses: statuses)
        #expect(summary.total == 4)
        #expect(summary.reachable == 3)
        #expect(summary.totalPower == 150)
        #expect(summary.today == 1.5)
        #expect(summary.yesterday == 2)
        #expect(summary.lifetime == 10)
    }

    @Test func draftBodyForTasmotaNullsOtherTypes() throws {
        var draft = SettingsSmartPlugDraft()
        draft.name = "  Bench  "
        draft.ipAddress = "192.168.1.9"
        draft.username = ""
        draft.printerId = 2
        draft.scheduleEnabled = true
        draft.scheduleOnTime = "07:30"
        draft.powerAlertEnabled = true
        draft.powerAlertHigh = "200"
        #expect(draft.validationError() == nil)
        let body = draft.body()
        #expect(body["name"] == .string("Bench"))
        #expect(body["plug_type"] == .string("tasmota"))
        #expect(body["ip_address"] == .string("192.168.1.9"))
        #expect(body["username"] == .null)
        #expect(body["ha_entity_id"] == .null)
        #expect(body["mqtt_power_topic"] == .null)
        #expect(body["rest_method"] == .null)
        #expect(body["mqtt_power_multiplier"] == .number(1))
        #expect(body["printer_id"] == .number(2))
        #expect(body["schedule_on_time"] == .string("07:30"))
        #expect(body["schedule_off_time"] == .null)
        #expect(body["power_alert_high"] == .number(200))
        #expect(body["power_alert_low"] == .null)
        #expect(body["auto_on"] == .bool(true))
        #expect(body["off_delay_mode"] == .string("time"))
        // Encodes with the server's snake_case keys untouched.
        let data = try APICoders.encoder.encode(JSONValue.object(body))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"off_delay_after_drying_minutes\""))
        #expect(text.contains("\"ha_energy_today_entity\""))
        #expect(text.contains("\"rest_energy_total_multiplier\""))
    }

    @Test func draftBodyForMQTTSkipsAutomation() {
        var draft = SettingsSmartPlugDraft()
        draft.type = .mqtt
        draft.name = "Meter"
        #expect(draft.validationError() != nil)
        draft.mqttEnergyTopic = "meter/energy"
        draft.mqttEnergyMultiplier = "0,5"
        draft.mqttPowerMultiplier = "abc"
        #expect(draft.validationError() == nil)
        let body = draft.body()
        #expect(body["mqtt_energy_topic"] == .string("meter/energy"))
        #expect(body["mqtt_energy_multiplier"] == .number(0.5))
        #expect(body["mqtt_power_multiplier"] == .number(1))
        #expect(body["ip_address"] == .null)
        #expect(body["auto_on"] == nil)
        #expect(body["enabled"] == nil)
    }

    @Test func draftValidation() {
        var draft = SettingsSmartPlugDraft()
        draft.name = "X"
        draft.ipAddress = "printer.local"
        #expect(draft.validationError() != nil)
        draft.type = .rest
        #expect(draft.validationError() != nil)
        draft.restOnUrl = "http://x/on"
        draft.restHeaders = "[1, 2]"
        #expect(draft.validationError() != nil)
        draft.restHeaders = #"{"Authorization": "Bearer abc"}"#
        #expect(draft.validationError() == nil)
        draft.powerAlertEnabled = true
        draft.powerAlertLow = "6000"
        #expect(draft.validationError() != nil)
        draft.powerAlertLow = "5"
        draft.scheduleEnabled = true
        draft.scheduleOffTime = "25:00"
        #expect(draft.validationError() != nil)
        draft.type = .homeassistant
        draft.scheduleOffTime = ""
        #expect(draft.validationError() != nil)
        draft.haEntityId = "switch.printer"
        #expect(draft.validationError() == nil)
        #expect(draft.body()["rest_on_url"] == .null)
        #expect(draft.body()["ha_entity_id"] == .string("switch.printer"))
    }

    // MARK: Sensors

    @Test func decodesPrinterSensorsAndReadings() throws {
        let sensors = try decode([SettingsHASensor].self, """
        [{"printer_id": 1, "name": "Enclosure Door", "entity_id": "binary_sensor.enclosure_door", "kind": "binary",
          "device_class": "door", "unit": null, "alert_state": "on", "alert_above": null, "alert_below": null,
          "block_print": true, "notify_on_alert": true, "show_on_printer_card": true, "sort_order": 0,
          "id": 4, "last_state": "off", "last_changed": "2026-09-20T09:00:00", "last_checked": null,
          "created_at": "2026-09-01T00:00:00", "updated_at": "2026-09-01T00:00:00"}]
        """)
        #expect(sensors[0].alertState == "on")
        #expect(sensors[0].showOnPrinterCard == true)
        let readings = try decode([SettingsHASensorReading].self, """
        [{"id": 4, "name": "Enclosure Door", "entity_id": "binary_sensor.enclosure_door", "kind": "binary",
          "device_class": "door", "unit": null, "state": "on", "value": null, "alerting": true, "block_print": true,
          "reachable": true, "last_changed": null},
         {"id": 5, "name": "Room", "entity_id": "sensor.room_temp", "kind": "numeric", "device_class": "temperature",
          "unit": "°C", "state": null, "value": null, "alerting": false, "block_print": false, "reachable": false, "last_changed": null}]
        """)
        #expect(readings[0].alerting == true)
        let first = readings[0], second = readings[1]
        #expect(SettingsSensorDisplay.describe(kind: first.kind, deviceClass: first.deviceClass, unit: first.unit,
                                               state: first.state, value: first.value, reachable: first.reachable) == "Open")
        #expect(SettingsSensorDisplay.describe(kind: second.kind, deviceClass: second.deviceClass, unit: second.unit,
                                               state: second.state, value: second.value, reachable: second.reachable) == "Unavailable")
        #expect(SettingsSensorDisplay.describe(kind: "numeric", deviceClass: "humidity", unit: "%", state: "45.5",
                                               value: 45.5, reachable: true, decimals: 2) == "45.50 %")
    }

    @Test func decodesDisplayEntities() throws {
        let entities = try decode([SettingsHADisplayEntity].self, """
        [{"entity_id": "binary_sensor.door", "friendly_name": "Door", "state": "off", "domain": "binary_sensor",
          "device_class": "door", "unit_of_measurement": null},
         {"entity_id": "sensor.box_humidity", "friendly_name": "Box Humidity", "state": "31", "domain": "sensor",
          "device_class": "humidity", "unit_of_measurement": "%"}]
        """)
        #expect(entities[0].kind == "binary")
        #expect(entities[1].kind == "numeric")
        #expect(SettingsLocationSensorCategory(deviceClass: entities[1].deviceClass) == .humidity)
        #expect(SettingsLocationSensorCategory(deviceClass: "moisture") == nil)
    }

    @Test func decodesLocationSensorsReadingsAndPlaces() throws {
        let sensors = try decode([SettingsLocationSensor].self, """
        [{"location_id": 2, "name": "Box Temp", "entity_id": "sensor.box_temperature", "kind": "numeric",
          "device_class": "temperature", "unit": "°C", "alert_state": null, "alert_above": 30.0, "alert_below": 20.0,
          "notify_on_alert": false, "show_on_card": true, "sort_order": 0, "id": 11, "last_state": "24.1",
          "last_changed": null, "last_checked": null, "created_at": "2026-09-01T00:00:00", "updated_at": "2026-09-01T00:00:00"},
         {"location_id": 2, "name": "Box Battery", "entity_id": "sensor.box_battery", "kind": "numeric",
          "device_class": "battery", "unit": "%", "alert_state": null, "alert_above": null, "alert_below": 10,
          "notify_on_alert": true, "show_on_card": false, "sort_order": 0, "id": 12, "last_state": null,
          "last_changed": null, "last_checked": null, "created_at": "2026-09-01T00:00:00", "updated_at": "2026-09-01T00:00:00"},
         {"location_id": 1, "name": "Shelf Hum", "entity_id": "sensor.shelf_humidity", "kind": "numeric",
          "device_class": "humidity", "unit": "%", "alert_state": null, "alert_above": null, "alert_below": null,
          "notify_on_alert": false, "show_on_card": true, "sort_order": 0, "id": 13, "last_state": null,
          "last_changed": null, "last_checked": null, "created_at": "2026-09-01T00:00:00", "updated_at": "2026-09-01T00:00:00"}]
        """)
        #expect(sensors[0].category == .temperature)
        let places = try decode([SettingsLocationSensorPlace].self, """
        [{"id": 1, "name": "Drybox 2", "identifier": null, "spool_count": 3, "created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00"},
         {"id": 2, "name": "Drybox 10", "identifier": "DB10", "spool_count": 0, "created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00"}]
        """)
        let snapshot = SettingsSensorSnapshot(printerSensors: [], locationSensors: [sensors[1], sensors[2], sensors[0]], locations: places)
        let groups = snapshot.locationGroups
        #expect(groups.map(\.id) == [1, 2])
        #expect(groups[1].title == "Drybox 10")
        #expect(groups[1].sensors.map(\.id) == [11, 12])

        let reading = try decode(SettingsLocationSensorReading.self, """
        {"id": 11, "name": "Box Temp", "entity_id": "sensor.box_temperature", "kind": "numeric", "device_class": "temperature",
         "unit": "°C", "state": "31.2", "value": 31.2, "alerting": true, "reachable": true, "alert_state": null,
         "alert_above": 30.0, "alert_below": 20.0, "last_changed": "2026-09-20T09:00:00", "show_on_card": true}
        """)
        #expect(SettingsSensorDisplay.alertStatus(reading) == "above")
        var low = reading; low.value = 10
        #expect(SettingsSensorDisplay.alertStatus(low) == "below")
        var ok = reading; ok.value = 25
        #expect(SettingsSensorDisplay.alertStatus(ok) == "ok")
        var unreachable = reading; unreachable.reachable = false
        #expect(SettingsSensorDisplay.alertStatus(unreachable) == nil)
    }

    @Test func locationDefaultsRoundTrip() throws {
        #expect(SettingsLocationSensorDefaults.parse("") == .builtIn)
        #expect(SettingsLocationSensorDefaults.parse("not json") == .builtIn)
        let parsed = SettingsLocationSensorDefaults.parse(#"{"temperature": {"alertAbove": "28", "alertBelow": "", "notifyOnAlert": true, "showOnCard": false}, "humidity": {"alertAbove": 40}}"#)
        #expect(parsed[.temperature] == .init(alertAbove: "28", alertBelow: "", notifyOnAlert: true))
        // A non-string threshold is ignored and the built-in kept.
        #expect(parsed[.humidity].alertAbove == "30")
        #expect(parsed[.battery] == SettingsLocationSensorDefaults.builtIn[.battery])

        var edited = parsed
        edited[.battery] = .init(alertAbove: "99", alertBelow: "15", notifyOnAlert: true)
        let json = edited.serialized()
        #expect(json.count <= 2000)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]])
        #expect(object["battery"]?["alertAbove"] as? String == "")
        #expect(object["battery"]?["alertBelow"] as? String == "15")
        #expect(object["temperature"]?["notifyOnAlert"] as? Bool == true)
        #expect(Set(object.keys) == ["temperature", "humidity", "battery"])
        var expected = edited
        expected[.battery].alertAbove = ""
        #expect(SettingsLocationSensorDefaults.parse(json) == expected)
    }

    @Test func alertDraftFields() {
        var binary = SettingsSensorAlertDraft(kind: "binary", alertState: "on", alertAbove: "5", alertBelow: "1")
        #expect(binary.hasCondition)
        #expect(binary.fields() == ["alert_state": .string("on"), "alert_above": .null, "alert_below": .null])
        binary.alertState = ""
        #expect(!binary.hasCondition)

        var numeric = SettingsSensorAlertDraft(kind: "numeric", alertState: "on", alertAbove: "30", alertBelow: "20")
        #expect(numeric.validationError() == nil)
        #expect(numeric.fields() == ["alert_state": .null, "alert_above": .number(30), "alert_below": .number(20)])
        #expect(numeric.fields(allowsAbove: false)["alert_above"] == .null)
        numeric.alertBelow = "35"
        #expect(numeric.validationError() != nil)
        #expect(numeric.validationError(allowsAbove: false) == nil)
        numeric.alertBelow = "x"
        #expect(numeric.validationError() != nil)
    }

    // MARK: Network

    @Test func decodesMQTTStatus() throws {
        let off = try decode(SettingsMQTTStatus.self, #"{"enabled": false, "connected": false, "broker": "", "port": 0, "topic_prefix": "bambuddy"}"#)
        #expect(off.topicPrefix == "bambuddy")
        #expect(off.endpoint == "")
        let on = try decode(SettingsMQTTStatus.self, #"{"enabled": true, "connected": true, "broker": "mqtt.lan", "port": 8883, "topic_prefix": "bb"}"#)
        #expect(on.endpoint == "mqtt.lan:8883")
    }

    @Test func webhookCurlCommands() {
        let add = SettingsNetworkWebhook.all.first { $0.path == "/webhook/queue/add" }
        let curl = add?.curl(base: "https://bb.example/api/v1") ?? ""
        #expect(curl.contains("-X POST"))
        #expect(curl.contains("X-API-Key"))
        #expect(curl.contains("'https://bb.example/api/v1/webhook/queue/add'"))
        let status = SettingsNetworkWebhook.all.first { $0.path == "/webhook/queue" }
        #expect(status?.curl(base: "x").contains("-X") == false)
        #expect(SettingsNetworkWebhook.all.count == 6)
    }
}
