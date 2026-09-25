import Foundation

// Time-window behavioral analysis: background-CPU and memory-growth
// attention signals with hysteresis, coverage gating and baseline guards.

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
            if average >= 90 && background >= 0.9 {
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
