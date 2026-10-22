import SwiftUI

/// Flat Square Corners: the corner radius is a NUMBER the user types
/// by hand — the same control the desktop offers (a number field,
/// 0–60), not a fixed toggle. 0 renders the glass corners fully
/// square; larger values round them back toward stock.
///
/// The value lives in `CornerRadiusStore`; the selection builder
/// overrides the spec's registry default with it at apply time. The
/// enable switch is the ordinary staged toggle, so the tweak stages,
/// persists and counts exactly like every other feature.
struct CornerRadiusView: View {
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var status: StatusStore
    @State private var value: Int = CornerRadiusStore.value
    @State private var text: String = String(CornerRadiusStore.value)

    private let featureID = "lg-corner-radius"

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
                    Toggle("Enable corner radius", isOn: enabled)
                        .disabled(!status.unlocked)
                    HStack {
                        Text("Corner radius")
                        Spacer()
                        TextField("0", text: $text)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: text) { _, new in
                                let digits = new.filter(\.isNumber)
                                if digits != new { text = digits }
                                if let n = Int(digits) { commit(n) }
                            }
                        Stepper("", value: $value, in: CornerRadiusStore.range, step: 1)
                            .labelsHidden()
                            .onChange(of: value) { _, new in
                                text = String(new)
                                commit(new)
                            }
                    }
                    .disabled(!status.unlocked)
                } header: {
                    Text("Liquid Glass Corner Radius")
                } footer: {
                    Text("Type the radius by hand or use the stepper (0–60). 0 = fully square corners. The value is saved as you type and is written with the next Apply, together with the SolariumInsetsAndCornerRadiusEnabled flag — the same pair the desktop writes.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Flat Square Corners")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func commit(_ n: Int) {
        let clamped = CornerRadiusStore.range.contains(n) ? n : (n < 0 ? 0 : 60)
        value = clamped
        CornerRadiusStore.value = clamped
    }
}
