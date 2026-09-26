import Foundation

struct AuthStatus: Codable, Sendable, Equatable {
    var authEnabled: Bool
    var requiresSetup: Bool
}

struct AdvancedAuthStatus: Codable, Sendable {
    var advancedAuthEnabled: Bool?
    var smtpConfigured: Bool?
    var localLoginEnabled: Bool?
    var autologinProviderId: Int?
}

struct GroupBrief: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
}

struct User: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var username: String
    var email: String?
    var role: String
    var isActive: Bool
    var isAdmin: Bool
    var authSource: String?
    var groups: [GroupBrief]?
    var permissions: [String]?
    var createdAt: String?
}

struct LoginRequest: Encodable, Sendable {
    var username: String
    var password: String
}

struct LoginResponse: Decodable, Sendable {
    var accessToken: String?
    var tokenType: String?
    var user: User?
    var requires2fa: Bool?
    var preAuthToken: String?
    var twoFaMethods: [String]?

    init(from decoder: Decoder) throws {
        // Decode through JSONValue so the digit-bearing `requires_2fa` key does not
        // depend on how the snake_case strategy capitalizes "2fa".
        let raw = try JSONValue(from: decoder)
        accessToken = raw["access_token"]?.stringValue ?? raw["accessToken"]?.stringValue
        tokenType = raw["token_type"]?.stringValue ?? raw["tokenType"]?.stringValue
        user = try raw["user"].flatMap { $0.isNull ? nil : try $0.decode(User.self) }
        requires2fa = (raw["requires_2fa"] ?? raw["requires2fa"] ?? raw["requires2Fa"])?.boolValue
        preAuthToken = raw["pre_auth_token"]?.stringValue ?? raw["preAuthToken"]?.stringValue
        twoFaMethods = (raw["two_fa_methods"] ?? raw["twoFaMethods"])?.arrayValue?.compactMap(\.stringValue)
    }
}

struct TwoFAVerifyRequest: Encodable, Sendable {
    var preAuthToken: String
    var code: String
    var method: String
}

struct OIDCProvider: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var iconUrl: String?
}

struct TokenResponse: Decodable, Sendable { var token: String }
