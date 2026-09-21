import SwiftUI
import AppKit

// Main window UI: search bar, adaptive app grid, hover actions and the
// expandable per-app detail panel. Rendered both in the main window and
// inside the notch panel.
struct Sparkline: View {
    let samples: [Double]
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxV = max(100.0, samples.max() ?? 100.0)
            Path { p in
                guard samples.count > 1, w > 0, h > 0 else { return }
                for (i, s) in samples.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(samples.count - 1)
                    let y = h - min(h, h * CGFloat(s / maxV))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
        }
    }
}

struct ContentView: View {
    private let minRowHeight: CGFloat = 40

    @EnvironmentObject private var store: UsageStore
    @State private var hoveredAppID: String? = nil
    @State private var hoveredQuitID: String? = nil
    @State private var hoveredOpenID: String? = nil
    @State private var hoveredChevronID: String? = nil
    @State private var query: String = ""
    @State private var expandedID: String? = nil
    @FocusState private var isSearchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var displayedApps: [AppEntry] {
        if trimmedQuery.isEmpty { return store.runningApps }
        return store.installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.id.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var runningIDs: Set<String> {
        Set(store.runningApps.map(\.id))
    }

    private func highlightedText(_ name: String, query q: String) -> AttributedString {
        var attr = AttributedString(name)
        attr.foregroundColor = .white.opacity(0.85)
        guard !q.isEmpty else { return attr }
        var index = name.startIndex
        while index < name.endIndex {
            guard let r = name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: index..<name.endIndex) else { break }
            let lower = name.distance(from: name.startIndex, to: r.lowerBound)
            let upper = name.distance(from: name.startIndex, to: r.upperBound)
            if let ar = Range(NSRange(location: lower, length: upper - lower), in: attr) {
                attr[ar].foregroundColor = .white
            }
            index = r.upperBound
        }
        return attr
    }

