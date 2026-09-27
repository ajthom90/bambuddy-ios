import Testing
import Foundation
@testable import Bambuddy

struct SystemTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesSystemInfo() throws {
        let info = try decode(SystemInfo.self, #"""
        {"app":{"version":"1.2.5","base_dir":"/app","archive_dir":"/app/archive"},
         "database":{"engine":"sqlite","version":null,"archives":120,"archives_completed":100,"archives_failed":15,
           "archives_printing":1,"printers":2,"filaments":30,"projects":4,"smart_plugs":0,
           "total_print_time_seconds":360000,"total_print_time_formatted":"100h","total_filament_grams":12000.5,"total_filament_kg":12.0},
         "printers":{"total":2,"connected":1,"connected_list":[{"id":1,"name":"X1C","state":"IDLE","model":"X1C"}]},
         "storage":{"archive_size_bytes":1048576,"archive_size_formatted":"1 MB","database_size_bytes":2048,
           "disk_total_bytes":1e11,"disk_used_bytes":5e10,"disk_free_bytes":5e10,"disk_percent_used":50.0},
         "system":{"platform":"Linux","platform_release":"6.1","architecture":"x86_64","hostname":"nas",
           "python_version":"3.12","uptime_seconds":86400,"uptime_formatted":"1d","boot_time":"2026-09-25T00:00:00"},
         "memory":{"total_bytes":8e9,"available_bytes":4e9,"used_bytes":4e9,"percent_used":50},
         "cpu":{"count":4,"count_logical":8,"percent":12.5}}
        """#)
        #expect(info.database?.archivesFailed == 15)
        #expect(info.printers?.connectedList?.first?.name == "X1C")
        #expect(info.cpu?.countLogical == 8)
        #expect(try decode(SystemInfo.self, "{}").app == nil)
    }

    @Test func decodesStorageHealthAndLogs() throws {
        let usage = try decode(SystemStorageUsage.self, #"""
        {"roots":["/data"],"total_bytes":1000,"total_formatted":"1 KB",
         "categories":[{"key":"archives","label":"Archives","bucket":null,"kind":"dir","deletable":false,"bytes":800,"formatted":"800 B","percent_of_total":80}],
         "other_breakdown":[],"scan_errors":0,"generated_at":"2026-09-26T12:00:00"}
        """#)
        #expect(usage.categories?.first?.percentOfTotal == 80)

        let health = try decode(SystemHealthScan.self, #"""
        {"findings":[{"signature_id":"mqtt_auth_failed","severity":"error","category":"printer","wiki_anchor":"mqtt",
          "count":3,"first_seen":null,"last_seen":"2026-09-26T12:00:00","sample":"auth failed"}],
         "scanned_entries":5000,"log_available":true,"summary":{"error":1}}
        """#)
        #expect(health.findings.first?.title == "Mqtt Auth Failed")
        #expect(health.findings.first?.wikiURL != nil)

        let logs = try decode(SystemLogsResponse.self, #"""
        {"entries":[{"timestamp":"2026-09-26 14:47:28,578","level":"INFO","logger_name":"app.main","message":"Started"}],
         "total_in_file":10,"filtered_count":1}
        """#)
        #expect(logs.entries.first?.loggerName == "app.main")
        let debug = try decode(SystemDebugLogging.self, #"{"enabled":true,"enabled_at":null,"duration_seconds":120}"#)
        #expect(debug.durationSeconds == 120)
    }

    @Test func decodesUpdatesAndDiagnostics() throws {
        let check = try decode(SystemUpdateCheck.self, #"""
        {"update_available":true,"current_version":"1.2.5","latest_version":"1.3.0","release_name":"1.3.0",
         "release_notes":"Notes","release_url":"https://github.com","published_at":"2026-09-20T00:00:00",
         "is_docker":true,"is_ha_addon":false,"update_method":"docker","error":null}
        """#)
        #expect(check.isDocker == true)
        let status = try decode(SystemUpdateStatus.self, #"{"status":"downloading","progress":40,"message":"Downloading","error":null}"#)
        #expect(status.progress == 40)
        let diag = try decode(SystemPrinterDiagnostic.self, #"""
        {"printer_id":1,"ip_address":"192.168.1.20","overall":"fail",
         "checks":[{"id":"port_mqtt","status":"pass","params":null},{"id":"subnet","status":"warn","params":{"printer_subnet":"10.0.0.0/24"}}]}
        """#)
        #expect(diag.checks[0].title == "MQTT port (8883)")
        #expect(diag.checks[1].params?["printer_subnet"]?.stringValue == "10.0.0.0/24")
        let bug = try decode(SystemBugReportResponse.self, #"{"success":true,"message":null,"issue_url":"https://x","issue_number":42}"#)
        #expect(bug.issueNumber == 42)
    }
}
