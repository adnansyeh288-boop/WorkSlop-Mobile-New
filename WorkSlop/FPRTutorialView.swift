import SwiftUI

/// The Force Partial Restore tutorial sheet.
///
/// Shown before every FPR run (the Apply run button presents it
/// first and only starts the run on confirm), and on demand from
/// the "How it works" button under the method picker. The steps
/// are plain facts about what the method does — no backup first,
/// only the tweaks' locations (plus, for the import variant, the
/// picked package's domains) are restored, and files outside the
/// restore are not deleted.
///
/// Continue stays disabled until the "I understand" toggle is
/// on. The view itself never starts anything: `onConfirm` /
/// `onCancel` hand the decision back to `ApplyView`, which owns
/// the sheet's presentation state and the run.
struct FPRTutorialView: View {
    let method: ApplyMethod
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var understood = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(method == .forcePartialRestoreImport
                         ? "Force Partial Restore + Import Backup skips the protective backup: a small backup is built on this phone and restored directly."
                         : "Force Partial Restore skips the protective backup: a small backup is built on this phone and restored directly.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("How it works")
                }

                Section {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Label(step, systemImage: "\(index + 1).circle")
                    }
                } header: {
                    Text("Steps")
                }

                Section {
                    Toggle("I understand", isOn: $understood)
                        .accessibilityIdentifier("fpr-tutorial-understand")
                }

                Section {
                    Button("Continue") { onConfirm() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(!understood)
                        .accessibilityIdentifier("fpr-tutorial-continue")
                    Button("Cancel", role: .cancel) { onCancel() }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("fpr-tutorial-cancel")
                }
            }
            .navigationTitle(method.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }

    /// The numbered steps, in order. The import variant inserts
    /// its merge step after step 2 and widens step 3 to cover the
    /// package's domains as well as the tweaks' locations.
    private var steps: [String] {
        let first = "First, the usual checks: Find My iPhone OFF, VPN tunnel running, pairing file imported."
        let second = "WorkSlop builds a small backup on this phone containing ONLY your staged tweaks. No backup of your data is taken first — that is what makes this fast, and why there is nothing to roll back to."
        let restore = "The phone restores that small backup. This should take minutes, not the long protective backup of the Normal Method."
        let reboot = "Afterwards, reboot the phone so the tweaks take effect. Removal uses the Normal Method only: if you want to be able to remove these tweaks, make a backup with Get Backup File before you apply — applying with Force Partial Restore without a backup made before applying means those tweaks cannot be removed afterwards."
        if method == .forcePartialRestoreImport {
            return [
                first,
                second,
                "The backup package you picked is merged in: its data files restore together with the tweaks. In the domains the package carries, the phone's current data is replaced by the package's copies.",
                "Only the locations your tweaks write to, plus the domains inside the package, are included. Photos, health data and app data are not in it, and files that are not part of this restore are NOT deleted.",
                restore,
                reboot,
            ]
        }
        return [
            first,
            second,
            "Only the locations your tweaks write to are included. Photos, health data and app data are not in it, and files that are not part of this restore are NOT deleted.",
            restore,
            reboot,
        ]
    }
}
