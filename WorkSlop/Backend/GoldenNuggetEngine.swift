import Foundation
import Minimuxer
import SwiftUI

/// An error whose message is meant for the operator, not for a stack trace.
struct GoldenNuggetError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// The apply pipeline, ported from GoldenNugget's own apply pass
// (`device_manager._apply_tweak_pass`) onto this app's restore machinery.
//
// Flow:
//   1. Compile the selection to plists — before the device is touched, so an
//      impossible selection costs nothing.
//   2. Real protective backup via mobilebackup2 — triggers the iOS 27
//      backup-password/trust popup and establishes an authorized session.
//      FactoryInfo {Applications: {}} skips app containers device-side.
//      shouldPreserve drains photos/movies mid-stream.
//   3. Prune Manifest.db to the protective keep-set (drained files still
//      have rows — they must be removed or restore requests them), then inject
//      the compiled tweak plists as rows + payloads.
//   4. Restore via mobilebackup2.
//
// This type is the run orchestrator and the app-facing facade.  The work itself
// lives in `Core/`: `ProtectiveBackup` (stage 2), `BackupInjector` (stage 3),
// `RestoreRunner` (stage 4), with `ChannelRecovery` / `StallGuard` /
// `TransportFailure` handling the retry and silence verdicts, `ManifestStore`
// owning the manifest, `RustLog` + `WireCensus` reading the Rust evidence, and
// `AppLog` being the process-wide log bus.  The facade is kept so the SwiftUI
// layer does not have to know any of that.
class GoldenNuggetEngine {
    static let shared = GoldenNuggetEngine()

    private init() {}

    // MARK: - Logging facade

    /// Route engine log lines into the UI list.
    var onLog: ((String) -> Void)? {
        didSet { AppLog.shared.setUIHandler(onLog) }
    }

    func log(_ msg: String) {
        AppLog.shared.log(msg)
    }

