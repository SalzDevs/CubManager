import Foundation
import AppKit
import Combine
import UserNotifications

// Single source of truth for app lists + live usage + CPU alerts.
// Consumed by the window UI, the menu bar item and the notch panel.
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var runningApps: [AppEntry] = []
    @Published var installedApps: [AppEntry] = []
    @Published var usage: [Int: UsageSnapshot] = [:]
    @Published var history: [Int: [Double]] = [:]
    @Published var alertRules: [AlertRule] = []
    @Published var liveAlertRuleIDs: Set<UUID> = []
    private var alertState: [UUID: (since: Date, fired: Bool)] = [:]

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
        loadAlertRules()
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

    // MARK: - CPU spike alerts

    private func loadAlertRules() {
        if let data = UserDefaults.standard.data(forKey: "alertRules"),
           let rules = try? JSONDecoder().decode([AlertRule].self, from: data) {
            alertRules = rules
        }
    }

    func saveAlertRules() {
        if let data = try? JSONEncoder().encode(alertRules) {
            UserDefaults.standard.set(data, forKey: "alertRules")
        }
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func addAlertRule() {
        alertRules.append(AlertRule(appID: "any", appName: "Any app", threshold: 80, durationSeconds: 30))
        saveAlertRules()
        Self.requestNotificationPermission()
    }

    func removeAlertRule(_ id: UUID) {
        alertRules.removeAll { $0.id == id }
        alertState[id] = nil
        liveAlertRuleIDs.remove(id)
        saveAlertRules()
    }

    /// State machine per rule: consecutive wall time above threshold fires once;
    /// dropping below re-arms. Called on the main thread after each usage tick.
    private func evaluateAlerts(_ snapshot: [Int: UsageSnapshot]) {
        guard !alertRules.isEmpty else {
            if !liveAlertRuleIDs.isEmpty { liveAlertRuleIDs = [] }
            return
        }
        var live = Set<UUID>()
        for rule in alertRules where rule.enabled {
            let cpu: Double
            if rule.appID == "any" {
                cpu = snapshot.values.map { $0.cpu }.max() ?? 0
            } else if let app = runningApps.first(where: { $0.id == rule.appID }),
                      let pid = app.pid,
                      let snap = snapshot[Int(pid)] {
                cpu = snap.cpu
            } else {
                cpu = 0   // app not running — below threshold, re-arms
            }
            var st = alertState[rule.id] ?? (since: Date(), fired: false)
            if cpu >= rule.threshold {
                if !st.fired && Date().timeIntervalSince(st.since) >= Double(rule.durationSeconds) {
                    st.fired = true
                    fireAlert(rule, cpu: cpu)
                }
                live.insert(rule.id)
            } else {
                st = (since: Date(), fired: false)
            }
            alertState[rule.id] = st
        }
        liveAlertRuleIDs = live
    }

    private func fireAlert(_ rule: AlertRule, cpu: Double) {
        let appName: String
        if rule.appID == "any",
           let hottest = runningApps.filter({ $0.pid != nil }).max(by: { cpuPct($0) < cpuPct($1) }) {
            appName = hottest.name
        } else {
            appName = rule.appName
        }
        let content = UNMutableNotificationContent()
        content.title = "CPU spike — \(appName)"
        content.body = "\(Int(cpu.rounded()))% CPU — over \(Int(rule.threshold))% for \(rule.durationSeconds)s"
        content.sound = .default
        let req = UNNotificationRequest(identifier: rule.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
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
            // Helper processes (Chromium/Electron renderers, network services)
            // are direct children of the app — their CPU/memory belongs to the
            // app's row, not to invisible helpers.
            let ppidMap = Self.allProcessParents()
            var childrenOf: [Int32: [Int32]] = [:]
            for (child, parent) in ppidMap where parent != 0 {
                childrenOf[parent, default: []].append(child)
            }
            var snapshot: [Int: UsageSnapshot] = [:]
            var sampledPids = Set<Int>()
            for pid in pids {
                let snap = self.sampleApp(pid: pid, children: childrenOf[pid] ?? [], now: now, sampledPids: &sampledPids)
                snapshot[Int(pid)] = snap
            }
            self.cpuSamples = self.cpuSamples.filter { sampledPids.contains($0.key) }
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
                self.evaluateAlerts(snapshot)
            }
        }
    }

    private func sampleApp(pid: pid_t, children: [Int32], now: Double, sampledPids: inout Set<Int>) -> UsageSnapshot {
        var appCpu = 0.0
        var memMB = 0.0
        var diskR = 0.0
        var diskW = 0.0
        var mainInfo = ProcTaskInfo()
        var samplePids = [pid]
        samplePids += children
        for p in samplePids { sampledPids.insert(Int(p)) }
        let mb = 1024.0 * 1024.0
        for samplePid in samplePids {
            var info = ProcTaskInfo()
            let sz = Int32(MemoryLayout<ProcTaskInfo>.size)
            guard proc_pidinfo(samplePid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { continue }
            let total = info.pti_total_user &+ info.pti_total_system
            var pidCpu = 0.0
            if let prev = cpuSamples[Int(samplePid)] {
                let dNanos = total >= prev.cpuNanos ? total - prev.cpuNanos : 0
                let dWall = now - prev.wall
                if dWall > 0 {
                    pidCpu = Double(dNanos) / (dWall * 1_000_000_000.0) * 100.0
                }
            }
            cpuSamples[Int(samplePid)] = (total, now)
            appCpu += pidCpu
            if samplePid == pid { mainInfo = info }
            var rusageBuf = [UInt8](repeating: 0, count: 512)
            if proc_pid_rusage(samplePid, RUSAGE_INFO_V2, &rusageBuf) == 0 {
                let memB = rusageBuf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 72, as: UInt64.self) }
                let readB = rusageBuf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 144, as: UInt64.self) }
                let writtenB = rusageBuf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 152, as: UInt64.self) }
                memMB += Double(memB) / mb
                diskR += Double(readB) / mb
                diskW += Double(writtenB) / mb
            }
        }
        var snap = UsageSnapshot()
        snap.cpu = appCpu
        snap.info = mainInfo
        snap.memMB = memMB
        snap.diskReadMB = diskR
        snap.diskWriteMB = diskW
        // Network: delta-sample nettop's cumulative counters into monotonic
        // lifetime totals; child helper pids count toward the app.
        let ppidMap = Self.allProcessParents()
        netLock.lock()
        let counters = netCounters
        var childIn: UInt64 = 0
        var childOut: UInt64 = 0
        for child in children {
            if let k = counters[Int(child)] {
                childIn &+= k.curIn
                childOut &+= k.curOut
            }
        }
        let mine = counters[Int(pid)] ?? (0, 0)
        let curIn = mine.curIn &+ childIn
        let curOut = mine.curOut &+ childOut
        var st = netState[Int(pid)] ?? (curIn, curOut, 0, 0)
        let dIn = curIn >= st.lastIn ? curIn &- st.lastIn : 0
        let dOut = curOut >= st.lastOut ? curOut &- st.lastOut : 0
        st = (curIn, curOut, st.totIn &+ dIn, st.totOut &+ dOut)
        netState[Int(pid)] = st
        netLock.unlock()
        snap.netInMB = Double(st.totIn) / 1_048_576.0
        snap.netOutMB = Double(st.totOut) / 1_048_576.0
        return snap
    }
}