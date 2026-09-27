import SwiftUI

/// Settings → Filament & AMS: tracking mode / Spoolman, filament checks, AMS display
/// thresholds, sensor history retention, inventory thresholds and the spool/color catalogs.
struct SettingsFilamentView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store
    @Environment(PrinterStore.self) private var printerStore
    @State private var spoolman = SettingsSpoolmanModel()

    /// An AMS reports roughly this humidity while its heater runs, so a lower drying trigger
    /// could never be reached.
    private let dryingHumidityFloor = 20

    var body: some View {
        SettingsForm("Filament & AMS") {
            SettingsSpoolmanSection(model: spoolman)
            filamentChecksSection
            humiditySection
            temperatureSection
            historySection
            inventorySection
            catalogsSection
        }
        .modifier(SettingsWorkflowKeyboardDone())
        .actionAlerts(spoolman.runner)
        .task {
            if printerStore.printers.isEmpty, !printerStore.isLoading { await printerStore.refresh() }
        }
        .task { spoolman.attach(session: session, store: store); await spoolman.run() }
        .onChange(of: store.isLoading) { wasLoading, isLoading in
            // Pull to refresh reloads the settings store; refresh the Spoolman state with it.
            if wasLoading, !isLoading, !spoolman.saving { Task { await spoolman.reload() } }
        }
    }

    private var filamentChecksSection: some View {
        Section {
            SettingsToggle("Disable Filament Warnings", key: "disable_filament_warnings",
                           help: "Don't warn about insufficient filament when printing or queueing.")
            SettingsToggle("Prefer Lowest Remaining Filament", key: "prefer_lowest_filament",
                           help: "When several spools match, use the one with the least filament left. Only useful with AMS filament backup turned on at the printer, so it can switch spools when one runs out.")
            SettingsToggle("Expand Per-Printer Mapping", key: "per_printer_mapping_expanded",
                           help: "When printing to several printers, show each printer's AMS slot mapping expanded by default.")
        } header: {
            Text("Filament Checks")
        }
    }

    private var humiditySection: some View {
        let fair = store.int("ams_humidity_fair") ?? 60
        return Section {
            SettingsNumberField("Good up to", key: "ams_humidity_good", unit: "%", range: 0...100)
            SettingsNumberField("Fair up to", key: "ams_humidity_fair", unit: "%",
                                help: "Also the default trigger for auto-drying.", range: 0...100)
            if fair < dryingHumidityFloor {
                Label("An AMS reads about \(dryingHumidityFloor)% or more while drying, so auto-drying could never finish at this level. Use a value above \(dryingHumidityFloor)% if auto-drying is on.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Label("AMS Humidity", systemImage: "humidity")
        } footer: {
            Text("Colors used for AMS humidity readings: green up to Good, orange up to Fair, red above. Per-filament drying triggers are on the Print Workflow page.")
        }
    }

    private var temperatureSection: some View {
        let fairTemp = store.double("ams_temp_fair") ?? 35
        return Section {
            SettingsNumberField("Good up to", key: "ams_temp_good", unit: "°C", integer: false, range: 0...60)
            SettingsNumberField("Fair up to", key: "ams_temp_fair", unit: "°C", integer: false, range: 0...60)
            LabeledContent {
                SettingsWorkflowNumberInput(
                    value: store.double("ams_temp_alarm").flatMap { $0 > 0 ? $0 : nil },
                    placeholder: SettingsNumberField.format(fairTemp, integer: false),
                    range: 0.5...120,
                    integer: false,
                    unit: "°C",
                    allowsEmpty: true,
                    width: 70
                ) { newValue in
                    Task { await store.save(["ams_temp_alarm": newValue.map { .number($0) } ?? .null]) }
                }
                .disabled(!store.canEdit)
            } label: {
                SettingsLabel("Alarm Above", help: "Leave empty to alarm at the Fair threshold.")
            }
        } header: {
            Label("AMS Temperature", systemImage: "thermometer.medium")
        } footer: {
            Text("Blue up to Good, orange up to Fair, red above. Only the alarm threshold sends notifications, so you can keep a warm AMS colored without being alerted.")
        }
    }

    private var historySection: some View {
        Section {
            SettingsNumberField("AMS Sensor History", key: "ams_history_retention_days", unit: "days", range: 1...365)
            SettingsNumberField("Printer Temperature History", key: "printer_sensor_history_retention_days", unit: "days",
                                help: "Nozzle, bed and chamber readings.", range: 1...365)
        } header: {
            Text("History Retention")
        } footer: {
            Text("Older humidity and temperature readings are deleted automatically.")
        }
    }

    private var inventorySection: some View {
        Section {
            SettingsNumberField("Low Stock Threshold", key: "low_stock_threshold", unit: "%",
                                help: "Spools below this remaining percentage count as low stock, unless a spool sets its own threshold.",
                                integer: false, range: 0.1...99.9)
            SettingsNumberField("Reorder Lead Time", key: "forecast_global_lead_time_days", unit: "days",
                                help: "Minimum lead time used when forecasting reorder points.", range: 0...365)
        } header: {
            Text("Inventory")
        }
    }

    private var catalogsSection: some View {
        Section {
            NavigationLink {
                SettingsCatalogSpoolView()
            } label: {
                Label("Spool Weights", systemImage: "scalemass")
            }
            NavigationLink {
                SettingsCatalogColorView()
            } label: {
                Label("Colors", systemImage: "paintpalette")
            }
        } header: {
            Text("Catalogs")
        } footer: {
            Text("Empty-spool weights and named filament colors used when adding and weighing spools.")
        }
        .disabled(!session.can("inventory:read"))
    }
}
