import SwiftUI
import UIKit

/// Icon Themes: the iOS 18 icon pack by catwithabaloon (Light / Dark /
/// Tinted), delivered the way the desktop delivers it — as WebClip
/// folders in HomeDomain (`Library/WebClips/WorkSlop_<bundleID>,<name>
/// .webclip/` with an `Info.plist` + `icon.png` per app). The original
/// app icons are never touched; iOS shows the clip as an extra Home
/// Screen icon that opens the real app.
///
/// The GoldenNugget engine has no icon-theme spec (upstream never
/// ported it), but its payload machinery is generic: a `TweakPayload`
/// is any bytes at any domain/path, the iOS 26 MBDB writer synthesises
/// the `.webclip` directory rows itself, and the iOS 27 injector has a
/// measured HomeDomain row shape. So this feature is a payload
/// producer next to the compiler — the delivery path itself (backup,
/// prune, inject, restore) is 100% the engine's, unchanged.
///
/// Performance rules kept from the pre-migration implementation: the
/// per-variant icon lists are filtered ONCE, decoded thumbnails live
/// in an NSCache, and payload building reads only the staged icons'
/// PNGs, once, at apply time.

// MARK: - Pack catalog

struct IOS18Icon: Identifiable {
    let name: String
    let bundleID: String
    let slug: String
    var id: String { slug }
}

enum IconVariant: String, CaseIterable {
    case light = "Light"
    case dark = "Dark"
    case tinted = "Tinted"

    var folder: String { "iOS18Icons/\(rawValue)" }
}

