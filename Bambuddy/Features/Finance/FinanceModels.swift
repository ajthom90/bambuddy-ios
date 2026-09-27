import Foundation

// MARK: - Responses

/// `WalletBalanceResponse` — a user's personal account balance.
struct FinanceWalletBalance: Codable, Sendable, Hashable {
    var userId: Int
    var balance: Double
    var currency: String
    var updatedAt: Date?
}

/// `WalletTransactionResponse` — one ledger entry.
struct FinanceTransaction: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var userId: Int
    var costCenterId: Int?
    /// `print_charge`, `deposit`, `withdraw`, `manual_adjustment` (kept as a string for forward compatibility).
    var transactionType: String
    var amount: Double
    var balanceAfter: Double?
    var description: String?
    var createdByUserId: Int?
    var printRunId: String?
    var printArchiveId: Int?
    var printQueueId: Int?
    var createdAt: Date?

    var kind: FinanceTransactionKind { FinanceTransactionKind(rawValue: transactionType) ?? .other }

    /// Print charges for interrupted jobs carry a bracketed status marker in their
    /// description, e.g. `"Benchy.3mf [cancelled: 42% printed]"`.
    var partialStatus: String? { FinanceChargeNote.parse(description).status }
    /// The description with any partial-print marker removed.
    var displayDescription: String? {
        kind == .printCharge ? FinanceChargeNote.parse(description).text : description
    }
}

/// `WalletTransactionListResponse` — a page of ledger entries.
struct FinanceTransactionPage: Codable, Sendable {
    var items: [FinanceTransaction]
    var total: Int
    var limit: Int
    var offset: Int
}

/// `CostCenterSummaryResponse` / `CostCenterDetailResponse` (detail adds `members`).
struct FinanceCostCenter: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var isPrivate: Bool
    var ownerUserId: Int?
    var isActive: Bool
    var totalBalance: Double?
    var totalBudget: Double?
    var monthlyBudget: Double?
    /// `monthly`, `total` or `none`.
    var budgetMode: String?
    var budgetLimit: Double?
    var budgetUsed: Double?
    var budgetAvailable: Double?
    var canPrint: Bool?
    var members: [FinanceCostCenterMember]?

    var hasBudget: Bool { budgetLimit != nil && budgetMode != "none" }

    /// Fraction of the budget already used or reserved (0...1), nil when unlimited.
    var budgetFraction: Double? {
        guard let limit = budgetLimit, let available = budgetAvailable else { return nil }
        guard limit > 0 else { return 1 }
        return min(1, max(0, (limit - available) / limit))
    }

    var budgetModeLabel: String {
        switch budgetMode {
        case "monthly": return "Monthly budget"
        case "total": return "Total budget"
        default: return "No budget"
        }
    }
}

/// `CostCenterMemberResponse`.
struct FinanceCostCenterMember: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var costCenterId: Int
    var userId: Int
    var canPrint: Bool
    var createdAt: Date?
}

/// `WalletAdjustmentResponse` — returned by deposit / withdraw.
struct FinanceAdjustmentResult: Codable, Sendable {
    var transaction: FinanceTransaction
    var balance: FinanceWalletBalance
}

/// `UserSlim` from `GET users/slim` — used only to label and pick users.
struct FinanceUserSlim: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var username: String
}

// MARK: - Requests

struct FinanceCostCenterCreate: Encodable, Sendable {
    var name: String
    var totalBudget: Double?
    var monthlyBudget: Double?
    var isActive: Bool = true
}

struct FinanceMemberUpsert: Encodable, Sendable {
    var userId: Int
    var canPrint: Bool
}

struct FinanceWalletAdjustment: Encodable, Sendable {
    var amount: Double
    var description: String?
    var costCenterId: Int?
}

struct FinanceManualCharge: Encodable, Sendable {
    var userId: Int
    var costCenterId: Int
    var amount: Double
    var description: String?
    var createdAt: Date?
}

// MARK: - Helpers

enum FinanceTransactionKind: String, CaseIterable, Sendable {
    case printCharge = "print_charge"
    case deposit
    case withdraw
    case manualAdjustment = "manual_adjustment"
    case other

    var label: String {
        switch self {
        case .printCharge: return "Print Charge"
        case .deposit: return "Deposit"
        case .withdraw: return "Withdrawal"
        case .manualAdjustment: return "Manual Charge"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .printCharge: return "printer.fill"
        case .deposit: return "arrow.down.circle.fill"
        case .withdraw: return "arrow.up.circle.fill"
        case .manualAdjustment: return "pencil.circle.fill"
        case .other: return "circle.fill"
        }
    }

    static var filterable: [FinanceTransactionKind] { [.deposit, .withdraw, .printCharge, .manualAdjustment] }
}

/// Parses the `[status: note]` marker the server appends to charges for partial prints.
enum FinanceChargeNote {
    static let statuses: Set<String> = ["aborted", "failed", "cancelled"]

    static func parse(_ description: String?) -> (status: String?, text: String?) {
        guard let description else { return (nil, nil) }
        guard let open = description.firstIndex(of: "[") else { return (nil, description) }
        let afterOpen = description.index(after: open)
        guard let close = description[afterOpen...].firstIndex(of: "]"),
              let colon = description[afterOpen..<close].firstIndex(of: ":") else { return (nil, description) }
        let status = description[afterOpen..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard statuses.contains(status) else { return (nil, description) }
        var remaining = description
        remaining.removeSubrange(open...close)
        let text = remaining.trimmingCharacters(in: .whitespaces)
        return (status, text.isEmpty ? nil : text)
    }
}
