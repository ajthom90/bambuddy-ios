import SwiftUI

// MARK: - Printer sensor editor

/// Binds a Home Assistant entity to a printer, or edits an existing binding.
struct SettingsSensorPrinterEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let sensor: SettingsHASensor?
    let existing: [SettingsHASensor]
    var onSaved: () async -> Void

    @State private var printerId: Int?
    @State private var entityId = ""
    @State private var deviceClass: String?
    @State private var unit: String?
    @State private var name = ""
    @State private var alert = SettingsSensorAlertDraft()
    @State private var blockPrint = false
    @State private var notifyOnAlert = false
    @State private var showOnCard = true
    @State private var entities = Loader<[SettingsHADisplayEntity]>()
    @State private var runner = ActionRunner()
    @State private var problem: String?
    @State private var confirmDelete = false
    @State private var didPopulate = false

    private var isEditing: Bool { sensor != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let sensor {
                        LabeledContent("Printer", value: session.printers.printer(sensor.printerId)?.name ?? "Unknown printer")
                    } else {
                        Picker("Printer", selection: $printerId) {
                            ForEach(session.printers.printers) { printer in
                                Text(printer.name).tag(Int?.some(printer.id))
                            }
                        }
                    }
                    NavigationLink {
                        SettingsSensorEntityPicker(loader: entities, selection: entityId, reload: loadEntities) { select($0) }
                    } label: {
                        LabeledContent("Entity") {
                            Text(entityId.isEmpty ? "Choose…" : entityId)
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(entityId.isEmpty ? .secondary : .primary)
                        }
                    }
                    TextField("Name", text: $name)
                } footer: {
                    Text("Binary sensors (doors, smoke, leaks) alert on a state; numeric sensors (temperature, humidity) alert outside a range.")
                }

                SettingsSensorAlertSection(alert: $alert, deviceClass: deviceClass, unit: unit, allowsAbove: true)

                Section {
                    Toggle(isOn: $blockPrint) {
                        SettingsLabel("Hold the Queue While Alerting", help: "Queued jobs won't start on this printer until the sensor is back to normal.")
                    }
                    Toggle(isOn: $notifyOnAlert) {
                        SettingsLabel("Notify on Alert", help: "Sends a notification when the sensor enters its alert state.")
                    }
                    Toggle(isOn: $showOnCard) {
                        SettingsLabel("Show on Printer Card")
                    }
                } footer: {
                    if (blockPrint || notifyOnAlert) && !alert.hasCondition {
                        Text("Holding the queue and notifications need an alert condition above.").foregroundStyle(.orange)
                    }
                }

                if isEditing, session.can("smart_plugs:delete") {
                    Section {
                        Button("Delete Sensor", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Printer Sensor" : "Add Printer Sensor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { ProgressView() } else {
                        Button(isEditing ? "Save" : "Add") { Task { await save() } }
                            .disabled(!session.can(isEditing ? "smart_plugs:update" : "smart_plugs:create"))
                    }
                }
            }
            .alert("Check the Form", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
            .confirm("Delete \(name.isEmpty ? "Sensor" : name)?", isPresented: $confirmDelete,
                     message: "The sensor is unbound from its printer. Home Assistant is not changed.") {
                Task { await delete() }
            }
            .actionAlerts(runner)
            .onAppear(perform: populate)
            .task { await loadEntities() }
        }
        .interactiveDismissDisabled(runner.isRunning)
    }

    private func populate() {
        guard !didPopulate else { return }
        didPopulate = true
        guard let sensor else {
            printerId = session.printers.printers.first?.id
            return
        }
        printerId = sensor.printerId
        entityId = sensor.entityId
        deviceClass = sensor.deviceClass
        unit = sensor.unit
        name = sensor.name
        alert = SettingsSensorAlertDraft(
            kind: sensor.kind ?? "binary",
            alertState: sensor.alertState ?? "",
            alertAbove: sensor.alertAbove.map(SettingsSmartPlugDraft.format) ?? "",
            alertBelow: sensor.alertBelow.map(SettingsSmartPlugDraft.format) ?? ""
        )
        blockPrint = sensor.blockPrint ?? false
        notifyOnAlert = sensor.notifyOnAlert ?? false
        showOnCard = sensor.showOnPrinterCard ?? true
    }

    private func loadEntities() async {
        let client = session.client
        await entities.load { try await client.get("ha-sensors/entities") }
    }

    private func select(_ entity: SettingsHADisplayEntity) {
        entityId = entity.entityId
        deviceClass = entity.deviceClass
        unit = entity.unitOfMeasurement.map { String($0.prefix(16)) }
        let kind = entity.kind
        if kind != alert.kind {
            alert = SettingsSensorAlertDraft(kind: kind)
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = String(entity.friendlyName.prefix(100)) }
    }

    private func save() async {
        if entityId.isEmpty { problem = "Choose a Home Assistant entity."; return }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problem = "Enter a name."; return }
        if !isEditing, printerId == nil { problem = "Choose a printer."; return }
        if let error = alert.validationError() { problem = error; return }
        if (blockPrint || notifyOnAlert) && !alert.hasCondition {
            problem = "Holding the queue or notifying needs an alert condition."
            return
        }
        if !isEditing, let printerId, existing.contains(where: { $0.printerId == printerId && $0.entityId == entityId }) {
            problem = "\(entityId) is already bound to this printer."
            return
        }
        var body: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "entity_id": .string(entityId),
            "kind": .string(alert.kind),
            "device_class": deviceClass.map { .string($0) } ?? .null,
            "unit": unit.map { .string($0) } ?? .null,
            "block_print": .bool(blockPrint),
            "notify_on_alert": .bool(notifyOnAlert),
            "show_on_printer_card": .bool(showOnCard),
        ]
        body.merge(alert.fields()) { _, new in new }
        let client = session.client
        var saved = false
        await runner.run {
            if let sensor {
                let _: SettingsHASensor = try await client.send(.patch, "ha-sensors/\(sensor.id)", body: JSONValue.object(body))
            } else {
                body["printer_id"] = .number(Double(printerId ?? 0))
                let _: SettingsHASensor = try await client.send(.post, "ha-sensors/", body: JSONValue.object(body))
            }
            saved = true
        }
        guard saved else { return }
        await onSaved()
        dismiss()
    }

    private func delete() async {
        guard let sensor else { return }
        let client = session.client
        var deleted = false
        await runner.run {
            try await client.call(.delete, "ha-sensors/\(sensor.id)")
            deleted = true
        }
        guard deleted else { return }
        await onSaved()
        dismiss()
    }
}