enum IOS18IconCatalog {
    /// Bundle IDs verified against the iTunes lookup for each app
    /// (same table the pre-migration app and the desktop ship).
    static let all: [IOS18Icon] = [
        IOS18Icon(name: "Shortcuts", bundleID: "com.apple.shortcuts", slug: "shortcuts"),
        IOS18Icon(name: "App Store", bundleID: "com.apple.AppStore", slug: "app-store"),
        IOS18Icon(name: "Settings", bundleID: "com.apple.Preferences", slug: "settings"),
        IOS18Icon(name: "Numbers", bundleID: "com.apple.Numbers", slug: "numbers"),
        IOS18Icon(name: "Pages", bundleID: "com.apple.Pages", slug: "pages"),
        IOS18Icon(name: "Keynote", bundleID: "com.apple.Keynote", slug: "keynote"),
        IOS18Icon(name: "Books", bundleID: "com.apple.iBooks", slug: "books"),
        IOS18Icon(name: "Calculator", bundleID: "com.apple.calculator", slug: "calculator"),
        IOS18Icon(name: "Calendar", bundleID: "com.apple.mobilecal", slug: "calendar"),
        IOS18Icon(name: "Camera", bundleID: "com.apple.camera", slug: "camera"),
        IOS18Icon(name: "Music Classical", bundleID: "com.apple.music.classical", slug: "music-classical"),
        IOS18Icon(name: "Clock", bundleID: "com.apple.mobiletimer", slug: "clock"),
        IOS18Icon(name: "Compass", bundleID: "com.apple.compass", slug: "compass"),
        IOS18Icon(name: "Contacts", bundleID: "com.apple.AddressBook", slug: "contacts"),
        IOS18Icon(name: "FaceTime", bundleID: "com.apple.facetime", slug: "facetime"),
        IOS18Icon(name: "Files", bundleID: "com.apple.DocumentsApp", slug: "files"),
        IOS18Icon(name: "Clips", bundleID: "com.apple.clips", slug: "clips"),
        IOS18Icon(name: "Find My", bundleID: "com.apple.findmy", slug: "find-my"),
        IOS18Icon(name: "Fitness", bundleID: "com.apple.Fitness", slug: "fitness"),
        IOS18Icon(name: "GarageBand", bundleID: "com.apple.mobilegarageband", slug: "garageband"),
        IOS18Icon(name: "Health", bundleID: "com.apple.Health", slug: "health"),
        IOS18Icon(name: "Home", bundleID: "com.apple.Home", slug: "home"),
        IOS18Icon(name: "Magnifier", bundleID: "com.apple.Magnifier", slug: "magnifier"),
        IOS18Icon(name: "Mail", bundleID: "com.apple.mobilemail", slug: "mail"),
        IOS18Icon(name: "Maps", bundleID: "com.apple.Maps", slug: "maps"),
        IOS18Icon(name: "Measure", bundleID: "com.apple.measure", slug: "measure"),
        IOS18Icon(name: "Music", bundleID: "com.apple.Music", slug: "music"),
        IOS18Icon(name: "News", bundleID: "com.apple.news", slug: "news"),
        IOS18Icon(name: "Notes", bundleID: "com.apple.mobilenotes", slug: "notes"),
        IOS18Icon(name: "Passwords", bundleID: "com.apple.Passwords", slug: "passwords"),
        IOS18Icon(name: "Phone", bundleID: "com.apple.mobilephone", slug: "phone"),
        IOS18Icon(name: "Photos", bundleID: "com.apple.mobileslideshow", slug: "photos"),
        IOS18Icon(name: "Podcasts", bundleID: "com.apple.podcasts", slug: "podcasts"),
        IOS18Icon(name: "Reminders", bundleID: "com.apple.reminders", slug: "reminders"),
        IOS18Icon(name: "Apple TV Remote", bundleID: "com.apple.TVRemote", slug: "apple-tv-remote"),
        IOS18Icon(name: "Safari", bundleID: "com.apple.mobilesafari", slug: "safari"),
        IOS18Icon(name: "Stocks", bundleID: "com.apple.stocks", slug: "stocks"),
        IOS18Icon(name: "Apple Store", bundleID: "com.apple.store.Jolly", slug: "apple-store"),
        IOS18Icon(name: "Swift Playgrounds", bundleID: "com.apple.Playgrounds", slug: "swift-playgrounds"),
        IOS18Icon(name: "TestFlight", bundleID: "com.apple.TestFlight", slug: "testflight"),
        IOS18Icon(name: "Tips", bundleID: "com.apple.tips", slug: "tips"),
        IOS18Icon(name: "Translate", bundleID: "com.apple.Translate", slug: "translate"),
        IOS18Icon(name: "Voice Memos", bundleID: "com.apple.VoiceMemos", slug: "voice-memos"),
        IOS18Icon(name: "Wallet", bundleID: "com.apple.Passbook", slug: "wallet"),
        IOS18Icon(name: "Watch", bundleID: "com.apple.Bridge", slug: "watch"),
        IOS18Icon(name: "Weather", bundleID: "com.apple.weather", slug: "weather"),
        IOS18Icon(name: "Messages", bundleID: "com.apple.MobileSMS", slug: "messages"),
        IOS18Icon(name: "iMovie", bundleID: "com.apple.iMovie", slug: "imovie"),
        IOS18Icon(name: "Apple Sports", bundleID: "com.apple.sports", slug: "apple-sports"),
        IOS18Icon(name: "TV", bundleID: "com.apple.tv", slug: "tv"),
        IOS18Icon(name: "Shazam", bundleID: "com.shazam.Shazam", slug: "shazam"),
        // Tinted-only entries (the 2.0 pack has 67 tinted PNGs; these
        // five have desktop-verified Apple bundle IDs).
        IOS18Icon(name: "Freeform", bundleID: "com.apple.Freeform", slug: "freeform"),
        IOS18Icon(name: "Journal", bundleID: "com.apple.Journal", slug: "journal"),
        IOS18Icon(name: "Feedback", bundleID: "com.apple.FeedbackAssistant", slug: "feedback"),
        IOS18Icon(name: "Image Playground", bundleID: "com.apple.ImagePlayground", slug: "image-playground"),
        IOS18Icon(name: "Final Cut Camera", bundleID: "com.apple.FinalCutCamera", slug: "final-cut-camera"),
    ]

