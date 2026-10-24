import Foundation

/// The hard block for the two AirCard pages (Wallet card skins, passcode
/// themes) — and ONLY those pages.
///
/// AirCard-iOS documents iOS 18.0–27.2 beta 2 as supported and 27.2 beta 3+
/// as patched (AirTraffic exploit closed), but enforces it as a UI warning
/// only: its `flashCards`/`flashPassthm` never check the OS version. WorkSlop
/// does the opposite here on purpose: without a block, a device on a patched
/// OS would open a tunnel, run a sync, and only then fail — burning the
/// user's time on an attempt that could never succeed. This gate runs BEFORE
/// any tunnel or sync work, in both the page UI and the engine entry points,
/// and it touches nothing else: no global gate, no change to `Airlift`,
/// `GoldenNuggetEngine`, staging, or any existing feature.
///
/// Boundary, exactly as AirCard states it (`ContentView.isPotentiallyPatchedOS`):
/// blocked when major > 27, or major == 27 and minor >= 3. Implemented as
/// `version >= 27.3` via `TweakVersion.compare`, which orders numerically.
///
/// Limitation carried over honestly from AirCard: `ProductVersion` cannot
/// distinguish 27.2 beta 3 from 27.2 stable (both report "27.2"), so a device
/// on 27.2 beta 3 passes this gate and fails later at the sync — the same
/// gap AirCard's own warning has. A 27.3+ stable release is blocked outright,
/// which is the intended behaviour since the patch persists.
///
/// An empty/unparseable version is also blocked: "unknown" must never be read
/// as "unpatched" on a page whose whole job is writing into device caches.
///
/// ## Vendored xcframework divergence (read before touching this file)
///
/// WorkSlop vendors an OLDER AirliftFFI snapshot than AirCard HEAD. Verified
/// against the headers: AirCard's `rust-core/include/airlift.h` declares
/// `al_set_target_host`/`al_set_target_hosts` (which AirCard calls before
/// every flash/scan to route RSD through the non-loopback VPN interface),
/// while WorkSlop's `Vendor/AirliftFFI.xcframework/.../airlift.h` declares
/// neither, and the vendored binaries differ as well. Per the coordinator's
/// binding decision, this port STAYS on the vendored snapshot: no binary swap,
/// no call to a symbol the header does not declare. The write path does not
/// depend on target-host routing — PosterBoard-over-AirLift already works on
/// the default LocalDevVPN 10.7.0.1 route — but there is NO static proof the
/// default route suffices for the Wallet syslog stream on every VPN setup.
/// Device testing must prove it. Never describe this port as "parity with
/// AirCard HEAD's binary": it is not.
enum AirCardGate {
    /// The first version known to have the AirTraffic patch.
    static let patchedFloor = "27.3"

    /// True when `deviceVersion` is at or past the patched floor.
    /// False for an empty or unparseable version — callers that need a
    /// verdict use `blockedReason`, which treats unknown as blocked.
    static func isPatched(deviceVersion: String) -> Bool {
        guard let cmp = TweakVersion.compare(deviceVersion, patchedFloor) else { return false }
        return cmp >= 0
    }

    /// The reason the AirCard pages must refuse, or nil when allowed.
    static func blockedReason(deviceVersion: String) -> String? {
        if deviceVersion.isEmpty {
            return "Could not determine the device iOS version, so AirCard features are "
                + "blocked rather than attempted blindly. Refresh the device status and try again."
        }
        guard TweakVersion.compare(deviceVersion, patchedFloor) != nil else {
            return "Could not parse the device iOS version (\(deviceVersion)), so AirCard "
                + "features are blocked rather than attempted blindly."
        }
        if isPatched(deviceVersion: deviceVersion) {
            return "iOS \(deviceVersion) is past the AirTraffic patch boundary (27.2 beta 3+). "
                + "Apple closed the exploit these features write through, so Wallet skins and "
                + "passcode themes cannot be applied on this version."
        }
        return nil
    }

    /// Throw before any tunnel/sync work when the gate blocks.
    static func requireUnpatched(deviceVersion: String) throws {
        if let reason = blockedReason(deviceVersion: deviceVersion) {
            throw GoldenNuggetError(reason)
        }
    }
}
