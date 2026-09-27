import Foundation
import Testing
@testable import Bambuddy

struct SettingsNotificationsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func encodedObject(_ value: JSONValue) throws -> [String: Any] {
        let data = try APICoders.encoder.encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Providers

    /// Shape produced by `_provider_to_dict` in routes/notifications.py.
    static let providerJSON = """
    {
      "id": 3,
      "name": "Phone",
      "provider_type": "ntfy",
      "enabled": true,
      "config": {"server": "https://ntfy.example.com", "topic": "printers", "auth_token": "tk_abc",
                 "event_priorities": {"on_print_failed": 5, "on_print_complete": 2}},
      "on_print_start": true,
      "on_print_complete": true,
      "on_print_failed": true,
      "on_print_stopped": false,
      "on_print_progress": false,
      "on_print_missing_spool_assignment": false,
      "on_billing_charge_failed": true,
      "on_printer_offline": true,
      "on_printer_error": false,
      "on_ai_failure_detection": false,
      "on_filament_low": false,
      "on_maintenance_due": false,
      "on_ha_sensor_alert": false,
      "on_location_ha_sensor_alert": false,
      "on_ams_humidity_high": true,
      "on_ams_temperature_high": false,
      "on_ams_drying_suspended": true,
      "on_ams_ht_humidity_high": false,
      "on_ams_ht_temperature_high": false,
      "on_plate_not_empty": true,
      "on_plate_clear_required": false,
      "on_bed_cooled": false,
      "on_first_layer_complete": false,
      "on_stock_reorder_alert": false,
      "on_stock_break_alert": false,
      "on_queue_job_added": false,
      "on_queue_job_assigned": false,
      "on_queue_job_started": false,
      "on_queue_job_waiting": true,
      "on_queue_job_skipped": true,
      "on_queue_job_failed": true,
      "on_queue_completed": false,
      "quiet_hours_enabled": true,
      "quiet_hours_start": "22:00",
      "quiet_hours_end": "07:00",
      "daily_digest_enabled": false,
      "daily_digest_time": null,
      "printer_id": 1,
      "last_success": "2026-09-20T10:15:30.123456Z",
      "last_error": "HTTP 500",
      "last_error_at": "2026-09-21T08:00:00",
      "created_at": "2026-01-02T03:04:05.678901",
      "updated_at": "2026-09-21T08:00:00.000001"
    }
    """

    @Test func decodesProvider() throws {
        let p = try decode(SettingsNotificationProvider.self, Self.providerJSON)
        #expect(p.id == 3)
        #expect(p.name == "Phone")
        #expect(p.providerType == "ntfy")
        #expect(p.kind == .ntfy)
        #expect(p.enabled)
        #expect(p.config["auth_token"]?.stringValue == "tk_abc")
        #expect(p.config["event_priorities"]?["on_print_failed"]?.intValue == 5)
        #expect(p.isOn("on_print_start"))
        #expect(!p.isOn("on_print_stopped"))
        #expect(p.isOn("on_ams_humidity_high"))
        #expect(p.events.count == SettingsNotificationEvent.all.count)
        #expect(p.quietHoursEnabled)
        #expect(p.quietHoursStart == "22:00")
        #expect(p.dailyDigestTime == nil)
        #expect(p.printerId == 1)
        #expect(p.lastSuccess != nil)
        #expect(p.lastErrorAt != nil)
        #expect(p.createdAt != nil)
        #expect(p.updatedAt != nil)
        // The error is newer than the last success.
        #expect(p.lastAttemptFailed)
        #expect(p.enabledEvents.first?.key == "on_print_start")
    }

    @Test func decodesProviderList() throws {
        let list = try decode([SettingsNotificationProvider].self, "[\(Self.providerJSON)]")
        #expect(list.count == 1)
    }

