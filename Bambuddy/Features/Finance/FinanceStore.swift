import Foundation
import Observation

/// What the signed-in user may see and do in Finance (mirrors the web page's gating).
struct FinancePermissions: Sendable, Equatable {
    var readOwn: Bool
    var readAll: Bool
    var create: Bool
    var modify: Bool
    var readUsers: Bool

    @MainActor
    init(session: AppSession) {
        readOwn = session.can("cost_centers:read_own")
        readAll = session.can("cost_centers:read_all")
        create = session.can("cost_centers:create")
        modify = session.can("cost_centers:modify")
        readUsers = session.can("users:read_slim") || session.can("users:read")
    }

    init(readOwn: Bool, readAll: Bool, create: Bool, modify: Bool, readUsers: Bool) {
        self.readOwn = readOwn
        self.readAll = readAll
        self.create = create
        self.modify = modify
        self.readUsers = readUsers
    }

    /// Any administrative cost-center permission unlocks the full cost center list.
    var accessAllCenters: Bool { readAll || create || modify }
    var canAccess: Bool { readOwn || accessAllCenters }
    var hasAdminView: Bool { accessAllCenters }
    var canAdjustWallets: Bool { modify && readUsers }
    var canManageMembers: Bool { modify && readUsers }
}

enum FinanceViewMode: String, CaseIterable, Identifiable, Sendable {
    case personal, admin
    var id: String { rawValue }
    var label: String { self == .personal ? "Personal" : "All Accounts" }
}

/// Holds the Finance page's data so the dashboard and its detail screens share one copy.
@MainActor
@Observable
final class FinanceStore {
    static let pageSize = 50

    var mode: FinanceViewMode = .personal
    var includeInactive = false
    /// Server-side user filter for the all-accounts ledger.
    var userFilter: Int?
    /// Client-side filters applied to the loaded ledger (as on the web page).
    var typeFilter: FinanceTransactionKind?
    var costCenterFilter: Int?

    private(set) var wallet: FinanceWalletBalance?
    private(set) var centers: [FinanceCostCenter] = []
    private(set) var users: [FinanceUserSlim] = []
    private(set) var transactions: [FinanceTransaction] = []
    private(set) var transactionTotal = 0
    private(set) var billingEnabled: Bool?
    private(set) var settingsCurrency: String?

    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var centersError: String?
    private(set) var transactionsError: String?
    private(set) var walletError: String?

    #if DEBUG
    /// Set by the `-financePreview` launch argument: render fixture data without a server.
    var isPreview = false
    #endif

    var currency: String { wallet?.currency ?? settingsCurrency ?? "EUR" }

    /// Whether the ledger shown is the all-accounts ledger (vs. the user's own).
    func showsAllAccounts(_ perms: FinancePermissions) -> Bool { mode == .admin && perms.readAll }
    func showsTransactions(_ perms: FinancePermissions) -> Bool { showsAllAccounts(perms) || perms.readOwn }

    var filteredTransactions: [FinanceTransaction] {
        transactions.filter { tx in
            if let typeFilter, tx.kind != typeFilter { return false }
            if let costCenterFilter, tx.costCenterId != costCenterFilter { return false }
            return true
        }
    }

    var hasActiveFilters: Bool { typeFilter != nil || costCenterFilter != nil || userFilter != nil }
    var canLoadMore: Bool { transactions.count < transactionTotal }

    func userName(_ id: Int?, me: User?) -> String {
        guard let id else { return "—" }
        if let name = users.first(where: { $0.id == id })?.username { return name }
        if let me, me.id == id { return me.username }
        return "User #\(id)"
    }

    func center(_ id: Int?) -> FinanceCostCenter? {
        guard let id else { return nil }
        return centers.first { $0.id == id }
    }

    func ownerLabel(_ center: FinanceCostCenter, me: User?) -> String {
        guard center.isPrivate else { return "Shared" }
        guard let owner = center.ownerUserId else { return "Personal" }
        return userName(owner, me: me)
    }

