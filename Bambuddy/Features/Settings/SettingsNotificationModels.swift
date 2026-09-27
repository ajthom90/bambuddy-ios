import Foundation

// MARK: - Provider

/// A server-side notification provider (`GET /notifications/`).
///
/// The response carries ~30 `on_*` event flags that keep growing between server versions, so
/// the payload is decoded from its raw dictionary: fixed fields are pulled out explicitly and
/// every `on_*` boolean lands in `events` (keyed by its snake_case name). Legacy rows may carry
/// `null` flags, which read as off.
struct SettingsNotificationProvider: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var providerType: String
    var enabled: Bool
    var config: [String: JSONValue]
    var events: [String: Bool]
    var quietHoursEnabled: Bool
    var quietHoursStart: String?
    var quietHoursEnd: String?
    var dailyDigestEnabled: Bool
    var dailyDigestTime: String?
    var printerId: Int?
    var lastSuccess: Date?
    var lastError: String?
    var lastErrorAt: Date?
    var createdAt: Date?
    var updatedAt: Date?
    /// The payload as received (kept for encoding).
    private var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) throws {
        guard let id = raw["id"]?.intValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Notification provider without id"))
        }
        self.raw = raw
        self.id = id
        name = raw["name"]?.stringValue ?? "Provider \(id)"
        providerType = raw["provider_type"]?.stringValue ?? ""
        enabled = raw["enabled"]?.boolValue ?? false
        config = raw["config"]?.objectValue ?? [:]
        var flags: [String: Bool] = [:]
        for (key, value) in raw where key.hasPrefix("on_") {
            flags[key] = value.boolValue ?? false
        }
        events = flags
        quietHoursEnabled = raw["quiet_hours_enabled"]?.boolValue ?? false
        quietHoursStart = Self.string(raw["quiet_hours_start"])
        quietHoursEnd = Self.string(raw["quiet_hours_end"])
        dailyDigestEnabled = raw["daily_digest_enabled"]?.boolValue ?? false
        dailyDigestTime = Self.string(raw["daily_digest_time"])
        printerId = raw["printer_id"].flatMap { $0.isNull ? nil : $0.intValue }
        lastSuccess = Self.date(raw["last_success"])
        lastError = Self.string(raw["last_error"])
        lastErrorAt = Self.date(raw["last_error_at"])
        createdAt = Self.date(raw["created_at"])
        updatedAt = Self.date(raw["updated_at"])
    }

    init(from decoder: Decoder) throws {
        // Decoding a dictionary keeps the server's snake_case keys even with `.convertFromSnakeCase`.
        let object = try decoder.singleValueContainer().decode([String: JSONValue].self)
        try self.init(raw: object)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull, let s = value.stringValue, !s.isEmpty else { return nil }
        return s
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard let value, !value.isNull else { return nil }
        if case .string(let s) = value { return APICoders.parseDate(s) }
        return value.doubleValue.map { Date(timeIntervalSince1970: $0) }
    }

    func isOn(_ event: String) -> Bool { events[event] ?? false }

    /// Events this provider fires on, in catalogue order.
    var enabledEvents: [SettingsNotificationEvent] {
        SettingsNotificationEvent.all.filter { isOn($0.key) }
    }

    /// True when the most recent delivery attempt failed (error newer than the last success).
    var lastAttemptFailed: Bool {
        guard lastError != nil else { return false }
        guard let lastSuccess else { return true }
        guard let lastErrorAt else { return false }
        return lastErrorAt > lastSuccess
    }

    var kind: SettingsNotificationProviderKind? { SettingsNotificationProviderKind(rawValue: providerType) }
}

// MARK: - Test results

/// `POST /notifications/test-config` and `POST /notifications/{id}/test`.
struct SettingsNotificationTestResult: Codable, Sendable, Hashable {
    var success: Bool
    var message: String?
}

/// `POST /notifications/test-all`.
struct SettingsNotificationTestAllResult: Codable, Sendable, Hashable {
    var tested: Int?
    var success: Int?
    var failed: Int?
    var results: [Entry]?

