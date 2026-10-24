import Foundation

/// The on-disk store of Option-4 backup packages (WorkSlop v4,
/// "Get Backup File").
///
/// A **package** is one directory whose top level holds the contents of a
/// backup device directory, exactly as a `ProtectiveBackup.run` pull leaves
/// them:
///
///   * `Manifest.db` — the device-authored sqlite manifest (the `Files`
///     table the device uploaded, replacing the host's placeholder);
///   * `Manifest.plist`, `Status.plist`, `Info.plist` — the backup metadata
///     files present in the pulled device directory;
///   * the sharded payload tree, `<xx>/<fileID>`.
///
/// Since step 2 a package may also be a **`.zip` of such a directory**
/// (produced by the Get Backup File export flow, see
/// `BackupExportZip`): the picker lists it like a directory, and an
/// FPR + Import run unpacks it to a working directory first, so the
/// merge still sees exactly the directory shape above.
///
/// Packages are produced by `GoldenNuggetEngine.getBackupFile` (which pulls
/// into a dot-prefixed staging directory under `root` and moves the finished
/// device directory here) and consumed by `FPRImport.merge` (Option 3).
/// Nothing in this store prunes or rewrites a package: what the pull left is
/// what is kept, and the merge — not the store — owns the pruning rules for
/// what may be restored from it.
enum BackupExportStore {
    /// `<Documents>/ExportedBackups/` — see `AppPaths.exportedBackups`.
    static var root: URL { AppPaths.exportedBackups }

    /// The finished packages under `root`, newest first by creation date.
    ///
    /// Dot-prefixed entries are excluded: that is where in-flight pulls
    /// stage (`.staging-<uuid>`) and where zip imports unpack
    /// (`.unzipped-<uuid>`), and neither is a package — a staging
    /// directory may be partial, and the run that owns it removes it
    /// on completion. Since step 2 a package is a directory **or** a
    /// `.zip` file of one; anything else is not a package.
    static func packageURLs() -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isRegularFileKey])
        else { return [] }
        let packages = entries.filter { url in
            guard !url.lastPathComponent.hasPrefix(".") else { return false }
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey]) else { return false }
            if values.isDirectory == true { return true }
            return values.isRegularFile == true
                && url.pathExtension.lowercased() == "zip"
        }
        return packages.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? .distantPast
            return da > db
        }
    }

    /// Remove stale zip-import working directories (`.unzipped-*`).
    /// Only that prefix, and only directories older than a day: a run
    /// removes its own working directory when it ends, so anything
    /// this old is a leftover of a run that never finished (the app
    /// was killed mid-run). The one-day floor means a sweep can never
    /// touch a working directory a live run is still using. The pull's
    /// `.staging-*` trees are never touched here — the pull owns them.
    static func removeStaleUnzipWorkingDirs() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in entries where url.lastPathComponent.hasPrefix(".unzipped-") {
            guard let values = try? url.resourceValues(
                forKeys: [.creationDateKey, .isDirectoryKey]),
                  values.isDirectory == true,
                  let created = values.creationDate, created < cutoff
            else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Total bytes of a package: for a directory, the regular files
    /// under it — metadata plists, `Manifest.db` and every shard
    /// payload alike; for a `.zip` package, the archive file itself.
    static func size(of package: URL) -> Int64 {
        let fm = FileManager.default
        if let values = try? package.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
           values.isDirectory != true {
            return Int64(values.fileSize ?? 0)
        }
        guard let walker = fm.enumerator(
            at: package, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }
}
