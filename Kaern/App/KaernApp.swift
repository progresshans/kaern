import KaernKit
import SwiftUI

/// A placeholder window while the app is rebuilt from the canvas design. It only proves the
/// app target builds and reaches the KaernKit git engine.
@main
struct KaernApp: App {
    var body: some Scene {
        WindowGroup {
            ShellView()
        }
        .defaultSize(width: 1440, height: 900)
    }
}

private struct ShellView: View {
    @State private var gitVersion: String?

    var body: some View {
        VStack(spacing: 8) {
            Text("Kaern")
                .font(.largeTitle.bold())
            Text(gitVersion.map { "git \($0)" } ?? "Looking for git…")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
        .task { gitVersion = await GitRunner().version() }
    }
}
