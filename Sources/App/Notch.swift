#if os(macOS) && !CUB_SELF_TEST
import SwiftUI
import AppKit
import Combine

// MARK: - Optional notch summary, not a compressed diagnostic dashboard

@MainActor
final class NotchController {
    static let shared = NotchController()
    private var panel: NSPanel?
    private var timer: Timer?
    private var work: DispatchWorkItem?
    private var expanded = false
    private var subscription: AnyCancellable?
    private var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } }

    func apply() {
        work?.cancel(); work = nil
        guard UserDefaults.standard.bool(forKey: "notchEnabled"), screen != nil else {
            panel?.orderOut(nil); panel = nil; expanded = false; timer?.invalidate(); timer = nil
            subscription = nil; return
        }
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear
            p.hasShadow = false; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
            subscription = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .receive(on: DispatchQueue.main).sink { _ in Self.shared.apply() }
        }
        show(expanded: false)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in Self.shared.refresh() } }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
        refresh()
    }
    func hover(_ inside: Bool) {
        work?.cancel()
        let action = DispatchWorkItem { [weak self] in self?.show(expanded: inside) }
        work = action
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.3 : 0.55), execute: action)
    }
    private func show(expanded: Bool) {
        guard let panel, let screen else { return }
        self.expanded = expanded
        let width: CGFloat = expanded ? 330 : 240
        let height: CGFloat = expanded ? 190 : max(32, screen.safeAreaInsets.top)
        panel.contentView = NSHostingView(rootView: NotchSummary(store: .shared, expanded: expanded)
            .frame(width: width, height: height).background(.black).clipShape(RoundedRectangle(cornerRadius: 12)))
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
            width: width, height: height), display: true)
        if !shouldHide { panel.orderFrontRegardless() }
    }
    private var shouldHide: Bool {
        guard UserDefaults.standard.bool(forKey: "hideInFullscreen"), let screen else { return false }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int32) != ProcessInfo.processInfo.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else { continue }
            // Window-server coordinates are top-left based on the primary display.
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            let rect = NSRect(x: x, y: primaryTop - y - h, width: w, height: h)
            if rect.insetBy(dx: -4, dy: -4).contains(screen.frame) { return true }
        }
        return false
    }
    func refresh() {
        guard let panel else { return }
        if screen == nil { apply(); return }
        if shouldHide { work?.cancel(); panel.orderOut(nil) }
        else if !panel.isVisible { show(expanded: false) }
    }
}

struct NotchSummary: View {
    @ObservedObject var store: UsageStore
    let expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if expanded {
                Text(store.statusTitle).font(.headline).foregroundStyle(.white)
                Text(store.attentionCount > 0 ? "Review sustained activity and choose what to do." : "A quiet overview of monitored apps. Open CubManager for details and history.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                Button("Open CubManager") { AppWindows.shared.showMain() }.buttonStyle(.borderedProminent).tint(.teal)
            } else {
                HStack {
                    Spacer()
                    Image(nsImage: AppWindows.logo()).resizable().frame(width: 18, height: 18)
                    if store.attentionCount > 0 { Circle().fill(.orange).frame(width: 5, height: 5) }
                    Spacer()
                }.foregroundStyle(.white)
            }
        }.padding(expanded ? 20 : 4).preferredColorScheme(.dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle()).onHover { NotchController.shared.hover($0) }
            .accessibilityLabel(expanded ? "CubManager summary" : "CubManager. Hover to expand.")
    }
}
#endif
