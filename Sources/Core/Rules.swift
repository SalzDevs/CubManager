import Foundation

// Custom CPU threshold rules and their per-app-instance accumulators.

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
