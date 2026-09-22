// CubManager — standalone, single-source edition.
// Based on SalzDevs/CubManager, reviewed at commit 39ff2d4 (2026-09-22).
// All application code, views, process collection, analysis and self-tests are here.
// Requires macOS 14+, Xcode 15+; no packages or mandatory image assets.
// In the original project REPLACE Sources/*.swift with this file; do not add a
// second @main alongside the original files. The original app-bundle build script
// can still package it. An Info.plist / app bundle is required for notifications
// and login registration; signing/notarization remain release-build tasks.
// Compile on a Mac: swiftc -swift-version 5 -parse-as-library -O CubManager.swift -o CubManager
// Portable logic tests: swiftc -swift-version 5 -parse-as-library -D CUB_SELF_TEST CubManager.swift -o CubManagerTests
// Run that test executable to execute the embedded assertions. Never disables Gatekeeper.
//
// Intentionally local-only: 30-minute in-memory history, no telemetry, accounts,
// network uploads, automatic force-quitting or claims to diagnose memory leaks.

import Foundation

// MARK: - Portable domain and analysis (also used by embedded self-tests)

private let historySeconds: Double = 30 * 60
private let mib: Double = 1_048_576

struct AppInstanceID: Hashable, Sendable {
    let pid: Int32
    let launched: Date
}

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let started: UInt64
}

struct ActivitySample: Sendable {
    let time: Double                 // system uptime, never wall-clock duration math
    let date: Date                   // chart labels only
    let elapsed: Double
    let cpu: Double?                 // 100% = one logical CPU's worth of CPU time
    let memory: Double?              // summed physical footprints; bytes
    let background: Bool            // true only if background for the whole interval
    let members: Set<ProcessIdentity>
    let complete: Bool              // completeness of the identifiable process group
}

struct RingBuffer<Element: Sendable>: Sendable {
    private var storage: [Element?]
    private var next = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ value: Element) {
        storage[next] = value
        next = (next + 1) % storage.count
        count = min(count + 1, storage.count)
    }

    var values: [Element] {
        let start = count == storage.count ? next : 0
        return (0..<count).compactMap { storage[(start + $0) % storage.count] }
    }
}

enum SignalKind: String, Sendable, CaseIterable {
    case backgroundCPU, memoryGrowth
    var priority: Int { self == .backgroundCPU ? 2 : 1 }
}

struct AttentionSignal: Identifiable, Sendable {
    var id: SignalKind { kind }
    let kind: SignalKind
    let began: Date
    var explanation: String
    var magnitude: Double
    var recovering = false
    var recoverySince: Double?
}

struct AnalysisResult: Sendable {
    var cpuReady = false
    var memoryReady = false
    var averageCPU: Double?
    var memoryChange: Double?
    var signals: [AttentionSignal] = []
    var primary: AttentionSignal? {
        signals.sorted { $0.kind.priority > $1.kind.priority }.first
    }
}

struct Incident: Identifiable, Sendable {
    let id = UUID()
    let kind: SignalKind
    let began: Date
    var ended: Date?
    var explanation: String
}

enum Format {
    static func cpu(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "Unavailable"
    }
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        let absolute = abs(value)
        if absolute >= 1_073_741_824 { return String(format: "%.1f GiB", value / 1_073_741_824) }
        return String(format: "%.0f MiB", value / mib)
    }
    static func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600 ? "\(value / 3600)h \((value % 3600) / 60)m" : "\(value / 60)m"
    }
}

struct ActivityAnalyzer: Sendable {
    private var active: [SignalKind: AttentionSignal] = [:]

    // Windows are contiguous, sufficiently covered and fresh. Missing data is not zero.
    static func window(_ samples: [ActivitySample], seconds: Double, now: Double,
                       interval: Double) -> [ActivitySample]? {
        let start = now - seconds
        let selected = samples.filter { $0.time > start && $0.time <= now }
        guard let first = selected.first, let last = selected.last,
              now - last.time <= interval * 2.5,
              first.time - first.elapsed <= start + interval,
              selected.allSatisfy({ $0.complete && $0.elapsed > 0 && $0.elapsed <= interval * 2.5 })
        else { return nil }
        for (a, b) in zip(selected, selected.dropFirst()) {
            if b.time - a.time > interval * 2.5 { return nil }
        }
        let covered = selected.reduce(0.0) { total, sample in
            total + max(0, min(sample.elapsed, sample.time - start))
        }
        return covered >= seconds * 0.95 ? selected : nil
    }

    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    mutating func evaluate(_ samples: [ActivitySample], now: Double,
                           date: Date, interval: Double) -> AnalysisResult {
        var result = AnalysisResult()
        var candidates: [SignalKind: (String, Double)] = [:]
        var cpuCanRecover = false
        var memoryCanRecover = false

        if let window = Self.window(samples, seconds: 120, now: now, interval: interval),
           window.allSatisfy({ $0.cpu != nil }) {
            result.cpuReady = true
            let duration = window.reduce(0.0) { $0 + $1.elapsed }
            let average = window.reduce(0.0) { $0 + ($1.cpu ?? 0) * $1.elapsed } / duration
            let background = window.filter(\.background).reduce(0.0) { $0 + $1.elapsed } / duration
            result.averageCPU = average
            if average >= 100 && background >= 0.9 {
                candidates[.backgroundCPU] = ("CPU averaged \(Format.cpu(average)) over 2 min, mostly in background", average)
            }
            cpuCanRecover = average < 70 || background < 0.5
        }

        if let window = Self.window(samples, seconds: 600, now: now, interval: interval),
           let members = window.first?.members,
           window.allSatisfy({ $0.memory != nil && $0.members == members }) {
            // A changed helper group resets this particular baseline: opening a new
            // renderer must not masquerade as growth in an unchanged process group.
            let buckets = (0..<10).compactMap { index -> Double? in
                let from = now - 600 + Double(index) * 60
                return Self.median(window.filter { $0.time > from && $0.time <= from + 60 }.compactMap(\.memory))
            }
            if buckets.count == 10, let first = buckets.first, let last = buckets.last {
                result.memoryReady = true
                let growth = last - first
                result.memoryChange = growth
                let increasing = zip(buckets, buckets.dropFirst()).filter { $0.1 > $0.0 + mib }.count
                if growth >= 500 * mib && growth >= first * 0.25 && increasing >= 6 {
                    candidates[.memoryGrowth] = ("Memory increased \(Format.bytes(growth)) over 10 min", growth)
                }
                memoryCanRecover = growth < 250 * mib || increasing < 3
            }
        }

        for kind in SignalKind.allCases {
            let ready = kind == .backgroundCPU ? result.cpuReady : result.memoryReady
            guard ready else {
                active.removeValue(forKey: kind) // unknown is not a continuing diagnosis
                continue
            }
            if let candidate = candidates[kind] {
                var signal = active[kind] ?? AttentionSignal(kind: kind, began: date,
                    explanation: candidate.0, magnitude: candidate.1)
                signal.explanation = candidate.0
                signal.magnitude = candidate.1
                signal.recovering = false
                signal.recoverySince = nil
                active[kind] = signal
            } else if var signal = active[kind] {
                let canRecover = kind == .backgroundCPU ? cpuCanRecover : memoryCanRecover
                if canRecover {
                    signal.recoverySince = signal.recoverySince ?? now
                    signal.recovering = true
                    if now - (signal.recoverySince ?? now) >= 60 {
                        active.removeValue(forKey: kind)
                    } else { active[kind] = signal }
                } else {
                    signal.recoverySince = nil
                    signal.recovering = false
                    active[kind] = signal
                }
            }
        }
        result.signals = active.values.sorted { $0.kind.priority > $1.kind.priority }
        return result
    }
}

