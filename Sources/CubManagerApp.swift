import SwiftUI
import AppKit
import Combine
import ServiceManagement

private let PROC_PIDTASKINFO: Int32 = 4
private let RUSAGE_INFO_V2: Int32 = 2

struct ProcTaskInfo {
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

struct AppEntry: Identifiable {
    let id: String          // bundle id, fallback path
    let name: String
    let icon: NSImage?
    let url: URL?           // .app bundle URL for launch
    let pid: pid_t?
    let launchDate: Date?
    var isRunning: Bool { pid != nil }
}

struct UsageSnapshot {
    var cpu: Double = 0
    var memMB: Double = 0
    var info = ProcTaskInfo()
    var diskReadMB: Double = 0
    var diskWriteMB: Double = 0
    var netInMB: Double = 0
    var netOutMB: Double = 0
}

// Single source of truth for app lists + live usage. Consumed by the
// window UI and the menu bar item.
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var runningApps: [AppEntry] = []
    @Published var installedApps: [AppEntry] = []
    @Published var usage: [Int: UsageSnapshot] = [:]
    @Published var history: [Int: [Double]] = [:]

    private let usageQueue = DispatchQueue(label: "cubmanager.usage")
    private var cpuSamples: [Int: (cpuNanos: UInt64, wall: Double)] = [:]

    // Per-app network via /usr/bin/nettop (no public per-app API): one persistent
    // CSV-streaming nettop feeds cumulative bytes_in/out per pid; we delta-sample
    // into monotonic lifetime totals so closed sockets don't erase history.
    private let netQueue = DispatchQueue(label: "cubmanager.nettop", qos: .utility)
    private let netLock = NSLock()
    private var netCounters: [Int: (curIn: UInt64, curOut: UInt64)] = [:]
    private var netState: [Int: (lastIn: UInt64, lastOut: UInt64, totIn: UInt64, totOut: UInt64)] = [:]
    private var nettopProcess: Process?

    private var cancellables = Set<AnyCancellable>()
    private var lastRefresh = Date.distantPast

