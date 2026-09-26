import SwiftUI

/// Users & groups administration. Pushed from Settings (no NavigationStack of its own).
struct UsersAndGroupsView: View {
    @Environment(AppSession.self) private var session

    fileprivate enum Tab: String, CaseIterable, Identifiable {
        case users = "Users", groups = "Groups"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .users
    @State private var users = Loader<[User]>()
    @State private var groups = Loader<[AdminGroup]>()
    @State private var advancedAuth: AdvancedAuthStatus?
    @State private var ldap: AdminLDAPStatus?
    @State private var search = ""
    @State private var runner = ActionRunner()

    @State private var editingUser: AdminUserEditTarget?
    @State private var showLDAP = false
    @State private var newGroup = false
    @State private var deleteTarget: User?
    @State private var deleteCounts: AdminUserItemsCount?
    @State private var twoFATarget: User?
    @State private var adminPassword = ""
    @State private var groupToDelete: AdminGroup?

    var body: some View {
        List {
            if !session.isAuthEnabled {
                Section {
                    Label {
                        Text("Sign-in is off, so users and groups are not enforced. Enable authentication in the web interface to require sign-in.")
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(.blue)
                    }
                    .font(.footnote)
                }
            }
            switch tab {
            case .users: usersSection
            case .groups: groupsSection
            }
        }
        .navigationTitle("Users & Groups")
        .searchable(text: $search, prompt: tab == .users ? "Search users" : "Search groups")
        .safeAreaInset(edge: .top) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if session.can("users:create") {
                        Button { editingUser = .new } label: { Label("New User", systemImage: "person.badge.plus") }
                        if ldap?.ldapEnabled == true {
                            Button { showLDAP = true } label: { Label("Add from Directory (LDAP)", systemImage: "person.text.rectangle") }
                        }
                    }
                    if session.can("groups:create") {
                        Button { newGroup = true } label: { Label("New Group", systemImage: "person.3") }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(!session.can("users:create") && !session.can("groups:create"))
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .actionAlerts(runner)
        .sheet(item: $editingUser) { target in
            AdminUserEditor(target: target, groups: groups.value ?? [], advancedAuth: advancedAuth?.advancedAuthEnabled == true) {
                Task { await load() }
            }
        }
        .sheet(isPresented: $showLDAP) {
            AdminLDAPPicker { Task { await load() } }
        }
        .navigationDestination(isPresented: $newGroup) {
            AdminGroupEditor(groupId: nil) { Task { await load() } }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil; deleteCounts = nil } }), titleVisibility: .visible) {
            if let user = deleteTarget {
                if let counts = deleteCounts, counts.total > 0 {
                    Button("Delete User, Keep Their Items", role: .destructive) { Task { await deleteUser(user, items: false) } }
                    Button("Delete User and \(counts.total) Items", role: .destructive) { Task { await deleteUser(user, items: true) } }
                } else {
                    Button("Delete User", role: .destructive) { Task { await deleteUser(user, items: false) } }
                }
            }
        } message: {
            Text(deleteMessage)
        }
        .alert("Reset Two-Factor Authentication", isPresented: Binding(get: { twoFATarget != nil }, set: { if !$0 { twoFATarget = nil; adminPassword = "" } })) {
            SecureField("Your password", text: $adminPassword)
            Button("Cancel", role: .cancel) {}
            Button("Disable 2FA", role: .destructive) {
                if let user = twoFATarget { Task { await disable2FA(user) } }
            }
        } message: {
            Text("Removes the authenticator app and email codes for \(twoFATarget?.username ?? "this user") and signs them out everywhere. Enter your own password to confirm.")
        }
        .confirm("Delete \(groupToDelete?.name ?? "group")?", isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }),
                 message: "Members lose the permissions this group grants.") {
            if let g = groupToDelete { Task { await deleteGroup(g) } }
        }
        #if DEBUG
        .onAppear {
            if UserDefaults.standard.string(forKey: "adminTab") == "groups" { tab = .groups }
        }
        #endif
    }

    // MARK: Users

    @ViewBuilder
    private var usersSection: some View {
        if !session.can("users:read") {
            ContentUnavailableView("No Access", systemImage: "lock", description: Text("You don't have permission to view users."))
        } else {
            LoadingContent(loader: users, retry: load) { list in
                let filtered = list.filter { search.isEmpty || $0.username.localizedCaseInsensitiveContains(search) || ($0.email ?? "").localizedCaseInsensitiveContains(search) }
                if filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Users" : "No Matches", systemImage: "person.2",
                                           description: Text(search.isEmpty ? "Create a user to let people sign in." : "No users match “\(search)”."))
                } else {
                    Section {
                        ForEach(filtered) { user in
                            Button { if session.can("users:update") { editingUser = .edit(user) } } label: {
                                AdminUserRow(user: user, isSelf: user.id == session.user?.id)
                            }
                            .tint(.primary)
                            .swipeActions(edge: .trailing) {
                                if session.can("users:delete"), user.id != session.user?.id {
                                    Button(role: .destructive) { Task { await beginDelete(user) } } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if session.can("users:update"), user.id != session.user?.id {
                                    Button { Task { await setActive(user, !user.isActive) } } label: {
                                        Label(user.isActive ? "Deactivate" : "Activate", systemImage: user.isActive ? "person.crop.circle.badge.xmark" : "person.crop.circle.badge.checkmark")
                                    }
                                    .tint(user.isActive ? .orange : .green)
                                }
                            }
                            .contextMenu { userMenu(user) }
                        }
                    } footer: {
                        Text("\(filtered.count) user\(filtered.count == 1 ? "" : "s")")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func userMenu(_ user: User) -> some View {
        let isSelf = user.id == session.user?.id
        if session.can("users:update") {
            Button { editingUser = .edit(user) } label: { Label("Edit", systemImage: "pencil") }
            if !isSelf {
                Button { Task { await setActive(user, !user.isActive) } } label: {
                    Label(user.isActive ? "Deactivate" : "Activate", systemImage: user.isActive ? "pause.circle" : "play.circle")
                }
            }
            if advancedAuth?.advancedAuthEnabled == true, !(user.email ?? "").isEmpty, !isSelf {
                Button { Task { await resetPassword(user) } } label: { Label("Email New Password", systemImage: "envelope.arrow.triangle.branch") }
            }
            if session.isAuthEnabled {
                Button { twoFATarget = user } label: { Label("Reset Two-Factor…", systemImage: "lock.rotation") }
            }
        }
        if session.can("users:delete"), !isSelf {
            Divider()
            Button(role: .destructive) { Task { await beginDelete(user) } } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    private var deleteTitle: String { "Delete \(deleteTarget?.username ?? "user")?" }

    private var deleteMessage: String {
        guard let counts = deleteCounts, counts.total > 0 else { return "This cannot be undone." }
        var parts: [String] = []
        if let a = counts.archives, a > 0 { parts.append("\(a) archive\(a == 1 ? "" : "s")") }
        if let q = counts.queueItems, q > 0 { parts.append("\(q) queue item\(q == 1 ? "" : "s")") }
        if let l = counts.libraryFiles, l > 0 { parts.append("\(l) library file\(l == 1 ? "" : "s")") }
        return "This user created \(parts.joined(separator: ", ")). Keep them (unowned) or delete them too? This cannot be undone."
    }

    // MARK: Groups

    @ViewBuilder
    private var groupsSection: some View {
        if !session.can("groups:read") {
            ContentUnavailableView("No Access", systemImage: "lock", description: Text("You don't have permission to view groups."))
        } else {
            LoadingContent(loader: groups, retry: load) { list in
                let filtered = list.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.description ?? "").localizedCaseInsensitiveContains(search) }
                if filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Groups" : "No Matches", systemImage: "person.3")
                } else {
                    Section {
                        ForEach(filtered) { group in
                            NavigationLink {
                                AdminGroupEditor(groupId: group.id) { Task { await load() } }
                            } label: {
                                AdminGroupRow(group: group)
                            }
                            .swipeActions {
                                if session.can("groups:delete"), !group.isSystem {
                                    Button(role: .destructive) { groupToDelete = group } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                            .contextMenu {
                                if session.can("groups:delete"), !group.isSystem {
                                    Button(role: .destructive) { groupToDelete = group } label: { Label("Delete…", systemImage: "trash") }
                                }
                            }
                        }
                    } footer: {
                        Text("Permissions come from group membership. Members of Administrators have full access.")
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        let client = session.client
        async let adv = try? client.get("auth/advanced-auth/status", as: AdvancedAuthStatus.self)
        async let ld = try? client.get("auth/ldap/status", as: AdminLDAPStatus.self)
        if session.can("users:read") { await users.load { try await client.get("users/") } }
        if session.can("groups:read") { await groups.load { try await client.get("groups/") } }
        advancedAuth = await adv
        ldap = await ld
    }

    private func beginDelete(_ user: User) async {
        deleteCounts = try? await session.client.get("users/\(user.id)/items-count")
        deleteTarget = user
    }

    private func deleteUser(_ user: User, items: Bool) async {
        await runner.run("User deleted") {
            try await session.client.call(.delete, "users/\(user.id)", query: ["delete_items": .bool(items)])
            await load()
        }
    }

    private func setActive(_ user: User, _ active: Bool) async {
        await runner.run(active ? "User activated" : "User deactivated") {
            let _: User = try await session.client.send(.patch, "users/\(user.id)", body: AdminUserPayload(isActive: active))
            await load()
        }
    }

    private func resetPassword(_ user: User) async {
        struct Body: Encodable { var userId: Int }
        await runner.run {
            let r: AdminMessageResponse = try await session.client.send(.post, "auth/reset-password", body: Body(userId: user.id))
            runner.successMessage = r.message ?? "Password reset email sent"
        }
    }

    private func disable2FA(_ user: User) async {
        struct Body: Encodable { var adminPassword: String? }
        let password = adminPassword
        await runner.run("Two-factor disabled for \(user.username)") {
            try await session.client.call(.delete, "auth/2fa/admin/\(user.id)", body: Body(adminPassword: password.isEmpty ? nil : password))
        }
        adminPassword = ""
    }

    private func deleteGroup(_ group: AdminGroup) async {
        await runner.run("Group deleted") {
            try await session.client.call(.delete, "groups/\(group.id)")
            await load()
        }
    }
}

// MARK: - Rows

private struct AdminUserRow: View {
    let user: User
    let isSelf: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: user.isAdmin ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .font(.title2)
                .foregroundStyle(user.isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(user.username).font(.body.weight(.medium))
                    if isSelf { Text("You").font(.caption).foregroundStyle(.secondary) }
                }
                if let email = user.email, !email.isEmpty {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
                FlowBadges(user: user)
            }
            Spacer()
            if !user.isActive { StatusBadge(text: "Inactive", color: .red) }
        }
        .padding(.vertical, 2)
    }

    private struct FlowBadges: View {
        let user: User
        var body: some View {
            HStack(spacing: 4) {
                if user.isAdmin { StatusBadge(text: "Admin", color: .purple) }
                if user.authSource == "ldap" { StatusBadge(text: "LDAP", color: .teal) }
                if user.authSource == "oidc" { StatusBadge(text: "SSO", color: .teal) }
                ForEach((user.groups ?? []).prefix(3)) { g in
                    StatusBadge(text: g.name, color: AdminGroup(id: g.id, name: g.name, permissions: [], isSystem: false).badgeColor)
                }
                if (user.groups?.count ?? 0) > 3 { Text("+\((user.groups?.count ?? 0) - 3)").font(.caption2).foregroundStyle(.secondary) }
                if (user.groups ?? []).isEmpty && !user.isAdmin { Text("No groups").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct AdminGroupRow: View {
    let group: AdminGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(group.name).font(.body.weight(.medium))
                if group.isSystem { StatusBadge(text: "Built-in", color: group.badgeColor) }
            }
            Text(group.description?.isEmpty == false ? group.description! : "No description")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 12) {
                Label("\(group.userCount ?? 0)", systemImage: "person.2")
                Label("\(group.permissions.count) permissions", systemImage: "key")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - User editor

fileprivate enum AdminUserEditTarget: Identifiable {
    case new
    case edit(User)
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let u): "user-\(u.id)"
        }
    }
}

private struct AdminUserEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let target: AdminUserEditTarget
    let groups: [AdminGroup]
    let advancedAuth: Bool
    var onSave: () -> Void

    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var isActive = true
    @State private var groupIds: Set<Int> = []
    @State private var runner = ActionRunner()

    private var existing: User? { if case .edit(let u) = target { return u }; return nil }
    private var isNew: Bool { existing == nil }
    private var isLDAP: Bool { existing?.authSource == "ldap" }
    private var isSelf: Bool { existing != nil && existing?.id == session.user?.id }

    private var passwordProblem: String? {
        if password.isEmpty { return isNew && !advancedAuth ? "" : nil }
        if let p = AdminPasswordPolicy.problem(password) { return p }
        if password != confirm { return "Passwords don't match." }
        return nil
    }

    private var canSave: Bool {
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if isNew && advancedAuth && email.isEmpty { return false }
        return passwordProblem == nil && !runner.isRunning
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Username", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(isLDAP)
                    TextField(advancedAuth && isNew ? "Email (required)" : "Email", text: $email)
                        .keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if existing != nil, !isSelf {
                        Toggle("Active", isOn: $isActive)
                    }
                }
                if isLDAP {
                    Section {
                        Label("This account signs in through the LDAP directory; its password is managed there.", systemImage: "person.text.rectangle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if isNew && advancedAuth {
                    Section {
                        Label("A password will be generated and emailed to the user.", systemImage: "envelope")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        SecureField(isNew ? "Password" : "New password (optional)", text: $password)
                            .textContentType(.newPassword)
                        if !password.isEmpty {
                            SecureField("Confirm password", text: $confirm).textContentType(.newPassword)
                        }
                    } header: {
                        Text("Password")
                    } footer: {
                        if let p = passwordProblem, !p.isEmpty {
                            Text(p).foregroundStyle(.red)
                        } else {
                            Text("At least 8 characters with upper- and lowercase letters, a digit and a symbol.")
                        }
                    }
                }
                Section {
                    if groups.isEmpty {
                        Text("No groups available").foregroundStyle(.secondary)
                    }
                    ForEach(groups) { group in
                        Button {
                            if groupIds.contains(group.id) { groupIds.remove(group.id) } else { groupIds.insert(group.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(group.name).foregroundStyle(.primary)
                                        if group.isSystem { StatusBadge(text: "Built-in", color: group.badgeColor) }
                                    }
                                    if let d = group.description, !d.isEmpty {
                                        Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer()
                                Image(systemName: groupIds.contains(group.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(groupIds.contains(group.id) ? Color.accentColor : .secondary)
                                    .font(.title3)
                            }
                        }
                    }
                } header: {
                    Text("Groups")
                } footer: {
                    Text("A user's permissions are the combination of all their groups.")
                }
            }
            .navigationTitle(isNew ? "New User" : "Edit User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { Task { await save() } }.disabled(!canSave)
                }
            }
            .actionAlerts(runner)
            .onAppear(perform: populate)
        }
    }

    private func populate() {
        guard let u = existing else { return }
        username = u.username
        email = u.email ?? ""
        isActive = u.isActive
        groupIds = Set((u.groups ?? []).map(\.id))
    }

    private func save() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        await runner.run {
            if let u = existing {
                var body = AdminUserPayload(
                    username: username != u.username ? username : nil,
                    password: password.isEmpty ? nil : password,
                    email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                    groupIds: Array(groupIds).sorted()
                )
                if !isSelf { body.isActive = isActive }
                let _: User = try await session.client.send(.patch, "users/\(u.id)", body: body)
            } else {
                let body = AdminUserPayload(
                    username: username,
                    password: advancedAuth ? nil : password,
                    email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                    role: "user",
                    groupIds: groupIds.isEmpty ? nil : Array(groupIds).sorted()
                )
                try await session.client.call(.post, "users/", body: body)
            }
            onSave()
            dismiss()
        }
    }
}

// MARK: - LDAP directory picker

private struct AdminLDAPPicker: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var onProvision: () -> Void

    @State private var query = ""
    @State private var results: [AdminLDAPUser] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            List {
                if query.count < 2 {
                    ContentUnavailableView("Search the Directory", systemImage: "magnifyingglass",
                                           description: Text("Type at least two characters of a name, username or email."))
                } else if let searchError {
                    ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(searchError))
                } else if results.isEmpty && !searching {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(results) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.displayName?.isEmpty == false ? r.displayName! : r.username).font(.body.weight(.medium))
                            Text([r.username, r.email].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if r.alreadyProvisioned == true {
                            StatusBadge(text: "Added", color: .secondary)
                        } else {
                            Button("Add") { Task { await provision(r) } }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .disabled(runner.isRunning)
                        }
                    }
                }
            }
            .overlay { if searching { ProgressView() } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, username or email")
            .task(id: query) { await search() }
            .navigationTitle("Add from LDAP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .actionAlerts(runner)
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await session.client.get("auth/ldap/search", query: ["q": .string(q)])
            searchError = nil
        } catch is CancellationError {
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func provision(_ r: AdminLDAPUser) async {
        struct Body: Encodable { var username: String }
        await runner.run("Added \(r.username)") {
            try await session.client.call(.post, "auth/ldap/provision", body: Body(username: r.username))
            if let i = results.firstIndex(of: r) { results[i].alreadyProvisioned = true }
            onProvision()
        }
    }
}

// MARK: - Group editor (permission matrix)

struct AdminGroupEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let groupId: Int?
    var onSave: () -> Void

    @State private var catalog = Loader<AdminPermissionCatalog>()
    @State private var group: AdminGroup?
    @State private var name = ""
    @State private var description = ""
    @State private var permissions: Set<String> = []
    @State private var original: Set<String> = []
    @State private var search = ""
    @State private var initialized = false
    @State private var runner = ActionRunner()

    private var canEdit: Bool { groupId == nil ? session.can("groups:create") : session.can("groups:update") }

    var body: some View {
        LoadingContent(loader: catalog, retry: load) { catalog in
            Form {
                if group?.isSystem == true {
                    Section {
                        Label("This is a built-in group. Its name can't be changed; edit its permissions with care.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section("Group") {
                    TextField("Name", text: $name).disabled(group?.isSystem == true || !canEdit)
                    TextField("Description", text: $description, axis: .vertical).disabled(!canEdit)
                }
                if let members = group?.users, !members.isEmpty {
                    Section("Members (\(members.count))") {
                        ForEach(members) { m in
                            HStack {
                                Text(m.username)
                                Spacer()
                                if m.isActive == false { StatusBadge(text: "Inactive", color: .red) }
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        Text("\(permissions.count) of \(catalog.allPermissions.count) selected")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("All") { permissions = Set(catalog.allPermissions) }.buttonStyle(.borderless).disabled(!canEdit)
                        Text("·").foregroundStyle(.secondary)
                        Button("None") { permissions = [] }.buttonStyle(.borderless).disabled(!canEdit)
                    }
                }
                ForEach(filtered(catalog.categories)) { category in
                    Section {
                        ForEach(category.permissions) { perm in
                            Toggle(isOn: Binding(
                                get: { permissions.contains(perm.value) },
                                set: { if $0 { permissions.insert(perm.value) } else { permissions.remove(perm.value) } }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(perm.label)
                                    Text(perm.value).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!canEdit)
                        }
                    } header: {
                        categoryHeader(category)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Filter permissions")
        .navigationTitle(groupId == nil ? "New Group" : (name.isEmpty ? "Group" : name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .confirmationAction) {
                    Button(groupId == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                }
            }
        }
        .actionAlerts(runner)
        .task { await load() }
    }

    private func categoryHeader(_ category: AdminPermissionCategory) -> some View {
        let values = Set(category.permissions.map(\.value))
        let selected = values.intersection(permissions).count
        let all = selected == values.count
        return HStack {
            Text(category.name)
            Text("\(selected)/\(values.count)").foregroundStyle(.secondary)
            Spacer()
            if canEdit {
                Button(all ? "Clear" : "Select All") {
                    if all { permissions.subtract(values) } else { permissions.formUnion(values) }
                }
                .font(.caption.weight(.semibold))
                .textCase(nil)
                .buttonStyle(.borderless)
            }
        }
    }

    private func filtered(_ categories: [AdminPermissionCategory]) -> [AdminPermissionCategory] {
        guard !search.isEmpty else { return categories }
        return categories.compactMap { cat in
            if cat.name.localizedCaseInsensitiveContains(search) { return cat }
            let perms = cat.permissions.filter { $0.label.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) }
            return perms.isEmpty ? nil : AdminPermissionCategory(name: cat.name, permissions: perms)
        }
    }

    private func load() async {
        let client = session.client
        await catalog.load { try await client.get("groups/permissions") }
        guard !initialized else { return }
        if let groupId {
            do {
                let g: AdminGroup = try await client.get("groups/\(groupId)")
                group = g
                name = g.name
                description = g.description ?? ""
                permissions = Set(g.permissions)
                original = permissions
                initialized = true
            } catch {
                catalog.error = error.localizedDescription
                catalog.value = nil
            }
        } else {
            initialized = true
        }
    }

    private func save() async {
        await runner.run(groupId == nil ? "Group created" : "Group saved") {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if let groupId {
                let body = AdminGroupPayload(name: trimmed != group?.name ? trimmed : nil, description: description, permissions: Array(permissions).sorted())
                let _: AdminGroup = try await session.client.send(.patch, "groups/\(groupId)", body: body)
            } else {
                let body = AdminGroupPayload(name: trimmed, description: description.isEmpty ? nil : description, permissions: Array(permissions).sorted())
                try await session.client.call(.post, "groups/", body: body)
            }
            onSave()
            dismiss()
        }
    }
}
