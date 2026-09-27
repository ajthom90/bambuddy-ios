#if DEBUG
import Foundation

/// Deterministic demo data for screenshots / previews. Enabled with the
/// `-statsSampleData` launch argument (the live server has no print history).
enum StatsSampleData {
    static let runs: [StatsPrintRun] = {
        var out: [StatsPrintRun] = []
        let materials = ["PLA", "PLA", "PETG", "PLA, PETG", "ABS", "TPU", "PLA-CF"]
        let colors = ["00AE42", "FFFFFF", "000000", "FF6A13,FFFFFF", "0A2CA5", "C12E1F", "F4EE2A"]
        let statuses = ["completed", "completed", "completed", "completed", "failed", "completed", "cancelled", "completed"]
        let now = Date.now
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for i in 0..<140 {
            let start = now.addingTimeInterval(-Double(next(170)) * 86400 - Double(next(24)) * 3600)
            let seconds = 900 + next(40000)
            let grams = Double(5 + next(420))
            let status = statuses[next(statuses.count)]
            let m = next(materials.count)
            let iso = start.ISO8601Format()
            out.append(StatsPrintRun(
                printerId: 1 + next(3), printName: "Sample part \(i + 1)",
                printTimeSeconds: Int(Double(seconds) * (0.85 + Double(next(30)) / 100)),
                actualTimeSeconds: seconds, filamentUsedGrams: grams,
                filamentType: materials[m], filamentColor: colors[m], status: status,
                startedAt: iso, completedAt: start.addingTimeInterval(Double(seconds)).ISO8601Format(),
                cost: grams * 0.025, energyKwh: Double(seconds) / 3600 * 0.12, energyCost: Double(seconds) / 3600 * 0.12 * 0.3,
                quantity: 1, createdAt: iso))
        }
        return out
    }()

    static var summary: StatsSummary {
        var s = StatsAggregator.summary(from: runs, printerId: nil)
        var byPrinter: [String: Double] = [:]
        for r in runs { byPrinter[String(r.printerId ?? 0), default: 0] += 1 }
        s.printsByPrinter = byPrinter
        s.printerNames = ["1": "X1 Carbon", "2": "P1S", "3": "A1 mini"]
        s.averageTimeAccuracy = 97.4
        s.timeAccuracyByPrinter = ["1": 101.2, "2": 94.1, "3": 108.9]
        return s
    }

    static let failures = StatsFailureAnalysis(
        periodDays: 30, totalPrints: 48, failedPrints: 5, failureRate: 11.4,
        failuresByReason: ["spaghettiDetached": 2, "adhesionFailure": 2, "Unknown": 1],
        failuresByFilament: ["PETG": 3, "PLA": 2], failuresByPrinter: ["P1S": 4, "X1 Carbon": 1],
        failuresByHour: ["3": 1, "14": 2, "22": 2],
        recentFailures: [StatsRecentFailure(id: 12, printName: "Bracket v2", failureReason: "spaghettiDetached", filamentType: "PETG", printerId: 2, createdAt: Date.now.ISO8601Format())],
        trend: [
            StatsFailureTrendPoint(weekStart: "2026-08-29", totalPrints: 11, failedPrints: 2, failureRate: 20),
            StatsFailureTrendPoint(weekStart: "2026-09-05", totalPrints: 14, failedPrints: 1, failureRate: 7.7),
            StatsFailureTrendPoint(weekStart: "2026-09-12", totalPrints: 12, failedPrints: 1, failureRate: 9.1),
            StatsFailureTrendPoint(weekStart: "2026-09-19", totalPrints: 11, failedPrints: 1, failureRate: 10),
        ]
    )
}
#endif
