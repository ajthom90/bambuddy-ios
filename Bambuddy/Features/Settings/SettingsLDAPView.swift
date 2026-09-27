import SwiftUI

/// LDAP / Active Directory sign-in configuration (stored in the `/settings/` blob as `ldap_*`).
struct SettingsLDAPView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store

    @State private var status = Loader<SettingsLDAPStatus>()
    @State private var groups: [GroupBrief]?
    @State private var draft = SettingsLDAPDraft()
    @State private var baseline = SettingsLDAPDraft()
    @State private var didSeed = false
    @State private var runner = ActionRunner()
    @State private var testResult: SettingsAuthMessageResponse?
    @State private var isTesting = false

    private var canEdit: Bool { store.canEdit }
    private var isDirty: Bool { draft != baseline }
    private var enabled: Bool { status.value?.ldapEnabled ?? store.bool("ldap_enabled") }

    var body: some View {
        Group {
            if store.hasLoaded {
                form
            } else if let error = store.loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Settings", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await store.load() } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("LDAP")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if runner.isRunning || store.isSaving {
                    ProgressView()
                } else if canEdit {
                    Button("Save") { Task { await save() } }.disabled(!isDirty || validation != nil)
                }
            }
        }
        .task {
            if !store.hasLoaded && !store.isLoading { await store.load() }
            seedIfNeeded()
            await loadStatus()
            await loadGroups()
        }
        .onChange(of: store.hasLoaded) { _, _ in seedIfNeeded() }
        .actionAlerts(runner)
        .modifier(SettingsAuthSaveErrorAlert())
    }

    private var form: some View {
        Form {
            statusSection
            serverSection
            provisioningSection
            mappingSection
            testSection
        }
        .refreshable {
            await store.load()
            reseed()
            await loadStatus()
            await loadGroups()
        }
        .disabled(!canEdit)
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            LabeledContent("Status") {
                StatusBadge(text: enabled ? "On" : "Off", color: enabled ? .green : .secondary)
            }
            if canEdit {
                if enabled {
                    Button("Turn Off LDAP Sign-In", role: .destructive) { Task { await setEnabled(false) } }
                } else {
                    Button("Turn On LDAP Sign-In") { Task { await setEnabled(true) } }
                        .disabled(!session.isAuthEnabled || status.value?.ldapConfigured != true || isDirty)
                }
            }
        } footer: {
            if enabled {
                Text("People can sign in with their directory credentials. Local accounts, including the administrator, keep working, and directory groups are mapped to Bambuddy groups at every sign-in.")
            } else if !session.isAuthEnabled {
                Text("Turn on authentication before enabling LDAP sign-in.")
            } else {
                Text("Enter and save the server details below, then turn LDAP sign-in on.")
            }
        }
    }

    private var serverSection: some View {
        Section {
            SettingsLDAPField(title: "Server URL", text: $draft.serverURL, prompt: "ldaps://ldap.example.com:636", keyboard: .URL)
            Picker("Security", selection: $draft.security) {
                Text("StartTLS").tag("starttls")
                Text("LDAPS").tag("ldaps")
                if !["starttls", "ldaps"].contains(draft.security) { Text(draft.security).tag(draft.security) }
            }
            SettingsLDAPField(title: "Bind DN", text: $draft.bindDN, prompt: "cn=bambuddy,ou=service,dc=example,dc=com")
            VStack(alignment: .leading, spacing: 4) {
                Text("Bind Password").font(.subheadline).foregroundStyle(.secondary)
                SecureField(baseline.bindDN.isEmpty ? "Password" : "Unchanged", text: $draft.bindPassword)
                    .textContentType(.password)
            }
            SettingsLDAPField(title: "Search Base", text: $draft.searchBase, prompt: "ou=users,dc=example,dc=com")
            SettingsLDAPField(title: "User Filter", text: $draft.userFilter, prompt: "(sAMAccountName={username})")
        } header: {
            Text("Directory Server")
        } footer: {
            Text("Use ldaps:// for a TLS connection (default port 636) or ldap:// with StartTLS (default port 389). The bind account is used to look people up; {username} in the filter is replaced with the name typed at sign-in. The bind password is never shown — leave it empty to keep the saved one.")
        }
    }

    private var provisioningSection: some View {
        Section {
            Toggle(isOn: $draft.autoProvision) {
                SettingsLabel("Create Accounts Automatically", help: "Make a Bambuddy account the first time someone signs in with LDAP.")
            }
            Picker("Fallback Group", selection: $draft.defaultGroup) {
                Text("None (deny sign-in)").tag("")
                ForEach(groupNames, id: \.self) { Text($0).tag($0) }
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("The fallback group is assigned when a directory user isn't in any mapped group. With no fallback, such users can't sign in.")
        }
    }

    private var mappingSection: some View {
        Section {
            ForEach($draft.mapping) { $row in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Directory group DN", text: $row.ldapGroup, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                    if let groups, !groups.isEmpty {
                        Picker("Bambuddy Group", selection: $row.bambuddyGroup) {
                            Text("Choose…").tag("")
                            ForEach(groupNames, id: \.self) { Text($0).tag($0) }
                            if !row.bambuddyGroup.isEmpty && !groupNames.contains(row.bambuddyGroup) {
                                Text("\(row.bambuddyGroup) (missing)").tag(row.bambuddyGroup)
                            }
                        }
                    } else {
                        TextField("Bambuddy group name", text: $row.bambuddyGroup)
                    }
                }
                .padding(.vertical, 2)
            }
            .onDelete { draft.mapping.remove(atOffsets: $0) }
            Button {
                draft.mapping.append(SettingsLDAPGroupMappingRow(ldapGroup: "", bambuddyGroup: ""))
            } label: {
                Label("Add Mapping", systemImage: "plus.circle")
            }
        } header: {
            Text("Group Mapping")
        } footer: {
            Text("Members of each directory group are placed in the chosen Bambuddy group when they sign in. Swipe a mapping to remove it. Incomplete rows are ignored when saving.")
        }
    }

    private var testSection: some View {
        Section {
            if let validation, isDirty {
                Label(validation, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.footnote)
            }
            Button {
                Task { await test() }
            } label: {
                HStack {
                    Text(isDirty ? "Save and Test Connection" : "Test Connection")
                    if isTesting { Spacer(); ProgressView() }
                }
            }
            .disabled(isTesting || (isDirty && validation != nil))
            if let testResult {
                SettingsTestResultLabel(success: testResult.success == true, message: testResult.message ?? (testResult.success == true ? "Connected" : "Connection failed"))
            }
        } footer: {
            Text("Connects with the saved settings and checks the bind account.")
        }
    }

    // MARK: Helpers

    private var groupNames: [String] {
        (groups ?? []).map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var validation: String? {
        if draft.serverURL.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the server URL." }
        if draft.searchBase.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the search base." }
        return nil
    }

    private func seedIfNeeded() {
        guard store.hasLoaded, !didSeed else { return }
        reseed()
    }

    private func reseed() {
        guard store.hasLoaded else { return }
        let fresh = SettingsLDAPDraft(store: store)
        // Keep unsaved edits across a refresh.
        if !didSeed || !isDirty { draft = fresh }
        baseline = fresh
        didSeed = true
    }

    private func loadStatus() async {
        let client = session.client
        await status.load { try await client.get("auth/ldap/status") }
    }

    private func loadGroups() async {
        if let list: [GroupBrief] = try? await session.client.get("groups/") { groups = list }
    }

    @discardableResult
    private func save() async -> Bool {
        let changes = draft.changes(from: baseline)
        guard !changes.isEmpty else { return true }
        let ok = await store.save(changes)
        if ok {
            baseline = SettingsLDAPDraft(store: store)
            draft = baseline
            await loadStatus()
            runner.successMessage = "LDAP settings saved"
        }
        return ok
    }

    private func setEnabled(_ on: Bool) async {
        if await store.save(["ldap_enabled": .bool(on)]) {
            runner.successMessage = on ? "LDAP sign-in turned on" : "LDAP sign-in turned off"
        }
        await loadStatus()
    }

    private func test() async {
        if isDirty {
            guard await save() else { return }
        }
        isTesting = true
        defer { isTesting = false }
        testResult = nil
        do {
            testResult = try await session.client.send(.post, "auth/ldap/test")
        } catch {
            testResult = SettingsAuthMessageResponse(success: false, message: error.localizedDescription)
        }
    }
}

