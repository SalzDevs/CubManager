#if os(macOS) && !CUB_SELF_TEST
import SwiftUI
import AppKit
import Combine

// MARK: - AppKit windows and menu bar (no external nibs/assets)

@MainActor
final class AppWindows: NSObject, NSWindowDelegate, NSMenuDelegate {
    static let shared = AppWindows()
    private var mainWindow: NSWindow?
    var mainWindowRef: NSWindow? { mainWindow }
    private var settingsWindow: NSWindow?
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?

    static func logo() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 20, height: 20); return image
        }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 2, width: 12, height: 13)).fill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 12, width: 7, height: 7)).fill()
            NSBezierPath(ovalIn: NSRect(x: 12, y: 12, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    func showMain() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "CubManager"
            window.styleMask.insert(.fullSizeContentView)   // content under the title bar — no dead band
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            let hosting = NSHostingView(rootView: ContentView(store: .shared))
            hosting.safeAreaRegions = []                    // no notch-inset dead band at the top
            window.contentView = hosting
            window.minSize = NSSize(width: 440, height: 260)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.center()
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.deminiaturize(nil); mainWindow?.makeKeyAndOrderFront(nil)
    }
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 650),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "CubManager Settings"
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: SettingsView(store: .shared))
            window.isReleasedWhenClosed = false; window.delegate = self; window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }

    func applyVisibility() {
        let defaults = UserDefaults.standard
        let showMenu = defaults.bool(forKey: "menubarEnabled")
        let showDock = defaults.bool(forKey: "dockIconVisible") || !showMenu
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        if showMenu && item == nil {
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            status.button?.image = Self.logo(); status.button?.toolTip = "CubManager"
            let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
            status.menu = menu; item = status
            subscription = UsageStore.shared.$reports.sink { [weak self] reports in
                let count = reports.values.filter { !$0.analysis.signals.isEmpty }.count
                self?.item?.button?.contentTintColor = count > 0 ? .systemOrange : nil
                self?.item?.button?.toolTip = count > 0 ? "CubManager · \(count) apps worth reviewing" : "CubManager"
            }
        } else if !showMenu, let item {
            NSStatusBar.system.removeStatusItem(item); self.item = nil; subscription = nil
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = UsageStore.shared
        if !store.statusTitle.isEmpty {
            let title = NSMenuItem(title: store.statusTitle, action: nil, keyEquivalent: "")
            title.isEnabled = false; menu.addItem(title)
        }
        let top = store.reports.values.sorted {
            let a = $0.analysis.primary?.kind.priority ?? 0, b = $1.analysis.primary?.kind.priority ?? 0
            return a == b ? ($0.sample.cpu ?? -1) > ($1.sample.cpu ?? -1) : a > b
        }.prefix(3)
        for report in top {
            let entry = NSMenuItem(title: "\(report.descriptor.name) · \(Format.cpu(report.sample.cpu)) CPU", action: #selector(inspectMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = InstanceBox(report.descriptor.id)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        add(menu, "Open CubManager", #selector(openMain), "o")
        add(menu, "Settings…", #selector(openSettings), ",")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CubManager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; menu.addItem(quit)
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self; menu.addItem(entry)
    }
    @objc private func openMain() { showMain() }
    @objc private func openSettings() { showSettings() }
    @objc private func inspectMenu(_ sender: NSMenuItem) {
        if let box = sender.representedObject as? InstanceBox { UsageStore.shared.inspect(box.id) }
    }
}
private final class InstanceBox: NSObject { let id: AppInstanceID; init(_ id: AppInstanceID) { self.id = id } }
#endif
