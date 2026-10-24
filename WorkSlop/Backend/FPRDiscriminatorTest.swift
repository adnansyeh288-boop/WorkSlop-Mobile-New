import Foundation
import Minimuxer
import SQLite3

/// The Force Partial Restore discriminator test — a development-only probe,
/// not a feature.
///
/// The open question it answers (research: `riset/force-partial-restore-27`
/// and `riset/fpr-format-vs-registrasi`, the latter independently audited):
/// the fork's long-standing claim is that a host-*synthesised* manifest is
/// rejected by an iOS 27 device because "only a pulled manifest carries the
/// device's own domain registration". The firmware says otherwise — domain
/// resolution at ingestion is a lookup in the firmware's own `Domains.plist`,
/// the sqlite branch is chosen purely by `Manifest.plist` Version ≥ 10.0, and
/// no prepare-INSERT exists anywhere on the restore ingestion path. What the
/// firmware cannot decide is the *apply* phase after ingestion on a real
/// device. This test is the discriminator for exactly that, and nothing else:
///
///   * a backup folder synthesised from nothing — no protective pull, so no
///     device-authored manifest is involved anywhere;
///   * in the iOS 27 sqlite format (a real `Manifest.db`, **not** the legacy
///     MBDB the existing `forcePartialRestore` dev switch synthesises);
///   * holding exactly ONE row: a harmless marker plist in
///     `ManagedPreferencesDomain`, the domain named in the fork's quote;
///   * restored through the existing `RestoreRunner` stack, whose options the
///     Rust layer serialises with `RemoveItemsNotRestored: false` and
///     `RestoreShouldReboot: false` present explicitly (an absent
///     `RemoveItemsNotRestored` key defaults to TRUE on the device and would
///     annotate every domain for deletion — the one proven way a partial
///     restore destroys data).
///
/// Reading the result: the verdict comes from the FIRST clean run. If a run
/// fails and is resumed, the restore engine writes flags into the *snapshot*
/// manifest DB as ordinary failure-resume bookkeeping (audit §3 of the
/// format-vs-registration report) — that is not a registration mechanism and
/// must not be read as one.
///
/// Every stage logs under the `[FPR-TEST]` prefix: the log is the evidence.
enum FPRDiscriminatorTest {
    /// The one domain and path under test.
    static let domain = "ManagedPreferencesDomain"
    static let relativePath = "Library/Preferences/com.workslop.fprtest.plist"
    /// The single key the marker plist carries.
    static let markerKey = "FPRDiscriminatorTest"

    private static func log(_ line: String) {
        AppLog.write("[FPR-TEST] \(line)")
    }

    /// Run the test end to end. Never throws: the outcome — success, refusal
    /// at a gate, or the device's answer — is written to the log and returned
    /// as a one-line summary for the Settings page.
    static func run() async -> String {
        log("synthesis start — building a one-row sqlite-27 backup from nothing "
            + "(no protective pull, no device-authored manifest)")
        do {
            let code = try await runThrowing()
            log("restore finished — ErrorCode \(code)")
            if code == 0 {
                log("SUCCESS: the device accepted and completed a restore of a "
                    + "host-synthesised sqlite partial manifest with no prior "
                    + "backup session. Read the marker back off the device to "
                    + "confirm the apply phase landed the file.")
                return "Restore finished — ErrorCode 0. See the log."
            }
            log("restore returned \(code) without confirming completion — "
                + "inspect the log above.")
            return "Restore returned \(code) — see the log."
        } catch {
            log("FAILED — \(error.localizedDescription)")
            return "Failed — \(error.localizedDescription)"
        }
    }