    struct Entry: Codable, Sendable, Hashable {
        var providerId: Int?
        var providerName: String?
        var providerType: String?
        var success: Bool?
        var message: String?
    }
}

// MARK: - Delivery log

/// `GET /notifications/logs` item.
struct SettingsNotificationLog: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var providerId: Int?
    /// Null when the provider has since been deleted.
    var providerName: String?
    var providerType: String?
    var eventType: String?
    var title: String?
    var message: String?
    var success: Bool?
    var errorMessage: String?
    var printerId: Int?
    var printerName: String?
    var createdAt: Date?
}

/// `GET /notifications/logs/stats`.
struct SettingsNotificationLogStats: Codable, Sendable, Hashable {
    var total: Int?
    var successCount: Int?
    var failureCount: Int?
    var byEventType: [String: Int]?
    var byProvider: [String: Int]?
}

/// `DELETE /notifications/logs`.
struct SettingsNotificationLogClearResult: Codable, Sendable, Hashable {
    var deleted: Int?
    var message: String?
}

// MARK: - Templates

/// `GET /notification-templates/` item.
struct SettingsNotificationTemplate: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var eventType: String
    var name: String?
    var titleTemplate: String?
    var bodyTemplate: String?
    var isDefault: Bool?
    var createdAt: Date?
    var updatedAt: Date?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return SettingsNotificationEventNames.name(for: eventType)
    }
}

/// `GET /notification-templates/variables` item.
struct SettingsNotificationTemplateVariables: Codable, Sendable, Hashable {
    var eventType: String
    var eventName: String?
    var variables: [String]?
}

/// `POST /notification-templates/preview` response.
struct SettingsNotificationTemplatePreview: Codable, Sendable, Hashable {
    var title: String?
    var body: String?
}

/// Request body for template preview / update.
struct SettingsNotificationTemplateRequest: Codable, Sendable, Hashable {
    var eventType: String?
    var titleTemplate: String
    var bodyTemplate: String
}

/// `GET /auth/advanced-auth/status` (only the field this page needs).
struct SettingsNotificationAdvancedAuthStatus: Codable, Sendable, Hashable {
    var advancedAuthEnabled: Bool?
    var smtpConfigured: Bool?
}

// MARK: - Event catalogue

/// One `on_*` event flag of a provider.
struct SettingsNotificationEvent: Sendable, Hashable, Identifiable {
    let key: String
    let title: String
    let help: String?
    let group: Group
    /// The server's default for new providers.
    let defaultOn: Bool

    var id: String { key }

    enum Group: String, Sendable, CaseIterable, Hashable {
        case printing, plate, printer, ams, sensors, inventory, queue

        var title: String {
            switch self {
            case .printing: "Print Jobs"
            case .plate: "Build Plate"
            case .printer: "Printer Status"
            case .ams: "AMS Environment"
            case .sensors: "Home Assistant Sensors"
            case .inventory: "Inventory"
            case .queue: "Print Queue"
            }
        }
    }

    init(_ key: String, _ title: String, _ group: Group, on defaultOn: Bool = false, help: String? = nil) {
        self.key = key; self.title = title; self.group = group; self.defaultOn = defaultOn; self.help = help
    }

