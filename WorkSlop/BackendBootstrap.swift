import Foundation
import Minimuxer

/// The backend's launch + connection bootstrap, extracted from the
/// fork's app entry and home view (`NuggetApp.init` and
/// `GoldenNuggetView.startMinimuxer`) so WorkSlop's own UI never has
/// to host backend logic. The order is load-bearing and mirrors the
/// original:
///
/// 1. `appInit()` — logging preference, the AirLift log sink and
///    grappa token provider, then our own WireGuard server
///    (em_proxy) when no LocalDevVPN-style tunnel is already up.
/// 2. `start()` — probe the tunnel, turn Rust file logging on BEFORE
///    `setLogging`, bind the localVPN connection config, start the
///    Minimuxer core with the pairing record, and poll readiness.
///
/// Safe to call repeatedly: a second call while a start is in flight
/// is ignored, and a core that already reports ready is left alone.
enum BackendBootstrap {
    private static var startInFlight = false
    private static let startLock = NSLock()

    static func appInit() {
        // Development mode's logging switch, applied at launch: it
        // governs the protocol half of every run.
        DevSettings.applyLoggingPreference()

        // AirLift's log sink, installed at launch: a launch is the
        // only moment a static archive's symbols are proven good, and
        // the sink is one-shot — a second call subscribes nothing.
        if Airlift.install() {
            AppLog.write("AirLift: log sink installed (AirTraffic escape available on iOS 27+)")
        } else {
            AppLog.write("AirLift: log sink already installed by the library")
        }
        // Referenced so the linker keeps `_ALGetGrappaToken`: the FFI
        // looks it up with dlsym when it writes.
        Airlift.installGrappaTokenProvider()

        // LocalDevVPN compatibility: only start our own WireGuard
        // server when no LocalDevVPN-style tunnel is already up.
        let tunnelUp = Tunnel.isInterfaceUp()
        AppLog.write("Tunnel status: \(Tunnel.describe()) — em_proxy \(tunnelUp ? "skipped (LocalDevVPN active)" : "starting")")
        if !tunnelUp {
            let emproxy = Minimuxer.shared().emproxy
            emproxy.setHandshakeClient(host: "127.0.0.1", port: 51820, enabled: false)
            Task {
                do {
                    try await emproxy.start(host: "127.0.0.1", port: 51820)
                } catch {
                    AppLog.write("em_proxy failed to start: \(error)")
                }
            }
        }
    }

    static func start() {
        guard let pairingFileRaw = PairingStore.loadRaw() else { return }
        startLock.lock()
        if startInFlight {
            startLock.unlock()
            GoldenNuggetEngine.shared.log("minimuxer start already in progress — ignoring this request")
            return
        }
        startInFlight = true
        startLock.unlock()

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .path(percentEncoded: false)
        Task.detached(priority: .userInitiated) {
            defer {
                startLock.lock()
                startInFlight = false
                startLock.unlock()
            }
            if case .success(true) = await Minimuxer.shared().core.isReady() {
                GoldenNuggetEngine.shared.log("minimuxer already ready — start skipped")
                return
            }
            // SideStore-style pre-start guard: the LocalDevVPN tunnel
            // routes to the emulated peer. Probe the tunnel first so
            // the RSD handshake can reach the device before we start.
            guard Tunnel.waitForTunnel(log: { line in GoldenNuggetEngine.shared.log(line) }) else {
                GoldenNuggetEngine.shared.log("Tunnel not ready: \(Tunnel.peerIP):\(Tunnel.servicePort) unreachable.\n\n\(Tunnel.requirements)")
                return
            }
            do {
                // FIRST, before setLogging()/start(): the Rust logger
                // latches on the first idevice_init_logger call in the
                // process, and setLogging(true) installs
                // console=Error/file=OFF.
                GoldenNuggetEngine.shared.enableRustFileLogging()
                let minimuxer = Minimuxer.shared()
                minimuxer.core.setLogging(true)
                minimuxer.core.setDeviceProbeTimeout(3000)
                // Bind the localVPN connection mode; the setters record
                // what the connection manager resolved (see
                // `Tunnel.reported`) for diagnostics.
                Tunnel.resetReported()
                await minimuxer.core.bindConnectionConfig(ConnectionConfigBinding(
                    setTunnelIfaceIp: { value in Tunnel.noteReported { $0.ifaceIP = value } },
                    setTunnelPeerIp: { value in Tunnel.noteReported { $0.peerIP = value } },
                    setTunnelPeerSubnetMask: { value in Tunnel.noteReported { $0.peerSubnetMask = value } },
                    setTunnelPeerReachable: { value in Tunnel.noteReported { $0.peerReachable = value } },
                    setTunnelIfaceSubnetMask: { value in Tunnel.noteReported { $0.ifaceSubnetMask = value } },
                    getRemoteServerIp: { "" },
                    setRemoteReachable: { _ in },
                    getOverrideTunnelPeerIp: { "" },
                    setOverrideTunnelPeerReachable: { _ in },
                    getConnectionMode: { .localVPN }
                ))
                // Diagnostic: the record's real keys, so a wrong or
                // unrecognised pairing file is obvious. No verdict is
                // attached — `start()` gives the authoritative one.
                if let keys = PairingRecord.topLevelKeys(pairingFileRaw) {
                    GoldenNuggetEngine.shared.log("pairing file top-level keys: \(keys.isEmpty ? "(empty)" : keys.sorted().joined(separator: ", "))")
                } else {
                    GoldenNuggetEngine.shared.log("pairing file: NOT a parseable plist")
                }
                try await minimuxer.core.start(pairingFile: pairingFileRaw, mountPath: docs)
                // Readiness wait, deadline-bounded: poll fast at
                // first, then back off, hard stop at 20 s.
                var isReady = false
                let deadline = Date().addingTimeInterval(20)
                var delay: UInt64 = 200_000_000   // 0.2 s -> doubles -> 2 s cap
                while Date() < deadline {
                    if case .success(true) = await minimuxer.core.isReady() {
                        isReady = true
                        break
                    }
                    try await Task.sleep(nanoseconds: delay)
                    delay = min(delay * 2, 2_000_000_000)
                }
                GoldenNuggetEngine.shared.log("minimuxer started. ready=\(isReady)")
                if !isReady {
                    GoldenNuggetEngine.shared.log("minimuxer.log tail:\n\(RustLog.tail())")
                }
            } catch {
                GoldenNuggetEngine.shared.log("minimuxer start failed: \(error.localizedDescription)")
                GoldenNuggetEngine.shared.log("minimuxer.log tail:\n\(RustLog.tail())")
            }
        }
    }
}
