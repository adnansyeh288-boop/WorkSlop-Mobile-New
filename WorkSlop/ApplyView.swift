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

    /// The v4 Apply method, persisted across launches. Defaults to
    /// `.normal` (the proven path); the raw value is stored so a
    /// value this build does not know falls back to `.normal`
    /// through the computed `method` below instead of trapping.
    @AppStorage("ApplyMethod.selected") private var methodRaw: String = ApplyMethod.normal.rawValue
    @State private var showFPRTutorial = false
    /// True only when the tutorial sheet was opened by the run
    /// button: confirming it then starts the run. Opened from
    /// "How it works" it is read-only information — confirming
    /// just dismisses it.
    @State private var tutorialStartsRun = false
    /// The iOS version read from the device through lockdown (the
    /// same `DeviceIdentity.read()` a run uses). Empty means the
    /// device has not answered yet — "not read yet", never a guess.
    @State private var detectedVersion = ""
    /// Free-space preflight snapshot (methods `.normal` and
    /// `.getBackupFile`), refreshed on appear and on method change.
    @State private var freeSpaceBytes: Int64 = 0
    @State private var mediaStoreBytes: Int64 = 0
    @State private var lastFailureSummary: String?
    @State private var mediaClearError: String?
    /// Backup packages on this phone (newest first), for the
    /// FPR + Import picker.
    @State private var backupPackages: [URL] = []
    @State private var selectedPackage: URL?
    @State private var showDeletePackageConfirmation = false
    /// The zip a Get Backup File run just produced, waiting for the
    /// user to pick where in Files to save it. The result is only set
    /// when the picker answers (saved or cancelled) — never before.
    @State private var exportZipURL: URL?
    @State private var showExportPicker = false

    private enum ApplyResult {
        case succeeded
        case failed(String)
        case cancelled
        case backupExported(name: String, size: Int64)
    }

    var body: some View {
        List {
            Section {
                // One card per method: the method is chosen by tapping
                // its blue button, which writes the same persisted
                // `methodRaw` the picker used to write. Selection state,
                // preflight, gates and dispatch are untouched — only
                // how the method is picked and displayed changes.
                ForEach(ApplyMethod.allCases) { candidate in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(candidate.label)
                                .font(.headline)
                            Spacer()
                            if candidate == method {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                        Text(methodWarning(for: candidate))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(candidate == method ? "Selected" : "Select") {
                            methodRaw = candidate.rawValue
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(candidate.requiresIOS27 && fprDisabledByVersion)
                        .accessibilityIdentifier("apply-method-select-\(candidate.rawValue)")
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                if fprDisabledByVersion {
                    Text("Force Partial Restore needs iOS 27 — this device reports iOS \(detectedVersion).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if method.requiresIOS27 {
                    Button("How it works") {
                        tutorialStartsRun = false
                        showFPRTutorial = true
                    }
                    .accessibilityIdentifier("fpr-how-it-works")
                }
            } header: {
                Text("Apply method")
            }

            if method == .forcePartialRestoreImport {
                Section {
                    if backupPackages.isEmpty {
                        Text("No backup package on this phone yet. Run Get Backup File first.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Backup package", selection: $selectedPackage) {
                            ForEach(backupPackages, id: \.self) { package in
                                Text("\(package.lastPathComponent) — \(formattedBytes(BackupExportStore.size(of: package)))")
                                    .tag(Optional(package))
                            }
                        }
                        .accessibilityIdentifier("backup-package-picker")
                        if selectedPackage != nil {
                            Button("Delete selected package", role: .destructive) {
                                showDeletePackageConfirmation = true
                            }
                            .accessibilityIdentifier("delete-backup-package")
                            .confirmationDialog("Delete this backup package?", isPresented: $showDeletePackageConfirmation, titleVisibility: .visible) {
                                Button("Delete package", role: .destructive) { deleteSelectedPackage() }
                                Button("Cancel", role: .cancel) { }
                            } message: {
                                Text("The package is deleted from WorkSlop's storage on this phone. This cannot be undone.")
                            }
                        }
                    }
                } header: {
                    Text("Backup package")
                }
            }

            Section {
                Text("iOS version detected: \(detectedVersion.isEmpty ? "not read yet" : detectedVersion)")
                Text(willRunText)
                preflightRow("Tweaks staged", ok: !selection.staged.isEmpty,
                             detail: "\(ApplyCounter.tweakCount(staged: selection.staged))")
                if !iconStage.staged.isEmpty {
                    preflightRow("Icon themes staged", ok: true,
                                 detail: "\(iconStage.staged.count)")
                }
                if statusBarSelection.isActive
                    || statusBarSelection.overrides.activeCount > 0 {
                    // Also shown when overrides exist but the selection
                    // is OFF: that state used to be invisible here, so a
                    // run could "succeed" while the status bar the user
                    // set never left the phone.
                    preflightRow("Status bar overrides",
                                 ok: statusBarSelection.isActive,
                                 detail: statusBarSelection.isActive
                                     ? "\(statusBarSelection.overrides.activeCount)"
                                     : "off — not delivered")
                }
                preflightRow("Build support", ok: BuildSupport.current != .unsupported,
                             detail: BuildSupport.current.displayText)
                preflightRow("Pairing file imported", ok: status.pairingImported, detail: nil)
                preflightRow("VPN tunnel detected", ok: status.vpnDetected, detail: nil)
                Text("⚠️ Find My iPhone must be OFF before applying. With it on, the device refuses the restore (error 211) after the backup has already run. Turn it off in Settings → your name → Find My → Find My iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if method == .normal || method == .getBackupFile {
                    Text("Free space on this phone: \(formattedBytes(freeSpaceBytes))")
                    if mediaStoreBytes > 0 {
                        HStack {
                            Text("Media copies held by WorkSlop: \(formattedBytes(mediaStoreBytes))")
                            Spacer()
                            Button("Clear") { clearMediaCopies() }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("clear-media-store")
                        }
                    }
                    if let mediaClearError {
                        Text(mediaClearError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let lastFailureSummary {
                        Text(lastFailureSummary)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
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
                    case .backupExported(let name, let size):
                        Label("Backup file saved", systemImage: "checkmark.circle")
                            .foregroundStyle(Color.green)
                        Text("\(name) (\(formattedBytes(size))) — saved in WorkSlop's storage on this phone, for later use with Force Partial Restore + Import Backup. Nothing on the phone was changed or restored, so there is nothing to restart for.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(runButtonTitle) {
                    startApply()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(!canStart || running)
                .accessibilityIdentifier("apply-now")

                if let blockerText {
                    Text(blockerText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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
        .sheet(isPresented: $showFPRTutorial) {
            FPRTutorialView(
                method: method,
                onConfirm: {
                    showFPRTutorial = false
                    if tutorialStartsRun {
                        tutorialStartsRun = false
                        beginRun()
                    }
                },
                onCancel: {
                    tutorialStartsRun = false
                    showFPRTutorial = false
                })
        }
        .sheet(isPresented: $showExportPicker, onDismiss: { exportPickerDismissed() }) {
            if let zipURL = exportZipURL {
                DocumentExportPicker(
                    url: zipURL,
                    onExported: { exportPickerSaved(to: $0) },
                    onCancelled: { exportPickerCancelled() })
            }
        }
        .onAppear {
            refreshFreeSpace()
            refreshBackupPackages()
        }
        .task {
            await refreshDetectedVersion()
        }
        .onChange(of: methodRaw) { _ in
            refreshFreeSpace()
            refreshBackupPackages()
        }
        .onChange(of: status.unlocked) { _ in
            Task { await refreshDetectedVersion() }
        }
    }

    // MARK: - State

    /// The selected Apply method (persisted as `methodRaw`).
    /// An unknown stored value falls back to `.normal`.
    private var method: ApplyMethod {
        ApplyMethod(rawValue: methodRaw) ?? .normal
    }

    private var hasStagedContent: Bool {
        !selection.staged.isEmpty || !iconStage.staged.isEmpty
            || statusBarSelection.isActive
    }

    /// True when the only staged content is PosterBoard, which general
    /// Apply never delivers (it has its own Apply on the PosterBoard
    /// page). Display only; the run path reports the same pointer in
    /// the log when a PB-only staged set reaches `beginApplyRun`.
    private var isPosterBoardOnlyStaged: Bool {
        !selection.staged.isEmpty
            && selection.staged.allSatisfy { $0 == "pb-tendies" || $0 == "pb-reset" }
            && iconStage.staged.isEmpty && !statusBarSelection.isActive
    }

    /// Product rule (user, 2026-10-24): on iOS 27 the status bar may
    /// only be applied through Force Partial Restore — the Normal
    /// method must not run it. True exactly when this selection would
    /// do that. An unread version does not block here (no speculation):
    /// the engine's run-layer gate decides on the resolved version.
    private var statusBarBlockedOnNormal27: Bool {
        method == .normal && detectedMajor == 27 && statusBarSelection.isActive
    }

    private var canStart: Bool {
        guard status.unlocked else { return false }
        if statusBarBlockedOnNormal27 { return false }
        // The card button already disables the FPR pair off iOS 27;
        // this is the same gate at the button, for a method stored
        // before the version was read (or on another iOS).
        if method.requiresIOS27, let major = detectedMajor, major != 27 {
            return false
        }
        switch method {
        case .getBackupFile:
            // A standalone copy: no tweaks need to be staged.
            return true
        case .forcePartialRestoreImport:
            return hasStagedContent && selectedPackage != nil
        case .normal, .forcePartialRestore:
            return hasStagedContent
        }
    }

    /// Why the run button is disabled, in plain terms, shown under
    /// the button so a first-time user is never left guessing.
    /// Mirrors `canStart` exactly — display only.
    private var blockerText: String? {
        guard !canStart, !running else { return nil }
        if !status.unlocked {
            if !status.pairingImported {
                return "Import a pairing file first — the pairing controls are on Home."
            }
            return "Connect the VPN tunnel first — the tunnel status is on Home."
        }
        if statusBarBlockedOnNormal27 {
            return "Status Bar tweaks on iOS 27 can only be applied with Force Partial Restore — switch the method above to Force Partial Restore."
        }
        if method.requiresIOS27, let major = detectedMajor, major != 27 {
            return "This method needs iOS 27 — this device reports iOS \(detectedVersion)."
        }
        switch method {
        case .getBackupFile:
            return nil
        case .forcePartialRestoreImport where selectedPackage == nil:
            return "No backup package yet — run Get Backup File first, then choose the package above."
        case .normal, .forcePartialRestore, .forcePartialRestoreImport:
            if isPosterBoardOnlyStaged {
                return "Stage tweaks first — or use the PosterBoard page's own Apply for PosterBoard."
            }
            return "Stage tweaks first — pick tweaks, icon themes, or status bar overrides on Home, then come back here."
        }
    }

    private var runButtonTitle: String {
        if running {
            return method == .getBackupFile ? "Getting backup…" : "Applying…"
        }
        return method == .getBackupFile ? "Get Backup File" : "Apply now"
    }

    /// Each card shows its own method's warning text, word for
    /// word as the picker section did. Factual only — what the
    /// method does and what it costs.
    private func methodWarning(for candidate: ApplyMethod) -> String {
        switch candidate {
        case .normal:
            return "Takes a protective backup on this phone first, then restores it with your tweaks. iOS only allows the backup when free space is larger than the backup's computed size — if it stops over space, free real space (empty Recently Deleted, restart) and try again."
        case .forcePartialRestore:
            return "No backup is taken first — WorkSlop builds a small backup containing only your staged tweaks and restores that. Fast, but there is nothing to roll back to. iOS 27 only."
        case .forcePartialRestoreImport:
            return "No backup is taken first — WorkSlop builds a small backup containing only your staged tweaks and restores that. Fast, but there is nothing to roll back to. iOS 27 only."
                + " A backup package you choose (made by Get Backup File) is merged in: data in the domains it carries replaces the data now on the phone in those domains."
        case .getBackupFile:
            return "Copies a backup package onto this phone, for later use with Force Partial Restore + Import Backup. It changes nothing on the phone, but it needs free space while it runs and the package stays in WorkSlop's storage until you delete it. After the pull, WorkSlop zips the package and offers it in Files, so you can keep a copy outside the app."
        }
    }

    /// Major version of the lockdown-read iOS version, or nil when
    /// the device has not answered yet ("not read yet").
    private var detectedMajor: Int? {
        guard let first = detectedVersion.split(separator: ".").first else { return nil }
        return Int(String(first))
    }

    /// True when the version is readable and is not iOS 27: the
    /// FPR pair is disabled on its card in that state. When the
    /// version is not yet readable the options stay enabled — the
    /// engine refuses precisely if it still cannot read it at run
    /// time.
    private var fprDisabledByVersion: Bool {
        guard let major = detectedMajor else { return false }
        return major != 27
    }

    /// The method that will actually run, for the preflight: the
    /// selected method's label, plus — for `.normal` — the branch
    /// the version resolves to when it is readable. Display only;
    /// the engine re-checks before running.
    private var willRunText: String {
        var text = "Will run: \(method.label)"
        if method == .normal, let major = detectedMajor {
            text += major >= 27 ? " (protective backup)" : " (partial restore)"
        }
        return text
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Preflight snapshots

    private func refreshFreeSpace() {
        freeSpaceBytes = FreeSpaceGuard.containerFreeBytes()
        mediaStoreBytes = FreeSpaceGuard.mediaStoreBytes()
        lastFailureSummary = FreeSpaceGuard.lastFailureSummary()
    }

    private func clearMediaCopies() {
        do {
            _ = try FreeSpaceGuard.clearMediaStore()
            mediaClearError = nil
        } catch {
            mediaClearError = "Could not clear media copies: \(error.localizedDescription)"
        }
        refreshFreeSpace()
    }

    private func refreshBackupPackages() {
        BackupExportStore.removeStaleUnzipWorkingDirs()
        let packages = BackupExportStore.packageURLs()
        backupPackages = packages
        if let current = selectedPackage, packages.contains(current) { return }
        selectedPackage = packages.first
    }

    /// The Files picker saved the zip. Exporting copies — it does
    /// not move — so the result is the zip still in WorkSlop's
    /// storage, and the log line proves a copy left the app.
    private func exportPickerSaved(to destination: URL) {
        guard let zipURL = exportZipURL else { return }
        exportZipURL = nil
        showExportPicker = false
        logLines.append("[WorkSlop] Saved a copy to Files: \(destination.lastPathComponent)")
        result = .backupExported(name: zipURL.lastPathComponent, size: BackupExportStore.size(of: zipURL))
    }

    /// The Files picker was dismissed without saving. The zip stays
    /// in WorkSlop's storage and the import picker can use it, so
    /// the result is the same shape as a save — the package is
    /// saved, only the Files copy did not happen — and the log
    /// says exactly that.
    private func exportPickerCancelled() {
        guard let zipURL = exportZipURL else { return }
        exportZipURL = nil
        showExportPicker = false
        logLines.append("[WorkSlop] Files export cancelled — the zip stays in WorkSlop's storage.")
        result = .backupExported(name: zipURL.lastPathComponent, size: BackupExportStore.size(of: zipURL))
    }

    /// Sheet dismissal with no delegate answer (a swipe the delegate
    /// never reported). The delegate always answers first in the
    /// normal flows, so this only covers the gap — a run must never
    /// end with no result at all.
    private func exportPickerDismissed() {
        if exportZipURL != nil { exportPickerCancelled() }
    }

    /// Delete the selected backup package from WorkSlop's storage
    /// (the Get Backup File warning promises the package stays
    /// "until you delete it" — this is that delete). View-level
    /// file removal only; the list refreshes afterwards.
    private func deleteSelectedPackage() {
        guard let package = selectedPackage else { return }
        try? FileManager.default.removeItem(at: package)
        if selectedPackage == package { selectedPackage = nil }
        refreshBackupPackages()
    }

    /// Re-read the device version through lockdown — the same
    /// one-shot read a run makes (`DeviceIdentity.read()` in
    /// `beginApplyRun`). An empty answer leaves the previous value
    /// (or "not read yet") in place instead of inventing one.
    private func refreshDetectedVersion() async {
        let identity = await DeviceIdentity.read()
        guard !identity.version.isEmpty else { return }
        await MainActor.run { detectedVersion = identity.version }
    }

    /// The stored status-bar selection the Status Bar page saved, in
    /// engine shape. Empty (inactive) when the page was never used.
    private var statusBarSelection: StatusBarSelection {
        var loaded = StatusBarSelection()
        if let stored = StatusBarPreferences.storedSelection() {
            loaded.restore(from: stored)
        }
        return loaded
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

    /// The run button's entry point. The FPR pair goes through
    /// its tutorial sheet first — the run only starts when the
    /// sheet is confirmed (`tutorialStartsRun`). Every other
    /// method runs straight away.
    private func startApply() {
        guard canStart, !running else { return }
        if method.requiresIOS27 {
            tutorialStartsRun = true
            showFPRTutorial = true
            return
        }
        beginRun()
    }

    /// Dispatch to the selected method's run. Get Backup File is
    /// a standalone copy, not an apply: it shares the running /
    /// log / progress machinery but stages nothing, records no
    /// applied tweaks and never shows the restart sheet.
    private func beginRun() {
        guard canStart, !running else { return }
        if method == .getBackupFile {
            beginBackupExportRun()
        } else {
            beginApplyRun()
        }
    }

    private func beginBackupExportRun() {
        // Make sure the connection bootstrap has had its chance: it
        // is a no-op when the core is already up.
        BackendBootstrap.start()
        running = true
        cancelling = false
        result = nil
        progressPercent = nil
        etaText = ""
        lastLoggedPercent = -1
        logLines = ["[WorkSlop] Get Backup File started — iOS \(DeviceInfoEx.fullVersion) (\(DeviceInfoEx.buildNumber))",
                    "[WorkSlop] Method: \(ApplyMethod.getBackupFile.label)"]
        installEngineCallbacks()

        let engine = GoldenNuggetEngine.shared
        applyTask = Task {
            // Same version source as an apply run: lockdown first,
            // this phone's system version as the fallback.
            let identity = await DeviceIdentity.read()
            let version = identity.version.isEmpty ? DeviceInfoEx.fullVersion : identity.version
            do {
                let package = try await engine.getBackupFile(deviceVersion: version)
                let dirSize = BackupExportStore.size(of: package)
                // Zip first, then offer the zip in Files. The
                // directory package is never deleted by this flow —
                // it stays, and so does the zip, whatever the user
                // picks in the picker.
                do {
                    let zipURL = try BackupExportZip.zip(package: package)
                    let zipSize = BackupExportStore.size(of: zipURL)
                    await MainActor.run {
                        finishRun()
                        refreshFreeSpace()
                        refreshBackupPackages()
                        logLines.append("[100%] Done — backup package saved: \(package.lastPathComponent)")
                        logLines.append("[WorkSlop] Zipped package: \(zipURL.lastPathComponent) (\(formattedBytes(zipSize))) — choose where to save it in Files.")
                        // The result waits for the picker: it is set
                        // by its saved / cancelled callback, never here.
                        exportZipURL = zipURL
                        showExportPicker = true
                    }
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    await MainActor.run {
                        finishRun()
                        refreshFreeSpace()
                        refreshBackupPackages()
                        logLines.append("[100%] Done — backup package saved: \(package.lastPathComponent)")
                        logLines.append("[WorkSlop] Could not zip the package: \(message). The directory package stays in WorkSlop's storage, and Force Partial Restore + Import Backup can still use it.")
                        result = .backupExported(name: package.lastPathComponent, size: dirSize)
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    let wasCancelling = cancelling
                    finishRun()
                    refreshFreeSpace()
                    result = wasCancelling ? .cancelled : .failed(message)
                }
            }
        }
    }

    private func beginApplyRun() {
        guard canStart, !running else { return }
        // Make sure the connection bootstrap has had its chance: it
        // is a no-op when the core is already up.
        BackendBootstrap.start()

        let runMethod = method
        let runPackage = selectedPackage
        let input = GNSelectionBuilder.build(staged: selection.staged)
        let iconBuild = WebClipPayloads.build(staged: iconStage.staged)
        running = true
        cancelling = false
        result = nil
        progressPercent = nil
        etaText = ""
        lastLoggedPercent = -1
        logLines = ["[WorkSlop] Apply started — iOS \(DeviceInfoEx.fullVersion) (\(DeviceInfoEx.buildNumber))"]
        if runMethod != .normal {
            logLines.append("[WorkSlop] Method: \(runMethod.label)")
        }
        for name in input.tendieFailures {
            logLines.append("[WorkSlop] Skipped unreadable .tendies file: \(name)")
        }
        for skip in input.tendieLimitSkips {
            logLines.append("[WorkSlop] Skipped .tendies file: \(skip)")
        }
        // PosterBoard is still offered — on its own page — it just
        // never rides general Apply, so it gets its own dropped line
        // instead of the generic "no longer offered" wording.
        let droppedPB = input.droppedFeatureIDs.filter { $0 == "pb-tendies" || $0 == "pb-reset" }
        if !droppedPB.isEmpty {
            logLines.append("[WorkSlop] PosterBoard is not delivered by general Apply — use the PosterBoard page's own Apply (\(droppedPB.joined(separator: ", "))).")
        }
        let droppedOther = input.droppedFeatureIDs.filter { $0 != "pb-tendies" && $0 != "pb-reset" }
        if !droppedOther.isEmpty {
            logLines.append("[WorkSlop] Not delivered (no longer offered): \(droppedOther.joined(separator: ", "))")
        }
        if !iconBuild.payloads.isEmpty {
            logLines.append("[WorkSlop] Icon themes: \(iconBuild.payloads.count / 2) web clip(s) ride this apply.")
        }
        for name in iconBuild.skipped {
            logLines.append("[WorkSlop] Icon theme skipped (pack artwork unreadable): \(name)")
        }
        let statusBar = statusBarSelection
        guard input.mappedFeatures > 0 || !iconBuild.payloads.isEmpty || statusBar.isActive else {
            running = false
            result = .failed("Nothing deliverable is staged — none of the staged tweaks exist in the current engine and no icon theme could be built. Unstage them and pick from the current list.")
            return
        }
        if runMethod == .forcePartialRestoreImport, runPackage == nil {
            running = false
            result = .failed("No backup package selected — run Get Backup File first, then pick the package above.")
            return
        }

        let engine = GoldenNuggetEngine.shared
        installEngineCallbacks()

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
                // A zip import package is unpacked to a dot-prefixed
                // working directory (hidden from the picker, like the
                // pull's staging tree) and the merge runs on the unpacked
                // directory, unchanged. A directory package passes through
                // untouched. The working directory is removed when this
                // run block exits, success, failure or cancel alike —
                // the `defer` runs before the catch's result block, and
                // the merge no longer needs the directory by then.
                var importWorkingDir: URL?
                defer {
                    if let dir = importWorkingDir {
                        try? FileManager.default.removeItem(at: dir)
                    }
                }
                var effectivePackage = runPackage
                if runMethod == .forcePartialRestoreImport, let pkg = runPackage,
                   pkg.pathExtension.lowercased() == "zip" {
                    let work = BackupExportStore.root.appendingPathComponent(
                        ".unzipped-\(UUID().uuidString)", conformingTo: .data)
                    // Assigned BEFORE the unpack: if the unpack throws
                    // halfway, the `defer` above still removes the
                    // partial directory instead of leaving it for the
                    // one-day stale sweep.
                    importWorkingDir = work
                    do {
                        try BackupExportZip.unzip(zip: pkg, to: work)
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        throw GoldenNuggetError(
                            "Could not unpack the selected zip package (\(pkg.lastPathComponent)): \(message)")
                    }
                    effectivePackage = work
                }
                switch runMethod {
                case .normal:
                    try await engine.applyTweaks(selection: input.selection,
                                                 posterBoard: input.posterBoard,
                                                 statusBar: statusBar,
                                                 deviceVersion: version,
                                                 isIPhone: isIPhone,
                                                 extraPayloads: iconBuild.payloads)
                case .forcePartialRestore:
                    try await engine.applyTweaksFPR(selection: input.selection,
                                                    posterBoard: input.posterBoard,
                                                    statusBar: statusBar,
                                                    deviceVersion: version,
                                                    isIPhone: isIPhone,
                                                    extraPayloads: iconBuild.payloads,
                                                    importPackage: nil)
                case .forcePartialRestoreImport:
                    try await engine.applyTweaksFPR(selection: input.selection,
                                                    posterBoard: input.posterBoard,
                                                    statusBar: statusBar,
                                                    deviceVersion: version,
                                                    isIPhone: isIPhone,
                                                    extraPayloads: iconBuild.payloads,
                                                    importPackage: effectivePackage)
                case .getBackupFile:
                    // Unreachable: beginRun routes Get Backup File
                    // to beginBackupExportRun, never here.
                    throw GoldenNuggetError("Get Backup File does not run through the apply path.")
                }
                await MainActor.run {
                    finishRun()
                    // Record what this run put on the device — the
                    // data Remove Tweaks works from. Dropped features
                    // and the PosterBoard items are not tweaks left on
                    // the device for Remove Tweaks: the reset action
                    // removes rather than installs, and tendies
                    // wallpapers are managed on the PosterBoard page
                    // (its files list and its reset). Recording either
                    // one left an entry no removal could ever clear.
                    AppliedTweaksStore.recordApply(
                        featureIDs: Array(selection.staged
                            .subtracting(input.droppedFeatureIDs)
                            .subtracting(["pb-reset", "pb-tendies"])),
                        statusBarActive: statusBar.isActive,
                        iconBundleIDs: iconStage.staged.map(\.bundleID),
                        pairingFingerprint: PairingStore.fingerprint)
                    if importWorkingDir != nil, let pkg = runPackage {
                        logLines.append("[WorkSlop] Import package \(pkg.lastPathComponent) was unpacked for this run; the working copy is removed when the run ends.")
                    }
                    logLines.append("[100%] Done — the engine finished and the device confirmed.")
                    result = .succeeded
                    showRestartSheet = true
                    refreshFreeSpace()
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    let wasCancelling = cancelling
                    finishRun()
                    refreshFreeSpace()
                    result = wasCancelling ? .cancelled : .failed(message)
                }
            }
        }
    }

    /// Wire the engine's log / progress / ETA callbacks into this
    /// view's state. Shared by every run (applies and Get Backup
    /// File alike); `finishRun` clears them again.
    private func installEngineCallbacks() {
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