    /// Every event flag accepted by `NotificationProviderCreate`, grouped for display.
    static let all: [SettingsNotificationEvent] = [
        .init("on_print_start", "Print started", .printing),
        .init("on_first_layer_complete", "First layer finished", .printing),
        .init("on_print_progress", "Progress milestones", .printing, help: "At 25%, 50% and 75%."),
        .init("on_print_complete", "Print completed", .printing, on: true),
        .init("on_print_failed", "Print failed", .printing, on: true),
        .init("on_print_stopped", "Print stopped", .printing, on: true, help: "Cancelled by a user or the printer."),
        .init("on_print_missing_spool_assignment", "Spools not assigned", .printing,
              help: "A print started while AMS slots it uses have no spool assigned."),
        .init("on_billing_charge_failed", "Charge not recorded", .printing, on: true,
              help: "The cost of a finished print could not be booked."),
        .init("on_plate_not_empty", "Objects on plate", .plate, on: true,
              help: "Something was detected on the bed before a print."),
        .init("on_plate_clear_required", "Plate needs clearing", .plate,
              help: "A finished print is waiting for someone to confirm the plate is clear."),
        .init("on_bed_cooled", "Bed cooled down", .plate, help: "After a print, once the bed drops below the threshold."),
        .init("on_printer_offline", "Printer offline", .printer),
        .init("on_printer_error", "Printer error", .printer, help: "HMS and AMS errors."),
        .init("on_ai_failure_detection", "AI failure detection", .printer, help: "Obico flagged a possible failed print."),
        .init("on_filament_low", "Filament low", .printer),
        .init("on_maintenance_due", "Maintenance due", .printer),
        .init("on_ams_humidity_high", "AMS humidity high", .ams),
        .init("on_ams_temperature_high", "AMS temperature high", .ams),
        .init("on_ams_drying_suspended", "AMS drying gave up", .ams, on: true,
              help: "Automatic drying stopped retrying on an AMS unit."),
        .init("on_ams_ht_humidity_high", "AMS-HT humidity high", .ams),
        .init("on_ams_ht_temperature_high", "AMS-HT temperature high", .ams),
        .init("on_ha_sensor_alert", "Printer sensor alert", .sensors,
              help: "A sensor bound to a printer entered its alert state."),
        .init("on_location_ha_sensor_alert", "Storage sensor alert", .sensors,
              help: "A sensor bound to a storage location entered its alert state."),
        .init("on_stock_reorder_alert", "Reorder point reached", .inventory),
        .init("on_stock_break_alert", "Stock will run out", .inventory,
              help: "Stock is forecast to run out before a reorder arrives."),
        .init("on_queue_job_added", "Job added", .queue),
        .init("on_queue_job_assigned", "Job assigned to printer", .queue),
        .init("on_queue_job_started", "Job started", .queue),
        .init("on_queue_job_waiting", "Job waiting", .queue, on: true, help: "Waiting for filament or a free printer."),
        .init("on_queue_job_skipped", "Job skipped", .queue, on: true),
        .init("on_queue_job_failed", "Job failed to start", .queue, on: true),
        .init("on_queue_completed", "Queue finished", .queue),
    ]

    struct GroupEntry: Hashable, Sendable, Identifiable {
        let group: Group
        let events: [SettingsNotificationEvent]
        var id: Group { group }
    }

    static func grouped() -> [GroupEntry] {
        Group.allCases.map { g in GroupEntry(group: g, events: all.filter { $0.group == g }) }.filter { !$0.events.isEmpty }
    }

    static func named(_ key: String) -> SettingsNotificationEvent? { all.first { $0.key == key } }
}

/// Human-readable names for the server's `event_type` strings (logs, templates).
enum SettingsNotificationEventNames {
    private static let names: [String: String] = [
        "print_start": "Print Started",
        "print_complete": "Print Completed",
        "print_failed": "Print Failed",
        "print_stopped": "Print Stopped",
        "print_progress": "Print Progress",
        "print_missing_spool_assignment": "Spools Not Assigned",
        "billing_charge_failed": "Charge Not Recorded",
        "printer_offline": "Printer Offline",
        "printer_error": "Printer Error",
        "filament_low": "Filament Low",
        "maintenance_due": "Maintenance Due",
        "ams_humidity_high": "AMS Humidity High",
        "ams_temperature_high": "AMS Temperature High",
        "ams_drying_suspended": "AMS Drying Suspended",
        "ams_ht_humidity_high": "AMS-HT Humidity High",
        "ams_ht_temperature_high": "AMS-HT Temperature High",
        "bed_cooled": "Bed Cooled",
        "first_layer_complete": "First Layer Complete",
        "plate_not_empty": "Objects on Plate",
        "plate_clear_required": "Plate Needs Clearing",
        "ai_failure_detection": "AI Failure Detection",
        "ha_sensor_alert": "Printer Sensor Alert",
        "location_ha_sensor_alert": "Storage Sensor Alert",
        "stock_reorder_alert": "Reorder Point Reached",
        "stock_break_alert": "Stock Will Run Out",
        "queue_job_added": "Queue Job Added",
        "queue_job_assigned": "Queue Job Assigned",
        "queue_job_started": "Queue Job Started",
        "queue_job_waiting": "Queue Job Waiting",
        "queue_job_skipped": "Queue Job Skipped",
        "queue_job_failed": "Queue Job Failed",
        "queue_completed": "Queue Completed",
        "user_created": "Welcome Email",
        "password_reset": "Password Reset",
        "user_print_start": "User Email: Print Started",
        "user_print_complete": "User Email: Print Completed",
        "user_print_failed": "User Email: Print Failed",
        "user_print_stopped": "User Email: Print Stopped",
        "daily_digest": "Daily Digest",
        "test": "Test Notification",
    ]