    private static func runThrowing() async throws -> Int32 {
        // The same readiness gates an Apply run passes (`prepareRun`), in the
        // same order: the dev switch, a stored pairing file, minimuxer ready
        // (which is itself gated on the pairing file and the tunnel), then
        // the UDID.
        guard DevSettings.effective.fprDiscriminatorTest else {
            throw GoldenNuggetError("the FPR discriminator test switch is off "
                + "(Settings → Development). Refusing to run.")
        }
        guard FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) else {
            throw GoldenNuggetError("no pairing file is stored. Import one first, "
                + "then run the test.")
        }
        let minimuxer = Minimuxer.shared()
        guard await isReady(minimuxer) else {
            throw GoldenNuggetError("minimuxer is not ready. Ensure WiFi and a "
                + "working tunnel (LocalDevVPN or WireGuard + em_proxy), then "
                + "select a pairing file.")
        }
        guard let udid = try await minimuxer.core.fetchUDID() else {
            throw GoldenNuggetError("Could not fetch device UDID")
        }
        log("UDID: \(udid)")
        log("Tunnel: \(Tunnel.describe())")

        // The version gate uses the app's own convention: a run re-reads
        // lockdown and branches on the major component. An unreadable version
        // refuses rather than guesses — the construction below is specific to
        // iOS 27 (Status 3.3 / Manifest 10.0 / SystemDomainsVersion 24.0).
        let identity = await DeviceIdentity.read()
        let major = Int(identity.version.split(separator: ".").first ?? "0") ?? 0
        log("device: \(identity.describe) (major \(major))")
        guard major == 27 else {
            throw GoldenNuggetError("the FPR discriminator test is an iOS 27 "
                + "construction and this device reports "
                + "\(identity.version.isEmpty ? "no readable version" : identity.version). "
                + "Refusing to run.")
        }

        let backupRoot = AppPaths.fprDiscriminatorTestRoot
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        // The fileID is in the synthesis log lines; the run needs nothing
        // further from it.
        _ = try synthesize(deviceDir: deviceDir, udid: udid)

        let store = ManifestStore(deviceDir: deviceDir)
        log("manifest row count: \(store.rowCount()) (the test is exactly 1)")
        log(store.auditAgainstDisk())

        // The options the restore below sends, for the record: RestoreRunner
        // sets RestoreShouldReboot=false and RestoreSystemFiles=true in
        // Swift; the FFI's RestoreOptions serialises the rest from defaults
        // that are themselves explicit in the plist —
        // RestoreDontCopyBackup=false, RestorePreserveSettings=true,
        // RemoveItemsNotRestored=false, no Password key. The load-bearing one
        // is RemoveItemsNotRestored=false: absent, the device defaults it to
        // TRUE and deletes files that are not in the backup.
        log("restore options: RestoreShouldReboot=false, RestoreSystemFiles=true, "
            + "RestoreDontCopyBackup=false, RestorePreserveSettings=true, "
            + "RemoveItemsNotRestored=false, Password=(absent)")

