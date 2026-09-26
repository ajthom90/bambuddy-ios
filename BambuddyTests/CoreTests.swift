import Testing
import Foundation
import SwiftUI
@testable import Bambuddy

struct CoreTests {
    @Test func jsonValueKeepsSnakeCaseKeysUnderSnakeStrategy() throws {
        struct Wrapper: Decodable { var payload: JSONValue }
        let data = Data(#"{"payload":{"nozzle_temp":210,"ams_0":{"tray_now":3}}}"#.utf8)
        let w = try APICoders.decoder.decode(Wrapper.self, from: data)
        #expect(w.payload["nozzle_temp"]?.intValue == 210)
        #expect(w.payload["ams_0"]?["tray_now"]?.intValue == 3)
    }

    @Test func statusDeltaMergeDecodes() throws {
        let base: JSONValue = ["id": 1, "name": "P1S", "connected": true, "state": "IDLE", "progress": 0]
        let merged = base.merging(["state": "RUNNING", "progress": 42.5, "temperatures": ["bed": 55, "nozzle_heating": true]])
        let status = try merged.decode(PrinterStatus.self)
        #expect(status.state == "RUNNING")
        #expect(status.progress == 42.5)
        #expect(status.temp("bed") == 55)
        #expect(status.isPrinting)
    }

    @Test func loginResponseRequires2fa() throws {
        let data = Data(#"{"requires_2fa":true,"pre_auth_token":"abc","two_fa_methods":["totp","email"]}"#.utf8)
        let r = try APICoders.decoder.decode(LoginResponse.self, from: data)
        #expect(r.requires2fa == true)
        #expect(r.preAuthToken == "abc")
        #expect(r.twoFaMethods == ["totp", "email"])
    }

    @Test func parsesServerDates() {
        #expect(APICoders.parseDate("2026-09-26T18:58:58") != nil)
        #expect(APICoders.parseDate("2026-09-26T18:58:58.123456") != nil)
        #expect(APICoders.parseDate("2026-09-26T18:58:58.123456+00:00") != nil)
        #expect(APICoders.parseDate("2026-09-26") != nil)
    }

    @Test func normalizesServerURLs() {
        #expect(AppSession.normalize("192.168.1.5:8000")?.absoluteString == "http://192.168.1.5:8000")
        #expect(AppSession.normalize("https://bambuddy.example.com/")?.absoluteString == "https://bambuddy.example.com")
        #expect(AppSession.normalize("https://x.com/api/v1")?.absoluteString == "https://x.com")
    }

    @Test func buildsQueryURLs() {
        let c = APIClient(baseURL: URL(string: "https://h.example")!)
        let u = c.url("printers/1/fan-speed", query: ["fan": "part", "speed": 50, "x": nil])
        #expect(u.absoluteString == "https://h.example/api/v1/printers/1/fan-speed?fan=part&speed=50")
        let e = c.url("library/files", query: ["q": "a+b c"])
        #expect(e.absoluteString == "https://h.example/api/v1/library/files?q=a%2Bb%20c")
    }

    @Test func parsesHexColors() {
        #expect(Color(hex: "FFF144FF") != nil)
        #expect(Color(hex: "#46A8F9") != nil)
        #expect(Color(hex: "") == nil)
    }
}
