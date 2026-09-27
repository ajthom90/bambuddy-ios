import SwiftUI

/// Add/edit sheet for a smart plug, covering every plug type and option the
/// server supports.
struct SettingsSmartPlugEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let target: SettingsSmartPlugEditorTarget
    let existingPlugs: [SettingsSmartPlug]
    var onSaved: () async -> Void

    @State private var draft = SettingsSmartPlugDraft()
    @State private var didPopulate = false
    @State private var runner = ActionRunner()
    @State private var validationMessage: String?
    @State private var testMessage: (success: Bool, text: String)?
    @State private var isTesting = false
    @State private var haSensors: [SettingsHASensorEntity] = []
    @State private var haSensorsError: String?
    @State private var confirmDelete = false

    private var editingPlug: SettingsSmartPlug? {
        if case .edit(let plug) = target { return plug }
        return nil
    }
    private var isEditing: Bool { editingPlug != nil }

    private var haConfigured: Bool {
        store.bool("ha_enabled") && !store.string("ha_url").isEmpty && !store.string("ha_token").isEmpty
    }
    private var mqttConfigured: Bool { !store.string("mqtt_broker").isEmpty }

    private var canSave: Bool {
        session.can(isEditing ? "smart_plugs:update" : "smart_plugs:create")
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isEditing { typeSection }
                identitySection
                switch draft.type {
                case .tasmota: tasmotaSections
                case .homeassistant: homeAssistantSections
                case .mqtt: mqttSections
                case .rest: restSections
                }
                if draft.type != .mqtt { printerSection }
                if draft.type.isControllable, isEditing || draft.type != .homeassistant { automationSection }
                alertsSection
                if draft.type != .mqtt { scheduleSection }
                visibilitySection
                if isEditing, session.can("smart_plugs:delete") {
                    Section {
                        Button("Delete Plug", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Plug" : "Add Smart Plug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else {
                        Button(isEditing ? "Save" : "Add") { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
            .alert("Check the Form", isPresented: Binding(get: { validationMessage != nil }, set: { if !$0 { validationMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(validationMessage ?? "") }
            .confirm("Delete \(draft.name.isEmpty ? "Plug" : draft.name)?", isPresented: $confirmDelete,
                     message: "The plug is removed from Bambuddy. The device itself is not changed.") {
                Task { await delete() }
            }
            .actionAlerts(runner)
            .onAppear(perform: populate)
            .task { if !store.hasLoaded { await store.load() } }
            .task(id: draft.type == .homeassistant && haConfigured) { await loadHASensors() }
        }
        .interactiveDismissDisabled(runner.isRunning)
    }

    // MARK: Sections

    private var typeSection: some View {
        Section {
            Picker("Type", selection: $draft.type) {
                ForEach(SettingsSmartPlugType.allCases) { type in
                    Text(type.shortLabel).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: draft.type) { _, _ in testMessage = nil }
        } footer: {
            Text(typeDescription)
        }
    }

    private var typeDescription: String {
        switch draft.type {
        case .tasmota: "A plug running Tasmota firmware, controlled directly over your network."
        case .homeassistant: "A switch, light, input boolean or script in Home Assistant."
        case .mqtt: "Reads power, energy and state from MQTT topics. MQTT plugs are monitor-only and can't be switched from Bambuddy."
        case .rest: "Any device with an HTTP API — openHAB, Shelly, ioBroker, Node-RED and similar."
        }
    }

    private var identitySection: some View {
        Section {
            TextField("Name", text: $draft.name)
        } header: {
            Text("Name")
        }
    }

    // Tasmota

    @ViewBuilder
    private var tasmotaSections: some View {
        Section {
            if !isEditing {
                NavigationLink {
                    SettingsTasmotaDiscoveryView(configuredAddresses: Set(existingPlugs.compactMap(\.ipAddress))) { device in
                        apply(device)
                    }
                } label: {
                    Label("Discover on Network", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            TextField("IP Address", text: $draft.ipAddress, prompt: Text("192.168.1.100"))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: draft.ipAddress) { _, _ in testMessage = nil }
            TextField("Username", text: $draft.username, prompt: Text("Username (optional)"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $draft.password, prompt: Text("Password (optional)"))
            if session.can("smart_plugs:control") {
                Button {
                    Task { await testTasmota() }
                } label: {
                    HStack {
                        Label("Test Connection", systemImage: "wifi")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(draft.ipAddress.trimmingCharacters(in: .whitespaces).isEmpty || isTesting)
            }
            if let testMessage { SettingsTestResultLabel(success: testMessage.success, message: testMessage.text) }
        } header: {
            Text("Device")
        } footer: {
            Text("Only needed when the plug's web interface is password protected.")
        }
    }

    private func apply(_ device: SettingsTasmotaDevice) {
        draft.type = .tasmota
        draft.ipAddress = device.ipAddress
        if draft.name.isEmpty || !isEditing { draft.name = device.name }
        testMessage = nil
    }

    // Home Assistant

    @ViewBuilder
    private var homeAssistantSections: some View {
        if !haConfigured {
            Section {
                Label("Home Assistant isn't connected yet. Enter its URL and access token under Network & Integrations first.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                NavigationLink("Open Network & Integrations") { SettingsNetworkView() }
            }
        }
        Section {
            NavigationLink {
                SettingsHAEntityPicker(
                    selection: $draft.haEntityId,
                    excluded: Set(existingPlugs.filter { $0.id != editingPlug?.id }.compactMap(\.haEntityId)),
                    onPick: { entity in if draft.name.isEmpty { draft.name = String(entity.friendlyName.prefix(100)) } }
                )
            } label: {
                LabeledContent("Entity") {
                    Text(draft.haEntityId.isEmpty ? "Choose…" : draft.haEntityId)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(draft.haEntityId.isEmpty ? .secondary : .primary)
                }
            }
            .disabled(!haConfigured)
        } header: {
            Text("Entity")
        } footer: {
            Text("Switches, lights, input booleans and scripts can be used. Search to find any other entity.")
        }
        if !draft.haEntityId.isEmpty, haConfigured {
            Section {
                sensorPicker("Power (W)", selection: $draft.haPowerEntity, units: SettingsHASensorEntity.powerUnits)
                sensorPicker("Energy Today (kWh)", selection: $draft.haEnergyTodayEntity, units: SettingsHASensorEntity.energyUnits)
                sensorPicker("Total Energy (kWh)", selection: $draft.haEnergyTotalEntity, units: SettingsHASensorEntity.energyUnits)
                if let haSensorsError {
                    Text(haSensorsError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Energy Monitoring (Optional)")
            } footer: {
                Text("Pick separate Home Assistant sensors if the switch doesn't report power and energy itself.")
            }
        }
    }

    private func sensorPicker(_ title: String, selection: Binding<String>, units: Set<String>) -> some View {
        NavigationLink {
            SettingsHASensorEntityPicker(title: title, sensors: haSensors.filter { units.contains($0.unitOfMeasurement ?? "") }, selection: selection)
        } label: {
            LabeledContent(title) {
                Text(selection.wrappedValue.isEmpty ? "None" : selection.wrappedValue)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MQTT

    @ViewBuilder
    private var mqttSections: some View {
        if !mqttConfigured {
            Section {
                Label("No MQTT broker is configured. Set one up under Network & Integrations → MQTT before adding an MQTT plug.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                NavigationLink("Open Network & Integrations") { SettingsNetworkView() }
            }
        }
        Section {
            plainField("Topic", text: $draft.mqttPowerTopic, prompt: "zigbee2mqtt/workshop-plug")
            plainField("JSON Path", text: $draft.mqttPowerPath, prompt: "power")
            decimalField("Multiplier", text: $draft.mqttPowerMultiplier)
        } header: {
            Text("Power")
        } footer: {
            Text("Leave the JSON path empty when the topic's payload is the bare number. Use the multiplier to convert units, e.g. 0.001 for mW.")
        }
        Section {
            plainField("Topic", text: $draft.mqttEnergyTopic, prompt: "Same as power, or another topic")
            plainField("JSON Path", text: $draft.mqttEnergyPath, prompt: "energy")
            decimalField("Multiplier", text: $draft.mqttEnergyMultiplier)
        } header: {
            Text("Energy (Optional)")
        } footer: {
            Text("Energy values are shown as today's usage in kWh.")
        }
        Section {
            plainField("Topic", text: $draft.mqttStateTopic, prompt: "Same as power, or another topic")
            plainField("JSON Path", text: $draft.mqttStatePath, prompt: "state")
            plainField("On Value", text: $draft.mqttStateOnValue, prompt: "ON, true or 1")
        } header: {
            Text("State (Optional)")
        } footer: {
            Text("The value that means the plug is switched on. At least one of the power, energy or state topics is required.")
        }
    }

    // REST

    @ViewBuilder
    private var restSections: some View {
        Section {
            Picker("Method", selection: $draft.restMethod) {
                ForEach(SettingsSmartPlugDraft.restMethods, id: \.self) { Text($0).tag($0) }
            }
            urlField("ON URL", text: $draft.restOnUrl, prompt: "http://openhab:8080/rest/items/Plug")
            plainField("ON Body", text: $draft.restOnBody, prompt: "Optional, e.g. ON", axis: .vertical)
            urlField("OFF URL", text: $draft.restOffUrl, prompt: "http://openhab:8080/rest/items/Plug")
            plainField("OFF Body", text: $draft.restOffBody, prompt: "Optional, e.g. OFF", axis: .vertical)
        } header: {
            Text("Control")
        } footer: {
            Text("At least one URL is required. The body is sent as-is with the chosen method.")
        }
        Section {
            TextField("Headers", text: $draft.restHeaders, prompt: Text(#"{"Authorization": "Bearer …"}"#), axis: .vertical)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2...6)
        } header: {
            Text("Headers (Optional)")
        } footer: {
            Text("A JSON object of extra HTTP headers sent with every request.")
        }
        Section {
            urlField("Status URL", text: $draft.restStatusUrl, prompt: "URL that returns the current state")
            plainField("JSON Path", text: $draft.restStatusPath, prompt: "e.g. state or data.power")
            plainField("On Value", text: $draft.restStatusOnValue, prompt: "ON")
        } header: {
            Text("State (Optional)")
        }
        Section {
            urlField("Power URL", text: $draft.restPowerUrl, prompt: "Defaults to the status URL")
            plainField("Power Path", text: $draft.restPowerPath, prompt: "e.g. apower")
            decimalField("Power Multiplier", text: $draft.restPowerMultiplier)
            urlField("Energy URL", text: $draft.restEnergyUrl, prompt: "Defaults to the power URL")
            plainField("Today Path", text: $draft.restEnergyPath, prompt: "Today's usage, resets at midnight")
            decimalField("Today Multiplier", text: $draft.restEnergyMultiplier)
            plainField("Lifetime Path", text: $draft.restEnergyTotalPath, prompt: "e.g. aenergy.total")
            decimalField("Lifetime Multiplier", text: $draft.restEnergyTotalMultiplier)
        } header: {
            Text("Energy (Optional)")
        } footer: {
            Text("Power is read in watts and energy in kWh; use the multipliers to convert (e.g. 0.001 for Wh). A lifetime counter lets Bambuddy work out daily totals for devices that only report one.")
        }
        if session.can("smart_plugs:control"), !(draft.restOnUrl.isEmpty && draft.restOffUrl.isEmpty) {
            Section {
                Button {
                    Task { await testREST() }
                } label: {
                    HStack {
                        Label("Test Connection", systemImage: "wifi")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isTesting)
                if let testMessage { SettingsTestResultLabel(success: testMessage.success, message: testMessage.text) }
            } footer: {
                Text("Sends a request to the ON URL (or the OFF URL when there's no ON URL) and reports whether it answered. The plug may switch.")
            }
        }
    }

    // Linking

    private var availablePrinters: [Printer] {
        let printers = session.printers.printers
        guard draft.type == .tasmota else { return printers }
        let taken = Set(existingPlugs.filter { $0.id != editingPlug?.id && $0.type == .tasmota }.compactMap(\.printerId))
        return printers.filter { !taken.contains($0.id) || $0.id == draft.printerId }
    }

    private var printerSection: some View {
        Section {
            Picker("Printer", selection: $draft.printerId) {
                Text("None").tag(Int?.none)
                ForEach(availablePrinters) { printer in
                    Text(printer.name).tag(Int?.some(printer.id))
                }
            }
            if draft.printerId != nil {
                Toggle(isOn: $draft.controlsPrinterPower) {
                    SettingsLabel("Powers the Printer", help: "Turn off for accessories such as a fan or light; they then follow the print without marking the printer offline when switched off.")
                }
            }
        } header: {
            Text("Linked Printer")
        } footer: {
            Text(draft.type == .tasmota
                 ? "A printer can have one Tasmota plug. Linking lets the plug follow the printer's jobs."
                 : "Linking lets the plug follow the printer's jobs.")
        }
    }

    @ViewBuilder
    private var automationSection: some View {
        Section {
            Toggle(isOn: $draft.enabled) { SettingsLabel("Automation", help: "Allow Bambuddy to switch this plug automatically.") }
            Toggle(isOn: $draft.autoOn) { SettingsLabel("Turn On When a Print Starts") }
            Toggle(isOn: $draft.autoOff) { SettingsLabel("Turn Off When a Print Finishes") }
            if draft.autoOff {
                Toggle(isOn: $draft.autoOffPersistent) {
                    SettingsLabel("Keep Auto Off Enabled", help: "Otherwise auto off switches itself off again after it has run once.")
                }
                Picker("Turn Off After", selection: $draft.offDelayMode) {
                    Text("A Delay").tag("time")
                    Text("Cooling Down").tag("temperature")
                }
                if draft.offDelayMode == "temperature" {
                    Stepper(value: $draft.offTempThreshold, in: 30...150, step: 5) {
                        LabeledContent("Nozzle Below", value: "\(draft.offTempThreshold) °C")
                    }
                } else {
                    Stepper(value: $draft.offDelayMinutes, in: 0...60) {
                        LabeledContent("Delay", value: "\(draft.offDelayMinutes) min")
                    }
                }
            }
            Toggle(isOn: $draft.autoOffAfterDrying) {
                SettingsLabel("Turn Off After AMS Drying", help: "Switch off when a drying cycle on the linked printer's AMS finishes.")
            }
            if draft.autoOffAfterDrying {
                Stepper(value: $draft.offDelayAfterDryingMinutes, in: 0...120, step: 5) {
                    LabeledContent("Delay After Drying", value: "\(draft.offDelayAfterDryingMinutes) min")
                }
            }
        } header: {
            Text("Automation")
        } footer: {
            Text("Automatic switching needs a linked printer. With the cooling-down option the plug waits until the nozzle has cooled below the threshold.")
        }
    }

    @ViewBuilder
    private var alertsSection: some View {
        Section {
            Toggle("Power Alerts", isOn: $draft.powerAlertEnabled)
            if draft.powerAlertEnabled {
                decimalField("Alert Above (W)", text: $draft.powerAlertHigh, prompt: "e.g. 200")
                decimalField("Alert Below (W)", text: $draft.powerAlertLow, prompt: "e.g. 10")
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Sends a notification when the power draw crosses a threshold (0–5000 W), at most once every five minutes.")
        }
    }

    @ViewBuilder
    private var scheduleSection: some View {
        Section {
            Toggle("Daily Schedule", isOn: $draft.scheduleEnabled)
            if draft.scheduleEnabled {
                timeRow("Turn On At", time: $draft.scheduleOnTime, fallback: "08:00")
                timeRow("Turn Off At", time: $draft.scheduleOffTime, fallback: "22:00")
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text("Switches the plug at the same time every day, using the server's time zone.")
        }
    }

    private func timeRow(_ title: String, time: Binding<String>, fallback: String) -> some View {
        Group {
            Toggle(title, isOn: Binding(get: { !time.wrappedValue.isEmpty }, set: { time.wrappedValue = $0 ? fallback : "" }))
            if !time.wrappedValue.isEmpty {
                DatePicker(title, selection: Binding(
                    get: { settingsSmartPlugDate(from: time.wrappedValue) },
                    set: { time.wrappedValue = settingsSmartPlugTimeString(from: $0) }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var visibilitySection: some View {
        Section {
            Toggle(isOn: $draft.showInSwitchbar) {
                SettingsLabel("Show in Switchbar", help: "Adds the plug to the quick-access switch bar in the web interface.")
            }
            if draft.type == .homeassistant {
                Toggle(isOn: $draft.showOnPrinterCard) {
                    SettingsLabel("Show on Printer Card", help: "Shows a button for this entity on the linked printer's card.")
                }
            }
        } header: {
            Text("Visibility")
        }
    }

    // MARK: Field helpers

    private func plainField(_ title: String, text: Binding<String>, prompt: String, axis: Axis = .horizontal) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt), axis: axis)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func urlField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            TextField(title, text: text, prompt: Text(prompt), axis: .vertical)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout)
        }
    }

    private func decimalField(_ title: String, text: Binding<String>, prompt: String = "1") -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
        }
    }

    // MARK: Actions

    private func populate() {
        guard !didPopulate else { return }
        didPopulate = true
        switch target {
        case .edit(let plug):
            draft = SettingsSmartPlugDraft(plug: plug)
        case .add(let device):
            if let device { apply(device) }
        }
    }

    private func loadHASensors() async {
        guard draft.type == .homeassistant, haConfigured else { return }
        do {
            haSensors = try await session.client.get("smart-plugs/ha/sensors")
            haSensorsError = nil
        } catch is CancellationError {
        } catch {
            haSensorsError = "Couldn't load Home Assistant sensors: \(error.localizedDescription)"
        }
    }

    private func testTasmota() async {
        isTesting = true
        defer { isTesting = false }
        testMessage = nil
        let body: [String: JSONValue] = [
            "ip_address": .string(draft.ipAddress.trimmingCharacters(in: .whitespaces)),
            "username": draft.username.isEmpty ? .null : .string(draft.username),
            "password": draft.password.isEmpty ? .null : .string(draft.password),
        ]
        do {
            let result: SettingsSmartPlugTestResult = try await session.client.send(.post, "smart-plugs/test-connection", body: JSONValue.object(body))
            var parts = ["Connected"]
            if let name = result.deviceName, !name.isEmpty { parts.append("to \(name)") }
            if let state = result.state { parts.append("— currently \(state)") }
            testMessage = (true, parts.joined(separator: " "))
            if draft.name.isEmpty, let name = result.deviceName { draft.name = name }
        } catch {
            testMessage = (false, error.localizedDescription)
        }
    }

    private func testREST() async {
        isTesting = true
        defer { isTesting = false }
        testMessage = nil
        let url = draft.restOnUrl.trimmingCharacters(in: .whitespaces).isEmpty ? draft.restOffUrl : draft.restOnUrl
        let headers = draft.restHeaders.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: JSONValue] = [
            "url": .string(url.trimmingCharacters(in: .whitespaces)),
            "method": .string(draft.restMethod),
            "headers": headers.isEmpty ? .null : .string(headers),
        ]
        do {
            let result: SettingsSmartPlugRESTTestResult = try await session.client.send(.post, "smart-plugs/rest/test-connection", body: JSONValue.object(body))
            testMessage = result.success ? (true, "The endpoint responded.") : (false, result.error ?? "The endpoint didn't respond.")
        } catch {
            testMessage = (false, error.localizedDescription)
        }
    }

    private func save() async {
        if let problem = draft.validationError() {
            validationMessage = problem
            return
        }
        let body = JSONValue.object(draft.body())
        let client = session.client
        var saved = false
        await runner.run {
            if let plug = editingPlug {
                let _: SettingsSmartPlug = try await client.send(.patch, "smart-plugs/\(plug.id)", body: body)
            } else {
                let _: SettingsSmartPlug = try await client.send(.post, "smart-plugs/", body: body)
            }
            saved = true
        }
        guard saved else { return }
        await onSaved()
        dismiss()
    }

    private func delete() async {
        guard let plug = editingPlug else { return }
        let client = session.client
        var deleted = false
        await runner.run {
            try await client.call(.delete, "smart-plugs/\(plug.id)")
            deleted = true
        }
        guard deleted else { return }
        await onSaved()
        dismiss()
    }
}

// MARK: - Time helpers

private func settingsSmartPlugDate(from time: String) -> Date {
    let parts = time.split(separator: ":").compactMap { Int($0) }
    var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
    components.hour = parts.first ?? 0
    components.minute = parts.count > 1 ? parts[1] : 0
    return Calendar.current.date(from: components) ?? .now
}

private func settingsSmartPlugTimeString(from date: Date) -> String {
    let components = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
}

// MARK: - Home Assistant pickers

/// Searchable list of switchable Home Assistant entities
/// (`GET /smart-plugs/ha/entities?search=`).
struct SettingsHAEntityPicker: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    var excluded: Set<String>
    var onPick: (SettingsHAEntity) -> Void

    @State private var search = ""
    @State private var loader = Loader<[SettingsHAEntity]>()

    var body: some View {
        LoadingContent(loader: loader, retry: { await load() }) { entities in
            let available = entities.filter { !excluded.contains($0.entityId) }
            List {
                if available.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Entities" : "No Matches",
                                           systemImage: "house",
                                           description: Text(search.isEmpty
                                                             ? "Home Assistant has no unused switches, lights, input booleans or scripts."
                                                             : "Nothing matches “\(search)”."))
                } else {
                    Section {
                        ForEach(available) { entity in
                            Button {
                                selection = entity.entityId
                                onPick(entity)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entity.friendlyName).foregroundStyle(.primary)
                                        Text(entity.entityId).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let state = entity.state { Text(state).font(.caption).foregroundStyle(.secondary) }
                                    if entity.entityId == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    } footer: {
                        Text(search.isEmpty ? "\(available.count) entities" : "\(available.count) matching entities")
                    }
                }
            }
        }
        .navigationTitle("Entity")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search all entities")
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        let client = session.client
        let query = search.trimmingCharacters(in: .whitespaces)
        await loader.load {
            try await client.get("smart-plugs/ha/entities", query: ["search": query.isEmpty ? nil : .string(query)])
        }
    }
}

/// Picks one of the already loaded Home Assistant sensors, or none.
private struct SettingsHASensorEntityPicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let sensors: [SettingsHASensorEntity]
    @Binding var selection: String
    @State private var search = ""

    private var filtered: [SettingsHASensorEntity] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sensors }
        return sensors.filter { $0.entityId.lowercased().contains(needle) || $0.friendlyName.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            Button {
                selection = ""
                dismiss()
            } label: {
                HStack {
                    Text("None").foregroundStyle(.primary)
                    Spacer()
                    if selection.isEmpty { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            Section {
                if filtered.isEmpty {
                    Text(sensors.isEmpty ? "Home Assistant has no sensors with a matching unit." : "No matching sensors.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { sensor in
                    Button {
                        selection = sensor.entityId
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sensor.friendlyName).foregroundStyle(.primary)
                                Text(sensor.entityId).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let state = sensor.state {
                                Text([state, sensor.unitOfMeasurement].compactMap { $0 }.joined(separator: " "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if sensor.entityId == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search sensors")
    }
}

// MARK: - Tasmota discovery

/// Scans the server's local network for Tasmota devices
/// (`discover/scan` → poll `discover/status` + `discover/devices` → `discover/stop`).
struct SettingsTasmotaDiscoveryView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var configuredAddresses: Set<String> = []
    var onSelect: (SettingsTasmotaDevice) -> Void

    @State private var status: SettingsTasmotaScanStatus?
    @State private var devices: [SettingsTasmotaDevice] = []
    @State private var isScanning = false
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                if isScanning {
                    Button("Stop Scanning", systemImage: "stop.circle", role: .destructive) { Task { await stop() } }
                } else {
                    Button(status == nil ? "Scan Network" : "Scan Again", systemImage: "dot.radiowaves.left.and.right") {
                        Task { await start() }
                    }
                }
                if let status, status.total > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(status.scanned), total: Double(max(status.total, 1)))
                        Text("\(status.scanned) of \(status.total) addresses checked")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("The Bambuddy server scans its own local network for devices running Tasmota. This can take a minute.")
            }

            if !devices.isEmpty {
                Section("Found \(devices.count) \(devices.count == 1 ? "Device" : "Devices")") {
                    ForEach(devices) { device in
                        let known = configuredAddresses.contains(device.ipAddress)
                        Button {
                            onSelect(device)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text(device.ipAddress).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                Spacer()
                                if known { StatusBadge(text: "Added", color: .secondary) }
                                if let state = device.state { StatusBadge(text: state, color: state.uppercased() == "ON" ? .green : .secondary) }
                            }
                        }
                        .disabled(known)
                    }
                }
            } else if let status, !isScanning, status.total > 0 {
                Section {
                    Text("No Tasmota devices were found. Make sure they're on the same network as the server.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Discover Tasmota")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadExisting() }
        .onDisappear { pollTask?.cancel() }
    }

    /// Shows the results of a scan that is already running or has finished.
    private func loadExisting() async {
        let client = session.client
        guard let current: SettingsTasmotaScanStatus = try? await client.get("smart-plugs/discover/status") else { return }
        if current.running || current.total > 0 {
            status = current
            devices = (try? await client.get("smart-plugs/discover/devices")) ?? []
        }
        if current.running { beginPolling() }
    }

    private func start() async {
        error = nil
        devices = []
        do {
            let started: SettingsTasmotaScanStatus = try await session.client.send(.post, "smart-plugs/discover/scan")
            status = started
            beginPolling()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func beginPolling() {
        isScanning = true
        pollTask?.cancel()
        let client = session.client
        pollTask = Task {
            while !Task.isCancelled {
                if let current: SettingsTasmotaScanStatus = try? await client.get("smart-plugs/discover/status") {
                    status = current
                    if let found: [SettingsTasmotaDevice] = try? await client.get("smart-plugs/discover/devices") { devices = found }
                    if !current.running { break }
                }
                try? await Task.sleep(for: .milliseconds(750))
            }
            isScanning = false
        }
    }

    private func stop() async {
        pollTask?.cancel()
        let client = session.client
        if let stopped: SettingsTasmotaScanStatus = try? await client.send(.post, "smart-plugs/discover/stop") { status = stopped }
        if let found: [SettingsTasmotaDevice] = try? await client.get("smart-plugs/discover/devices") { devices = found }
        isScanning = false
    }
}
