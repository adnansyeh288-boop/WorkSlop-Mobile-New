import Foundation

/// The four Apply methods of WorkSlop v4 — the user's locked menu structure
/// (2026-10-24). This enum is the shared contract between the Apply UI and
/// the engine; the cases and the user-facing labels are fixed.
///
/// - `normal`: the proven behaviour — protective backup on iOS 27, partial
///   restore on iOS 26 — plus the free-space fix on the iOS 27 path.
/// - `forcePartialRestore`: iOS 27 only. A host-synthesised sqlite-27 partial
///   manifest of the staged tweaks, restored with no backup phase. Its own
///   implementation (`ForcePartialRestore.swift`); it shares no code with
///   the iOS 26 partial-restore path.
/// - `forcePartialRestoreImport`: iOS 27 only. The same synthesis, merged
///   with user data from a backup package produced by `getBackupFile`.
/// - `getBackupFile`: a standalone action (not an apply) that pulls a
///   device-authored MobileBackup package the user can keep and re-import
///   through `forcePartialRestoreImport`. Works on iOS 26 and 27.
enum ApplyMethod: String, CaseIterable, Identifiable, Sendable {
    case normal
    case forcePartialRestore
    case forcePartialRestoreImport
    case getBackupFile

    var id: String { rawValue }

    /// The exact user-facing label.
    var label: String {
        switch self {
        case .normal: return "Normal Method"
        case .forcePartialRestore: return "Force Partial Restore — iOS 27"
        case .forcePartialRestoreImport: return "Force Partial Restore + Import Backup — iOS 27"
        case .getBackupFile: return "Get Backup File"
        }
    }

    /// True for the two methods that only exist on iOS 27 — they must refuse
    /// (not silently fall back) on any other major version.
    var requiresIOS27: Bool {
        switch self {
        case .forcePartialRestore, .forcePartialRestoreImport: return true
        case .normal, .getBackupFile: return false
        }
    }
}
