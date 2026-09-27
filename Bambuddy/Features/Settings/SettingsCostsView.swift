import SwiftUI

/// Cost tracking, energy pricing and cost-center billing settings.
struct SettingsCostsView: View {
    @Environment(ServerSettingsStore.self) private var store
    @Environment(AppSession.self) private var session
    @State private var runner = ActionRunner()
    @State private var confirmRebuild = false

    var body: some View {
        let currency = store.string("currency", default: "USD")
        let symbol = SettingsCostsCurrencies.symbol(for: currency)
        SettingsForm("Costs & Energy") {
            Section {
                SettingsPicker("Currency", key: "currency", choices: SettingsCostsCurrencies.codes.map {
                    ($0, SettingsCostsCurrencies.label(for: $0))
                })
                SettingsNumberField("Filament Cost", key: "default_filament_cost", unit: "\(symbol)/kg",
                                    help: "Used when a spool has no price of its own.", integer: false, range: 0...100_000)
            } header: {
                Text("Cost Tracking")
            }

            Section {
                SettingsNumberField("Electricity Price", key: "energy_cost_per_kwh", unit: "\(symbol)/kWh",
                                    integer: false, range: 0...1_000)
                SettingsPicker("Energy Shown on Dashboard", key: "energy_tracking_mode", choices: [
                    ("print", "During Prints Only"),
                    ("total", "Total Consumption"),
                ])
            } header: {
                Text("Energy")
            } footer: {
                if store.string("energy_tracking_mode", default: "total") == "print" {
                    Text("Adds up the energy measured while prints were running.")
                } else {
                    Text("Shows the lifetime energy reported by your smart plugs, including idle time.")
                }
            }

            Section {
                SettingsToggle("Enforce Billing", key: "billing_enabled",
                               help: "Require prints and queue jobs to be charged to a cost center.")
                if store.bool("billing_enabled") {
                    SettingsToggle("Stop Unauthorized Prints", key: "printer_kill_switch_enabled",
                                   help: "Immediately cancel prints that start on a printer without going through Bambuddy.")
                }
            } header: {
                Text("Billing")
            }

            if store.bool("billing_enabled") {
                Section {
                    SettingsStepper("Reset Day", key: "finance_budget_reset_day", range: 1...31, default: 1)
                    NavigationLink {
                        CostsTimeZonePicker()
                    } label: {
                        LabeledContent("Time Zone", value: store.string("finance_budget_reset_timezone", default: "UTC"))
                    }
                    .disabled(!store.canEdit)
                } header: {
                    Text("Monthly Budget")
                } footer: {
                    Text("Budgets start over on this day of every month, at midnight in the chosen time zone. In shorter months the last day is used instead.")
                }

                if session.isAuthEnabled && session.can("cost_centers:modify") {
                    Section {
                        Button {
                            confirmRebuild = true
                        } label: {
                            HStack {
                                Label("Rebuild Wallet Ledger", systemImage: "arrow.triangle.2.circlepath")
                                if runner.isRunning { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(runner.isRunning)
                    } footer: {
                        Text("Recalculates the running balance of every wallet transaction. Only needed to repair balances that look wrong.")
                    }
                }
            }
        }
        .actionAlerts(runner)
        .confirm("Rebuild Wallet Ledger?", isPresented: $confirmRebuild,
                 message: "Every stored balance will be recalculated from the transaction history. This can take a moment on large installations.",
                 action: "Rebuild", role: nil) {
            Task {
                await runner.run {
                    let result: SettingsCostsRebuildResult = try await session.client.send(.post, "finance/rebuild-balance-ledger")
                    if let count = result.transactionsRebuilt {
                        runner.successMessage = "Rebuilt \(count) transaction\(count == 1 ? "" : "s")"
                    } else {
                        runner.successMessage = "Ledger rebuilt"
                    }
                }
            }
        }
    }
}

/// `POST /finance/rebuild-balance-ledger`
struct SettingsCostsRebuildResult: Codable, Sendable {
    var status: String?
    var transactionsRebuilt: Int?
    var message: String?
}

enum SettingsCostsCurrencies {
    /// Currencies the web interface offers (with their preferred short symbols).
    static let symbols: [(code: String, symbol: String)] = [
        ("USD", "$"), ("EUR", "€"), ("GBP", "£"), ("CHF", "Fr."), ("JPY", "¥"), ("CNY", "¥"), ("CAD", "$"),
        ("AUD", "$"), ("INR", "₹"), ("HKD", "HK$"), ("KRW", "₩"), ("SEK", "kr"), ("NOK", "kr"), ("DKK", "kr"),
        ("PLN", "zł"), ("BRL", "R$"), ("TWD", "NT$"), ("SGD", "S$"), ("NZD", "NZ$"), ("MXN", "MX$"), ("BZD", "BZ$"),
        ("MYR", "RM"), ("CZK", "Kč"), ("THB", "฿"), ("ZAR", "R"), ("TRY", "₺"), ("RUB", "₽"), ("HUF", "Ft"),
        ("ILS", "₪"), ("UAH", "₴"), ("IDR", "Rp"), ("PHP", "₱"),
    ]

    static var codes: [String] { symbols.map(\.code) }

    static func symbol(for code: String) -> String {
        symbols.first { $0.code == code.uppercased() }?.symbol ?? code
    }

    /// "EUR – Euro" using the system's localized currency names.
    static func label(for code: String, locale: Locale = .current) -> String {
        guard let name = locale.localizedString(forCurrencyCode: code), name != code else { return code }
        return "\(code) – \(name)"
    }
}

/// Searchable list of IANA time zones for the budget reset.
private struct CostsTimeZonePicker: View {
    @Environment(ServerSettingsStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private static let common = ["UTC", "Europe/London", "Europe/Berlin", "Europe/Vienna", "Europe/Zurich", "America/New_York",
                                 "America/Chicago", "America/Denver", "America/Los_Angeles", "Asia/Tokyo", "Asia/Singapore", "Australia/Sydney"]

    var body: some View {
        let current = store.string("finance_budget_reset_timezone", default: "UTC")
        List {
            if query.isEmpty {
                Section("Common") {
                    ForEach(Self.common, id: \.self) { row($0, current: current) }
                }
                if TimeZone.current.identifier != "GMT", !Self.common.contains(TimeZone.current.identifier) {
                    Section("This Device") { row(TimeZone.current.identifier, current: current) }
                }
            }
            Section(query.isEmpty ? "All Time Zones" : "Results") {
                ForEach(filtered, id: \.self) { row($0, current: current) }
            }
        }
        .navigationTitle("Time Zone")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search time zones")
        .alert("Couldn't Save", isPresented: Binding(get: { store.saveError != nil }, set: { if !$0 { store.saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.saveError ?? "") }
    }

    private var filtered: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return all }
        let q = query.replacingOccurrences(of: " ", with: "_")
        return all.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private func row(_ id: String, current: String) -> some View {
        Button {
            Task {
                if await store.save(["finance_budget_reset_timezone": .string(id)]) { dismiss() }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(id.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.primary)
                    if let tz = TimeZone(identifier: id), let name = tz.localizedName(for: .generic, locale: .current) {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if id == current { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }
}