// Same keys as the original persisted rules. Custom rules remain optional and
// separate from conservative default attention signals.
struct AlertRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var appID = "any"
    var appName = "Any app"
    var threshold: Double = 100
    var durationSeconds = 120
    var enabled = true
}

struct RuleKey: Hashable, Sendable { let rule: UUID; let app: AppInstanceID }
struct RuleProgress: Sendable { var accumulated = 0.0; var fired = false }

struct RuleEvaluator: Sendable {
    private var progress: [RuleKey: RuleProgress] = [:]
    mutating func evaluate(rule: AlertRule, app: AppInstanceID, cpu: Double?, elapsed: Double) -> Bool {
        let key = RuleKey(rule: rule.id, app: app)
        guard rule.enabled, let cpu, cpu >= rule.threshold, elapsed > 0 else {
            progress.removeValue(forKey: key)
            return false
        }
        var value = progress[key] ?? RuleProgress()
        value.accumulated += elapsed
        let shouldFire = !value.fired && value.accumulated >= Double(rule.durationSeconds)
        value.fired = value.fired || shouldFire
        progress[key] = value
        return shouldFire
    }
    mutating func retain(apps: Set<AppInstanceID>, rules: Set<UUID>) {
        progress = progress.filter { apps.contains($0.key.app) && rules.contains($0.key.rule) }
    }
}

#if os(macOS) && !CUB_SELF_TEST
import SwiftUI
import AppKit
import Combine
import ServiceManagement
import UserNotifications
import Darwin

// MARK: - libproc ABI, localized to this file
// These fixed-layout mirrors match proc_taskinfo and rusage_info_v2 in the macOS
// SDK. Assertions guard their sizes. CPU is proc_taskinfo nanoseconds; do not
// confuse it with rusage time fields whose units can differ by architecture.
private struct TaskInfo {
    var virtualSize: UInt64 = 0; var residentSize: UInt64 = 0
    var user: UInt64 = 0; var system: UInt64 = 0
    var threadsUser: UInt64 = 0; var threadsSystem: UInt64 = 0
    var policy: Int32 = 0; var faults: Int32 = 0; var pageins: Int32 = 0
    var cowFaults: Int32 = 0; var messagesSent: Int32 = 0; var messagesReceived: Int32 = 0
    var machCalls: Int32 = 0; var unixCalls: Int32 = 0; var switches: Int32 = 0
    var threads: Int32 = 0; var running: Int32 = 0; var priority: Int32 = 0
}

private struct ResourceUsageV2 {
    var uuid0: UInt64 = 0; var uuid1: UInt64 = 0
    var user: UInt64 = 0; var system: UInt64 = 0
    var packageWakeups: UInt64 = 0; var interruptWakeups: UInt64 = 0
    var pageins: UInt64 = 0; var wired: UInt64 = 0; var resident: UInt64 = 0
    var footprint: UInt64 = 0; var start: UInt64 = 0; var exit: UInt64 = 0
    var childUser: UInt64 = 0; var childSystem: UInt64 = 0
    var childPackageWakeups: UInt64 = 0; var childInterruptWakeups: UInt64 = 0
    var childPageins: UInt64 = 0; var childElapsed: UInt64 = 0
    var diskRead: UInt64 = 0; var diskWritten: UInt64 = 0
}

@_silgen_name("proc_pidinfo")
private func cub_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64,
                         _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
@_silgen_name("proc_pid_rusage")
private func cub_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer?) -> Int32

struct AppDescriptor: Sendable {
    let id: AppInstanceID
    let name: String
    let bundleID: String
    let url: URL?
    let background: Bool
    let lastActivation: Double
}

struct ProcessMetric: Sendable {
    let id: ProcessIdentity
    let cpu: Double?
    let memory: Double
    let diskRead: Double
    let diskWritten: Double
    let threads: Int
}

struct AppReport: Sendable {
    let descriptor: AppDescriptor
    let sample: ActivitySample
    let analysis: AnalysisResult
    let history: [ActivitySample]
    let processes: [ProcessMetric]
    let expectedProcessCount: Int
    let incidents: [Incident]
    var diskRead: Double? { sample.complete ? processes.reduce(0) { $0 + $1.diskRead } : nil }
    var diskWritten: Double? { sample.complete ? processes.reduce(0) { $0 + $1.diskWritten } : nil }
}

struct Notice: Sendable { let app: AppInstanceID; let title: String; let body: String }
struct CollectionBatch: Sendable {
    let reports: [AppInstanceID: AppReport]
    let notices: [Notice]
    let treeAvailable: Bool
}

// MARK: - Background collection and analysis

