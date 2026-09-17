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
        // Bare-binary launch (not a .app bundle) needs explicit regular activation
        // or the window never becomes key -> TextField ignores keyboard.
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            for window in NSApp.windows where window.level == .normal {
                window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
                window.collectionBehavior = [.fullScreenNone]
                window.isMovableByWindowBackground = true
                window.setContentSize(NSSize(width: 320, height: 420))
                window.center()
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
        }
    }
}

struct AppEntry: Identifiable {
    let id: String          // bundle id, fallback path
    let name: String
    let icon: NSImage?
    let url: URL?           // .app bundle URL for launch
    let pid: pid_t?
    var isRunning: Bool { pid != nil }
}

struct ContentView: View {
    private let minRowHeight: CGFloat = 40

    @State private var runningApps: [AppEntry] = []
    @State private var installedApps: [AppEntry] = []
    @State private var hoveredAppID: String? = nil
    @State private var hoveredQuitID: String? = nil
    @State private var hoveredOpenID: String? = nil
    @State private var cancellables = Set<AnyCancellable>()
    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var displayedApps: [AppEntry] {
        if trimmedQuery.isEmpty { return runningApps }
        return installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.id.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var runningIDs: Set<String> {
        Set(runningApps.map(\.id))
    }

    private func highlightedText(_ name: String, query q: String) -> AttributedString {
        var attr = AttributedString(name)
        attr.foregroundColor = .white.opacity(0.85)
        guard !q.isEmpty else { return attr }
        var index = name.startIndex
        while index < name.endIndex {
            guard let r = name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: index..<name.endIndex) else { break }
            let lower = name.distance(from: name.startIndex, to: r.lowerBound)
            let upper = name.distance(from: name.startIndex, to: r.upperBound)
            if let ar = Range(NSRange(location: lower, length: upper - lower), in: attr) {
                attr[ar].foregroundColor = .white
            }
            index = r.upperBound
        }
        return attr
    }

    private func refreshRunningApps() {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPid }
            .compactMap { app -> AppEntry? in
                guard let name = app.localizedName else { return nil }
                let id = app.bundleIdentifier ?? "pid-\(app.processIdentifier)"
                return AppEntry(id: id, name: name, icon: app.icon,
                                url: app.bundleURL, pid: app.processIdentifier)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func loadInstalledApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let dirs = [
                "/Applications",
                "/System/Applications",
                "/System/Applications/Utilities",
                NSHomeDirectory() + "/Applications"
            ]
            var seen = Set<String>()
            var result: [AppEntry] = []
            for d in dirs {
                guard let urls = try? fm.contentsOfDirectory(
                    at: URL(fileURLWithPath: d),
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for u in urls where u.pathExtension == "app" {
                    let bundle = Bundle(url: u)
                    let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? u.deletingPathExtension().lastPathComponent
                    let bid = bundle?.bundleIdentifier ?? u.path
                    if seen.contains(bid) { continue }
                    seen.insert(bid)
                    result.append(AppEntry(id: bid, name: name,
                                           icon: NSWorkspace.shared.icon(forFile: u.path),
                                           url: u, pid: nil))
                }
            }
            let sorted = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { installedApps = sorted }
        }
    }

    private func openApp(_ app: AppEntry) {
        if let pid = app.pid, let running = NSRunningApplication(processIdentifier: pid) {
            running.activate(options: [.activateAllWindows])
        } else if let url = app.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func quitApp(_ app: AppEntry) {
        if let pid = app.pid, let running = NSRunningApplication(processIdentifier: pid) {
            running.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refreshRunningApps() }
        refreshRunningApps()
    }

    private func quitButton(_ app: AppEntry, rowHeight: CGFloat) -> some View {
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

    private func openButton(_ app: AppEntry, rowHeight: CGFloat) -> some View {
        Button {
            openApp(app)
            query = ""
        } label: {
            Image(systemName: "arrow.up.right")
                .font(.system(size: min(max(rowHeight * 0.2, 11), 18), weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: min(max(rowHeight * 0.3, 24), 32),
                       height: min(max(rowHeight * 0.3, 24), 32))
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredOpenID = hovering ? app.id : nil
        }
        .background(
            Circle().fill(hoveredOpenID == app.id
                          ? Color.green.opacity(0.8)
                          : Color.white.opacity(0.15))
        )
        .opacity(hoveredAppID == app.id ? 1 : 0)
        .help("Open \(app.name)")
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
                let searching = !trimmedQuery.isEmpty
                let rowCount = displayedApps.count
                let fitCount = max(1, min(rowCount, Int(geo.size.height / minRowHeight)))
                let rowHeight: CGFloat = searching ? minRowHeight : geo.size.height / CGFloat(fitCount)

                if displayedApps.isEmpty {
                    VStack {
                        Spacer()
                        Text(trimmedQuery.isEmpty ? "No running apps" : "No apps found")
                            .foregroundStyle(.white.opacity(0.4))
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(displayedApps) { app in
                                HStack(spacing: 10) {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: min(max(rowHeight * 0.38, 22), 54),
                                                   height: min(max(rowHeight * 0.38, 22), 54))
                                    }
                                    Text(highlightedText(app.name, query: trimmedQuery))
                                        .font(.system(size: min(max(rowHeight * 0.26, 13), 21), weight: .regular))
                                    if searching && runningIDs.contains(app.id) {
                                        Circle()
                                            .fill(Color.green.opacity(0.9))
                                            .frame(width: 6, height: 6)
                                    }
                                    Spacer()
                                    if app.isRunning {
                                        quitButton(app, rowHeight: rowHeight)
                                    }
                                    if searching {
                                        openButton(app, rowHeight: rowHeight)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .frame(height: rowHeight)
                                .background(hoveredAppID == app.id ? Color.white.opacity(0.08) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { openApp(app) }
                                .onHover { hovering in
                                    hoveredAppID = hovering ? app.id : nil
                                }
                                .contextMenu {
                                    Button("Open \(app.name)") { openApp(app) }
                                    if app.isRunning {
                                        Button("Quit \(app.name)") { quitApp(app) }
                                    }
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
                        if !searching {
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(Color.black)
        .onAppear {
            refreshRunningApps()
            loadInstalledApps()
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didLaunchApplicationNotification)
                .merge(with: NSWorkspace.shared.notificationCenter
                    .publisher(for: NSWorkspace.didTerminateApplicationNotification))
                .receive(on: DispatchQueue.main)
                .sink { _ in refreshRunningApps() }
                .store(in: &cancellables)
        }
    }
}