    static func name(for eventType: String) -> String {
        if let known = names[eventType] { return known }
        let words = eventType.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? eventType : words.joined(separator: " ")
    }

    /// Event types offered in the log filter when the stats don't list any yet.
    static var knownEventTypes: [String] { names.keys.sorted { name(for: $0) < name(for: $1) } }
}

// MARK: - Provider kinds & config fields

/// Provider types supported by the server (`ProviderType`).
enum SettingsNotificationProviderKind: String, CaseIterable, Sendable, Identifiable {
    case email, telegram, discord, ntfy, pushover, bark, callmebot, webhook, homeassistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .email: "Email (SMTP)"
        case .telegram: "Telegram"
        case .discord: "Discord"
        case .ntfy: "ntfy"
        case .pushover: "Pushover"
        case .bark: "Bark"
        case .callmebot: "WhatsApp (CallMeBot)"
        case .webhook: "Webhook"
        case .homeassistant: "Home Assistant"
        }
    }

    var systemImage: String {
        switch self {
        case .email: "envelope.fill"
        case .telegram: "paperplane.fill"
        case .discord: "bubble.left.and.bubble.right.fill"
        case .ntfy: "bell.badge.fill"
        case .pushover: "iphone.radiowaves.left.and.right"
        case .bark: "app.badge.fill"
        case .callmebot: "phone.bubble.fill"
        case .webhook: "point.3.connected.trianglepath.dotted"
        case .homeassistant: "house.fill"
        }
    }

    var summary: String {
        switch self {
        case .email: "Sends messages through your own SMTP server."
        case .telegram: "Posts through a Telegram bot to a chat, group or forum topic."
        case .discord: "Posts to a Discord channel using a channel webhook."
        case .ntfy: "Publishes to an ntfy topic on ntfy.sh or a self-hosted server."
        case .pushover: "Delivers push notifications through the Pushover service."
        case .bark: "Sends push notifications to the Bark iOS app."
        case .callmebot: "Sends WhatsApp messages through the free CallMeBot API."
        case .webhook: "POSTs JSON to any URL (generic or Slack/Mattermost format)."
        case .homeassistant: "Calls a Home Assistant service using the connection from Network settings."
        }
    }

    var fields: [SettingsNotificationConfigField] { SettingsNotificationConfigField.fields(for: self) }

    static func title(for raw: String) -> String { Self(rawValue: raw)?.title ?? raw }
    static func systemImage(for raw: String) -> String { Self(rawValue: raw)?.systemImage ?? "bell.fill" }
}

/// Describes one entry of a provider's `config` object.
struct SettingsNotificationConfigField: Sendable, Identifiable {
    enum Style: Sendable {
        case text, secret, number, multiline, url, email, phone
        case choice([(value: String, label: String)])
        case toggle
    }

    let key: String
    let label: String
    var placeholder: String = ""
    var style: Style = .text
    var required = false
    var help: String?
    /// Value the server assumes when the key is absent (used by choice/toggle fields).
    var defaultValue: String = ""
    /// Only shown when this returns true for the current config.
    var visibleIf: (@Sendable ([String: String]) -> Bool)?

    var id: String { key }

    func isVisible(_ config: [String: String]) -> Bool { visibleIf?(config) ?? true }

