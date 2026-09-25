import Foundation
import AppKit
import Combine
import UserNotifications

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
