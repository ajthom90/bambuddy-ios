import SwiftUI

/// Navigation destinations inside the Queue section.
enum QueueRoute: Hashable {
    case item(QueueItem)
    case batchGroup(Int)
    case batchOrder(QueueBatch)
    case pipelineRun(Int)
}

/// A row in the pending list: a standalone item or a batch of sibling items.
enum QueueRow: Identifiable, Hashable {
    case item(QueueItem)
    case batch(id: Int, name: String, items: [QueueItem])

    var id: String {
        switch self {
        case .item(let i): "i-\(i.id)"
        case .batch(let id, _, _): "b-\(id)"
        }
    }

    var items: [QueueItem] {
        switch self {
        case .item(let i): [i]
        case .batch(_, _, let items): items
        }
    }

    /// Groups items sharing a `batch_id` into one row at the position of the first sibling.
    static func group(_ items: [QueueItem]) -> [QueueRow] {
        var rows: [QueueRow] = []
        var seen = Set<Int>()
        for item in items {
            if let batch = item.batchId {
                guard !seen.contains(batch) else { continue }
                seen.insert(batch)
                let siblings = items.filter { $0.batchId == batch }
                rows.append(.batch(id: batch, name: item.batchName ?? "Batch", items: siblings))
            } else {
                rows.append(.item(item))
            }
        }
        return rows
    }
}

/// Deficit line returned by `POST queue/{id}/start` when spools are too low (HTTP 409).
struct QueueFilamentDeficit: Hashable, Sendable {
    var slotId: Int?
    var filamentType: String?
    var requiredGrams: Double?
    var remainingGrams: Double?
}

/// Shared state and actions for the Queue section.
@MainActor
@Observable
final class QueueViewModel {
    var items: [QueueItem]?
    var error: String?
    var shortestFirst = false
    var uploadProgress: [Int: Int] = [:]
    var printerFilter: Int?
    var statusFilter = ""
    var locationFilter = ""
    /// Set when a manual start was refused for low filament; the UI offers "Print Anyway".
    var filamentShort: (itemId: Int, deficit: [QueueFilamentDeficit])?
    let runner = ActionRunner()

    @ObservationIgnored private var subscription: UUID?

