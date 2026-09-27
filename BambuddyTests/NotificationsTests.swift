import Testing
import Foundation
@testable import Bambuddy

struct NotificationsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesNotificationPreferences() throws {
        let prefs = try decode(NotificationEmailPreferences.self, #"""
        {"notify_print_start":false,"notify_print_complete":true,"notify_print_failed":true,"notify_print_stopped":false}
        """#)
        #expect(prefs.notifyPrintComplete)
        #expect(!prefs.notifyPrintStopped)
    }
}