/// Local edit state for the LDAP form.
struct SettingsLDAPDraft: Equatable {
    var serverURL = ""
    var security = "starttls"
    var bindDN = ""
    var bindPassword = ""
    var searchBase = ""
    var userFilter = "(sAMAccountName={username})"
    var autoProvision = false
    var defaultGroup = ""
    var mapping: [SettingsLDAPGroupMappingRow] = []

    init() {}

    @MainActor
    init(store: ServerSettingsStore) {
        serverURL = store.string("ldap_server_url")
        security = store.string("ldap_security", default: "starttls")
        bindDN = store.string("ldap_bind_dn")
        searchBase = store.string("ldap_search_base")
        userFilter = store.string("ldap_user_filter", default: "(sAMAccountName={username})")
        autoProvision = store.bool("ldap_auto_provision")
        defaultGroup = store.string("ldap_default_group")
        mapping = SettingsLDAPGroupMappingRow.parse(store.string("ldap_group_mapping"))
        if security.isEmpty { security = "starttls" }
    }

    /// Only the keys that differ from `base` (the bind password only when a new one was typed).
    func changes(from base: SettingsLDAPDraft) -> [String: JSONValue] {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out: [String: JSONValue] = [:]
        if trim(serverURL) != base.serverURL { out["ldap_server_url"] = .string(trim(serverURL)) }
        if security != base.security { out["ldap_security"] = .string(security) }
        if trim(bindDN) != base.bindDN { out["ldap_bind_dn"] = .string(trim(bindDN)) }
        if !bindPassword.isEmpty { out["ldap_bind_password"] = .string(bindPassword) }
        if trim(searchBase) != base.searchBase { out["ldap_search_base"] = .string(trim(searchBase)) }
        if trim(userFilter) != base.userFilter { out["ldap_user_filter"] = .string(trim(userFilter)) }
        if autoProvision != base.autoProvision { out["ldap_auto_provision"] = .bool(autoProvision) }
        if defaultGroup != base.defaultGroup { out["ldap_default_group"] = .string(defaultGroup) }
        let newMapping = SettingsLDAPGroupMappingRow.encode(mapping)
        if newMapping != SettingsLDAPGroupMappingRow.encode(base.mapping) { out["ldap_group_mapping"] = .string(newMapping) }
        return out
    }
}

private struct SettingsLDAPField: View {
    let title: String
    @Binding var text: String
    var prompt: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}
