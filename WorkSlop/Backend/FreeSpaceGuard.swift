import Foundation

/// Bookkeeping for the iOS 27 free-space gate (Option 1, Normal path).
///
/// The device lets a protective backup proceed only when the free space the
/// host reports is greater than its computed `uploadSize` (counted inclusive
/// of hardlink/clone repetitions) + 128 MiB. On a shortfall it sends
/// `DLMessagePurgeDiskSpace` asking the host to free real space, re-reads the
/// free-space answer, and kills the backup (MBErrorDomain/105) if the number
/// did not rise.
///
/// This app cannot answer that purge mid-backup: the vendored Rust crate
/// answers it itself ("Operation not supported", which the device tolerates)
/// and the Swift FFI delegate vtable has no purge callback. What the app CAN
/// do honestly is (a) log the numbers the gate acted on, (b) free the one pool
/// of real space it owns — the AFC media store — at the failure point so a
/// retry starts with that space back, and (c) persist the measured numbers so
/// a preflight can show a real deficit instead of "storage full".
///
/// All persisted records live in `UserDefaults` under the `FreeSpaceGuard.`
/// prefix. No number is ever invented: a value that was not measured is
/// simply absent from the record and from the summary.
enum FreeSpaceGuard {
    private static let prefix = "FreeSpaceGuard."

    private static var defaults: UserDefaults { .standard }

    private static func key(_ name: String) -> String { prefix + name }

    // MARK: - Media store

    /// Total bytes of the files under the AFC media store (0 if absent).
    ///
    /// This walks the LOCAL store tree. `AfcMediaBackup.survey()` is not used:
    /// it walks the DEVICE over AFC and reports the device's media, not the
    /// copies this app is holding in its own container.
    static func mediaStoreBytes() -> Int64 {
        let root = AfcMediaBackup.storeRoot
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return 0 }
        var total: Int64 = 0
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: nil
        ) else { return 0 }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// Free space on the volume the app container lives on — the same volume
    /// (and the same API family) the backup delegate reports to the device.
    static func containerFreeBytes() -> Int64 {
        AfcMediaBackup.containerFreeBytes()
    }

    /// Empty the media store and return how many bytes it held just before.
    ///
    /// The size is measured BEFORE `AfcMediaBackup.clear()` runs, so the
    /// return value is the amount this call actually freed. Throws if a media
    /// transfer is in flight (`AfcMediaBackup.clear()` refuses to race one).
    static func clearMediaStore() throws -> Int64 {
        let before = mediaStoreBytes()
        try AfcMediaBackup.clear()
        return before
    }

    // MARK: - Failure record

    /// Persist one space failure with the real numbers measured for it.
    ///
    /// `uploadSize` here is the per-failure value the caller measured for
    /// this run; a nil clears the per-failure slot, and
    /// `lastFailureSummary()` then falls back to the syslog capture record
    /// (`lastKnownUploadSize()`), which is kept separately and never
    /// overwritten by a failure that did not measure one.
    static func recordSpaceFailure(reportedFree: Int64, purgeCount: Int,
                                   finalError: String, uploadSize: Int64?) {
        defaults.set(NSNumber(value: reportedFree), forKey: key("lastFailureReportedFree"))
        defaults.set(purgeCount, forKey: key("lastFailurePurgeCount"))
        defaults.set(finalError, forKey: key("lastFailureError"))
        if let uploadSize {
            defaults.set(NSNumber(value: uploadSize), forKey: key("lastFailureUploadSize"))
        } else {
            defaults.removeObject(forKey: key("lastFailureUploadSize"))
        }
        // A new failure supersedes the previous run's purge-arm result; the
        // arm for THIS failure records its own freed amount right after.
        defaults.removeObject(forKey: key("lastFreedByArm"))
        defaults.set(Date().timeIntervalSince1970, forKey: key("lastFailureAt"))
    }

    /// Record how much real space the purge arm freed at the failure point.
    static func recordFreedByArm(_ bytes: Int64) {
        defaults.set(NSNumber(value: bytes), forKey: key("lastFreedByArm"))
    }

    /// User-facing one/two-liner for the last recorded space failure, built
    /// only from persisted, measured numbers. Nil when no failure is on
    /// record.
    static func lastFailureSummary() -> String? {
        guard defaults.object(forKey: key("lastFailureAt")) != nil else { return nil }
        let reportedFree = defaults.object(forKey: key("lastFailureReportedFree")) as? NSNumber
        let purgeCount = defaults.integer(forKey: key("lastFailurePurgeCount"))
        let finalError = defaults.string(forKey: key("lastFailureError")) ?? ""
        var parts: [String] = []
        var headline = "The last backup was stopped by the device over free space"
        if let reportedFree {
            headline += ": \(formatBytes(reportedFree.int64Value)) was free"
        }
        headline += "."
        parts.append(headline)
        if purgeCount > 0 {
            parts.append("The device asked for space to be freed \(purgeCount) time(s) (purge requests).")
        }
        if let uploadSize = defaults.object(forKey: key("lastFailureUploadSize")) as? NSNumber {
            parts.append("The device's computed backup size was \(formatBytes(uploadSize.int64Value)).")
        } else if let uploadSize = lastKnownUploadSize() {
            parts.append("The device's computed backup size (from its log) was \(formatBytes(uploadSize)).")
        }
        if let freed = defaults.object(forKey: key("lastFreedByArm")) as? NSNumber, freed.int64Value > 0 {
            parts.append("WorkSlop freed \(formatBytes(freed.int64Value)) of media copies it was holding; run Apply again.")
        }
        if !finalError.isEmpty {
            parts.append("Device error: \(finalError)")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - uploadSize capture (device syslog)

    /// Persist the gate numbers the device wrote to its syslog just before
    /// the free-space check: `uploadSize:<inclusive>(<exclusive>)` and the
    /// file count that went with them.
    static func recordUploadSize(inclusive: Int64, exclusive: Int64, fileCount: Int) {
        defaults.set(NSNumber(value: inclusive), forKey: key("uploadSizeInclusive"))
        defaults.set(NSNumber(value: exclusive), forKey: key("uploadSizeExclusive"))
        defaults.set(fileCount, forKey: key("uploadFileCount"))
        defaults.set(Date().timeIntervalSince1970, forKey: key("uploadSizeAt"))
    }

    /// The last captured inclusive `uploadSize`, if syslog capture ever
    /// produced one.
    static func lastKnownUploadSize() -> Int64? {
        guard let value = defaults.object(forKey: key("uploadSizeInclusive")) as? NSNumber
        else { return nil }
        return value.int64Value
    }

    // MARK: - Rust log purge census

    /// How many times `DLMessagePurgeDiskSpace` appears in the Rust log at or
    /// after byte offset `mark` (a `RustLog.size()` snapshot taken before the
    /// run). The vendored crate logs every purge request it receives as
    /// `Unsupported DL message: DLMessagePurgeDiskSpace`, so this count is
    /// the number of times the device demanded space during that run.
    static func purgeCountInRustLog(since mark: UInt64) -> Int {
        guard let whole = try? Data(contentsOf: RustLog.url) else { return 0 }
        let from = Int(min(mark, UInt64(whole.count)))
        let text = String(decoding: whole.dropFirst(from), as: UTF8.self)
        let needle = "DLMessagePurgeDiskSpace"
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    // MARK: - Formatting

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
