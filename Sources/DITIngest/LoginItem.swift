import Foundation
import ServiceManagement

/// Registers the app to launch automatically at login, so it's always running.
enum LoginItem {
    static func enable() {
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Not fatal: the app still works, it just won't auto-start until the
            // user enables it in System Settings > General > Login Items.
            NSLog("Login item registration failed: \(error)")
        }
    }
}
