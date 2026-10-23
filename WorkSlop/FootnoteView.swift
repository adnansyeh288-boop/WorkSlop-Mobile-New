import SwiftUI

/// Lock Screen Footnote: a line of text the user types, shown at
/// the bottom of the lock screen.
///
/// The mechanism is Nugget's (FileLocation.footnote): the string is
/// written as `LockScreenFootnote` into
/// `SharedDeviceConfiguration.plist` on the configuration-profiles
/// shared container. The text lives in `FootnoteStore`; the
/// selection builder overrides the spec's staged string with it at
/// apply time, the same pattern the corner radius uses.
///
/// Saving is what stages: saving a non-empty text stages the
/// feature, saving an empty field un-stages it, so the staged set
/// always matches the text the user last saved — there is no
/// separate enable switch to drift out of sync with the text.
struct FootnoteView: View {
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var status: StatusStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = FootnoteStore.text

    private let featureID = "sb-lock-screen-footnote"

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                Section {
                    HStack {
                        TextField("Footnote text", text: $text)
                            .accessibilityIdentifier("footnote-text-field")
                        // The explicit save (owner's ask, 2026-10-23):
                        // the same round checkmark button the corner
                        // radius editor uses — saving commits the
                        // text and stages (or un-stages) the feature,
                        // so "saved" is a thing the user did.
                        Button(action: saveAndDismiss) {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background { Circle().fill(Color.accentColor) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("footnote-save")
                        .accessibilityLabel("Save footnote")
                    }
                    .disabled(!status.unlocked)
                } header: {
                    Text("Lock Screen Footnote")
                } footer: {
                    Text("Shown at the bottom of the lock screen (LockScreenFootnote in SharedDeviceConfiguration.plist). Type the text and tap the round checkmark to save it — a saved text stages the footnote for the next Apply; clearing the field and saving un-stages it again. The text itself stays saved on this phone until you overwrite it.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Lock Screen Footnote")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Commit the field to the store, stage or un-stage the feature
    /// to match it (whitespace alone is not a footnote), and leave.
    private func saveAndDismiss() {
        FootnoteStore.text = text
        selection.set(featureID,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        dismiss()
    }
}
