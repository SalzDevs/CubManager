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
    var body: some View {
        let values = points.compactMap { value($0) }
        let maximum = max(memory ? mib : 100, values.max() ?? 0) * 1.1
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(memory ? "Memory" : "CPU").font(.subheadline.weight(.medium))
                Spacer()
                Text(memory ? Format.bytes(values.max()) : Format.cpu(values.max())).font(.caption).foregroundStyle(.secondary)
                Text("peak").font(.caption).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                guard let end = points.last?.time else { return }
                var path = Path()
                var previous: Double?
                for point in points {
                    guard let measurement = value(point) else { previous = nil; continue }
                    let x = (point.time - (end - seconds)) / seconds * size.width
                    let y = size.height - measurement / maximum * size.height
                    let position = CGPoint(x: x, y: y)
                    if let previous, point.time - previous <= interval * 2.5, point.elapsed > 0 { path.addLine(to: position) }
                    else { path.move(to: position) }
                    previous = point.time
                }
                context.stroke(path, with: .color(memory ? .blue : .teal), lineWidth: 2)
            }
            .frame(height: 90).padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
            .accessibilityLabel("\(memory ? "Memory" : "CPU") history. Peak \(memory ? Format.bytes(values.max()) : Format.cpu(values.max())). Gaps represent unavailable samples.")
            HStack {
                Text("−\(Int(seconds / 60)) min")
                Spacer()
                if let last = points.last { Text(last.date, style: .time) }
            }.font(.caption2).foregroundStyle(.secondary)
        }
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
