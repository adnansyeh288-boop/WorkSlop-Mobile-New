import SwiftUI

/// All Tweaks: one row per tweak group. Tapping a row opens that
/// group's tweak options as a plain list.
struct AllTweaksView: View {
    private let groups: [TweakGroup] = [
        TweakGroup(id: "Liquid Glass", icon: "sparkles",
                   footer: "Partial restore on iOS 26; on iOS 27 a protective backup is taken first, then the modified backup is restored."),
        TweakGroup(id: "Status Bar", icon: "antenna.radiowaves.left.and.right",
                   footer: "Carrier name, fake 5G, signal bars, custom time text and per-item show/hide — written by the status bar override engine and delivered with Apply."),
        TweakGroup(id: "SpringBoard", icon: "square.grid.2x2", footer: nil),
        TweakGroup(id: "Daemons", icon: "gearshape.2",
                   footer: "Daemon toggles stage the same disabled-daemons list the desktop manages."),
        TweakGroup(id: "Recommended", icon: "star",
                   footer: "The desktop one-tap Recommended analytics set, as individual switches."),
        TweakGroup(id: "Apple Internal", icon: "hammer", footer: nil),
        TweakGroup(id: "PosterBoard", icon: "rectangle.on.rectangle", footer: nil),
        TweakGroup(id: "Custom Icons", icon: "apps.iphone",
                   footer: "The iOS 18 icon pack by catwithabaloon, delivered as Home Screen web clips — the original app icons are never modified."),
    ]

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                ForEach(groups) { group in
                    NavigationLink {
                        if group.id == "Custom Icons" {
                            IconThemesView()
                        } else if group.id == "Status Bar" {
                            StatusBarView()
                        } else {
                            TweakListView(group: group)
                        }
                    } label: {
                        HStack {
                            Label {
                                Text(group.id)
                            } icon: {
                                RowIcon(name: group.icon)
                            }
                            Spacer()
                            Text("\(group.id == "Status Bar" ? StatusBarGroupHelper.activeCount : group.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("tweak-group-\(group.id)")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("All Tweaks")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TweakGroup: Identifiable, Hashable {
    let id: String
    let icon: String
    let footer: String?

    /// The catalog section this row reads. The menu label stays
    /// user-facing ("Apple Internal"); the catalog calls it
    /// "Internal Options".
    var catalogSection: String {
        id == "Apple Internal" ? "Internal Options" : id
    }

    var count: Int {
        if id == "Custom Icons" { return IOS18IconCatalog.all.count }
        return FeatureCatalog.features(in: catalogSection).count
    }
}

/// The tweak options of one group: plain toggles, never sliders.
/// `embedded` is set when the view is a page of the slider shell:
/// the shell's floating chrome owns the title then, and the list
/// gains clearances so rows never hide behind the sliders.
struct TweakListView: View {
    let group: TweakGroup
    var embedded = false
    @EnvironmentObject private var selection: SelectionStore
    /// The corner-radius number the Flat Square Corners row shows.
    /// The store is UserDefaults, which nothing observes, so a body
    /// that read it directly kept showing the pre-edit value after
    /// the editor popped back — the tweak looked unsaved when it
    /// was saved all along. Refreshed from the store on every
    /// appear, which includes the pop back from the editor.
    @State private var cornerRadiusShown = CornerRadiusStore.value
    /// The saved Lock Screen Footnote text, refreshed on appear for
    /// the same reason as the corner radius above — the store is
    /// UserDefaults, which nothing observes.
    @State private var footnoteShown = FootnoteStore.text
    /// The saved white-point value, refreshed on appear for the same
    /// reason as the two stores above.
    @State private var highlightWhiteShown = HighlightWhiteStore.value
    /// The PosterBoard apply mode, mirrored from
    /// `PosterBoardApplyModeSettings` (UserDefaults, unobserved like
    /// the stores above) so the picker on the PosterBoard page shows
    /// the stored value and writes changes straight back.
    @State private var posterBoardMode: PosterBoardApplyMode = PosterBoardApplyModeSettings.current

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                if group.id == "Liquid Glass" {
                    Section {
                        LiquidGlassPreviewCard()
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } header: {
                        Text("Liquid Glass Enable/Disable")
                            .textCase(nil)
                            .foregroundStyle(
                                LiquidGlassPreviewCard.isDisabled(selection)
                                    ? .secondary : .primary)
                    }
                }
                Section {
                    ForEach(FeatureCatalog.features(in: group.catalogSection)) { feature in
                        if feature.id == "lg-corner-radius" {
                            // The corner tweak is a number the user
                            // types by hand (as on the desktop), so its
                            // row opens the number page instead of a
                            // plain toggle.
                            NavigationLink {
                                CornerRadiusView()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title)
                                    Text("SolariumCornerRadius = \(cornerRadiusShown) (tap to set the number)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .accessibilityIdentifier("nav-corner-radius")
                        } else if feature.id == "sb-lock-screen-footnote" {
                            // The footnote is text the user types, so
                            // its row opens the text editor instead of
                            // a plain toggle — same shape as the
                            // corner-radius row above.
                            NavigationLink {
                                FootnoteView()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title)
                                    Text(footnoteShown.isEmpty
                                         ? "LockScreenFootnote (tap to set the text)"
                                         : "LockScreenFootnote = \u{201C}\(footnoteShown)\u{201D}")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .accessibilityIdentifier("nav-lock-screen-footnote")
                        } else if feature.id == "lg-highlight-white" {
                            // The white point is a number (0.0–1.0),
                            // so its row opens the number page instead
                            // of a plain toggle — same shape as the
                            // corner-radius row above. As a toggle it
                            // could only ever write the default 1.0.
                            NavigationLink {
                                HighlightWhiteView()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title)
                                    Text("SolariumHighlightWhite = \(String(format: "%.2f", highlightWhiteShown)) (tap to set the number)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .accessibilityIdentifier("nav-highlight-white")
                        } else {
                            FeatureToggleRow(feature: feature)
                        }
                    }
                    if group.id == "PosterBoard" {
                        NavigationLink {
                            PosterBoardFilesView()
                        } label: {
                            Label {
                                Text("PosterBoard files")
                            } icon: {
                                RowIcon(name: "rectangle.on.rectangle")
                            }
                        }
                        .accessibilityIdentifier("nav-posterboard-files")
                    }
                } footer: {
                    if let footer = group.footer { Text(footer) }
                }
                if group.id == "PosterBoard" {
                    // The apply mode is the user's choice — the two
                    // mechanisms install the same wallpapers different
                    // ways, and only "Protective backup" can reset the
                    // store. Until this picker existed the setting had
                    // no UI at all, so the default (AirLift) silently
                    // made every reset fail.
                    Section {
                        Picker("Apply mode", selection: $posterBoardMode) {
                            ForEach(PosterBoardApplyMode.allCases) { mode in
                                Label(mode.title, systemImage: mode.symbol)
                                    .tag(mode)
                            }
                        }
                        .accessibilityIdentifier("posterboard-apply-mode-picker")
                        .onChange(of: posterBoardMode) { _, newValue in
                            PosterBoardApplyModeSettings.current = newValue
                        }
                    } header: {
                        Text("Apply mode")
                    } footer: {
                        Text(posterBoardMode.summary
                             + (posterBoardMode.supportsReset
                                ? " This is the mode that can reset the PosterBoard store."
                                : " A reset needs the \"Protective backup\" mode."))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .modifier(ShellListInsets(enabled: embedded))
            .deferredMount(memoryKey: "tweaklist-\(group.id)")
        }
        .navigationTitle(embedded ? "" : group.id)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            cornerRadiusShown = CornerRadiusStore.value
            footnoteShown = FootnoteStore.text
            highlightWhiteShown = HighlightWhiteStore.value
            posterBoardMode = PosterBoardApplyModeSettings.current
        }
    }
}
