import SwiftUI
import AppKit
import Combine

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
    @State private var hoveredAppID: Int? = nil
    @State private var hoveredQuitID: Int? = nil
    @State private var cancellables = Set<AnyCancellable>()
    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool

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

    private func quitApp(_ app: RunningApp) {
        if let running = NSRunningApplication(processIdentifier: pid_t(app.id)) {
            // Graceful quit: app's own save/cancel flow still runs (same as ⌘Q)
            running.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refreshApps() }
        refreshApps()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar — flat full-width header row, flush with grid
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.4))
                    .font(.system(size: 13, weight: .medium))
                TextField("Search apps", text: $query, prompt: Text("Search apps").foregroundColor(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white.opacity(0.9))
                    .font(.system(size: 13))
                    .focused($isSearchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.5))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: minRowHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSearchFocused ? Color.white.opacity(0.35) : Color.white.opacity(0.12))
                    .frame(height: 1)
            }
            .animation(.easeInOut(duration: 0.15), value: query.isEmpty)
            .animation(.easeInOut(duration: 0.15), value: isSearchFocused)

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
                            // Quit button, revealed on hover
                            Button {
                                quitApp(app)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: min(max(rowHeight * 0.2, 11), 18), weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(width: min(max(rowHeight * 0.3, 24), 32),
                                           height: min(max(rowHeight * 0.3, 24), 32))
                                    .background(Circle().fill(Color.white.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                hoveredQuitID = hovering ? app.id : nil
                            }
                            .background(
                                Circle().fill(hoveredQuitID == app.id
                                              ? Color.red.opacity(0.8)
                                              : Color.white.opacity(0.15))
                            )
                            .opacity(hoveredAppID == app.id ? 1 : 0)
                            .help("Quit \(app.name)")
                        }
                        .padding(.horizontal, 14)
                        .frame(height: rowHeight)
                        .background(hoveredAppID == app.id ? Color.white.opacity(0.08) : Color.clear)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoveredAppID = hovering ? app.id : nil
                        }
                        .contextMenu {
                            Button("Quit \(app.name)") { quitApp(app) }
                        }
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
        }
        .background(Color.black)
        .onAppear {
            refreshApps()
            // React to app launches and quits while Cubby runs
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didLaunchApplicationNotification)
                .merge(with: NSWorkspace.shared.notificationCenter
                    .publisher(for: NSWorkspace.didTerminateApplicationNotification))
                .receive(on: DispatchQueue.main)
                .sink { _ in refreshApps() }
                .store(in: &cancellables)
        }
    }
}
