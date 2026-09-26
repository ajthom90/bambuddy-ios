import Foundation

// MARK: Groups & permissions

struct AdminGroup: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var description: String?
    var permissions: [String]
    var isSystem: Bool
    var userCount: Int?
    var createdAt: String?
    var updatedAt: String?
    /// Only present on `GET /groups/{id}`.
    var users: [AdminGroupMember]?
}

struct AdminGroupMember: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var username: String
    var email: String?
    var isActive: Bool?
}

struct AdminGroupPayload: Encodable, Sendable {
    var name: String?
    var description: String?
    var permissions: [String]
}

struct AdminPermissionInfo: Codable, Sendable, Hashable, Identifiable {
    var value: String
    var label: String
    var id: String { value }
}

struct AdminPermissionCategory: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var permissions: [AdminPermissionInfo]
    var id: String { name }
}

struct AdminPermissionCatalog: Codable, Sendable {
    var categories: [AdminPermissionCategory]
    var allPermissions: [String]
}

// MARK: Users

struct AdminUserPayload: Encodable, Sendable {
    var username: String?
    var password: String?
    var email: String?
    var role: String?
    var isActive: Bool?
    var groupIds: [Int]?
}

struct AdminUserItemsCount: Codable, Sendable {
    var archives: Int?
    var queueItems: Int?
    var libraryFiles: Int?
    var total: Int { (archives ?? 0) + (queueItems ?? 0) + (libraryFiles ?? 0) }
}

struct AdminLDAPStatus: Codable, Sendable {
    var ldapEnabled: Bool?
    var ldapConfigured: Bool?
}

struct AdminLDAPUser: Codable, Sendable, Hashable, Identifiable {
    var username: String
    var email: String?
    var displayName: String?
    var dn: String
    var alreadyProvisioned: Bool?
    var id: String { dn }
}

struct AdminMessageResponse: Codable, Sendable {
    var message: String?
}

// MARK: API keys

struct AdminAPIKey: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var keyPrefix: String
    var userId: Int?
    var canQueue: Bool
    var canControlPrinter: Bool
    var canReadStatus: Bool
    var canManageLibrary: Bool
    var canManageInventory: Bool
    var canManageMaintenance: Bool
    var canManageArchives: Bool
    var canManageProjects: Bool
    var canAccessCloud: Bool
    var canUpdateEnergyCost: Bool
    var printerIds: [Int]?
    var enabled: Bool
    var lastUsed: String?
    var createdAt: String?
    var expiresAt: String?
    /// Plaintext secret; only returned once by `POST /api-keys/`.
    var key: String?

    var isExpired: Bool {
        guard let expiresAt, let d = APICoders.parseDate(expiresAt) else { return false }
        return d < Date()
    }
}

/// Scopes an API key can be granted, in display order.
struct AdminAPIKeyScopes: Codable, Sendable, Equatable {
    var canReadStatus = true
    var canQueue = true
    var canControlPrinter = false
    var canManageLibrary = true
    var canManageInventory = true
    var canManageMaintenance = true
    var canManageArchives = true
    var canManageProjects = true
    var canAccessCloud = false
    var canUpdateEnergyCost = false

    init() {}

    init(_ key: AdminAPIKey) {
        canReadStatus = key.canReadStatus
        canQueue = key.canQueue
        canControlPrinter = key.canControlPrinter
        canManageLibrary = key.canManageLibrary
        canManageInventory = key.canManageInventory
        canManageMaintenance = key.canManageMaintenance
        canManageArchives = key.canManageArchives
        canManageProjects = key.canManageProjects
        canAccessCloud = key.canAccessCloud
        canUpdateEnergyCost = key.canUpdateEnergyCost
    }

    static var all: [(WritableKeyPath<AdminAPIKeyScopes, Bool>, String, String)] { [
        (\.canReadStatus, "Read Status", "Read printer status and job progress"),
        (\.canQueue, "Queue Prints", "Add jobs to the print queue"),
        (\.canControlPrinter, "Control Printers", "Pause, resume and stop prints; other printer controls"),
        (\.canManageLibrary, "Library", "Upload and manage library files"),
        (\.canManageInventory, "Inventory", "Manage spools and filament inventory"),
        (\.canManageMaintenance, "Maintenance", "Log and manage maintenance tasks"),
        (\.canManageArchives, "Archives", "Manage print archives"),
        (\.canManageProjects, "Projects", "Manage projects"),
        (\.canAccessCloud, "Cloud Access", "Use the owner's Bambu Cloud connection"),
        (\.canUpdateEnergyCost, "Energy Cost", "Update the energy price used for cost tracking"),
    ] }

    var labels: [String] { Self.all.filter { self[keyPath: $0.0] }.map(\.1) }
}

struct AdminAPIKeyPayload: Encodable, Sendable {
    var name: String?
    var canQueue: Bool
    var canControlPrinter: Bool
    var canReadStatus: Bool
    var canManageLibrary: Bool
    var canManageInventory: Bool
    var canManageMaintenance: Bool
    var canManageArchives: Bool
    var canManageProjects: Bool
    var canAccessCloud: Bool
    var canUpdateEnergyCost: Bool
    var printerIds: [Int]?
    var enabled: Bool?
    var expiresAt: Date?

