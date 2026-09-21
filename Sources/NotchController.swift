import SwiftUI
import AppKit
import Combine

// Notch-docked mode: a black panel docked top-center over the camera notch
// (looks like the notch extends), collapsed to a bear mark; expands on hover
// into the full app grid. Non-activating: hovering never steals focus.
final class NotchPanel: NSPanel {
    weak var notchController: NotchController?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseExited {
            notchController?.scheduleCollapse()
        } else if event.type == .mouseEntered {
            notchController?.cancelCollapse()
        }
        super.sendEvent(event)
    }
}

final class NotchController: NSObject {
    static let shared = NotchController()


    private var panel: NotchPanel?
    private var isExpanded = false
    private var collapseTimer: Timer?
    private var dwellTimer: Timer?
    private var store: UsageStore { UsageStore.shared }

    private var hasNotch: Bool {
        (NSScreen.main?.safeAreaInsets.top ?? 0) > 0
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "notchEnabled") && hasNotch
    }

    func apply() {
        if isEnabled {
            if panel == nil { createPanel() }
            position()
        } else if let p = panel {
            p.orderOut(nil)
            panel = nil
            isExpanded = false
        }
    }

    private func createPanel() {
        let p = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.notchController = self
        p.ignoresMouseEvents = false
        panel = p
        showCollapsed()
    }

    private func screenFrame() -> NSRect {
        NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1470, height: 956)
    }

    private func collapsedFrame() -> NSRect {
        let s = screenFrame()
        let height: CGFloat = 32
        return NSRect(x: s.midX - 120, y: s.maxY - height, width: 240, height: height)
    }

    private func expandedFrame() -> NSRect {
        let s = screenFrame()
        let height = min(420, s.maxY - 60)
        return NSRect(x: s.midX - 160, y: s.maxY - height, width: 320, height: height)
    }

    private func showCollapsed() {
        guard let panel else { return }
        isExpanded = false
        let hosting = NSHostingView(rootView:
            NotchCollapsedView()
                .frame(width: 240, height: 32)
                .clipShape(.rect(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        )
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = hosting
        panel.setFrame(collapsedFrame(), display: true)
        panel.orderFrontRegardless()
    }

    func expand() {
        guard let panel, !isExpanded else { return }
        isExpanded = true
        let f = expandedFrame()
        let hosting = NSHostingView(rootView:
            ContentView()
                .environmentObject(store)
                .frame(width: 320, height: f.height)
                .clipShape(.rect(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
        )
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: f.size)
        panel.contentView = hosting
        panel.setFrame(f, display: true, animate: true)
    }

    func collapse() {
        guard let panel, isExpanded else { return }
        showCollapsed()
    }

    func scheduleCollapse() {
        cancelDwell()
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            self?.collapse()
        }
    }

    func cancelCollapse() {
        collapseTimer?.invalidate()
        collapseTimer = nil
    }

    /// Cursor must rest on the mark ~0.3s before expanding — fast sweeps
    /// (e.g. toward the fullscreen menu bar) never trigger the grid.
    func beginDwell() {
        guard !isExpanded else { return }
        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.expand()
        }
    }

    func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    /// Any on-screen window that covers the main screen means some app is
    /// fullscreen on the current space — hide the panel so it never floats
    /// over video/games. Cheap CGWindowList check, piggybacks on a 0.5s tick.
    static func fullscreenAppOnMainScreen() -> Bool {
        guard let main = NSScreen.main else { return false }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info["kCGWindowLayer"] as? Int) == 0 else { continue }
            guard let owner = info["kCGWindowOwnerName"] as? String,
                  !owner.contains("CubManager") else { continue }
            guard let b = info["kCGWindowBounds"] as? [String: CGFloat] else { continue }
            let w = b["Width"] ?? 0, h = b["Height"] ?? 0
            if w >= main.frame.width - 4 && h >= main.frame.height - 4 { return true }
        }
        return false
    }

    func refresh() {
        guard let panel else { return }
        let hideInFullscreen = UserDefaults.standard.object(forKey: "hideInFullscreen") as? Bool ?? true
        if hideInFullscreen && Self.fullscreenAppOnMainScreen() {
            if panel.isVisible {
                panel.orderOut(nil)
                isExpanded = false
            }
        } else if !panel.isVisible {
            showCollapsed()
        }
    }

    private func position() {
        guard let panel else { return }
        panel.setFrame(isExpanded ? expandedFrame() : collapsedFrame(), display: true)
    }

    override init() {
        super.init()
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &refreshCancellables)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    private var refreshCancellables = Set<AnyCancellable>()

    @objc private func screenChanged() { apply() }
}

struct NotchCollapsedView: View {
    @ObservedObject private var store = UsageStore.shared
    @State private var pulse = false

    private var alertActive: Bool { !store.liveAlertRuleIDs.isEmpty }

    var body: some View {
        ZStack {
            Color.black
            Image(nsImage: MenubarController.menuBarLogoIcon())
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .opacity(0.9)
                .scaleEffect(alertActive && pulse ? 1.3 : 1.0)
                .opacity(alertActive && pulse ? 1.0 : (alertActive ? 0.55 : 0.9))
                .onChange(of: store.liveAlertRuleIDs) { _, live in
                    pulse = false
                    if !live.isEmpty {
                        withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    } else {
                        pulse = false
                    }
                }
        }
        .onHover { hovering in
            if hovering { NotchController.shared.beginDwell() }
        }
        .help("CubManager")
    }
}