#if os(macOS) && !CUB_SELF_TEST
import SwiftUI
import AppKit
import ServiceManagement

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
                Text("Sustained background CPU: at least 90% average for two minutes, mostly in background.")
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
#endif
