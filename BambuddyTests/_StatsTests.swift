import Testing
import Foundation
@testable import Bambuddy

struct StatsDecodeTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesEmptyStatsFromLiveServer() throws {
        let s = try decode(StatsSummary.self, #"""
        {"total_prints":0,"successful_prints":0,"failed_prints":0,"cancelled_prints":0,"total_print_time_hours":0.0,
         "total_filament_grams":0.0,"total_cost":0.0,"prints_by_filament_type":{},"prints_by_printer":{},"printer_names":{},
         "average_time_accuracy":null,"time_accuracy_by_printer":null,"total_energy_kwh":0.0,"total_energy_cost":0.0,
         "energy_data_warming_up":false}
        """#)
        #expect(s.totalPrints == 0)
        #expect(s.averageTimeAccuracy == nil)
        #expect(s.timeAccuracyByPrinter == nil)
        #expect(s.printsByPrinter?.isEmpty == true)
    }

    @Test func decodesPopulatedStatsKeepingDictionaryKeys() throws {
        let s = try decode(StatsSummary.self, #"""
        {"total_prints":12,"successful_prints":9,"failed_prints":2,"cancelled_prints":1,"total_print_time_hours":41.3,
         "total_filament_grams":1520.4,"total_cost":38.02,"prints_by_filament_type":{"PLA_Basic":7,"PETG":4},
         "prints_by_printer":{"1":8,"2":4,"None":0},"printer_names":{"1":"X1C_Lab","2":"P1S"},
         "average_time_accuracy":97.3,"time_accuracy_by_printer":{"1":101.5,"unknown":88.0},
         "total_energy_kwh":4.125,"total_energy_cost":0.619,"energy_data_warming_up":true}
        """#)
        #expect(s.printsByFilamentType?["PLA_Basic"] == 7)
        #expect(s.printerNames?["1"] == "X1C_Lab")
        #expect(s.timeAccuracyByPrinter?["unknown"] == 88)
        #expect(s.energyDataWarmingUp == true)
    }

    @Test func decodesStatsFromOlderServerWithoutOptionalFields() throws {
        let s = try decode(StatsSummary.self, #"""
        {"total_prints":3,"successful_prints":3,"failed_prints":0,"total_print_time_hours":2,"total_filament_grams":50,
         "total_cost":1,"prints_by_filament_type":{},"prints_by_printer":{"1":3}}
        """#)
        #expect(s.cancelledPrints == nil)
        #expect(s.totalEnergyKwh == nil)
    }

    @Test func decodesSlimRuns() throws {
        let runs = try decode([StatsPrintRun].self, #"""
        [{"printer_id":1,"print_name":"Benchy","print_time_seconds":3600,"actual_time_seconds":3720,
          "filament_used_grams":14.2,"filament_type":"PLA, PETG","filament_color":"#FF0000,00AE42FF","status":"completed",
          "started_at":"2026-09-20T10:00:00","completed_at":"2026-09-20T11:02:00","cost":0.36,"energy_kwh":0.12,
          "energy_cost":0.02,"quantity":1,"created_at":"2026-09-20T10:00:00.123456"},
         {"printer_id":null,"print_name":null,"print_time_seconds":null,"actual_time_seconds":null,
          "filament_used_grams":null,"filament_type":null,"filament_color":null,"status":"aborted",
          "started_at":null,"completed_at":null,"cost":null,"energy_kwh":null,"energy_cost":null,"quantity":1,
          "created_at":"2026-09-21T08:00:00Z"}]
        """#)
        #expect(runs.count == 2)
        #expect(runs[0].materials == ["PLA", "PETG"])
        #expect(runs[0].colors == ["#FF0000", "00AE42FF"])
        #expect(runs[0].effectiveSeconds == 3720)
        #expect(runs[0].createdDate != nil)
        #expect(runs[1].materials == ["Unknown"])
        #expect(runs[1].isFailed)
        #expect(runs[1].effectiveSeconds == 0)
    }

    @Test func decodesFailureAnalysis() throws {
        let a = try decode(StatsFailureAnalysis.self, #"""
        {"period_days":30,"total_prints":10,"failed_prints":2,"failure_rate":22.2,
         "failures_by_reason":{"spaghettiDetached":1,"Unknown":1},"failures_by_filament":{"PETG":2},
         "failures_by_printer":{"P1S":2},"failures_by_hour":{"0":0,"13":1,"23":1},
         "recent_failures":[{"id":null,"print_name":"Clip","failure_reason":null,"filament_type":null,"printer_id":2,"created_at":null},
                            {"id":7,"print_name":"Box","failure_reason":"layerShift","filament_type":"PETG","printer_id":null,"created_at":"2026-09-19T12:00:00+00:00"}],
         "trend":[{"week_start":"2026-08-29","total_prints":0,"failed_prints":0,"failure_rate":0},
                  {"week_start":"2026-09-05","total_prints":10,"failed_prints":2,"failure_rate":22.2}]}
        """#)
        #expect(a.failureRate == 22.2)
        #expect(a.failuresByHour?["13"] == 1)
        #expect(a.recentFailures?.first?.id == nil)
        #expect(a.trend?.count == 2)
    }

    @Test func decodesEmptyFailureAnalysisFromLiveServer() throws {
        let a = try decode(StatsFailureAnalysis.self, #"""
        {"period_days":30,"total_prints":0,"failed_prints":0,"failure_rate":0,"failures_by_reason":{},"failures_by_filament":{},
         "failures_by_printer":{},"failures_by_hour":{"0":0,"1":0},"recent_failures":[],
         "trend":[{"week_start":"2026-08-29","total_prints":0,"failed_prints":0,"failure_rate":0}]}
        """#)
        #expect(a.totalPrints == 0)
        #expect(a.recentFailures?.isEmpty == true)
    }

    @Test func decodesUsersAndRecalculateResult() throws {
        let users = try decode([StatsUserOption].self, #"[{"id":1,"username":"admin"},{"id":4,"username":"maker"}]"#)
        #expect(users.map(\.id) == [1, 4])
        let r = try decode(StatsRecalculateResult.self, #"{"message":"Recalculated costs for 5 archives","updated":5}"#)
        #expect(r.updated == 5)
    }
}

struct StatsAggregatorTests {
    private func run(_ status: String, grams: Double = 10, seconds: Int = 3600, type: String? = "PLA",
                     color: String? = nil, printer: Int? = 1, created: String = "2026-09-20T10:00:00") -> StatsPrintRun {
        StatsPrintRun(printerId: printer, printName: "p", printTimeSeconds: seconds, actualTimeSeconds: seconds,
                      filamentUsedGrams: grams, filamentType: type, filamentColor: color, status: status,
                      startedAt: created, completedAt: created, cost: grams / 10, energyKwh: nil, energyCost: nil,
                      quantity: 1, createdAt: created)
    }

    @Test func outcomesTreatCancelledAsNeutral() {
        let c = StatsAggregator.outcomes([run("completed"), run("completed"), run("failed"), run("aborted"), run("cancelled")])
        #expect(c.total == 5)
        #expect(c.failed == 2)
        #expect(c.cancelled == 1)
        #expect(c.successRate == 50)
    }

    @Test func summaryFromRunsForPrinterFilter() {
        let s = StatsAggregator.summary(from: [run("completed", grams: 20, type: "PLA, PETG"), run("failed", grams: 5)], printerId: 1)
        #expect(s.totalPrints == 2)
        #expect(s.totalFilamentGrams == 25)
        #expect(s.printsByFilamentType?["PLA"] == 2)
        #expect(s.printsByFilamentType?["PETG"] == 1)
        #expect(s.totalPrintTimeHours == 2)
    }

    @Test func materialWeightIsSplitAcrossMultiMaterialPrints() {
        let data = StatsAggregator.byMaterial([run("completed", grams: 30, type: "PLA, PETG"), run("completed", grams: 10, type: nil)], metric: .weight)
        #expect(data.first { $0.name == "PLA" }?.value == 15)
        #expect(data.first { $0.name == "Unknown" }?.value == 10)
    }

    @Test func colorsAndDurations() {
        let runs = [run("completed", grams: 20, seconds: 1200, color: "FF0000,00FF00"), run("completed", grams: 10, seconds: 90000, color: "FF0000")]
        let colors = StatsAggregator.colors(runs, metric: .weight)
        #expect(colors.first?.name == "FF0000")
        #expect(colors.first?.value == 20)
        let hist = StatsAggregator.durationHistogram(runs)
        #expect(hist.first?.value == 1)
        #expect(hist.last?.value == 1)
    }

    @Test func recordsAndStreak() {
        let runs = [
            run("completed", grams: 50, created: "2026-09-21T10:00:00"),
            run("completed", grams: 80, created: "2026-09-21T12:00:00"),
            run("failed", grams: 5, created: "2026-09-19T10:00:00"),
        ]
        let records = StatsAggregator.records(runs, currencyCode: "USD")
        #expect(records.contains { $0.kind == .heaviest })
        #expect(records.contains { $0.kind == .busiestDay && $0.value == "2 prints" })
        #expect(records.first { $0.kind == .streak }?.value == "2")
    }

    @Test func materialSuccessNeedsTwoDecidedRuns() {
        let data = StatsAggregator.materialSuccess([run("completed"), run("failed"), run("completed", type: "ABS")])
        #expect(data.count == 1)
        #expect(data.first?.rate == 50)
    }

    @Test func reasonLabels() {
        #expect(StatsAggregator.reasonLabel("spaghettiDetached") == "Spaghetti detached")
        #expect(StatsAggregator.reasonLabel("layer_shift") == "Layer shift")
        #expect(StatsAggregator.reasonLabel("Unknown") == "Unknown")
        #expect(StatsAggregator.reasonLabel("Nozzle clog on layer 3") == "Nozzle clog on layer 3")
    }

    @Test func timeframeRangesAndApiDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 15))!
        let last7 = StatsTimeframe.last7.range(now: now, calendar: cal)
        #expect(StatsTimeframe.apiDay(last7.from, calendar: cal) == "2026-09-20")
        #expect(StatsTimeframe.apiDay(last7.to, calendar: cal) == "2026-09-26")
        let week = StatsTimeframe.thisWeek.range(now: now, calendar: cal)
        #expect(StatsTimeframe.apiDay(week.from, calendar: cal) == "2026-09-21") // Monday
        #expect(StatsTimeframe.allTime.range(now: now, calendar: cal).from == nil)
        #expect(StatsTimeframe.apiDay(StatsTimeframe.thisYear.range(now: now, calendar: cal).from, calendar: cal) == "2026-01-01")
    }

    @Test func layoutParsingIsTolerant() {
        let l = StatsLayout(orderRaw: "records,bogus,quick-stats,records", hiddenRaw: "filament-trends,nope")
        #expect(l.order.first == .records)
        #expect(l.order.count == StatsWidgetKind.allCases.count)
        #expect(l.hidden == [.filamentTrends])
        #expect(!l.visible.contains(.filamentTrends))
        #expect(StatsLayout(orderRaw: "", hiddenRaw: "") == .standard)
    }
}
