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
    /// stage (`.staging-<uuid>`), and a staging directory is not a package
    /// — it may be partial, and the pull that owns it removes it on failure.
    /// Non-directories are excluded for the same reason: a package is a
    /// directory by definition.
    static func packageURLs() -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])
        else { return [] }
        let packages = entries.filter { url in
            guard !url.lastPathComponent.hasPrefix(".") else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
        }
        return packages.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? .distantPast
            return da > db
        }
    }

    /// Total bytes of the regular files under a package directory —
    /// metadata plists, `Manifest.db` and every shard payload alike.
    static func size(of package: URL) -> Int64 {
        let fm = FileManager.default
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
