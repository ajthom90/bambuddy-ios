import SwiftUI

/// Settings → Sensors: Home Assistant entities bound to printers (they can hold
/// the queue or notify) and to storage locations (temperature, humidity, battery).
struct SettingsSensorsView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store
    @Environment(LiveUpdates.self) private var live

    @State private var loader = Loader<SettingsSensorSnapshot>()
    @State private var printerReadings: [Int: SettingsHASensorReading] = [:]
    @State private var locationReadings: [Int: SettingsLocationSensorReading] = [:]
    @State private var runner = ActionRunner()
    @State private var printerEditor: SettingsSensorEditorTarget<SettingsHASensor>?
    @State private var locationEditor: SettingsSensorEditorTarget<SettingsLocationSensor>?
    @State private var printerSensorToDelete: SettingsHASensor?
    @State private var locationGroupToDelete: SettingsSensorLocationGroup?

    private var haConfigured: Bool {
        store.bool("ha_enabled") && !store.string("ha_url").isEmpty && !store.string("ha_token").isEmpty
    }
    private var canCreate: Bool { session.can("smart_plugs:create") }
    private var canEdit: Bool { session.can("smart_plugs:update") }
    private var canDelete: Bool { session.can("smart_plugs:delete") }
    private var printers: [Printer] { session.printers.printers }

    var body: some View {
        Group {
            if !store.hasLoaded, store.loadError == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LoadingContent(loader: loader, retry: load) { snapshot in
                    if !haConfigured && snapshot.isEmpty {
                        notConfiguredState
                    } else {
                        list(snapshot)
                    }
                }
            }
        }
        .navigationTitle("Sensors")
        .toolbar { toolbar }
        .task { if !store.hasLoaded { await store.load() } }
        .task(id: live.revision("inventory_changed")) { await load() }
        .task(id: pollKey) { await pollReadings() }
        .sheet(item: $printerEditor) { target in
            SettingsSensorPrinterEditor(sensor: target.sensor, existing: loader.value?.printerSensors ?? []) { await load() }
        }
        .sheet(item: $locationEditor) { target in
            SettingsLocationSensorEditor(
                sensor: target.sensor,
                locations: loader.value?.locations ?? [],
                existing: loader.value?.locationSensors ?? []
            ) { await load() }
        }
        .confirm("Delete \(printerSensorToDelete?.name ?? "Sensor")?", isPresented: Binding(get: { printerSensorToDelete != nil }, set: { if !$0 { printerSensorToDelete = nil } }),
                 message: "The sensor is unbound from its printer. Home Assistant is not changed.") {
            if let sensor = printerSensorToDelete { Task { await deletePrinterSensor(sensor) } }
        }
        .confirm("Delete All Sensors for \(locationGroupToDelete?.title ?? "Location")?", isPresented: Binding(get: { locationGroupToDelete != nil }, set: { if !$0 { locationGroupToDelete = nil } }),
                 message: "\(locationGroupToDelete?.sensors.count ?? 0) sensor bindings will be removed. Home Assistant is not changed.", action: "Delete All") {
            if let group = locationGroupToDelete { Task { await deleteLocationGroup(group) } }
        }
        .actionAlerts(runner)
    }

    // MARK: States

    private var notConfiguredState: some View {
        ContentUnavailableView {
            Label("Home Assistant Not Connected", systemImage: "house.badge.exclamationmark")
        } description: {
            Text("Sensors are read from Home Assistant. Turn on the Home Assistant integration and enter its URL and access token under Network & Integrations, then bind door, temperature or humidity sensors to printers and storage locations here.")
        } actions: {
            NavigationLink("Open Network & Integrations") { SettingsNetworkView() }
                .buttonStyle(.borderedProminent)
        }
        .refreshable { await load() }
    }

    private func list(_ snapshot: SettingsSensorSnapshot) -> some View {
        List {
            if !haConfigured {
                Section {
                    Label("Home Assistant isn't connected, so these sensors can't be read right now.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    NavigationLink("Open Network & Integrations") { SettingsNetworkView() }
                }
            }
            printerSection(snapshot)
            locationSections(snapshot)
            Section {
                NavigationLink {
                    SettingsLocationSensorOptionsView(sensors: snapshot.locationSensors) { await load() }
                } label: {
                    Label("Location Sensor Options", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("How often location sensors are read, and the alert thresholds new location sensors start with.")
            }
        }
        .refreshable {
            await load()
            await refreshReadings()
        }
    }

    // MARK: Printer sensors

    @ViewBuilder
    private func printerSection(_ snapshot: SettingsSensorSnapshot) -> some View {
        Section {
            if snapshot.printerSensors.isEmpty {
                Text("No printer sensors yet.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.printerSensors) { sensor in
                printerRow(sensor)
            }
            if canCreate {
                Button("Add Printer Sensor", systemImage: "plus") { printerEditor = .init(sensor: nil) }
                    .disabled(printers.isEmpty || !haConfigured)
            }
        } header: {
            Text("Printer Sensors")
        } footer: {
            Text("Bind a Home Assistant sensor — an enclosure door, a smoke detector, the room temperature — to a printer. A sensor in its alert state can notify you and hold that printer's queue.")
        }
    }

    private func printerRow(_ sensor: SettingsHASensor) -> some View {
        let reading = printerReadings[sensor.id]
        let printerName = session.printers.printer(sensor.printerId)?.name ?? "Unknown printer"
        return HStack(spacing: 12) {
            Image(systemName: SettingsSensorDisplay.systemImage(deviceClass: sensor.deviceClass, kind: sensor.kind, state: reading?.state ?? sensor.lastState))
                .foregroundStyle(reading?.alerting == true ? .red : .accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(sensor.name).lineLimit(1)
                Text(sensor.entityId).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    StatusBadge(text: printerName, color: .indigo)
                    if sensor.blockPrint == true { StatusBadge(text: "Holds Queue", color: .orange) }
                    if sensor.notifyOnAlert == true { StatusBadge(text: "Notifies", color: .blue) }
                    if sensor.showOnPrinterCard == false { StatusBadge(text: "Hidden", color: .secondary) }
                }
            }
            Spacer(minLength: 8)
            if let reading {
                Text(SettingsSensorDisplay.describe(kind: reading.kind ?? sensor.kind, deviceClass: reading.deviceClass ?? sensor.deviceClass,
                                                    unit: reading.unit ?? sensor.unit, state: reading.state, value: reading.value, reachable: reading.reachable))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(reading.alerting == true ? .red : (reading.reachable == true ? .primary : .secondary))
                    .multilineTextAlignment(.trailing)
            } else if let last = sensor.lastState {
                Text(SettingsSensorDisplay.stateLabel(last, deviceClass: sensor.deviceClass) + (sensor.kind == "numeric" ? sensor.unit.map { " \($0)" } ?? "" : ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .onTapGesture { if canEdit { printerEditor = .init(sensor: sensor) } }
        .swipeActions(edge: .trailing) {
            if canDelete {
                Button("Delete", systemImage: "trash", role: .destructive) { printerSensorToDelete = sensor }
            }
            if canEdit {
                Button("Edit", systemImage: "pencil") { printerEditor = .init(sensor: sensor) }.tint(.blue)
            }
        }
        .contextMenu {
            if canEdit {
                Button("Edit", systemImage: "pencil") { printerEditor = .init(sensor: sensor) }
                Toggle("Show on Printer Card", isOn: Binding(get: { sensor.showOnPrinterCard ?? true }, set: { value in
                    Task { await patchPrinterSensor(sensor, ["show_on_printer_card": .bool(value)]) }
                }))
            }
            if canDelete {
                Button("Delete", systemImage: "trash", role: .destructive) { printerSensorToDelete = sensor }
            }
        }
    }

    // MARK: Location sensors

    @ViewBuilder
    private func locationSections(_ snapshot: SettingsSensorSnapshot) -> some View {
        let groups = snapshot.locationGroups
        if groups.isEmpty {
            Section {
                Text("No storage location sensors yet.").foregroundStyle(.secondary)
                addLocationButton(snapshot)
            } header: {
                Text("Storage Location Sensors")
            } footer: {
                Text("Watch the temperature, humidity and battery of a dry box or shelf. Readings appear on the location in Inventory. Each location can have one sensor of each kind.")
            }
        } else {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                Section {
                    ForEach(group.sensors) { sensor in
                        locationRow(sensor)
                    }
                    if index == groups.count - 1 { addLocationButton(snapshot) }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        if index == 0 { Text("Storage Location Sensors").padding(.bottom, 6) }
                        HStack {
                            Label(group.title, systemImage: "shippingbox")
                            Spacer()
                            if canDelete {
                                Button("Delete All", role: .destructive) { locationGroupToDelete = group }
                                    .font(.caption)
                                    .textCase(nil)
                            }
                        }
                    }
                } footer: {
                    if index == groups.count - 1 {
                        Text("Readings appear on the location in Inventory. Each location can have one sensor of each kind.")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func addLocationButton(_ snapshot: SettingsSensorSnapshot) -> some View {
        if canCreate {
            Button("Add Location Sensor", systemImage: "plus") { locationEditor = .init(sensor: nil) }
                .disabled(!haConfigured)
        }
    }

    private func locationRow(_ sensor: SettingsLocationSensor) -> some View {
        let reading = locationReadings[sensor.id]
        let status = reading.flatMap(SettingsSensorDisplay.alertStatus)
        let valueColor: Color = switch status {
        case "above": .purple
        case "below": .red
        case "ok": .green
        default: .primary
        }
        return HStack(spacing: 12) {
            Image(systemName: sensor.category?.systemImage ?? SettingsSensorDisplay.systemImage(deviceClass: sensor.deviceClass, kind: sensor.kind, state: sensor.lastState))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(sensor.name).lineLimit(1)
                Text(sensor.entityId).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if sensor.notifyOnAlert == true || sensor.showOnCard == false {
                    HStack(spacing: 4) {
                        if sensor.notifyOnAlert == true { StatusBadge(text: "Notifies", color: .blue) }
                        if sensor.showOnCard == false { StatusBadge(text: "Hidden", color: .secondary) }
                    }
                }
            }
            Spacer(minLength: 8)
            if let reading {
                Text(SettingsSensorDisplay.describe(kind: reading.kind ?? sensor.kind, deviceClass: reading.deviceClass ?? sensor.deviceClass,
                                                    unit: reading.unit ?? sensor.unit, state: reading.state, value: reading.value,
                                                    reachable: reading.reachable, decimals: 2))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(reading.reachable == true ? valueColor : .secondary)
            }
        }
        .contentShape(.rect)
        .onTapGesture { if canEdit { locationEditor = .init(sensor: sensor) } }
        .swipeActions(edge: .trailing) {
            if canDelete {
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await deleteLocationSensor(sensor) } }
            }
            if canEdit {
                Button("Edit", systemImage: "pencil") { locationEditor = .init(sensor: sensor) }.tint(.blue)
            }
        }
        .contextMenu {
            if canEdit {
                Button("Edit", systemImage: "pencil") { locationEditor = .init(sensor: sensor) }
                Toggle("Show on Inventory Card", isOn: Binding(get: { sensor.showOnCard ?? true }, set: { value in
                    Task { await patchLocationSensor(sensor, ["show_on_card": .bool(value)]) }
                }))
            }
            if canDelete {
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await deleteLocationSensor(sensor) } }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if canCreate, haConfigured, loader.value != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Printer Sensor", systemImage: "printer") { printerEditor = .init(sensor: nil) }
                        .disabled(printers.isEmpty)
                    Button("Location Sensor", systemImage: "shippingbox") { locationEditor = .init(sensor: nil) }
                } label: {
                    Label("Add Sensor", systemImage: "plus")
                }
            }
        }
    }

    // MARK: Data

    private var pollKey: String {
        let snapshot = loader.value
        let printerIDs = Set(snapshot?.printerSensors.map(\.printerId) ?? []).sorted()
        let locationIDs = Set(snapshot?.locationSensors.map(\.locationId) ?? []).sorted()
        return "\(printerIDs)|\(locationIDs)|\(store.int("location_sensor_poll_interval") ?? 120)"
    }

    private func load() async {
        let client = session.client
        await loader.load {
            async let printerSensors: [SettingsHASensor] = client.get("ha-sensors/")
            async let locationSensors: [SettingsLocationSensor] = client.get("location-ha-sensors/")
            // Locations need inventory access; without it sensors still show, under a generic title.
            async let locations: [SettingsLocationSensorPlace]? = try? client.get("inventory/locations")
            return SettingsSensorSnapshot(printerSensors: try await printerSensors,
                                          locationSensors: try await locationSensors,
                                          locations: await locations ?? [])
        }
    }

    private func pollReadings() async {
        let interval = max(store.int("location_sensor_poll_interval") ?? 120, 60)
        while !Task.isCancelled {
            await refreshReadings()
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func refreshReadings() async {
        guard let snapshot = loader.value else { return }
        let client = session.client
        let printerIDs = Array(Set(snapshot.printerSensors.map(\.printerId)))
        let locationIDs = Array(Set(snapshot.locationSensors.map(\.locationId)))
        let printerResults = await withTaskGroup(of: [SettingsHASensorReading].self) { group in
            for id in printerIDs {
                group.addTask { (try? await client.get("ha-sensors/by-printer/\(id)/readings", as: [SettingsHASensorReading].self)) ?? [] }
            }
            var all: [SettingsHASensorReading] = []
            for await readings in group { all += readings }
            return all
        }
        let locationResults = await withTaskGroup(of: [SettingsLocationSensorReading].self) { group in
            for id in locationIDs {
                group.addTask {
                    (try? await client.get("location-ha-sensors/by-location/\(id)/readings", query: ["show_on_card": false],
                                           as: [SettingsLocationSensorReading].self)) ?? []
                }
            }
            var all: [SettingsLocationSensorReading] = []
            for await readings in group { all += readings }
            return all
        }
        guard !Task.isCancelled else { return }
        printerReadings = Dictionary(printerResults.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        locationReadings = Dictionary(locationResults.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func patchPrinterSensor(_ sensor: SettingsHASensor, _ changes: [String: JSONValue]) async {
        let client = session.client
        await runner.run {
            let _: SettingsHASensor = try await client.send(.patch, "ha-sensors/\(sensor.id)", body: JSONValue.object(changes))
        }
        await load()
    }

    private func patchLocationSensor(_ sensor: SettingsLocationSensor, _ changes: [String: JSONValue]) async {
        let client = session.client
        await runner.run {
            let _: SettingsLocationSensor = try await client.send(.patch, "location-ha-sensors/\(sensor.id)", body: JSONValue.object(changes))
        }
        await load()
    }

    private func deletePrinterSensor(_ sensor: SettingsHASensor) async {
        let client = session.client
        await runner.run("Sensor removed") {
            try await client.call(.delete, "ha-sensors/\(sensor.id)")
        }
        await load()
    }

    private func deleteLocationSensor(_ sensor: SettingsLocationSensor) async {
        let client = session.client
        await runner.run("Sensor removed") {
            try await client.call(.delete, "location-ha-sensors/\(sensor.id)")
        }
        await load()
    }

    private func deleteLocationGroup(_ group: SettingsSensorLocationGroup) async {
        let client = session.client
        await runner.run("Sensors removed") {
            for sensor in group.sensors {
                try await client.call(.delete, "location-ha-sensors/\(sensor.id)")
            }
        }
        // Reload whatever happened: a failure part-way has still removed some.
        await load()
    }
}

// MARK: - Supporting types

/// Opens a sensor editor for a new (`sensor == nil`) or existing sensor.
struct SettingsSensorEditorTarget<Sensor: Identifiable & Hashable>: Identifiable {
    var sensor: Sensor?
    var id: String { sensor.map { "edit-\($0.id)" } ?? "new" }
}

/// Everything the sensors page shows, loaded together.
struct SettingsSensorSnapshot: Sendable {
    var printerSensors: [SettingsHASensor]
    var locationSensors: [SettingsLocationSensor]
    var locations: [SettingsLocationSensorPlace]

    var isEmpty: Bool { printerSensors.isEmpty && locationSensors.isEmpty }

    /// Location sensors grouped by location, in the server's (natural) location
    /// order, each group sorted temperature → humidity → battery.
    var locationGroups: [SettingsSensorLocationGroup] {
        let order = Dictionary(locations.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let grouped = Dictionary(grouping: locationSensors, by: \.locationId)
        return grouped.map { id, sensors in
            SettingsSensorLocationGroup(
                id: id,
                title: locations.first { $0.id == id }?.name ?? "Unknown location",
                sensors: sensors.sorted { ($0.category?.order ?? 99, $0.id) < ($1.category?.order ?? 99, $1.id) }
            )
        }
        .sorted { (order[$0.id] ?? Int.max, $0.id) < (order[$1.id] ?? Int.max, $1.id) }
    }
}

struct SettingsSensorLocationGroup: Identifiable, Sendable {
    var id: Int
    var title: String
    var sensors: [SettingsLocationSensor]
}
