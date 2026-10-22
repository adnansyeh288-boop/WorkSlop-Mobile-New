import SwiftUI

/// Live preview at the top of the Liquid Glass page (owner's design,
/// 2026-10-22): a blue wallpaper card holding ONE notification
/// banner. The banner mirrors the REAL staged tweaks — it is a live
/// readout of the staging state, never a static picture:
///
/// - Force Solarium Fallback staged (`lg-force-fallback` or
///   `lg-ui-force-fallback`) → Liquid Glass is disabled: the banner
///   turns flat grey, exactly the disabled look, and the card's
///   "Liquid Glass Enable/Disable" title greys out with it. This
///   happens the moment the toggle is staged — no Apply, no restart.
/// - White Glass Highlight staged (`lg-highlight-white`) → a bright
///   white reflection appears on the banner's edge.
/// - Solarium Text Frost staged (`lg-text-frost`) → the banner's
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

            banner
                .padding(.horizontal, 14)
        }
        .frame(height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: selection.staged)
        .accessibilityIdentifier("lg-preview")
    }

    /// The notification banner itself. Only its material changes
    /// with the staged tweaks — glass, frosted, or the flat grey of
    /// disabled Liquid Glass.
    private var banner: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.45, blue: 0.95),
                                 Color(red: 0.35, green: 0.65, blue: 1.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("WorkSlop")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("now")
                        .font(.caption2)
                        .foregroundStyle(disabled ? Color(white: 0.45) : .secondary)
                }
                Text("This notification uses Liquid Glass.")
                    .font(.subheadline)
                    .lineLimit(2)
            }
            .foregroundStyle(disabled ? Color(white: 0.25) : Color.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(disabled ? AnyShapeStyle(Color(white: 0.83))
                      : frosted ? AnyShapeStyle(.regularMaterial)
                      : AnyShapeStyle(.ultraThinMaterial))
        }
        .overlay {
            if !disabled {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(highlight ? 0.95 : 0.55),
                                  lineWidth: highlight ? 1.4 : 1)
            }
        }
        .overlay {
            // The highlight tweak's reflection: a white sheen
            // pooled at the banner's top edge.
            if highlight && !disabled {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
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