    /// Legacy rows can carry null flags and no status/timestamps.
    @Test func decodesLegacyProviderWithNulls() throws {
        let json = """
        {"id": 9, "name": "Old", "provider_type": "email", "enabled": false,
         "config": {"smtp_server": "smtp.example.com", "smtp_port": 587, "use_tls": true},
         "on_print_start": null, "on_print_complete": true, "on_stock_break_alert": null,
         "quiet_hours_enabled": false, "quiet_hours_start": null, "quiet_hours_end": null,
         "daily_digest_enabled": false, "daily_digest_time": null, "printer_id": null,
         "last_success": null, "last_error": null, "last_error_at": null,
         "created_at": "2025-05-01T12:00:00", "updated_at": "2025-05-01T12:00:00"}
        """
        let p = try decode(SettingsNotificationProvider.self, json)
        #expect(p.id == 9)
        #expect(!p.enabled)
        #expect(!p.isOn("on_print_start"))
        #expect(p.isOn("on_print_complete"))
        #expect(!p.isOn("on_queue_completed"))
        #expect(p.printerId == nil)
        #expect(p.lastSuccess == nil)
        #expect(!p.lastAttemptFailed)

        let draft = SettingsNotificationProviderDraft(provider: p)
        #expect(draft.config["smtp_port"] == "587")
        #expect(draft.config["use_tls"] == "true")
        #expect(draft.events["on_print_start"] == false)
        #expect(draft.quietHoursStart == "22:00")
    }

    @Test func errorOlderThanSuccessIsNotFailure() throws {
        let json = """
        {"id": 1, "name": "A", "provider_type": "discord", "enabled": true, "config": {},
         "last_success": "2026-09-22T10:00:00Z", "last_error": "timeout", "last_error_at": "2026-09-21T10:00:00Z",
         "created_at": "2026-09-01T00:00:00Z", "updated_at": "2026-09-01T00:00:00Z"}
        """
        let p = try decode(SettingsNotificationProvider.self, json)
        #expect(!p.lastAttemptFailed)
    }

    @Test func providerRoundTripsThroughEncoding() throws {
        let p = try decode(SettingsNotificationProvider.self, Self.providerJSON)
        let data = try APICoders.encoder.encode(p)
        let again = try APICoders.decoder.decode(SettingsNotificationProvider.self, from: data)
        #expect(again == p)
    }

    // MARK: Tests

