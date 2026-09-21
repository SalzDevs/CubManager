import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage("menubarEnabled") private var menubarEnabled = true
    @AppStorage("dockIconVisible") private var dockIconVisible = true
    @AppStorage("notchEnabled") private var notchEnabled = false
    @AppStorage("hideInFullscreen") private var hideInFullscreen = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("refreshInterval") private var refreshInterval = 1.0

    private var hasNotch: Bool {
        (NSScreen.main?.safeAreaInsets.top ?? 0) > 0
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show in menu bar", isOn: $menubarEnabled)
                Toggle("Show Dock icon", isOn: $dockIconVisible)
                    .disabled(!menubarEnabled)
                Toggle("Show in notch", isOn: $notchEnabled)
                    .disabled(!hasNotch)
                Toggle("Hide in fullscreen", isOn: $hideInFullscreen)
                    .disabled(!notchEnabled || !hasNotch)
                if !hasNotch {
                    Text("This Mac has no notch")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                Picker("Refresh rate", selection: $refreshInterval) {
                    Text("Every second").tag(1.0)
                    Text("Every 2 seconds").tag(2.0)
                    Text("Every 5 seconds").tag(5.0)
                }
            }
            Section("CPU alerts") {
                if store.alertRules.isEmpty {
                    Text("Get notified when an app runs hot for too long.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach($store.alertRules) { $rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Toggle("", isOn: $rule.enabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            Picker("", selection: $rule.appID) {
                                Text("Any app").tag("any")
                                ForEach(store.runningApps) { app in
                                    Text(app.name).tag(app.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            Spacer()
                            Button {
                                store.removeAlertRule(rule.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        HStack(spacing: 8) {
                            Stepper(value: $rule.threshold, in: 10...400, step: 10) {
                                Text("≥ \(Int(rule.threshold))% CPU")
                            }
                            .fixedSize()
                            Spacer()
                            Picker("", selection: $rule.durationSeconds) {
                                Text("10s").tag(10)
                                Text("30s").tag(30)
                                Text("60s").tag(60)
                                Text("2m").tag(120)
                            }
                            .labelsHidden()
                            .frame(width: 70)
                        }
                    }
                    .onChange(of: rule) { _, _ in
                        store.saveAlertRules()
                    }
                }
                Button("Add alert…") {
                    store.addAlertRule()
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
        .onChange(of: hideInFullscreen) { _, _ in
            NotchController.shared.refresh()
        }
        .onChange(of: notchEnabled) { _, _ in
            NotchController.shared.apply()
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