    // MARK: Loading

    func reload(client: APIClient, perms: FinancePermissions) async {
        #if DEBUG
        if isPreview { loadPreview(); return }
        #endif
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        if !perms.hasAdminView { mode = .personal }
        async let settingsTask: Void = loadSettings(client: client)
        async let walletTask: Void = loadWallet(client: client, perms: perms)
        async let centersTask: Void = loadCenters(client: client, perms: perms)
        async let usersTask: Void = loadUsers(client: client, perms: perms)
        async let txTask: Void = loadTransactions(client: client, perms: perms, reset: true)
        _ = await (settingsTask, walletTask, centersTask, usersTask, txTask)
    }

    func loadMore(client: APIClient, perms: FinancePermissions) async {
        guard canLoadMore, !isLoadingMore else { return }
        #if DEBUG
        if isPreview { return }
        #endif
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loadTransactions(client: client, perms: perms, reset: false)
    }

    func reloadTransactions(client: APIClient, perms: FinancePermissions) async {
        #if DEBUG
        if isPreview { return }
        #endif
        await loadTransactions(client: client, perms: perms, reset: true)
    }

    private func loadSettings(client: APIClient) async {
        guard let settings: JSONValue = try? await client.get("settings/") else { return }
        billingEnabled = settings["billing_enabled"]?.boolValue
        settingsCurrency = settings["currency"]?.stringValue
    }

    private func loadWallet(client: APIClient, perms: FinancePermissions) async {
        guard perms.readOwn else { wallet = nil; return }
        do {
            wallet = try await client.get("finance/me/balance")
            walletError = nil
        } catch is CancellationError {
        } catch {
            walletError = error.localizedDescription
        }
    }

    private func loadCenters(client: APIClient, perms: FinancePermissions) async {
        do {
            if mode == .admin && perms.accessAllCenters {
                centers = try await client.get("finance/cost-centers", query: ["include_inactive": .bool(includeInactive)])
            } else {
                centers = try await client.get("finance/cost-centers/mine")
            }
            centersError = nil
        } catch is CancellationError {
        } catch {
            centersError = error.localizedDescription
        }
    }

    private func loadUsers(client: APIClient, perms: FinancePermissions) async {
        guard perms.readUsers else { return }
        if let list: [FinanceUserSlim] = try? await client.get("users/slim") {
            users = list.sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
        }
    }

    private func loadTransactions(client: APIClient, perms: FinancePermissions, reset: Bool) async {
        guard showsTransactions(perms) else {
            transactions = []
            transactionTotal = 0
            return
        }
        let offset = reset ? 0 : transactions.count
        do {
            let page: FinanceTransactionPage
            if showsAllAccounts(perms) {
                page = try await client.get("finance/transactions", query: [
                    "limit": .int(Self.pageSize), "offset": .int(offset), "user_id": .of(userFilter),
                ])
            } else {
                page = try await client.get("finance/me/transactions", query: ["limit": .int(Self.pageSize), "offset": .int(offset)])
            }
            if reset {
                transactions = page.items
            } else {
                let known = Set(transactions.map(\.id))
                transactions += page.items.filter { !known.contains($0.id) }
            }
            transactionTotal = page.total
            transactionsError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            transactionsError = error.localizedDescription
        }
    }

    // MARK: Local updates after mutations

    func replaceCenter(_ center: FinanceCostCenter) {
        if let i = centers.firstIndex(where: { $0.id == center.id }) { centers[i] = center } else { centers.append(center) }
    }

    func removeCenter(_ id: Int) { centers.removeAll { $0.id == id } }

    #if DEBUG
    private func loadPreview() {
        let data = Data(FinancePreviewData.json.utf8)
        guard let bundle = try? APICoders.decoder.decode(FinancePreviewData.self, from: data) else { return }
        wallet = bundle.wallet
        centers = bundle.centers
        users = bundle.users
        transactions = bundle.transactions
        transactionTotal = bundle.transactions.count
        billingEnabled = true
        hasLoaded = true
    }
    #endif
}