// MARK: - Location sensor editor

/// Binds a temperature, humidity or battery sensor to a storage location.
struct SettingsLocationSensorEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let sensor: SettingsLocationSensor?
    let existing: [SettingsLocationSensor]
    var onSaved: () async -> Void

    @State private var locations: [SettingsLocationSensorPlace]
    @State private var locationId: Int?
    @State private var entityId = ""
    @State private var deviceClass: String?
    @State private var unit: String?
    @State private var name = ""
    @State private var autoFilledName = ""
    @State private var alert = SettingsSensorAlertDraft(kind: "numeric")
    @State private var notifyOnAlert = false
    @State private var showOnCard = true
    @State private var entities = Loader<[SettingsHADisplayEntity]>()
    @State private var runner = ActionRunner()
    @State private var problem: String?
    @State private var confirmDelete = false
    @State private var overwriteTarget: SettingsLocationSensor?
    @State private var siblings: [SettingsHADisplayEntity] = []
    @State private var showNewLocation = false
    @State private var newLocationName = ""
    @State private var didPopulate = false

    init(sensor: SettingsLocationSensor?, locations: [SettingsLocationSensorPlace], existing: [SettingsLocationSensor], onSaved: @escaping () async -> Void) {
        self.sensor = sensor
        self.existing = existing
        self.onSaved = onSaved
        _locations = State(initialValue: locations)
    }

    private var isEditing: Bool { sensor != nil }
    private var category: SettingsLocationSensorCategory? { SettingsLocationSensorCategory(deviceClass: deviceClass) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let sensor {
                        LabeledContent("Location", value: locations.first { $0.id == sensor.locationId }?.name ?? "Unknown location")
                    } else {
                        Picker("Location", selection: $locationId) {
                            if locationId == nil { Text("Choose…").tag(Int?.none) }
                            ForEach(locations) { location in
                                Text(location.name).tag(Int?.some(location.id))
                            }
                        }
                        if session.can("inventory:update") {
                            Button("New Location…", systemImage: "plus") {
                                newLocationName = ""
                                showNewLocation = true
                            }
                        }
                    }
                    NavigationLink {
                        SettingsSensorEntityPicker(loader: entities, selection: entityId, reload: loadEntities,
                                                   filter: { SettingsLocationSensorCategory(deviceClass: $0.deviceClass) != nil }) { select($0) }
                    } label: {
                        LabeledContent("Entity") {
                            Text(entityId.isEmpty ? "Choose…" : entityId)
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(entityId.isEmpty ? .secondary : .primary)
                        }
                    }
                    TextField("Name", text: $name)
                } footer: {
                    Text("Only Home Assistant sensors with the temperature, humidity or battery device class can be bound to a location.")
                }

                SettingsSensorAlertSection(alert: $alert, deviceClass: deviceClass, unit: unit, allowsAbove: category?.allowsAlertAbove ?? true)

                Section {
                    Toggle(isOn: $showOnCard) {
                        SettingsLabel("Show on Inventory Card", help: "Shows the reading on the location's spools in Inventory.")
                    }
                    Toggle(isOn: $notifyOnAlert) {
                        SettingsLabel("Notify on Alert")
                    }
                } footer: {
                    if notifyOnAlert && !alert.hasCondition {
                        Text("Notifications need an alert threshold above.").foregroundStyle(.orange)
                    }
                }

                if isEditing, session.can("smart_plugs:delete") {
                    Section {
                        Button("Delete Sensor", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Location Sensor" : "Add Location Sensor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { ProgressView() } else {
                        Button(isEditing ? "Save" : "Add") { Task { await save() } }
                            .disabled(!session.can(isEditing ? "smart_plugs:update" : "smart_plugs:create"))
                    }
                }
            }
            .alert("Check the Form", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
            .alert("New Location", isPresented: $showNewLocation) {
                TextField("Name", text: $newLocationName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await createLocation() } }
            } message: {
                Text("Adds a storage location to Inventory.")
            }
            .confirmationDialog("Replace the \(category?.title.lowercased() ?? "existing") sensor?",
                                isPresented: Binding(get: { overwriteTarget != nil }, set: { if !$0 { overwriteTarget = nil } }),
                                titleVisibility: .visible) {
                if let target = overwriteTarget {
                    Button("Replace \(target.entityId)", role: .destructive) { Task { await overwrite(target) } }
                }
            } message: {
                Text("A location can have only one \(category?.title.lowercased() ?? "") sensor. The existing binding will point to the new entity instead.")
            }
            .confirmationDialog("Add Matching Sensors?", isPresented: Binding(get: { !siblings.isEmpty }, set: { if !$0 { siblings = [] } }),
                                titleVisibility: .visible) {
                Button("Add All \(siblings.count + 1)") { Task { await createWithSiblings(siblings) } }
                Button("Only This One") { Task { await create(extra: []) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The same device also reports " + siblings.map(\.entityId).joined(separator: ", ") + ". They can be added now with the default alert rules.")
            }
            .confirm("Delete \(name.isEmpty ? "Sensor" : name)?", isPresented: $confirmDelete,
                     message: "The sensor is unbound from its location. Home Assistant is not changed.") {
                Task { await delete() }
            }
            .actionAlerts(runner)
            .onAppear(perform: populate)
            .task { await loadEntities() }
            .task { if !store.hasLoaded { await store.load() } }
        }
        .interactiveDismissDisabled(runner.isRunning)
    }

    private func populate() {
        guard !didPopulate else { return }
        didPopulate = true
        guard let sensor else {
            locationId = locations.first?.id
            return
        }
        locationId = sensor.locationId
        entityId = sensor.entityId
        deviceClass = sensor.deviceClass
        unit = sensor.unit
        name = sensor.name
        autoFilledName = sensor.name
        alert = SettingsSensorAlertDraft(
            kind: sensor.kind ?? "numeric",
            alertState: sensor.alertState ?? "",
            alertAbove: sensor.alertAbove.map(SettingsSmartPlugDraft.format) ?? "",
            alertBelow: sensor.alertBelow.map(SettingsSmartPlugDraft.format) ?? ""
        )
        notifyOnAlert = sensor.notifyOnAlert ?? false
        showOnCard = sensor.showOnCard ?? true
    }

    private func loadEntities() async {
        let client = session.client
        await entities.load { try await client.get("location-ha-sensors/entities") }
    }

    private var defaults: SettingsLocationSensorDefaults {
        SettingsLocationSensorDefaults.parse(store.string("location_sensor_alert_defaults"))
    }

    private func select(_ entity: SettingsHADisplayEntity) {
        entityId = entity.entityId
        deviceClass = entity.deviceClass
        unit = entity.unitOfMeasurement.map { String($0.prefix(16)) }
        let kind = entity.kind
        if kind != alert.kind { alert = SettingsSensorAlertDraft(kind: kind) }
        // Follow the entity's name only while the field still holds what we filled in.
        if name == autoFilledName {
            name = String(entity.friendlyName.prefix(100))
            autoFilledName = name
        }
        if !isEditing, let category = SettingsLocationSensorCategory(deviceClass: entity.deviceClass) {
            let rule = defaults[category]
            if kind == "numeric" {
                alert.alertAbove = category.allowsAlertAbove ? rule.alertAbove : ""
                alert.alertBelow = rule.alertBelow
            }
            notifyOnAlert = rule.notifyOnAlert
            showOnCard = SettingsLocationSensorShowOnCard.get(category)
        }
    }

    private func primaryBody() -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "entity_id": .string(entityId),
            "kind": .string(alert.kind),
            "device_class": deviceClass.map { .string($0) } ?? .null,
            "unit": unit.map { .string($0) } ?? .null,
            "notify_on_alert": .bool(notifyOnAlert),
            "show_on_card": .bool(showOnCard),
        ]
        body.merge(alert.fields(allowsAbove: category?.allowsAlertAbove ?? true)) { _, new in new }
        return body
    }

    private func save() async {
        if entityId.isEmpty { problem = "Choose a Home Assistant entity."; return }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problem = "Enter a name."; return }
        if !isEditing, locationId == nil { problem = "Choose a location."; return }
        if let error = alert.validationError(allowsAbove: category?.allowsAlertAbove ?? true) { problem = error; return }
        if notifyOnAlert && !alert.hasCondition { problem = "Notifications need an alert threshold."; return }

        if let sensor {
            let client = session.client
            let body = primaryBody()
            var saved = false
            await runner.run {
                let _: SettingsLocationSensor = try await client.send(.patch, "location-ha-sensors/\(sensor.id)", body: JSONValue.object(body))
                saved = true
            }
            if saved { await finish() }
            return
        }

        guard let locationId else { return }
        let atLocation = existing.filter { $0.locationId == locationId }
        if let category, let conflict = atLocation.first(where: { $0.category == category }) {
            overwriteTarget = conflict
            return
        }
        if atLocation.isEmpty, let category {
            let found = siblingEntities(of: entityId, category: category)
            if !found.isEmpty {
                siblings = found
                return
            }
        }
        await create(extra: [])
    }

    /// Other sensors of the same device, found by swapping the category suffix
    /// of the entity id (`sensor.box_temperature` → `sensor.box_humidity`).
    private func siblingEntities(of entityId: String, category: SettingsLocationSensorCategory) -> [SettingsHADisplayEntity] {
        let lower = entityId.lowercased()
        guard lower.hasSuffix(category.rawValue) else { return [] }
        let prefix = String(lower.dropLast(category.rawValue.count))
        let candidates = entities.value ?? []
        return SettingsLocationSensorCategory.allCases.filter { $0 != category }.compactMap { other in
            candidates.first { $0.entityId.lowercased() == prefix + other.rawValue }
        }
    }

    private func createWithSiblings(_ extra: [SettingsHADisplayEntity]) async {
        siblings = []
        await create(extra: extra)
    }

    private func create(extra: [SettingsHADisplayEntity]) async {
        guard let locationId else { return }
        var primary = primaryBody()
        primary["location_id"] = .number(Double(locationId))
        let rules = defaults
        let extraBodies: [JSONValue] = extra.map { entity in
            let category = SettingsLocationSensorCategory(deviceClass: entity.deviceClass)
            let rule = category.map { rules[$0] }
            let kind = entity.kind
            var alert = SettingsSensorAlertDraft(kind: kind)
            if kind == "numeric", let rule, let category {
                alert.alertAbove = category.allowsAlertAbove ? rule.alertAbove : ""
                alert.alertBelow = rule.alertBelow
            }
            var body: [String: JSONValue] = [
                "location_id": .number(Double(locationId)),
                "name": .string(String(entity.friendlyName.prefix(100))),
                "entity_id": .string(entity.entityId),
                "kind": .string(kind),
                "device_class": entity.deviceClass.map { .string($0) } ?? .null,
                "unit": entity.unitOfMeasurement.map { .string(String($0.prefix(16))) } ?? .null,
                "notify_on_alert": .bool((rule?.notifyOnAlert ?? false) && alert.hasCondition),
                "show_on_card": .bool(category.map(SettingsLocationSensorShowOnCard.get) ?? showOnCard),
            ]
            body.merge(alert.fields(allowsAbove: category?.allowsAlertAbove ?? true)) { _, new in new }
            return .object(body)
        }
        let client = session.client
        var created = false
        let message = extra.isEmpty ? nil : "Added \(extra.count + 1) sensors"
        await runner.run(message) {
            let _: SettingsLocationSensor = try await client.send(.post, "location-ha-sensors/", body: JSONValue.object(primary))
            created = true
            for body in extraBodies {
                let _: SettingsLocationSensor = try await client.send(.post, "location-ha-sensors/", body: body)
            }
        }
        if created { await finish() }
    }

    private func overwrite(_ target: SettingsLocationSensor) async {
        overwriteTarget = nil
        let client = session.client
        let body = primaryBody()
        var saved = false
        await runner.run {
            let _: SettingsLocationSensor = try await client.send(.patch, "location-ha-sensors/\(target.id)", body: JSONValue.object(body))
            saved = true
        }
        if saved { await finish() }
    }

    private func createLocation() async {
        let trimmed = newLocationName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let client = session.client
        await runner.run {
            let location: SettingsLocationSensorPlace = try await client.send(.post, "inventory/locations", body: ["name": trimmed])
            locations.append(location)
            locationId = location.id
        }
    }

    private func delete() async {
        guard let sensor else { return }
        let client = session.client
        var deleted = false
        await runner.run {
            try await client.call(.delete, "location-ha-sensors/\(sensor.id)")
            deleted = true
        }
        if deleted { await finish() }
    }

    private func finish() async {
        await onSaved()
        dismiss()
    }
}

