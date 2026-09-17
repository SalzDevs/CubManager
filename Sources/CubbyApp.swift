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

struct RunningApp: Identifiable {
    let id: Int
    let name: String
    let icon: NSImage?
}

struct ContentView: View {
    private let minRowHeight: CGFloat = 40

    @State private var apps: [RunningApp] = []

    private func refreshApps() {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPid }
            .compactMap { app -> RunningApp? in
                guard let name = app.localizedName else { return nil }
                return RunningApp(id: Int(app.processIdentifier), name: name, icon: app.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        GeometryReader { geo in
            let rowCount = apps.count
            // Viewport must show whole rows only: n = rows that fit at min height
            let fitCount = max(1, min(rowCount, Int(geo.size.height / minRowHeight)))
            let rowHeight = geo.size.height / CGFloat(fitCount)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(apps) { app in
                        HStack(spacing: 10) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: min(max(rowHeight * 0.38, 22), 54),
                                           height: min(max(rowHeight * 0.38, 22), 54))
                            }
                            Text(app.name)
                                .foregroundStyle(.white.opacity(0.85))
                                .font(.system(size: min(max(rowHeight * 0.26, 13), 21), weight: .regular))
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .bottom) {
                // Bottom of last visible row always sits at viewport end
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
            }
        }
        .background(Color.black)
        .onAppear { refreshApps() }
    }
}
