import SwiftUI

/// Device + gate state for the whole app, in ONE place.
///
/// The old UI probed the VPN tunnel and the pairing file from
/// several views (and once per row per render, before the perf
/// fixes). Every row now reads this single object from the
/// environment — no per-row probing, no per-row @AppStorage.
final class StatusStore: ObservableObject {
    @Published private(set) var vpnDetected: Bool
    @Published private(set) var pairingImported: Bool
    @Published private(set) var probing = false

    /// The activation gate: no tweak toggles on before BOTH the
    /// pairing file is imported AND a VPN tunnel is up.
    var unlocked: Bool { vpnDetected && pairingImported }

    init() {
        vpnDetected = DeviceStatus.vpnTunnelActive()
        pairingImported = PairingStore.isImported
    }

    /// Re-probe tunnel + pairing file, then ask lockdownd whether it
    /// answers on the tunnel (the real two-phase check).
    func refresh() {
        guard !probing else { return }
        probing = true
        vpnDetected = DeviceStatus.vpnTunnelActive()
        pairingImported = PairingStore.isImported
        Task { [weak self] in
            // Phase 2 of the two-phase check: does lockdownd answer
            // through the tunnel? The read's verdict is not a gate
            // input (the gate is pairing + tunnel) - it ends the
            // probing state, as the old LockdownProbe call did.
            _ = await DeviceIdentity.read()
            await MainActor.run { self?.probing = false }
        }
    }

    /// Called after import/delete so the rows update without a refresh.
    func pairingChanged() {
        pairingImported = PairingStore.isImported
    }
}
