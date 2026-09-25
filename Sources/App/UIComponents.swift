#if os(macOS) && !CUB_SELF_TEST
import SwiftUI
import AppKit

let cpuExplanation = "100% means approximately one logical CPU’s worth of processing time. Apps using multiple cores can exceed 100%. High usage may be expected while compiling, exporting or processing. This is not a battery-use percentage."

struct AppIcon: View {
    let url: URL?
    var size: CGFloat = 32
    var body: some View {
        Group {
            if let url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable() }
            else { Image(systemName: "app.fill").resizable().foregroundStyle(.secondary) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct InfoButton: View {
    let label: String
    let text: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(label)
            .popover(isPresented: $showing) {
                Text(text).font(.callout).padding(18).frame(width: 310).fixedSize(horizontal: false, vertical: true)
            }
    }
}

struct Metric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).weight(.medium)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
}

struct AppActions: View {
    @ObservedObject var store: UsageStore
    let id: AppInstanceID
    var showInspect = true
    var body: some View {
        HStack(spacing: 12) {
            if showInspect {
                Button("Inspect") { store.inspect(id) }.buttonStyle(.bordered)
            }
            Button("Open app") { store.open(id) }.buttonStyle(.borderless)
            Spacer(minLength: 4)
            Button(store.pendingQuit.contains(id) ? "Quit requested…" : "Quit normally") { store.quit(id) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .disabled(store.pendingQuit.contains(id) || store.reports[id] == nil)
        }.font(.callout)
    }
}
#endif
