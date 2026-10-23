import SwiftUI

/// The two-slider navigation (owner's design, 2026-10-22): the old
/// All Tweaks menu is gone. A glass slider under each page's header
/// carries the top group (Home, Liquid Glass, Recommend, SpringBoard,
/// Icon Themes) and a floating glass slider at the bottom carries
/// Icon Themes, Apple Internal, Status Bar, Daemons, PosterBoard.
///
/// This file is pure chrome: it switches which EXISTING page is on
/// screen. Every page keeps its own SkyBackground and its own stores;
/// no engine, staging, or apply code lives here.
enum MainPage: Hashable, CaseIterable {
    case home
    case liquidGlass
    case recommend
    case springBoard
    case iconThemes
    case appleInternal
    case statusBar
    case daemons
    case posterBoard

    var title: String {
        switch self {
        case .home: return "Home"
        case .liquidGlass: return "Liquid Glass"
        case .recommend: return "Recommend"
        case .springBoard: return "SpringBoard"
        case .iconThemes: return "Icon Themes"
        case .appleInternal: return "Apple Internal"
        case .statusBar: return "Status Bar"
        case .daemons: return "Daemons"
        case .posterBoard: return "PosterBoard"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .liquidGlass: return "sparkles"
        case .recommend: return "star.fill"
        case .springBoard: return "square.grid.2x2"
        case .iconThemes: return "apps.iphone"
        case .appleInternal: return "hammer"
        case .statusBar: return "antenna.radiowaves.left.and.right"
        case .daemons: return "gearshape.2"
        case .posterBoard: return "rectangle.on.rectangle"
        }
    }

    /// The catalog group this page renders (nil for the pages that
    /// are not catalog lists: Home, Icon Themes, Status Bar). Group
    /// values mirror AllTweaksView's menu definitions exactly.
    var tweakGroup: TweakGroup? {
        switch self {
        case .liquidGlass:
            return TweakGroup(id: "Liquid Glass", icon: "sparkles",
                              footer: "Partial restore on iOS 26; on iOS 27 a protective backup is taken first, then the modified backup is restored.")
        case .recommend:
            return TweakGroup(id: "Recommended", icon: "star",
                              footer: "The desktop one-tap Recommended analytics set, as individual switches.")
        case .springBoard:
            return TweakGroup(id: "SpringBoard", icon: "square.grid.2x2", footer: nil)
        case .appleInternal:
            return TweakGroup(id: "Apple Internal", icon: "hammer", footer: nil)
        case .daemons:
            return TweakGroup(id: "Daemons", icon: "gearshape.2",
                              footer: "Daemon toggles stage the same disabled-daemons list the desktop manages.")
        case .posterBoard:
            return TweakGroup(id: "PosterBoard", icon: "rectangle.on.rectangle", footer: nil)
        case .home, .iconThemes, .statusBar:
            return nil
        }
    }

    static let topGroup: [MainPage] = [.home, .liquidGlass, .recommend, .springBoard, .iconThemes]
    static let bottomGroup: [MainPage] = [.iconThemes, .appleInternal, .statusBar, .daemons, .posterBoard]
}

/// Clearances so a page's list can scroll under the floating header
/// and bottom slider without its first/last rows hiding behind them.
enum ShellInsets {
    static let top: CGFloat = 108
    static let bottom: CGFloat = 84
}

/// Applies the shell clearances to a page's List, only when the page
/// is embedded in the slider shell (pushed copies keep stock layout).
struct ShellListInsets: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .safeAreaInset(edge: .top) { Color.clear.frame(height: ShellInsets.top) }
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: ShellInsets.bottom) }
        } else {
            content
        }
    }
}

/// One glass slider bar. The selected page is a white pill with
/// black text (iOS 26 style); the rest are dark-blue labels on the
/// glass. The pill is ONE shape shared by every item through a
/// matched-geometry effect: on a page change it stretches and
/// springs into its new item like a liquid-glass bubble instead of
/// blinking out in one place and in at another. Items are compact
/// (owner's fix, 2026-10-22: the first three — Recommend on top,
/// Status Bar below — must never be clipped on Home) and the bar
/// still scrolls horizontally, keeping the selection in view.
struct SliderBar: View {
    let pages: [MainPage]
    @Binding var selection: MainPage
    @Namespace private var pillNS

    /// The liquid spring: quick response, low damping — the pill
    /// overshoots a touch and settles, like glass finding its shape.
    private var liquidSpring: Animation {
        .spring(response: 0.45, dampingFraction: 0.68)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(pages, id: \.self) { page in
                        Button {
                            selection = page
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: page.icon)
                                    .font(.footnote.weight(.semibold))
                                Text(page.title)
                                    .font(.footnote.weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background {
                                if selection == page {
                                    Capsule()
                                        .fill(.white)
                                        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                                        .matchedGeometryEffect(id: "slider-pill", in: pillNS)
                                }
                            }
                            .foregroundStyle(selection == page
                                             ? Color.black
                                             : Color(red: 0.07, green: 0.23, blue: 0.38))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(page)
                        .accessibilityIdentifier("slider-\(page.title)")
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
                .animation(liquidSpring, value: selection)
            }
            .onChange(of: selection) { newValue in
                withAnimation(liquidSpring) { proxy.scrollTo(newValue, anchor: .center) }
            }
            .onAppear {
                proxy.scrollTo(selection, anchor: .center)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(.white.opacity(0.65), lineWidth: 1)
                )
                .shadow(color: .blue.opacity(0.16), radius: 10, y: 4)
        }
    }
}

/// Mounts a page's heavy content a beat AFTER the page itself is on
/// screen, so a page switch's cross-fade starts with only the page's
/// SkyBackground and the shell chrome animating.
///
/// Every slider page is `ZStack { SkyBackground; List }`: the List's
/// first body build (rows, thumbnails, preview cards) used to land
/// synchronously inside the transition's first frame — on the main
/// thread, while the outgoing page (Home, the heaviest: a scroll
/// view full of material cards) was also still rendering — and the
/// fade stuttered from its first frames, worst leaving Home
/// (owner's report, 2026-10-23). With the content mounted ~40 ms
/// in, the page is still nearly transparent, so the content joins
/// the fade already in progress instead of stalling it; the
/// background and chrome are untouched and carry the switch from
/// frame one. The delay is all this does — no content is altered,
/// cached, or kept resident.
struct DeferredMount: ViewModifier {
    @State private var mounted = false

    func body(content: Content) -> some View {
        Group {
            if mounted {
                content
            } else {
                Color.clear
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            mounted = true
        }
    }
}

extension View {
    /// See `DeferredMount`: mount this content one beat after its
    /// page, so a page transition never pays its first-build cost.
    func deferredMount() -> some View {
        modifier(DeferredMount())
    }
}

/// Page header for the slider pages: a white circle with a black
/// chevron (iOS 26 style) returns to Home; the title is centered.
struct PageHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.title3.weight(.bold))
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 38, height: 38)
                        .background {
                            Circle()
                                .fill(.white)
                                .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("page-back")
                Spacer()
            }
        }
        .frame(height: 44)
    }
}

/// The floating chrome over a slider page: header + top slider at
/// the top, bottom slider at the bottom. The page itself (with its
/// own SkyBackground) shows through everywhere else.
struct ShellChrome: View {
    let title: String
    @Binding var page: MainPage

    var body: some View {
        VStack(spacing: 10) {
            PageHeader(title: title) { page = .home }
            SliderBar(pages: MainPage.topGroup, selection: $page)
            Spacer()
            SliderBar(pages: MainPage.bottomGroup, selection: $page)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}
