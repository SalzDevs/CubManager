import SwiftUI
import AppKit
import UserNotifications

@main
struct CubManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = UsageStore.shared

    var body: some Scene {
        // Single window: WindowGroup restores duplicate windows on relaunch
        Window("CubManager", id: "main") {
            ContentView()
                .frame(minWidth: 320, minHeight: 420)
                .navigationTitle("CubManager")
                .background(Color.black)
                .background(WindowTracker())
                .environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let closer = MainWindowCloser()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.applyDockIcon()
        MenubarController.shared.apply()
        NotchController.shared.apply()
        UNUserNotificationCenter.current().delegate = self
        DispatchQueue.main.async {
            for window in NSApp.windows where window.level == .normal {
                window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
                window.collectionBehavior = [.fullScreenNone]
                window.isMovableByWindowBackground = true
                window.setContentSize(NSSize(width: 320, height: 420))
                window.center()
                window.delegate = self.closer
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
        }
    }

    // Keep running with no windows (menu-bar mode)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    static func applyDockIcon() {
        let visible = UserDefaults.standard.object(forKey: "dockIconVisible") as? Bool ?? true
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}