    private func rowTap(_ app: AppEntry) {
        // Row click toggles the details panel. Clicking never switches
        // to another app's window.
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedID = expandedID == app.id ? nil : app.id
        }
    }

    private func clearHover() {
        // Window resize moves rows under a stationary cursor; SwiftUI's
        // tracking areas don't fire enter/exit on pure frame changes, so
        // hover state goes stale (highlight sticks to the wrong row).
        // Reset it on resize; the next real mouse move re-establishes it.
        hoveredAppID = nil
        hoveredQuitID = nil
        hoveredOpenID = nil
        hoveredChevronID = nil
    }

    private func memString(_ memMB: Double) -> String {
        memMB >= 1024 ? String(format: "%.1f GB", memMB / 1024) : String(format: "%.0f MB", memMB)
    }

    private func uptimeString(_ date: Date?) -> String {
        guard let date else { return "–" }
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func cpuColor(_ cpu: Double) -> Color {
        if cpu >= 200 { return Color.orange.opacity(0.9) }
        if cpu >= 100 { return Color.yellow.opacity(0.75) }
        return Color.white.opacity(0.55)
    }

    private func memColor(_ memMB: Double) -> Color {
        memMB >= 2048 ? Color.yellow.opacity(0.75) : Color.white.opacity(0.55)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            Text(value)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    private func chevronButton(_ app: AppEntry, rowHeight: CGFloat) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedID = expandedID == app.id ? nil : app.id
            }
        } label: {
            Image(systemName: expandedID == app.id ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredChevronID = hovering ? app.id : nil
            if hovering { hoveredAppID = app.id }
        }
        .background(
            Circle().fill(hoveredChevronID == app.id
                          ? Color.white.opacity(0.25)
                          : Color.white.opacity(0.15))
        )
        .opacity(expandedID == app.id ? 1 : (hoveredAppID == app.id ? 1 : 0))
        .allowsHitTesting(hoveredAppID == app.id)
        .help("Details")
    }

    private func detailPanel(_ app: AppEntry) -> some View {
        let u = app.pid.flatMap { store.usage[Int($0)] }
        let hist = app.pid.flatMap { store.history[Int($0)] } ?? []
        let bundle = app.url.flatMap { Bundle(url: $0) }
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let bid = bundle?.bundleIdentifier ?? app.id
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text("\(version ?? "–") · \(bid) · PID \(app.pid ?? 0)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                    Text(app.url?.path ?? "–")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expandedID = nil }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("CPU · last 60s")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Sparkline(samples: hist)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.03)))
            }
            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading)
            ], alignment: .leading, spacing: 12) {
                metric("CPU", String(format: "%.1f%%", u?.cpu ?? 0))
                metric("MEM", memString(u?.memMB ?? 0))
                metric("UPTIME", uptimeString(app.launchDate))
                metric("THREADS", "\(u?.info.pti_threadnum ?? 0)")
                metric("DISK R", memString(u?.diskReadMB ?? 0))
                metric("DISK W", memString(u?.diskWriteMB ?? 0))
                metric("NET IN", memString(u?.netInMB ?? 0))
                metric("NET OUT", memString(u?.netOutMB ?? 0))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }

    private func usageView(_ u: UsageSnapshot, rowHeight: CGFloat) -> some View {
        let size = min(max(rowHeight * 0.18, 10), 12)
        let iconSize = min(max(rowHeight * 0.16, 9), 10)
        return HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Text(String(format: "%.1f%%", u.cpu))
                    .font(.system(size: size, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(cpuColor(u.cpu))
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(spacing: 3) {
                Image(systemName: "memorychip")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Text(memString(u.memMB))
                    .font(.system(size: size, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(memColor(u.memMB))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .fixedSize()
    }

    private func quitButton(_ app: AppEntry, rowHeight: CGFloat) -> some View {
        Button {
            store.quitApp(app)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: min(max(rowHeight * 0.2, 10), 12), weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredQuitID = hovering ? app.id : nil
            if hovering { hoveredAppID = app.id }
        }
        .background(
            Circle().fill(hoveredQuitID == app.id
                          ? Color.red.opacity(0.8)
                          : Color.white.opacity(0.15))
        )
        .opacity(hoveredAppID == app.id ? 1 : 0)
        .allowsHitTesting(hoveredAppID == app.id)
        .help("Quit \(app.name)")
    }

    private func openButton(_ app: AppEntry, rowHeight: CGFloat) -> some View {
        Button {
            store.openApp(app)
            query = ""
        } label: {
            Image(systemName: "arrow.up.right")
                .font(.system(size: min(max(rowHeight * 0.2, 10), 12), weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredOpenID = hovering ? app.id : nil
            if hovering { hoveredAppID = app.id }
        }
        .background(
            Circle().fill(hoveredOpenID == app.id
                          ? Color.green.opacity(0.8)
                          : Color.white.opacity(0.15))
        )
        .opacity(hoveredAppID == app.id ? 1 : 0)
        .allowsHitTesting(hoveredAppID == app.id)
        .help("Open \(app.name)")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar — flat full-width header row, flush with grid
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.4))
                    .font(.system(size: 13, weight: .medium))
                TextField("Search apps", text: $query, prompt: Text("Search apps").foregroundColor(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white.opacity(0.9))
                    .font(.system(size: 13))
                    .focused($isSearchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.5))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                SettingsLink {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.white.opacity(0.4))
                        .font(.system(size: 12, weight: .medium))
                }
                .help("Settings")
                // Center-aligns with the traffic-light close/expand buttons
                // (their center sits 16pt from the window top, measured)
                .offset(y: -4)
            }
            .padding(.horizontal, 14)
            .frame(height: minRowHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSearchFocused ? Color.white.opacity(0.35) : Color.white.opacity(0.12))
                    .frame(height: 1)
            }
            .animation(.easeInOut(duration: 0.15), value: query.isEmpty)
            .animation(.easeInOut(duration: 0.15), value: isSearchFocused)

            GeometryReader { geo in
                let searching = !trimmedQuery.isEmpty
                let rowCount = displayedApps.count
                let fitCount = max(1, min(rowCount, Int(geo.size.height / minRowHeight)))
                let rowHeight: CGFloat = searching ? minRowHeight : geo.size.height / CGFloat(fitCount)

                if displayedApps.isEmpty {
                    VStack {
                        Spacer()
                        Text(trimmedQuery.isEmpty ? "No running apps" : "No apps found")
                            .foregroundStyle(.white.opacity(0.4))
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(displayedApps) { app in
                                VStack(spacing: 0) {
                                    if !searching && expandedID == app.id {
                                        detailPanel(app)
                                    } else {
                                    HStack(spacing: 8) {
                                        HStack(spacing: 10) {
                                            if let icon = app.icon {
                                                Image(nsImage: icon)
                                                    .resizable()
                                                    .frame(width: min(max(rowHeight * 0.32, 20), 38),
                                                           height: min(max(rowHeight * 0.32, 20), 38))
                                            }
                                            Text(highlightedText(app.name, query: trimmedQuery))
                                                .font(.system(size: 15, weight: .regular))
                                                .lineLimit(1)
                                                .layoutPriority(1)
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture { rowTap(app) }
                                        if searching && runningIDs.contains(app.id) {
                                            Circle()
                                                .fill(Color.green.opacity(0.9))
                                                .frame(width: 6, height: 6)
                                        }
                                        Spacer()
                                        if !searching, let pid = app.pid, let u = store.usage[Int(pid)] {
                                            usageView(u, rowHeight: rowHeight)
                                        }
                                        if !searching {
                                            chevronButton(app, rowHeight: rowHeight)
                                        }
                                        if app.isRunning {
                                            quitButton(app, rowHeight: rowHeight)
                                        }
                                        if searching {
                                            openButton(app, rowHeight: rowHeight)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: rowHeight)
                                    .overlay(alignment: .top) {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.12))
                                            .frame(height: 1)
                                    }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(hoveredAppID == app.id ? Color.white.opacity(0.08) : Color.clear)
                                .onHover { hovering in
                                    hoveredAppID = hovering ? app.id : nil
                                }
                                .contextMenu {
                                    Button("Open \(app.name)") { store.openApp(app) }
                                    if app.isRunning {
                                        Button("Quit \(app.name)") { store.quitApp(app) }
                                    }
                                }
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.12))
                                        .frame(height: 1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .overlay(alignment: .bottom) {
                        if !searching {
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(Color.black)
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification))
                .receive(on: DispatchQueue.main)
        ) { _ in
            clearHover()
        }
    }
}
