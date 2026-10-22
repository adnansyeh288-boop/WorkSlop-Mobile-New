import SwiftUI

/// Apply: the real thing. Preflight checks, then the GoldenNugget
/// engine runs the staged selection in one pass:
///
/// - iOS 26: partial (sparse) restore, no wipe.
/// - iOS 27+: a protective backup of all data first, then the
///   modified backup is restored. The engine never reboots the
///   phone — the user restarts manually afterwards.
///
/// Progress, ETA and log lines all come from the engine's own
/// callbacks; success is only reported when the engine's run
/// returns without throwing.
///
/// Cancel is the engine's cancel flag: the run stops at its next
/// checkpoint. A restore already in flight may finish or stop
/// part-way — the result text says so instead of pretending the
/// cancel was instant or total.
struct ApplyView: View {
    @EnvironmentObject private var status: StatusStore
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var iconStage: IconThemeStage

    @State private var running = false
    @State private var cancelling = false
    /// Whole percent 0–100 from the engine; nil when it has not
    /// reported yet (it reports NaN when a run's progress clears).
    @State private var progressPercent: Double?
    @State private var etaText = ""
    @State private var logLines: [String] = []
    @State private var lastLoggedPercent = -1
    @State private var result: ApplyResult?
    @State private var showRestartSheet = false
    @State private var applyTask: Task<Void, Never>?

    private enum ApplyResult {
        case succeeded
        case failed(String)
        case cancelled
    }

