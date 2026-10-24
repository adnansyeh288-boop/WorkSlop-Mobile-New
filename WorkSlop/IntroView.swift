import SwiftUI

/// First-launch introduction, shown once. Plain text pages — what
/// WorkSlop Mobile supports, and what it needs before anything is
/// applied. No animation, no cards.
struct IntroView: View {
    @AppStorage("seenIntro") private var seenIntro = false
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                introPage(
                    title: "WorkSlop",
                    lines: [
                        "On-device tweaks for this iPhone: Liquid Glass, Status Bar, Daemons, Apple Internal, SpringBoard, Custom Icons and PosterBoard.",
                        "This device: \(DeviceStatus.modelOrDash) \u{2022} iOS \(DeviceInfoEx.fullVersion)",
                    ])
                .tag(0)

                introPage(
                    title: "Supported iOS",
                    lines: [
                        "Liquid Glass: iOS 26.0 and later.",
                        "Status Bar classic options: iOS 26.x (iOS 27 keeps carrier text only).",
                        "iOS 26 and below: tweaks ride Partial restore (sparse restore, no wipe). iOS 27: Full backup \u{2192} modify \u{2192} restore with all data - the WorkSlop Desktop method.",
                        "Devices below iOS 26.0 or above iOS 27 get an \"iOS version not supported\" notice instead of this app.",
                    ])
                .tag(1)

                introPage(
                    title: "Before you apply",
                    lines: [
                        "Import the pairing file (.plist) on the Home screen.",
                        "Applies run over a loopback VPN tunnel to this same phone - the tunnel row on Home must say DETECTED.",
                        "Find My must be OFF before an apply, back ON afterwards - same rule as the desktop.",
                        "The app cannot reboot your iPhone \u{2014} after an apply you restart manually.",
                        "Apply sends the staged tweaks through the on-device restore engine. A running restore cannot be cancelled mid-flight.",
                    ])
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button(page == 2 ? "Start" : "Continue") {
                if page == 2 {
                    seenIntro = true
                    dismiss()
                } else {
                    withAnimation { page += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .accessibilityIdentifier("intro-continue")
        }
    }

    private func introPage(title: String, lines: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.title.weight(.bold))
                    .padding(.top, 32)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
        }
    }
}
