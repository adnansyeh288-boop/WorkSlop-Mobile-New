import Foundation
import ZIPFoundation

/// Zip / unzip for Option-4 backup packages (WorkSlop v4 step 2).
///
/// A package is a directory (see `BackupExportStore`) or, since step 2,
/// a `.zip` of one. The zip holds the package's entries relative to the
/// package root — no top-level folder — so unzipping reproduces the
/// package directory exactly, and the existing merge (`FPRImport.merge`)
/// runs on the unpacked directory unchanged.
///
/// Uses ZIPFoundation, already a dependency of the app (via the local
/// Minimuxer package) for PosterBoard packs — no new dependency.
/// Each unpacked entry's CRC32 is compared against its central
/// directory checksum here (the library only computes it) — and a zip
/// that would write outside its destination, or collide with itself,
/// fails the whole unpack rather than silently dropping or
/// overwriting.
enum BackupExportZip {
    /// Zip a whole package directory into `<packageName>.zip` next to
    /// it (in `BackupExportStore.root`). The name loop mirrors the
    /// package-naming loop in `getBackupFileRun`: a stale zip of the
    /// same name is never overwritten, a `-2`, `-3`, … suffix is used
    /// instead. The source directory is left untouched — the caller
    /// decides what to do with it (step 2 keeps it; the user deletes
    /// it with the existing Delete button if they want).
    static func zip(package: URL) throws -> URL {
        let fm = FileManager.default
        let root = package.deletingLastPathComponent()
        var zipName = package.lastPathComponent + ".zip"
        var zipURL = root.appendingPathComponent(zipName, conformingTo: .data)
        var suffix = 2
        while fm.fileExists(atPath: zipURL.path) {
            zipName = "\(package.lastPathComponent)-\(suffix).zip"
            zipURL = root.appendingPathComponent(zipName, conformingTo: .data)
            suffix += 1
        }
        let archive = try Archive(url: zipURL, accessMode: .create)
        // No `.skipsHiddenFiles`: a package is zipped whole — a hidden
        // entry silently left out would make the zip a different
        // package from the directory it claims to be.
        guard let walker = fm.enumerator(at: package, includingPropertiesForKeys: nil) else {
            // The archive file already exists at this point (empty) —
            // it must not survive to pose as a package in the picker.
            try? fm.removeItem(at: zipURL)
            throw GoldenNuggetError(
                "Could not list the backup package to zip it (\(package.lastPathComponent)).")
        }
        do {
            for case let url as URL in walker {
                // Relative path inside the package, e.g. "Manifest.db"
                // or "ab/cdef1234…". `addEntry(with:relativeTo:)`
                // handles files, directories and symlinks itself.
                let relative = String(url.path.dropFirst(package.path.count + 1))
                try archive.addEntry(with: relative, relativeTo: package,
                                     compressionMethod: .deflate)
            }
        } catch {
            // A half-written zip must never pose as a package.
            try? fm.removeItem(at: zipURL)
            throw error
        }
        return zipURL
    }

    /// Unpack a package archive into `destDir`, reproducing the
    /// package layout exactly. `destDir` must be fresh (the caller
    /// passes a UUID working directory); entries that would escape
    /// it (`..`, absolute paths) or that collide with an entry
    /// already unpacked throw, and the caller removes the partial
    /// directory. Symlinks that point outside the destination are
    /// refused by the library itself (`allowUncontainedSymlinks`
    /// stays false).
    static func unzip(zip: URL, to destDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let archive = try Archive(url: zip, accessMode: .read)
        let destRoot = destDir.standardizedFileURL.path
        for entry in archive {
            let dest = destDir.appendingPathComponent(entry.path).standardizedFileURL
            let destPath = dest.path
            // An entry for the root itself ("." ) carries no content.
            guard destPath != destRoot else { continue }
            guard destPath.hasPrefix(destRoot + "/") else {
                throw GoldenNuggetError(
                    "The zip file contains an entry that escapes its folder (\(entry.path)) — refusing to unpack it.")
            }
            // Throws on a second entry for the same path (the
            // library refuses to overwrite), so a zip that collides
            // with itself fails loudly instead of silently winning
            // one entry over another.
            //
            // The library only *computes* the CRC32 and returns it —
            // it does not compare it (that comparison lives in
            // `FileManager.unzipItem`, which is not used here). A
            // corrupt entry must fail the whole unpack, so the
            // comparison is done here. Directory entries checksum
            // to 0 on both sides, so the comparison is uniform.
            let crc = try archive.extract(entry, to: dest)
            guard crc == entry.checksum else {
                throw GoldenNuggetError(
                    "The zip file is corrupt: entry \(entry.path) fails its checksum — refusing to unpack it.")
            }
        }
    }
}
