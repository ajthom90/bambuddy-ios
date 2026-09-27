import SwiftUI

/// `MaintenanceTypeResponse` — a kind of maintenance task (built-in or custom).
struct MaintenanceTypeInfo: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var description: String?
    var defaultIntervalHours: Double?
    var intervalType: String?
    var icon: String?
    var wikiUrl: String?
    var isSystem: Bool
    var createdAt: String?

    var interval: Double { defaultIntervalHours ?? 100 }
    var kind: String { intervalType ?? "hours" }
}

/// `PrinterMaintenanceOverview` — one printer's maintenance items with counts.
struct MaintenancePrinterOverview: Codable, Sendable, Identifiable, Hashable {
    var printerId: Int
    var printerName: String
    var printerModel: String?
    var totalPrintHours: Double
    var maintenanceItems: [MaintenanceItemStatus]
    var dueCount: Int
    var warningCount: Int

    var id: Int { printerId }

    /// Overdue first, then due soon, then by type.
    var sortedItems: [MaintenanceItemStatus] {
        maintenanceItems.sorted { a, b in
            if a.urgencyRank != b.urgencyRank { return a.urgencyRank < b.urgencyRank }
            return a.maintenanceTypeId < b.maintenanceTypeId
        }
    }

    var nextTask: MaintenanceItemStatus? {
        sortedItems.first { $0.enabled && ($0.isDue || $0.isWarning) }
    }
}

/// `MaintenanceStatus` — computed status of a maintenance item on a printer.
struct MaintenanceItemStatus: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var printerId: Int
    var printerName: String
    var printerModel: String?
    var maintenanceTypeId: Int
    var maintenanceTypeName: String
    var maintenanceTypeIcon: String?
    var maintenanceTypeWikiUrl: String?
    var enabled: Bool
    var intervalHours: Double
    var intervalType: String
    var currentHours: Double
    var hoursSinceMaintenance: Double
    var hoursUntilDue: Double
    var daysSinceMaintenance: Double?
    var daysUntilDue: Double?
    var isDue: Bool
    var isWarning: Bool
    var lastPerformedAt: String?

    var isDaysBased: Bool { intervalType == "days" }

    fileprivate var urgencyRank: Int {
        if !enabled { return 3 }
        if isDue { return 0 }
        if isWarning { return 1 }
        return 2
    }

    /// How far through the interval this item is (0…1).
    var progress: Double {
        guard intervalHours > 0 else { return 0 }
        let used = isDaysBased ? (daysSinceMaintenance ?? 0) : (intervalHours - hoursUntilDue)
        return max(0, min(1, used / intervalHours))
    }

    var statusColor: Color {
        if !enabled { return .secondary }
        if isDue { return .red }
        if isWarning { return .orange }
        return .green
    }

    var statusText: String {
        guard enabled else { return "Disabled" }
        let remaining = isDaysBased ? (daysUntilDue ?? 0) : hoursUntilDue
        let amount = MaintenanceFormat.amount(abs(remaining), daysBased: isDaysBased)
        if isDue { return "Overdue by \(amount)" }
        if isWarning { return "Due in \(amount)" }
        return "\(amount) left"
    }

    var statusSymbol: String {
        if !enabled { return "pause.circle" }
        if isDue { return "exclamationmark.triangle.fill" }
        if isWarning { return "clock.fill" }
        return "checkmark.circle.fill"
    }
}

/// `PrinterMaintenanceResponse` — returned by PATCH/assign on an item.
struct MaintenanceItemRecord: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var printerId: Int
    var maintenanceTypeId: Int
    var maintenanceType: MaintenanceTypeInfo?
    var customIntervalHours: Double?
    var enabled: Bool
    var lastPerformedAt: String?
    var lastPerformedHours: Double?
    var createdAt: String?
    var updatedAt: String?
}

/// `MaintenanceHistoryResponse` — one "performed" log entry.
struct MaintenanceHistoryEntry: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var printerMaintenanceId: Int
    var performedAt: String
    var hoursAtMaintenance: Double
    var notes: String?
}

struct MaintenanceRestoreResult: Codable, Sendable {
    var restored: Int?
}

// MARK: - Formatting & icons

enum MaintenanceFormat {
    /// "3 days", "2 weeks", "12.5 h" …
    static func amount(_ value: Double, daysBased: Bool) -> String {
        if daysBased {
            if value < 1 { return "less than a day" }
            let days = Int(value.rounded())
            if days < 14 { return days == 1 ? "1 day" : "\(days) days" }
            if days < 120 { let w = Int((value / 7).rounded()); return "\(w) weeks" }
            let m = Int((value / 30).rounded())
            return m == 1 ? "1 month" : "\(m) months"
        }
        if value < 1 { return "\(Int((value * 60).rounded())) min" }
        if value < 10 { return String(format: "%.1f h", value) }
        return "\(Int(value.rounded())) h"
    }

    /// "Every 100 print hours", "Every 30 days" …
    static func interval(_ value: Double, type: String) -> String {
        let n = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        if type == "days" {
            switch value {
            case 1: return "Daily"
            case 7: return "Weekly"
            case 30: return "Monthly"
            case 365: return "Yearly"
            default: return "Every \(n) days"
            }
        }
        return "Every \(n) print hours"
    }

    static func shortInterval(_ value: Double, type: String) -> String {
        let n = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return type == "days" ? "\(n)d" : "\(n)h"
    }
}

/// The server stores icon names from the web UI's icon set; these map them to SF Symbols.
enum MaintenanceIcons {
    static let all: [(name: String, symbol: String)] = [
        ("Wrench", "wrench.adjustable"),
        ("Droplet", "drop"),
        ("Flame", "flame"),
        ("Ruler", "ruler"),
        ("Sparkles", "sparkles"),
        ("Square", "square"),
        ("Cable", "cable.connector"),
        ("Calendar", "calendar"),
        ("Timer", "timer"),
        ("Cog", "gearshape"),
        ("Fan", "fan"),
        ("Zap", "bolt"),
        ("Wind", "wind"),
        ("Thermometer", "thermometer.medium"),
        ("Layers", "square.3.layers.3d"),
        ("Box", "shippingbox"),
        ("Target", "target"),
        ("RefreshCw", "arrow.clockwise"),
        ("Settings", "gearshape.2"),
        ("Filter", "line.3.horizontal.decrease"),
        ("CircleDot", "circle.circle"),
    ]

    static func symbol(for name: String?) -> String {
        guard let name else { return "wrench.adjustable" }
        return all.first { $0.name == name }?.symbol ?? "wrench.adjustable"
    }
}
