import Foundation

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