    private init() {
        // 0.5s cadence; the configured refresh interval gates the heavy pass.
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.maybeRefreshUsage() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRunningApps() }
            .store(in: &cancellables)
        refreshRunningApps()
        loadInstalledApps()
        startNettopMonitor()
        refreshUsage()
        lastRefresh = Date()
    }

    private func maybeRefreshUsage() {
        let interval = UserDefaults.standard.object(forKey: "refreshInterval") as? Double ?? 1.0
        guard Date().timeIntervalSince(lastRefresh) >= interval else { return }
        lastRefresh = Date()
        refreshUsage()
    }

    func cpuPct(_ app: AppEntry) -> Double {
        (app.pid.flatMap { usage[Int($0)]?.cpu }) ?? 0
    }

    private func refreshRunningApps() {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPid }
            .compactMap { app -> AppEntry? in
                guard let name = app.localizedName else { return nil }
                let id = app.bundleIdentifier ?? "pid-\(app.processIdentifier)"
                return AppEntry(id: id, name: name, icon: app.icon,
                                url: app.bundleURL, pid: app.processIdentifier,
                                launchDate: app.launchDate)
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
                                           url: u, pid: nil, launchDate: nil))
                }
            }
            let sorted = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self.installedApps = sorted }
        }
    }

    func openApp(_ app: AppEntry) {
        if let pid = app.pid, let running = NSRunningApplication(processIdentifier: pid) {
            running.activate(options: [.activateAllWindows])
        } else if let url = app.url {
            NSWorkspace.shared.open(url)
        }
    }

    func quitApp(_ app: AppEntry) {
        if let pid = app.pid, let running = NSRunningApplication(processIdentifier: pid) {
            running.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshRunningApps() }
        refreshRunningApps()
    }

    // All processes' parent pids via sysctl. Third-party helpers (Chromium/Electron
    // network services) are direct children of the app; Apple's XPC services are
    // reparented to launchd and can't be attributed with public API.
    private static func allProcessParents() -> [Int32: Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        var infos = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &infos, &size, nil, 0) == 0, size > 0 else { return [:] }
        var map: [Int32: Int32] = [:]
        for i in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
            map[infos[i].kp_proc.p_pid] = infos[i].kp_eproc.e_ppid
        }
        return map
    }

    private func startNettopMonitor() {
        netLock.lock()
        defer { netLock.unlock() }
        if let p = nettopProcess, p.isRunning { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // nettop block-buffers to pipes and flushes nothing until exit; run it
        // under a pseudo-tty (script) so each 1s snapshot is flushed to us.
        p.arguments = ["-q", "/dev/null", "/usr/bin/nettop", "-L", "-x", "-P", "-n", "-s", "1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        nettopProcess = p
        let fh = pipe.fileHandleForReading
        netQueue.async {
            var buf = Data()
            while p.isRunning {
                let d = fh.availableData
                if d.isEmpty { break }
                buf.append(d)
                while let nl = buf.firstRange(of: Data([0x0A])) {
                    let line = String(decoding: buf[buf.startIndex..<nl.lowerBound], as: UTF8.self)
                    buf.removeSubrange(buf.startIndex..<nl.upperBound)
                    self.parseNettopLine(line)
                }
            }
        }
    }

    private func parseNettopLine(_ line: String) {
        let cols = line.components(separatedBy: ",")
        guard cols.count >= 6 else { return }
        let proc = cols[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = proc.lastIndex(of: "."),
              let pid = Int(proc[proc.index(after: dot)...]), pid > 0 else { return }
        let bin = cols[4].trimmingCharacters(in: .whitespacesAndNewlines)
        let bout = cols[5].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bi = UInt64(bin), let bo = UInt64(bout) else { return }
        netLock.lock()
        netCounters[pid] = (bi, bo)
        netLock.unlock()
    }

    private func refreshUsage() {
        let pids = runningApps.compactMap { $0.pid }
        usageQueue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            var snapshot: [Int: UsageSnapshot] = [:]
            for pid in pids {
                var info = ProcTaskInfo()
                let sz = Int32(MemoryLayout<ProcTaskInfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { continue }
                let total = info.pti_total_user &+ info.pti_total_system
                var cpu = 0.0
                if let prev = self.cpuSamples[Int(pid)] {
                    let dNanos = total >= prev.cpuNanos ? total - prev.cpuNanos : 0
                    let dWall = now - prev.wall
                    if dWall > 0 {
                        cpu = Double(dNanos) / (dWall * 1_000_000_000.0) * 100.0
                    }
                }
                self.cpuSamples[Int(pid)] = (total, now)
                var snap = UsageSnapshot()
                snap.cpu = cpu
                snap.info = info
                var rusageBuf = [UInt8](repeating: 0, count: 512)
                if proc_pid_rusage(pid, RUSAGE_INFO_V2, &rusageBuf) == 0 {
                    func u64(_ off: Int) -> UInt64 { rusageBuf.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) } }
                    let mb = 1024.0 * 1024.0
                    snap.memMB = Double(u64(72)) / mb
                    snap.diskReadMB = Double(u64(144)) / mb
                    snap.diskWriteMB = Double(u64(152)) / mb
                }
                // Network: delta-sample nettop's cumulative counters into
                // monotonic lifetime totals. Direct child helper processes
                // (Chromium/Electron network services) count toward the app.
                let ppidMap = Self.allProcessParents()
                self.netLock.lock()
                let counters = self.netCounters
                var childIn: UInt64 = 0
                var childOut: UInt64 = 0
                for (child, parent) in ppidMap where parent == pid {
                    if let k = counters[Int(child)] {
                        childIn &+= k.curIn
                        childOut &+= k.curOut
                    }
                }
                let mine = counters[Int(pid)] ?? (0, 0)
                let curIn = mine.curIn &+ childIn
                let curOut = mine.curOut &+ childOut
                var st = self.netState[Int(pid)] ?? (curIn, curOut, 0, 0)
                let dIn = curIn >= st.lastIn ? curIn &- st.lastIn : 0
                let dOut = curOut >= st.lastOut ? curOut &- st.lastOut : 0
                st = (curIn, curOut, st.totIn &+ dIn, st.totOut &+ dOut)
                self.netState[Int(pid)] = st
                self.netLock.unlock()
                snap.netInMB = Double(st.totIn) / 1_048_576.0
                snap.netOutMB = Double(st.totOut) / 1_048_576.0
                snapshot[Int(pid)] = snap
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.usage = snapshot
                var newHist = self.history
                for (pid, s) in snapshot {
                    var h = newHist[pid] ?? []
                    h.append(s.cpu)
                    if h.count > 60 { h.removeFirst(h.count - 60) }
                    newHist[pid] = h
                }
                newHist = newHist.filter { snapshot[$0.key] != nil }
                self.history = newHist
                // prune net state for dead pids
                self.netLock.lock()
                self.netState = self.netState.filter { snapshot[$0.key] != nil }
                self.netCounters = self.netCounters.filter { snapshot[$0.key] != nil }
                self.netLock.unlock()
            }
        }
    }
}

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

