import Foundation
import SQLite3

/// Option 3's import merge — read the exported backup package at `package`
/// (a device directory in the Option-4 format: Manifest.db + Manifest.plist +
/// Status.plist + Info.plist + sharded payload), select its data rows under
/// the FPR report's pruning rules, and merge them into the synthesised FPR
/// device directory at `deviceDir` — payload files copied into the shards,
/// rows inserted into its Manifest.db. Tweak rows are injected afterwards
/// by the caller and win any fileID collision (the caller's injection is
/// `INSERT OR REPLACE`, in `ManifestStore.upsert`). Returns a one-line
/// summary for the log. Throws on any unsafe input (missing/corrupt
/// manifest, a manifest that cannot be read to the end).
///
/// The selection rules (FPR report Q2/Q4; `ForcePartialRestore.swift`'s
/// whitelist doc carries the same firmware evidence):
///
///   a. **Banned domains are hard-excluded**: `CameraRollDomain`,
///      `MediaDomain`, `HealthDomain`. Their `Domains.plist` entries carry
///      remove-on-restore path lists, so restoring them replaces whole
///      subtrees (`Media/Photos`, `Health`) instead of writing the listed
///      files. A device-authored *complete* set would be a normal restore's
///      business; this merge never carries them, even if a package somehow
///      contains them.
///   b. **Directory rows** (the blob's `Mode` is a directory) are included
///      as rows alone — the row is what makes the restore create the
///      directory, and a directory has no payload.
///   c. **Symlink rows** likewise carry no payload by definition (the
///      manifest audit counts `flags == 4` rows payload-less on purpose),
///      so they are included as rows alone.
///   d. **Regular file rows** are included only when the payload exists at
///      the package's shard path AND its on-disk size equals the size the
///      row's own blob declares. Anything else is skipped: the delegate
///      drains filter-rejected files to 0-byte placeholders during a pull
///      (and may remove the stand-ins afterwards), so a stored package can
///      hold rows whose payload is missing or 0 bytes while the blob
///      declares a real size — restoring such a row would write an empty
///      file over the device's real one. Zero-byte file rows (declared 0,
///      on disk 0) are skipped too, counted separately: losing a
///      legitimately-empty file is recoverable, overwriting a real file
///      with 0 bytes is the proven bootloop class, and no exception is
///      carved for a domain whose empty files cannot be evidenced safe.
///
/// The package's own `Status.plist` / `Manifest.plist` / `Info.plist` are
/// **not** copied: the synthesised construction's host manifests
/// (`HostManifests.ensure(ios27:)`) stay, because they are the half of the
/// construction the FPR verdict covers. Only `Files` rows and their
/// payloads cross over, each row's blob carried verbatim — device-authored
/// metadata is the entire point of importing a device-authored package.
enum FPRImport {
    static func merge(package: URL, into deviceDir: URL, udid: String,
                      log: (String) -> Void) throws -> String {
        let fm = FileManager.default
        let packageName = package.lastPathComponent

        // MARK: Validate the package manifest before touching the target.
        //
        // Never proceed on a partially-read manifest: every row is read
        // into memory first, and any read failure throws before a single
        // payload is copied or row upserted.
        let dbURL = package.appendingPathComponent("Manifest.db")
        guard fm.fileExists(atPath: dbURL.path) else {
            if fm.fileExists(atPath: package.appendingPathComponent("Manifest.mbdb").path) {
                throw GoldenNuggetError(
                    "The selected package (\(packageName)) is a legacy MBDB backup "
                    + "(Manifest.mbdb, no Manifest.db). Force Partial Restore + Import "
                    + "needs an Option-4 package — the sqlite format Get Backup File "
                    + "produces. Export a fresh package with Get Backup File and "
                    + "select that one.")
            }
            throw GoldenNuggetError(
                "The selected package (\(packageName)) has no Manifest.db — it is "
                + "not an Option-4 backup package. Export one with Get Backup File "
                + "and select that.")
        }

        let rows = try readAllRows(dbURL: dbURL, packageName: packageName)
        guard !rows.isEmpty else {
            throw GoldenNuggetError(
                "The selected package (\(packageName)) has a Manifest.db with no "
                + "Files rows — there is nothing to import, and an FPR run that "
                + "silently restored tweaks only is exactly what this merge must "
                + "never produce. Re-export the package with Get Backup File.")
        }
        log("package \(packageName): \(rows.count) manifest row(s) read for device \(udid)")
        log("the package's Status.plist / Manifest.plist / Info.plist are NOT copied — "
            + "the synthesised backup keeps its own host manifests")

        let target = ManifestStore(deviceDir: deviceDir)
        let source = ManifestStore(deviceDir: package)

        var imported = 0
        var importedFileRows = 0
        var importedDirRows = 0
        var importedSymlinkRows = 0
        var importedDomains = Set<String>()
        var skippedBanned = 0
        var bannedSamples: [String] = []
        // The summary's one "placeholder/missing" bucket, broken down in
        // the log lines below: payload absent, payload size disagreeing
        // with the blob (the drained-placeholder shape), and rows whose
        // blob cannot be read at all (no Mode / no Size — the shape the
        // pre-restore audit calls inconsistent, which the device cannot
        // restore either).
        var skippedMissing = 0
        var skippedMismatch = 0
        var skippedUnreadable = 0
        var missingSamples: [String] = []
        var mismatchSamples: [String] = []
        var unreadableSamples: [String] = []
        var skippedZero = 0
        var zeroSamples: [String] = []

        for row in rows {
            let label = "\(row.domain)/\(row.relativePath)"

            // (a) Banned domains first, before any other test.
            if FPRDomainWhitelist.bannedDomains.contains(row.domain) {
                skippedBanned += 1
                if bannedSamples.count < 5 { bannedSamples.append(label) }
                continue
            }

            guard let blob = row.blob, !blob.isEmpty else {
                skippedUnreadable += 1
                if unreadableSamples.count < 5 { unreadableSamples.append(label) }
                continue
            }
            let metadata = blobMetadata(blob)
            guard let mode = metadata.mode else {
                skippedUnreadable += 1
                if unreadableSamples.count < 5 { unreadableSamples.append(label) }
                continue
            }
            let fileType = mode & typeMask

            // (b) Directory rows: the row alone, no payload.
            if fileType == typeDirectory {
                try target.upsert(fileID: row.fileID, domain: row.domain,
                                  relativePath: row.relativePath,
                                  flags: row.flags, blob: blob)
                imported += 1
                importedDirRows += 1
                importedDomains.insert(row.domain)
                continue
            }

            // (c) Symlink rows: no payload by definition.
            if fileType == typeSymlink {
                try target.upsert(fileID: row.fileID, domain: row.domain,
                                  relativePath: row.relativePath,
                                  flags: row.flags, blob: blob)
                imported += 1
                importedSymlinkRows += 1
                importedDomains.insert(row.domain)
                continue
            }

            guard fileType == typeRegularFile, let declaredSize = metadata.size else {
                skippedUnreadable += 1
                if unreadableSamples.count < 5 { unreadableSamples.append(label) }
                continue
            }

            // (d) Regular files: payload present, size exactly as declared.
            let payloadURL = source.payloadURL(forFileID: row.fileID)
            guard fm.fileExists(atPath: payloadURL.path) else {
                skippedMissing += 1
                if missingSamples.count < 5 { missingSamples.append(label) }
                continue
            }
            let onDisk = ((try? fm.attributesOfItem(atPath: payloadURL.path))?[.size]
                as? NSNumber)?.int64Value ?? -1
            if declaredSize == 0 && onDisk == 0 {
                skippedZero += 1
                if zeroSamples.count < 5 { zeroSamples.append(label) }
                continue
            }
            guard onDisk == Int64(declaredSize) else {
                skippedMismatch += 1
                if mismatchSamples.count < 5 {
                    mismatchSamples.append("\(label) (blob declares \(declaredSize) B, "
                        + "payload on disk is \(onDisk) B)")
                }
                continue
            }

            let destination = target.payloadURL(forFileID: row.fileID)
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: payloadURL, to: destination)
            } catch {
                throw GoldenNuggetError(
                    "Import merge failed copying the payload for \(label) from "
                    + "\(packageName): \(error.localizedDescription). The FPR run is "
                    + "stopped before any restore — the partially merged backup is "
                    + "discarded, never restored.")
            }
            try target.upsert(fileID: row.fileID, domain: row.domain,
                              relativePath: row.relativePath,
                              flags: row.flags, blob: blob)
            imported += 1
            importedFileRows += 1
            importedDomains.insert(row.domain)
        }

        // Every skip class is counted and logged, with samples, so a merge
        // that carried less than the package held says exactly what and why.
        if skippedBanned > 0 {
            log("excluded \(skippedBanned) row(s) in banned domains "
                + "(\(FPRDomainWhitelist.bannedDomains.sorted().joined(separator: ", "))) — "
                + "restoring them replaces whole subtrees, e.g. \(bannedSamples.joined(separator: ", "))")
        }
        if skippedMissing > 0 {
            log("skipped \(skippedMissing) file row(s) whose payload is not in the package "
                + "(drained during the pull and never stored), e.g. \(missingSamples.joined(separator: ", "))")
        }
        if skippedMismatch > 0 {
            log("skipped \(skippedMismatch) file row(s) whose payload size disagrees with "
                + "the blob (the drained-placeholder shape — restoring one would write "
                + "the wrong bytes over the device's file), e.g. \(mismatchSamples.joined(separator: ", "))")
        }
        if skippedUnreadable > 0 {
            log("skipped \(skippedUnreadable) row(s) whose MBFile blob is missing or "
                + "unreadable (no Mode/Size the device could read either), e.g. "
                + "\(unreadableSamples.joined(separator: ", "))")
        }
        if skippedZero > 0 {
            log("skipped \(skippedZero) zero-byte file row(s) (declared 0 B, payload 0 B) — "
                + "never merged: an empty payload cannot be told apart from a drained "
                + "placeholder at restore time, e.g. \(zeroSamples.joined(separator: ", "))")
        }
        log("merged \(imported) row(s): \(importedFileRows) file(s) with payloads, "
            + "\(importedDirRows) directory row(s), \(importedSymlinkRows) symlink row(s), "
            + "across \(importedDomains.count) domain(s)")

        let skippedPlaceholder = skippedMissing + skippedMismatch + skippedUnreadable
        return "imported \(imported) rows (\(importedDomains.count) domains) from "
            + "\(packageName); skipped \(skippedPlaceholder) placeholder/missing, "
            + "\(skippedZero) zero-byte, \(skippedBanned) banned-domain"
    }

    // MARK: - Reading the package manifest

    /// One `Files` row, read in full before any merging happens.
    private struct PackageRow {
        let fileID: String
        let domain: String
        let relativePath: String
        let flags: Int32
        /// The row's `MBFile` blob, verbatim; nil when the column is NULL.
        let blob: Data?
    }

    /// `S_IFMT` and the file-type values `Mode` carries, spelled as masks:
    /// directory rows are how existing code builds them too
    /// (`Int(MODE_DIR_DEFAULT) | Int(S_IFDIR)` in `TweakInjector`).
    private static let typeMask = 0o170000
    private static let typeRegularFile = 0o100000  // S_IFREG
    private static let typeDirectory = 0o040000     // S_IFDIR
    private static let typeSymlink = 0o120000       // S_IFLNK

    /// Open the package's `Manifest.db` read-only and read every `Files`
    /// row. Throws — naming the package — when the file cannot be opened,
    /// has no `Files` table (a legacy or host-placeholder database is not a
    /// device-authored package), or cannot be read to the end.
    private static func readAllRows(dbURL: URL, packageName: String) throws -> [PackageRow] {
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openRC == SQLITE_OK, let db else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let db { sqlite3_close(db) }
            throw GoldenNuggetError(
                "The selected package (\(packageName)) has a Manifest.db that cannot "
                + "be opened (\(why)) — it is corrupt or is not a backup package. "
                + "Re-export it with Get Backup File.")
        }
        defer { sqlite3_close(db) }

        // The Files table must exist. The host-written placeholder a pull
        // starts from has ManifestEntry instead; a package still holding
        // that shape never received the device's own database.
        var tableStmt: OpaquePointer?
        let tableRC = sqlite3_prepare_v2(
            db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'Files'",
            -1, &tableStmt, nil)
        guard tableRC == SQLITE_OK, let tableStmt else {
            throw GoldenNuggetError(
                "The selected package (\(packageName)) has a Manifest.db that cannot "
                + "be read (\(String(cString: sqlite3_errmsg(db)))). Re-export it "
                + "with Get Backup File.")
        }
        var filesTables = 0
        if sqlite3_step(tableStmt) == SQLITE_ROW {
            filesTables = Int(sqlite3_column_int64(tableStmt, 0))
        }
        sqlite3_finalize(tableStmt)
        guard filesTables > 0 else {
            throw GoldenNuggetError(
                "The selected package (\(packageName)) has a Manifest.db with no "
                + "Files table — that is not the device-authored database an "
                + "Option-4 package carries (a host placeholder or a legacy "
                + "backup looks like this). Re-export it with Get Backup File.")
        }

        var stmt: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(
            db, "SELECT fileID, domain, relativePath, flags, file FROM Files",
            -1, &stmt, nil)
        guard prepareRC == SQLITE_OK, let stmt else {
            throw GoldenNuggetError(
                "The selected package (\(packageName)) has a Manifest.db whose Files "
                + "table cannot be read (\(String(cString: sqlite3_errmsg(db)))). "
                + "Re-export it with Get Backup File.")
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [PackageRow] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_DONE { break }
            guard stepRC == SQLITE_ROW else {
                // A partial read is no read: the merge must not proceed on
                // half a manifest, so the rows gathered so far are dropped
                // with the throw.
                throw GoldenNuggetError(
                    "The selected package (\(packageName)) has a Manifest.db that "
                    + "failed partway through reading its Files table (SQLite code "
                    + "\(stepRC): \(String(cString: sqlite3_errmsg(db)))). The import "
                    + "was not attempted. Re-export the package with Get Backup File.")
            }
            guard let idText = sqlite3_column_text(stmt, 0),
                  let domainText = sqlite3_column_text(stmt, 1),
                  let pathText = sqlite3_column_text(stmt, 2) else {
                throw GoldenNuggetError(
                    "The selected package (\(packageName)) has a Files row with no "
                    + "fileID/domain/relativePath — its Manifest.db is not a "
                    + "well-formed device-authored database. The import was not "
                    + "attempted. Re-export the package with Get Backup File.")
            }
            var blob: Data?
            let blobCount = sqlite3_column_bytes(stmt, 4)
            if blobCount > 0, let raw = sqlite3_column_blob(stmt, 4) {
                blob = Data(bytes: raw, count: Int(blobCount))
            }
            rows.append(PackageRow(fileID: String(cString: idText),
                                   domain: String(cString: domainText),
                                   relativePath: String(cString: pathText),
                                   flags: sqlite3_column_int(stmt, 3),
                                   blob: blob))
        }
        return rows
    }

    // MARK: - Reading a row's MBFile blob

    /// The `Mode` / `Size` a row's blob declares, or nils when unreadable.
    ///
    /// `MBFileBlob.swift`'s own reader (`mbFileBlobObject`) is file-private,
    /// so this mirrors its rule: scan the keyed archive's `$objects` for the
    /// entry holding the metadata keys, and read the values only when they
    /// are inline numbers — a reference-valued `Mode` is exactly the shape
    /// the device's `decodeInteger` reads raise on, so it comes back nil
    /// here and the row is skipped as unreadable.
    private static func blobMetadata(_ blob: Data) -> (mode: Int?, size: Int?) {
        guard let object = try? PropertyListSerialization.propertyList(
                from: blob, options: [], format: nil),
              let dict = object as? [String: Any],
              let objects = dict["$objects"] as? [Any] else {
            return (nil, nil)
        }
        for entry in objects {
            guard let entry = entry as? [String: Any],
                  entry["Birth"] != nil || entry["Mode"] != nil else { continue }
            return ((entry["Mode"] as? NSNumber)?.intValue,
                    (entry["Size"] as? NSNumber)?.intValue)
        }
        return (nil, nil)
    }
}
