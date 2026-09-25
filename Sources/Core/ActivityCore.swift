import Foundation

// Pure activity-monitoring domain types and formatting. No AppKit/SwiftUI:
// this file is also compiled into the standalone self-test binary.

let mib: Double = 1_048_576

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
