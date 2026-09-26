import SwiftUI

// MARK: - Detail

struct FinanceTransactionDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let store: FinanceStore
    let transactionID: Int

    @State private var runner = ActionRunner()
    @State private var showEdit = false
    @State private var confirmDelete = false

    private var perms: FinancePermissions { FinancePermissions(session: session) }
    private var transaction: FinanceTransaction? { store.transactions.first { $0.id == transactionID } }
    private var currency: String { store.currency }

    var body: some View {
        Group {
            if let tx = transaction {
                content(tx)
            } else {
                ContentUnavailableView("Transaction Unavailable", systemImage: "doc.questionmark",
                                       description: Text("It may have been deleted or is no longer loaded."))
            }
        }
        .navigationTitle(transaction.map { $0.kind == .other ? $0.transactionType : $0.kind.label } ?? "Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if transaction != nil, store.mode == .admin, perms.modify {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit", systemImage: "pencil") { showEdit = true }
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            if let transaction {
                FinanceTransactionEditor(store: store, transaction: transaction) {
                    Task { await store.reload(client: session.client, perms: perms) }
                }
            }
        }
        .confirm("Delete Transaction?", isPresented: $confirmDelete, message: "Balances will be recalculated automatically.") {
            Task {
                var deleted = false
                await runner.run {
                    try await session.client.call(.delete, "finance/transactions/\(transactionID)")
                    deleted = true
                }
                if deleted {
                    dismiss()
                    await store.reload(client: session.client, perms: perms)
                }
            }
        }
        .actionAlerts(runner)
    }

    private func content(_ tx: FinanceTransaction) -> some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: tx.kind.systemImage)
                        .font(.largeTitle)
                        .foregroundStyle(tx.amount >= 0 ? .green : .red)
                    Text(tx.amount.formatted(.currency(code: currency).sign(strategy: .always())))
                        .font(.largeTitle.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tx.amount >= 0 ? .green : .red)
                    if let status = tx.partialStatus {
                        StatusBadge(text: "Partial print · \(status.capitalized)", color: .yellow)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                InfoRow("Type", tx.kind == .other ? tx.transactionType : tx.kind.label)
                InfoRow("Date", tx.createdAt?.formatted(date: .long, time: .shortened))
                InfoRow("Description", tx.displayDescription)
                InfoRow("Balance After", tx.balanceAfter.map { $0.formatted(.currency(code: currency)) })
            }
            Section("Account") {
                InfoRow("User", store.userName(tx.userId, me: session.user))
                if let id = tx.costCenterId {
                    if store.center(id) != nil {
                        NavigationLink(value: FinanceRoute.costCenter(id)) {
                            InfoRow("Cost Center", store.center(id)?.name)
                        }
                    } else {
                        InfoRow("Cost Center", "#\(id)")
                    }
                } else {
                    InfoRow("Cost Center", "Personal account")
                }
                if let by = tx.createdByUserId {
                    InfoRow("Recorded By", store.userName(by, me: session.user))
                }
            }
            if tx.printArchiveId != nil || tx.printQueueId != nil || tx.printRunId != nil {
                Section("Print") {
                    if let id = tx.printArchiveId { InfoRow("Archive", "#\(id)") }
                    if let id = tx.printQueueId { InfoRow("Queue Item", "#\(id)") }
                    if let run = tx.printRunId { InfoRow("Run ID", run) }
                }
            }
        }
    }
}

// MARK: - Shared form pieces

private struct FinanceUserPicker: View {
    let users: [FinanceUserSlim]
    var title = "User"
    var noneLabel = "Select…"
    @Binding var selection: Int?

    var body: some View {
        Picker(title, selection: $selection) {
            Text(noneLabel).tag(Int?.none)
            ForEach(users) { Text($0.username).tag(Optional($0.id)) }
            if let selection, !users.contains(where: { $0.id == selection }) {
                Text("User #\(selection)").tag(Optional(selection))
            }
        }
    }
}

private struct FinanceCenterPicker: View {
    let centers: [FinanceCostCenter]
    var noneLabel: String
    @Binding var selection: Int?

    var body: some View {
        Picker("Cost Center", selection: $selection) {
            Text(noneLabel).tag(Int?.none)
            ForEach(centers) { Text($0.name).tag(Optional($0.id)) }
            if let selection, !centers.contains(where: { $0.id == selection }) {
                Text("Cost center #\(selection)").tag(Optional(selection))
            }
        }
    }
}

private struct FinanceAmountField: View {
    let title: String
    let currency: String
    @Binding var value: Double?