    static func imageData(slug: String, variant: IconVariant) -> Data? {
        guard let url = Bundle.main.url(forResource: slug, withExtension: "png",
                                        subdirectory: variant.folder)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    static func hasIcon(slug: String, variant: IconVariant) -> Bool {
        Bundle.main.url(forResource: slug, withExtension: "png",
                        subdirectory: variant.folder) != nil
    }

    /// Decoded gallery thumbnails, cached for the whole session —
    /// decoding PNG data on every render was a real source of lag.
    private static let imageCache = NSCache<NSString, UIImage>()

    static func image(slug: String, variant: IconVariant) -> UIImage? {
        let key = "\(variant.rawValue):\(slug)" as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let data = imageData(slug: slug, variant: variant),
              let img = UIImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    /// Per-variant lists, filtered once: an entry without artwork in
    /// a variant never appears in that variant's table (the old page
    /// showed thumbnail-less rows whose tap was a silent no-op).
    static let byVariant: [IconVariant: [IOS18Icon]] = {
        var map: [IconVariant: [IOS18Icon]] = [:]
        for variant in IconVariant.allCases {
            map[variant] = all.filter { hasIcon(slug: $0.slug, variant: variant) }
        }
        return map
    }()
}

// MARK: - Staging

struct StagedIconTheme: Identifiable, Codable, Equatable {
    var bundleID: String
    var appName: String
    var slug: String
    var variant: String

    var id: String { bundleID }
    var iconVariant: IconVariant { IconVariant(rawValue: variant) ?? .light }
}

enum IconThemeStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("icon-themes.json")
    }

