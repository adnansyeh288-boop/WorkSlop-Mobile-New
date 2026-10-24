import SwiftUI

/// White Glass Highlight: the white point is a NUMBER (0.0–1.0, in
/// 0.05 steps, as the spec's own bounds say) — the same shape as the
/// Flat Square Corners page. It used to render as a plain toggle, so
/// every apply wrote the registry default 1.0 whatever the user
/// wanted; this page is what makes the number reachable.
///
/// The value lives in `HighlightWhiteStore`; the selection builder
/// overrides the spec's registry default with it at apply time. The
/// enable switch is the ordinary staged toggle, so the tweak stages,
/// persists and counts exactly like every other feature.
struct HighlightWhiteView: View {
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var status: StatusStore
    @State private var value: Double = HighlightWhiteStore.value

    private let featureID = "lg-highlight-white"

    private var enabled: Binding<Bool> {
        Binding(
            get: { selection.isOn(featureID) },
            set: { selection.set(featureID, $0) })
    }

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                Section {
                    Toggle("Enable white glass highlight", isOn: enabled)
                        .disabled(!status.unlocked)
                    HStack {
                        Text("White point")
                        Spacer()
                        Text(String(format: "%.2f", value))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $value,
                           in: HighlightWhiteStore.range,
                           step: HighlightWhiteStore.step)
                        .disabled(!status.unlocked)
                        .accessibilityIdentifier("highlight-white-slider")
                        .onChange(of: value) { _, new in
                            HighlightWhiteStore.value = new
                        }
                } header: {
                    Text("White Glass Highlight")
                } footer: {
                    Text("White point of the glass highlight, 0.0–1.0 in 0.05 steps. 1.0 is full white (the stock value). The value is saved as you move the slider and is written with the next Apply.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("White Glass Highlight")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { value = HighlightWhiteStore.value }
    }
}