actor ActivityCollector {
    private struct Counter { let identity: ProcessIdentity; let cpu: UInt64; let time: Double }
    private var counters: [Int32: Counter] = [:]
    private var histories: [AppInstanceID: RingBuffer<ActivitySample>] = [:]
    private var analyzers: [AppInstanceID: ActivityAnalyzer] = [:]
    private var incidents: [AppInstanceID: [Incident]] = [:]
    private var rules = RuleEvaluator()
    private var previousTime: Double?
    private var previousInterval: Double?
    private var lastRules: [AlertRule] = []

    private func processParents() -> [Int32: Int32]? {
        var mibValues: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        // The process list can grow between sizing and reading. Retry boundedly.
        for _ in 0..<3 {
            var bytes = 0
            guard sysctl(&mibValues, 4, nil, &bytes, nil, 0) == 0 else { return nil }
            let count = bytes / MemoryLayout<kinfo_proc>.stride + 128
            var entries = [kinfo_proc](repeating: kinfo_proc(), count: count)
            bytes = entries.count * MemoryLayout<kinfo_proc>.stride
            let status = entries.withUnsafeMutableBytes { buffer in
                sysctl(&mibValues, 4, buffer.baseAddress, &bytes, nil, 0)
            }
            if status == 0 {
                var parents: [Int32: Int32] = [:]
                for entry in entries.prefix(bytes / MemoryLayout<kinfo_proc>.stride) {
                    parents[entry.kp_proc.p_pid] = entry.kp_eproc.e_ppid
                }
                return parents
            }
            if errno != ENOMEM { return nil }
        }
        return nil
    }

    private func readProcess(_ pid: Int32, time: Double, interval: Double) -> ProcessMetric? {
        precondition(MemoryLayout<TaskInfo>.size == 96)
        precondition(MemoryLayout<ResourceUsageV2>.size == 160)
        var before = ResourceUsageV2()
        var after = ResourceUsageV2()
        var task = TaskInfo()
        guard cub_rusage(pid, 2, &before) == 0,
              cub_pidinfo(pid, 4, 0, &task, Int32(MemoryLayout<TaskInfo>.size)) == 96,
              cub_rusage(pid, 2, &after) == 0, before.start == after.start else { return nil }
        let identity = ProcessIdentity(pid: pid, started: after.start)
        let total = task.user &+ task.system
        var cpu: Double?
        if let previous = counters[pid], previous.identity == identity,
           time > previous.time, time - previous.time <= interval * 2.5, total >= previous.cpu {
            cpu = Double(total - previous.cpu) / ((time - previous.time) * 1_000_000_000) * 100
        }
        counters[pid] = Counter(identity: identity, cpu: total, time: time)
        return ProcessMetric(id: identity, cpu: cpu, memory: Double(after.footprint),
            diskRead: Double(after.diskRead), diskWritten: Double(after.diskWritten), threads: Int(task.threads))
    }

    func collect(apps: [AppDescriptor], interval: Double, alertRules: [AlertRule], reset: Bool) -> CollectionBatch {
        let now = ProcessInfo.processInfo.systemUptime
        let date = Date()
        let elapsed = previousTime.map { now - $0 } ?? 0
        let gap = reset || previousInterval != interval || elapsed > interval * 2.5
        if gap {
            counters.removeAll()
            analyzers.removeAll()
            rules = RuleEvaluator()
        }
        if lastRules != alertRules { rules = RuleEvaluator(); lastRules = alertRules }
        previousTime = now
        previousInterval = interval
        let parents = processParents()
        var children: [Int32: [Int32]] = [:]
        for (child, parent) in parents ?? [:] where child != parent { children[parent, default: []].append(child) }
        let roots = Set(apps.map { $0.id.pid })
        var visited = Set<Int32>()
        var reports: [AppInstanceID: AppReport] = [:]
        var notices: [Notice] = []
        let alive = Set(apps.map(\.id))
        histories = histories.filter { alive.contains($0.key) }
        analyzers = analyzers.filter { alive.contains($0.key) }
        incidents = incidents.filter { alive.contains($0.key) }
        rules.retain(apps: alive, rules: Set(alertRules.map(\.id)))

        for app in apps {
            var stack = [app.id.pid]
            var group = Set<Int32>()
            while let pid = stack.popLast() {
                guard !group.contains(pid), pid == app.id.pid || !roots.contains(pid) else { continue }
                group.insert(pid)
                stack.append(contentsOf: children[pid] ?? [])
            }
            var metrics: [ProcessMetric] = []
            for pid in group.sorted() where !visited.contains(pid) {
                visited.insert(pid)
                if let metric = readProcess(pid, time: now, interval: interval) { metrics.append(metric) }
            }
            let complete = parents != nil && metrics.count == group.count
            let cpuKnown = complete && !gap && elapsed > 0 && metrics.allSatisfy { $0.cpu != nil }
            let sample = ActivitySample(time: now, date: date, elapsed: gap ? 0 : elapsed,
                cpu: cpuKnown ? metrics.reduce(0) { $0 + ($1.cpu ?? 0) } : nil,
                memory: complete ? metrics.reduce(0) { $0 + $1.memory } : nil,
                background: app.background && app.lastActivation < now - elapsed,
                members: Set(metrics.map(\.id)), complete: complete)
            var history = histories[app.id] ?? RingBuffer(capacity: 1801)
            history.append(sample)
            histories[app.id] = history
            let samples = history.values.filter { now - $0.time <= historySeconds }
            var analyzer = analyzers[app.id] ?? ActivityAnalyzer()
            let analysis = analyzer.evaluate(samples, now: now, date: date, interval: interval)
            analyzers[app.id] = analyzer
            var events = incidents[app.id] ?? []
            for index in events.indices where events[index].ended == nil {
                if let signal = analysis.signals.first(where: { $0.kind == events[index].kind }) {
                    events[index].explanation = signal.explanation
                } else { events[index].ended = date }
            }
            for signal in analysis.signals where !events.contains(where: { $0.kind == signal.kind && $0.ended == nil }) {
                events.append(Incident(kind: signal.kind, began: date, explanation: signal.explanation))
                notices.append(Notice(app: app.id, title: "\(app.name): activity worth reviewing", body: signal.explanation))
            }
            events = Array(events.filter { date.timeIntervalSince($0.ended ?? date) <= historySeconds }.suffix(50))
            incidents[app.id] = events
            for rule in alertRules where rule.appID == "any" || rule.appID == app.bundleID {
                if rules.evaluate(rule: rule, app: app.id, cpu: sample.cpu, elapsed: sample.elapsed) {
                    notices.append(Notice(app: app.id, title: "\(app.name): CPU rule matched",
                        body: "At least \(Int(rule.threshold))% CPU for \(rule.durationSeconds) seconds. This may be expected work."))
                }
            }
            reports[app.id] = AppReport(descriptor: app, sample: sample, analysis: analysis,
                history: samples, processes: metrics, expectedProcessCount: group.count, incidents: events)
        }
        counters = counters.filter { visited.contains($0.key) }
        return CollectionBatch(reports: reports, notices: notices, treeAvailable: parents != nil)
    }
}

// MARK: - On-demand network measurement; no persistent helper

struct NetworkReading: Sendable { let incoming: Double; let outgoing: Double; let date: Date }
enum NetworkProbeError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Network counters were unavailable. The app may have no active sockets, or macOS may restrict access." }
}

enum NetworkProbe {
    // nettop is invoked directly, not through script/a shell. -L 1 exits after
    // one snapshot, so pipe buffering does not require a long-lived PTY process.
    static func measure(pids: Set<Int32>) async throws -> NetworkReading {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            process.arguments = ["-L", "1", "-x", "-P", "-n", "-J", "bytes_in,bytes_out"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0 else { throw NetworkProbeError.unavailable }
            let text = String(decoding: data, as: UTF8.self)
            var inIndex: Int?
            var outIndex: Int?
            var matched = Set<Int32>()
            var incoming = 0.0
            var outgoing = 0.0
            for line in text.split(whereSeparator: \.isNewline) {
                let columns = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let i = columns.firstIndex(of: "bytes_in"), let o = columns.firstIndex(of: "bytes_out") {
                    inIndex = i; outIndex = o; continue
                }
                guard let i = inIndex, let o = outIndex, columns.count > max(i, o),
                      let processColumn = columns.prefix(min(i, o)).first(where: { value in
                          guard let suffix = value.split(separator: ".").last, let pid = Int32(suffix) else { return false }
                          return pids.contains(pid)
                      }), let suffix = processColumn.split(separator: ".").last, let pid = Int32(suffix),
                      !matched.contains(pid), let bytesIn = Double(columns[i]), let bytesOut = Double(columns[o]) else { continue }
                matched.insert(pid); incoming += bytesIn; outgoing += bytesOut
            }
            guard !matched.isEmpty else { throw NetworkProbeError.unavailable }
            return NetworkReading(incoming: incoming, outgoing: outgoing, date: Date())
        }.value
    }
}

// MARK: - Main-actor presentation and safe actions

enum SortOrder: String, CaseIterable, Identifiable {
    case recommended = "Recommended", cpu = "CPU usage", memory = "Memory usage", name = "Name"
    var id: String { rawValue }
}

