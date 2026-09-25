#if os(macOS) && !CUB_SELF_TEST
import SwiftUI
import AppKit

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
    @State private var showAllRunning = false
    @FocusState private var focusedApp: AppInstanceID?
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var maxVisible: Int { 3 }
    private var visibleReports: [AppReport] {
        let all = store.displayedReports
        guard search.isEmpty, !showAllRunning else { return all }
        return Array(all.prefix(maxVisible))
    }
    private var hiddenCount: Int { store.displayedReports.count - visibleReports.count }
    private var overflowing: Bool { showAllRunning && store.displayedReports.count > maxVisible }

    var body: some View {
        VStack(spacing: 0) {
            if let report = store.inspected {
                InspectView(store: store, report: report).id(report.descriptor.id)
            } else {
                header
                Divider()
                listArea
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
        .frame(minWidth: 440, minHeight: 260)
        .ignoresSafeArea(edges: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.teal)
    }

    /// No scrolling for the normal list (≤3 cards): the window itself hugs
    /// the content via NSHostingView.sizingOptions. Scroll only when the
    /// user explicitly expands to all running apps.
    @ViewBuilder private var listArea: some View {
        if overflowing {
            ScrollView {
                runningList.padding(16)
            }
            .frame(maxHeight: 640)
        } else {
            runningList.padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CubManager").font(.title2.bold())
                    Text("Understand your apps. Stay in control.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 64)   // clear the traffic-light buttons
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
            HStack {
                Picker("Sort", selection: $store.sort) { ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 160)
                Spacer()
                Text("CPU").font(.caption).foregroundStyle(.secondary)
                InfoButton(label: "How CPU percentages work", text: cpuExplanation)
            }
            appSection("Running apps", apps: visibleReports)
            if hiddenCount > 0 {
                Button("+\(hiddenCount) more running") {
                    withAnimation(.easeInOut(duration: 0.2)) { showAllRunning = true }
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            } else if showAllRunning {
                Button("Show fewer") {
                    withAnimation(.easeInOut(duration: 0.2)) { showAllRunning = false }
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
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
#endif
