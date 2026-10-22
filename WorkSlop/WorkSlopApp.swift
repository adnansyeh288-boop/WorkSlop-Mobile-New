import SwiftUI

@main
struct WorkSlopApp: App {
    @AppStorage("seenIntro") private var seenIntro = false
    @State private var showIntro = false

    init() {
        // English only (user order 2026-10-13): the in-app language
        // picker is gone, so pin AppleLanguages to English at launch
        // (also clears any language a previous version had set).
        UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        // Backend launch sequence (logging, AirLift sink, em_proxy),
        // then the Minimuxer start if a pairing record is in place.
        BackendBootstrap.appInit()
        BackendBootstrap.start()
    }

    /// iOS line this build supports: iOS 26 through 27 — the engine's
    /// line. On iOS 26 the tweaks ride the partial restore; on iOS 27
    /// a protective backup is taken first, then the modified backup
    /// is restored. Anything outside the line gets the full-screen
    /// notice instead of an app that cannot serve it.
    private var iosSupported: Bool {
        let v = DeviceInfo.iosVersion
        return (26...27).contains(v.major)
    }

    /// `-DemoScreen <name>` deep-links screenshot runs straight to a
    /// menu (home|settings|statusbar|posterboard). Nil on normal launches.
    private var demoScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-DemoScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var body: some Scene {
        WindowGroup {
            if iosSupported {
                ContentView(demoScreen: demoScreen)
                    .sheet(isPresented: $showIntro) { IntroView() }
                    .onAppear {
                        // Demo/screenshot runs (-DemoIOS26) land
                        // straight on Home, no intro sheet.
                        if !seenIntro,
                           !ProcessInfo.processInfo.arguments.contains("-DemoIOS26") {
                            showIntro = true
                        }
                    }
            } else {
                UnsupportedIOSView()
            }
        }
    }
}

/// Full-screen block for devices outside the supported iOS line.
/// Honest and final: no app UI behind it, just the facts.
struct UnsupportedIOSView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.octagon")
                    .font(.system(size: 60))
                    .foregroundStyle(.red)
                Text("iOS version not supported")
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("This device is running iOS \(DeviceInfoEx.fullVersion). WorkSlop 15.0 supports iOS 26.0 through 27.x.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Text("The app will not open on this iOS. Nothing was changed on your device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding()
        }
    }
}