    static func fields(for kind: SettingsNotificationProviderKind) -> [SettingsNotificationConfigField] {
        switch kind {
        case .callmebot:
            return [
                .init(key: "phone", label: "Phone Number", placeholder: "+1234567890", style: .phone, required: true,
                      help: "Include the country code."),
                .init(key: "apikey", label: "API Key", placeholder: "CallMeBot API key", style: .secret, required: true),
            ]
        case .ntfy:
            return [
                .init(key: "server", label: "Server URL", placeholder: "https://ntfy.sh", style: .url,
                      help: "Leave empty to use ntfy.sh."),
                .init(key: "topic", label: "Topic", placeholder: "my-printers", required: true),
                .init(key: "auth_token", label: "Access Token", placeholder: "Optional", style: .secret),
            ]
        case .pushover:
            let emergency: @Sendable ([String: String]) -> Bool = { $0["priority"] == "2" }
            return [
                .init(key: "user_key", label: "User Key", placeholder: "Pushover user key", style: .secret, required: true),
                .init(key: "app_token", label: "Application Token", placeholder: "Pushover app token", style: .secret, required: true),
                .init(key: "priority", label: "Priority", style: .choice([
                    ("-2", "Lowest"), ("-1", "Low"), ("0", "Normal"), ("1", "High"), ("2", "Emergency"),
                ]), defaultValue: "0"),
                .init(key: "retry", label: "Repeat Every (seconds)", placeholder: "60", style: .number,
                      help: "Emergency alerts repeat until acknowledged; at least 30 seconds.", visibleIf: emergency),
                .init(key: "expire", label: "Stop Repeating After (seconds)", placeholder: "3600", style: .number,
                      help: "At most 10800 seconds (3 hours).", visibleIf: emergency),
            ]
        case .telegram:
            return [
                .init(key: "bot_token", label: "Bot Token", placeholder: "Token from @BotFather", style: .secret, required: true),
                .init(key: "chat_id", label: "Chat ID", placeholder: "Chat or group ID", required: true),
                .init(key: "message_thread_id", label: "Topic ID", placeholder: "Optional", style: .number,
                      help: "For forum groups: the topic to post in. Leave empty for the General topic."),
            ]
        case .email:
            let auth: @Sendable ([String: String]) -> Bool = { ($0["auth_enabled"] ?? "true").lowercased() != "false" }
            return [
                .init(key: "smtp_server", label: "SMTP Server", placeholder: "smtp.example.com", style: .url, required: true),
                .init(key: "security", label: "Security", style: .choice([
                    ("starttls", "STARTTLS"), ("ssl", "SSL/TLS"), ("none", "None"),
                ]), defaultValue: "starttls"),
                .init(key: "smtp_port", label: "Port", placeholder: "587", style: .number,
                      help: "Usually 587 for STARTTLS, 465 for SSL/TLS and 25 without encryption."),
                .init(key: "auth_enabled", label: "Authentication", style: .toggle, defaultValue: "true"),
                .init(key: "username", label: "Username", placeholder: "you@example.com", style: .email, visibleIf: auth),
                .init(key: "password", label: "Password", placeholder: "Password or app password", style: .secret, visibleIf: auth),
                .init(key: "from_email", label: "From", placeholder: "printer@example.com", style: .email, required: true),
                .init(key: "to_email", label: "To", placeholder: "you@example.com", style: .email, required: true),
            ]
        case .discord:
            return [
                .init(key: "webhook_url", label: "Webhook URL", placeholder: "https://discord.com/api/webhooks/…", style: .url, required: true),
            ]
        case .webhook:
            let generic: @Sendable ([String: String]) -> Bool = { $0["payload_format"] != "slack" }
            return [
                .init(key: "webhook_url", label: "URL", placeholder: "https://example.com/hook", style: .url, required: true),
                .init(key: "payload_format", label: "Payload", style: .choice([
                    ("generic", "Generic JSON"), ("slack", "Slack / Mattermost"),
                ]), defaultValue: "generic"),
                .init(key: "auth_header", label: "Authorization Header", placeholder: "e.g. Bearer abc123 (optional)", style: .secret),
                .init(key: "field_title", label: "Title Field", placeholder: "title", help: "JSON key used for the title.", visibleIf: generic),
                .init(key: "field_message", label: "Message Field", placeholder: "message", help: "JSON key used for the message.", visibleIf: generic),
            ]
        case .homeassistant:
            return [
                .init(key: "service", label: "Service", placeholder: "notify.mobile_app_my_phone",
                      help: "Leave empty to create a persistent notification in Home Assistant."),
                .init(key: "data", label: "Extra Service Data (JSON)", placeholder: #"{"priority": "high"}"#, style: .multiline,
                      help: "Optional JSON object passed as the service's data, e.g. push options for the mobile app."),
            ]
        case .bark:
            return [
                .init(key: "device_key", label: "Device Key", placeholder: "Bark device key", style: .secret, required: true),
                .init(key: "server", label: "Server URL", placeholder: "https://api.day.app", style: .url,
                      help: "Leave empty to use the public Bark server."),
                .init(key: "group", label: "Group", placeholder: "Optional"),
                .init(key: "sound", label: "Sound", placeholder: "Optional, e.g. minuet"),
                .init(key: "level", label: "Interruption Level", style: .choice([
                    ("", "Default"), ("active", "Active"), ("timeSensitive", "Time Sensitive"),
                    ("critical", "Critical"), ("passive", "Passive"),
                ])),
            ]
        }
    }
}

