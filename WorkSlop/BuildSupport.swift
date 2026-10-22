import Foundation

/// Support level of the iOS build this device runs.
///
/// - `supported`: the iOS 26 line — the engine's iOS 26 path is
///   device-proven from this app (user's iPhone, 26.6.1, 2026-10-22).
/// - `partial`: the iOS 27 line — the engine's iOS 27 path is
///   upstream's shipping code but has NOT been device-proven from
///   this app yet, so these builds run with a warning, at the
///   user's own risk.
/// - `unsupported`: outside the app's iOS 26–27 line (the app
///   itself refuses to open there; see WorkSlopApp).
enum BuildSupportLevel: Equatable {
    case supported
    case partial
    case unsupported

    var displayText: String {
        switch self {
        case .supported: return "Supported"
        case .partial: return "Partially supported"
        case .unsupported: return "Not supported"
        }
    }
}

enum BuildSupport {
    /// The iOS 27.0 train + 27.0.1, newest first (user order
    /// 2026-10-22: developer betas 1–8, the public betas, RC, the
    /// official stable, and 27.0.1 on top — all Partially Supported).
    ///
    /// Build numbers are the user's own verified list, the same one
    /// WorkSlop Desktop ships (its SUPPORTED_BUILDS, verified
    /// 2026-09-30); 24A446 (27.0.1) is the build this project's
    /// firmware work verified directly. Public betas ship from this
    /// same train — a public-beta device reports one of these build
    /// numbers or a train sibling, and any 27.x build not listed
    /// here still resolves to `.partial` by the version rule below,
    /// so no 27.0 public beta can fall through.
    static let partialBuilds: [(build: String, label: String)] = [
        ("24A446", "iOS 27.0.1"),
        ("24A437", "iOS 27.0 (official stable)"),
        ("24A435", "iOS 27.0 RC"),
        ("24A5430a", "iOS 27.0 Developer Beta 8"),
        ("24A5424a", "iOS 27.0 Developer Beta 7"),
        ("24A5418b", "iOS 27.0 Developer Beta 6"),
        ("24A5408d", "iOS 27.0 Developer Beta 5"),
        ("24A5390f", "iOS 27.0 Developer Beta 4"),
        ("24A5380h", "iOS 27.0 Developer Beta 3"),
        ("24A5370h", "iOS 27.0 Developer Beta 2"),
        ("24A5355q", "iOS 27.0 Developer Beta 1"),
    ]

    /// Human label for a listed build ("iOS 27.0 Developer Beta 4"),
    /// nil when the build is not in the table.
    static func label(forBuild build: String) -> String? {
        partialBuilds.first { $0.build == build }?.label
    }

    static func level(build: String, major: Int) -> BuildSupportLevel {
        if partialBuilds.contains(where: { $0.build == build }) {
            return .partial
        }
        switch major {
        case 26:
            return .supported
        case 27:
            // Any other 27.x build (27.1, 27.2 betas, RC variants):
            // same untested line, same level.
            return .partial
        default:
            return .unsupported
        }
    }

    /// This device's level, from its own reported build + version.
    static var current: BuildSupportLevel {
        level(build: DeviceInfoEx.buildNumber, major: DeviceInfo.iosVersion.major)
    }

    /// This device's train label when its build is listed
    /// ("iOS 27.0.1"), for display next to the level.
    static var currentBuildLabel: String? {
        label(forBuild: DeviceInfoEx.buildNumber)
    }
}