    static func load() -> [StagedIconTheme] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([StagedIconTheme].self, from: data)
        else { return [] }
        return entries
    }

    static func save(_ entries: [StagedIconTheme]) {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Staged icon themes, shared by the galleries and the Apply page.
/// Single writer to IconThemeStore.
final class IconThemeStage: ObservableObject {
    @Published private(set) var staged: [StagedIconTheme] = IconThemeStore.load()

    func stagedEntry(bundleID: String) -> StagedIconTheme? {
        staged.first { $0.bundleID == bundleID }
    }

    /// Tap behaviour: staging an icon that is already staged with the
    /// same variant unstages it; a different variant replaces it.
    func toggle(_ icon: IOS18Icon, variant: IconVariant) {
        if let existing = stagedEntry(bundleID: icon.bundleID) {
            remove(bundleID: icon.bundleID)
            if existing.variant != variant.rawValue {
                append(icon, variant: variant)
            }
        } else {
            append(icon, variant: variant)
        }
        IconThemeStore.save(staged)
    }

    func selectAll(variant: IconVariant) {
        for icon in IOS18IconCatalog.byVariant[variant] ?? [] {
            if stagedEntry(bundleID: icon.bundleID)?.variant != variant.rawValue {
                remove(bundleID: icon.bundleID)
                append(icon, variant: variant)
            }
        }
        IconThemeStore.save(staged)
    }

    func remove(bundleID: String) {
        staged.removeAll { $0.bundleID == bundleID }
        IconThemeStore.save(staged)
    }

    func remove(at offsets: IndexSet) {
        staged.remove(atOffsets: offsets)
        IconThemeStore.save(staged)
    }

    private func append(_ icon: IOS18Icon, variant: IconVariant) {
        staged.append(StagedIconTheme(bundleID: icon.bundleID, appName: icon.name,
                                      slug: icon.slug, variant: variant.rawValue))
    }
}

// MARK: - WebClip payloads

enum WebClipPayloads {
    struct Build {
        let payloads: [TweakPayload]
        /// App names whose pack PNG could not be read — reported to
        /// the user, never dropped silently.
        let skipped: [String]
    }

    /// The desktop's `make_webclip_plist`, key for key (the shape
    /// Cowabunga established and the desktop ships, device-proven on
    /// 26.6.1). XML format, like the desktop's plistlib FMT_XML.
    static func webClipPlist(bundleID: String, displayName: String) -> Data? {
        let info: [String: Any] = [
            "ApplicationBundleIdentifier": bundleID,
            "ApplicationBundleVersion": 1,
            "ClassicMode": false,
            "ConfigurationIsManaged": false,
            "ContentMode": "UIWebClipContentModeRecommended",
            "FullScreen": true,
            "IconIsPrecomposed": false,
            "IconIsScreenShotBased": false,
            "IgnoreManifestScope": false,
            "IsAppClip": false,
            "Orientations": 0,
            "ScenelessBackgroundLaunch": false,
            "Title": displayName,
            "WebClipStatusBarStyle": "UIWebClipStatusBarStyleDefault",
            "RemovalDisallowed": false,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: info,
                                                   format: .xml, options: 0)
    }

    /// The desktop's `sanitize_display_name`: commas break the
    /// WebClip folder-name pattern (a single comma-separated string)
    /// and path separators would break restore paths — both become
    /// spaces.
    static func sanitize(_ name: String) -> String {
        String(name.map { ($0 == "," || $0 == "/") ? " " : $0 })
    }

    static func build(staged: [StagedIconTheme]) -> Build {
        var payloads: [TweakPayload] = []
        var skipped: [String] = []
        for entry in staged {
            let displayName = sanitize(entry.appName)
            let folder = "Library/WebClips/WorkSlop_\(entry.bundleID),\(displayName).webclip"
            guard let plist = webClipPlist(bundleID: entry.bundleID, displayName: displayName),
                  let icon = IOS18IconCatalog.imageData(slug: entry.slug, variant: entry.iconVariant)
            else {
                skipped.append(entry.appName)
                continue
            }
            payloads.append(TweakPayload(domain: "HomeDomain",
                                         relativePath: "\(folder)/Info.plist",
                                         contents: plist))
            payloads.append(TweakPayload(domain: "HomeDomain",
                                         relativePath: "\(folder)/icon.png",
                                         contents: icon))
        }
        return Build(payloads: payloads, skipped: skipped)
    }
}

// MARK: - Page

/// Icon Themes page: the staged set on top, then one gallery per
/// variant (Light / Dark / Tinted) from the catwithabaloon pack.
/// Tapping a gallery row stages that icon; tapping it again unstages.
struct IconThemesView: View {
    @EnvironmentObject private var iconStage: IconThemeStage

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                if !iconStage.staged.isEmpty {
                    Section {
                        ForEach(iconStage.staged) { entry in
                            HStack(spacing: 12) {
                                iconThumbnail(slug: entry.slug, variant: entry.iconVariant)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.appName)
                                    Text(entry.variant)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .onDelete { iconStage.remove(at: $0) }
                    } header: {
                        Text("Staged (\(iconStage.staged.count))")
                    } footer: {
                        Text("Staged icons are sent on the next Apply. Unstaging stops them being sent again; a clip already on the Home Screen can be deleted there like any bookmark (long-press it) — these clips are never removal-locked.")
                    }
                }

                ForEach(IconVariant.allCases, id: \.self) { variant in
                    Section {
                        ForEach(IOS18IconCatalog.byVariant[variant] ?? []) { icon in
                            galleryRow(icon, variant: variant)
                        }
                    } header: {
                        HStack {
                            Text(variant.rawValue)
                            Spacer()
                            Button("Select All") { iconStage.selectAll(variant: variant) }
                                .font(.subheadline)
                                .textCase(nil)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Icon Themes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func galleryRow(_ icon: IOS18Icon, variant: IconVariant) -> some View {
        let staged = iconStage.stagedEntry(bundleID: icon.bundleID)
        let isStagedHere = staged?.variant == variant.rawValue
        return Button {
            iconStage.toggle(icon, variant: variant)
        } label: {
            HStack(spacing: 12) {
                iconThumbnail(slug: icon.slug, variant: variant)
                VStack(alignment: .leading, spacing: 2) {
                    Text(icon.name)
                        .foregroundStyle(.primary)
                    Text(icon.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isStagedHere {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if staged != nil {
                    Text(staged?.variant ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("icon-theme-\(variant.rawValue)-\(icon.slug)")
    }

    private func iconThumbnail(slug: String, variant: IconVariant) -> some View {
        Group {
            if let image = IOS18IconCatalog.image(slug: slug, variant: variant) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
