import SwiftUI
import Charts

struct FinanceRootView: View {
    @Environment(AppSession.self) private var session
    @State private var store: FinanceStore = {
        let store = FinanceStore()
        #if DEBUG
        store.isPreview = ProcessInfo.processInfo.arguments.contains("-financePreview")
        #endif
        return store
    }()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Finance")
                .navigationDestination(for: FinanceRoute.self) { route in
                    switch route {
                    case .costCenter(let id): FinanceCostCenterDetailView(store: store, centerID: id)
                    case .transaction(let id): FinanceTransactionDetailView(store: store, transactionID: id)
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        let perms = FinancePermissions(session: session)
        if isPreview {
            FinanceDashboardView(store: store, perms: perms)
        } else if !session.isAuthEnabled {
            ContentUnavailableView {
                Label("Sign-In Required", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("Wallets, charges and cost centers belong to user accounts. Turn on authentication on your Bambuddy server to use Finance.")
            }
        } else if !perms.canAccess {
            ContentUnavailableView("No Access", systemImage: "lock", description: Text("Your account isn't allowed to view finance data."))
        } else {
            FinanceDashboardView(store: store, perms: perms)
        }
    }

    private var isPreview: Bool {
        #if DEBUG
        return store.isPreview
        #else
        return false
        #endif
    }
}

enum FinanceRoute: Hashable {
    case costCenter(Int)
    case transaction(Int)
}

// MARK: - Dashboard

private struct FinanceDashboardView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Bindable var store: FinanceStore
    let perms: FinancePermissions

    @State private var runner = ActionRunner()
    @State private var sheet: FinanceSheet?
    @State private var pendingDeleteCenter: FinanceCostCenter?
    @State private var pendingDeleteTransaction: FinanceTransaction?
    @State private var confirmRebuild = false

    private var client: APIClient { session.client }
    private var isAdmin: Bool { store.mode == .admin }

    var body: some View {
        List {
            if store.billingEnabled == false {
                Section {
                    Label {
                        Text("Billing is turned off in Settings, so prints are not charged and budgets are not enforced.")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                }
            }
            if perms.hasAdminView {
                Section {
                    Picker("View", selection: $store.mode) {
                        ForEach(FinanceViewMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            summarySection
            balanceChartSection
            centersSection
            if store.showsTransactions(perms) { transactionsSection }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if !store.hasLoaded && store.isLoading { ProgressView() }
        }
        .refreshable { await store.reload(client: client, perms: perms) }
        .task(id: live.revision("print_start", "print_complete", "archive_created", "archive_updated", "billing_charge_failed")) {
            await store.reload(client: client, perms: perms)
        }
        .onChange(of: store.mode) { reload() }
        .onChange(of: store.includeInactive) { reload() }
        .onChange(of: store.userFilter) { Task { await store.reloadTransactions(client: client, perms: perms) } }
        .toolbar { toolbarContent }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .createCenter:
                FinanceCostCenterEditor(store: store, perms: perms, center: nil) { reload() }
            case .editCenter(let center):
                FinanceCostCenterEditor(store: store, perms: perms, center: center) { reload() }
            case .adjustWallet:
                FinanceWalletAdjustSheet(store: store) { reload() }
            case .manualCharge:
                FinanceManualChargeSheet(store: store) { reload() }
            case .editTransaction(let tx):
                FinanceTransactionEditor(store: store, transaction: tx) { reload() }
            }
        }
        .confirmationDialog("Delete \"\(pendingDeleteCenter?.name ?? "")\"?", isPresented: Binding(
            get: { pendingDeleteCenter != nil }, set: { if !$0 { pendingDeleteCenter = nil } }
        ), titleVisibility: .visible, presenting: pendingDeleteCenter) { center in
            Button("Delete Cost Center", role: .destructive) { deleteCenter(center) }
        } message: { _ in
            Text("Cost centers that still have transactions or active budget reservations can't be deleted.")
        }
        .confirmationDialog("Delete Transaction?", isPresented: Binding(
            get: { pendingDeleteTransaction != nil }, set: { if !$0 { pendingDeleteTransaction = nil } }
        ), titleVisibility: .visible, presenting: pendingDeleteTransaction) { tx in
            Button("Delete Transaction", role: .destructive) { deleteTransaction(tx) }
        } message: { _ in
            Text("Balances will be recalculated automatically.")
        }
        .confirm("Rebuild Balance Ledger?", isPresented: $confirmRebuild,
                 message: "Recalculates every account's running balance from its transactions.", action: "Rebuild", role: nil) {
            Task {
                await runner.run("Ledger rebuilt") { try await client.call(.post, "finance/rebuild-balance-ledger") }
                reload()
            }
        }
        .actionAlerts(runner)
    }

    private func reload() { Task { await store.reload(client: client, perms: perms) } }

    // MARK: Summary

    private var summarySection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 200 : 150), spacing: 12)], spacing: 12) {
                if perms.readOwn {
                    FinanceStatTile(title: "Personal Balance", systemImage: "wallet.bifold", tint: .green,
                                    value: store.wallet.map { $0.balance.formatted(.currency(code: store.currency)) } ?? (store.walletError != nil ? "—" : "…"))
                }
                FinanceStatTile(title: store.showsAllAccounts(perms) ? "Transactions" : "My Transactions",
                                systemImage: "clock.arrow.circlepath", tint: .blue,
                                value: store.hasLoaded ? "\(store.transactionTotal)" : "…")
                FinanceStatTile(title: "Cost Centers", systemImage: "building.2", tint: .orange,
                                value: store.hasLoaded ? "\(store.centers.count)" : "…")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            Text("Account balances track costs. Printing is limited only by the selected cost center's budget; a cost center without a budget can print without limit.")
        }
    }

    @ViewBuilder private var balanceChartSection: some View {
        let points = store.showsAllAccounts(perms) ? [] : store.transactions
            .compactMap { tx -> (Date, Double)? in
                guard let date = tx.createdAt, let balance = tx.balanceAfter else { return nil }
                return (date, balance)
            }
            .sorted { $0.0 < $1.0 }
        if points.count >= 2 {
            Section("Balance History") {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Date", point.0), y: .value("Balance", point.1))
                            .interpolationMethod(.stepEnd)
                        PointMark(x: .value("Date", point.0), y: .value("Balance", point.1))
                            .symbolSize(20)
                    }
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.4))
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(v.formatted(.currency(code: store.currency).precision(.fractionLength(0)))) }
                        }
                    }
                }
                .frame(height: 180)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: Cost centers

    private var centersSection: some View {
        Section {
            if let error = store.centersError, store.centers.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if store.centers.isEmpty && store.hasLoaded {
                Text("No cost centers yet.").foregroundStyle(.secondary)
            }
            ForEach(store.centers) { center in
                NavigationLink(value: FinanceRoute.costCenter(center.id)) {
                    FinanceCostCenterRow(center: center, currency: store.currency,
                                         owner: isAdmin ? store.ownerLabel(center, me: session.user) : nil)
                }
                .swipeActions(edge: .trailing) {
                    if isAdmin && perms.modify && !center.isPrivate {
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDeleteCenter = center }
                    }
                    if isAdmin && perms.modify {
                        Button("Edit", systemImage: "pencil") { sheet = .editCenter(center) }.tint(.blue)
                    }
                }
                .contextMenu {
                    if isAdmin && perms.modify {
                        Button("Edit", systemImage: "pencil") { sheet = .editCenter(center) }
                        if !center.isPrivate {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDeleteCenter = center }
                        }
                    }
                }
            }
        } header: {
            Text(isAdmin ? "Cost Centers" : "My Cost Centers")
        } footer: {
            if isAdmin && perms.canManageMembers && store.centers.contains(where: { !$0.isPrivate }) {
                Text("Open a shared cost center to manage its members.")
            }
        }
    }

    // MARK: Transactions

    private var transactionsSection: some View {
        Section {
            if let error = store.transactionsError, store.transactions.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if store.transactions.isEmpty && store.hasLoaded {
                Text("No transactions yet.").foregroundStyle(.secondary)
            } else if store.filteredTransactions.isEmpty && store.hasLoaded {
                Text("No loaded transactions match the filters.").foregroundStyle(.secondary)
            }
            ForEach(store.filteredTransactions) { tx in
                NavigationLink(value: FinanceRoute.transaction(tx.id)) {
                    FinanceTransactionRow(transaction: tx, currency: store.currency,
                                          centerName: store.center(tx.costCenterId)?.name,
                                          userName: isAdmin ? store.userName(tx.userId, me: session.user) : nil)
                }
                .swipeActions(edge: .trailing) {
                    if isAdmin && perms.modify {
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDeleteTransaction = tx }
                        Button("Edit", systemImage: "pencil") { sheet = .editTransaction(tx) }.tint(.blue)
                    }
                }
                .contextMenu {
                    if isAdmin && perms.modify {
                        Button("Edit", systemImage: "pencil") { sheet = .editTransaction(tx) }
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDeleteTransaction = tx }
                    }
                }
            }
            if store.canLoadMore {
                Button {
                    Task { await store.loadMore(client: client, perms: perms) }
                } label: {
                    HStack {
                        Text("Load More (\(store.transactions.count) of \(store.transactionTotal))")
                        Spacer()
                        if store.isLoadingMore { ProgressView() }
                    }
                }
                .disabled(store.isLoadingMore)
            }
        } header: {
            HStack {
                Text(store.showsAllAccounts(perms) ? "Transactions" : "My Transactions")
                Spacer()
                if store.hasActiveFilters {
                    Button("Clear Filters") {
                        store.typeFilter = nil
                        store.costCenterFilter = nil
                        store.userFilter = nil
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if store.showsTransactions(perms) {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Type", selection: $store.typeFilter) {
                        Text("All Types").tag(FinanceTransactionKind?.none)
                        ForEach(FinanceTransactionKind.filterable, id: \.self) { kind in
                            Label(kind.label, systemImage: kind.systemImage).tag(Optional(kind))
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Cost Center", selection: $store.costCenterFilter) {
                        Text("All Cost Centers").tag(Int?.none)
                        ForEach(store.centers) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu)
                    if store.showsAllAccounts(perms) && !store.users.isEmpty {
                        Picker("User", selection: $store.userFilter) {
                            Text("All Users").tag(Int?.none)
                            ForEach(store.users) { Text($0.username).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.menu)
                    }
                    if isAdmin && perms.accessAllCenters {
                        Divider()
                        Toggle("Show Inactive Cost Centers", isOn: $store.includeInactive)
                    }
                } label: {
                    Label("Filter", systemImage: store.hasActiveFilters
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        if isAdmin && (perms.create || perms.modify) {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if perms.create {
                        Button("New Cost Center", systemImage: "building.2") { sheet = .createCenter }
                    }
                    if perms.canAdjustWallets {
                        Button("Adjust Wallet", systemImage: "plusminus.circle") { sheet = .adjustWallet }
                        Button("Add Manual Print Charge", systemImage: "printer") { sheet = .manualCharge }
                    }
                    if perms.modify {
                        Divider()
                        Button("Rebuild Balance Ledger", systemImage: "arrow.triangle.2.circlepath") { confirmRebuild = true }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
    }

    // MARK: Actions

    private func deleteCenter(_ center: FinanceCostCenter) {
        Task {
            await runner.run("Cost center deleted") {
                try await client.call(.delete, "finance/cost-centers/\(center.id)")
                store.removeCenter(center.id)
            }
            reload()
        }
    }

    private func deleteTransaction(_ tx: FinanceTransaction) {
        Task {
            await runner.run("Transaction deleted") {
                try await client.call(.delete, "finance/transactions/\(tx.id)")
            }
            reload()
        }
    }
}

enum FinanceSheet: Identifiable {
    case createCenter
    case editCenter(FinanceCostCenter)
    case adjustWallet
    case manualCharge
    case editTransaction(FinanceTransaction)

    var id: String {
        switch self {
        case .createCenter: return "create"
        case .editCenter(let c): return "center-\(c.id)"
        case .adjustWallet: return "adjust"
        case .manualCharge: return "manual"
        case .editTransaction(let t): return "tx-\(t.id)"
        }
    }
}

// MARK: - Shared rows

private struct FinanceStatTile: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }
}

struct FinanceCostCenterRow: View {
    let center: FinanceCostCenter
    let currency: String
    var owner: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: center.isPrivate ? "person.fill" : "person.3.fill")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                Text(center.name).font(.headline)
                if !center.isActive { StatusBadge(text: "Inactive", color: .gray) }
                if center.canPrint == false { StatusBadge(text: "Can't Print", color: .red) }
                Spacer()
                Text((center.totalBalance ?? 0).formatted(.currency(code: currency)))
                    .monospacedDigit()
                    .foregroundStyle((center.totalBalance ?? 0) < 0 ? .red : .primary)
            }
            if let owner {
                Text(owner).font(.caption).foregroundStyle(.secondary)
            }
            FinanceBudgetBar(center: center, currency: currency)
        }
        .padding(.vertical, 2)
    }
}

struct FinanceBudgetBar: View {
    let center: FinanceCostCenter
    let currency: String

    var body: some View {
        if let fraction = center.budgetFraction, let limit = center.budgetLimit {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: fraction)
                    .tint(fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .green)
                HStack {
                    Text(center.budgetModeLabel)
                    Spacer()
                    Text("\((center.budgetAvailable ?? 0).formatted(.currency(code: currency))) of \(limit.formatted(.currency(code: currency))) left")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else {
            Text("No budget · unlimited printing").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct FinanceTransactionRow: View {
    let transaction: FinanceTransaction
    let currency: String
    var centerName: String?
    var userName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: transaction.kind.systemImage)
                .font(.title3)
                .foregroundStyle(transaction.amount >= 0 ? .green : .red)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transaction.kind == .other ? transaction.transactionType : transaction.kind.label)
                        .font(.subheadline.weight(.semibold))
                    if let status = transaction.partialStatus {
                        StatusBadge(text: status.capitalized, color: .yellow)
                    }
                }
                if let text = transaction.displayDescription, !text.isEmpty {
                    Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(metaLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(transaction.amount.formatted(.currency(code: currency).sign(strategy: .always())))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(transaction.amount >= 0 ? .green : .red)
                if let after = transaction.balanceAfter {
                    Text(after.formatted(.currency(code: currency)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let date = transaction.createdAt { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let userName { parts.append(userName) }
        parts.append(centerName ?? (transaction.costCenterId == nil ? "Personal" : "Cost center #\(transaction.costCenterId!)"))
        return parts.joined(separator: " · ")
    }
}