    @Test func decodesTestResults() throws {
        let ok = try decode(SettingsNotificationTestResult.self, #"{"success": true, "message": "Test notification sent successfully"}"#)
        #expect(ok.success)
        let all = try decode(SettingsNotificationTestAllResult.self, """
        {"tested": 2, "success": 1, "failed": 1, "results": [
          {"provider_id": 1, "provider_name": "Mail", "provider_type": "email", "success": true, "message": "Email sent successfully"},
          {"provider_id": 2, "provider_name": "Bot", "provider_type": "telegram", "success": false, "message": "Telegram error: chat not found"}
        ]}
        """)
        #expect(all.tested == 2)
        #expect(all.failed == 1)
        #expect(all.results?.last?.providerName == "Bot")
        #expect(all.results?.last?.success == false)
        let none = try decode(SettingsNotificationTestAllResult.self, #"{"tested": 0, "success": 0, "failed": 0, "results": []}"#)
        #expect(none.results?.isEmpty == true)
    }

    // MARK: Logs

    @Test func decodesLogs() throws {
        let logs = try decode([SettingsNotificationLog].self, """
        [
          {"id": 12, "provider_id": 3, "provider_name": "Phone", "provider_type": "ntfy", "event_type": "print_complete",
           "title": "Print Completed", "message": "X1C: Benchy.3mf", "success": true, "error_message": null,
           "printer_id": 1, "printer_name": "X1C", "created_at": "2026-09-21T08:00:00.123456"},
          {"id": 11, "provider_id": 7, "provider_name": null, "provider_type": null, "event_type": "test",
           "title": "Test", "message": "Hello", "success": false, "error_message": "HTTP 401",
           "printer_id": null, "printer_name": null, "created_at": "2026-09-20T08:00:00"}
        ]
        """)
        #expect(logs.count == 2)
        #expect(logs[0].success == true)
        #expect(logs[0].createdAt != nil)
        #expect(logs[1].providerName == nil)
        #expect(logs[1].errorMessage == "HTTP 401")
    }

    @Test func decodesLogStatsAndClear() throws {
        let stats = try decode(SettingsNotificationLogStats.self, """
        {"total": 5, "success_count": 4, "failure_count": 1,
         "by_event_type": {"print_complete": 3, "test": 2}, "by_provider": {"Phone": 5}}
        """)
        #expect(stats.total == 5)
        #expect(stats.successCount == 4)
        #expect(stats.byEventType?["print_complete"] == 3)
        #expect(stats.byProvider?["Phone"] == 5)
        let empty = try decode(SettingsNotificationLogStats.self,
                               #"{"total": 0, "success_count": 0, "failure_count": 0, "by_event_type": {}, "by_provider": {}}"#)
        #expect(empty.byEventType?.isEmpty == true)
        let cleared = try decode(SettingsNotificationLogClearResult.self, #"{"deleted": 4, "message": "Deleted 4 logs older than 30 days"}"#)
        #expect(cleared.deleted == 4)
    }

    @Test func logFilterQuery() {
        var filter = SettingsNotificationLogFilter()
        var q = filter.query(limit: 50, offset: 0)
        #expect(q["success"] == nil || q["success"]! == nil)
        #expect(!filter.isFiltered)
        filter.status = .failed
        filter.providerId = 4
        filter.eventType = "print_failed"
        filter.days = 30
        q = filter.query(limit: 50, offset: 100)
        let items = q.compactMap { key, value in value.map { $0.queryItems(key: key) } }.flatMap { $0 }
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(dict["success"] == "false")
        #expect(dict["provider_id"] == "4")
        #expect(dict["event_type"] == "print_failed")
        #expect(dict["days"] == "30")
        #expect(dict["offset"] == "100")
        #expect(dict["limit"] == "50")
        #expect(filter.isFiltered)
    }

    // MARK: Templates

    @Test func decodesTemplates() throws {
        let templates = try decode([SettingsNotificationTemplate].self, """
        [{"id": 1, "event_type": "print_start", "name": "Print Started", "title_template": "Print Started",
          "body_template": "{printer}: {filename}\\nEstimated: {estimated_time}", "is_default": true,
          "created_at": "2025-01-01T00:00:00", "updated_at": "2025-01-02T00:00:00"}]
        """)
        #expect(templates.first?.eventType == "print_start")
        #expect(templates.first?.displayName == "Print Started")
        #expect(templates.first?.bodyTemplate?.contains("\n") == true)

        let vars = try decode([SettingsNotificationTemplateVariables].self, """
        [{"event_type": "print_start", "event_name": "Print Started",
          "variables": ["printer", "filename", "estimated_time", "eta", "timestamp", "app_name"]},
         {"event_type": "ams_humidity_high", "event_name": "ams_humidity_high", "variables": ["printer", "ams_label"]}]
        """)
        #expect(vars.count == 2)
        #expect(vars[0].variables?.contains("eta") == true)

        let preview = try decode(SettingsNotificationTemplatePreview.self, #"{"title": "Print Started", "body": "Bambu X1C: Benchy.3mf"}"#)
        #expect(preview.body == "Bambu X1C: Benchy.3mf")
    }

    @Test func templateRequestEncoding() throws {
        let preview = SettingsNotificationTemplateRequest(eventType: "print_start", titleTemplate: "T {printer}", bodyTemplate: "B")
        let json = try encodedObject(try JSONValue.from(preview))
        #expect(json["event_type"] as? String == "print_start")
        #expect(json["title_template"] as? String == "T {printer}")
        #expect(json["body_template"] as? String == "B")

        let update = SettingsNotificationTemplateRequest(eventType: nil, titleTemplate: "T", bodyTemplate: "B")
        let data = try APICoders.encoder.encode(update)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["event_type"] == nil)
        #expect(obj.keys.sorted() == ["body_template", "title_template"])
    }

    @Test func templateFilterAndInsertion() throws {
        let templates = try decode([SettingsNotificationTemplate].self, """
        [{"id": 2, "event_type": "print_failed", "name": "Print Failed", "title_template": "Oops", "body_template": "x", "is_default": true},
         {"id": 1, "event_type": "print_start", "name": "Print Started", "title_template": "Go", "body_template": "y", "is_default": true}]
        """)
        #expect(SettingsNotificationTemplatesView.filter(templates, query: "").map(\.id) == [2, 1])
        #expect(SettingsNotificationTemplatesView.filter(templates, query: "oops").map(\.id) == [2])
        #expect(SettingsNotificationTemplatesView.filter(templates, query: "start").map(\.id) == [1])

        let text = "Hello world"
        let start = text.index(text.startIndex, offsetBy: 6)
        let replaced = SettingsNotificationTemplateText.inserting("{printer}", into: text, selection: start..<text.endIndex)
        #expect(replaced.text == "Hello {printer}")
        #expect(replaced.cursor == replaced.text.endIndex)
        let inserted = SettingsNotificationTemplateText.inserting("{x}", into: text, selection: start..<start)
        #expect(inserted.text == "Hello {x}world")
        #expect(inserted.text[inserted.cursor...] == "world")
        let appended = SettingsNotificationTemplateText.inserting("{x}", into: "ab", selection: nil)
        #expect(appended.text == "ab{x}")

        #expect(SettingsNotificationTemplateText.validationError(title: " ", body: "b") != nil)
        #expect(SettingsNotificationTemplateText.validationError(title: "t", body: "") != nil)
        #expect(SettingsNotificationTemplateText.validationError(title: String(repeating: "a", count: 201), body: "b") != nil)
        #expect(SettingsNotificationTemplateText.validationError(title: "t", body: "b") == nil)
    }

    @Test func decodesAdvancedAuthStatus() throws {
        let status = try decode(SettingsNotificationAdvancedAuthStatus.self, """
        {"advanced_auth_enabled": false, "smtp_configured": true, "local_login_enabled": true, "autologin_provider_id": null}
        """)
        #expect(status.advancedAuthEnabled == false)
        #expect(status.smtpConfigured == true)
    }

    // MARK: Draft & request bodies

    @Test func newDraftBodyUsesServerDefaults() throws {
        var draft = SettingsNotificationProviderDraft()
        draft.name = "  Mail  "
        draft.providerType = "email"
        draft.config = ["smtp_server": "smtp.example.com", "from_email": "a@b.c", "to_email": "d@e.f",
                        "smtp_port": "", "auth_enabled": "false", "username": "hidden", "security": "ssl"]
        let json = try encodedObject(draft.body())
        #expect(json["name"] as? String == "Mail")
        #expect(json["provider_type"] as? String == "email")
        #expect(json["enabled"] as? Bool == true)
        #expect(json["printer_id"] is NSNull)
        #expect(json["quiet_hours_enabled"] as? Bool == false)
        #expect(json["quiet_hours_start"] is NSNull)
        #expect(json["daily_digest_time"] is NSNull)
        #expect(json["on_print_complete"] as? Bool == true)
        #expect(json["on_print_start"] as? Bool == false)
        #expect(json["on_queue_job_waiting"] as? Bool == true)
        #expect(json["on_ams_ht_temperature_high"] as? Bool == false)
        for event in SettingsNotificationEvent.all { #expect(json[event.key] is Bool, "missing \(event.key)") }
        let config = try #require(json["config"] as? [String: Any])
        // Empty values are dropped so the server falls back to its defaults; "false" is kept.
        #expect(config["smtp_port"] == nil)
        #expect(config["auth_enabled"] as? String == "false")
        #expect(config["security"] as? String == "ssl")
        // Hidden while authentication is off.
        #expect(config["username"] == nil)
        #expect(config["event_priorities"] == nil)
        #expect(draft.validationError == nil)
    }

    @Test func editDraftKeepsConfigAndPriorities() throws {
        let p = try decode(SettingsNotificationProvider.self, Self.providerJSON)
        var draft = SettingsNotificationProviderDraft(provider: p)
        #expect(draft.config["topic"] == "printers")
        #expect(draft.eventPriorities["on_print_failed"] == 5)
        #expect(draft.events["on_print_start"] == true)
        #expect(draft.printerId == 1)
        draft.quietHoursStart = "6:5"
        let json = try encodedObject(draft.body(includeType: false))
        #expect(json["provider_type"] == nil)
        #expect(json["printer_id"] as? Int == 1)
        #expect(json["quiet_hours_start"] as? String == "06:05")
        let config = try #require(json["config"] as? [String: Any])
        #expect(config["auth_token"] as? String == "tk_abc")
        let priorities = try #require(config["event_priorities"] as? [String: Any])
        #expect(priorities["on_print_failed"] as? Int == 5)
        #expect(priorities["on_print_complete"] as? Int == 2)

        // Priorities for events that are switched off are not sent.
        draft.events["on_print_failed"] = false
        let config2 = try #require(try encodedObject(draft.body())["config"] as? [String: Any])
        let priorities2 = try #require(config2["event_priorities"] as? [String: Any])
        #expect(priorities2["on_print_failed"] == nil)

        let test = try encodedObject(draft.testBody)
        #expect(test["provider_type"] as? String == "ntfy")
        #expect((test["config"] as? [String: Any])?["topic"] as? String == "printers")
    }

    @Test func homeAssistantObjectDataBecomesText() throws {
        let json = """
        {"id": 5, "name": "HA", "provider_type": "homeassistant", "enabled": true,
         "config": {"service": "notify.mobile_app_phone", "data": {"ttl": 0, "priority": "high"}},
         "created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00"}
        """
        let draft = SettingsNotificationProviderDraft(provider: try decode(SettingsNotificationProvider.self, json))
        #expect(draft.config["data"] == #"{"priority":"high","ttl":0}"#)
        #expect(draft.validationError == nil)
    }

    @Test func draftValidation() {
        var draft = SettingsNotificationProviderDraft()
        #expect(draft.validationError != nil) // no name
        draft.name = "Bot"
        draft.providerType = "telegram"
        #expect(draft.configValidationError != nil) // bot token missing
        draft.config = ["bot_token": "123:abc", "chat_id": "-100"]
        #expect(draft.validationError == nil)
        draft.config["message_thread_id"] = "1e5"
        #expect(draft.configValidationError != nil)
        draft.config["message_thread_id"] = "42"
        #expect(draft.configValidationError == nil)

        draft.providerType = "homeassistant"
        draft.config = ["data": "[1, 2]"]
        #expect(draft.configValidationError != nil)
        draft.config = ["data": #"{"priority": "high"}"#]
        #expect(draft.configValidationError == nil)
        draft.config = [:]
        #expect(draft.configValidationError == nil) // nothing required

        draft.providerType = "pushover"
        draft.config = ["user_key": "u", "app_token": "a", "priority": "2", "retry": "10"]
        #expect(draft.configValidationError != nil)
        draft.config["retry"] = "60"
        #expect(draft.configValidationError == nil)
        // retry/expire are only sent for emergency priority.
        draft.config["priority"] = "1"
        let config = draft.configPayload
        #expect(config["retry"] == nil)
        #expect(config["priority"]?.stringValue == "1")

        draft.providerType = "webhook"
        draft.config = ["webhook_url": "https://x", "payload_format": "slack", "field_title": "t"]
        #expect(draft.configPayload["field_title"] == nil)
        #expect(draft.configPayload["payload_format"]?.stringValue == "slack")
    }

    @Test func timeHelpers() {
        #expect(SettingsNotificationProviderDraft.normalizedTime("7:05") == "07:05")
        #expect(SettingsNotificationProviderDraft.normalizedTime("23:59") == "23:59")
        #expect(SettingsNotificationProviderDraft.normalizedTime("24:00") == nil)
        #expect(SettingsNotificationProviderDraft.normalizedTime("nope") == nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let date = SettingsNotificationProviderDraft.date(fromTime: "22:30", calendar: calendar)
        #expect(SettingsNotificationProviderDraft.time(from: date, calendar: calendar) == "22:30")
    }

    @Test func eventCatalogue() {
        let keys = SettingsNotificationEvent.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(keys.count == 32)
        #expect(SettingsNotificationEvent.grouped().flatMap(\.events).count == keys.count)
        for kind in SettingsNotificationProviderKind.allCases {
            #expect(!kind.title.isEmpty)
            #expect(kind == .homeassistant || kind.fields.contains { $0.required })
        }
        #expect(SettingsNotificationEventNames.name(for: "queue_job_added") == "Queue Job Added")
        #expect(SettingsNotificationEventNames.name(for: "brand_new_event") == "Brand New Event")
    }
}
