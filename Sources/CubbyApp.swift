import SwiftUI

@main
struct CubbyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 320, minHeight: 420)
                .background(Color.black)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
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
