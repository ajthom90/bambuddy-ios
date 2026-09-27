import Foundation
import Observation

/// Live scale readings and NFC tag events pushed by SpoolBuddy stations over the
/// WebSocket. `spoolbuddy_weight` is a "quiet" event (it never bumps
/// `LiveUpdates.revision`), so this subscribes to the raw event stream instead.
@MainActor
@Observable
final class SpoolBuddyLiveState {
    struct Reading: Equatable {
        var grams: Double
        var stable: Bool
        var rawAdc: Int?
        var at: Date
    }

    struct UnknownTag: Equatable {
        var tagUid: String?
        var trayUuid: String?
        var tagType: String?
        var identifier: String { tagUid ?? trayUuid ?? "" }
    }

    enum WriteOutcome: Equatable {
        case written(spoolId: Int?, tagUid: String?)
        case failed(String)
    }

    struct ActivityEntry: Identifiable, Equatable {
        let id = UUID()
        var date: Date
        var deviceId: String
        var systemImage: String
        var text: String
        var isProblem: Bool
    }

    private(set) var readings: [String: Reading] = [:]
    private(set) var matched: [String: SpoolBuddyMatchedSpool] = [:]
    private(set) var unknown: [String: UnknownTag] = [:]
    private(set) var reportedOnline: [String: Bool] = [:]
    private(set) var writeOutcomes: [String: WriteOutcome] = [:]
    private(set) var activity: [ActivityEntry] = []
    /// Bumps when the device list should be reloaded (online/offline/update/unregistered).
    private(set) var deviceRevision = 0
    /// Bumps when a tag was linked or written, so spool lists can reload.
    private(set) var spoolRevision = 0

    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private weak var live: LiveUpdates?

    func start(_ live: LiveUpdates) {
        guard subscription == nil else { return }
        self.live = live
        subscription = live.subscribe { [weak self] event in self?.handle(event) }
    }

    func stop() {
        if let subscription { live?.unsubscribe(subscription) }
        subscription = nil
    }

    func clearWriteOutcome(_ deviceId: String) { writeOutcomes[deviceId] = nil }

    /// A tag currently on the reader, if any.
    func currentTagIdentifier(_ deviceId: String) -> String? {
        matched[deviceId]?.tagUid ?? unknown[deviceId]?.identifier
    }

    func isOnline(_ device: SpoolBuddyDevice) -> Bool {
        reportedOnline[device.deviceId] ?? device.isOnline
    }

    // MARK: Event handling

    func handle(_ event: LiveEvent) {
        guard event.type.hasPrefix("spoolbuddy_") || event.type == "spoolman_unavailable" else { return }
        let raw = event.raw
        func value(_ key: String) -> JSONValue? {
            if let v = raw[key], !v.isNull { return v }
            if let v = raw["data"]?[key], !v.isNull { return v }
            return nil
        }
        let deviceId = value("device_id")?.stringValue ?? ""

        switch event.type {
        case "spoolbuddy_weight":
            guard let grams = value("weight_grams")?.doubleValue else { return }
            readings[deviceId] = Reading(grams: grams, stable: value("stable")?.boolValue ?? false,
                                         rawAdc: value("raw_adc")?.intValue, at: Date())
            if reportedOnline[deviceId] != true { reportedOnline[deviceId] = true }

        case "spoolbuddy_tag_matched":
            guard let spool = value("spool"), let id = spool["id"]?.intValue else { return }
            let m = SpoolBuddyMatchedSpool(
                id: id,
                tagUid: value("tag_uid")?.stringValue ?? value("tray_uuid")?.stringValue ?? "",
                material: spool["material"]?.stringValue ?? "",
                subtype: spool["subtype"]?.stringValue,
                colorName: spool["color_name"]?.stringValue,
                rgba: spool["rgba"]?.stringValue,
                brand: spool["brand"]?.stringValue,
                labelWeight: spool["label_weight"]?.doubleValue ?? 0,
                coreWeight: spool["core_weight"]?.doubleValue ?? 0,
                weightUsed: spool["weight_used"]?.doubleValue ?? 0
            )
            matched[deviceId] = m
            unknown[deviceId] = nil
            log(deviceId, "tag", "Recognized \(m.title.isEmpty ? "spool #\(m.id)" : m.title)")

        case "spoolbuddy_unknown_tag":
            let tag = UnknownTag(tagUid: value("tag_uid")?.stringValue, trayUuid: value("tray_uuid")?.stringValue,
                                 tagType: value("tag_type")?.stringValue)
            unknown[deviceId] = tag
            matched[deviceId] = nil
            log(deviceId, "questionmark.circle", "Unknown tag \(tag.identifier)")

        case "spoolbuddy_tag_removed":
            if matched[deviceId] != nil || unknown[deviceId] != nil {
                log(deviceId, "tag.slash", "Tag removed")
            }
            matched[deviceId] = nil
            unknown[deviceId] = nil

        case "spoolbuddy_tag_written":
            writeOutcomes[deviceId] = .written(spoolId: value("spool_id")?.intValue, tagUid: value("tag_uid")?.stringValue)
            spoolRevision += 1
            log(deviceId, "checkmark.seal", "Tag written for spool #\(value("spool_id")?.intValue ?? 0)")

        case "spoolbuddy_tag_write_failed", "spoolbuddy_tag_link_failed":
            let message = value("message")?.stringValue ?? "Tag write failed"
            writeOutcomes[deviceId] = .failed(message)
            log(deviceId, "exclamationmark.triangle", message, problem: true)

        case "spoolbuddy_lookup_error", "spoolman_unavailable":
            log(deviceId, "exclamationmark.triangle", event.type == "spoolman_unavailable" ? "Spoolman is unavailable" : "Spool lookup failed", problem: true)

        case "spoolbuddy_online":
            reportedOnline[deviceId] = true
            deviceRevision += 1
            log(deviceId, "wifi", "Came online")

        case "spoolbuddy_offline":
            reportedOnline[deviceId] = false
            readings[deviceId] = nil
            deviceRevision += 1
            log(deviceId, "wifi.slash", "Went offline", problem: true)

        case "spoolbuddy_update":
            deviceRevision += 1
            if let status = value("update_status")?.stringValue {
                log(deviceId, "arrow.down.circle", "Update: \(value("update_message")?.stringValue ?? status)", problem: status == "error" || status == "failed")
            }

        case "spoolbuddy_unregistered":
            readings[deviceId] = nil
            matched[deviceId] = nil
            unknown[deviceId] = nil
            deviceRevision += 1

        default:
            break
        }
    }

    private func log(_ deviceId: String, _ image: String, _ text: String, problem: Bool = false) {
        activity.insert(ActivityEntry(date: Date(), deviceId: deviceId, systemImage: image, text: text, isProblem: problem), at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
    }
}