// MARK: - Shared pieces

/// "Alert when…" controls: a state for binary sensors, thresholds for numeric ones.
private struct SettingsSensorAlertSection: View {
    @Binding var alert: SettingsSensorAlertDraft
    let deviceClass: String?
    let unit: String?
    let allowsAbove: Bool

    var body: some View {
        Section {
            if alert.kind == "binary" {
                Picker("Alert When", selection: $alert.alertState) {
                    Text("Never").tag("")
                    Text(SettingsSensorDisplay.stateLabel("on", deviceClass: deviceClass)).tag("on")
                    Text(SettingsSensorDisplay.stateLabel("off", deviceClass: deviceClass)).tag("off")
                }
            } else {
                if allowsAbove {
                    threshold("Alert Above", text: $alert.alertAbove)
                }
                threshold("Alert Below", text: $alert.alertBelow)
            }
        } header: {
            Text("Alert")
        } footer: {
            Text(alert.kind == "binary"
                 ? "Leave on Never to only display the sensor."
                 : "Leave both empty to only display the sensor.")
        }
    }

    private func threshold(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("None", text: text)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                if let unit, !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Searchable list of bindable Home Assistant entities.
private struct SettingsSensorEntityPicker: View {
    @Environment(\.dismiss) private var dismiss
    let loader: Loader<[SettingsHADisplayEntity]>
    let selection: String
    var reload: () async -> Void
    var filter: (SettingsHADisplayEntity) -> Bool = { _ in true }
    var onPick: (SettingsHADisplayEntity) -> Void
    @State private var search = ""

    init(loader: Loader<[SettingsHADisplayEntity]>, selection: String, reload: @escaping () async -> Void,
         filter: @escaping (SettingsHADisplayEntity) -> Bool = { _ in true }, onPick: @escaping (SettingsHADisplayEntity) -> Void) {
        self.loader = loader
        self.selection = selection
        self.reload = reload
        self.filter = filter
        self.onPick = onPick
    }

    var body: some View {
        LoadingContent(loader: loader, retry: reload) { all in
            let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
            let matches = all.filter(filter).filter {
                needle.isEmpty || $0.entityId.lowercased().contains(needle) || $0.friendlyName.lowercased().contains(needle)
            }
            List {
                if matches.isEmpty {
                    ContentUnavailableView(needle.isEmpty ? "No Entities" : "No Matches", systemImage: "sensor",
                                           description: Text(needle.isEmpty ? "Home Assistant has no sensors that can be bound here." : "Nothing matches “\(search)”."))
                }
                ForEach(matches) { entity in
                    Button {
                        onPick(entity)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: SettingsSensorDisplay.systemImage(deviceClass: entity.deviceClass, kind: entity.kind, state: entity.state))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entity.friendlyName).foregroundStyle(.primary)
                                Text(entity.entityId).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let state = entity.state {
                                Text([state, entity.unitOfMeasurement].compactMap { $0 }.joined(separator: " "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if entity.entityId == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Entity")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search entities")
        .refreshable { await reload() }
    }
}

/// Per-device preference for whether new location sensors start visible on the
/// Inventory card (the web app keeps this per browser, too).
enum SettingsLocationSensorShowOnCard {
    private static func key(_ category: SettingsLocationSensorCategory) -> String {
        "settings.locationSensor.showOnCard.\(category.rawValue)"
    }

    static func get(_ category: SettingsLocationSensorCategory) -> Bool {
        UserDefaults.standard.object(forKey: key(category)) as? Bool ?? true
    }

    static func set(_ value: Bool, for category: SettingsLocationSensorCategory) {
        UserDefaults.standard.set(value, forKey: key(category))
    }
}

// MARK: - Options

/// Poll interval and the default alert rules for new location sensors.
struct SettingsLocationSensorOptionsView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store

    let sensors: [SettingsLocationSensor]
    var onChanged: () async -> Void

    @State private var defaults = SettingsLocationSensorDefaults.builtIn
    @State private var showOnCard: [SettingsLocationSensorCategory: Bool] = [:]
    @State private var seeded = false
    @State private var confirmApply = false
    @State private var runner = ActionRunner()

    var body: some View {
        SettingsForm("Location Sensor Options") {
            Section {
                SettingsNumberField("Refresh Every", key: "location_sensor_poll_interval", unit: "s", range: 60...3600)
            } footer: {
                Text("How often Bambuddy reads location sensors from Home Assistant (60–3600 seconds).")
            }

            ForEach(SettingsLocationSensorCategory.allCases) { category in
                categorySection(category)
            }

            if session.can("smart_plugs:update") {
                Section {
                    Button("Apply Defaults to Existing Sensors", systemImage: "arrow.counterclockwise") { confirmApply = true }
                        .disabled(sensors.isEmpty || runner.isRunning)
                } footer: {
                    Text("Resets the thresholds, notifications, visibility and names of all \(sensors.count) bound location sensors to these defaults.")
                }
            }
        }
        .confirm("Apply Defaults to \(sensors.count) Sensors?", isPresented: $confirmApply,
                 message: "Every temperature, humidity and battery sensor bound to a location gets these alert rules, and its name is reset to the Home Assistant name.",
                 action: "Apply") {
            Task { await applyToExisting() }
        }
        .actionAlerts(runner)
        .onAppear(perform: seed)
        .onChange(of: store.hasLoaded) { _, _ in seed() }
    }

    private func categorySection(_ category: SettingsLocationSensorCategory) -> some View {
        let rule = Binding(get: { defaults[category] }, set: { defaults[category] = $0; persist() })
        let hasCondition = !(rule.wrappedValue.alertBelow.isEmpty && (!category.allowsAlertAbove || rule.wrappedValue.alertAbove.isEmpty))
        return Section {
            if category.allowsAlertAbove {
                thresholdField("Alert Above", text: rule.alertAbove, unit: category.unitHint)
            }
            thresholdField("Alert Below", text: rule.alertBelow, unit: category.unitHint)
            Toggle("Notify on Alert", isOn: rule.notifyOnAlert)
                .disabled(!hasCondition || !store.canEdit)
            Toggle(isOn: Binding(get: { showOnCard[category] ?? true }, set: { value in
                showOnCard[category] = value
                SettingsLocationSensorShowOnCard.set(value, for: category)
            })) {
                SettingsLabel("Show on Inventory Card", help: "Remembered on this device.")
            }
        } header: {
            Label(category.title, systemImage: category.systemImage)
        }
    }

    private func thresholdField(_ title: String, text: Binding<String>, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("None", text: text)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
                    .disabled(!store.canEdit)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func seed() {
        guard !seeded, store.hasLoaded else { return }
        seeded = true
        defaults = SettingsLocationSensorDefaults.parse(store.string("location_sensor_alert_defaults"))
        for category in SettingsLocationSensorCategory.allCases {
            showOnCard[category] = SettingsLocationSensorShowOnCard.get(category)
        }
    }

    /// Saves the defaults (debounced) once they differ from what the server has.
    private func persist() {
        guard store.canEdit else { return }
        let sanitized = sanitizedDefaults()
        let json = sanitized.serialized()
        guard json.count <= 2000,
              sanitized != SettingsLocationSensorDefaults.parse(store.string("location_sensor_alert_defaults")) else { return }
        store.stage("location_sensor_alert_defaults", .string(json))
    }

    /// Clears notification flags on categories without a threshold, which the
    /// server would reject when they are seeded onto a sensor.
    private func sanitizedDefaults() -> SettingsLocationSensorDefaults {
        var result = defaults
        for category in SettingsLocationSensorCategory.allCases {
            var rule = result[category]
            let hasCondition = !rule.alertBelow.isEmpty || (category.allowsAlertAbove && !rule.alertAbove.isEmpty)
            if !hasCondition { rule.notifyOnAlert = false }
            if !category.allowsAlertAbove { rule.alertAbove = "" }
            result[category] = rule
        }
        return result
    }

    private func applyToExisting() async {
        let client = session.client
        let rules = sanitizedDefaults()
        let targets = sensors.filter { $0.category != nil }
        let names = Dictionary(((try? await client.get("location-ha-sensors/entities", as: [SettingsHADisplayEntity].self)) ?? [])
            .map { ($0.entityId, $0.friendlyName) }, uniquingKeysWith: { a, _ in a })
        let cards = showOnCard
        await runner.run("Updated \(targets.count) sensors") {
            for sensor in targets {
                guard let category = sensor.category else { continue }
                let rule = rules[category]
                var alert = SettingsSensorAlertDraft(kind: sensor.kind ?? "numeric", alertState: sensor.alertState ?? "",
                                                     alertAbove: rule.alertAbove, alertBelow: rule.alertBelow)
                if alert.kind == "binary" { alert.alertAbove = ""; alert.alertBelow = "" }
                var body: [String: JSONValue] = [
                    "notify_on_alert": .bool(rule.notifyOnAlert && alert.hasCondition),
                    "show_on_card": .bool(cards[category] ?? true),
                ]
                if alert.kind == "numeric" {
                    let fields = alert.fields(allowsAbove: category.allowsAlertAbove)
                    body["alert_above"] = fields["alert_above"]
                    body["alert_below"] = fields["alert_below"]
                }
                if let friendly = names[sensor.entityId] { body["name"] = .string(String(friendly.prefix(100))) }
                let _: SettingsLocationSensor = try await client.send(.patch, "location-ha-sensors/\(sensor.id)", body: JSONValue.object(body))
            }
        }
        await store.flush()
        await onChanged()
    }
}
