import SwiftUI

/// All Tweaks: one row per tweak group. Tapping a row opens that
/// group's tweak options as a plain list.
struct AllTweaksView: View {
    private let groups: [TweakGroup] = [
        TweakGroup(id: "Liquid Glass", icon: "sparkles",
                   footer: "Partial restore on iOS 26; on iOS 27 a protective backup is taken first, then the modified backup is restored."),
        TweakGroup(id: "SpringBoard", icon: "square.grid.2x2", footer: nil),
        TweakGroup(id: "Daemons", icon: "gearshape.2",
                   footer: "Daemon toggles stage the same disabled-daemons list the desktop manages."),
        TweakGroup(id: "Recommended", icon: "star",
                   footer: "The desktop one-tap Recommended analytics set, as individual switches."),
        TweakGroup(id: "Apple Internal", icon: "hammer", footer: nil),
        TweakGroup(id: "PosterBoard", icon: "rectangle.on.rectangle", footer: nil),
    ]

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                ForEach(groups) { group in
                    NavigationLink {
                        TweakListView(group: group)
                    } label: {
                        HStack {
                            Label {
                                Text(group.id)
                            } icon: {
                                RowIcon(name: group.icon)
                            }
                            Spacer()
                            Text("\(group.count)")
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
        FeatureCatalog.features(in: catalogSection).count
    }
}

/// The tweak options of one group: plain toggles, never sliders.
struct TweakListView: View {
    let group: TweakGroup

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                Section {
                    ForEach(FeatureCatalog.features(in: group.catalogSection)) { feature in
                        FeatureToggleRow(feature: feature)
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
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(group.id)
        .navigationBarTitleDisplayMode(.inline)
    }
}
