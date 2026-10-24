import Foundation
import SQLite3

/// Force Partial Restore (WorkSlop v4, Apply Options 2 and 3): a partial
/// restore for iOS 27 that is *synthesised on the host* in the iOS 27
/// format — a sqlite `Manifest.db`, never the legacy MBDB — and restored
/// with no backup phase at all.
///
/// The construction is the one the firmware research settled
/// (`riset/force-partial-restore-27`, `riset/fpr-format-vs-registrasi`,
/// the latter independently audited, verdict FORMAT):
///
///   * `Manifest.plist` Version 10.0 selects the device's sqlite ingestion
///     branch (`-[MBProperties hasManifestDB]`); the MBDB branch is the
///     legacy one the existing `forcePartialRestore` dev switch selects,
///     and it is not what runs here.
///   * Domain resolution at ingestion is a lookup in the firmware's own
///     `Domains.plist` plus live container synthesis — there is no
///     registration gate fed by a previous device-authored backup, so a
///     host-synthesised manifest needs no protective pull to be accepted.
///   * The restore goes through the engine's shared `runRestore`, i.e. the
///     existing `RestoreRunner` stack — byte-for-byte the proven Normal
///     path's restore. One honesty note (v4 audit, item c): the Swift
///     options dictionary sets `RestoreShouldReboot: false` only;
///     `RemoveItemsNotRestored` is NOT set in Swift — it comes from the
///     vendored Rust layer's default RestoreOptions (see idevice.h), and
///     its value on the mobilebackup2 path cannot be verified from this
///     repo. That key is load-bearing: absent/false is what we need —
///     absent-with-device-default-TRUE would annotate every domain for
///     deletion in the removing phase. WIRE-CONFIRM before any FPR device
///     test on a data-bearing phone.
///   * Payloads are restricted to the whitelist below. Three domains are
///     hard-banned: their `Domains.plist` entries carry
///     remove-on-restore path lists, so restoring them replaces whole
///     subtrees (`CameraRollDomain` → `Media/Photos`, `HealthDomain` →
///     `Health`) instead of writing the listed files. A tweak whose
///     target lives in one of them cannot be served by this method, ever;
///     it needs the Normal method's full path.
///
/// This file shares **no code** with the iOS 26 partial-restore path
/// (`partialRestore()` / `MBDBManifest`): the locked v4 rule is that the
/// two constructions never touch, so the iOS 26 path stays byte-untouched
/// and proven. What *is* shared is downstream of the manifest — the
/// injector (`BackupInjector` / `TweakInjector` / `ManifestStore`) and
/// the restore stack — exactly as the discriminator test shared them.

// MARK: - The domain whitelist

/// The explicit, auditable set of backup domains a Force Partial Restore
/// payload may land in.
///
/// Every entry names the payload source that writes it, so the set can be
/// re-derived from the code instead of trusted. A payload source added
/// later does **not** join this set by implication: its domain must be
/// added here, with its source named, or FPR runs refuse its payloads.
enum FPRDomainWhitelist {
    /// Checked FIRST, always throwing, however the payload was produced.
    ///
    /// Per the FPR report (Q2/Q4.3), from `Domains.plist` in the iOS 27
    /// firmware itself: `CameraRollDomain` removes `Media/Photos` (plus
    /// PhotoData caches / sharing / Sync subtrees) on restore,
    /// `HealthDomain` removes the whole `Health` subtree, and
    /// `MediaDomain` is in the same remove-list family. Restoring any of
    /// them is subtree replacement, not a file write.
    static let bannedDomains: Set<String> = [
        "CameraRollDomain",
        "MediaDomain",
        "HealthDomain",
    ]

    /// The fixed domains of `TweakDomainMap` — the destinations
    /// `TweakCompiler` emits for every registry tweak location
    /// (`TweakFileLocation`), each mapped from its device-path prefix:
    static let fixedDomains: Set<String> = [
        // TweakDomainMap: /var/Managed Preferences/ — the bulk of the
        // registry (SpringBoard, UIKit, AppStore, … plists); also
        // SkipSetup.build's purplebuddy payload.
        "ManagedPreferencesDomain",
        // TweakDomainMap: /var/root/
        "RootDomain",
        // TweakDomainMap: /var/preferences/ — e.g. the FeatureFlags
        // location (/var/preferences/FeatureFlags/Global.plist).
        "SystemPreferencesDomain",
        // TweakDomainMap: /var/MobileDevice/
        "MobileDeviceDomain",
        // TweakDomainMap: /var/mobile/ — also StatusBarMechanism (both
        // the classic struct and the iOS 27 archive live in HomeDomain;
        // StatusBarSelection.swift / StatusBarArchive.domain), the
        // TweakCompiler .GlobalPreferences HomeDomain mirror, and Icon
        // Themes' WebClip payloads (WebClipPayloads.build, the
        // extraPayloads an apply carries).
        // NOTE (v4 audit item e): HomeDomain's own firmware entry carries
        // a remove-on-restore list of its own (Library/MediaStream,
        // Library/Preferences/com.apple.migration.plist per the FPR
        // research). No staged tweak writes there, but a restore touching
        // HomeDomain may still clear those paths device-side — residual
        // risk to watch in the first device test, not a whitelist change.
        "HomeDomain",
        // TweakDomainMap: /var/db/ — e.g. the daemons location
        // (/var/db/com.apple.xpc.launchd/disabled.plist).
        "DatabaseDomain",
    ]