    init(name: String?, scopes: AdminAPIKeyScopes, printerIds: [Int]?, enabled: Bool?, expiresAt: Date?) {
        self.name = name
        canQueue = scopes.canQueue
        canControlPrinter = scopes.canControlPrinter
        canReadStatus = scopes.canReadStatus
        canManageLibrary = scopes.canManageLibrary
        canManageInventory = scopes.canManageInventory
        canManageMaintenance = scopes.canManageMaintenance
        canManageArchives = scopes.canManageArchives
        canManageProjects = scopes.canManageProjects
        canAccessCloud = scopes.canAccessCloud
        canUpdateEnergyCost = scopes.canUpdateEnergyCost
        self.printerIds = printerIds
        self.enabled = enabled
        self.expiresAt = expiresAt
    }

    // Always send `printer_ids` / `expires_at` (as null when cleared) so an
    // edit can remove a restriction.
    enum CodingKeys: String, CodingKey {
        case name, canQueue, canControlPrinter, canReadStatus, canManageLibrary, canManageInventory
        case canManageMaintenance, canManageArchives, canManageProjects, canAccessCloud, canUpdateEnergyCost
        case printerIds, enabled, expiresAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(canQueue, forKey: .canQueue)
        try c.encode(canControlPrinter, forKey: .canControlPrinter)
        try c.encode(canReadStatus, forKey: .canReadStatus)
        try c.encode(canManageLibrary, forKey: .canManageLibrary)
        try c.encode(canManageInventory, forKey: .canManageInventory)
        try c.encode(canManageMaintenance, forKey: .canManageMaintenance)
        try c.encode(canManageArchives, forKey: .canManageArchives)
        try c.encode(canManageProjects, forKey: .canManageProjects)
        try c.encode(canAccessCloud, forKey: .canAccessCloud)
        try c.encode(canUpdateEnergyCost, forKey: .canUpdateEnergyCost)
        try c.encode(printerIds, forKey: .printerIds)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encode(expiresAt, forKey: .expiresAt)
    }
}

// MARK: Long-lived camera tokens (`/auth/tokens`)

struct AdminCameraToken: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var userId: Int?
    var name: String
    var scope: String?
    var lookupPrefix: String?
    var createdAt: String?
    var expiresAt: String?
    var lastUsedAt: String?
    /// Plaintext; only present in the create response.
    var token: String?

    var isExpired: Bool {
        guard let expiresAt, let d = APICoders.parseDate(expiresAt) else { return false }
        return d < Date()
    }

    var scopeLabel: String { AdminCameraTokenScope(rawValue: scope ?? "")?.title ?? (scope ?? "Camera stream") }
}

enum AdminCameraTokenScope: String, CaseIterable, Identifiable, Sendable {
    case cameraStream = "camera_stream"
    case camwall
    case overlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cameraStream: "Camera Stream"
        case .camwall: "Camera Wall"
        case .overlay: "Streaming Overlay"
        }
    }

    var explanation: String {
        switch self {
        case .cameraStream:
            "Fetches camera streams and snapshots only. Suited to Home Assistant, Frigate or anything embedding one camera."
        case .camwall:
            "Opens the camera wall on a display without signing in. It sees every printer's name, state and camera, but no file names, addresses or access codes."
        case .overlay:
            "Opens a streaming overlay for one printer (for OBS and similar). It sees that printer's camera and live print status, including the file name, but no addresses or access codes."
        }
    }
}

struct AdminCameraTokenCreate: Encodable, Sendable {
    var name: String
    var expiresInDays: Int
    var scope: String
}

// MARK: Account security

struct AdminTwoFAStatus: Codable, Sendable, Equatable {
    var totpEnabled: Bool
    var emailOtpEnabled: Bool
    var backupCodesRemaining: Int
}

struct AdminTOTPSetup: Decodable, Sendable {
    var secret: String
    var qrCodeB64: String?
    var issuer: String?

    init(secret: String, qrCodeB64: String?, issuer: String?) {
        self.secret = secret
        self.qrCodeB64 = qrCodeB64
        self.issuer = issuer
    }

    init(from decoder: Decoder) throws {
        // `qr_code_b64` has a digit-bearing segment; read it through JSONValue so
        // the snake_case conversion's capitalization does not matter.
        let raw = try JSONValue(from: decoder)
        guard let secret = raw["secret"]?.stringValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing secret"))
        }
        self.secret = secret
        qrCodeB64 = (raw["qr_code_b64"] ?? raw["qrCodeB64"])?.stringValue
        issuer = raw["issuer"]?.stringValue
    }
}

struct AdminBackupCodes: Codable, Sendable {
    var backupCodes: [String]
    var message: String?
}

struct AdminOIDCLink: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var providerId: Int
    var providerName: String
    var providerEmail: String?
    var createdAt: String?
}

struct AdminEmailOTPSetup: Codable, Sendable {
    var message: String?
    var setupToken: String?
}
