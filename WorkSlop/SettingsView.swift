import SwiftUI

/// Settings: version/device info, credits, license.
/// English only (user order 2026-10-13): the in-app language picker
/// was removed and the app pins AppleLanguages to English at launch
/// (see WorkSlopApp). Localizable.xcstrings is left untouched.
struct SettingsView: View {
    @State private var mediaStoreBytes: Int64 = 0
    @State private var containerFree: Int64 = 0
    @State private var showClearMediaConfirmation = false
    @State private var lastFreedText: String?
    @State private var clearErrorText: String?

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
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
                LabeledContent("Media copies held by WorkSlop",
                               value: formatBytes(mediaStoreBytes))
                LabeledContent("Free space on this iPhone",
                               value: formatBytes(containerFree))
                Text("These are safety copies of photos and videos WorkSlop pulled during earlier applies. The originals stay on the phone — clearing only removes WorkSlop's copies, and frees space the iOS 27 backup check counts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let lastFreedText {
                    Text(lastFreedText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let clearErrorText {
                    Text(clearErrorText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Clear media copies", role: .destructive) {
                    showClearMediaConfirmation = true
                }
                .disabled(mediaStoreBytes == 0)
            } header: {
                Text("Media store")
            }
            }
            .scrollContentBackground(.hidden)
            .onAppear { refreshMediaStore() }
            .confirmationDialog("Clear media copies?",
                                isPresented: $showClearMediaConfirmation,
                                titleVisibility: .visible) {
                Button("Clear media copies", role: .destructive) {
                    performClearMediaStore()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes WorkSlop's safety copies of your photos and videos (\(formatBytes(mediaStoreBytes))). The originals on this iPhone are not touched.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refreshMediaStore() {
        mediaStoreBytes = FreeSpaceGuard.mediaStoreBytes()
        containerFree = FreeSpaceGuard.containerFreeBytes()
    }

    private func performClearMediaStore() {
        do {
            let freed = try FreeSpaceGuard.clearMediaStore()
            lastFreedText = "Freed \(formatBytes(freed)) of media copies."
            clearErrorText = nil
        } catch {
            clearErrorText = "Could not clear the media copies: \(error.localizedDescription)"
            lastFreedText = nil
        }
        refreshMediaStore()
    }
}