    /// Run `body` under `label`, writing a failure into the log before it escapes.
    ///
    /// Every run entry point throws to a view that turns the error into a status
    /// line, and a status line lives exactly as long as the screen: the file sink
    /// is the only record a failed run leaves once the app is closed. It has to
    /// be written here rather than at the call sites because there are four of
    /// them and a fifth would silently skip it — which is how a posterboard apply
    /// came to end with its last line still on the *fetch* and nothing saying
    /// why.
    private func loggedRun<T>(_ label: String,
                              _ body: () async throws -> T) async throws -> T {
        try InFlightCall.shared.beginRun()
        defer { InFlightCall.shared.endRun() }
        do {
            return try await body()
        } catch let failure as TransportFailure where failure.isCancellation {
            log("\(label) stopped: \(failure.label)")
            throw failure
        } catch {
            log("\(label) failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Cancellation facade

    func requestCancel() { CancelFlag.shared.request() }

    func clearCancel() { CancelFlag.shared.clear() }

    // MARK: - Paths facade

    static var appLogURL: URL { AppPaths.appLog }
    static var rustLogURL: URL { AppPaths.rustLog }
    static var diagnosticsURL: URL { AppPaths.diagnostics }

    static func rustLogSize() -> UInt64 { RustLog.size() }
    static func appLogSize() -> UInt64 { AppLog.shared.file.size() }
    static func rustLogStatus() -> String { RustLog.status() }

    /// Remember the log offset so the next excerpt covers only THIS run.
    @discardableResult
    func markRustLog() -> UInt64 { RustLog.markStart() }

    // MARK: - Rust logging

    /// Point the Rust logger at `<Documents>/minimuxer.log` at DEBUG level.
    ///
    /// MUST run before `setLogging(true)` / `core.start()`: the Rust side
    /// latches on the first `idevice_init_logger` call for the whole process
    /// (`Once`), and the existing call site installs console=Error / file=OFF.
    /// That is why `minimuxer.log` never existed and a failed mobilebackup2
    /// backup produced no Rust-side evidence.  Safe to call repeatedly — every
    /// call after the first returns -2 without changing anything.
    @discardableResult
    func enableRustFileLogging() -> Int32 {
        // One line per call was wrong twice over: `.onAppear` fires on every
        // navigation back and `startMinimuxer` calls this again, so a session
        // that never got a tunnel printed the same "rust log → …" line a dozen
        // times — the loudest thing in a log whose real failure was one line
        // lower. The Rust side is process-wide state; the first answer is the
        // only one that describes it.
        if let cached = RustLog.initResult {
            return cached
        }

        do {
            try PairingLogPrivacy.removeLegacyDumps(at: [AppPaths.rustLog, AppPaths.appLog])
        } catch {
            // Keep the sink disabled until its old secrets can be removed.
            log("Could not remove legacy pairing secrets from diagnostic logs: \(error.localizedDescription)")
            return -1
        }
        let path = AppPaths.rustLog.path

        let rc: Int32
        if let gateway = Minimuxer.shared().ideviceGateway {
            rc = gateway.enableRustFileLogging(to: path)
        } else {
            rc = -99
        }
        RustLog.noteInitResult(rc)

        let meaning: String
        switch rc {
        case 0:   meaning = "file sink requested (DEBUG)"
        case -1:  meaning = "file error — path rejected by Rust"
        case -2:  meaning = "already initialized — a previous idevice_init_logger call won, Rust logs stay on console(Error) and never reach the file"
        case -3:  meaning = "invalid path string"
        case -99: meaning = "no ideviceGateway available"
        default:  meaning = "unknown"
        }
        log("rust log → \(path): rc=\(rc) (\(meaning))")

        // rc=0 only means the subscriber was installed; the file itself is
        // created by the first line the Rust side writes, so it is legitimately
        // absent here. What must be true NOW is that the directory exists —
        // a missing parent is the one case where the sink can never come up, and
        // it is invisible afterwards (status reads "size=MISSING" forever).
        if rc == 0 {
            let fm = FileManager.default
            let parent = URL.documents.path
            let parentExists = fm.fileExists(atPath: parent)
            log("rust log dir: \(parent) exists=\(parentExists) "
                + "(file appears with the first Rust line)")
            if !parentExists {
                log("⚠️ the Rust log directory does not exist — no Rust evidence will be "
                    + "written this session. This app is running somewhere its Documents "
                    + "path is not writable.")
            }
        }
        return rc
    }

    // MARK: - Diagnostics

    /// The failure dump; see `Diagnostics.report()`.
    func diagnostics() async -> String {
        await Diagnostics.report()
    }

    // MARK: - Progress facade

    /// Whole-percent progress of the run in flight, or nil when nothing has
    /// reported yet.  The reference's home page prints the same number in its
    /// process-status line (`IOSApplyPage.set_status` parses `NN%` out of the
    /// status text), and a multi-minute restore with no number on it is the one
    /// screen the operator keeps re-reading to guess whether it is alive.
    private(set) var progress: Double?

    /// Route progress into the UI.  Called from the Rust progress callbacks, so
    /// the handler hops to the main actor itself.
    var onProgress: ((Double) -> Void)?

    /// Route the remaining-time estimate into the UI with the same story as
    /// `onProgress`: the feed happens on the Rust callback thread, the handler
    /// hops to the main actor.  Empty string until a stable rate is known — the
    /// desktop's status line shows nothing while `eta.py` is still quiet.
    var onEta: ((String) -> Void)?

    /// The last formatted remaining time (`""` before an estimate exists or
    /// while nothing is running).
    private(set) var etaText: String = ""

    /// The `eta.py` port.  Recreated per run so a new apply starts estimating
    /// from a clean slate even though the engine object is a singleton.
    private var etaEstimator = ProgressEta()

    private func reportProgress(_ percent: Double) {
        let clamped = percent < 0 ? 0 : min(percent, 100)
        progress = clamped
        onProgress?(clamped)
        let estimate = etaEstimator.update(clamped)
        etaText = estimate
        onEta?(estimate)
    }

    private func clearProgress() {
        progress = nil
        etaEstimator.reset()
        etaText = ""
        onProgress?(Double.nan)
        onEta?("")
    }

    // MARK: - Run: apply the ported GoldenNugget tweaks

    /// Apply everything this app can deliver: the compiled plist tweaks, the skip-setup
    /// files, and the PosterBoard selection — **one pass, one button**.
    ///
    /// This is GoldenNugget's `device_manager._apply_tweak_pass`, whose file list is
    /// built from every feature at once: its `needs_posterboard` flag decides whether the
    /// store's database has to be fetched first, and the wallpapers then ride the same
    /// restore as the tweaks.  There is no separate apply for wallpapers — this port had
    /// one for a while, a second button running the same four stages over a different
    /// payload set, and it is gone.  What is left of it is the flag.
    ///
    /// The compile runs *before* the device is touched, so an empty or impossible
    /// selection fails without paying for a backup first.  The PosterBoard database is
    /// the one input that has to come off the device; that stage therefore talks to it,
    /// but it is still ahead of the expensive protective pull and of the restore.
    func applyTweaks(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        deviceVersion: String,
        isIPhone: Bool,
        extraPayloads: [TweakPayload] = []
    ) async throws {
        // `_prepare_rollback_preset` (`main_window_mixins.py:1090`): keep the
        // last successful apply available as a one-click rollback *before* the
        // next apply overwrites it.  Best-effort, like the reference.
        try await loggedRun("apply") {
            GoldenNuggetPresets.prepareRollback()
            try await applyTweaksRun(selection: selection,
                                     posterBoard: posterBoard,
                                     statusBar: statusBar,
                                     deviceVersion: deviceVersion,
                                     isIPhone: isIPhone,
                                     extraPayloads: extraPayloads)
        }
        // `_save_last_applied_preset` (`main_window_mixins.py:1101`): a run
        // that returned is a successful apply — it becomes the rollback source
        // for the next one.  The model string is derived because the engine
        // does not carry a full identity; the snapshot is internal metadata.
        _ = GoldenNuggetPresets.saveLastApplied(selection: selection,
                                                deviceModel: isIPhone ? "iPhone" : "iPad",
                                                iosVersion: deviceVersion)
    }

    private func applyTweaksRun(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        deviceVersion: String,
        isIPhone: Bool,
        extraPayloads: [TweakPayload] = []
    ) async throws {
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN apply")
        defer { runStage.done() }

        let compiled = TweakCompiler.compile(selection: selection,
                                             deviceVersion: deviceVersion,
                                             isIPhone: isIPhone)

        let tweakPayloads = compiled.payloads

        // The status bar is built here, on the version the page already read, and
        // for the same reason the plist compile is: a payload that cannot be built
        // has to fail before the device is touched.  The page resolves the
        // mechanism from this same number, so the two cannot disagree.
        var statusBarPayloads: [TweakPayload] = []
        if statusBar.isActive {
            let mechanism = StatusBarMechanism.mechanism(for: deviceVersion)
            let built = try statusBar.payload(for: mechanism)
            statusBarPayloads = [TweakPayload(domain: mechanism.domain,
                                              relativePath: mechanism.restorePath,
                                              contents: built.data)]
            // The count, then the parenthetical the reference's summary has: an
            // enabled-but-empty selection still writes a file, and the log has to
            // say so, or a reset reads as a no-op.
            log("Status bar: \(statusBar.overrides.activeCount) override(s)"
                + " \(statusBar.overrides.activeCount == 0 ? "(a reset)" : "") via "
                + "\(mechanism == .classic ? "the classic struct" : "the iOS 27 archive") "
                + "→ \(statusBarPayloads[0].label) (\(built.data.count) B)")
            for field in built.dropped {
                log("  ⚠️ \(field) has no counterpart in the iOS 27 archive and was not delivered")
            }
        }

        // Upstream's skip-setup block rides the same apply, **ahead of** the
        // tweaks (`device_manager.add_skip_setup`).  Its warnings are logged
        // below: the parts this port cannot reproduce must not read like parity.
        //
        // Always the un-supervised variant.  The `supervised` / `organizationName`
        // arguments used to come off the Supervision page, and the page is gone —
        // it recorded `IsSupervised` without ever writing the
        // `SupervisorHostCertificates` that make the flag mean anything, so a
        // device this app "supervised" sat in a state the reference never
        // produces on purpose.  `SkipSetup` still carries the supervised shape
        // because `scripts/skipsetup-check.swift` checks both, but nothing in the
        // app selects it any more.
        let skipSetup = SkipSetupSettings.shared.skipSetupEnabled
            ? SkipSetup.build(supervised: false, organizationName: "")
            : SkipSetup.Build(payloads: [], warnings: [])

        guard !tweakPayloads.isEmpty || !skipSetup.payloads.isEmpty || posterBoard.isActive
                || statusBar.isActive || !extraPayloads.isEmpty else {
            throw GoldenNuggetError("Nothing to apply: no tweak is enabled (or every enabled one "
                + "was skipped), skip setup is off, the status bar is untouched, and there is "
                + "nothing selected on the PosterBoard page.")
        }
        if !extraPayloads.isEmpty {
            // WorkSlop addition (not upstream): caller-built payloads
            // that ride the same delivery — currently the Icon Themes
            // WebClip files. The machinery below treats them exactly
            // like compiled payloads; nothing about the delivery
            // itself changes.
            log("Extra payloads: \(extraPayloads.count) file(s) from the caller")
            for payload in extraPayloads {
                log("  → \(payload.domain):\(payload.relativePath)")
            }
        }
        log("Tweaks: \(tweakPayloads.count) file(s) from \(compiled.locations.count) plist(s)")
        for location in compiled.locations { log("  → \(location.rawValue)") }
        for item in compiled.skipped { log("  ⚠️ skipped \(item.label): \(item.reason)") }
        if !skipSetup.payloads.isEmpty {
            log("Skip setup: \(skipSetup.payloads.count) file(s) ahead of the tweaks")
            for payload in skipSetup.payloads { log("  → \(payload.label)") }
            for warning in skipSetup.warnings { log("⚠️ \(warning)") }
        }

        let udid = try await prepareRun()
        // Resolved once, here, because two stages need it: the PosterBoard compile (its
        // reset preferences change at 26.4) and the manifest-format fork inside
        // `deliver`.  `resolvedDeviceVersion` carries the reasoning for refusing to
        // guess — a device whose version cannot be read must not be treated as iOS 26.
        let version = try await resolvedDeviceVersion(deviceVersion)
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        log("device version for the manifest-format fork: \(version) (major \(major))")

        // Product rule (user, 2026-10-24): on iOS 27 the status bar may only be
        // applied through Force Partial Restore, never through this Normal run.
        // The Apply page blocks the combination before the run starts; this is
        // the same gate at the run layer, on the run's own resolved version,
        // before any backup or restore work (and before the PosterBoard stage
        // below touches the device). The FPR run does not pass through here.
        if major == 27 && statusBar.isActive {
            throw GoldenNuggetError("Status Bar tweaks on iOS 27 can only be applied with "
                + "Force Partial Restore — this run is the Normal method, so it was stopped "
                + "before any backup or restore work. Switch the method to Force Partial "
                + "Restore and run again.")
        }

        // PosterBoard, if the page has anything. One mechanism only — the
        // original Nugget method: the store's database first (a wallpaper
        // exists only once it has a row in it), then the wallpapers
        // themselves, delivered through the backup/restore tail below.
        var posterBoardPayloads: [TweakPayload] = []
        if posterBoard.isActive {
            log("PosterBoard: \(posterBoard.describe)")
            var structureVersion = PosterBoard.fallbackStructureVersion
            var database: URL?
            if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
                // A reset needs no database, so it needs no fetch and no exchange.
                log("PosterBoard: reset only — no database is needed, and none is fetched.")
            } else {
                let fetched = try await PosterBoardBackup.fetch(
                    backupRoot: AppPaths.posterBoardFetchRoot, udid: udid,
                    // The same fork `deliver` is about to take, from the same number.
                    ios27: major >= 27 && !DevSettings.effective.forcePartialRestore,
                    onProgress: { overall in
                        self.logProgress("posterboard backup progress", overall)
                    },
                    log: { AppLog.write($0) })
                database = fetched.database
                structureVersion = fetched.structureVersion
            }
            posterBoardPayloads = try await PosterBoard.compile(
                selection: posterBoard,
                structureVersion: structureVersion,
                database: database,
                deviceVersion: version,
                workingDirectory: PosterBoard.workDirectory,
                log: { AppLog.write($0) })
            let onDisk = posterBoardPayloads.filter { $0.source != nil }.count
            let total = posterBoardPayloads.reduce(0) { $0 + $1.byteCount }
            log("PosterBoard: \(posterBoardPayloads.count) payload(s), \(onDisk) of them on disk "
                + "(\(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)))")
        }

        // Skip setup, then the tweaks, then the status bar, then the wallpapers: one
        // array, one pass through the injector, which derives the directory rows from
        // each payload's path.  The order is the reference's — `add_skip_setup`
        // ahead of the tweaks, and `apply_classic_tweak` / `apply_ios27_tweak`
        // before the wallpapers — and it only actually matters for the two
        // skip-setup files, which land in the order they are appended.
        let payloads = skipSetup.payloads + tweakPayloads + statusBarPayloads
            + posterBoardPayloads + extraPayloads

        try await deliver(payloads: payloads, udid: udid, version: version, label: "apply") {
            log("Apply succeeded: the device confirmed it finished.")
            log("Reboot the device so the injected preferences take effect.")
            if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
                log("The PosterBoard store was cleared. Reboot the device, then add wallpapers "
                    + "from a fresh database fetch — a reset makes the copy fetched before it "
                    + "stale.")
            } else if posterBoard.isActive {
                log("Reboot the device so the PosterBoard store picks the new wallpapers up.")
            }
        }
    }

    // MARK: - Run: Force Partial Restore (v4 Options 2 + 3)
    //
    // A PARALLEL entry, not a branch of the one above: `applyTweaks` /
    // `applyTweaksRun` / `deliver` keep their exact Normal behaviour, and
    // this path shares nothing with the iOS 26 partial-restore
    // construction either (the locked v4 rule — the two must not touch).
    // What is shared is what the research says must be identical: the
    // payload assembly below mirrors `applyTweaksRun` step for step, and
    // the restore itself is the same `runRestore` / `RestoreRunner`
    // stack — byte-for-byte the proven one. (The Swift options dictionary
    // sets `RestoreShouldReboot: false`; `RemoveItemsNotRestored` is not
    // set in Swift and comes from the vendored Rust RestoreOptions
    // defaults — v4 audit item c: wire-confirm before device testing.)

    /// Apply the selection by Force Partial Restore: a host-synthesised
    /// sqlite-27 partial backup, restored with **no backup phase** —
    /// iOS 27 only (Options 2 and 3 of the v4 menu; `importPackage`
    /// non-nil is Option 3, whose rows `FPRImport.merge` folds in before
    /// the tweaks).
    ///
    /// The wrapper mirrors `applyTweaks` exactly, and that *is* the
    /// Remove-Tweaks / rollback bookkeeping: `prepareRollback()` inside
    /// the `loggedRun` bracket before the run, `saveLastApplied(...)`
    /// after it returns — reached only on success, as in `applyTweaks`.
    /// The remaining record —
    /// `AppliedTweaksStore.recordApply` — is written by the *view* after
    /// any successful engine apply (see `ApplyView`), not by the engine,
    /// so a caller of this entry records an FPR apply the same way it
    /// records a Normal one, with no engine-side difference.
    func applyTweaksFPR(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        deviceVersion: String,
        isIPhone: Bool,
        extraPayloads: [TweakPayload] = [],
        importPackage: URL? = nil
    ) async throws {
        try await loggedRun("apply (force partial restore)") {
            GoldenNuggetPresets.prepareRollback()
            try await applyTweaksFPRRun(selection: selection,
                                        posterBoard: posterBoard,
                                        statusBar: statusBar,
                                        deviceVersion: deviceVersion,
                                        isIPhone: isIPhone,
                                        extraPayloads: extraPayloads,
                                        importPackage: importPackage)
        }
        _ = GoldenNuggetPresets.saveLastApplied(selection: selection,
                                                deviceModel: isIPhone ? "iPhone" : "iPad",
                                                iosVersion: deviceVersion)
    }

    private func applyTweaksFPRRun(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        deviceVersion: String,
        isIPhone: Bool,
        extraPayloads: [TweakPayload] = [],
        importPackage: URL? = nil
    ) async throws {
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN apply (force partial restore)")
        defer { runStage.done() }

        log("[FPR] Force Partial Restore"
            + "\(importPackage != nil ? " + Import Backup" : "") — a host-synthesised "
            + "sqlite-27 partial restore. No protective backup will be pulled "
            + "and no AFC media pull will run in this method; both absences "
            + "are the method, not an omission.")

        // Payload assembly: the same steps, in the same order, as
        // `applyTweaksRun` — compile before the device is touched, status
        // bar on the caller's version, skip setup ahead of the tweaks.
        // Duplicated rather than factored out of `applyTweaksRun` so the
        // proven path's code is not touched to share it.
        let compiled = TweakCompiler.compile(selection: selection,
                                             deviceVersion: deviceVersion,
                                             isIPhone: isIPhone)
        let tweakPayloads = compiled.payloads

        var statusBarPayloads: [TweakPayload] = []
        if statusBar.isActive {
            let mechanism = StatusBarMechanism.mechanism(for: deviceVersion)
            let built = try statusBar.payload(for: mechanism)
            statusBarPayloads = [TweakPayload(domain: mechanism.domain,
                                              relativePath: mechanism.restorePath,
                                              contents: built.data)]
            log("Status bar: \(statusBar.overrides.activeCount) override(s)"
                + " \(statusBar.overrides.activeCount == 0 ? "(a reset)" : "") via "
                + "\(mechanism == .classic ? "the classic struct" : "the iOS 27 archive") "
                + "→ \(statusBarPayloads[0].label) (\(built.data.count) B)")
            for field in built.dropped {
                log("  ⚠️ \(field) has no counterpart in the iOS 27 archive and was not delivered")
            }
        }

        let skipSetup = SkipSetupSettings.shared.skipSetupEnabled
            ? SkipSetup.build(supervised: false, organizationName: "")
            : SkipSetup.Build(payloads: [], warnings: [])

        guard !tweakPayloads.isEmpty || !skipSetup.payloads.isEmpty || posterBoard.isActive
                || statusBar.isActive || !extraPayloads.isEmpty || importPackage != nil else {
            throw GoldenNuggetError("Nothing to apply: no tweak is enabled (or every enabled one "
                + "was skipped), skip setup is off, the status bar is untouched, there is "
                + "nothing selected on the PosterBoard page, and no backup package was "
                + "chosen to import.")
        }
        if !extraPayloads.isEmpty {
            log("Extra payloads: \(extraPayloads.count) file(s) from the caller")
            for payload in extraPayloads {
                log("  → \(payload.domain):\(payload.relativePath)")
            }
        }
        log("Tweaks: \(tweakPayloads.count) file(s) from \(compiled.locations.count) plist(s)")
        for location in compiled.locations { log("  → \(location.rawValue)") }
        for item in compiled.skipped { log("  ⚠️ skipped \(item.label): \(item.reason)") }
        if !skipSetup.payloads.isEmpty {
            log("Skip setup: \(skipSetup.payloads.count) file(s) ahead of the tweaks")
            for payload in skipSetup.payloads { log("  → \(payload.label)") }
            for warning in skipSetup.warnings { log("⚠️ \(warning)") }
        }

        // PosterBoard never rides Force Partial Restore (coordinator
        // ruling D3): it is Normal-method only, and its own Apply on the
        // PosterBoard page is the only entry that carries it. Refused
        // here, before any device work at all, rather than silently
        // dropping the wallpapers. General Apply no longer builds a
        // PosterBoard selection at all, so this gate is defence in depth
        // for any future caller that passes one in.
        if posterBoard.isActive {
            throw GoldenNuggetError("PosterBoard does not run through Force Partial "
                + "Restore — use the PosterBoard page's own Apply, which runs "
                + "the Normal backup/restore method.")
        }

        let udid = try await prepareRun()
        let version = try await resolvedDeviceVersion(deviceVersion)
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        log("device version for the Force Partial Restore gate: \(version) (major \(major))")

        // The same branch-integrity re-read `deliver` performs: this
        // run's == 27 gate below rests on the read just resolved, and a
        // wrong read in the dangerous direction (a 26 device read as 27)
        // would hand it a construction its restore cannot take. The
        // re-read goes through the same path (`DeviceIdentity.read()`),
        // and a disagreement — or an unreadable re-read — stops the run
        // before any synthesis or restore.
        let branchReread = await DeviceIdentity.read()
        let branchRereadMajor = Int(branchReread.version.split(separator: ".").first ?? "0") ?? 0
        log("[BRANCH] initial read: \(version) (major \(major)); "
            + "FPR re-read: \(branchReread.version.isEmpty ? "unreadable" : branchReread.version) "
            + "(major \(branchRereadMajor)); fork: force partial restore")
        guard !branchReread.version.isEmpty, branchRereadMajor == major else {
            throw GoldenNuggetError(
                "Device version read changed during setup (was \(version), now "
                + "\(branchReread.version.isEmpty ? "unreadable" : branchReread.version)) "
                + "— run stopped before any backup or restore. Reconnect the tunnel and retry.")
        }

        // The construction is 27-specific (Status 3.3 / Manifest 10.0 /
        // SystemDomainsVersion 24.0), so the gate is exact, not >=.
        guard major == 27 else {
            throw GoldenNuggetError("Force Partial Restore is iOS 27 only — "
                + "this device reports iOS \(version).")
        }

        // The legacy dev switch must not leak into this run: it selects
        // the MBDB branch inside `deliver`, a path FPR never takes, and
        // on iOS 27 that branch's synthesis is the one the device
        // rejects. Noted in the log when it is on, obeyed never.
        if DevSettings.effective.forcePartialRestore {
            log("[FPR] development mode's legacy force-partial-restore switch is on — "
                + "FPR ignores it: that switch selects the legacy MBDB branch, and "
                + "this run synthesises sqlite-27 regardless.")
        }

        // PosterBoard: none. The gate before `prepareRun` already threw
        // for any active PosterBoard selection, so no PB stage exists on
        // this path — not even the reset-only route the old code kept.
        // (D3: PB is Normal-method only.)
        let payloads = skipSetup.payloads + tweakPayloads + statusBarPayloads
            + extraPayloads

        // The whitelist gate: before synthesis, so a refused payload
        // costs no device work beyond the reads above.
        try FPRDomainWhitelist.validate(payloads)

        // No `protectiveBackup()` call and no AFC media pull exist on
        // this path — the synthesis replaces both.
        let backupRoot = try await ForcePartialRestore.makeBackup(
            udid: udid,
            payloads: payloads,
            importPackage: importPackage,
            log: { AppLog.write($0) })

        try await runRestore(backupRoot: backupRoot, udid: udid,
                             label: "apply (force partial restore)") {
            log("Apply succeeded (Force Partial Restore): the device confirmed it finished.")
            log("Reboot the device so the injected preferences take effect.")
            // No PosterBoard tail here: the gate above guarantees no PB
            // selection reaches this path.
        }
    }

    // MARK: - Run: Get Backup File (v4 Option 4)
    //
    // A standalone action, not an apply: pull the device-authored backup
    // once, keep it as a package under `BackupExportStore.root`, and hand
    // the package back. The package is what Option 3
    // (`applyTweaksFPR(..., importPackage:)`) later merges from.

    /// Pull a device-authored backup package the user can keep and
    /// re-import through Force Partial Restore + Import Backup.
    ///
    /// No version gate: this works on iOS 26 and 27. `deviceVersion` (the
    /// caller's read) is resolved through `resolvedDeviceVersion` — an
    /// unreadable version stops the run (the refuse-to-guess rule every
    /// format fork in this app follows) — but the resolved major only
    /// chooses `ProtectiveBackup.run`'s host seed (`ios27:`), so a 26
    /// device is seeded with its own Status 2.4 / Manifest 9.1 shape and
    /// no sqlite placeholder, instead of the iOS 27 seed every
    /// pre-existing caller of `run()` used. No second pull path is
    /// invented here for one family. Still unproven until a beta tester
    /// runs it: the pull machinery itself on a 26 device through this
    /// code path (the codebase's own iOS 26 paths never call `run()`).
    ///
    /// What the package carries — precisely, from the pull's own filter
    /// (`ProtectiveBackup.isProtectiveFile`, the mid-stream `shouldPreserve`
    /// that decides which offered payloads are ever written to disk):
    ///
    ///   * the backup metadata files (`Info.plist`, `Manifest.plist`,
    ///     `Manifest.db`, `Status.plist`) — with `Manifest.db` being the
    ///     device's own uploaded database (it replaces the host's
    ///     placeholder during the pull);
    ///   * `SystemPreferencesDomain` and `MessagesDomain` whole (the iOS 27
    ///     raw-tree message data, `Library/Messages` / `Library/SMS` /
    ///     `Library/MessagesMetaData`, is the same set in tree form);
    ///   * `HomeDomain` under the listed prefixes only: `Library/Accounts`,
    ///     `Library/ConfigurationProfiles`, `Library/Preferences`,
    ///     `Library/SpringBoard`, `Library/ControlCenter`,
    ///     `Library/Shortcuts`, `Library/WebClips`, `Library/WebApp`,
    ///     `Library/WebKit/WebsiteData`, `Library/AddressBook`.
    ///
    /// The package is the pull's raw product — **no prune runs on it** —
    /// so its `Manifest.db` also *lists* rows the filter drained (their
    /// payloads are missing or 0-byte placeholders; `CameraRollDomain` is
    /// the standing example: the manifest-coordinate keep-set
    /// `isProtectiveEntry`/`keepsRow` names it, while the mid-stream filter
    /// never preserves a media payload, as `ProtectiveBackup`'s own comment
    /// records). Listed is not carried, and telling the two apart is
    /// `FPRImport.merge`'s placeholder rules' whole job.
    ///
    /// What it does **not** carry: photos, videos and app containers — the
    /// filter drains them mid-stream — and the AFC media store, which is a
    /// separate mechanism (`AfcMediaBackup`) and not part of the package.
    ///
    /// No presets bookkeeping: nothing was applied, so there is no rollback
    /// record to prepare and no last-applied snapshot to save.
    func getBackupFile(deviceVersion: String) async throws -> URL {
        try await loggedRun("get backup file") {
            try await getBackupFileRun(deviceVersion: deviceVersion)
        }
    }

    private func getBackupFileRun(deviceVersion: String) async throws -> URL {
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN get backup file")
        defer { runStage.done() }

        log("Get Backup File: pulling a device-authored backup package to keep "
            + "(reported device version: \(deviceVersion.isEmpty ? "not read by the caller" : deviceVersion) "
            + "— not gated on: this pull runs on iOS 26 and 27)")

        let udid = try await prepareRun()
        // The host seed must match the device's own manifest format, so the
        // version IS resolved (and an unreadable version stops the run, the
        // same refuse-to-guess rule as every other format fork) — it only
        // chooses the seed, it never gates whether the pull may run.
        let version = try await resolvedDeviceVersion(deviceVersion)
        let seedIOS27 = Int(version.split(separator: ".").first ?? "") ?? 0 >= 27
        log("Get Backup File: seeding host manifests as \(seedIOS27 ? "iOS 27" : "iOS 26") format "
            + "(device version \(version))")

        let root = BackupExportStore.root
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Stage under the export root (dot-prefixed, so `packageURLs` never
        // lists it) and move the finished device directory into place: a
        // failed or interrupted pull must leave no partial package behind.
        let stagingRoot = root.appendingPathComponent(".staging-\(UUID().uuidString)",
                                                      conformingTo: .data)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        do {
            try await ProtectiveBackup.run(backupRoot: stagingRoot, udid: udid, ios27: seedIOS27) { overall in
                self.logProgress("backup progress", overall)
            }
            log("Protective backup pull complete — packaging it for export.")
            clearProgress()

            let pulledDir = AppPaths.deviceDir(backupRoot: stagingRoot, udid: udid)
            guard fm.fileExists(atPath: pulledDir.appendingPathComponent("Manifest.db").path) else {
                throw GoldenNuggetError(
                    "The pull finished but left no Manifest.db in the backup it "
                    + "produced, so there is no device-authored package to keep. "
                    + "Nothing was exported.")
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            var packageName = "\(formatter.string(from: Date()))-\(String(udid.prefix(8)))"
            var package = root.appendingPathComponent(packageName, conformingTo: .data)
            var suffix = 2
            while fm.fileExists(atPath: package.path) {
                packageName = "\(formatter.string(from: Date()))-\(String(udid.prefix(8)))-\(suffix)"
                package = root.appendingPathComponent(packageName, conformingTo: .data)
                suffix += 1
            }
            try fm.moveItem(at: pulledDir, to: package)
            try? fm.removeItem(at: stagingRoot)

            let size = BackupExportStore.size(of: package)
            let rows = ManifestStore(deviceDir: package).rowCount()
            log("Backup package exported: \(package.path)")
            log("package: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), "
                + "\(rows) manifest row(s) — the device-authored protective set "
                + "(SystemPreferencesDomain, MessagesDomain, and the HomeDomain "
                + "preference/SpringBoard/accounts subtrees the backup filter "
                + "preserves). Photos, videos and app containers are NOT in it: "
                + "the filter drains them, and the AFC media store is a separate "
                + "mechanism that is not part of the package. Status.plist / "
                + "Manifest.plist / Info.plist are the ones the pull left in the "
                + "device directory, and Manifest.db is the device's own.")
            return package
        } catch {
            // Leave no partial package: the staging tree goes, the original
            // error stands.
            try? fm.removeItem(at: stagingRoot)
            throw error
        }
    }

    /// Fetch only the device's PosterBoard database, without applying anything.
    ///
    /// There is deliberately no UI button for this (coordinator ruling D6):
    /// a PosterBoard apply fetches its own database in-run, and a copy
    /// fetched before a reset is stale, so a fetched copy must never be an
    /// apply input. The reference has the same standalone fetch (its "Fetch
    /// Database File" wizard in `pb_dialog.py`) for the same reason: the fetch
    /// is the one stage of a wallpaper apply that can fail on its own terms —
    /// the device decides whether it will upload the container. The result is
    /// cached at `PosterBoardBackup.cachedDatabase(udid:)`, and an apply reuses
    /// nothing: it fetches its own.
    func fetchPosterBoardDatabase() async throws {
        try await loggedRun("posterboard database fetch") {
            try await fetchPosterBoardDatabaseRun()
        }
    }

    private func fetchPosterBoardDatabaseRun() async throws {
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        let stage = StageTimer("RUN posterboard database fetch")
        defer { stage.done() }

        let udid = try await prepareRun()
        _ = try await PosterBoardBackup.fetch(
            backupRoot: AppPaths.posterBoardFetchRoot, udid: udid,
            onProgress: { overall in self.logProgress("posterboard backup progress", overall) },
            log: { AppLog.write($0) })
        log("PosterBoard database fetched and validated.")
    }

    // MARK: - Run: PosterBoard only (its own Apply / Remove menus)

    /// Apply or reset PosterBoard — and nothing else — through the one
    /// remaining mechanism, the original Nugget backup/restore method.
    ///
    /// This is deliberately NOT `applyTweaksRun` with empty selections
    /// (coordinator ruling D7): that run would drag skip-setup payloads
    /// and the status-bar iOS 27 gate along with a "PosterBoard-only" run.
    /// What this run does carry, verbatim from the Normal run's PosterBoard
    /// stage, is: the reset-no-database shortcut, the in-run device
    /// database fetch for tendies, `PosterBoard.compile` (so the
    /// compile-order rule — reset beats tendies, never mixed — and the
    /// 5-file / 10-descriptor caps enforced by the caller hold), and the
    /// shared `deliver()` tail. `deliver()` is the same tail a bundled
    /// run used, so the iOS 26 MBDB / iOS 27 protective-backup fork, the
    /// prune-and-inject step (including its `posterBoardSnapshot: nil`
    /// default — no live caller passes a snapshot, bundled runs included),
    /// and the restore are byte-for-byte the bundled path's.
    ///
    /// What this run does NOT do, on purpose: it never touches
    /// `GoldenNuggetPresets` (a PB-only run must not overwrite the general
    /// rollback preset with an empty selection), never records into
    /// `AppliedTweaksStore` (PB ids are excluded there by design — the
    /// caller does not record either), and never enters Force Partial
    /// Restore (PB is Normal-method only).
    func applyPosterBoardOnly(_ selection: PosterBoardSelection,
                              deviceVersion: String) async throws {
        try await loggedRun("posterboard apply") {
            try await applyPosterBoardOnlyRun(selection, deviceVersion: deviceVersion)
        }
    }

    private func applyPosterBoardOnlyRun(_ selection: PosterBoardSelection,
                                         deviceVersion: String) async throws {
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        let stage = StageTimer("RUN posterboard apply")
        defer { stage.done() }

        guard selection.isActive else {
            throw GoldenNuggetError("Nothing selected on the PosterBoard page: "
                + "stage Tendies wallpapers or a PosterBoard reset first.")
        }

        let udid = try await prepareRun()
        let version = try await resolvedDeviceVersion(deviceVersion)
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        log("device version for the manifest-format fork: \(version) (major \(major))")

        log("PosterBoard: \(selection.describe)")
        var structureVersion = PosterBoard.fallbackStructureVersion
        var database: URL?
        if selection.fullReset || !selection.resetModes.isEmpty {
            // A reset needs no database, so it needs no fetch and no exchange.
            log("PosterBoard: reset only — no database is needed, and none is fetched.")
        } else {
            let fetched = try await PosterBoardBackup.fetch(
                backupRoot: AppPaths.posterBoardFetchRoot, udid: udid,
                // The same fork `deliver` is about to take, from the same number.
                ios27: major >= 27 && !DevSettings.effective.forcePartialRestore,
                onProgress: { overall in
                    self.logProgress("posterboard backup progress", overall)
                },
                log: { AppLog.write($0) })
            database = fetched.database
            structureVersion = fetched.structureVersion
        }
        let payloads = try await PosterBoard.compile(
            selection: selection,
            structureVersion: structureVersion,
            database: database,
            deviceVersion: version,
            workingDirectory: PosterBoard.workDirectory,
            log: { AppLog.write($0) })
        let onDisk = payloads.filter { $0.source != nil }.count
        let total = payloads.reduce(0) { $0 + $1.byteCount }
        log("PosterBoard: \(payloads.count) payload(s), \(onDisk) of them on disk "
            + "(\(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)))")
        guard !payloads.isEmpty else {
            throw GoldenNuggetError("PosterBoard compiled to nothing — no payload was "
                + "produced for this selection, so no backup or restore was run.")
        }

        try await deliver(payloads: payloads, udid: udid, version: version,
                          label: "posterboard apply") {
            log("PosterBoard apply succeeded: the device confirmed it finished.")
            if selection.fullReset || !selection.resetModes.isEmpty {
                log("The PosterBoard store was cleared. Reboot the device, then add wallpapers "
                    + "from a fresh database fetch — a reset makes the copy fetched before it "
                    + "stale.")
            } else {
                log("Reboot the device so the PosterBoard store picks the new wallpapers up.")
            }
        }
    }

    // MARK: - The shared delivery tail
    //
    // Both applies end in the same four stages, and the order is load-bearing:
    // the manifest-format fork decides whether there is anything to prune, the
    // pull is what authorizes the session, the prune must precede the injection,
    // and the restore is what delivers any of it.

    /// One payload set through stages 1–4.  `udid` and `version` come from the caller:
    /// the PosterBoard stage talks to the device (and needs the version) before this
    /// runs, so resolving them again here would be a second answer to a settled question.
    private func deliver(
        payloads: [TweakPayload],
        udid: String,
        version: String,
        label: String,
        onSuccess: () -> Void
    ) async throws {
        // The two versions take opposite paths, and the split is the
        // reference's one-line fork (`backup.py:113`) widened to the whole run:
        // iOS 26 speaks legacy MBDB and can have a backup built for it from
        // nothing, iOS 27+ speaks the modern sqlite Manifest.db and must keep
        // the device's own state. Comparing "26.0" against "27.0" lexically
        // would put 26.9 on the wrong side, so compare the major component.
        //
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        // Development mode can force the iOS 26 branch, so the reported version is no
        // longer the last word on which branch runs -- only the default for it. Read
        // once, here, and both decisions below quote the same snapshot.
        let dev = DevSettings.effective

        // Branch-integrity guard (2026-10-24): the fork below rests on the
        // one version read the caller resolved, and a reporter on iOS
        // 26.7.1 was wrongly sent down the iOS 27 protective path by a
        // single wrong read. (Known gap, v4 audit item h, partly
        // closed in step 5: `resetPagesRun` still forks inline and
        // never passes through here, so this guard does not cover
        // page-reset runs; `removeAppliedTweaksRun` now carries its
        // own copy of the guard, placed before its fork.) So the read is repeated here — through the
        // same path `resolvedDeviceVersion` uses, `DeviceIdentity.read()`
        // (lockdown ProductVersion) — immediately before the fork is
        // computed, and the two reads must agree on the major component
        // or the run stops BEFORE any backup or restore work. When they
        // agree nothing changes: same fork, same lines after this one.
        let branchReread = await DeviceIdentity.read()
        let branchRereadMajor = Int(branchReread.version.split(separator: ".").first ?? "0") ?? 0
        let branchFork = major >= 27 && !dev.forcePartialRestore ? "protective" : "partial"
        log("[BRANCH] initial read: \(version) (major \(major)); "
            + "pre-fork re-read: \(branchReread.version.isEmpty ? "unreadable" : branchReread.version) "
            + "(major \(branchRereadMajor)); fork: \(branchFork)")
        guard !branchReread.version.isEmpty, branchRereadMajor == major else {
            throw GoldenNuggetError(
                "Device version read changed during setup (was \(version), now "
                + "\(branchReread.version.isEmpty ? "unreadable" : branchReread.version)) "
                + "— run stopped before any backup or restore. Reconnect the tunnel and retry.")
        }

        let ios27 = major >= 27 && !dev.forcePartialRestore
        let hasEligibility = payloads.contains { $0.domain == "SysContainerDomain-com.apple.eligibilityd" }
        if hasEligibility && !ios27 {
            throw GoldenNuggetError("Siri AI overrides require an unencrypted protective backup. Disable forced partial restore and retry.")
        }
        // Reported before the fork, because this number *is* the fork: the
        // branch lines below say where the run went, this says why.
        log("device version for the manifest-format fork: \(version) (major \(major))")
        if dev.forcePartialRestore {
            log("development mode: forcing the iOS 26 branch on a major \(major) device "
                + "-- no protective backup will be pulled")
        }

        // iOS 26: a Partial Restore, built rather than pulled -- an empty device
        // directory, the host-side manifests, then this run's rows. Nothing was
        // pulled, so there is no device state to reconcile against and the
        // prune would only discard what this run just wrote.
        //
        // iOS 27: the protective backup, pulled from the device, then pruned to
        // what is on disk before injection. A synthesized manifest is not enough
        // here: `restored` rejects a domain it cannot resolve ("Failed to
        // prepare INSERT for ManagedPreferencesDomain") because the real one
        // carries the device's own domain registration.
        let backupRoot: URL
        let prune: Bool
        if ios27 {
            log("Manifest format: sqlite (iOS 27+ path), protective backup pulled")
            backupRoot = try await protectiveBackup(udid: udid)
            if hasEligibility {
                let manifestURL = backupRoot.appendingPathComponent(udid).appendingPathComponent("Manifest.plist")
                let data = try Data(contentsOf: manifestURL)
                let manifest = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                guard manifest?["IsEncrypted"] as? Bool == false else {
                    throw GoldenNuggetError("Siri AI overrides require a confirmed unencrypted protective backup. Disable local backup encryption in Finder/iTunes and retry.")
                }
            }
            prune = true
            // Media over AFC, after the backup and before the prune: the backup
            // filter rejects the media domains, so this is the only thing that
            // collects them, and doing it here means an apply is the one action
            // that leaves media preserved rather than only tweaks applied.
            //
            // Deletion stays off. A run is not the place to remove the user's
            // photos: it is started to apply tweaks, and the media page is where
            // that choice is made with a count and a free-space figure in front
            // of the user.
            if dev.skipAfcMedia {
                log("development mode: skipping the AFC media pull (Dev.SkipAfcMedia)")
            } else {
                clearProgress()
                log("AFC media: collecting media files…")
                await mediaBackup(deletingOriginals: false)
            }
        } else {
            log("Manifest format: legacy MBDB (iOS 26 path), built from nothing")
            backupRoot = try await partialRestore(udid: udid)
            prune = false
        }

        clearProgress()
        log("Pruning and injecting tweaks…")
        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            tweakPayloads: payloads,
            prune: prune,
            ios27: ios27
        )

        try await runRestore(backupRoot: backupRoot, udid: udid, label: label,
                             onSuccess: onSuccess)
    }

    /// Put the named pages back to stock, on the device.
    ///
    /// A port of `device_manager.reset_tweaks` (`device_manager.py:1104`): a
    /// fixed set of files written over the device's own, with nothing read back
    /// first — no psysbackup capture, on either branch. The page set comes from
    /// the picker the reference's `ResetDialog` offers, not from this app's
    /// tweak selection; the two are unrelated, and the reference's dialog is
    /// likewise built from `get_resettable_pages`, not from what is enabled.
    ///
    /// It is the same pipeline as `applyTweaks` with a different payload list, so
    /// it reuses `protectiveBackup` / `partialRestore` / `pruneAndInject` /
    /// `runRestore` rather than growing a second restore path. The two branches
    /// differ in what a nulled file is written as (0 bytes vs. a valid empty
    /// plist — `TweakReset` has the table and the reason) and in which manifest
    /// the run needs, for the same reason the apply forks:
    ///
    /// * **iOS 27+** speaks the modern sqlite `Manifest.db` and rejects a
    ///   synthesized one ("Failed to prepare INSERT for ManagedPreferencesDomain"
    ///   — the real one carries the device's own domain registration), so the
    ///   reset pulls the protective backup and prunes it, exactly as an apply
    ///   does. It does **not** pull media: a reset is a preferences operation and
    ///   the backup filter rejects the media domains anyway.
    /// * **iOS 26** speaks legacy MBDB and can have a backup built for it from
    ///   nothing, so the reset synthesises one.
    ///
    /// What is deliberately absent is the reference's `clear_lastapply`: it drops
    /// the apply record so a later apply does not skip Phase 2 against a reset
    /// device, and there is no phase-2 skip in this port to guard. The app's own
    /// selection is left alone too, exactly as the reference leaves the tweaks
    /// page as the user had it — the reset is of the *device*, and the selection
    /// is what would put the tweaks back.
    func resetPages(pages: Set<ResetPage>) async throws {
        try await loggedRun("page reset") { try await resetPagesRun(pages: pages) }
    }

    private func resetPagesRun(pages: Set<ResetPage>) async throws {
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN page reset")
        defer { runStage.done() }

        guard !pages.isEmpty else {
            throw GoldenNuggetError("No page was selected — nothing to reset.")
        }

        let udid = try await prepareRun()

        // Read the version here for the same reason the apply does: the pages
        // read it before lockdown answers, so a value of "" would put a 27
        // device on the 26 branch and hand it 0-byte plists.
        let version = try await resolvedDeviceVersion("")
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        let dev = DevSettings.effective
        let ios27 = major >= 27 && !dev.forcePartialRestore

        let plan = TweakReset.plan(pages: pages, ios27: ios27)
        guard !plan.payloads.isEmpty else {
            throw GoldenNuggetError("Every selected page resolved to no file — nothing to reset.")
        }

        // The reference appends the skip-setup files to the *reset's* file list
        // too (`add_skip_setup(files_to_restore, uses_domains)`, called after the
        // null loop and before `start_restore`), subject to its own gate — which
        // on iOS 27 only passes when the file list already restores real domains,
        // and in the reset path that means the Daemons page was ticked. Reproduced
        // as written; see `TweakReset.skipSetupAllowed(pages:ios27:)`.
        let skipSetupOn = SkipSetupSettings.shared.skipSetupEnabled
        let skipSetup: SkipSetup.Build
        if !skipSetupOn {
            skipSetup = SkipSetup.Build(payloads: [], warnings: [])
        } else if plan.skipSetupAllowed {
            skipSetup = SkipSetup.build(supervised: false, organizationName: "")
        } else {
            skipSetup = SkipSetup.Build(payloads: [], warnings: [])
            log("Skip Setup is on, but the reference omits its two files here: on iOS 27 "
                + "the reset restores no real domain unless the Daemons page is ticked, "
                + "and that is its `add_skip_setup` condition. Tick Daemons, or reset on "
                + "iOS 26, to include them.")
        }

        log("Reset: \(pages.count) page(s) — \(plan.targets.count) file(s) on iOS \(version)")
        for target in plan.targets {
            log("  → \(target.path) [\(target.kind.rawValue), "
                + "\(target.contents.count) bytes]")
        }
        for item in plan.skipped { log("  ⚠️ skipped \(item.label): \(item.reason)") }
        for page in ResetPage.allCases where pages.contains(page) {
            log("  page \(page.title): \(page.locations.count) file(s)")
        }
        if ios27 {
            log("iOS 27 branch: a nulled file is written as a valid empty plist, not 0 bytes — "
                + "a truncated plist is a SpringBoard boot loop on this release. Nothing is read "
                + "back from the device first: this is the reference's own no-capture fallback, "
                + "not a psysbackup restore of the original values.")
        } else {
            log("iOS 26 branch: a nulled file is written as 0 bytes, over a synthesised MBDB "
                + "backup (no device content pulled).")
        }

        let backupRoot: URL
        let prune: Bool
        if ios27 {
            log("Manifest format: sqlite (iOS 27+ path), protective backup pulled, then pruned")
            backupRoot = try await protectiveBackup(udid: udid)
            prune = true
        } else {
            log("Manifest format: legacy MBDB (iOS 26 path), built from nothing")
            backupRoot = try await partialRestore(udid: udid)
            prune = false
        }

        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            // Same order as the reference's file list: the daemons file first, then
            // the nulled ones, then the two skip-setup files last — the reference
            // calls `add_skip_setup` after the null loop.
            tweakPayloads: plan.payloads + skipSetup.payloads,
            prune: prune,
            ios27: ios27
        )

        try await runRestore(backupRoot: backupRoot, udid: udid, label: "page reset") {
            log("Reset succeeded: the device confirmed it finished.")
            log("The pages above are back to their defaults. The selections in this app are "
                + "untouched — applying again would write the tweaks back.")
            log("Reboot the device so the restored files take effect.")
        }
    }

    /// Remove Tweaks: turn off exactly the tweaks the app recorded as
    /// applied, by nulling the files they live in (the `TweakReset`
    /// locations plan). Same delivery pipeline as the page reset —
    /// protective backup first on iOS 27, verdict-based restore — with
    /// two differences: no skip-setup files ever ride along, and the
    /// null is a valid empty plist on every version (see the plan's
    /// doc for the iOS 26.2+ boot-loop reason).
    ///
    /// Removal is per FILE, not per key: every tweak sharing a nulled
    /// file turns off with it. The Remove page groups the recorded
    /// tweaks by file so that is visible before the run starts.
    ///
    /// WorkSlop-only entry point (the fork has no equivalent): carried
    /// over from the previous engine unchanged, except the old
    /// start-gate refusal — `loggedRun`'s `InFlightCall` run bracket
    /// now refuses a second concurrent run before this body starts.
    func removeAppliedTweaks(locations: Set<TweakFileLocation>,
                             includeStatusBar: Bool) async throws {
        try await loggedRun("remove tweaks") {
            try await removeAppliedTweaksRun(locations: locations,
                                             includeStatusBar: includeStatusBar)
        }
    }

    private func removeAppliedTweaksRun(locations: Set<TweakFileLocation>,
                                        includeStatusBar: Bool) async throws {
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN remove tweaks")
        defer { runStage.done() }

        var locations = locations
        if includeStatusBar { locations.remove(.statusBarOverridesArchive) }
        guard !locations.isEmpty || includeStatusBar else {
            throw GoldenNuggetError("Nothing to remove — the recorded tweaks resolve to no file.")
        }

        let udid = try await prepareRun()
        let version = try await resolvedDeviceVersion("")
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        let dev = DevSettings.effective
        let ios27 = major >= 27 && !dev.forcePartialRestore

        // Branch-integrity guard, the same pattern `deliver()` uses:
        // the fork below — and the `ios27:` plan that follows it
        // (the status bar mechanism is archive on 27, classic on
        // 26) — rests on the one version read just resolved, and a
        // single wrong read in the dangerous direction (a 26 device
        // read as 27) would send it down the sqlite protective path.
        // Re-read through the same path (`DeviceIdentity.read()`)
        // immediately before the fork, and stop the run before any
        // backup or restore work when the two reads disagree on
        // the major component — or when the re-read is unreadable.
        let branchReread = await DeviceIdentity.read()
        let branchRereadMajor = Int(branchReread.version.split(separator: ".").first ?? "0") ?? 0
        let branchFork = ios27 ? "protective" : "partial"
        log("[BRANCH] initial read: \(version) (major \(major)); "
            + "pre-fork re-read: \(branchReread.version.isEmpty ? "unreadable" : branchReread.version) "
            + "(major \(branchRereadMajor)); fork: \(branchFork)")
        guard !branchReread.version.isEmpty, branchRereadMajor == major else {
            throw GoldenNuggetError(
                "Device version read changed during setup (was \(version), now "
                + "\(branchReread.version.isEmpty ? "unreadable" : branchReread.version)) "
                + "— run stopped before any backup or restore. Reconnect the tunnel and retry.")
        }

        let plan = TweakReset.plan(locations: locations,
                                   includeStatusBar: includeStatusBar, ios27: ios27)
        guard !plan.payloads.isEmpty else {
            throw GoldenNuggetError("Every recorded file was skipped — nothing to remove.")
        }

        log("Remove: \(plan.targets.count) file(s) on iOS \(version)")
        for target in plan.targets {
            log("  → \(target.path) [\(target.kind.rawValue), "
                + "\(target.contents.count) bytes]")
        }
        for item in plan.skipped { log("  ⚠️ skipped \(item.label): \(item.reason)") }
        log("A nulled file is written as a valid empty plist on every version — "
            + "not 0 bytes (a truncated plist is a SpringBoard boot loop on "
            + "iOS 26.2+). Readers fall back to their defaults.")

        let backupRoot: URL
        let prune: Bool
        if ios27 {
            log("Manifest format: sqlite (iOS 27+ path), protective backup pulled, then pruned")
            backupRoot = try await protectiveBackup(udid: udid)
            prune = true
        } else {
            log("Manifest format: legacy MBDB (iOS 26 path), built from nothing")
            backupRoot = try await partialRestore(udid: udid)
            prune = false
        }

        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            tweakPayloads: plan.payloads,
            prune: prune,
            ios27: ios27
        )

        try await runRestore(backupRoot: backupRoot, udid: udid, label: "remove tweaks") {
            log("Remove succeeded: the device confirmed it finished.")
            log("The files above are back to their defaults. Reboot the device "
                + "so the change takes effect.")
        }
    }