struct InstalledApp: Identifiable, Sendable {
    var id: String { url.path }
    let name: String
    let bundleID: String
    let url: URL
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    @Published private(set) var reports: [AppInstanceID: AppReport] = [:]
    @Published private(set) var order: [AppInstanceID] = []
    @Published private(set) var attentionSection = Set<AppInstanceID>()
    @Published private(set) var installed: [InstalledApp] = []
    @Published var selected: AppInstanceID?
    @Published var sort: SortOrder = .recommended { didSet { reorder(force: true) } }
    @Published var actionMessages: [AppInstanceID: String] = [:]
    @Published var pendingQuit = Set<AppInstanceID>()
    @Published var banner: String?
    @Published var alertRules: [AlertRule] = [] { didSet { saveRules() } }
    @Published private(set) var treeAvailable = true
    @Published private(set) var sleeping = false
    @Published private(set) var lastCollection: Date?
    @Published private(set) var clock = Date()
    @Published private(set) var scanning = false
    private let collector = ActivityCollector()
    private var timer: Timer?
    private var inFlight = false
    private var needsReset = true
    private var generation = 0
    private var lastTick = -Double.infinity
    private var lastOrder = -Double.infinity
    private var lastInventory = Date.distantPast
    private var lastActivation: [Int32: Double] = [:]
    private var archivedSelection: AppReport?
    private var notificationCooldown: [AppInstanceID: Date] = [:]
    private var cancellables = Set<AnyCancellable>()
    var pointerInList = false { didSet { if !pointerInList { reorder(force: true) } } }
    var listHasFocus = false { didSet { if !listHasFocus { reorder(force: true) } } }
    var displayedReports: [AppReport] { order.compactMap { reports[$0] } }
    var attentionCount: Int { reports.values.filter { !$0.analysis.signals.isEmpty }.count }
    var inspected: AppReport? { selected.flatMap { reports[$0] ?? (archivedSelection?.descriptor.id == $0 ? archivedSelection : nil) } }
    var interval: Double {
        let stored = UserDefaults.standard.double(forKey: "refreshInterval")
        return [1.0, 2.0, 5.0].contains(stored) ? stored : 2
    }
    var notificationsEnabled: Bool { UserDefaults.standard.bool(forKey: "notificationsEnabled") }
    var monitoringStale: Bool {
        sleeping || lastCollection.map { clock.timeIntervalSince($0) > max(10, interval * 3) } == true
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "alertRules"),
           let decoded = try? JSONDecoder().decode([AlertRule].self, from: data) { alertRules = decoded }
    }

    func start() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] event in
                guard let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.lastActivation[app.processIdentifier] = ProcessInfo.processInfo.systemUptime
            }.store(in: &cancellables)
        center.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.sleeping = true; self?.generation += 1; self?.needsReset = true
            }.store(in: &cancellables)
        center.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.sleeping = false; self?.needsReset = true; self?.lastTick = -Double.infinity
            }.store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        refreshInstalled()
        tick()
    }

    private func tick() {
        clock = Date()
        let now = ProcessInfo.processInfo.systemUptime
        guard !sleeping, !inFlight, now - lastTick >= interval else { return }
        lastTick = now
        let descriptors = NSWorkspace.shared.runningApplications.compactMap { app -> AppDescriptor? in
            guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let launched = app.launchDate, !app.isTerminated else { return nil }
            return AppDescriptor(id: AppInstanceID(pid: app.processIdentifier, launched: launched),
                name: app.localizedName ?? "Unknown app", bundleID: app.bundleIdentifier ?? "", url: app.bundleURL,
                background: !app.isActive, lastActivation: lastActivation[app.processIdentifier] ?? now)
        }
        for app in descriptors where lastActivation[app.id.pid] == nil { lastActivation[app.id.pid] = now }
        let alivePIDs = Set(descriptors.map { $0.id.pid })
        lastActivation = lastActivation.filter { alivePIDs.contains($0.key) }
        inFlight = true
        let reset = needsReset
        needsReset = false
        let currentGeneration = generation
        let currentRules = alertRules
        let currentInterval = interval
        Task {
            let batch = await collector.collect(apps: descriptors, interval: currentInterval, alertRules: currentRules, reset: reset)
            inFlight = false
            guard currentGeneration == generation, !sleeping else { return }
            if let selected, let old = reports[selected] { archivedSelection = old }
            reports = batch.reports
            treeAvailable = batch.treeAvailable
            lastCollection = Date()
            let alive = Set(reports.keys)
            actionMessages = actionMessages.filter { alive.contains($0.key) || $0.key == selected }
            pendingQuit.formIntersection(alive)
            notificationCooldown = notificationCooldown.filter { alive.contains($0.key) }
            reorder()
            for notice in batch.notices { sendNotification(notice) }
        }
    }

    private func reorder(force: Bool = false) {
        guard !pointerInList, !listHasFocus, pendingQuit.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastOrder >= 15 || order.isEmpty else { return }
        lastOrder = now
        attentionSection = Set(reports.values.filter { !$0.analysis.signals.isEmpty }.map { $0.descriptor.id })
        order = reports.keys.sorted { lhs, rhs in
            guard let a = reports[lhs], let b = reports[rhs] else { return lhs.pid < rhs.pid }
            switch sort {
            case .recommended:
                let ap = a.analysis.primary?.kind.priority ?? 0, bp = b.analysis.primary?.kind.priority ?? 0
                if ap != bp { return ap > bp }
                if ap > 0 {
                    let av = a.analysis.primary?.magnitude ?? 0, bv = b.analysis.primary?.magnitude ?? 0
                    if av != bv { return av > bv }
                }
            case .cpu:
                if a.sample.cpu != b.sample.cpu { return (a.sample.cpu ?? -1) > (b.sample.cpu ?? -1) }
            case .memory:
                if a.sample.memory != b.sample.memory { return (a.sample.memory ?? -1) > (b.sample.memory ?? -1) }
            case .name: break
            }
            let comparison = a.descriptor.name.localizedStandardCompare(b.descriptor.name)
            return comparison == .orderedSame ? lhs.pid < rhs.pid : comparison == .orderedAscending
        }
    }

    var statusTitle: String {
        if sleeping { return "Monitoring paused for sleep" }
        if monitoringStale { return "Monitoring interrupted" }
        if lastCollection == nil { return "Gathering activity…" }
        if !treeAvailable { return "Some activity is unavailable" }
        if reports.isEmpty { return "No supported running apps" }
        if attentionCount > 0 { return "\(attentionCount) \(attentionCount == 1 ? "app" : "apps") worth reviewing" }
        if reports.values.contains(where: { !$0.sample.complete || $0.sample.cpu == nil }) { return "Some activity is unavailable" }
        if reports.values.contains(where: { !$0.analysis.cpuReady }) { return "Gathering recent activity…" }
        return "Nothing needs your attention"
    }

    var statusDetail: String {
        if sleeping || monitoringStale { return "Recent values may be stale. Analysis restarts when fresh samples arrive." }
        if !treeAvailable { return "The process list could not be read. Missing measurements are not zero." }
        if reports.isEmpty { return "Monitoring covers supported running apps, not every macOS process." }
        if attentionCount > 0 { return "Sustained activity is worth reviewing, but may be expected work." }
        let memoryReady = reports.values.filter { $0.analysis.memoryReady }.count
        return "No active CPU or memory-growth signals. Memory trends ready for \(memoryReady) of \(reports.count) apps; other baselines need history or stable helper groups."
    }

    func inspect(_ id: AppInstanceID) {
        selected = id
        archivedSelection = reports[id]
        AppWindows.shared.showMain()
    }

    func runningInstance(_ id: AppInstanceID) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: id.pid), !app.isTerminated,
              app.launchDate == id.launched else { return nil }
        return app
    }

    func open(_ id: AppInstanceID) {
        guard let app = runningInstance(id) else { actionMessages[id] = "This app instance has closed."; return }
        if !app.activate(options: [.activateAllWindows]) { actionMessages[id] = "No app window could be brought forward." }
    }

    func quit(_ id: AppInstanceID, force: Bool = false) {
        guard let app = runningInstance(id) else { actionMessages[id] = "This app instance has closed."; return }
        let accepted = force ? app.forceTerminate() : app.terminate()
        actionMessages[id] = accepted ? "Quit requested. The app may ask you to save changes." : "The app did not accept the quit request. Open it to check for a save prompt."
        guard accepted else { return }
        pendingQuit.insert(id)
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            pendingQuit.remove(id)
            if runningInstance(id) != nil {
                actionMessages[id] = "The app is still running. It may be waiting for you to save changes."
            } else { actionMessages[id] = "App closed." }
            reorder(force: true)
        }
    }

    func refreshInstalled() {
        guard !scanning else { return }
        scanning = true
        lastInventory = Date()
        Task {
            let apps = await Task.detached(priority: .utility) { () -> [InstalledApp] in
                let fm = FileManager.default
                let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
                var found: [URL: InstalledApp] = [:]
                for root in roots {
                    guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root),
                        includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                    for case let url as URL in enumerator where url.pathExtension == "app" {
                        enumerator.skipDescendants()
                        let bundle = Bundle(url: url)
                        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                            ?? url.deletingPathExtension().lastPathComponent
                        found[url] = InstalledApp(name: name, bundleID: bundle?.bundleIdentifier ?? "", url: url)
                    }
                }
                return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }.value
            installed = apps; scanning = false
        }
    }

    func refreshInventoryIfNeeded() { if Date().timeIntervalSince(lastInventory) > 60 { refreshInstalled() } }
    func launch(_ app: InstalledApp) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in self.banner = "Could not open \(app.name): \(error.localizedDescription)" } }
        }
    }
    private func saveRules() {
        if let data = try? JSONEncoder().encode(alertRules) { UserDefaults.standard.set(data, forKey: "alertRules") }
    }

    func requestNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { banner = "Notifications require a packaged app bundle."; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                if !granted {
                    UserDefaults.standard.set(false, forKey: "notificationsEnabled")
                    self.banner = error?.localizedDescription ?? "Notifications are disabled in macOS. In-app attention signals remain available."
                }
            }
        }
    }
    private func sendNotification(_ notice: Notice) {
        guard notificationsEnabled, Bundle.main.bundleIdentifier != nil,
              notificationCooldown[notice.app].map({ Date().timeIntervalSince($0) >= 600 }) ?? true else { return }
        notificationCooldown[notice.app] = Date()
        let content = UNMutableNotificationContent()
        content.title = notice.title; content.body = notice.body
        content.userInfo = ["pid": Int(notice.app.pid), "launched": notice.app.launched.timeIntervalSince1970]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { Task { @MainActor in self.banner = "Notification could not be delivered: \(error.localizedDescription)" } }
        }
    }
}

