import SwiftUI

struct SpoolBuddyRootView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @State private var liveState = SpoolBuddyLiveState()
    @State private var store = SpoolBuddyStore()
    @State private var path = NavigationPath()

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    devicesSection
                    toolsSection
                    activitySection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SpoolBuddy")
            .refreshable { await reload() }
            .navigationDestination(for: SpoolBuddyRoute.self) { route in
                switch route {
                case .device(let id): SpoolBuddyDeviceView(deviceId: id)
                case .settings(let id): SpoolBuddyDeviceSettingsView(deviceId: id)
                case .calibration(let id): SpoolBuddyCalibrationView(deviceId: id)
                case .writeTag(let spoolId): SpoolBuddyWriteTagView(initialSpoolId: spoolId)
                case .ams: SpoolBuddyAMSView()
                case .inventory: SpoolBuddyInventoryView()
                case .activity: SpoolBuddyActivityView()
                }
            }
            .task { liveState.start(live) }
            .task(id: liveState.deviceRevision) { await store.loadDevices(session) }
            .task(id: liveState.spoolRevision) { await store.loadSpools(session) }
            .task {
                // Online state is derived from heartbeats; refresh it periodically like the web UI.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    await store.loadDevices(session)
                }
            }
            #if DEBUG
            .onAppear {
                // `-openSpoolBuddy ams|inventory|write|activity` opens a tool screen (screenshots).
                guard path.isEmpty, let target = UserDefaults.standard.string(forKey: "openSpoolBuddy") else { return }
                let map: [String: SpoolBuddyRoute] = ["ams": .ams, "inventory": .inventory, "write": .writeTag(nil), "activity": .activity]
                if let r = map[target] { path.append(r) }
            }
            #endif
        }
        .environment(liveState)
        .environment(store)
    }

    private func reload() async {
        await store.loadDevices(session)
        await store.loadSpools(session)
    }

    // MARK: Sections

    @ViewBuilder
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stations").font(.title3.bold())
            LoadingContent(loader: store.devices, retry: { await store.loadDevices(session) }) { devices in
                if devices.isEmpty {
                    ContentUnavailableView {
                        Label("No SpoolBuddy Stations", systemImage: "sensor.tag.radiowaves.forward")
                    } description: {
                        Text("SpoolBuddy is a Raspberry Pi station with an NFC reader and scale. It appears here automatically once its daemon connects to this server.")
                    } actions: {
                        Link("Learn About SpoolBuddy", destination: URL(string: "https://wiki.bambuddy.cool")!)
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(devices) { device in
                            NavigationLink(value: SpoolBuddyRoute.device(device.deviceId)) {
                                SpoolBuddyDeviceCard(device: device)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(minHeight: store.devices.value == nil ? 120 : nil)
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                tool("AMS Slots", "tray.2", "Assign spools to printer slots", .ams)
                tool("Spools", "circle.circle", "Weights, tags and locations", .inventory)
                if session.can("inventory:update") {
                    tool("Write Tag", "wave.3.right.circle", "Encode an NFC tag for a spool", .writeTag(nil))
                }
                tool("Activity", "list.bullet.rectangle", "Recent scans and events", .activity)
            }
        }
    }

    private func tool(_ title: String, _ image: String, _ subtitle: String, _ route: SpoolBuddyRoute) -> some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: image).font(.title2).foregroundStyle(Color.accentColor)
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var activitySection: some View {
        if !liveState.activity.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent Activity").font(.title3.bold())
                    Spacer()
                    NavigationLink("See All", value: SpoolBuddyRoute.activity).font(.subheadline)
                }
                VStack(spacing: 0) {
                    ForEach(liveState.activity.prefix(5)) { entry in
                        SpoolBuddyActivityRow(entry: entry, deviceName: deviceName(entry.deviceId))
                            .padding(.horizontal).padding(.vertical, 8)
                        Divider().padding(.leading)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            }
        }
    }

    private func deviceName(_ id: String) -> String {
        store.devices.value?.first { $0.deviceId == id }?.displayName ?? id
    }
}