    /// The AFC media stage, as a stage rather than a separate button so the run
    /// log tells the whole story in one place.
    private func mediaBackup(deletingOriginals: Bool) async {
        do {
            let survey = try await AfcMediaBackup.survey()
            guard !survey.files.isEmpty else {
                log("AFC media: nothing in \(AfcMediaBackup.trees.joined(separator: "/")) "
                    + "— skipped")
                return
            }
            log("AFC media: pulling \(survey.files.count) file(s), \(survey.bytes) byte(s)")
            let manifest = try await AfcMediaBackup.pull(deletingOriginals: deletingOriginals) {
                self.log($0)
            }
            let removed = manifest.entries.filter(\.deleted).count
            log("AFC media: stored \(manifest.entries.count) file(s), \(removed) removed "
                + "from the device")
        } catch {
            // Not fatal to the tweak apply. The store is a copy, not a
            // precondition for writing preferences, and a media failure must not
            // cost the user the tweak run they started.
            log("AFC media: FAILED — \(error.localizedDescription)")
        }
        clearProgress()
    }

    // MARK: - Protective flow stages
    //
    // The full flow, kept in one place because the order is load-bearing.

    /// Stage 1: the working backup, into `<Documents>/<udid>/`.
    ///
    /// A Partial Restore, so it is built rather than pulled: an empty device
    /// directory, then the host-side manifests, then this run's rows and
    /// payloads. There is no user content to preserve and nothing to wipe, which
    /// is why the reference's three-phase flow (and its safe-state recovery) has
    /// no part here on iOS 26 -- the restore lands on the live device.
    private func partialRestore(udid: String) async throws -> URL {
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)
        log("Partial Restore: synthesising backup at \(backupRoot.lastPathComponent) "
            + "(no device content pulled)")
        return backupRoot
    }

    /// A real protective backup into `<Documents>/<udid>/`.
    private func protectiveBackup(udid: String) async throws -> URL {
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)
        try await ProtectiveBackup.run(backupRoot: backupRoot, udid: udid, captureUploadSize: true) { overall in
            self.logProgress("backup progress", overall)
        }
        log("Protective backup complete.")
        clearProgress()
        return backupRoot
    }

    // MARK: - Shared run plumbing
    //
    // The sequence below is order-sensitive, so it lives in one place.

    /// Everything a run does before touching the device.
    ///
    /// Returns the device UDID (needed to name the backup root).  Throws
    /// `GoldenNuggetError` for the operator-facing failures.
    private func prepareRun() async throws -> String {
        let minimuxer = Minimuxer.shared()
        guard await testReady(minimuxer) else {
            throw GoldenNuggetError("minimuxer is not ready. Ensure WiFi and a working tunnel (LocalDevVPN or WireGuard + em_proxy), then select a pairing file.")
        }
        guard let udid = try await minimuxer.core.fetchUDID() else {
            throw GoldenNuggetError("Could not fetch device UDID")
        }
        log("UDID: \(udid)")
        log("Tunnel: \(Tunnel.describe())")
        try await Diagnostics.preflightBackupEncryption()
        // Everything after this byte offset is this run's Rust output.
        markRustLog()

        return udid
    }

    /// The version the manifest-format fork branches on — never a guess.
    ///
    /// An empty `fallback` means "the page never managed to read it" (it reads
    /// once, when it appears, and lockdown may not have been answering yet), and
    /// **not** "iOS 26". Parsing it as 0 used to send a 27.0 device down the
    /// legacy branch, which cannot work there: that branch synthesises a backup
    /// from nothing, and what the device answers is
    /// `MBErrorDomain/205 — No keybag in manifest` (2026-09-26).
    ///
    /// So re-read lockdown — `prepareRun()` has just shown it is ready — and
    /// refuse to continue if even that fails. Refusing beats defaulting: the two
    /// branches want different manifest formats, and a wrong pick costs the
    /// operator a whole run plus a puzzle like this one.
    private func resolvedDeviceVersion(_ fallback: String) async throws -> String {
        if !fallback.isEmpty { return fallback }
        log("device version: the caller had none (it read the identity before lockdown answered) "
            + "— re-reading before the format fork")
        let identity = await DeviceIdentity.read()
        guard !identity.version.isEmpty else {
            throw GoldenNuggetError(
                "Could not read the device's iOS version (lockdown ProductVersion), which this run "
                + "needs to choose a manifest format: iOS 27+ gets a protective backup pulled from the "
                + "device with a sqlite Manifest.db, iOS 26 a legacy MBDB backup synthesised on the "
                + "host. Unlock the device, confirm the tunnel is up, then run again.")
        }
        log("device version: lockdown answered \(identity.version)")
        return identity.version
    }

    /// Start from an empty backup root.  Both flows need this: the manifest is
    /// merged into, not replaced, so a leftover Manifest.db from a previous run
    /// would leak its rows (and its pruned keep-set) into this one.
    private func resetDirectory(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Clamp and throttle a Rust progress callback down to whole percent.
    ///
    /// The callback fires per file; logging every call appended thousands of
    /// lines and pushed the interesting ones out of the UI list.
    private func logProgress(_ prefix: String, _ overall: Double) {
        let pct = overall < 0 ? 0 : min(overall, 100)
        reportProgress(pct)
        log(String(format: "\(prefix): %.0f%%", pct))
    }

    /// Stage 4: one mobilebackup2 restore, with the iOS-27 transient-channel
    /// retry in front of it.
    ///
    /// `onSuccess` carries only the success wording — the two flows describe
    /// their outcome differently, but the failure line is the same.
    private func runRestore(
        backupRoot: URL,
        udid: String,
        label: String,
        onSuccess: () -> Void
    ) async throws {
        // Say what is being offered before offering it.  Every recorded "the
        // restore said success but only part came back" run so far has had to be
        // reconstructed from the prune / inject / placeholder lines after the
        // fact; this puts the same numbers in one place, at the moment they are
        // still actionable.
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        log(ManifestStore(deviceDir: deviceDir).auditAgainstDisk())

        clearProgress()
        log("Restoring backup… (this is the stage that finalizes on the device)")
        let code = try await ChannelRecovery.retry(
            label: label,
            attempts: 3,
            diagnostics: { await Diagnostics.report() }
        ) {
            try await RestoreRunner.run(backupRoot: backupRoot, sourceIdentifier: udid)
        }

        if code == 0 {
            onSuccess()
        } else {
            // Unreachable while RestoreRunner verifies its own outcome, but kept
            // so a future path that stops doing so cannot fail silently.
            log("restore returned \(code) without confirming completion — inspect the log above.")
        }
    }

    // MARK: - Readiness

    private func testReady(_ minimuxer: Minimuxer) async -> Bool {
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        return false
    }
}
