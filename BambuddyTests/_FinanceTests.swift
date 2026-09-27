import Testing
import Foundation
@testable import Bambuddy

struct FinanceDecodeTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func walletBalanceWithAndWithoutTimestamp() throws {
        let stored = try decode(FinanceWalletBalance.self,
            #"{"user_id": 3, "balance": 20.0, "currency": "USD", "updated_at": "2026-09-20T10:11:12.123456"}"#)
        #expect(stored.balance == 20)
        #expect(stored.currency == "USD")
        #expect(stored.updatedAt != nil)
        // GET me/balance for a user without a wallet row returns updated_at: null.
        let computed = try decode(FinanceWalletBalance.self,
            #"{"user_id": 4, "balance": 0, "currency": "EUR", "updated_at": null}"#)
        #expect(computed.updatedAt == nil)
    }

    @Test func transactionPageWithNulls() throws {
        let json = """
        {"items": [
          {"id": 12, "user_id": 2, "cost_center_id": 5, "transaction_type": "print_charge", "amount": -3.4,
           "balance_after": 16.6, "description": "Benchy.3mf [cancelled: 40% printed]", "created_by_user_id": null,
           "print_run_id": "a1b2c3", "print_archive_id": 99, "print_queue_id": 7, "created_at": "2026-09-24T16:02:11.000123"},
          {"id": 11, "user_id": 2, "cost_center_id": null, "transaction_type": "deposit", "amount": 20.0,
           "balance_after": null, "description": null, "created_by_user_id": 1, "print_run_id": null,
           "print_archive_id": null, "print_queue_id": null, "created_at": "2026-09-20T08:00:00+00:00"},
          {"id": 10, "user_id": 2, "cost_center_id": 5, "transaction_type": "manual_adjustment", "amount": -4.0,
           "balance_after": 0.0, "description": "Manual print charge (Admin edit)", "created_by_user_id": 1,
           "print_run_id": null, "print_archive_id": null, "print_queue_id": null, "created_at": "2026-09-01T00:00:00Z"},
          {"id": 9, "user_id": 2, "transaction_type": "refund", "amount": 1.0, "created_at": "2026-08-01T00:00:00"}
        ], "total": 57, "limit": 50, "offset": 0}
        """
        let page = try decode(FinanceTransactionPage.self, json)
        #expect(page.total == 57)
        #expect(page.items.count == 4)
        let charge = page.items[0]
        #expect(charge.kind == .printCharge)
        #expect(charge.partialStatus == "cancelled")
        #expect(charge.displayDescription == "Benchy.3mf")
        #expect(charge.printArchiveId == 99)
        #expect(page.items[1].costCenterId == nil)
        #expect(page.items[1].balanceAfter == nil)
        #expect(page.items[2].kind == .manualAdjustment)
        #expect(page.items[2].partialStatus == nil)
        #expect(page.items[3].kind == .other)
    }

    @Test func costCenterSummaryAndDetail() throws {
        let list = try decode([FinanceCostCenter].self, """
        [{"id": 1, "name": "alice", "is_private": true, "owner_user_id": 2, "is_active": true, "total_balance": 25.0,
          "total_budget": 0.0, "monthly_budget": null, "budget_mode": "total", "budget_limit": 0.0, "budget_used": 0.0,
          "budget_available": 0.0, "can_print": true},
         {"id": 2, "name": "Lab", "is_private": false, "owner_user_id": null, "is_active": true, "total_balance": 0.0,
          "total_budget": null, "monthly_budget": null, "budget_mode": "none", "budget_limit": null, "budget_used": null,
          "budget_available": null, "can_print": false}]
        """)
        #expect(list.count == 2)
        #expect(list[0].budgetFraction == 1)
        #expect(list[1].hasBudget == false)
        #expect(list[1].budgetFraction == nil)
        #expect(list[1].canPrint == false)

        let detail = try decode(FinanceCostCenter.self, """
        {"id": 3, "name": "Robotics", "is_private": false, "owner_user_id": null, "is_active": false, "total_balance": -12.5,
         "total_budget": null, "monthly_budget": 50.0, "budget_mode": "monthly", "budget_limit": 50.0, "budget_used": 12.5,
         "budget_available": 37.5, "can_print": true,
         "members": [{"id": 8, "cost_center_id": 3, "user_id": 4, "can_print": false, "created_at": "2026-09-01T12:00:00"}]}
        """)
        #expect(detail.members?.first?.userId == 4)
        #expect(detail.members?.first?.canPrint == false)
        #expect(detail.budgetFraction == 0.25)
        #expect(detail.budgetModeLabel == "Monthly budget")
    }

    @Test func minimalCostCenterUsesDefaults() throws {
        // Only the schema's required fields.
        let c = try decode(FinanceCostCenter.self, #"{"id": 9, "name": "X", "is_private": false, "is_active": true}"#)
        #expect(c.totalBalance == nil)
        #expect(c.budgetMode == nil)
        #expect(c.hasBudget == false)
    }

    @Test func adjustmentResponse() throws {
        let r = try decode(FinanceAdjustmentResult.self, """
        {"transaction": {"id": 30, "user_id": 2, "cost_center_id": 1, "transaction_type": "withdraw", "amount": -5.0,
          "balance_after": 20.0, "description": null, "created_by_user_id": 1, "print_run_id": null,
          "print_archive_id": null, "print_queue_id": null, "created_at": "2026-09-25T09:00:00"},
         "balance": {"user_id": 2, "balance": 20.0, "currency": "EUR", "updated_at": "2026-09-25T09:00:00"}}
        """)
        #expect(r.transaction.kind == .withdraw)
        #expect(r.balance.balance == 20)
    }

    @Test func memberAndUsers() throws {
        let m = try decode(FinanceCostCenterMember.self,
            #"{"id": 1, "cost_center_id": 2, "user_id": 3, "can_print": true, "created_at": "2026-09-25T09:00:00.5"}"#)
        #expect(m.canPrint)
        let users = try decode([FinanceUserSlim].self, #"[{"id": 1, "username": "admin"}, {"id": 2, "username": "bob"}]"#)
        #expect(users.map(\.username) == ["admin", "bob"])
    }

    @Test func requestBodiesUseSnakeCase() throws {
        let create = try JSONValue.from(FinanceCostCenterCreate(name: "Lab", totalBudget: nil, monthlyBudget: 25))
        #expect(create["monthly_budget"]?.doubleValue == 25)
        #expect(create["is_active"]?.boolValue == true)
        let manual = try JSONValue.from(FinanceManualCharge(userId: 2, costCenterId: 3, amount: 4, description: nil,
                                                            createdAt: Date(timeIntervalSince1970: 0)))
        #expect(manual["cost_center_id"]?.intValue == 3)
        #expect(manual["created_at"]?.stringValue == "1970-01-01T00:00:00Z")
        let adjust = try JSONValue.from(FinanceWalletAdjustment(amount: 5, description: "x", costCenterId: nil))
        #expect(adjust["amount"]?.doubleValue == 5)
        // Explicit nulls survive encoding (used to clear budgets / move a transaction to the personal account).
        let patch: JSONValue = ["cost_center_id": nil, "monthly_budget": nil]
        let data = try APICoders.encoder.encode(patch)
        let raw = String(decoding: data, as: UTF8.self)
        #expect(raw.contains("\"cost_center_id\":null"))
    }

    @Test func chargeNoteParsing() {
        #expect(FinanceChargeNote.parse("Part.3mf [failed: 12%]").status == "failed")
        #expect(FinanceChargeNote.parse("Part.3mf [failed: 12%]").text == "Part.3mf")
        #expect(FinanceChargeNote.parse("[aborted: early]").text == nil)
        #expect(FinanceChargeNote.parse("Plain [note]").status == nil)
        #expect(FinanceChargeNote.parse("Other [paused: 1]").status == nil)
        #expect(FinanceChargeNote.parse(nil).text == nil)
    }

    @Test @MainActor func previewFixtureDecodes() throws {
        #if DEBUG
        let bundle = try APICoders.decoder.decode(FinancePreviewData.self, from: Data(FinancePreviewData.json.utf8))
        #expect(bundle.centers.count == 3)
        #expect(bundle.transactions.count == 6)
        #endif
    }

    @Test func permissionsGating() {
        let own = FinancePermissions(readOwn: true, readAll: false, create: false, modify: false, readUsers: false)
        #expect(own.canAccess)
        #expect(!own.hasAdminView)
        let billing = FinancePermissions(readOwn: false, readAll: false, create: false, modify: true, readUsers: true)
        #expect(billing.canAccess)
        #expect(billing.accessAllCenters)
        #expect(billing.canAdjustWallets)
        let none = FinancePermissions(readOwn: false, readAll: false, create: false, modify: false, readUsers: true)
        #expect(!none.canAccess)
    }
}