    var body: some View {
        List {
            Section {
                preflightRow("Tweaks staged", ok: !selection.staged.isEmpty,
                             detail: "\(selection.staged.count)")
                if !iconStage.staged.isEmpty {
                    preflightRow("Icon themes staged", ok: true,
                                 detail: "\(iconStage.staged.count)")
                }
                preflightRow("Build support", ok: BuildSupport.current != .unsupported,
                             detail: BuildSupport.current.displayText)
                preflightRow("Pairing file imported", ok: status.pairingImported, detail: nil)
                preflightRow("VPN tunnel detected", ok: status.vpnDetected, detail: nil)
            } header: {
                Text("Preflight")
            } footer: {
                Text(routeText)
            }

            if running {
                Section(cancelling ? "Cancelling…" : "Running") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(progressPercent.map { "\(Int($0))%" } ?? "—")
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                            Spacer()
                            Text(cancelling ? "Stopping…" : (etaText.isEmpty ? "Working…" : etaText))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let progressPercent {
                            ProgressView(value: progressPercent, total: 100)
                        } else {
                            ProgressView()
                        }
                        Text(cancelling
                             ? "Cancel requested — the engine stops at its next checkpoint…"
                             : "Progress and log lines come straight from the engine.")
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }

                Section("Log") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(logLines.indices, id: \.self) { i in
                                    Text(logLines[i])
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .id(i)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 220)
                        .onChange(of: logLines.count) { _ in
                            if let last = logLines.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            if let result {
                Section("Result") {
                    switch result {
                    case .succeeded:
                        Label("Sent - restart your iPhone manually", systemImage: "checkmark.circle")
                            .foregroundStyle(Color.green)
                        Text("The engine finished and the device confirmed the restore. Reboot from Settings → General → Shut Down, then verify the tweaks.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Label("Failed", systemImage: "xmark.circle")
                            .foregroundStyle(Color.red)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .cancelled:
                        Label("Cancelled", systemImage: "stop.circle")
                            .foregroundStyle(Color.orange)
                        Text("The engine stopped at a checkpoint after your cancel request. If a restore was already in flight it may have finished or stopped part-way — re-run Apply to complete the changes, and restart your iPhone afterwards either way.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(running ? "Applying…" : "Apply now") {
                    startApply()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(!canStart || running)
                .accessibilityIdentifier("apply-now")

                if running {
                    Button(cancelling ? "Cancelling…" : "Cancel", role: .destructive) {
                        cancelApply()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(cancelling)
                    .accessibilityIdentifier("apply-cancel")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cancel asks the engine to stop at its next checkpoint. If cancelled while a restore is in flight, re-run Apply to complete the changes.")
                    Text("IMPORTANT: if Cancel does not respond or the app hangs, you MUST fully close WorkSlop (swipe it away from the app switcher). If the problem persists, restart your iPhone manually (Settings → General → Shut Down). This is required to keep your device safe.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Apply")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRestartSheet) {
            NavigationStack {
                List {
                    Section {
                        Label("Apply complete", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                            .font(.headline)
                        Text("The engine finished and the device confirmed the restore. Now restart your iPhone so SpringBoard picks up the new files.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Section("How to restart") {
                        Label("Open Settings → General → Shut Down", systemImage: "1.circle")
                        Label("Slide to power off, wait 10 seconds", systemImage: "2.circle")
                        Label("Hold the side button until the Apple logo appears", systemImage: "3.circle")
                        Label("After reboot, check that your tweaks are active", systemImage: "4.circle")
                    }
                    Section {
                        Text("If a tweak didn't take effect, re-run Apply — it sends the full staged set again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Restart your iPhone")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showRestartSheet = false }
                    }
                }
            }
        }
    }

    // MARK: - State

    private var canStart: Bool {
        status.unlocked && (!selection.staged.isEmpty || !iconStage.staged.isEmpty)
    }

    private var routeText: String {
        let major = DeviceInfo.iosVersion.major
        if major >= 27 {
            return "This device runs iOS \(major): protective backup → modify → restore, then restart manually."
        }
        return "This device runs iOS \(major): partial (sparse) restore, no wipe."
    }

    private func preflightRow(_ title: String, ok: Bool, detail: String?) -> some View {
        HStack {
            Label(title, systemImage: ok ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(ok ? Color.green : Color.red)
            Spacer()
            if let detail {
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Run

    private func startApply() {
        guard canStart, !running else { return }
        // Make sure the connection bootstrap has had its chance: it
        // is a no-op when the core is already up.
        BackendBootstrap.start()

        let input = GNSelectionBuilder.build(staged: selection.staged)
        let iconBuild = WebClipPayloads.build(staged: iconStage.staged)
        running = true
        cancelling = false
        result = nil
        progressPercent = nil
        etaText = ""
        lastLoggedPercent = -1
        logLines = ["[WorkSlop] Apply started — iOS \(DeviceInfoEx.fullVersion) (\(DeviceInfoEx.buildNumber))"]
        for name in input.tendieFailures {
            logLines.append("[WorkSlop] Skipped unreadable .tendies file: \(name)")
        }
        if !input.droppedFeatureIDs.isEmpty {
            logLines.append("[WorkSlop] Not delivered (no longer offered): \(input.droppedFeatureIDs.joined(separator: ", "))")
        }
        if !iconBuild.payloads.isEmpty {
            logLines.append("[WorkSlop] Icon themes: \(iconBuild.payloads.count / 2) web clip(s) ride this apply.")
        }
        for name in iconBuild.skipped {
            logLines.append("[WorkSlop] Icon theme skipped (pack artwork unreadable): \(name)")
        }
        guard input.mappedFeatures > 0 || !iconBuild.payloads.isEmpty else {
            running = false
            result = .failed("Nothing deliverable is staged — none of the staged tweaks exist in the current engine and no icon theme could be built. Unstage them and pick from the current list.")
            return
        }

        let engine = GoldenNuggetEngine.shared
        engine.onLog = { line in
            DispatchQueue.main.async {
                logLines.append(line)
            }
        }
        engine.onProgress = { percent in
            DispatchQueue.main.async {
                if percent.isNaN {
                    progressPercent = nil
                } else {
                    progressPercent = percent
                    let pct = Int(percent)
                    if pct != lastLoggedPercent {
                        lastLoggedPercent = pct
                        logLines.append("[\(pct)%]")
                    }
                }
            }
        }
        engine.onEta = { eta in
            DispatchQueue.main.async { etaText = eta }
        }

        applyTask = Task {
            // The engine wants the device's own version line: read it
            // from lockdownd when the connection is up, and fall back
            // to this phone's system version (the device IS this
            // phone) when it is not.
            let identity = await DeviceIdentity.read()
            let version = identity.version.isEmpty ? DeviceInfoEx.fullVersion : identity.version
            let isIPhone = identity.productType.isEmpty
                ? DeviceStatus.model.hasPrefix("iPhone")
                : identity.isIPhone
            do {
                try await engine.applyTweaks(selection: input.selection,
                                             posterBoard: input.posterBoard,
                                             statusBar: StatusBarSelection(),
                                             deviceVersion: version,
                                             isIPhone: isIPhone,
                                             extraPayloads: iconBuild.payloads)
                await MainActor.run {
                    finishRun()
                    logLines.append("[100%] Done — the engine finished and the device confirmed.")
                    result = .succeeded
                    showRestartSheet = true
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    let wasCancelling = cancelling
                    finishRun()
                    result = wasCancelling ? .cancelled : .failed(message)
                }
            }
        }
    }

    /// Sets the engine's cancel flag. The run stops at the engine's
    /// next checkpoint and the awaiting call throws, which lands in
    /// the cancelled result — the button does not fake an instant stop.
    private func cancelApply() {
        guard running, !cancelling else { return }
        cancelling = true
        logLines.append("[WorkSlop] Cancel requested — the engine stops at its next checkpoint…")
        GoldenNuggetEngine.shared.requestCancel()
    }

    private func finishRun() {
        applyTask = nil
        running = false
        cancelling = false
        let engine = GoldenNuggetEngine.shared
        engine.onLog = nil
        engine.onProgress = nil
        engine.onEta = nil
    }
}