// MARK: - Editing

/// ntfy priority levels for `config.event_priorities`.
enum SettingsNotificationNtfyPriority {
    static let levels: [(value: Int, label: String)] = [(1, "Min"), (2, "Low"), (3, "Default"), (4, "High"), (5, "Urgent")]
}

/// Editable state of a provider and the request bodies built from it.
struct SettingsNotificationProviderDraft: Sendable, Hashable {
    var name = ""
    var providerType: String = SettingsNotificationProviderKind.email.rawValue
    var enabled = true
    /// Scalar config values, all as strings (the server reads them as strings).
    var config: [String: String] = [:]
    /// Non-scalar config values that the form doesn't edit (kept verbatim).
    var extraConfig: [String: JSONValue] = [:]
    /// ntfy per-event priority (keys are `on_*` event names, values 1–5).
    var eventPriorities: [String: Int] = [:]
    var events: [String: Bool] = Dictionary(uniqueKeysWithValues: SettingsNotificationEvent.all.map { ($0.key, $0.defaultOn) })
    var printerId: Int?
    var quietHoursEnabled = false
    var quietHoursStart = "22:00"
    var quietHoursEnd = "07:00"
    var dailyDigestEnabled = false
    var dailyDigestTime = "08:00"

    init() {}

    init(provider p: SettingsNotificationProvider) {
        name = p.name
        providerType = p.providerType
        enabled = p.enabled
        for (key, value) in p.config {
            if key == "event_priorities" {
                for (event, level) in value.objectValue ?? [:] {
                    if let n = level.intValue, (1...5).contains(n) { eventPriorities[event] = n }
                }
                continue
            }
            switch value {
            case .string, .number, .bool: config[key] = value.stringValue ?? ""
            case .null: break
            case .array, .object:
                // HA service data may have been stored as an object; edit it as JSON text.
                if key == "data", let text = Self.jsonText(value) { config[key] = text } else { extraConfig[key] = value }
            }
        }
        for event in SettingsNotificationEvent.all { events[event.key] = p.events[event.key] ?? false }
        printerId = p.printerId
        quietHoursEnabled = p.quietHoursEnabled
        quietHoursStart = p.quietHoursStart ?? "22:00"
        quietHoursEnd = p.quietHoursEnd ?? "07:00"
        dailyDigestEnabled = p.dailyDigestEnabled
        dailyDigestTime = p.dailyDigestTime ?? "08:00"
    }

    var kind: SettingsNotificationProviderKind? { SettingsNotificationProviderKind(rawValue: providerType) }

