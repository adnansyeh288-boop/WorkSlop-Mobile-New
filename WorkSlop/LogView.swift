import SwiftUI

/// The app log, as a Home menu page.
///
/// The engine has always written every run to a rotating file in
/// Documents (`AppPaths.appLog`, 2 MB cap) — this page is its reader.
/// Because the log lives in a file, it survives the app being closed
/// and the device restarting; what you see here is the saved log, not
/// just the current session. The Apply page's own log box stays as
/// the live view during a run.
struct LogView: View {
    @State private var lines: [String] = []
    @State private var fileSize: UInt64 = 0

    private var shareText: String { lines.joined(separator: "\n") }

    var body: some View {
        ZStack {
            SkyBackground()
            VStack(spacing: 0) {
                if lines.isEmpty {
                    ContentUnavailableView(
                        "No log yet",
                        systemImage: "doc.text",
                        description: Text("Nothing has been logged yet. Staging a tweak or running Apply writes the first lines."))
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(lines.joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(12)
                                .id("logText")
                        }
                        .onAppear {
                            proxy.scrollTo("logText", anchor: .bottom)
                        }
                    }
                }
                Divider()
                HStack {
                    Text(fileSize > 0
                         ? "Saved log — \(lines.count) line(s), \(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)). Kept across restarts."
                         : "The log is saved to a file and kept across restarts.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    ShareLink(item: shareText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .controlSize(.small)
                    .disabled(lines.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private func reload() {
        fileSize = AppLog.shared.file.size()
        guard let text = try? String(contentsOf: AppPaths.appLog, encoding: .utf8) else {
            lines = AppLog.shared.memory.snapshot
            return
        }
        lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