    func load(_ client: APIClient) async {
        do {
            let list: [QueueItem] = try await client.get("queue/", query: [
                "printer_id": .of(printerFilter),
                "status": statusFilter.isEmpty ? nil : .string(statusFilter),
            ])
            items = list
            error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadSettings(_ client: APIClient) async {
        if let s: JSONValue = try? await client.get("settings/") {
            shortestFirst = s["queue_shortest_first"]?.boolValue ?? false
        }
    }

    /// Tracks FTP upload progress pushed while the scheduler sends a job to a printer.
    func attach(_ live: LiveUpdates) {
        guard subscription == nil else { return }
        subscription = live.subscribe { [weak self] event in
            guard let self, let id = event.raw["queue_item_id"]?.intValue else { return }
            switch event.type {
            case "queue_item_uploading": self.uploadProgress[id] = 0
            case "queue_item_upload_progress": self.uploadProgress[id] = event.raw["pct"]?.intValue ?? 0
            case "queue_item_acked", "queue_item_failed": self.uploadProgress[id] = nil
            default: break
            }
        }
    }

    func detach(_ live: LiveUpdates) {
        if let subscription { live.unsubscribe(subscription) }
        subscription = nil
    }

    // MARK: Derived lists

    func matchesLocation(_ item: QueueItem, printers: PrinterStore) -> Bool {
        guard !locationFilter.isEmpty else { return true }
        if let loc = item.targetLocation, !loc.isEmpty { return loc == locationFilter }
        if let pid = item.printerId { return printers.printer(pid)?.location == locationFilter }
        return false
    }

    func visible(_ printers: PrinterStore) -> [QueueItem] {
        (items ?? []).filter { matchesLocation($0, printers: printers) }
    }

    func locations(_ printers: PrinterStore) -> [String] {
        var set = Set(printers.printers.compactMap(\.location).filter { !$0.isEmpty })
        for item in items ?? [] { if let l = item.targetLocation, !l.isEmpty { set.insert(l) } }
        return set.sorted()
    }

    /// Pending items in the order the scheduler would take them when shortest-job-first is on.
    static func shortestFirstOrder(_ items: [QueueItem]) -> [QueueItem] {
        items.sorted { a, b in
            let ak = a.printerId ?? -Int(a.targetModel?.unicodeScalars.first?.value ?? 0)
            let bk = b.printerId ?? -Int(b.targetModel?.unicodeScalars.first?.value ?? 0)
            if ak != bk { return ak < bk }
            if (a.beenJumped ?? false) != (b.beenJumped ?? false) { return a.beenJumped ?? false }
            let at = a.printTimeSeconds ?? .max, bt = b.printTimeSeconds ?? .max
            if at != bt { return at < bt }
            return (a.position ?? 0) < (b.position ?? 0)
        }
    }

    /// Items that could start right now, for which an "if started now" ETA is meaningful.
    func etaEligible() -> Set<Int> {
        let all = items ?? []
        let busy = Set(all.filter(\.isPrinting).compactMap(\.printerId))
        let now = Date()
        func future(_ i: QueueItem) -> Bool { (i.scheduledDate.map { $0 > now } ?? false) }
        var firstPerPrinter: [Int: Int] = [:]
        let contenders = all.filter { $0.isPending && $0.printerId != nil && !$0.isStaged && !future($0) }
        let ordered = shortestFirst ? Self.shortestFirstOrder(contenders) : contenders.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        for item in ordered where firstPerPrinter[item.printerId!] == nil { firstPerPrinter[item.printerId!] = item.id }
        var result = Set<Int>()
        for item in all where item.isPending {
            if item.waitingReason != nil || future(item) || item.requirePreviousSuccess == true { continue }
            guard let t = item.printTimeSeconds, t > 0 else { continue }
            guard let pid = item.printerId else { result.insert(item.id); continue }
            if busy.contains(pid) { continue }
            if item.isStaged || firstPerPrinter[pid] == item.id { result.insert(item.id) }
        }
        return result
    }

    /// Printers whose queue is blocked by a failed print gating `require_previous_success` items.
    func gateBlockedPrinters() -> [(printerId: Int, name: String, count: Int)] {
        var counts: [Int: (String, Int)] = [:]
        for item in items ?? [] where item.state == "skipped" && item.errorMessage == QueueItem.previousFailedReason {
            guard let pid = item.printerId else { continue }
            counts[pid, default: (item.printerName ?? "Printer #\(pid)", 0)].1 += 1
        }
        return counts.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.name < $1.name }
    }

    // MARK: Actions

    func start(_ item: QueueItem, skipFilamentCheck: Bool = false, client: APIClient) async {
        do {
            let _: JSONValue = try await client.send(.post, "queue/\(item.id)/start", query: ["skip_filament_check": skipFilamentCheck ? .bool(true) : nil])
            filamentShort = nil
            runner.successMessage = "Print released"
            await load(client)
        } catch let e as APIError where e.status == 409 && e.code == "insufficient_filament" {
            let lines = e.detail?["deficit"]?.arrayValue ?? []
            filamentShort = (item.id, lines.map {
                QueueFilamentDeficit(
                    slotId: $0["slot_id"]?.intValue, filamentType: $0["filament_type"]?.stringValue,
                    requiredGrams: $0["required_grams"]?.doubleValue, remainingGrams: $0["remaining_grams"]?.doubleValue
                )
            })
        } catch {
            runner.errorMessage = error.localizedDescription
        }
    }

    func cancel(_ ids: [Int], client: APIClient) async {
        await runner.run(ids.count > 1 ? "\(ids.count) items cancelled" : "Queue item cancelled") {
            for id in ids { try await client.call(.post, "queue/\(id)/cancel") }
        }
        await load(client)
    }

    func stop(_ item: QueueItem, client: APIClient) async {
        await runner.run("Stop sent") { try await client.call(.post, "queue/\(item.id)/stop") }
        await load(client)
    }

    func remove(_ ids: [Int], client: APIClient) async {
        var removed = 0, kept = 0
        await runner.run {
            for id in ids {
                let r: QueueDeleteResult = try await client.send(.delete, "queue/\(id)")
                if r.deleted == false { kept += 1 } else { removed += 1 }
            }
        }
        if removed + kept > 0 {
            runner.successMessage = kept > 0
                ? "\(removed) removed, \(kept) kept (still needed by a batch order)"
                : (removed == 1 ? "Removed from queue" : "\(removed) items removed")
        }
        await load(client)
    }

    func reorder(_ orderedIds: [Int], client: APIClient) async {
        // Optimistic: apply the positions locally first so the list does not jump back.
        if var list = items {
            for (i, id) in orderedIds.enumerated() {
                if let idx = list.firstIndex(where: { $0.id == id }) { list[idx].position = i + 1 }
            }
            items = list
        }
        let body: JSONValue = ["items": .array(orderedIds.enumerated().map { ["id": .number(Double($1)), "position": .number(Double($0 + 1))] })]
        await runner.run { try await client.call(.post, "queue/reorder", body: body) }
        await load(client)
    }

    /// Moves the given item ids to sit before/after an anchor in the global pending order.
    func move(_ moving: [Int], anchor: Int, after: Bool, client: APIClient) async {
        let pending = (items ?? []).filter(\.isPending).sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        var remaining = pending.map(\.id).filter { !moving.contains($0) }
        guard var index = remaining.firstIndex(of: anchor) else { return }
        if after { index += 1 }
        let ordered = pending.map(\.id).filter { moving.contains($0) }
        remaining.insert(contentsOf: ordered, at: index)
        await reorder(remaining, client: client)
    }

    func resume(printerId: Int, client: APIClient) async {
        await runner.run {
            let r: QueueResumeResult = try await client.send(.post, "queue/printer/\(printerId)/resume")
            runner.successMessage = "Restored \(r.restored ?? 0), acknowledged \(r.acknowledged ?? 0)"
        }
        await load(client)
    }

    func setShortestFirst(_ on: Bool, client: APIClient) async {
        shortestFirst = on
        await runner.run { try await client.call(.patch, "settings/", body: ["queue_shortest_first": JSONValue.bool(on)]) }
    }

    func createBatch(name: String, ids: [Int], client: APIClient) async {
        await runner.run("Grouped as \(name)") {
            let body: JSONValue = ["name": .string(name), "item_ids": .array(ids.map { .number(Double($0)) })]
            let _: QueueBatch = try await client.send(.post, "queue/batches", body: body)
        }
        await load(client)
    }

    func ungroup(batchId: Int, client: APIClient) async {
        await runner.run {
            let r: QueueUngroupResult = try await client.send(.post, "queue/batches/\(batchId)/ungroup")
            runner.successMessage = "\(r.ungroupedCount ?? 0) items ungrouped"
        }
        await load(client)
    }
}

/// Permission helpers mirroring the server's own/all split.
@MainActor
enum QueuePermissions {
    static func canUpdate(_ item: QueueItem, _ session: AppSession) -> Bool {
        guard session.isAuthEnabled else { return true }
        if session.can("queue:update_all") { return true }
        return session.can("queue:update_own") && item.createdById != nil && item.createdById == session.user?.id
    }

    static func canDelete(_ item: QueueItem, _ session: AppSession) -> Bool {
        guard session.isAuthEnabled else { return true }
        if session.can("queue:delete_all") { return true }
        return session.can("queue:delete_own") && item.createdById != nil && item.createdById == session.user?.id
    }
}