    private static func jsonText(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The `config` object to send: trimmed, empty values dropped (the server substitutes its
    /// defaults only for absent keys), hidden fields omitted, event priorities only for ntfy.
    var configPayload: [String: JSONValue] {
        var out = extraConfig
        let hidden = Set((kind?.fields ?? []).filter { !$0.isVisible(config) }.map(\.key))
        for (key, value) in config {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !hidden.contains(key) else { continue }
            out[key] = .string(trimmed)
        }
        if providerType == SettingsNotificationProviderKind.ntfy.rawValue {
            let enabledKeys = Set(events.filter(\.value).map(\.key))
            let relevant = eventPriorities.filter { enabledKeys.contains($0.key) && (1...5).contains($0.value) }
            if !relevant.isEmpty {
                out["event_priorities"] = .object(relevant.mapValues { .number(Double($0)) })
            }
        } else {
            out["event_priorities"] = nil
        }
        return out
    }

    /// Body for `POST /notifications/` and `PATCH /notifications/{id}`.
    func body(includeType: Bool = true) -> JSONValue {
        var body: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "enabled": .bool(enabled),
            "config": .object(configPayload),
            "printer_id": printerId.map { .number(Double($0)) } ?? .null,
            "quiet_hours_enabled": .bool(quietHoursEnabled),
            "quiet_hours_start": quietHoursEnabled ? .string(Self.normalizedTime(quietHoursStart) ?? "22:00") : .null,
            "quiet_hours_end": quietHoursEnabled ? .string(Self.normalizedTime(quietHoursEnd) ?? "07:00") : .null,
            "daily_digest_enabled": .bool(dailyDigestEnabled),
            "daily_digest_time": dailyDigestEnabled ? .string(Self.normalizedTime(dailyDigestTime) ?? "08:00") : .null,
        ]
        if includeType { body["provider_type"] = .string(providerType) }
        for event in SettingsNotificationEvent.all { body[event.key] = .bool(events[event.key] ?? event.defaultOn) }
        return .object(body)
    }

    /// Body for `POST /notifications/test-config`.
    var testBody: JSONValue {
        .object(["provider_type": .string(providerType), "config": .object(configPayload)])
    }

    /// The first problem that would stop the server (or the provider) from accepting this draft.
    var validationError: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "Enter a name." }
        if trimmedName.count > 100 { return "The name can be at most 100 characters." }
        if let problem = configValidationError { return problem }
        return nil
    }

    /// Problems with the provider-specific configuration only (used before testing).
    var configValidationError: String? {
        guard let kind else { return "Choose a provider type." }
        for field in kind.fields where field.required && field.isVisible(config) {
            if (config[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(field.label) is required."
            }
        }
        let value = { (key: String) in (config[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch kind {
        case .telegram:
            let thread = value("message_thread_id")
            if !thread.isEmpty, !thread.allSatisfy({ $0.isASCII && $0.isNumber }) { return "Topic ID must be a whole number." }
        case .homeassistant:
            let data = value("data")
            if !data.isEmpty {
                guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)), parsed.objectValue != nil else {
                    return "Extra service data must be a JSON object, like {\"priority\": \"high\"}."
                }
            }
        case .email:
            let port = value("smtp_port")
            if !port.isEmpty, Int(port) == nil { return "Port must be a number." }
        case .pushover where config["priority"] == "2":
            if let retry = Int(value("retry")), !(30...10800).contains(retry) { return "Repeat interval must be between 30 and 10800 seconds." }
            if let expire = Int(value("expire")), !(30...10800).contains(expire) { return "Expiry must be between 30 and 10800 seconds." }
            if !value("retry").isEmpty, Int(value("retry")) == nil { return "Repeat interval must be a number." }
            if !value("expire").isEmpty, Int(value("expire")) == nil { return "Expiry must be a number." }
        default:
            break
        }
        return nil
    }

    // MARK: Time helpers

    /// Normalizes "7:5" / "07:05" to "07:05"; nil when not a valid 24-hour time.
    static func normalizedTime(_ value: String) -> String? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    /// "HH:MM" → a date today at that time (in the given calendar's time zone).
    static func date(fromTime value: String, calendar: Calendar = .current, reference: Date = .now) -> Date {
        let normalized = normalizedTime(value) ?? "00:00"
        let parts = normalized.split(separator: ":").compactMap { Int($0) }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: reference) ?? reference
    }

    /// A date → "HH:MM" in the given calendar's time zone.
    static func time(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
