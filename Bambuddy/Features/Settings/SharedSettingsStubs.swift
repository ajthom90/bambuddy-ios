import SwiftUI

// Screens owned by the Users/Admin feature, linked from Settings.
// Each is presented inside an existing NavigationStack (no stack of its own).

/// Users & groups administration (users, groups, permissions).
struct UsersAndGroupsView: View {
    var body: some View { OpenInWebView(title: "Users & Groups", webPath: "settings") }
}

/// API keys and camera tokens.
struct APIKeysView: View {
    var body: some View { OpenInWebView(title: "API Keys", webPath: "settings") }
}

/// Signed-in user's security: change password, 2FA, linked OIDC accounts.
struct AccountSecurityView: View {
    var body: some View { OpenInWebView(title: "Account Security", webPath: "settings") }
}