    /// Container domains, by prefix — `TweakDomainMap`'s two container
    /// rules, whose first path segment becomes part of the domain name:
    ///
    ///   * `SysContainerDomain-` — /var/containers/Data/SystemGroup/<group>/;
    ///     includes `SysContainerDomain-com.apple.eligibilityd`, the
    ///     payload `deliver` special-cases for Siri AI overrides and
    ///     `TweakRowProfile` shapes as `.eligibilityContainer`.
    ///   * `SysSharedContainerDomain-` —
    ///     /var/containers/Shared/SystemGroup/<group>/; includes the
    ///     footnote location's
    ///     `SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles`
    ///     (TweakFileLocation.footnote, via TweakCompiler) and SkipSetup
    ///     .build's CloudConfigurationDetails payload (same domain,
    ///     spelled literally in SkipSetup.swift).
    static let containerPrefixes = [
        "SysContainerDomain-",
        "SysSharedContainerDomain-",
    ]

    /// Exact domains from staged-payload sources outside `TweakDomainMap`:
    static let exactDomains: Set<String> = [
        // PosterBoard.compile / PosterBoardSnapshot — every PosterBoard
        // payload (descriptor files, the store database, reset zeroing)
        // lands in PosterBoard.domain. In an FPR run only the reset-only
        // selection reaches synthesis (a non-reset backup-mode selection
        // is refused before synthesis; AirLift mode produces no
        // payloads), but the domain is the feature's, so it is listed.
        "AppDomain-com.apple.PosterBoard",
    ]

    /// Whether one domain may ride an FPR restore. The ban is consulted
    /// before the allow rules, so a banned domain loses even if some
    /// future allow rule would match it.
    static func isAllowed(_ domain: String) -> Bool {
        if bannedDomains.contains(domain) { return false }
        if fixedDomains.contains(domain) || exactDomains.contains(domain) { return true }
        return containerPrefixes.contains { domain.hasPrefix($0) }
    }

    /// Refuse a payload set FPR must not restore.
    ///
    /// Throws `GoldenNuggetError` naming the domain and the reason —
    /// banned (subtree replacement) vs not in the whitelist (no staged
    /// source is known to write it) — plus the payload that carried it,
    /// so the log says exactly which file was refused.
    static func validate(_ payloads: [TweakPayload]) throws {
        for payload in payloads {
            if bannedDomains.contains(payload.domain) {
                throw GoldenNuggetError(
                    "Force Partial Restore refuses \(payload.label): "
                    + "\(payload.domain) is banned — restoring it replaces a whole "
                    + "subtree on the device (its firmware remove-on-restore list), "
                    + "it does not just write this file. Use the Normal Method for "
                    + "anything that targets \(payload.domain).")
            }
            guard isAllowed(payload.domain) else {
                throw GoldenNuggetError(
                    "Force Partial Restore refuses \(payload.label): "
                    + "\(payload.domain) is not in the FPR domain whitelist. No staged "
                    + "payload source is known to write it, so it is refused rather "
                    + "than guessed at — the whitelist in ForcePartialRestore.swift "
                    + "is the audit point, and a new source must be added there "
                    + "deliberately.")
            }
        }
    }
}

// MARK: - The synthesis

/// Builds the FPR backup folder from nothing. The engine owns the run
/// (gates, payload assembly, the restore); this owns the folder.
enum ForcePartialRestore {
    /// Synthesise a complete, restorable iOS 27 backup at
    /// `AppPaths.fprRoot(udid:)` and return that root, ready for the
    /// engine's `runRestore`.
    ///
    /// Steps, in order:
    ///
    ///   1. Wipe + create the device directory.
    ///   2. `HostManifests.ensure(ios27: true, isFullBackup: false)` —
    ///      Status 3.3 / `SnapshotState "finished"` / Manifest 10.0 /
    ///      SystemDomainsVersion 24.0, the same writer the proven paths
    ///      and the discriminator use.
    ///   3. A fresh, empty `Manifest.db` in the restore schema
    ///      (`Files` + `Properties`) — see `createEmptyManifestDatabase`
    ///      for why `HostManifests.writeSQLiteManifest` is *not* that.
    ///   4. Option 3 only: `FPRImport.merge` folds the imported package's
    ///      data rows in, before the tweaks, so a tweak row wins any
    ///      fileID collision (the merge contract's own rule).
    ///   5. The tweak payloads, injected with their directory-scaffolding
    ///      rows — the real construction includes them (FPR report Q4.1);
    ///      the discriminator's single-row shape was a test variable, not
    ///      the feature's.
    ///
    /// - Parameter log: the run's log sink. Every line this emits carries
    ///   the `[FPR]` prefix itself.
    static func makeBackup(udid: String,
                           payloads: [TweakPayload],
                           importPackage: URL?,
                           log: (String) -> Void) async throws -> URL {
        // Defence in depth: the engine validates before synthesis, and
        // the synthesis validates again, so no caller of this function
        // can put an unwhitelisted payload into a manifest.
        try FPRDomainWhitelist.validate(payloads)

        log("[FPR] synthesis start — building a host-synthesised sqlite-27 "
            + "partial backup from nothing (no backup phase, no protective "
            + "pull, no AFC media pull)")

        let backupRoot = AppPaths.fprRoot(udid: udid)
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        let fm = FileManager.default
        try? fm.removeItem(at: backupRoot)
        try fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)

