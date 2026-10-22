import SwiftUI

/// Settings: version/device info, credits, license.
/// English only (user order 2026-10-13): the in-app language picker
/// was removed and the app pins AppleLanguages to English at launch
/// (see WorkSlopApp). Localizable.xcstrings is left untouched.
struct SettingsView: View {
    var body: some View {
        ZStack {
            SkyBackground()
            List {
                Section {
                LabeledContent("Version", value: "2.0")
                LabeledContent("This device's iOS", value: DeviceInfoEx.fullVersion)
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
                Text("Beta testers: Charlie, rfrz1d_, Davy (@Davydavpn), uggtx, Fayaz")
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
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
