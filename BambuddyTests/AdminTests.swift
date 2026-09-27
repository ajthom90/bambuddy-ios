import Testing
import Foundation
@testable import Bambuddy

struct AdminTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesGroupsAndPermissions() throws {
        let groups = try decode([AdminGroup].self, #"""
        [{"id":1,"name":"Administrators","description":"Full access","permissions":["printers:read","settings:update"],
          "is_system":true,"user_count":1,"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"},
         {"id":5,"name":"Viewers","description":null,"permissions":[],"is_system":false,"user_count":null,
          "users":[{"id":3,"username":"sam","email":null,"is_active":true}]}]
        """#)
        #expect(groups[0].isSystem)
        #expect(groups[1].users?.first?.username == "sam")

        let catalog = try decode(AdminPermissionCatalog.self, #"""
        {"categories":[{"name":"Printers","permissions":[{"value":"printers:read","label":"View printers"}]}],
         "all_permissions":["printers:read"]}
        """#)
        #expect(catalog.categories.first?.permissions.first?.id == "printers:read")

        let count = try decode(AdminUserItemsCount.self, #"{"archives":3,"queue_items":1,"library_files":null}"#)
        #expect(count.total == 4)
        let ldap = try decode([AdminLDAPUser].self, #"[{"username":"bob","email":null,"display_name":"Bob","dn":"uid=bob,dc=x","already_provisioned":false}]"#)
        #expect(ldap.first?.id == "uid=bob,dc=x")
        let ldapStatus = try decode(AdminLDAPStatus.self, #"{"ldap_enabled":false,"ldap_configured":null}"#)
        #expect(ldapStatus.ldapEnabled == false)
    }

    @Test func decodesAPIKeysAndCameraTokens() throws {
        let keys = try decode([AdminAPIKey].self, #"""
        [{"id":1,"name":"Home Assistant","key_prefix":"bb_abc","user_id":1,"can_queue":true,"can_control_printer":false,
          "can_read_status":true,"can_manage_library":false,"can_manage_inventory":false,"can_manage_maintenance":false,
          "can_manage_archives":false,"can_manage_projects":false,"can_access_cloud":false,"can_update_energy_cost":true,
          "printer_ids":null,"enabled":true,"last_used":null,"created_at":"2026-09-01T00:00:00","expires_at":"2020-01-01T00:00:00"}]
        """#)
        #expect(keys[0].isExpired)
        let scopes = AdminAPIKeyScopes(keys[0])
        #expect(scopes.labels == ["Read Status", "Queue Prints", "Energy Cost"])

        let tokens = try decode([AdminCameraToken].self, #"""
        [{"id":2,"user_id":1,"name":"Frigate","scope":"camera_stream","lookup_prefix":"ct_1","created_at":"2026-09-01T00:00:00",
          "expires_at":null,"last_used_at":null}]
        """#)
        #expect(!tokens[0].isExpired)
        #expect(tokens[0].name == "Frigate")
    }

    @Test func decodesAccountSecurity() throws {
        let status = try decode(AdminTwoFAStatus.self, #"{"totp_enabled":true,"email_otp_enabled":false,"backup_codes_remaining":8}"#)
        #expect(status.backupCodesRemaining == 8)
        let setup = try decode(AdminTOTPSetup.self, #"{"secret":"JBSWY3DP","qr_code_b64":"iVBOR","issuer":"Bambuddy"}"#)
        #expect(setup.qrCodeB64 == "iVBOR")
        let codes = try decode(AdminBackupCodes.self, #"{"backup_codes":["a1","b2"],"message":null}"#)
        #expect(codes.backupCodes.count == 2)
        let links = try decode([AdminOIDCLink].self, #"[{"id":1,"provider_id":2,"provider_name":"Authentik","provider_email":null,"created_at":null}]"#)
        #expect(links.first?.providerName == "Authentik")
        let otp = try decode(AdminEmailOTPSetup.self, #"{"message":"Code sent","setup_token":"tok"}"#)
        #expect(otp.setupToken == "tok")
    }
}
