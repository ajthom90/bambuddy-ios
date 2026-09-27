import Foundation

// MARK: - Authentication administration models

/// `GET /auth/ldap/status`.
struct SettingsLDAPStatus: Codable, Sendable, Equatable {
    var ldapEnabled: Bool?
    var ldapConfigured: Bool?
}

/// Row counts in `GET /auth/encryption-status`.
struct SettingsAuthEncryptionRowCounts: Codable, Sendable, Equatable {
    var oidcProviders: Int?
    var userTotp: Int?

    var total: Int { (oidcProviders ?? 0) + (userTotp ?? 0) }
}

/// `GET /auth/encryption-status` — at-rest encryption of OIDC client secrets and TOTP seeds.
struct SettingsAuthEncryptionStatus: Codable, Sendable, Equatable {
    var keyConfigured: Bool?
    /// `env`, `file`, `generated` or `none`.
    var keySource: String?
    var legacyPlaintextRows: SettingsAuthEncryptionRowCounts?
    var encryptedRows: SettingsAuthEncryptionRowCounts?
    var decryptionBroken: Bool?
    var migrationErrorCount: Int?

    enum Severity: Equatable { case critical, warning, good, inactive }

    var legacyTotal: Int { legacyPlaintextRows?.total ?? 0 }
    var encryptedTotal: Int { encryptedRows?.total ?? 0 }

    /// Overall health, most severe condition first.
    var severity: Severity {
        if decryptionBroken == true { return .critical }
        if keySource == "generated" || legacyTotal > 0 { return .warning }
        if keyConfigured == true { return .good }
        return .inactive
    }
}

/// `POST /auth/setup` body.
struct SettingsAuthSetupRequest: Encodable, Sendable {
    var authEnabled: Bool
    var adminUsername: String?
    var adminPassword: String?
}

/// `POST /auth/setup` response.
struct SettingsAuthSetupResponse: Codable, Sendable {
    var authEnabled: Bool?
    var adminCreated: Bool?
}

/// Generic `{success?, message?}` responses (LDAP test, advanced-auth toggles, disable auth…).
struct SettingsAuthMessageResponse: Codable, Sendable {
    var success: Bool?
    var message: String?
}

/// Full OIDC provider record as returned to administrators (`GET /auth/oidc/providers/all`).
struct SettingsOIDCProviderRecord: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var issuerUrl: String?
    var clientId: String?
    var scopes: String?
    var isEnabled: Bool?
    var autoCreateUsers: Bool?
    var autoLinkExistingAccounts: Bool?
    var emailClaim: String?
    var requireEmailVerified: Bool?
    var iconUrl: String?
    var defaultGroupId: Int?
    var isAutologin: Bool?
    var isEnvManaged: Bool?
    var hasIcon: Bool?
}

/// Editable form state for creating or editing an OIDC provider.
struct SettingsOIDCProviderDraft: Equatable, Sendable {
    var name = ""
    var issuerUrl = ""
    var clientId = ""
    var clientSecret = ""
    var scopes = "openid email profile"
    var isEnabled = true
    var autoCreateUsers = false
    var autoLinkExistingAccounts = false
    var emailClaim = "email"
    var requireEmailVerified = true
    var iconUrl = ""
    var defaultGroupId: Int?
    var isAutologin = false

    init() {}