// MARK: - Shared UI components

private let coverageExplanation = "CubManager monitors regular running apps and identifiable descendants. Some background services, reparented helpers and Apple XPC services cannot be attributed. Summed process footprints are approximate. Missing data is never treated as zero. This does not detect every cause of a slow Mac."
private let cpuExplanation = "100% means approximately one logical CPU’s worth of processing time. Apps using multiple cores can exceed 100%. High usage may be expected while compiling, exporting or processing. This is not a battery-use percentage."

struct AppIcon: View {
    let url: URL?
    var size: CGFloat = 32
    var body: some View {
        Group {
            if let url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable() }
            else { Image(systemName: "app.fill").resizable().foregroundStyle(.secondary) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct InfoButton: View {
    let label: String
    let text: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(label)
            .popover(isPresented: $showing) {
                Text(text).font(.callout).padding(18).frame(width: 310).fixedSize(horizontal: false, vertical: true)
            }
    }
}

struct Metric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).weight(.medium)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
}

struct AppActions: View {
    @ObservedObject var store: UsageStore
    let id: AppInstanceID
    var showInspect = true
    var body: some View {
        HStack(spacing: 12) {
            if showInspect {
                Button("Inspect") { store.inspect(id) }.buttonStyle(.bordered)
            }
            Button("Open app") { store.open(id) }.buttonStyle(.borderless)
            Spacer(minLength: 4)
            Button(store.pendingQuit.contains(id) ? "Quit requested…" : "Quit normally") { store.quit(id) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .disabled(store.pendingQuit.contains(id) || store.reports[id] == nil)
        }.font(.callout)
    }
}

struct AppRow: View {
    @ObservedObject var store: UsageStore
    let report: AppReport
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppIcon(url: report.descriptor.url)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.descriptor.name).font(.headline).lineLimit(1)
                    Text(report.descriptor.background ? "Background" : "Foreground").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(Format.cpu(report.sample.cpu)) CPU").monospacedDigit()
                    Text(Format.bytes(report.sample.memory)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let signal = report.analysis.primary {
                Label(signal.recovering ? "Activity settling · \(signal.explanation)" : signal.explanation,
                      systemImage: signal.recovering ? "arrow.down.right" : "waveform.path")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if !report.sample.complete {
                Label("Some process measurements are unavailable", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            AppActions(store: store, id: report.descriptor.id)
            if let message = store.actionMessages[report.descriptor.id] {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
    }
}

struct ContentView: View {
    @ObservedObject var store: UsageStore
    @State private var query = ""
    @FocusState private var focusedApp: AppInstanceID?
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            if let report = store.inspected {
                InspectView(store: store, report: report).id(report.descriptor.id)
            } else {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if search.isEmpty { runningList } else { searchResults }
                    }.padding(16)
                }
                .onHover { store.pointerInList = $0 }
                .onChange(of: focusedApp) { _, value in store.listHasFocus = value != nil }
                .onDisappear { store.pointerInList = false; store.listHasFocus = false }
            }
            if let banner = store.banner {
                Divider()
                HStack {
                    Text(banner).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { store.banner = nil }
                }.padding(12).background(Color.orange.opacity(0.08))
            }
        }
        .frame(minWidth: 440, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.teal)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CubManager").font(.title2.bold())
                    Text("Understand your apps. Stay in control.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { AppWindows.shared.showSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Settings").accessibilityLabel("Settings")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search running and installed apps", text: $query).textFieldStyle(.plain)
                    .onChange(of: query) { _, value in if !value.isEmpty { store.refreshInventoryIfNeeded() } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }.padding(16)
    }

