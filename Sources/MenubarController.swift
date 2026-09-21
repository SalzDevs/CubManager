import AppKit
import Combine

// Menu bar item: top CPU hogs + open/settings/quit. Rebuilt on each open.
final class MenubarController: NSObject, NSMenuDelegate {
    static let shared = MenubarController()

    private var statusItem: NSStatusItem?
    let menu = NSMenu()
    private let closer = MainWindowCloser()
    private var cancellables = Set<AnyCancellable>()

    private func cpuPct(_ app: AppEntry) -> Double {
        (app.pid.flatMap { UsageStore.shared.usage[Int($0)]?.cpu }) ?? 0
    }

    /// The actual logo artwork as the menu bar mark (18pt, colored —
    /// not a template so the navy bear + cream face keep their identity).
    /// Falls back to the hand-drawn bear silhouette if the asset is missing.
    static func menuBarLogoIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 20, height: 20)   // 44px rep renders at 2x
            return img
        }
        return bearMenuBarIcon()
    }

    /// Custom menu bar mark: bear-head silhouette (matches the app logo).
    /// Template image = macOS tints it for light/dark menu bars automatically.
    static func bearMenuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // head
            NSBezierPath(ovalIn: NSRect(x: 4.0, y: 1.6, width: 10.0, height: 9.8)).fill()
            // ears — clearly separated above the head
            NSBezierPath(ovalIn: NSRect(x: 2.2, y: 9.8, width: 5.2, height: 5.2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10.6, y: 9.8, width: 5.2, height: 5.2)).fill()
            // inner-ear cutouts
            if let ctx = NSGraphicsContext.current {
                ctx.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 3.5, y: 11.0, width: 2.6, height: 2.6)).fill()
                NSBezierPath(ovalIn: NSRect(x: 11.9, y: 11.0, width: 2.6, height: 2.6)).fill()
                ctx.compositingOperation = .sourceOver
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    func apply() {
        let enabled = UserDefaults.standard.object(forKey: "menubarEnabled") as? Bool ?? true
        if enabled {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = Self.menuBarLogoIcon()
                // Warm tint while any CPU-spike alert is live
                UsageStore.shared.$liveAlertRuleIDs
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] live in
                        self?.statusItem?.button?.contentTintColor = live.isEmpty ? nil : .systemOrange
                    }
                    .store(in: &cancellables)
                menu.delegate = self
                menu.autoenablesItems = false
                item.menu = menu
                statusItem = item
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let store = UsageStore.shared
        let hogs = Array(
            store.runningApps
                .filter { $0.pid != nil }
                .sorted { cpuPct($0) > cpuPct($1) }
                .prefix(3)
        )
        if hogs.isEmpty {
            let none = NSMenuItem(title: "No running apps", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for app in hogs {
                let item = NSMenuItem(title: "\(app.name) — \(String(format: "%.1f%%", cpuPct(app)))",
                                      action: #selector(activateHog(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app.pid
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open CubManager", action: #selector(openMainWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsPanel), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit CubManager",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func activateHog(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? pid_t,
              let app = UsageStore.shared.runningApps.first(where: { $0.pid == pid }) else { return }
        UsageStore.shared.openApp(app)
    }

    @objc private func openMainWindow() {
        guard let w = MainWindowRef.window else { return }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettingsPanel() {
        // SwiftUI Settings scene responder action
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
    }
}