        // One run, no retry wrapper: the discriminator is the first clean
        // run's answer, and a retry loop would smear exactly that evidence.
        return try await RestoreRunner.run(backupRoot: backupRoot, sourceIdentifier: udid)
    }

    /// `prepareRun`'s readiness check, duplicated because that one is private
    /// to the engine: ask once, give the tunnel half a second, ask again.
    private static func isReady(_ minimuxer: Minimuxer) async -> Bool {
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        return false
    }

    // MARK: - Synthesis

    /// Build the backup folder from nothing and return the marker's fileID.
    ///
    /// Everything here reuses the writers the proven paths use, so the only
    /// new variable in the experiment is the one under test — that the
    /// manifest was synthesised rather than pulled:
    ///
    ///   * `Status.plist` / `Manifest.plist` / `Info.plist` come from
    ///     `HostManifests.ensure` with the iOS 27 arguments (Status Version
    ///     "3.3", `SnapshotState` "finished", `IsFullBackup` false; Manifest
    ///     Version "10.0", `SystemDomainsVersion` "24.0").
    ///   * `Manifest.db` is a fresh sqlite database with the `Files` schema
    ///     spelled the way the app itself spells it (`PosterBoardSnapshot`)
    ///     plus the `Properties` table (`HostManifests`), left empty — the
    ///     desktop writer of this same format leaves it empty too.
    ///   * The single row goes in through `ManifestStore.upsert`, with its
    ///     fileID from `ManifestStore.fileID` and its blob from
    ///     `buildMBFileBlob` shaped by `TweakRowProfile` for the domain —
    ///     digest included, because this domain's file rows carry one.
    ///   * The payload lands at `ManifestStore.payloadURL`, the `<xx>/<fileID>`
    ///     shard.
    private static func synthesize(deviceDir: URL, udid: String) throws -> String {
        let fm = FileManager.default
        try? fm.removeItem(at: deviceDir)
        try fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)

        try HostManifests.ensure(deviceDir: deviceDir, udid: udid, ios27: true,
                                 isFullBackup: false)
        log("host manifests written: Status.plist (Version 3.3, SnapshotState "
            + "\"finished\", IsFullBackup false), Manifest.plist (Version 10.0, "
            + "SystemDomainsVersion 24.0), Info.plist")

        // The marker payload: a tiny plist whose only content is the marker
        // key, so its presence on the device afterwards is unambiguous and
        // its absence costs nothing.
        let contents = try PropertyListSerialization.data(
            fromPropertyList: [markerKey: 1], format: .binary, options: 0)

        let fileID = ManifestStore.fileID(domain: domain, relativePath: relativePath)

        try createManifestDatabase(at: deviceDir)

        let profile = TweakRowProfile.forDomain(domain)
        let blob = buildMBFileBlob(
            relativePath: relativePath,
            mode: Int(MODE_FILE_DEFAULT) | Int(S_IFREG),
            size: contents.count,
            userID: profile.fileOwner,
            groupID: profile.fileGroup,
            protectionClass: profile.fileProtectionClass,
            // A synthesised row needs an inode in the band the device's own
            // occupy, derived from the fileID so a re-run reproduces it —
            // the same helper `injectSystemPlist` uses for its rows.
            inodeNumber: BackupInjector.inode(for: fileID),
            timestamp: Int(Date().timeIntervalSince1970),
            digest: profile.carriesDigest ? payloadDigest(contents) : nil,
            extendedAttributes: profile.fileExceptionPublisher.map {
                buildDataprotectionExtendedAttributes(publisher: $0)
            })

        let store = ManifestStore(deviceDir: deviceDir)
        try store.upsert(fileID: fileID, domain: domain, relativePath: relativePath,
                         flags: 1, blob: blob)

        let payloadURL = store.payloadURL(forFileID: fileID)
        try fm.createDirectory(at: payloadURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try contents.write(to: payloadURL)

        log("manifest row: domain=\(domain) relativePath=\(relativePath) "
            + "fileID=\(fileID) flags=1 payload=\(contents.count) bytes "
            + "at \(payloadURL.lastPathComponent)")
        log(store.blobKeySample(ours: fileID))
        return fileID
    }

    /// A fresh `Manifest.db` with the restore schema and no rows.
    ///
    /// The `Files` statement is the app's own verbatim spelling
    /// (`PosterBoardSnapshot.retainBaseline`); the `Properties` statement is
    /// `HostManifests`' (and the desktop `_write_manifest_db`'s). No
    /// `Properties` rows are written: in a device-authored database that
    /// table's contents are the device's own, and the one host writer of
    /// this format (desktop) ships it empty.
    private static func createManifestDatabase(at deviceDir: URL) throws {
        let url = deviceDir.appendingPathComponent("Manifest.db")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw GoldenNuggetError("FPR test: Manifest.db: \(why)")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, """
            PRAGMA journal_mode=DELETE;
            CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB);
            CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB);
            """, nil, nil, nil) == SQLITE_OK else {
            throw GoldenNuggetError("FPR test: Manifest.db schema: "
                + String(cString: sqlite3_errmsg(db)))
        }
    }
}