enum SpoolBuddyRoute: Hashable {
    case device(String)
    case settings(String)
    case calibration(String)
    case writeTag(Int?)
    case ams
    case inventory
    case activity
}

// MARK: - Device card

private struct SpoolBuddyDeviceCard: View {
    @Environment(SpoolBuddyLiveState.self) private var liveState
    let device: SpoolBuddyDevice

    var body: some View {
        let online = liveState.isOnline(device)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName).font(.headline)
                    Text(device.ipAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(text: online ? "Online" : "Offline", color: online ? .green : .secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                if device.hasScale {
                    SpoolBuddyWeightText(reading: online ? liveState.readings[device.deviceId] : nil, font: .system(size: 34, weight: .semibold, design: .rounded))
                } else {
                    Text("No scale").foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    hardware("wave.3.right", ok: device.hasNfc && device.nfcOk, present: device.hasNfc)
                    hardware("scalemass", ok: device.hasScale && device.scaleOk, present: device.hasScale)
                }
            }
            SpoolBuddyTagSummary(deviceId: device.deviceId)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .opacity(online ? 1 : 0.75)
    }

    private func hardware(_ image: String, ok: Bool, present: Bool) -> some View {
        Image(systemName: image)
            .foregroundStyle(!present ? Color.secondary.opacity(0.4) : ok ? .green : .orange)
            .accessibilityLabel(present ? (ok ? "Working" : "Problem") : "Not present")
    }
}

/// Live weight with a "stable" indicator.
struct SpoolBuddyWeightText: View {
    let reading: SpoolBuddyLiveState.Reading?
    var font: Font = .largeTitle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let reading {
                Text(reading.grams, format: .number.precision(.fractionLength(1)))
                    .font(font).monospacedDigit()
                    .contentTransition(.numericText(value: reading.grams))
                    .animation(.snappy, value: reading.grams)
                Text("g").font(.title3).foregroundStyle(.secondary)
                Image(systemName: reading.stable ? "checkmark.circle.fill" : "waveform.path")
                    .foregroundStyle(reading.stable ? .green : .orange)
                    .font(.caption)
                    .accessibilityLabel(reading.stable ? "Stable" : "Settling")
            } else {
                Text("-- g").font(font).foregroundStyle(.secondary)
            }
        }
    }
}

/// One-line summary of the tag currently on a device's reader.
struct SpoolBuddyTagSummary: View {
    @Environment(SpoolBuddyLiveState.self) private var liveState
    let deviceId: String

    var body: some View {
        if let m = liveState.matched[deviceId] {
            HStack(spacing: 8) {
                ColorSwatch(hex: m.hexColor, size: 20)
                Text(m.title.isEmpty ? "Spool #\(m.id)" : m.title).font(.subheadline).lineLimit(1)
                Spacer()
                Text(Fmt.grams(max(0, m.labelWeight - m.weightUsed)) + " left").font(.caption).foregroundStyle(.secondary)
            }
        } else if let u = liveState.unknown[deviceId] {
            Label("Unknown tag \(u.identifier)", systemImage: "questionmark.circle")
                .font(.subheadline).foregroundStyle(.orange).lineLimit(1)
        } else {
            Label("No tag on reader", systemImage: "sensor.tag.radiowaves.forward")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Activity

struct SpoolBuddyActivityRow: View {
    let entry: SpoolBuddyLiveState.ActivityEntry
    let deviceName: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.systemImage).foregroundStyle(entry.isProblem ? .orange : Color.accentColor).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.text).font(.subheadline)
                Text(deviceName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SpoolBuddyActivityView: View {
    @Environment(SpoolBuddyLiveState.self) private var liveState
    @Environment(SpoolBuddyStore.self) private var store

    var body: some View {
        List {
            if liveState.activity.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Tag scans, writes and station status changes appear here while the app is open."))
            }
            ForEach(liveState.activity) { entry in
                SpoolBuddyActivityRow(entry: entry, deviceName: store.devices.value?.first { $0.deviceId == entry.deviceId }?.displayName ?? entry.deviceId)
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }
}
