import SwiftUI

/// Settings: version/device info, credits, license.
/// English only (user order 2026-10-13): the in-app language picker
/// was removed and the app pins AppleLanguages to English at launch
/// (see WorkSlopApp). Localizable.xcstrings is left untouched.
struct SettingsView: View {
    /// Development-mode bindings, over the same `UserDefaults` keys the
    /// backend reads (`DevSettings`) — spelled once, there, so the page and
    /// the gate cannot disagree about which switch is which.
    @AppStorage(DevSettings.Key.enabled) private var devEnabled = false
    @AppStorage(DevSettings.Key.fprDiscriminatorTest) private var fprTestArmed = false
    @State private var fprRunning = false
    @State private var fprResult = ""

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                Section {
                LabeledContent("Version", value: "3.0")
                LabeledContent("This device's iOS", value: DeviceInfoEx.fullVersion)
                LabeledContent("Build", value: DeviceInfoEx.buildNumber)
                LabeledContent("Build support", value: BuildSupport.current.displayText)
                Text("iOS 26: Partial restore (sparse restore, no wipe). iOS 27: a protective backup of all data is taken first, the tweaks are injected into it, and the modified backup is restored.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("A running restore cannot be cancelled mid-flight. If it stalls, turn off the VPN tunnel, then force-restart (Volume Up, Volume Down, hold Side button).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("This app cannot reboot your iPhone. After an apply you restart manually.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Info")
            }

            Section {
                LabeledContent("Developer", value: "adnan.120hz")
                Link("TikTok @adnan.120hz", destination: URL(string: "https://www.tiktok.com/@adnan.120hz")!)
                Text("Beta testers: Charlie, rfrz1d_, Davy, uggtx, Fayaz, alfndv1")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("iOS 18 icon pack: catwithabaloon (v2.0)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Credits")
            }

            Section {
                Text("WorkSlop Mobile is free software, licensed under the GNU Affero General Public License v3.0 or later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("Read the full license (AGPL-3.0)",
                     destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
            } header: {
                Text("License")
            }

            Section {
                Toggle("Development Mode", isOn: $devEnabled)
                if devEnabled {
                    Toggle("FPR Discriminator Test", isOn: $fprTestArmed)
                    Button("FPR Discriminator Test (iOS 27)") { runFPRTest() }
                        .disabled(!fprTestArmed || fprRunning)
                    if !fprResult.isEmpty {
                        Text(fprResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Development only. Restores ONE harmless marker file (ManagedPreferencesDomain/Library/Preferences/com.workslop.fprtest.plist) from a backup manifest synthesised on this device — no protective backup is pulled first. That is the experiment: whether an iOS 27 device accepts a synthesised sqlite partial manifest at all. Every stage is written to the log under [FPR-TEST].")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Development")
            }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Start the discriminator test. The run itself reports into the app log
    /// under `[FPR-TEST]`; the line kept here is only its one-sentence
    /// outcome, so the page says what happened without pretending to be the
    /// evidence.
    private func runFPRTest() {
        fprRunning = true
        fprResult = "Running — progress is in the log."
        Task {
            let outcome = await FPRDiscriminatorTest.run()
            fprResult = outcome
            fprRunning = false
        }
    }
}
