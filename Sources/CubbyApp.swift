import SwiftUI
import AppKit

@main
struct CubbyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 320, minHeight: 420)
                .navigationTitle("Cubby")
                .background(Color.black)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.level == .normal {
                window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
                window.collectionBehavior = [.fullScreenNone]
                window.isMovableByWindowBackground = true
                window.setContentSize(NSSize(width: 320, height: 420))
                window.center()
            }
        }
    }
}

struct ContentView: View {
    private let minRowHeight: CGFloat = 40

    private var rows: [String] {
        (1...12).map { "Row \($0)" }
    }

    var body: some View {
        GeometryReader { geo in
            let rowCount = CGFloat(rows.count)
            // Fit rows to window height, but never below minRowHeight (scroll if overflow)
            let rowHeight = max(minRowHeight, geo.size.height / rowCount)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.self) { row in
                        HStack {
                            Text(row)
                                .foregroundStyle(.white.opacity(0.85))
                                .font(.system(size: 13, weight: .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: rowHeight)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 1)
                        }
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 1)
                        }
                    }
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.black)
    }
}
