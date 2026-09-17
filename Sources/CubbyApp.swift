import SwiftUI

@main
struct CubbyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 320, minHeight: 420)
                .background(Color.black)
                .background(WindowAccessor())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

// Makes green traffic-light button zoom (expand arrows) instead of fullscreen
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.collectionBehavior = [.fullScreenAuxiliary]
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("Cubby")
                .foregroundStyle(.white.opacity(0.6))
                .font(.system(size: 20, weight: .medium, design: .rounded))
        }
    }
}