    init(_ provider: SettingsOIDCProviderRecord) {
        name = provider.name
        issuerUrl = provider.issuerUrl ?? ""
        clientId = provider.clientId ?? ""
        scopes = provider.scopes ?? "openid email profile"
        isEnabled = provider.isEnabled ?? true
        autoCreateUsers = provider.autoCreateUsers ?? false
        autoLinkExistingAccounts = provider.autoLinkExistingAccounts ?? false
        emailClaim = provider.emailClaim ?? "email"
        requireEmailVerified = provider.requireEmailVerified ?? true
        iconUrl = provider.iconUrl ?? ""
        defaultGroupId = provider.defaultGroupId
        isAutologin = provider.isAutologin ?? false
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Auto-linking by the standard `email` claim is only allowed with verified emails.
    var violatesAutoLinkRule: Bool {
        autoLinkExistingAccounts && Self.trimmed(emailClaim).isEmpty == false && Self.trimmed(emailClaim) == "email" && !requireEmailVerified
    }

    func isValid(isEdit: Bool) -> Bool {
        !Self.trimmed(name).isEmpty && !Self.trimmed(issuerUrl).isEmpty && !Self.trimmed(clientId).isEmpty
            && (isEdit || !clientSecret.isEmpty) && !violatesAutoLinkRule
    }

    /// Body for `POST /auth/oidc/providers`.
    func createBody() -> JSONValue {
        var body = commonFields()
        body["client_secret"] = .string(clientSecret)
        let icon = Self.trimmed(iconUrl)
        body["icon_url"] = icon.isEmpty ? .null : .string(icon)
        return .object(body)
    }

    /// Body for `PUT /auth/oidc/providers/{id}`. The secret is only sent when replaced, and an
    /// explicit `icon_url: null` clears a previously configured icon.
    func updateBody(original: SettingsOIDCProviderRecord) -> JSONValue {
        var body = commonFields()
        if !clientSecret.isEmpty { body["client_secret"] = .string(clientSecret) }
        let icon = Self.trimmed(iconUrl)
        if !icon.isEmpty {
            body["icon_url"] = .string(icon)
        } else if !(original.iconUrl ?? "").isEmpty {
            body["icon_url"] = .null
        }
        return .object(body)
    }

    private func commonFields() -> [String: JSONValue] {
        let claim = Self.trimmed(emailClaim)
        var body: [String: JSONValue] = [
            "name": .string(Self.trimmed(name)),
            "issuer_url": .string(Self.trimmed(issuerUrl)),
            "client_id": .string(Self.trimmed(clientId)),
            "scopes": .string(Self.trimmed(scopes).isEmpty ? "openid email profile" : Self.trimmed(scopes)),
            "is_enabled": .bool(isEnabled),
            "auto_create_users": .bool(autoCreateUsers),
            "auto_link_existing_accounts": .bool(autoLinkExistingAccounts),
            "email_claim": .string(claim.isEmpty ? "email" : claim),
            "require_email_verified": .bool(requireEmailVerified),
            "is_autologin": .bool(isAutologin),
        ]
        if let defaultGroupId { body["default_group_id"] = .number(Double(defaultGroupId)) }
        return body
    }
}

/// One row of the LDAP → Bambuddy group mapping (`ldap_group_mapping` is stored as a JSON object
/// string: `{"<ldap group DN>": "<Bambuddy group name>"}`).
struct SettingsLDAPGroupMappingRow: Identifiable, Equatable, Sendable {
    var id = UUID()
    var ldapGroup: String
    var bambuddyGroup: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ldapGroup == rhs.ldapGroup && lhs.bambuddyGroup == rhs.bambuddyGroup
    }

    /// Parses the stored setting. Invalid or non-object JSON yields no rows.
    static func parse(_ raw: String) -> [SettingsLDAPGroupMappingRow] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "None", let data = trimmed.data(using: .utf8),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else { return [] }
        return object.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { key in
            SettingsLDAPGroupMappingRow(ldapGroup: key, bambuddyGroup: object[key]?.stringValue ?? "")
        }
    }

    /// Encodes rows back into the compact JSON string the server expects. Rows with an empty DN or
    /// group are dropped; no rows means an empty string (no mapping).
    static func encode(_ rows: [SettingsLDAPGroupMappingRow]) -> String {
        var map: [String: String] = [:]
        for row in rows {
            let dn = row.ldapGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            let group = row.bambuddyGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dn.isEmpty, !group.isEmpty else { continue }
            map[dn] = group
        }
        guard !map.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(map) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `GET /auth/smtp` / `POST /auth/smtp`. The server never returns the password; an empty
/// password on save keeps the stored one.
struct SettingsSMTPConfig: Codable, Sendable, Equatable {
    var smtpHost: String?
    var smtpPort: Int?
    var smtpUsername: String?
    var smtpPassword: String?
    /// `starttls`, `ssl` or `none`.
    var smtpSecurity: String?
    var smtpAuthEnabled: Bool?
    var smtpFromEmail: String?
    var smtpFromName: String?
    /// Deprecated (pre-`smtp_security` servers).
    var smtpUseTls: Bool?

    static func defaultPort(for security: String) -> Int {
        switch security {
        case "ssl": 465
        case "none": 25
        default: 587
        }
    }

    static func security(forPort port: Int) -> String? {
        switch port {
        case 587: "starttls"
        case 465: "ssl"
        case 25: "none"
        default: nil
        }
    }
}

/// `POST /auth/smtp/test` body.
struct SettingsSMTPTestRequest: Encodable, Sendable {
    var testRecipient: String
}
