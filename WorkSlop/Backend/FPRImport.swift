import Foundation

/// Option 3's import merge — the contract is fixed here; the real merge
/// replaces this stub's body during the v4 build (wave 2). The stub throws
/// rather than pretend: an FPR + Import run on a build without the merge
/// must fail loudly, never silently restore tweaks only.
///
/// Contract: read the exported backup package at `package` (a device
/// directory in the Option-4 format: Manifest.db + Manifest.plist +
/// Status.plist + Info.plist + sharded payload), select its data rows under
/// the FPR report's pruning rules, and merge them into the synthesised FPR
/// device directory at `deviceDir` — payload files copied into the shards,
/// rows inserted into its Manifest.db. Tweak rows are injected afterwards
/// by the caller and win any fileID collision. Returns a one-line summary
/// for the log. Throws on any unsafe input (missing/corrupt manifest,
/// rows whose payload is absent or a drained placeholder).
enum FPRImport {
    static func merge(package: URL, into deviceDir: URL, udid: String,
                      log: (String) -> Void) throws -> String {
        throw GoldenNuggetError("Force Partial Restore + Import Backup is not "
            + "available in this build: the import merge has not landed yet.")
    }
}
