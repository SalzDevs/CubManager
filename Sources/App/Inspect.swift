#if os(macOS) && !CUB_SELF_TEST
import SwiftUI
import AppKit

// MARK: - Timestamped charts and inspection

struct HistoryChart: View {
    let samples: [ActivitySample]
    let seconds: Double
    let memory: Bool
    let interval: Double
    private var points: [ActivitySample] {
        guard let last = samples.last else { return [] }
        return samples.filter { $0.time >= last.time - seconds }
    }
    private func value(_ sample: ActivitySample) -> Double? { memory ? sample.memory : sample.cpu }

    private var lineColor: Color { memory ? .blue : .teal }

    /// Nice, data-driven gridline steps (1/2/2.5/5 × 10ⁿ) — the axis follows
    /// the data instead of being hard-coded.
    private func niceGridlines(maximum: Double) -> [Double] {
        var rawStep = maximum / 3
        let magnitude = pow(10.0, floor(log10(rawStep)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }
            .first { maximum / $0 <= 3.5 } ?? rawStep
        var values: [Double] = []
        var v = 0.0
        while v <= maximum + 0.001 { values.append(v); v += step }
        return values.count >= 2 ? values : [0, maximum]
    }

    private func gridLabel(_ gridValue: Double) -> String {
        memory ? Format.bytes(gridValue) : String(format: "%.0f%%", gridValue)
    }

    private var axisWidth: CGFloat { memory ? 44 : 30 }

    private func timeAgoLabel(_ secondsAgo: Double) -> String {
        let s = Int(secondsAgo.rounded())
        if s >= 3600 {
            let h = s / 3600, m = (s % 3600) / 60
            return m != 0 ? "−\(h)h \(m)m" : "−\(h)h"
        }
        if s >= 60 {
            let m = s / 60, r = s % 60
            return r != 0 ? "−\(m)m \(r)s" : "−\(m)m"
        }
        return "−\(s)s"
    }

    var body: some View {
        let values = points.compactMap { value($0) }
        let current = values.last
        let peak = values.max() ?? 0
        // Scale: CPU keeps 100% (one core) visible; memory scales to the peak.
        let maximum = max(memory ? mib : 100, peak) * 1.08
        let gridValues = niceGridlines(maximum: maximum)
        let currentValueText = memory ? Format.bytes(current) : Format.cpu(current)
        let peakText = memory ? Format.bytes(peak) : Format.cpu(peak)
        let xLabels: [(Double, String)] = [
            (0, timeAgoLabel(seconds)),
            (0.5, timeAgoLabel(seconds / 2)),
            (1, "now"),
        ]

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(memory ? "Memory" : "CPU").font(.subheadline.weight(.medium))
                Spacer()
                Text(currentValueText)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(lineColor)
                Text("now").font(.caption2).foregroundStyle(.secondary)
                Text(peakText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text("peak").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 5) {
                // Y-axis labels live OUTSIDE the plot — they can never
                // overlap the data line.
                ZStack(alignment: .topLeading) {
                    ForEach(gridValues, id: \.self) { gridValue in
                        Text(gridLabel(gridValue))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                            .offset(y: max(0, min(76, (1 - gridValue / maximum) * 90 - 5)))
                    }
                }
                .frame(width: axisWidth, height: 90, alignment: .topTrailing)
                Canvas { context, size in
                    guard let end = points.last?.time else { return }
                    // y gridlines
                    for gridValue in gridValues {
                        let y = size.height - gridValue / maximum * size.height
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: y))
                        line.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(line, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
                    }
                // CPU: dashed reference line at exactly one core
                if !memory, maximum > 100 {
                    let y = size.height - 100 / maximum * size.height
                    var ref = Path()
                    ref.move(to: CGPoint(x: 0, y: y))
                    ref.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(ref, with: .color(.primary.opacity(0.18)),
                                   style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                }
                // x gridlines (vertical)
                for fraction in [0.0, 0.5, 1.0] {
                    let x = fraction * size.width
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
                }
                var previous: Double?
                var area = Path()
                var line = Path()
                var started = false
                var lastPosition: CGPoint?
                for point in points {
                    guard let measurement = value(point) else { previous = nil; started = false; continue }
                    let x = (point.time - (end - seconds)) / seconds * size.width
                    let y = size.height - measurement / maximum * size.height
                    let position = CGPoint(x: x, y: y)
                    if let previous, point.time - previous <= interval * 2.5, point.elapsed > 0, started {
                        line.addLine(to: position)
                        area.addLine(to: position)
                    } else {
                        line.move(to: position)
                        area.move(to: CGPoint(x: x, y: size.height))
                        area.addLine(to: position)
                        started = true
                    }
                    previous = point.time
                    lastPosition = position
                }
                if let lastPosition, started {
                    area.addLine(to: CGPoint(x: lastPosition.x, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [lineColor.opacity(0.35), lineColor.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
                    context.stroke(line, with: .color(lineColor), lineWidth: 1.5)
                    context.fill(Path(ellipseIn: CGRect(x: lastPosition.x - 3, y: lastPosition.y - 3, width: 6, height: 6)),
                                 with: .color(lineColor))
                }
            }
            }
            .frame(height: 90)
            // x-axis labels under the chart, anchored to the gridline edges
            .overlay(alignment: .bottomLeading) { xLabel(xLabels[0].1, anchor: .leading) }
            .overlay(alignment: .bottom) { xLabel(xLabels[1].1) }
            .overlay(alignment: .bottomTrailing) { xLabel(xLabels[2].1, anchor: .trailing) }
            .padding(8).padding(.bottom, 16)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
            .accessibilityLabel("\(memory ? "Memory" : "CPU") history. Current \(currentValueText). Peak \(peakText). Gaps represent unavailable samples.")
        }
    }

    private func xLabel(_ text: String, anchor: Alignment = .center) -> some View {
        Text(text)
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: anchor)
    }
}

struct InspectView: View {
    @ObservedObject var store: UsageStore
    let report: AppReport
    @State private var seconds = 300.0
    @State private var confirmForce = false
    @State private var network: NetworkReading?
    @State private var networkError: String?
    @State private var measuringNetwork = false
    private var id: AppInstanceID { report.descriptor.id }
    private var closed: Bool { store.reports[id] == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { store.selected = nil } label: { Label("All apps", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                HStack(spacing: 12) {
                    AppIcon(url: report.descriptor.url, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.descriptor.name).font(.title2.bold())
                        Text(closed ? "App closed · Last recorded activity" : (report.descriptor.background ? "In background" : "In foreground"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !closed { AppActions(store: store, id: id, showInspect: false) }
                if let message = store.actionMessages[id] { Text(message).font(.callout).foregroundStyle(.secondary) }
                HStack(alignment: .top, spacing: 24) {
                    Metric(title: "CPU", value: Format.cpu(report.sample.cpu))
                    InfoButton(label: "How CPU percentages work", text: cpuExplanation)
                    Metric(title: "Memory footprint", value: Format.bytes(report.sample.memory))
                    Spacer(minLength: 0)
                }
                Picker("History", selection: $seconds) {
                    Text("5 minutes").tag(300.0); Text("30 minutes").tag(1800.0)
                }.pickerStyle(.segmented)
                HistoryChart(samples: report.history, seconds: seconds, memory: false, interval: store.interval)
                HistoryChart(samples: report.history, seconds: seconds, memory: true, interval: store.interval)
                    .font(.caption).foregroundStyle(.secondary)
                if !report.incidents.isEmpty { incidentList }
            }.padding(20)
        }
        .confirmationDialog("Force quit \(report.descriptor.name)?", isPresented: $confirmForce, titleVisibility: .visible) {
            Button("Force quit", role: .destructive) { store.quit(id, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Unsaved work may be lost. CubManager will not force quit automatically.") }
    }

    private var incidentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent observations").font(.headline)
            ForEach(report.incidents.reversed()) { incident in
                VStack(alignment: .leading, spacing: 4) {
                    Text(incident.explanation).font(.callout)
                    HStack {
                        Text(incident.began, style: .time)
                        Text(incident.ended == nil && !closed ? "· Active" : "· Ended or evaluation interrupted")
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func measureNetwork() {
        guard store.runningInstance(id) != nil else { networkError = "This app instance has closed."; return }
        measuringNetwork = true; networkError = nil
        let pids = Set(report.processes.map { $0.id.pid })
        Task {
            defer { measuringNetwork = false }
            do {
                let reading = try await NetworkProbe.measure(pids: pids)
                guard store.runningInstance(id) != nil else { networkError = "The app closed during measurement."; return }
                network = reading
            } catch { networkError = error.localizedDescription }
        }
    }
}
#endif