    private var runningList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: store.attentionCount > 0 ? "waveform.path" : "circle.dotted")
                    .foregroundStyle(store.attentionCount > 0 ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.statusTitle).font(.headline)
                    Text(store.statusDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Monitoring \(store.reports.count) apps · Local history up to 30 min")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                InfoButton(label: "What is monitored?", text: coverageExplanation)
            }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.teal.opacity(0.06)))
            HStack {
                Picker("Sort", selection: $store.sort) { ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 160)
                Spacer()
                Text("CPU").font(.caption).foregroundStyle(.secondary)
                InfoButton(label: "How CPU percentages work", text: cpuExplanation)
            }
            if store.sort == .recommended {
                appSection("Needs attention", apps: store.displayedReports.filter { store.attentionSection.contains($0.descriptor.id) })
                appSection("Other running apps", apps: store.displayedReports.filter { !store.attentionSection.contains($0.descriptor.id) })
            } else { appSection("Running apps", apps: store.displayedReports) }
        }
    }

    @ViewBuilder private func appSection(_ title: String, apps: [AppReport]) -> some View {
        if !apps.isEmpty {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(apps, id: \.descriptor.id) { report in
                AppRow(store: store, report: report)
                    .focusable().focused($focusedApp, equals: report.descriptor.id)
                    .onKeyPress(.return) { store.inspect(report.descriptor.id); return .handled }
            }
        }
    }

    private var searchResults: some View {
        let running = store.reports.values.filter { matches($0.descriptor.name, $0.descriptor.bundleID) }
            .sorted { $0.descriptor.name.localizedStandardCompare($1.descriptor.name) == .orderedAscending }
        let runningURLs = Set(store.reports.values.compactMap { $0.descriptor.url })
        let installed = store.installed.filter { !runningURLs.contains($0.url) && matches($0.name, $0.bundleID) }
        return VStack(alignment: .leading, spacing: 12) {
            appSection("Running apps", apps: running)
            if !installed.isEmpty {
                Text("INSTALLED APPS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(installed) { app in
                    HStack {
                        AppIcon(url: app.url)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Button("Launch") { store.launch(app) }
                    }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            if store.scanning { ProgressView("Finding installed apps…").controlSize(.small) }
            if running.isEmpty && installed.isEmpty && !store.scanning { Text("No matching apps").foregroundStyle(.secondary) }
        }
    }
    private func matches(_ name: String, _ bundle: String) -> Bool {
        name.localizedStandardContains(search) || bundle.localizedStandardContains(search)
    }
}

// MARK: - Timestamped charts and inspection

struct HistoryChart: View {
    let samples: [ActivitySample]
    let seconds: Double
    let memory: Bool
    let interval: Double
    private var points: [ActivitySample] {
        guard let last = samples.last else { return [] }
        return samples.filter { $0.time >= last.time - seconds }
    }
    private func value(_ sample: ActivitySample) -> Double? { memory ? sample.memory : sample.cpu }
    var body: some View {
        let values = points.compactMap { value($0) }
        let maximum = max(memory ? mib : 100, values.max() ?? 0) * 1.1
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(memory ? "Memory" : "CPU").font(.subheadline.weight(.medium))
                Spacer()
                Text(memory ? Format.bytes(values.max()) : Format.cpu(values.max())).font(.caption).foregroundStyle(.secondary)
                Text("peak").font(.caption).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                guard let end = points.last?.time else { return }
                var path = Path()
                var previous: Double?
                for point in points {
                    guard let measurement = value(point) else { previous = nil; continue }
                    let x = (point.time - (end - seconds)) / seconds * size.width
                    let y = size.height - measurement / maximum * size.height
                    let position = CGPoint(x: x, y: y)
                    if let previous, point.time - previous <= interval * 2.5, point.elapsed > 0 { path.addLine(to: position) }
                    else { path.move(to: position) }
                    previous = point.time
                }
                context.stroke(path, with: .color(memory ? .blue : .teal), lineWidth: 2)
            }
            .frame(height: 90).padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
            .accessibilityLabel("\(memory ? "Memory" : "CPU") history. Peak \(memory ? Format.bytes(values.max()) : Format.cpu(values.max())). Gaps represent unavailable samples.")
            HStack {
                Text("−\(Int(seconds / 60)) min")
                Spacer()
                if let last = points.last { Text(last.date, style: .time) }
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct InspectView: View {
    @ObservedObject var store: UsageStore
    let report: AppReport
    @State private var seconds = 300.0
    @State private var showTechnical = false
    @State private var confirmForce = false
    @State private var network: NetworkReading?
    @State private var networkError: String?
    @State private var measuringNetwork = false
    private var id: AppInstanceID { report.descriptor.id }
    private var closed: Bool { store.reports[id] == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { store.selected = nil } label: { Label("All apps", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                HStack(spacing: 12) {
                    AppIcon(url: report.descriptor.url, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.descriptor.name).font(.title2.bold())
                        Text(closed ? "App closed · Last recorded activity" : (report.descriptor.background ? "In background" : "In foreground"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !closed { AppActions(store: store, id: id, showInspect: false) }
                if let message = store.actionMessages[id] { Text(message).font(.callout).foregroundStyle(.secondary) }
                observation
                HStack(alignment: .top, spacing: 24) {
                    Metric(title: "CPU", value: Format.cpu(report.sample.cpu))
                    InfoButton(label: "How CPU percentages work", text: cpuExplanation)
                    Metric(title: "Memory footprint", value: Format.bytes(report.sample.memory))
                    Spacer(minLength: 0)
                }
                Picker("History", selection: $seconds) {
                    Text("5 minutes").tag(300.0); Text("30 minutes").tag(1800.0)
                }.pickerStyle(.segmented)
                HistoryChart(samples: report.history, seconds: seconds, memory: false, interval: store.interval)
                HistoryChart(samples: report.history, seconds: seconds, memory: true, interval: store.interval)
                Text("History is local and in memory. Gaps are not zero usage. Memory trends reset when the helper group changes.")
                    .font(.caption).foregroundStyle(.secondary)
                if !report.incidents.isEmpty { incidentList }
                DisclosureGroup("Technical details", isExpanded: $showTechnical) { technical.padding(.top, 12) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Measurement coverage").font(.subheadline.weight(.medium))
                    Text("Read \(report.processes.count) of \(report.expectedProcessCount) identifiable processes in the latest sample.")
                    Text(coverageExplanation)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
        .confirmationDialog("Force quit \(report.descriptor.name)?", isPresented: $confirmForce, titleVisibility: .visible) {
            Button("Force quit", role: .destructive) { store.quit(id, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Unsaved work may be lost. CubManager will not force quit automatically.") }
    }

    private var observation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What was observed").font(.headline)
            if store.monitoringStale && !closed {
                Text("Monitoring is interrupted. These are the last recorded values.")
            } else if !report.sample.complete {
                Text("Some process measurements are unavailable; no complete app total can be shown.")
            } else if report.analysis.signals.isEmpty {
                Text(report.analysis.cpuReady ? "No sustained background CPU signal in the evaluated window." : "Gathering two minutes of valid CPU history.")
            }
            ForEach(report.analysis.signals) { signal in
                Label(signal.recovering ? "Activity settling. \(signal.explanation)" : signal.explanation, systemImage: "waveform.path")
                    .foregroundStyle(.orange)
            }
            if let average = report.analysis.averageCPU { Text("2-minute CPU average: \(Format.cpu(average))") }
            if let growth = report.analysis.memoryChange { Text("10-minute memory change: \(growth >= 0 ? "+" : "")\(Format.bytes(growth))") }
            else { Text("Memory trend needs ten minutes of valid history with a stable helper group.") }
            Text("Background work and memory growth may be expected. These measurements do not diagnose a fault or a memory leak.")
                .font(.caption).foregroundStyle(.secondary)
        }.font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.teal.opacity(0.06)))
    }

    private var incidentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent observations").font(.headline)
            ForEach(report.incidents.reversed()) { incident in
                VStack(alignment: .leading, spacing: 4) {
                    Text(incident.explanation).font(.callout)
                    HStack {
                        Text(incident.began, style: .time)
                        Text(incident.ended == nil && !closed ? "· Active" : "· Ended or evaluation interrupted")
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var technical: some View {
        VStack(alignment: .leading, spacing: 12) {
            detail("Bundle ID", report.descriptor.bundleID.isEmpty ? "Unavailable" : report.descriptor.bundleID)
            detail("PID", String(id.pid))
            detail("Version", report.descriptor.url.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "Unavailable")
            detail("Path", report.descriptor.url?.path ?? "Unavailable")
            detail("Uptime at last sample", Format.duration(report.sample.date.timeIntervalSince(id.launched)))
            detail("Threads in measured processes", String(report.processes.reduce(0) { $0 + $1.threads }))
            detail("Disk read · current processes, since their starts", Format.bytes(report.diskRead))
            detail("Disk written · current processes, since their starts", Format.bytes(report.diskWritten))
            Text("Disk counters can decrease when helpers exit; they are not lifetime app totals.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button(measuringNetwork ? "Measuring network…" : "Measure network counters") { measureNetwork() }
                .disabled(measuringNetwork || closed)
            Text("On demand only. Reports counters for current sockets/processes returned by nettop—not a transfer rate or lifetime app total. No network history is collected.")
                .font(.caption).foregroundStyle(.secondary)
            if let network {
                detail("Received in available counters", Format.bytes(network.incoming))
                detail("Sent in available counters", Format.bytes(network.outgoing))
                Text(network.date, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            if let networkError { Text(networkError).font(.caption).foregroundStyle(.secondary) }
            Divider()
            ForEach(report.processes, id: \.id) { process in
                Text("PID \(process.id.pid) · \(Format.cpu(process.cpu)) CPU · \(Format.bytes(process.memory))")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            if !closed {
                Divider()
                Button("Force quit…", role: .destructive) { confirmForce = true }
            }
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
    private func measureNetwork() {
        guard store.runningInstance(id) != nil else { networkError = "This app instance has closed."; return }
        measuringNetwork = true; networkError = nil
        let pids = Set(report.processes.map { $0.id.pid })
        Task {
            defer { measuringNetwork = false }
            do {
                let reading = try await NetworkProbe.measure(pids: pids)
                guard store.runningInstance(id) != nil else { networkError = "The app closed during measurement."; return }
                network = reading
            } catch { networkError = error.localizedDescription }
        }
    }
}

// MARK: - Settings, including backward-compatible custom alert rules

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("menubarEnabled") private var menubarEnabled = true
    @AppStorage("dockIconVisible") private var dockIconVisible = true
    @AppStorage("notchEnabled") private var notchEnabled = false
    @AppStorage("hideInFullscreen") private var hideInFullscreen = true
    @AppStorage("refreshInterval") private var refreshInterval = 2.0
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?
    private var hasNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show in menu bar", isOn: $menubarEnabled)
                Toggle("Show Dock icon", isOn: $dockIconVisible).disabled(!menubarEnabled)
                Toggle("Show notch summary", isOn: $notchEnabled).disabled(!hasNotch)
                Toggle("Hide notch in fullscreen", isOn: $hideInFullscreen).disabled(!notchEnabled)
                Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: setLogin))
                if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
                Picker("Sample interval", selection: $refreshInterval) {
                    Text("1 second").tag(1.0); Text("2 seconds (recommended)").tag(2.0); Text("5 seconds").tag(5.0)
                }
            }
            Section("Attention signals") {
                Text("Sustained background CPU: at least 100% average for two minutes, mostly in background.")
                Text("Memory growth: at least 500 MiB and 25% over ten minutes, increasing across multiple time buckets with unchanged helper membership.")
                Text("Conservative heuristics, not fault diagnoses. New history is needed after sleep, sampling changes or missing measurements.").foregroundStyle(.secondary)
                Toggle("Notify me about sustained activity and custom rules", isOn: $notificationsEnabled)
                Text("Off by default. At most one notification per app every ten minutes. In-app observations remain visible.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Optional custom CPU rules") {
                ForEach($store.alertRules) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("Enabled", isOn: $rule.enabled).labelsHidden()
                            Picker("App", selection: $rule.appID) {
                                Text("Any app").tag("any")
                                ForEach(ruleApps, id: \.bundleID) { app in Text(app.name).tag(app.bundleID) }
                                if rule.appID != "any" && !ruleApps.contains(where: { $0.bundleID == rule.appID }) {
                                    Text(rule.appName).tag(rule.appID)
                                }
                            }
                            Button(role: .destructive) { store.alertRules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Delete CPU rule")
                        }
                        Stepper("At least \(Int(rule.threshold))% CPU", value: $rule.threshold, in: 10...1600, step: 10)
                        Picker("For", selection: $rule.durationSeconds) {
                            Text("10 seconds").tag(10); Text("30 seconds").tag(30)
                            Text("1 minute").tag(60); Text("2 minutes").tag(120)
                        }
                    }
                    .onChange(of: rule.appID) { _, id in
                        rule.appName = id == "any" ? "Any app" : ruleApps.first(where: { $0.bundleID == id })?.name ?? id
                    }
                }
                Button("Add rule") { store.alertRules.append(AlertRule()) }
                Text("Each app is timed independently, including ‘Any app’ rules. Rules do not automatically quit or throttle apps.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy and coverage") {
                Text("No account, telemetry or uploads. Activity history stays in memory and is discarded on exit. Alert preferences are stored locally.")
                Text(coverageExplanation).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 520, height: 650)
        .onChange(of: menubarEnabled) { _, value in
            if !value { dockIconVisible = true }
            AppWindows.shared.applyVisibility()
        }
        .onChange(of: dockIconVisible) { _, _ in AppWindows.shared.applyVisibility() }
        .onChange(of: notchEnabled) { _, _ in NotchController.shared.apply() }
        .onChange(of: hideInFullscreen) { _, _ in NotchController.shared.refresh() }
        .onChange(of: notificationsEnabled) { _, value in if value { store.requestNotifications() } }
        .onAppear { loginEnabled = SMAppService.mainApp.status == .enabled }
    }

    private var ruleApps: [InstalledApp] {
        var seen = Set<String>()
        return store.installed.filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }
    }
    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Allow CubManager in System Settings → General → Login Items." : nil
        } catch { loginMessage = error.localizedDescription; loginEnabled = SMAppService.mainApp.status == .enabled }
    }
}

// MARK: - AppKit windows and menu bar (no external nibs/assets)

@MainActor
final class AppWindows: NSObject, NSWindowDelegate, NSMenuDelegate {
    static let shared = AppWindows()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?

    static func logo() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 20, height: 20); return image
        }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 2, width: 12, height: 13)).fill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 12, width: 7, height: 7)).fill()
            NSBezierPath(ovalIn: NSRect(x: 12, y: 12, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    func showMain() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "CubManager"
            window.contentView = NSHostingView(rootView: ContentView(store: .shared))
            window.minSize = NSSize(width: 440, height: 560)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.setFrameAutosaveName("CubManagerMain")
            if !window.setFrameUsingName("CubManagerMain") { window.center() }
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.deminiaturize(nil); mainWindow?.makeKeyAndOrderFront(nil)
    }
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 650),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "CubManager Settings"
            window.contentView = NSHostingView(rootView: SettingsView(store: .shared))
            window.isReleasedWhenClosed = false; window.delegate = self; window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }

    func applyVisibility() {
        let defaults = UserDefaults.standard
        let showMenu = defaults.bool(forKey: "menubarEnabled")
        let showDock = defaults.bool(forKey: "dockIconVisible") || !showMenu
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        if showMenu && item == nil {
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            status.button?.image = Self.logo(); status.button?.toolTip = "CubManager"
            let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
            status.menu = menu; item = status
            subscription = UsageStore.shared.$reports.sink { [weak self] reports in
                let count = reports.values.filter { !$0.analysis.signals.isEmpty }.count
                self?.item?.button?.contentTintColor = count > 0 ? .systemOrange : nil
                self?.item?.button?.toolTip = count > 0 ? "CubManager · \(count) apps worth reviewing" : "CubManager"
            }
        } else if !showMenu, let item {
            NSStatusBar.system.removeStatusItem(item); self.item = nil; subscription = nil
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = UsageStore.shared
        let title = NSMenuItem(title: store.statusTitle, action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        let top = store.reports.values.sorted {
            let a = $0.analysis.primary?.kind.priority ?? 0, b = $1.analysis.primary?.kind.priority ?? 0
            return a == b ? ($0.sample.cpu ?? -1) > ($1.sample.cpu ?? -1) : a > b
        }.prefix(3)
        for report in top {
            let entry = NSMenuItem(title: "\(report.descriptor.name) · \(Format.cpu(report.sample.cpu)) CPU", action: #selector(inspectMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = InstanceBox(report.descriptor.id)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        add(menu, "Open CubManager", #selector(openMain), "o")
        add(menu, "Settings…", #selector(openSettings), ",")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CubManager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; menu.addItem(quit)
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self; menu.addItem(entry)
    }
    @objc private func openMain() { showMain() }
    @objc private func openSettings() { showSettings() }
    @objc private func inspectMenu(_ sender: NSMenuItem) {
        if let box = sender.representedObject as? InstanceBox { UsageStore.shared.inspect(box.id) }
    }
}
private final class InstanceBox: NSObject { let id: AppInstanceID; init(_ id: AppInstanceID) { self.id = id } }

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
                Text(store.attentionCount > 0 ? "Review sustained activity and choose what to do." : "A quiet overview of monitored apps. Open CubManager for coverage and history.")
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

// MARK: - Application entry point

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["menubarEnabled": true, "dockIconVisible": true,
            "notchEnabled": false, "hideInFullscreen": true, "refreshInterval": 2.0, "notificationsEnabled": false])
        let appMenu = NSMenu()
        let root = NSMenuItem(); let submenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; submenu.addItem(settings); submenu.addItem(.separator())
        submenu.addItem(withTitle: "Quit CubManager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = submenu; appMenu.addItem(root)
        // Standard Edit menu preserves native text editing in hosted SwiftUI fields.
        let edit = NSMenuItem(); edit.title = "Edit"; let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        edit.submenu = editMenu; appMenu.addItem(edit); NSApp.mainMenu = appMenu
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        UsageStore.shared.start()
        AppWindows.shared.applyVisibility()
        NotchController.shared.apply()
        AppWindows.shared.showMain()
    }
    @objc private func showSettings() { AppWindows.shared.showSettings() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindows.shared.showMain(); return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completion: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let pid = (info["pid"] as? NSNumber)?.int32Value
        let launched = (info["launched"] as? NSNumber)?.doubleValue
        Task { @MainActor in
            if let pid, let launched {
                let id = AppInstanceID(pid: pid, launched: Date(timeIntervalSince1970: launched))
                if UsageStore.shared.reports[id] != nil { UsageStore.shared.inspect(id) }
                else { AppWindows.shared.showMain() }
            } else { AppWindows.shared.showMain() }
            completion()
        }
    }
}

@main
struct CubManagerMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif

// MARK: - Embedded portable regression tests (no XCTest target / extra file needed)

#if CUB_SELF_TEST
@main
struct CubManagerSelfTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        let identity = ProcessIdentity(pid: 10, started: 100)
        func samples(seconds: Int, cpu: Double = 150, background: Bool = true,
                     memory: (Double) -> Double = { _ in 500 * mib }) -> [ActivitySample] {
            stride(from: 2, through: seconds, by: 2).map { value in
                ActivitySample(time: Double(value), date: Date(timeIntervalSince1970: Double(value)), elapsed: 2,
                    cpu: cpu, memory: memory(Double(value)), background: background, members: [identity], complete: true)
            }
        }
        func evaluate(_ values: [ActivitySample], now: Double) -> AnalysisResult {
            var analyzer = ActivityAnalyzer()
            return analyzer.evaluate(values, now: now, date: Date(timeIntervalSince1970: now), interval: 2)
        }

        var ring = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { ring.append(value) }
        check(ring.values == [3, 4, 5], "Ring preserves chronological order across wrap")
        check(!evaluate(samples(seconds: 30), now: 30).cpuReady, "Short CPU bursts cannot fill a two-minute window")
        let sustained = evaluate(samples(seconds: 120), now: 120)
        check(sustained.cpuReady && sustained.primary?.kind == .backgroundCPU, "Sustained background CPU is detected")
        check(evaluate(samples(seconds: 120, background: false), now: 120).signals.isEmpty, "Foreground exports are not background incidents")
        check(evaluate(samples(seconds: 120, cpu: 5), now: 120).signals.isEmpty, "Quiet CPU does not trigger")
        let growing = samples(seconds: 600, cpu: 5, memory: { (500 + $0 * 1.5) * mib })
        let growth = evaluate(growing, now: 600)
        check(growth.memoryReady && growth.primary?.kind == .memoryGrowth, "Sustained large memory growth is detected")
        let step = samples(seconds: 600, cpu: 5, memory: { ($0 < 300 ? 500 : 1500) * mib })
        check(evaluate(step, now: 600).signals.isEmpty, "A single allocation jump is not a sustained trend")
        let changed = growing.enumerated().map { index, sample in
            ActivitySample(time: sample.time, date: sample.date, elapsed: sample.elapsed, cpu: sample.cpu,
                memory: sample.memory, background: sample.background,
                members: index > 150 ? [ProcessIdentity(pid: 10, started: 200)] : [identity], complete: true)
        }
        check(!evaluate(changed, now: 600).memoryReady, "PID reuse or membership change invalidates memory baseline")
        let missing = samples(seconds: 120).filter { $0.time < 50 || $0.time > 80 }
        check(!evaluate(missing, now: 120).cpuReady, "Sampling gaps invalidate CPU window")
        check(!evaluate(samples(seconds: 120), now: 200).cpuReady, "Stale samples cannot claim monitoring is healthy")
        let unavailable = samples(seconds: 120).map { sample in
            ActivitySample(time: sample.time, date: sample.date, elapsed: 2, cpu: nil, memory: nil,
                background: true, members: [identity], complete: false)
        }
        check(!evaluate(unavailable, now: 120).cpuReady, "Unavailable data is not zero")
        check(Format.cpu(nil) == "Unavailable", "Unknown CPU is explicitly labeled")
        check(Format.cpu(180) == "180.0%", "CPU above one core is not clamped")

        var analyzer = ActivityAnalyzer()
        var history = samples(seconds: 120)
        _ = analyzer.evaluate(history, now: 120, date: Date(), interval: 2)
        var recoveringObserved = false
        var recovered = false
        for time in stride(from: 122, through: 360, by: 2) {
            history.append(ActivitySample(time: Double(time), date: Date(), elapsed: 2, cpu: 0, memory: 500 * mib,
                background: true, members: [identity], complete: true))
            let state = analyzer.evaluate(history, now: Double(time), date: Date(), interval: 2)
            recoveringObserved = recoveringObserved || state.signals.contains(where: \.recovering)
            recovered = state.signals.isEmpty
        }
        check(recoveringObserved && recovered, "Hysteresis shows recovery before resolution")

        var evaluator = RuleEvaluator()
        let rule = AlertRule(threshold: 100, durationSeconds: 10)
        let a = AppInstanceID(pid: 1, launched: Date(timeIntervalSince1970: 1))
        let b = AppInstanceID(pid: 2, launched: Date(timeIntervalSince1970: 1))
        check(!evaluator.evaluate(rule: rule, app: a, cpu: 150, elapsed: 6), "First app has not met duration")
        check(!evaluator.evaluate(rule: rule, app: b, cpu: 150, elapsed: 6), "Any-app rule does not combine different apps")
        check(evaluator.evaluate(rule: rule, app: a, cpu: 150, elapsed: 4), "Same app reaching duration fires")
        check(!evaluator.evaluate(rule: rule, app: a, cpu: 150, elapsed: 4), "Rule fires once per sustained interval")
        _ = evaluator.evaluate(rule: rule, app: a, cpu: nil, elapsed: 2)
        check(!evaluator.evaluate(rule: rule, app: a, cpu: 150, elapsed: 2), "Missing data resets rule duration")
        print("CubManager: \(checks) portable regression checks passed.")
    }
}
#endif