#if DEBUG
/// Fixture data for the `-financePreview` launch argument (UI review without an auth-enabled server).
struct FinancePreviewData: Decodable {
    var wallet: FinanceWalletBalance
    var centers: [FinanceCostCenter]
    var users: [FinanceUserSlim]
    var transactions: [FinanceTransaction]

    static let json = """
    {
      "wallet": {"user_id": 1, "balance": 18.4, "currency": "USD", "updated_at": "2026-09-20T10:00:00"},
      "users": [{"id": 1, "username": "admin"}, {"id": 2, "username": "maria"}, {"id": 3, "username": "sam"}],
      "centers": [
        {"id": 1, "name": "admin (personal)", "is_private": true, "owner_user_id": 1, "is_active": true,
         "total_balance": 18.4, "total_budget": null, "monthly_budget": null, "budget_mode": "none",
         "budget_limit": null, "budget_used": null, "budget_available": null, "can_print": true},
        {"id": 2, "name": "Robotics Club", "is_private": false, "owner_user_id": null, "is_active": true,
         "total_balance": -12.75, "total_budget": null, "monthly_budget": 50.0, "budget_mode": "monthly",
         "budget_limit": 50.0, "budget_used": 12.75, "budget_available": 37.25, "can_print": true},
        {"id": 3, "name": "Prototyping", "is_private": false, "owner_user_id": null, "is_active": true,
         "total_balance": 0.0, "total_budget": 200.0, "monthly_budget": null, "budget_mode": "total",
         "budget_limit": 200.0, "budget_used": 188.0, "budget_available": 4.5, "can_print": false}
      ],
      "transactions": [
        {"id": 7, "user_id": 1, "cost_center_id": 2, "transaction_type": "print_charge", "amount": -3.25,
         "balance_after": 18.4, "description": "Gear housing.3mf [cancelled: 40% printed]", "created_by_user_id": null,
         "print_run_id": "run-7", "print_archive_id": 41, "print_queue_id": 12, "created_at": "2026-09-24T16:02:11"},
        {"id": 6, "user_id": 1, "cost_center_id": 2, "transaction_type": "print_charge", "amount": -9.5,
         "balance_after": 21.65, "description": "Chassis v2.3mf", "created_by_user_id": null,
         "print_run_id": "run-6", "print_archive_id": 40, "print_queue_id": null, "created_at": "2026-09-22T09:15:00"},
        {"id": 5, "user_id": 1, "cost_center_id": null, "transaction_type": "deposit", "amount": 25.0,
         "balance_after": 31.15, "description": "Top-up", "created_by_user_id": 1,
         "print_run_id": null, "print_archive_id": null, "print_queue_id": null, "created_at": "2026-09-18T12:00:00"},
        {"id": 4, "user_id": 1, "cost_center_id": 3, "transaction_type": "manual_adjustment", "amount": -4.0,
         "balance_after": 6.15, "description": "Manual print charge", "created_by_user_id": 1,
         "print_run_id": null, "print_archive_id": null, "print_queue_id": null, "created_at": "2026-09-10T08:30:00"},
        {"id": 3, "user_id": 1, "cost_center_id": null, "transaction_type": "withdraw", "amount": -5.0,
         "balance_after": 10.15, "description": null, "created_by_user_id": 1,
         "print_run_id": null, "print_archive_id": null, "print_queue_id": null, "created_at": "2026-09-02T08:30:00"},
        {"id": 2, "user_id": 1, "cost_center_id": null, "transaction_type": "deposit", "amount": 15.15,
         "balance_after": 15.15, "description": "Initial balance", "created_by_user_id": 1,
         "print_run_id": null, "print_archive_id": null, "print_queue_id": null, "created_at": "2026-08-28T08:30:00"}
      ]
    }
    """
}
#endif
