import SwiftUI

/// Status Bar: the GoldenNugget status-bar override engine, exposed.
///
/// Every control edits a `StatusBarSelection` — the same model the desktop
/// presets use — and the page saves it through `StatusBarPreferences`
/// after every change. Apply reads the stored selection back and hands
/// it to the engine, which writes the classic status bar struct on
/// iOS 26 and the overrides archive on iOS 27.
struct StatusBarView: View {
    @State private var selection: StatusBarSelection

    init() {
        var loaded = StatusBarSelection()
        if let stored = StatusBarPreferences.storedSelection() {
            loaded.restore(from: stored)
        }
        _selection = State(initialValue: loaded)
    }

    private func persist() {
        StatusBarPreferences.save(selection.stored)
    }

    private func fieldBinding(_ key: StatusBarOverrides.FieldKey)
        -> Binding<StatusBarOverrides.Field> {
        Binding(
            get: { selection.overrides.field(for: key) },
            set: { newValue in
                selection.overrides.set(newValue, for: key)
                persist()
            })
    }

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                Section {
                    Toggle("Enable status bar overrides", isOn: $selection.enabled)
                        .onChange(of: selection.enabled) { _, _ in persist() }
                    Toggle("Silly mode — show every item", isOn: $selection.overrides.sillyMode)
                        .onChange(of: selection.overrides.sillyMode) { _, _ in persist() }
                } header: {
                    Text("Status Bar Overrides")
                } footer: {
                    Text("Overrides ride along with the next Apply run — nothing is sent from this page alone. iOS 26 receives the classic status bar struct, iOS 27 the overrides archive.")
                }

                Section("Carrier") {
                    textRow("Carrier name", .carrierName, prompt: "Carrier")
                    networkRow("Data network type", .dataNetworkType)
                    barsRow("Signal bars", .signalBars, range: 0...4)
                    textRow("Service badge", .serviceBadge, prompt: "Badge")
                    shownRow("Cellular service shown", .cellularServiceShown)
                }

                Section("Secondary Carrier") {
                    textRow("Carrier name", .secondaryCarrierName, prompt: "Carrier")
                    networkRow("Data network type", .secondaryDataNetworkType)
                    barsRow("Signal bars", .secondarySignalBars, range: 0...4)
                    textRow("Service badge", .secondaryServiceBadge, prompt: "Badge")
                }

                Section("Text and Battery") {
                    textRow("Time text", .timeText, prompt: "9:41")
                    textRow("Date text", .dateText, prompt: "Date")
                    textRow("Breadcrumb", .breadcrumb, prompt: "‹ App")
                    textRow("Battery detail", .batteryDetail, prompt: "100%")
                    barsRow("Battery capacity", .batteryCapacity, range: 0...100)
                    barsRow("Wi-Fi bars", .wifiBars, range: 0...3)
                }

                Section {
                    Toggle("Show raw signal number", isOn: $selection.overrides.rawSignalShown)
                        .onChange(of: selection.overrides.rawSignalShown) { _, _ in persist() }
                    Toggle("Show raw Wi-Fi signal number", isOn: $selection.overrides.rawWifiSignalShown)
                        .onChange(of: selection.overrides.rawWifiSignalShown) { _, _ in persist() }
                } header: {
                    Text("Raw Signal")
                } footer: {
                    Text("Replaces the signal bars with the raw numeric value, the way field-test mode shows it.")
                }

                Section {
                    ForEach(StatusBarItem.allCases, id: \.self) { item in
                        itemRow(item)
                    }
                } header: {
                    Text("Items")
                } footer: {
                    Text("Stock leaves an item alone. Shown and Hidden force the item on or off. On iOS 27 the item list is ignored — the archive cannot carry it — and only the fields above are delivered.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Status Bar")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Rows

    private func textRow(_ title: String, _ key: StatusBarOverrides.FieldKey,
                         prompt: String) -> some View {
        let field = fieldBinding(key)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: field.set)
            if field.wrappedValue.set {
                TextField(prompt, text: field.text)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
        }
    }

    private func barsRow(_ title: String, _ key: StatusBarOverrides.FieldKey,
                         range: ClosedRange<Int>) -> some View {
        let field = fieldBinding(key)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: field.set)
            if field.wrappedValue.set {
                Stepper(value: field.value, in: range) {
                    Text("\(field.wrappedValue.value)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The named steps are the desktop-verified fake-network values
    /// (11 = 5G, 12 = 5G+, 13 = 5G UW, 14 = 5G UC); the stepper keeps
    /// every other raw value reachable without inventing names for it.
    private func networkRow(_ title: String, _ key: StatusBarOverrides.FieldKey) -> some View {
        let field = fieldBinding(key)
        let named: [(String, Int)] = [("5G", 11), ("5G+", 12), ("5G UW", 13), ("5G UC", 14)]
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: field.set)
            if field.wrappedValue.set {
                Picker("Type", selection: field.value) {
                    ForEach(named, id: \.1) { name, value in
                        Text(name).tag(value)
                    }
                    if !named.contains(where: { $0.1 == field.wrappedValue.value }) {
                        Text("Raw \(field.wrappedValue.value)").tag(field.wrappedValue.value)
                    }
                }
                .pickerStyle(.segmented)
                Stepper(value: field.value, in: 0...30) {
                    Text("Raw value: \(field.wrappedValue.value)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func shownRow(_ title: String, _ key: StatusBarOverrides.FieldKey) -> some View {
        let field = fieldBinding(key)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: field.set)
            if field.wrappedValue.set {
                Toggle("Shown", isOn: Binding(
                    get: { field.wrappedValue.value != 0 },
                    set: { on in
                        var edited = field.wrappedValue
                        edited.value = on ? 1 : 0
                        field.wrappedValue = edited
                    }))
            }
        }
    }

    private func itemRow(_ item: StatusBarItem) -> some View {
        let current = selection.overrides.itemShown[item]
        return Picker(item.title, selection: Binding(
            get: { current == nil ? 0 : (current! ? 1 : 2) },
            set: { choice in
                switch choice {
                case 1: selection.overrides.itemShown[item] = true
                case 2: selection.overrides.itemShown[item] = false
                default: selection.overrides.itemShown[item] = nil
                }
                persist()
            })) {
            Text("Stock").tag(0)
            Text("Shown").tag(1)
            Text("Hidden").tag(2)
        }
        .pickerStyle(.menu)
    }
}

/// What the All Tweaks list shows on the Status Bar row: how many
/// overrides the stored selection carries, or 0 when it is off.
enum StatusBarGroupHelper {
    static var activeCount: Int {
        guard let stored = StatusBarPreferences.storedSelection(), stored.enabled else { return 0 }
        var selection = StatusBarSelection()
        selection.restore(from: stored)
        return selection.overrides.activeCount
    }
}
