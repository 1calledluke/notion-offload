import Foundation
import UserNotifications

enum Notifier {
    static func notify(title: String = "Notion Transcribe", body: String) {
        // UNUserNotificationCenter throws an unrecoverable NSException outside
        // a real .app bundle (e.g. the --transcribe CLI mode). Log instead.
        guard Bundle.main.bundleIdentifier != nil else {
            Log.write("(cli) \(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.write("Notification error: \(error.localizedDescription)")
            }
        }
    }
}