        try HostManifests.ensure(deviceDir: deviceDir, udid: udid,
                                 ios27: true, isFullBackup: false)
        log("[FPR] host manifests written: Status.plist (Version 3.3, "
            + "SnapshotState \"finished\", IsFullBackup false), "
            + "Manifest.plist (Version 10.0, SystemDomainsVersion 24.0), "
            + "Info.plist")

        try createEmptyManifestDatabase(at: deviceDir)
        log("[FPR] Manifest.db created empty (Files + Properties schema, "
            + "restore shape — not the backup-pull placeholder)")

        let domains = Set(payloads.map(\.domain)).sorted()
        log("[FPR] whitelist: \(payloads.count) payload(s) validated, "
            + "domain(s): \(domains.isEmpty ? "(none — import only)" : domains.joined(separator: ", "))")

        if let importPackage {
            // The contract is fixed in FPRImport.swift; on a build where
            // its body is still the throwing stub this throws loudly,
            // which is the stub's own stated behaviour — an FPR + Import
            // run must never silently restore tweaks only.
            let summary = try FPRImport.merge(package: importPackage,
                                              into: deviceDir, udid: udid,
                                              log: { log("[FPR] import: \($0)") })
            log("[FPR] import merge: \(summary)")
        }

        // Injection wiring decision: `pruneAndInject` with
        // `prune: false, ios27: true`, the same entry the Normal path
        // ends in — NOT a direct TweakInjector call. Read against
        // BackupInjector.swift, its ios27 + prune:false path is safe on
        // a fresh host DB:
        //
        //   * the prune itself is the only stage that assumes device
        //     rows, and `prune: false` skips it outright (its own doc:
        //     a synthesised backup has "nothing to reconcile against
        //     the filesystem");
        //   * `HostManifests.ensure` re-runs as a no-op (the three
        //     plists already exist) except when a payload is
        //     `AppDomain-*` — the PosterBoard reset payloads — where its
        //     `Applications` registration is exactly what the Normal
        //     path does for the same payloads, and required for the
        //     device to resolve the domain at all;
        //   * what remains is `TweakInjector.inject`, which derives the
        //     directory-scaffolding rows from each payload's path and
        //     upserts through `ManifestStore` — the reuse points the
        //     construction wants, with no second injection path to
        //     drift from the proven one.
        try await BackupInjector.pruneAndInject(backupRoot: backupRoot,
                                                udid: udid,
                                                tweakPayloads: payloads,
                                                prune: false,
                                                ios27: true)

        let store = ManifestStore(deviceDir: deviceDir)
        log("[FPR] \(store.auditAgainstDisk())")
        log("[FPR] manifest row count: \(store.rowCount()) "
            + "(tweak file rows + their directory scaffolding rows"
            + "\(importPackage != nil ? " + imported data rows" : ""))")
        log("[FPR] synthesis complete at \(backupRoot.lastPathComponent) — "
            + "handing the backup to the shared restore")
        return backupRoot
    }

    /// A fresh `Manifest.db` with the restore schema and no rows.
    ///
    /// `HostManifests.writeSQLiteManifest` was checked first, per the
    /// reuse rule, and it does **not** produce this: it writes the
    /// libimobiledevice-shaped placeholder a *backup pull* serves the
    /// device (`ManifestEntry` + `Properties` with text values) — there
    /// is no `Files` table in it, so `ManifestStore` / `TweakInjector`
    /// could not write a single row into it. A restore manifest is the
    /// other shape, spelled the way the app itself spells it in the two
    /// places that create one from nothing:
    ///
    ///   * `CREATE TABLE Files …` — verbatim,
    ///     `PosterBoardSnapshot.swift` (the recovery snapshot's manifest),
    ///     also the discriminator's synthesis;
    ///   * `CREATE TABLE Properties …` — verbatim,
    ///     `HostManifests.swift`'s own schema line for the table.
    ///
    /// `Properties` is left empty: in a device-authored database its
    /// contents are the device's own, and the desktop host writer of
    /// this same format ships it empty too (discriminator notes).
    private static func createEmptyManifestDatabase(at deviceDir: URL) throws {
        let url = deviceDir.appendingPathComponent("Manifest.db")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw GoldenNuggetError("[FPR] Manifest.db: \(why)")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, """
            PRAGMA journal_mode=DELETE;
            CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB);
            CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB);
            """, nil, nil, nil) == SQLITE_OK else {
            throw GoldenNuggetError("[FPR] Manifest.db schema: "
                + String(cString: sqlite3_errmsg(db)))
        }
    }
}
