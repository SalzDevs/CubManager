import SwiftUI
import AppKit

// Weak ref to the main window (the window is never destroyed — see AppDelegate)
final class MainWindowRef {
    static weak var window: NSWindow?
}

struct WindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = TrackerView()
        return v
    }
    func updateNSView(_ view: NSView, context: Context) {
        MainWindowRef.window = view.window
    }

    final class TrackerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainWindowRef.window = window
        }
    }
}

// Red X hides the window instead of destroying it — the app keeps running in
// the menu bar and "Open CubManager" summons it back.
final class MainWindowCloser: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}