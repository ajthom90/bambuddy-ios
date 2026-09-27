import SwiftUI

// MARK: - Detail

struct FinanceCostCenterDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Environment(\.dismiss) private var dismiss
    let store: FinanceStore
    let centerID: Int

    @State private var detail: FinanceCostCenter?
    @State private var loadError: String?
    @State private var runner = ActionRunner()
    @State private var showEdit = false
    @State private var showAddMember = false
    @State private var confirmDelete = false
    @State private var pendingRemoval: FinanceCostCenterMember?

    private var perms: FinancePermissions { FinancePermissions(session: session) }
    private var center: FinanceCostCenter? { detail ?? store.center(centerID) }
    private var isAdmin: Bool { store.mode == .admin && perms.accessAllCenters }
    private var currency: String { store.currency }

    var body: some View {
        Group {
            if let center {
                content(center)
            } else if let loadError {
                ContentUnavailableView("Couldn't Load", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(center?.name ?? "Cost Center")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: live.revision("print_start", "print_complete", "archive_created", "billing_charge_failed")) { await load() }
        .refreshable { await load() }
        .toolbar {
            if let center, isAdmin, perms.modify {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit", systemImage: "pencil") { showEdit = true }
                        if !center.isPrivate {
                            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            if let center {
                FinanceCostCenterEditor(store: store, perms: perms, center: center) { Task { await reloadAll() } }
            }
        }
        .sheet(isPresented: $showAddMember) {
            if let center {
                FinanceAddMemberSheet(store: store, center: center) { Task { await load() } }
            }
        }
        .confirm("Delete \"\(center?.name ?? "")\"?", isPresented: $confirmDelete,
                 message: "Cost centers that still have transactions or active budget reservations can't be deleted.") {
            Task {
                var deleted = false
                await runner.run {
                    try await session.client.call(.delete, "finance/cost-centers/\(centerID)")
                    deleted = true
                }
                if deleted {
                    store.removeCenter(centerID)
                    dismiss()
                }
            }
        }
        .confirmationDialog("Remove Member?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { member in
            Button("Remove \(store.userName(member.userId, me: session.user))", role: .destructive) { remove(member) }
        }
        .actionAlerts(runner)
    }

    @ViewBuilder private func content(_ center: FinanceCostCenter) -> some View {
        List {
            Section {
                LabeledContent("Account Balance") {
                    Text((center.totalBalance ?? 0).formatted(.currency(code: currency)))
                        .monospacedDigit()
                        .foregroundStyle((center.totalBalance ?? 0) < 0 ? .red : .primary)
                }
                InfoRow("Type", center.isPrivate ? "Private" : "Shared")
                if center.isPrivate {
                    InfoRow("Owner", store.ownerLabel(center, me: session.user))
                }
                InfoRow("Status", center.isActive ? "Active" : "Inactive")
                if let canPrint = center.canPrint {
                    InfoRow("Printing", canPrint ? "Allowed" : "Not allowed")
                }
            }

            Section("Budget") {
                InfoRow("Budget Type", center.budgetModeLabel)
                if center.hasBudget {
                    InfoRow("Limit", center.budgetLimit.map { $0.formatted(.currency(code: currency)) })
                    InfoRow(center.budgetMode == "monthly" ? "Used This Period" : "Used", center.budgetUsed.map { $0.formatted(.currency(code: currency)) })
                    InfoRow("Available", center.budgetAvailable.map { $0.formatted(.currency(code: currency)) })
                    if let fraction = center.budgetFraction {
                        Gauge(value: fraction) {
                            Text("Used or reserved")
                        } currentValueLabel: {
                            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        }
                        .tint(fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .green)
                    }
                } else {
                    Text("No budget is set, so printing against this cost center is unlimited.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if isAdmin && !center.isPrivate {
                membersSection(center)
            }

            let related = store.transactions.filter { $0.costCenterId == center.id }
            if !related.isEmpty {
                Section {
                    ForEach(related) { tx in
                        NavigationLink(value: FinanceRoute.transaction(tx.id)) {
                            FinanceTransactionRow(transaction: tx, currency: currency, centerName: center.name,
                                                  userName: store.mode == .admin ? store.userName(tx.userId, me: session.user) : nil)
                        }
                    }
                } header: {
                    Text("Recent Transactions")
                } footer: {
                    Text("From the transactions loaded on the Finance page.")
                }
            }
        }
    }

    @ViewBuilder private func membersSection(_ center: FinanceCostCenter) -> some View {
        Section {
            let members = center.members ?? []
            if members.isEmpty {
                Text("No members assigned.").foregroundStyle(.secondary)
            }
            ForEach(members) { member in
                HStack {
                    Label(store.userName(member.userId, me: session.user), systemImage: "person")
                    Spacer()
                    if perms.canManageMembers {
                        Toggle("Can Print", isOn: Binding(
                            get: { member.canPrint },
                            set: { newValue in setCanPrint(member, newValue) }
                        ))
                        .labelsHidden()
                    } else {
                        Text(member.canPrint ? "Can print" : "View only").foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    if perms.canManageMembers {
                        Button("Remove", systemImage: "person.badge.minus", role: .destructive) { pendingRemoval = member }
                    }
                }
                .contextMenu {
                    if perms.canManageMembers {
                        Button("Remove", systemImage: "person.badge.minus", role: .destructive) { pendingRemoval = member }
                    }
                }
            }
            if perms.canManageMembers {
                Button("Add Member", systemImage: "person.badge.plus") { showAddMember = true }
            }
        } header: {
            Text("Members")
        } footer: {
            if perms.canManageMembers { Text("The switch controls whether a member may print against this cost center.") }
        }
    }

    // MARK: Actions

    private func load() async {
        #if DEBUG
        if store.isPreview {
            if var c = store.center(centerID), !c.isPrivate, c.members == nil {
                c.members = [FinanceCostCenterMember(id: 1, costCenterId: c.id, userId: 2, canPrint: true, createdAt: nil),
                             FinanceCostCenterMember(id: 2, costCenterId: c.id, userId: 3, canPrint: false, createdAt: nil)]
                detail = c
            }
            return
        }
        #endif
        guard isAdmin else { detail = nil; return }
        do {
            let value: FinanceCostCenter = try await session.client.get("finance/cost-centers/\(centerID)")
            detail = value
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func reloadAll() async {
        await load()
        await store.reload(client: session.client, perms: perms)
    }

    private func setCanPrint(_ member: FinanceCostCenterMember, _ value: Bool) {
        Task {
            await runner.run {
                let _: FinanceCostCenterMember = try await session.client.send(
                    .post, "finance/cost-centers/\(centerID)/members",
                    body: FinanceMemberUpsert(userId: member.userId, canPrint: value))
            }
            await load()
        }
    }

    private func remove(_ member: FinanceCostCenterMember) {
        Task {
            await runner.run("Member removed") {
                try await session.client.call(.delete, "finance/cost-centers/\(centerID)/members/\(member.userId)")
            }
            await load()
        }
    }
}

// MARK: - Create / edit

struct FinanceCostCenterEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let store: FinanceStore
    let perms: FinancePermissions
    let center: FinanceCostCenter?
    var onSaved: () -> Void

    @State private var name = ""
    @State private var budgetMode = "monthly"
    @State private var budgetValue: Double?
    @State private var isActive = true
    @State private var runner = ActionRunner()

    private var isNew: Bool { center == nil }
    private var isPrivate: Bool { center?.isPrivate ?? false }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .disabled(isPrivate)
                    if !isNew && !isPrivate {
                        Toggle("Active", isOn: $isActive)
                    }
                } footer: {
                    if isPrivate {
                        Text("Private cost centers can't be renamed or deactivated. Set a budget of 0 to stop printing against it.")
                    }
                }
                Section {
                    Picker("Budget Type", selection: $budgetMode) {
                        Text("No Budget").tag("none")
                        Text("Monthly").tag("monthly")
                        Text("Total").tag("total")
                    }
                    if budgetMode != "none" {
                        LabeledContent(budgetMode == "monthly" ? "Monthly Budget" : "Total Budget") {
                            TextField("0.00", value: $budgetValue, format: .number.precision(.fractionLength(0...2)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Budget")
                } footer: {
                    Text(budgetFooter)
                }
            }
            .navigationTitle(isNew ? "New Cost Center" : "Edit Cost Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { Task { await save() } }
                        .disabled(trimmedName.isEmpty || runner.isRunning)
                }
            }
            .onAppear(perform: populate)
            .actionAlerts(runner)
            .interactiveDismissDisabled(runner.isRunning)
        }
    }

    private func populate() {
        guard let center else { return }
        name = center.name
        isActive = center.isActive
        switch center.budgetMode {
        case "total":
            budgetMode = "total"; budgetValue = center.totalBudget ?? center.budgetLimit
        case "monthly":
            budgetMode = "monthly"; budgetValue = center.monthlyBudget ?? center.budgetLimit
        default:
            budgetMode = "none"; budgetValue = nil
        }
    }

    private var budgetFooter: String {
        switch budgetMode {
        case "monthly": return "Resets at the start of every budget period (the reset day is set in Settings). Amounts are in \(store.currency)."
        case "total": return "A fixed amount for the lifetime of the cost center. Amounts are in \(store.currency)."
        default: return "Printing is unlimited without a budget."
        }
    }

    private var monthly: Double? { budgetMode == "monthly" ? budgetValue : nil }
    private var total: Double? { budgetMode == "total" ? budgetValue : nil }

    private func save() async {
        var ok = false
        await runner.run {
            let client = session.client
            if let center {
                if !center.isPrivate && (trimmedName != center.name || isActive != center.isActive) {
                    let body: JSONValue = ["name": .string(trimmedName), "is_active": .bool(isActive)]
                    let updated: FinanceCostCenter = try await client.send(.patch, "finance/cost-centers/\(center.id)", body: body)
                    store.replaceCenter(updated)
                }
                let budgets: JSONValue = [
                    "monthly_budget": monthly.map { .number($0) } ?? .null,
                    "total_budget": total.map { .number($0) } ?? .null,
                ]
                let updated: FinanceCostCenter = try await client.send(.patch, "finance/cost-centers/\(center.id)/budgets", body: budgets)
                store.replaceCenter(updated)
            } else {
                let created: FinanceCostCenter = try await client.send(.post, "finance/cost-centers",
                    body: FinanceCostCenterCreate(name: trimmedName, totalBudget: total, monthlyBudget: monthly))
                store.replaceCenter(created)
            }
            ok = true
        }
        if ok {
            onSaved()
            dismiss()
        }
    }
}

// MARK: - Add member

private struct FinanceAddMemberSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let store: FinanceStore
    let center: FinanceCostCenter
    var onSaved: () -> Void

    @State private var userID: Int?
    @State private var canPrint = true
    @State private var runner = ActionRunner()

    private var candidates: [FinanceUserSlim] {
        let existing = Set((center.members ?? []).map(\.userId))
        return store.users.filter { !existing.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if candidates.isEmpty {
                    Text("Every user is already a member of this cost center.").foregroundStyle(.secondary)
                } else {
                    Picker("User", selection: $userID) {
                        Text("Select…").tag(Int?.none)
                        ForEach(candidates) { Text($0.username).tag(Optional($0.id)) }
                    }
                    Toggle("Can Print", isOn: $canPrint)
                }
            }
            .navigationTitle("Add Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }.disabled(userID == nil || runner.isRunning)
                }
            }
            .onAppear { if userID == nil { userID = candidates.first?.id } }
            .actionAlerts(runner)
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        guard let userID else { return }
        var ok = false
        await runner.run {
            let _: FinanceCostCenterMember = try await session.client.send(
                .post, "finance/cost-centers/\(center.id)/members",
                body: FinanceMemberUpsert(userId: userID, canPrint: canPrint))
            ok = true
        }
        if ok { onSaved(); dismiss() }
    }
}
