import SwiftUI
import AppKit
import Combine

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

struct UsageSnapshot {
    var cpu: Double = 0
    var memMB: Double = 0
    var info = ProcTaskInfo()
    var diskReadMB: Double = 0
    var diskWriteMB: Double = 0
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
    private static let usageQueue = DispatchQueue(label: "cubby.usage")
    private static var cpuSamples: [Int: (cpuNanos: UInt64, wall: Double)] = [:]

    @State private var runningApps: [AppEntry] = []
    @State private var installedApps: [AppEntry] = []
    @State private var hoveredAppID: String? = nil
    @State private var hoveredQuitID: String? = nil
    @State private var hoveredOpenID: String? = nil
    @State private var hoveredChevronID: String? = nil
    @State private var cancellables = Set<AnyCancellable>()
    @State private var query: String = ""
    @State private var usage: [Int: UsageSnapshot] = [:]
    @State private var history: [Int: [Double]] = [:]
    @State private var expandedID: String? = nil
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

    private func rowTap(_ app: AppEntry) {
        // Row click toggles the details panel. Clicking never switches
        // to another app's window.
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedID = expandedID == app.id ? nil : app.id
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

    private func fmtK(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.1fk", v / 1000) : String(format: "%.0f", v)
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

    private func panelButton(_ title: String, red: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(red ? Color.red.opacity(0.9) : Color.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(red ? Color.red.opacity(0.15) : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
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
        }
        .background(
            Circle().fill(hoveredChevronID == app.id
                          ? Color.white.opacity(0.25)
                          : Color.white.opacity(0.15))
        )
        .opacity(expandedID == app.id ? 1 : (hoveredAppID == app.id ? 1 : 0))
        .help("Details")
    }

    private func detailPanel(_ app: AppEntry) -> some View {
        let u = app.pid.flatMap { usage[Int($0)] }
        let hist = app.pid.flatMap { history[Int($0)] } ?? []
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
                    Text("\(version ?? "–") · \(bid)")
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
                metric("THREADS", "\(u?.info.pti_threadnum ?? 0)")
                metric("DISK R", memString(u?.diskReadMB ?? 0))
                metric("DISK W", memString(u?.diskWriteMB ?? 0))
                metric("PAGEINS", "\(u?.info.pti_pageins ?? 0)")
                metric("FAULTS", fmtK(Double(u?.info.pti_faults ?? 0)))
                metric("SYSCALLS", fmtK(Double(u?.info.pti_syscalls_mach ?? 0) + Double(u?.info.pti_syscalls_unix ?? 0)))
                metric("CTX SW", fmtK(Double(u?.info.pti_csw ?? 0)))
                metric("PID", "\(app.pid ?? 0)")
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

    private func refreshUsage() {
        let pids = runningApps.compactMap { $0.pid }
        Self.usageQueue.async {
            let now = ProcessInfo.processInfo.systemUptime
            var snapshot: [Int: UsageSnapshot] = [:]
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
                snapshot[Int(pid)] = snap
            }
            DispatchQueue.main.async {
                usage = snapshot
                var newHist = history
                for (pid, s) in snapshot {
                    var h = newHist[pid] ?? []
                    h.append(s.cpu)
                    if h.count > 60 { h.removeFirst(h.count - 60) }
                    newHist[pid] = h
                }
                newHist = newHist.filter { snapshot[$0.key] != nil }
                history = newHist
            }
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
                .font(.system(size: min(max(rowHeight * 0.2, 10), 12), weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 18)
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
                .font(.system(size: min(max(rowHeight * 0.2, 10), 12), weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 18)
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
                                        if !searching, let pid = app.pid, let u = usage[Int(pid)] {
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
                                .background(hoveredAppID == app.id ? Color.white.opacity(0.08) : Color.clear)
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
