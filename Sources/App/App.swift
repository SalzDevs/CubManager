#if os(macOS) && !CUB_SELF_TEST
import AppKit
import UserNotifications
import Foundation

// MARK: - Application entry point

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["menubarEnabled": true, "dockIconVisible": true,
            "notchEnabled": false, "hideInFullscreen": true, "refreshInterval": 2.0, "notificationsEnabled": false])
        let appMenu = NSMenu()
        let root = NSMenuItem(); let submenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; submenu.addItem(settings); submenu.addItem(.separator())
        submenu.addItem(withTitle: "Quit CubManager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = submenu; appMenu.addItem(root)
        // Standard Edit menu preserves native text editing in hosted SwiftUI fields.
        let edit = NSMenuItem(); edit.title = "Edit"; let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        edit.submenu = editMenu; appMenu.addItem(edit); NSApp.mainMenu = appMenu
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        UsageStore.shared.start()
        AppWindows.shared.applyVisibility()
        NotchController.shared.apply()
        AppWindows.shared.showMain()
    }
    @objc private func showSettings() { AppWindows.shared.showSettings() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindows.shared.showMain(); return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completion: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let pid = (info["pid"] as? NSNumber)?.int32Value
        let launched = (info["launched"] as? NSNumber)?.doubleValue
        Task { @MainActor in
            if let pid, let launched {
                let id = AppInstanceID(pid: pid, launched: Date(timeIntervalSince1970: launched))
                if UsageStore.shared.reports[id] != nil { UsageStore.shared.inspect(id) }
                else { AppWindows.shared.showMain() }
            } else { AppWindows.shared.showMain() }
            completion()
        }
    }
}

@main
struct CubManagerMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
