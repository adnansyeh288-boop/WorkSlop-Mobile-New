import Foundation

/// The record of what the last successful applies put on the device —
/// the data Remove Tweaks works from.
///
/// Written by the Apply page after every successful run (merged: a
/// later apply adds to the record, it does not replace it) and kept
/// in Documents, so it survives navigation, process death and device
/// restarts. It stores the pairing fingerprint from apply time:
/// removal only makes sense against the device that pairing reaches,
/// so a removed or replaced pairing file invalidates the record for
/// removal (the Remove page says so instead of guessing).
///
/// Icon themes are recorded for completeness but are NOT removed by
/// Remove Tweaks — the web clips carry `RemovalDisallowed = false`,
/// so the user deletes them from the Home Screen directly.
struct AppliedTweaksRecord: Codable, Equatable {
    var featureIDs: [String] = []
    var statusBarActive: Bool = false
    var iconBundleIDs: [String] = []
    /// SHA-256 of the pairing record in place at apply time.
    var pairingFingerprint: String?
    var lastApplied: Date?
}

enum AppliedTweaksStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppliedTweaks.json")
    }

    static func load() -> AppliedTweaksRecord {
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(AppliedTweaksRecord.self, from: data)
        else { return AppliedTweaksRecord() }
        return record
    }

    static func save(_ record: AppliedTweaksRecord) {
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Merge a successful apply into the record.
    static func recordApply(featureIDs: [String], statusBarActive: Bool,
                            iconBundleIDs: [String], pairingFingerprint: String?) {
        var record = load()
        record.featureIDs = Array(Set(record.featureIDs).union(featureIDs)).sorted()
        record.statusBarActive = record.statusBarActive || statusBarActive
        record.iconBundleIDs = Array(Set(record.iconBundleIDs).union(iconBundleIDs)).sorted()
        record.pairingFingerprint = pairingFingerprint
        record.lastApplied = Date()
        save(record)
        AppLog.write("Applied record updated — \(record.featureIDs.count) tweak(s), "
            + "status bar \(record.statusBarActive ? "on" : "off"), "
            + "\(record.iconBundleIDs.count) icon theme(s)")
    }

    /// Drop features a successful removal turned off. When nothing is
    /// left, the whole record goes — there is nothing to remove twice.
    static func recordRemoval(featureIDs: [String], statusBar: Bool) {
        var record = load()
        record.featureIDs.removeAll { featureIDs.contains($0) }
        if statusBar { record.statusBarActive = false }
        if record.featureIDs.isEmpty && !record.statusBarActive {
            record.iconBundleIDs = []
            record.pairingFingerprint = nil
            record.lastApplied = nil
        }
        save(record)
    }
}
