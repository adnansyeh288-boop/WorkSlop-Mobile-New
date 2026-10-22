import SwiftUI

/// Live preview at the top of the Liquid Glass page (owner's design,
/// 2026-10-22): a blue wallpaper card with one glass pill in the
/// middle that reads "Liquid Glass Preview". The pill mirrors three
/// REAL staged tweaks — it is a readout of the staging state, never
/// a decoration that pretends:
///
/// - Force Solarium Fallback staged (`lg-force-fallback` or
///   `lg-ui-force-fallback`) → the glass is off: the pill goes flat
///   grey and the card's "Liquid Glass Enable/Disable" title greys
///   out with it.
/// - White Glass Highlight staged (`lg-highlight-white`) → a bright
///   white reflection appears on the pill's edge.
/// - Solarium Text Frost staged (`lg-text-frost`) → the pill's
///   material turns thick and frosted.
struct LiquidGlassPreviewCard: View {
    @EnvironmentObject private var selection: SelectionStore

    static func isDisabled(_ selection: SelectionStore) -> Bool {
        selection.isOn("lg-force-fallback") || selection.isOn("lg-ui-force-fallback")
    }

    private var disabled: Bool { Self.isDisabled(selection) }
    private var highlight: Bool { selection.isOn("lg-highlight-white") }
    private var frosted: Bool { selection.isOn("lg-text-frost") }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.13, green: 0.42, blue: 0.88),
                            Color(red: 0.35, green: 0.62, blue: 0.97),
                            Color(red: 0.66, green: 0.82, blue: 0.99),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // Soft wallpaper light, like a blurred photo backdrop.
            Circle()
                .fill(.white.opacity(0.20))
                .frame(width: 190, height: 190)
                .blur(radius: 30)
                .offset(x: -110, y: -60)
            Circle()
                .fill(Color(red: 0.55, green: 0.80, blue: 1.0).opacity(0.35))
                .frame(width: 170, height: 170)
                .blur(radius: 28)
                .offset(x: 120, y: 55)

            pill
        }
        .frame(height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("lg-preview")
    }

    private var pill: some View {
        Text("Liquid Glass Preview")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(disabled ? Color(white: 0.32) : Color.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background {
                if disabled {
                    Capsule().fill(Color(red: 0.79, green: 0.79, blue: 0.79))
                } else if frosted {
                    Capsule().fill(.regularMaterial)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay {
                if !disabled {
                    Capsule()
                        .strokeBorder(.white.opacity(highlight ? 0.95 : 0.55),
                                      lineWidth: highlight ? 1.4 : 1)
                }
            }
            .overlay {
                // The highlight tweak's reflection: a white sheen
                // pooled at the pill's top edge.
                if highlight && !disabled {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.55), .white.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}