// Menu bar item: top CPU hogs + open/settings/quit. Rebuilt on each open.
final class MenubarController: NSObject, NSMenuDelegate {
    static let shared = MenubarController()

    private var statusItem: NSStatusItem?
    let menu = NSMenu()
    private let closer = MainWindowCloser()

    private func cpuPct(_ app: AppEntry) -> Double {
        (app.pid.flatMap { UsageStore.shared.usage[Int($0)]?.cpu }) ?? 0
    }

    func apply() {
        let enabled = UserDefaults.standard.object(forKey: "menubarEnabled") as? Bool ?? true
        if enabled {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(systemSymbolName: "gauge.with.needle",
                                             accessibilityDescription: "CubManager")
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

@main
struct CubManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = UsageStore.shared

    var body: some Scene {
        // Single window: WindowGroup restores duplicate windows on relaunch
        Window("CubManager", id: "main") {
            ContentView()
                .frame(minWidth: 320, minHeight: 420)
                .navigationTitle("CubManager")
                .background(Color.black)
                .background(WindowTracker())
                .environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let closer = MainWindowCloser()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.applyDockIcon()
        MenubarController.shared.apply()
        DispatchQueue.main.async {
            for window in NSApp.windows where window.level == .normal {
                window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
                window.collectionBehavior = [.fullScreenNone]
                window.isMovableByWindowBackground = true
                window.setContentSize(NSSize(width: 320, height: 420))
                window.center()
                window.delegate = self.closer
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
        }
    }

    // Keep running with no windows (menu-bar mode)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    static func applyDockIcon() {
        let visible = UserDefaults.standard.object(forKey: "dockIconVisible") as? Bool ?? true
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }
}

struct SettingsView: View {
    @AppStorage("menubarEnabled") private var menubarEnabled = true
    @AppStorage("dockIconVisible") private var dockIconVisible = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("refreshInterval") private var refreshInterval = 1.0

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show in menu bar", isOn: $menubarEnabled)
                Toggle("Show Dock icon", isOn: $dockIconVisible)
                    .disabled(!menubarEnabled)
                Toggle("Launch at login", isOn: $launchAtLogin)
                Picker("Refresh rate", selection: $refreshInterval) {
                    Text("Every second").tag(1.0)
                    Text("Every 2 seconds").tag(2.0)
                    Text("Every 5 seconds").tag(5.0)
                }
            }
            Section("About") {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable()
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CubManager")
                            .font(.system(size: 13, weight: .semibold))
                        Text("v\(version) · SalzDevs")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 300)
        .onChange(of: launchAtLogin) { _, on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = !on
            }
        }
        .onChange(of: dockIconVisible) { _, _ in
            AppDelegate.applyDockIcon()
        }
        .onChange(of: menubarEnabled) { _, on in
            // Without a Dock icon the menu bar is the only way back in.
            if !on { dockIconVisible = true }
            MenubarController.shared.apply()
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}

struct Sparkline: View {
    let samples: [Double]
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxV = max(100.0, samples.max() ?? 100.0)
            Path { p in
                guard samples.count > 1, w > 0, h > 0 else { return }
                for (i, s) in samples.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(samples.count - 1)
                    let y = h - min(h, h * CGFloat(s / maxV))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
        }
    }
}

struct ContentView: View {
    private let minRowHeight: CGFloat = 40

