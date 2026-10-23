import CryptoKit
import Foundation

// MARK: - PairingStore (WorkSlop's pairing API over the GN record)
//
// The UI has always talked to a `PairingStore`; what a pairing record
// IS and where it lives is now the backend's answer, not ours:
// `PairingRecord` validates and persists, `AppPaths.pairingFile` is
// the canonical path, and the raw text is remembered in UserDefaults
// under `PairingRecord.Key.stored` for the next launch's bootstrap.
//
// One migration is handled here: installs from the old engine stored
// the record at Documents/pairing.plist. The first read that finds a
// usable record there adopts it into the canonical location, so an
// upgrade does not read as "pairing file lost".

enum PairingStore {
    static var fileURL: URL { AppPaths.pairingFile }

    private static var legacyURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairing.plist")
    }

    static var isImported: Bool { loadRaw() != nil }

    /// SHA-256 of the stored pairing record, or nil when none is
    /// imported. The applied-tweaks record stores this at apply time;
    /// Remove Tweaks compares it before running, because a removal is
    /// only meaningful against the device the recorded pairing reaches
    /// — a removed or replaced pairing file invalidates the record.
    static var fingerprint: String? {
        guard let raw = loadRaw(), let data = raw.data(using: .utf8) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Import a picked file through the backend's acceptance path
    /// (validate → write canonical → read back) and remember it for
    /// the bootstrap. Returns nil on success, or the failure in words.
    static func importFile(at url: URL) -> String? {
        do {
            let record = try PairingRecord.accept(contentsOf: url)
            PairingRecord.persist(record)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The record the bootstrap hands to minimuxer, from the first
    /// source that holds a usable one: canonical file, remembered
    /// text, legacy file (adopted on the way through).
    static func loadRaw() -> String? {
        if let raw = PairingRecord.onDisk() { return raw }
        if let stored = UserDefaults.standard.string(forKey: PairingRecord.Key.stored),
           PairingRecord.usable(stored) {
            return stored
        }
        if let raw = try? String(contentsOf: legacyURL, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if PairingRecord.usable(trimmed) {
                try? trimmed.write(to: AppPaths.pairingFile, atomically: true, encoding: .utf8)
                PairingRecord.persist(trimmed)
                return trimmed
            }
        }
        return nil
    }

    static func delete() {
        try? FileManager.default.removeItem(at: AppPaths.pairingFile)
        try? FileManager.default.removeItem(at: legacyURL)
        UserDefaults.standard.removeObject(forKey: PairingRecord.Key.stored)
        UserDefaults.standard.set(true, forKey: PairingRecord.Key.autoImportDisabled)
    }
}

// MARK: - Feature → GN spec mapping
//
// WorkSlop's feature ids are the UI's vocabulary; the engine speaks
// TweakSpec ids. The join was verified key-by-key and label-by-label
// against the imported catalog (see ID-MAPPING.md in the migration
// notes): 60 of 62 features map. `lg-legibility-2` and `custom-icons`
// have no GN counterpart and are no longer in the catalog.

enum GNMapping {
    static let specIDsByFeature: [String: [String]] = [
        // Liquid Glass (by plist key)
        "lg-disallow-clock": ["NoLiquidClock"],
        "lg-disable-dock": ["NoLiquidDock"],
        "lg-flat-icons": ["UseFlatIconsEverywhere"],
        "lg-disable-widget-specular": ["DisableWidgetSpecular"],
        "lg-disable-dock-specular": ["DisableDockSpecular"],
        "lg-disable-folder-specular": ["DisableFolderSpecular"],
        "lg-exclude-clear-shadows": ["ExcludeClearGlassShadows"],
        "lg-disable-refraction": ["DisableOuterRefraction"],
        "lg-disable-hdr": ["DisableSolariumHDR"],
        "lg-disable-specular-motion": ["DisableSpecularMotion"],
        "lg-disable-specular-everywhere": ["DisableSpecularEverywhere"],
        "lg-blurr-motion": ["SolariumIncreasedDiffusion"],
        "lg-disallow-lockscreen": ["DisallowGlassLockScreen"],
        "lg-ios18-lockscreen-look": ["DisallowGlassButtons"],
        "lg-highlight-white": ["SolariumHighlightWhite"],
        "lg-background-filter": ["SolariumBackgroundFilter"],
        "lg-display-angle": ["SolariumUseDisplayAngle"],
        "lg-exclude-search-shadow": ["ExcludeSearchShadow"],
        "lg-exclude-dock-shadow": ["ExcludeDockShadow"],
        "lg-floating-bg-fills": ["FloatingContentViewEnableBackgroundFills"],
        "lg-disable-solarium-swiftui": ["DisableSolariumSwiftUI"],
        "lg-legibility-2": ["GlassLegibility"],
        "lg-corner-radius": ["SolariumCornerRadius"],
        "lg-force-fallback": ["ForceSolariumFallback"],
        "lg-disable-hs-exterior": ["DisableHomeScreenGlassExterior"],
        "lg-disable-kb-exterior": ["DisableKeyboardGlassExterior"],
        "lg-disable-focus-foreground": ["DisableSolariumFocusForegroundEffects"],
        "lg-force-dark-shadow": ["SolariumForceDarkShadow"],
        "lg-text-frost": ["SolariumTextFrost"],
        "lg-disable-dock-exterior": ["DisableDockGlassExterior"],
        "lg-ui-force-fallback": ["UISolariumFallback"],
        "lg-disable-compact-chrome": ["DisableSolariumCompactChrome"],
        "lg-force-enhanced-speculars": ["ForceEnhancedSpeculars"],
        // SpringBoard
        "sb-watchos-pairing": ["WatchOSCompatibility"],
        "sb-dont-lock-crash": ["SBDontLockAfterCrash"],
        "sb-dont-dim-ac": ["SBDontDimOrLockOnAC"],
        "sb-hide-low-power": ["SBHideLowPowerAlerts"],
        "sb-hide-ac-power": ["SBHideACPower"],
        "sb-never-breadcrumb": ["SBNeverBreadcrumb"],
        "sb-supervision-text": ["SBShowSupervisionTextOnLockScreen"],
        "sb-lock-screen-footnote": ["LockScreenFootnote"],
        "sb-icon-parallax": ["SBDisableIconParallax"],
        "sb-disable-dynamic-island": ["HideDICompletely"],
        "sb-disable-fly-in": ["SBDisableIconFlyInAnimation"],
        // Daemons (spec id is "Daemon.<group name>")
        "dm-clear-screentime": ["ClearScreenTimeAgentPlist"],
        "dm-thermalmonitord": ["Daemon.thermalmonitord"],
        "dm-ota": ["Daemon.OTA"],
        "dm-usagetrackingagent": ["Daemon.UsageTrackingAgent"],
        "dm-gamecenter": ["Daemon.GameCenter"],
        "dm-atwakeup": ["Daemon.ATWAKEUP"],
        "dm-tips": ["Daemon.Tips"],
        "dm-vpn": ["Daemon.VPN"],
        "dm-chineselan": ["Daemon.ChineseLAN"],
        "dm-healthkit": ["Daemon.HealthKit"],
        "dm-airprint": ["Daemon.AirPrint"],
        "dm-assistivetouch": ["Daemon.AssistiveTouch"],
        "dm-icloud": ["Daemon.iCloud"],
        "dm-passbook": ["Daemon.PassBook"],
        "dm-spotlight": ["Daemon.Spotlight"],
        "dm-nanotimekit": ["Daemon.NanoTimeKit"],
        "dm-voicecontrol": ["Daemon.VoiceControl"],
        "dm-followup": ["Daemon.FollowUp"],
        "dm-wifianalytics": ["Daemon.WifiAnalytics"],
        "dm-analyticshelper": ["Daemon.AnalyticsHelper"],
        "dm-callanalytics": ["Daemon.CallAnalytics"],
        "dm-coreduet": ["Daemon.CoreDuet"],
        "dm-insight": ["Daemon.Insight"],
        "dm-metrics": ["Daemon.Metrics"],
        "dm-mediaexperience": ["Daemon.MediaExperience"],
        "dm-symptomsd": ["Daemon.Symptomsd"],
        "dm-statisticaldiagnostic": ["Daemon.StatisticalDiagnostic"],
        "dm-wirelessdiagnostics": ["Daemon.WirelessDiagnostics"],
        "dm-duetheuristic": ["Daemon.DuetHeuristic"],
        "dm-duetexpert": ["Daemon.DuetExpert"],
        "dm-decisiond": ["Daemon.Decisiond"],
        "dm-triald": ["Daemon.Triald"],
        "dm-sociald": ["Daemon.Sociald"],
        // Internal Options
        "in-build-version": ["SBBuildNumber"],
        "in-rtl": ["RTL"],
        "in-ltr": ["LTR"],
        "in-disable-thermal": ["Daemon.thermalmonitord"],
        "in-hidden-icons": ["SBIconVisibility"],
    ]

    private static let specsByID: [String: TweakSpec] =
        Dictionary(uniqueKeysWithValues: TweakCatalog.allWithDaemons.map { ($0.id, $0) })

    static func specIDs(forFeature id: String) -> [String] {
        if id == "dm-recommended" {
            return DaemonGroups.all.filter(\.isRecommended).map { "Daemon.\($0.name)" }
        }
        return specIDsByFeature[id] ?? []
    }

    static func specs(forFeature id: String) -> [TweakSpec] {
        specIDs(forFeature: id).compactMap { specsByID[$0] }
    }

    static func isPosterBoard(_ id: String) -> Bool {
        id == "pb-tendies" || id == "pb-reset"
    }

    /// The version gate the row shows, read from the GN specs
    /// themselves — the same check the engine's compiler runs again
    /// at apply time. Nil for features with no spec (PosterBoard),
    /// whose caller falls back to the feature's own window.
    static func availability(forFeature id: String,
                               version: String,
                               isIPhone: Bool) -> Availability? {
        let specs = specs(forFeature: id)
        guard !specs.isEmpty else { return nil }
        if specs.allSatisfy({ $0.isCompatible(deviceVersion: version, isIPhone: isIPhone) }) {
            return .supported
        }
        var bounds: [String] = []
        if let min = specs.compactMap(\.minVersion).max() { bounds.append("iOS \(min)+") }
        if let max = specs.compactMap(\.maxVersion).min() { bounds.append("max iOS \(max)") }
        return .unsupported(reason: bounds.isEmpty ? "Not for this iOS" : "Requires \(bounds.joined(separator: ", "))")
    }

    /// Info-sheet lines for one feature, from the GN spec itself —
    /// what it writes and where, in the spec's own words.
    static func explanationLines(for feature: Feature) -> [String] {
        var lines = [feature.subtitle]
        switch feature.id {
        case "pb-tendies":
            lines.append("Delivered by the engine's PosterBoard stage, from the .tendies files in PosterBoard Files.")
        case "pb-reset":
            lines.append("Clears the Collections, Suggested Photos and gallery-cache descriptor folders; PosterBoard rebuilds them on next use.")
        case "dm-recommended":
            let groups = DaemonGroups.all.filter(\.isRecommended)
            let labels = groups.reduce(0) { $0 + $1.labels.count }
            lines.append("Turns on \(groups.count) recommended daemon groups (\(labels) labels): "
                         + groups.map(\.name).joined(separator: ", ") + ".")
        default:
            for spec in specs(forFeature: feature.id) {
                if let detail = spec.detail { lines.append(detail) }
                if !spec.key.isEmpty {
                    lines.append("Writes \(spec.key) to \(spec.location.rawValue).")
                }
            }
        }
        lines.append("Route: \(feature.routeSummary).")
        return lines
    }
}

// MARK: - Staged set → engine inputs

struct GNApplyInput {
    var selection = TweakSelection()
    var posterBoard = PosterBoardSelection()
    /// Features that produced engine input (a spec switched on, or a
    /// PosterBoard selection). Zero means there is nothing to apply.
    var mappedFeatures = 0
    /// Staged ids the engine has no counterpart for. The catalog no
    /// longer offers any, but a staged set persisted by an older build
    /// can still hold one — it is reported, never silently dropped.
    var droppedFeatureIDs: [String] = []
    var tendieFailures: [String] = []
}

enum GNSelectionBuilder {
    static func build(staged: Set<String>) -> GNApplyInput {
        var input = GNApplyInput()
        for id in staged.sorted() {
            switch id {
            case "pb-tendies":
                var tendies: [PosterBoardTendie] = []
                for url in TendiesStore.urls(kind: "Tendies") {
                    do {
                        tendies.append(try PosterBoardTendie(url: url))
                    } catch {
                        input.tendieFailures.append(url.lastPathComponent)
                    }
                }
                input.posterBoard.tendies = tendies
                input.mappedFeatures += 1
            case "pb-reset":
                input.posterBoard.resetModes = Set(PosterBoardResetMode.allCases)
                input.mappedFeatures += 1
            default:
                let specs = GNMapping.specs(forFeature: id)
                if specs.isEmpty {
                    input.droppedFeatureIDs.append(id)
                } else {
                    for spec in specs { input.selection.setOn(true, for: spec) }
                    // The corner tweak carries the user's own number,
                    // as on the desktop (a NUMBER field, 0–60) — the
                    // registry default of 0 is only the starting point.
                    if id == "lg-corner-radius",
                       let spec = specs.first(where: { $0.id == "SolariumCornerRadius" }) {
                        input.selection.restore(
                            enabled: true, value: nil,
                            multiValues: [
                                "SolariumCornerRadius": .int(CornerRadiusStore.value),
                                "SolariumInsetsAndCornerRadiusEnabled": .bool(true),
                            ],
                            for: spec)
                    }
                    // The footnote spec is a single-key text spec: the
                    // compiler writes the selection's staged value, so
                    // override it with the text the user saved in the
                    // editor (FootnoteStore), like the corner radius
                    // above overrides its spec's values.
                    if id == "sb-lock-screen-footnote",
                       let spec = specs.first(where: { $0.id == "LockScreenFootnote" }) {
                        input.selection.restore(
                            enabled: true,
                            value: .string(FootnoteStore.text),
                            multiValues: nil,
                            for: spec)
                    }
                    input.mappedFeatures += 1
                }
            }
        }
        return input
    }
}

/// The REAL number of tweaks a staged set delivers.
///
/// The Home Apply button used to count staged feature IDs, which
/// undercounts: one staged feature can write several specs (the
/// Recommended daemon set is one toggle for dozens of daemons), and
/// it ignored icon themes and status bar overrides entirely. This
/// counts what an apply actually writes: every spec of every staged
/// feature, one per PosterBoard tendie / reset mode, plus the icon
/// themes and the status bar overrides when those are active.
enum ApplyCounter {
    static func tweakCount(staged: Set<String>) -> Int {
        var n = 0
        for id in staged {
            switch id {
            case "pb-tendies":
                n += TendiesStore.urls(kind: "Tendies").count
            case "pb-reset":
                n += PosterBoardResetMode.allCases.count
            default:
                n += GNMapping.specs(forFeature: id).count
            }
        }
        return n
    }

    static func total(staged: Set<String>, iconCount: Int,
                      statusBarActive: Bool, statusBarCount: Int) -> Int {
        tweakCount(staged: staged) + iconCount
            + (statusBarActive ? statusBarCount : 0)
    }
}