    var body: some View {
        LabeledContent(title) {
            TextField("0.00", value: $value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
            Text(currency).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Edit transaction

struct FinanceTransactionEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let store: FinanceStore
    let transaction: FinanceTransaction
    var onSaved: () -> Void

    @State private var userID: Int?
    @State private var centerID: Int?
    @State private var amount: Double?
    @State private var note = ""
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FinanceUserPicker(users: store.users, selection: $userID)
                    FinanceCenterPicker(centers: store.centers, noneLabel: "Personal (none)", selection: $centerID)
                }
                Section {
                    FinanceAmountField(title: "Amount", currency: store.currency, value: $amount)
                } footer: {
                    Text("Negative amounts are charges; positive amounts are credits.")
                }
                Section {
                    TextField("Description", text: $note, axis: .vertical).lineLimit(2...5)
                } footer: {
                    Text("Edited descriptions are marked as an admin edit. Saving recalculates the ledger.")
                }
            }
            .navigationTitle("Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(runner.isRunning || !hasChanges)
                }
            }
            .onAppear {
                userID = transaction.userId
                centerID = transaction.costCenterId
                amount = transaction.amount
                note = transaction.description ?? ""
            }
            .actionAlerts(runner)
        }
    }

    private var hasChanges: Bool {
        userID != transaction.userId || centerID != transaction.costCenterId
            || amount != transaction.amount || note != (transaction.description ?? "")
    }

    private func save() async {
        var body: [String: JSONValue] = [:]
        if let userID, userID != transaction.userId { body["user_id"] = .number(Double(userID)) }
        // An explicit null moves the entry to the personal account.
        if centerID != transaction.costCenterId { body["cost_center_id"] = centerID.map { .number(Double($0)) } ?? .null }
        if let amount, amount != transaction.amount { body["amount"] = .number(amount) }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, note != (transaction.description ?? "") { body["description"] = .string(trimmed) }
        var ok = false
        await runner.run {
            let _: FinanceTransaction = try await session.client.send(.patch, "finance/transactions/\(transaction.id)", body: JSONValue.object(body))
            ok = true
        }
        if ok { onSaved(); dismiss() }
    }
}

// MARK: - Deposit / withdraw

struct FinanceWalletAdjustSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let store: FinanceStore
    var onSaved: () -> Void

    @State private var userID: Int?
    @State private var isDeposit = true
    @State private var amount: Double?
    @State private var centerID: Int?
    @State private var note = ""
    @State private var runner = ActionRunner()

    private var isValid: Bool { userID != nil && (amount ?? 0) > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $isDeposit) {
                        Text("Deposit").tag(true)
                        Text("Withdraw").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    FinanceUserPicker(users: store.users, selection: $userID)
                    FinanceCenterPicker(centers: store.centers, noneLabel: "Personal account", selection: $centerID)
                    FinanceAmountField(title: "Amount", currency: store.currency, value: $amount)
                } footer: {
                    Text(isDeposit ? "Adds credit to the selected account." : "Withdrawals can't exceed the account's balance.")
                }
                Section {
                    TextField("Description (optional)", text: $note)
                }
            }
            .navigationTitle("Adjust Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { Task { await save() } }.disabled(!isValid || runner.isRunning)
                }
            }
            .onAppear { if userID == nil { userID = session.user?.id ?? store.users.first?.id } }
            .actionAlerts(runner)
        }
    }

    private func save() async {
        guard let userID, let amount, amount > 0 else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = FinanceWalletAdjustment(amount: amount, description: trimmed.isEmpty ? nil : trimmed, costCenterId: centerID)
        var ok = false
        await runner.run {
            let _: FinanceAdjustmentResult = try await session.client.send(
                .post, "finance/users/\(userID)/\(isDeposit ? "deposit" : "withdraw")", body: body)
            ok = true
        }
        if ok { onSaved(); dismiss() }
    }
}

// MARK: - Manual print charge

struct FinanceManualChargeSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let store: FinanceStore
    var onSaved: () -> Void

    @State private var userID: Int?
    @State private var centerID: Int?
    @State private var amount: Double?
    @State private var note = ""
    @State private var date = Date()
    @State private var runner = ActionRunner()

    private var isValid: Bool { userID != nil && centerID != nil && amount != nil && amount != 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FinanceUserPicker(users: store.users, selection: $userID)
                    FinanceCenterPicker(centers: store.centers, noneLabel: "Select…", selection: $centerID)
                    FinanceAmountField(title: "Charge", currency: store.currency, value: $amount)
                    DatePicker("Date", selection: $date)
                } footer: {
                    Text("Records a print that wasn't tracked automatically. The amount is always booked as a charge and the ledger is recalculated.")
                }
                Section {
                    TextField("Description (optional)", text: $note)
                }
            }
            .navigationTitle("Manual Print Charge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }.disabled(!isValid || runner.isRunning)
                }
            }
            .actionAlerts(runner)
        }
    }

    private func save() async {
        guard let userID, let centerID, let amount else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = FinanceManualCharge(userId: userID, costCenterId: centerID, amount: abs(amount),
                                       description: trimmed.isEmpty ? nil : trimmed, createdAt: date)
        var ok = false
        await runner.run {
            let _: FinanceTransaction = try await session.client.send(.post, "finance/transactions/manual", body: body)
            ok = true
        }
        if ok { onSaved(); dismiss() }
    }
}