    @EnvironmentObject private var store: UsageStore
    @State private var hoveredAppID: String? = nil
    @State private var hoveredQuitID: String? = nil
    @State private var hoveredOpenID: String? = nil
    @State private var hoveredChevronID: String? = nil
    @State private var query: String = ""
    @State private var expandedID: String? = nil
    @FocusState private var isSearchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var displayedApps: [AppEntry] {
        if trimmedQuery.isEmpty { return store.runningApps }
        return store.installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.id.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var runningIDs: Set<String> {
        Set(store.runningApps.map(\.id))
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

    private func rowTap(_ app: AppEntry) {
        // Row click toggles the details panel. Clicking never switches
        // to another app's window.
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedID = expandedID == app.id ? nil : app.id
        }
    }

    private func clearHover() {
        // Window resize moves rows under a stationary cursor; SwiftUI's
        // tracking areas don't fire enter/exit on pure frame changes, so
        // hover state goes stale (highlight sticks to the wrong row).
        // Reset it on resize; the next real mouse move re-establishes it.
        hoveredAppID = nil
        hoveredQuitID = nil
        hoveredOpenID = nil
        hoveredChevronID = nil
    }

    private func memString(_ memMB: Double) -> String {
        memMB >= 1024 ? String(format: "%.1f GB", memMB / 1024) : String(format: "%.0f MB", memMB)
    }

    private func uptimeString(_ date: Date?) -> String {
        guard let date else { return "–" }
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func cpuColor(_ cpu: Double) -> Color {
        if cpu >= 200 { return Color.orange.opacity(0.9) }
        if cpu >= 100 { return Color.yellow.opacity(0.75) }
        return Color.white.opacity(0.55)
    }

    private func memColor(_ memMB: Double) -> Color {
        memMB >= 2048 ? Color.yellow.opacity(0.75) : Color.white.opacity(0.55)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            Text(value)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    private func chevronButton(_ app: AppEntry, rowHeight: CGFloat) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedID = expandedID == app.id ? nil : app.id
            }
        } label: {
            Image(systemName: expandedID == app.id ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredChevronID = hovering ? app.id : nil
            if hovering { hoveredAppID = app.id }
        }
        .background(
            Circle().fill(hoveredChevronID == app.id
                          ? Color.white.opacity(0.25)
                          : Color.white.opacity(0.15))
        )
        .opacity(expandedID == app.id ? 1 : (hoveredAppID == app.id ? 1 : 0))
        .allowsHitTesting(hoveredAppID == app.id)
        .help("Details")
    }

    private func detailPanel(_ app: AppEntry) -> some View {
        let u = app.pid.flatMap { store.usage[Int($0)] }
        let hist = app.pid.flatMap { store.history[Int($0)] } ?? []
        let bundle = app.url.flatMap { Bundle(url: $0) }
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let bid = bundle?.bundleIdentifier ?? app.id
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text("\(version ?? "–") · \(bid) · PID \(app.pid ?? 0)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                    Text(app.url?.path ?? "–")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expandedID = nil }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("CPU · last 60s")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Sparkline(samples: hist)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.03)))
            }
            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading)
            ], alignment: .leading, spacing: 12) {
                metric("CPU", String(format: "%.1f%%", u?.cpu ?? 0))
                metric("MEM", memString(u?.memMB ?? 0))
                metric("UPTIME", uptimeString(app.launchDate))
                metric("THREADS", "\(u?.info.pti_threadnum ?? 0)")
                metric("DISK R", memString(u?.diskReadMB ?? 0))
                metric("DISK W", memString(u?.diskWriteMB ?? 0))
                metric("NET IN", memString(u?.netInMB ?? 0))
                metric("NET OUT", memString(u?.netOutMB ?? 0))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }

    private func usageView(_ u: UsageSnapshot, rowHeight: CGFloat) -> some View {
        let size = min(max(rowHeight * 0.18, 10), 12)
        let iconSize = min(max(rowHeight * 0.16, 9), 10)
        return HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Text(String(format: "%.1f%%", u.cpu))
                    .font(.system(size: size, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(cpuColor(u.cpu))
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(spacing: 3) {
                Image(systemName: "memorychip")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Text(memString(u.memMB))
                    .font(.system(size: size, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(memColor(u.memMB))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .fixedSize()
    }

    private func quitButton(_ app: AppEntry, rowHeight: CGFloat) -> some View {
        Button {
            store.quitApp(app)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: min(max(rowHeight * 0.2, 10), 12), weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredQuitID = hovering ? app.id : nil
            if hovering { hoveredAppID = app.id }
        }
        .background(
            Circle().fill(hoveredQuitID == app.id
                          ? Color.red.opacity(0.8)
                          : Color.white.opacity(0.15))
        )
        .opacity(hoveredAppID == app.id ? 1 : 0)
        .allowsHitTesting(hoveredAppID == app.id)
        .help("Quit \(app.name)")
    }

    private func openButton(_ app: AppEntry, rowHeight: CGFloat) -> some View {
        Button {
            store.openApp(app)
            query = ""
        } label: {
            Image(systemName: "arrow.up.right")
                .font(.system(size: min(max(rowHeight * 0.2, 10), 12), weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredOpenID = hovering ? app.id : nil
            if hovering { hoveredAppID = app.id }
        }
        .background(
            Circle().fill(hoveredOpenID == app.id
                          ? Color.green.opacity(0.8)
                          : Color.white.opacity(0.15))
        )
        .opacity(hoveredAppID == app.id ? 1 : 0)
        .allowsHitTesting(hoveredAppID == app.id)
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
                SettingsLink {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.white.opacity(0.4))
                        .font(.system(size: 12, weight: .medium))
                }
                .help("Settings")
                // Align with the native traffic-light buttons (center ≈ 14pt)
                .offset(y: -6)
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
                                VStack(spacing: 0) {
                                    if !searching && expandedID == app.id {
                                        detailPanel(app)
                                    } else {
                                    HStack(spacing: 8) {
                                        HStack(spacing: 10) {
                                            if let icon = app.icon {
                                                Image(nsImage: icon)
                                                    .resizable()
                                                    .frame(width: min(max(rowHeight * 0.32, 20), 38),
                                                           height: min(max(rowHeight * 0.32, 20), 38))
                                            }
                                            Text(highlightedText(app.name, query: trimmedQuery))
                                                .font(.system(size: 15, weight: .regular))
                                                .lineLimit(1)
                                                .layoutPriority(1)
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture { rowTap(app) }
                                        if searching && runningIDs.contains(app.id) {
                                            Circle()
                                                .fill(Color.green.opacity(0.9))
                                                .frame(width: 6, height: 6)
                                        }
                                        Spacer()
                                        if !searching, let pid = app.pid, let u = store.usage[Int(pid)] {
                                            usageView(u, rowHeight: rowHeight)
                                        }
                                        if !searching {
                                            chevronButton(app, rowHeight: rowHeight)
                                        }
                                        if app.isRunning {
                                            quitButton(app, rowHeight: rowHeight)
                                        }
                                        if searching {
                                            openButton(app, rowHeight: rowHeight)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: rowHeight)
                                    .overlay(alignment: .top) {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.12))
                                            .frame(height: 1)
                                    }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(hoveredAppID == app.id ? Color.white.opacity(0.08) : Color.clear)
                                .onHover { hovering in
                                    hoveredAppID = hovering ? app.id : nil
                                }
                                .contextMenu {
                                    Button("Open \(app.name)") { store.openApp(app) }
                                    if app.isRunning {
                                        Button("Quit \(app.name)") { store.quitApp(app) }
                                    }
                                }
                                .overlay(alignment: .bottom) {
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
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification))
                .receive(on: DispatchQueue.main)
        ) { _ in
            clearHover()
        }
    }
}
