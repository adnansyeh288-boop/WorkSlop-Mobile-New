import SwiftUI

// MARK: - Aligned row icon

/// Fixed-width SF Symbol for menu rows. Different symbols have
/// different optical widths, which makes the label text start at
/// ragged x positions ("mencong"). A fixed frame keeps every row's
/// text in one straight column.
struct RowIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .frame(width: 30, alignment: .center)
    }
}

// MARK: - Lock banner

/// Shown at the top while the pairing-file + VPN gate is closed.
struct LockBanner: View {
    @EnvironmentObject private var status: StatusStore

    var body: some View {
        if !status.unlocked {
            Text(ActivationGate.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - One flat tweak row: toggle, never a slider

struct FeatureToggleRow: View {
    let feature: Feature
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var status: StatusStore
    @State private var showInfo = false

    private var availability: Availability {
        // The GN spec's own version bounds are the authority; the
        // feature's window is only the fallback for the spec-less
        // PosterBoard features.
        if let a = GNMapping.availability(forFeature: feature.id,
                                          version: DeviceInfoEx.fullVersion,
                                          isIPhone: DeviceStatus.model.hasPrefix("iPhone")) {
            return a
        }
        return feature.availability(for: DeviceInfo.iosVersion)
    }

    /// Toggle is live only when the iOS supports the tweak AND the
    /// pairing-file + VPN gate is open.
    private var toggleEnabled: Bool {
        availability.isEnabled && status.unlocked
    }

    /// What the tweak writes, where, and through which route — from
    /// the GN spec itself.
    private var explanation: String {
        var lines = GNMapping.explanationLines(for: feature)
        lines.append("Support: \(supportLabel).")
        return lines.joined(separator: "\n\n")
    }

    private var supportLabel: String {
        let specs = GNMapping.specs(forFeature: feature.id)
        guard !specs.isEmpty else { return feature.window.label }
        var bounds: [String] = []
        if let min = specs.compactMap(\.minVersion).max() { bounds.append("iOS \(min)+") }
        if let max = specs.compactMap(\.maxVersion).min() { bounds.append("max iOS \(max)") }
        return bounds.isEmpty ? "iOS 26+" : bounds.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { selection.isOn(feature.id) },
                set: { selection.set(feature.id, $0) })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title)
                        .lineLimit(2)
                    Text(feature.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !availability.isEnabled, let chip = availability.chipText {
                        Text(chip)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(!toggleEnabled)
            .accessibilityIdentifier("toggle-\(feature.id)")
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("info-\(feature.id)")
        }
        .opacity(availability.isEnabled ? 1 : 0.6)
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                ScrollView {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(feature.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Done") { showInfo = false }
                }
            }
        }
    }
}

// MARK: - VPN tunnel explainer

/// What the loopback VPN tunnel is (and is not), and App Store apps
/// that can open one.
struct TunnelInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("What the tunnel is") {
                    Text("WorkSlop runs on the same iPhone it tweaks. To deliver a payload it must talk to this phone's own lockdownd service, and iOS does not let an app open that connection directly - the traffic has to ride a local VPN tunnel (a utun interface) back into the phone itself.")
                    Text("This is NOT an internet VPN: no traffic leaves your iPhone, nothing is routed through a server, and your browsing is untouched. The tunnel is only a loopback bridge to this device, and your pairing file is what authenticates the session.")
                }
                Section("Apps that can open the tunnel") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LocalDevVPN").font(.body.weight(.semibold))
                        Text("Opens the loopback tunnel WorkSlop detects.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("WorkSlop only detects the tunnel; it never sees or routes your internet traffic.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("VPN tunnel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
