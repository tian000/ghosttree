import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Ghosttree", systemImage: "tree.fill")
                .font(.largeTitle.bold())

            Text("Instant, isolated copy-on-write views of any directory.")
                .font(.title3)

            GroupBox("Native filesystem extension") {
                HStack {
                    Image(systemName: nativeFSKitAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(nativeFSKitAvailable ? .green : .orange)
                    Text(nativeFSKitAvailable
                         ? "This Mac can run Ghosttree's FSKit extension."
                         : "Mounting requires macOS 26 or newer. The CLI and overlay engine can still be developed and tested here.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Text("CLI quick start")
                .font(.headline)
            Text("ghosttree create --lower ~/projects --name experiment --mount")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Spacer()
        }
        .padding(28)
        .frame(minWidth: 620, minHeight: 330)
    }

    private var nativeFSKitAvailable: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }
}
