#if os(macOS) && !CUB_SELF_TEST
import Foundation
import Darwin

let historySeconds: Double = 30 * 60

// MARK: - Background collection

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

    // CPU-time counters (proc_taskinfo and rusage) are expressed in mach
    // absolute-time ticks (~24 MHz on Apple Silicon, timebase 125/3 ns per
    // tick), not nanoseconds. Without this conversion every CPU reading is
    // reported ~40x too low.
    private static let cpuTickToNs: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

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
            let tickNs = Self.cpuTickToNs
            cpu = Double(total - previous.cpu) * tickNs / ((time - previous.time) * 1_000_000_000) * 100
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
#endif
