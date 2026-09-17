import SwiftUI
import AppKit
import Combine

private let PROC_PIDTASKINFO: Int32 = 4
private let RUSAGE_INFO_V2: Int32 = 2

private struct ProcTaskInfo {
    var pti_virtual_size: UInt64 = 0
    var pti_resident_size: UInt64 = 0
    var pti_total_user: UInt64 = 0
    var pti_total_system: UInt64 = 0
    var pti_threads_user: UInt64 = 0
    var pti_threads_system: UInt64 = 0
    var pti_policy: Int32 = 0
    var pti_faults: Int32 = 0
    var pti_pageins: Int32 = 0
    var pti_cow_faults: Int32 = 0
    var pti_messages_sent: Int32 = 0
    var pti_messages_received: Int32 = 0
    var pti_syscalls_mach: Int32 = 0
    var pti_syscalls_unix: Int32 = 0
    var pti_csw: Int32 = 0
    var pti_threadnum: Int32 = 0
    var pti_numrunning: Int32 = 0
    var pti_priority: Int32 = 0
}

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pid_rusage")
private func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer?) -> Int32

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
    private static let usageQueue = DispatchQueue(label: "cubby.usage")
    private static var cpuSamples: [Int: (cpuNanos: UInt64, wall: Double)] = [:]

    @State private var runningApps: [AppEntry] = []
    @State private var installedApps: [AppEntry] = []
    @State private var hoveredAppID: String? = nil
    @State private var hoveredQuitID: String? = nil
    @State private var hoveredOpenID: String? = nil
    @State private var cancellables = Set<AnyCancellable>()
    @State private var query: String = ""
    @State private var usage: [Int: (cpu: Double, memMB: Double)] = [:]
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

    private func memString(_ memMB: Double) -> String {
        memMB >= 1024 ? String(format: "%.1f GB", memMB / 1024) : String(format: "%.0f MB", memMB)
    }

    private func cpuColor(_ cpu: Double) -> Color {
        if cpu >= 200 { return Color.orange.opacity(0.9) }
        if cpu >= 100 { return Color.yellow.opacity(0.75) }
        return Color.white.opacity(0.55)
    }

    private func memColor(_ memMB: Double) -> Color {
        memMB >= 2048 ? Color.yellow.opacity(0.75) : Color.white.opacity(0.55)
    }

    private func usageView(_ u: (cpu: Double, memMB: Double), rowHeight: CGFloat) -> some View {
        let size = min(max(rowHeight * 0.18, 10), 13)
        let iconSize = min(max(rowHeight * 0.16, 9), 11)
        return HStack(spacing: 14) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Text(String(format: "%.1f%%", u.cpu))
                    .font(.system(size: size, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(cpuColor(u.cpu))
            }
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Text(memString(u.memMB))
                    .font(.system(size: size, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(memColor(u.memMB))
            }
        }
    }

    private func refreshUsage() {
        let pids = runningApps.compactMap { $0.pid }
        Self.usageQueue.async {
            let now = ProcessInfo.processInfo.systemUptime
            var snapshot: [Int: (cpu: Double, memMB: Double)] = [:]
            for pid in pids {
                var info = ProcTaskInfo()
                let sz = Int32(MemoryLayout<ProcTaskInfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { continue }
                let total = info.pti_total_user &+ info.pti_total_system
                var cpu = 0.0
                if let prev = Self.cpuSamples[Int(pid)] {
                    let dNanos = total >= prev.cpuNanos ? total - prev.cpuNanos : 0
                    let dWall = now - prev.wall
                    if dWall > 0 {
                        cpu = Double(dNanos) / (dWall * 1_000_000_000.0) * 100.0
                    }
                }
                Self.cpuSamples[Int(pid)] = (total, now)
                var physFootprint: UInt64 = 0
                var rusageBuf = [UInt8](repeating: 0, count: 512)
                if proc_pid_rusage(pid, RUSAGE_INFO_V2, &rusageBuf) == 0 {
                    physFootprint = rusageBuf.withUnsafeBytes { $0.load(fromByteOffset: 72, as: UInt64.self) }
                }
                let memMB = Double(physFootprint) / (1024.0 * 1024.0)
                snapshot[Int(pid)] = (cpu, memMB)
            }
            DispatchQueue.main.async { usage = snapshot }
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
                                    if !searching, let pid = app.pid, let u = usage[Int(pid)] {
                                        usageView(u, rowHeight: rowHeight)
                                    }
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
            refreshUsage()
            Timer.publish(every: 1.0, on: .main, in: .common)
                .autoconnect()
                .sink { _ in refreshUsage() }
                .store(in: &cancellables)
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
