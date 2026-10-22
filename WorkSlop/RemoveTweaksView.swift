import SwiftUI

/// Remove Tweaks: turn off the tweaks this app recorded as applied.
///
/// The record (`AppliedTweaksStore`) is written by every successful
/// Apply. Removal is the engine's own reset machinery aimed at
/// exactly the files those tweaks live in — the files are nulled
/// (valid empty plist; the stock daemons dict; a zeroed status bar
/// payload) and delivered through the same pipeline as an apply,
/// protective backup first on iOS 27.
///
/// Honest limits, shown in the page rather than hidden:
/// * Removal works per FILE, not per key — tweaks sharing a file are
///   grouped under it and turn off together.
/// * It only runs while the pairing file from apply time is still in
///   place (same fingerprint). A removed or replaced pairing blocks
///   removal — re-apply first to refresh the record.
/// * Icon themes and PosterBoard themes are not removed here: web
///   clips are deleted from the Home Screen, PosterBoard themes from
///   the PosterBoard page's own reset.
struct RemoveTweaksView: View {
    @EnvironmentObject private var status: StatusStore
    @EnvironmentObject private var selection: SelectionStore

    @State private var record = AppliedTweaksStore.load()
    @State private var running = false
    @State private var cancelling = false
    @State private var outcome: String?
    @State private var failed = false
    @State private var logLines: [String] = []
    @State private var confirmTarget: RemoveTarget?
    @State private var removeTask: Task<Void, Never>?

    private struct RemoveTarget: Identifiable {
        let id: String
        let title: String
        let locations: Set<TweakFileLocation>
        let includeStatusBar: Bool
        let featureIDs: [String]
        /// Targets for files the record never knew about (applied
        /// before the record existed) skip the record gates — the
        /// device gate (imported pairing + tunnel) still applies.
        var bypassRecordGate: Bool = false
    }

    /// Recorded features grouped by the file a removal must null.
    /// A feature whose specs span several files appears under each —
    /// it counts as removed once every file it lives in was nulled.
    private var fileGroups: [(location: TweakFileLocation, featureIDs: [String])] {
        var byLocation: [TweakFileLocation: [String]] = [:]
        for id in record.featureIDs where !GNMapping.isPosterBoard(id) {
            for location in Set(GNMapping.specs(forFeature: id).map(\.location)) {
                byLocation[location, default: []].append(id)
            }
        }
        return byLocation
            .map { (location: $0.key, featureIDs: $0.value.sorted()) }
            .sorted { $0.location.rawValue < $1.location.rawValue }
    }

    /// Every file any catalog tweak writes to — the removal targets
    /// for tweaks applied before the record existed (the record only
    /// knows applies from the build that introduced it). Resetting a
    /// file to stock is the same write whether or not a tweak was
    /// ever applied to it, so these are always safe to offer.
    private var allTweakLocations: [TweakFileLocation] {
        Array(Set(TweakCatalog.allWithDaemons.map(\.location)))
            .sorted { $0.rawValue < $1.rawValue }
    }

    private var unrecordedLocations: [TweakFileLocation] {
        let recorded = Set(fileGroups.map(\.location))
        return allTweakLocations.filter { !recorded.contains($0) }
    }

    private var canRunUnrecorded: Bool { status.unlocked && !running }

    private var pairingMatches: Bool {
        guard let recorded = record.pairingFingerprint else { return true }
        return PairingStore.fingerprint == recorded
    }

    private var canRemove: Bool {
        status.unlocked && pairingMatches && !running
            && (!record.featureIDs.isEmpty || record.statusBarActive)
    }

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                if record.featureIDs.isEmpty && !record.statusBarActive {
                    Section {
                        Text("Nothing recorded as applied. Tweaks are recorded here after a successful Apply — run Apply first.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if !pairingMatches {
                        Section {
                            Label("The pairing file was removed or replaced since the recorded apply. Remove Tweaks only works with the pairing file from apply time — re-apply your tweaks to refresh the record.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    if !status.unlocked {
                        Section {
                            Label("Connect first: import the pairing file and open the VPN tunnel (same gate as Apply).", systemImage: "lock")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(fileGroups, id: \.location) { group in
                        Section {
                            ForEach(group.featureIDs, id: \.self) { id in
                                Text(FeatureCatalog.feature(id: id)?.title ?? id)
                            }
                            Button(role: .destructive) {
                                confirmTarget = RemoveTarget(
                                    id: group.location.rawValue,
                                    title: "Remove the \(group.featureIDs.count) tweak(s) in this file",
                                    locations: [group.location],
                                    includeStatusBar: false,
                                    featureIDs: group.featureIDs)
                            } label: {
                                Label("Remove these tweaks", systemImage: "trash")
                            }
                            .disabled(!canRemove)
                        } header: {
                            Text(group.location.rawValue)
                        } footer: {
                            Text("Removal resets this whole file to stock — every tweak listed here turns off together.")
                        }
                    }
                    if record.statusBarActive {
                        Section {
                            Text("Status bar overrides")
                            Button(role: .destructive) {
                                confirmTarget = RemoveTarget(
                                    id: "statusbar",
                                    title: "Remove the status bar overrides",
                                    locations: [],
                                    includeStatusBar: true,
                                    featureIDs: [])
                            } label: {
                                Label("Remove status bar overrides", systemImage: "trash")
                            }
                            .disabled(!canRemove)
                        } header: {
                            Text("Status Bar")
                        }
                    }
                    if !record.iconBundleIDs.isEmpty {
                        Section {
                            ForEach(record.iconBundleIDs, id: \.self) { Text($0) }
                        } header: {
                            Text("Icon themes (not removed here)")
                        } footer: {
                            Text("Web clips are deleted from the Home Screen directly: touch and hold the icon, then Remove Bookmark.")
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            confirmTarget = RemoveTarget(
                                id: "all",
                                title: "Remove ALL recorded tweaks",
                                locations: Set(fileGroups.map(\.location)),
                                includeStatusBar: record.statusBarActive,
                                featureIDs: record.featureIDs)
                        } label: {
                            Label("Remove all recorded tweaks", systemImage: "trash.fill")
                        }
                        .disabled(!canRemove)
                    } footer: {
                        Text("Removal runs the same delivery pipeline as Apply (protective backup first on iOS 27) and writes stock files. Restart the iPhone afterwards so the change takes effect.")
                    }
                }

                if !unrecordedLocations.isEmpty {
                    Section {
                        ForEach(unrecordedLocations, id: \.self) { location in
                            HStack {
                                Text(location.rawValue)
                                    .font(.footnote)
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    confirmTarget = RemoveTarget(
                                        id: "unrecorded-" + location.rawValue,
                                        title: "Remove any tweaks in this file",
                                        locations: [location],
                                        includeStatusBar: false,
                                        featureIDs: [],
                                        bypassRecordGate: true)
                                }
                                .disabled(!canRunUnrecorded)
                            }
                        }
                        Button(role: .destructive) {
                            confirmTarget = RemoveTarget(
                                id: "unrecorded-all",
                                title: "Remove ALL tweak files (recorded or not)",
                                locations: Set(allTweakLocations),
                                includeStatusBar: true,
                                featureIDs: record.featureIDs,
                                bypassRecordGate: true)
                        } label: {
                            Label("Remove all tweak files", systemImage: "trash.fill")
                        }
                        .disabled(!canRunUnrecorded)
                    } header: {
                        Text("Applied before the record?")
                    } footer: {
                        Text("The record only knows applies from the build that introduced it. Tweaks applied earlier still sit in these files — resetting one to stock is harmless even if nothing was applied to it. Restart the iPhone afterwards.")
                    }
                }

                if running || !logLines.isEmpty {
                    Section("Log") {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                        }
                        if running {
                            Button("Cancel", role: .destructive) {
                                cancelling = true
                                GoldenNuggetEngine.shared.requestCancel()
                            }
                            .disabled(cancelling)
                        }
                    }
                }
                if let outcome {
                    Section {
                        Label(outcome, systemImage: failed ? "xmark.circle" : "checkmark.circle")
                            .foregroundStyle(failed ? Color.red : Color.green)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Remove Tweaks")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { record = AppliedTweaksStore.load() }
        .confirmationDialog(
            confirmTarget?.title ?? "",
            isPresented: Binding(
                get: { confirmTarget != nil },
                set: { if !$0 { confirmTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let target = confirmTarget { runRemove(target) }
                confirmTarget = nil
            }
            Button("Cancel", role: .cancel) { confirmTarget = nil }
        } message: {
            Text("The file(s) are reset to stock through the same pipeline as Apply. This cannot be undone except by applying the tweaks again.")
        }
    }

    // MARK: - Run

    private func runRemove(_ target: RemoveTarget) {
        guard !running, status.unlocked else { return }
        guard target.bypassRecordGate || canRemove else { return }
        BackendBootstrap.start()
        running = true
        cancelling = false
        outcome = nil
        failed = false
        logLines = ["[WorkSlop] Remove started — \(target.title)"]

        let engine = GoldenNuggetEngine.shared
        engine.onLog = { line in
            DispatchQueue.main.async { logLines.append(line) }
        }
        engine.onProgress = nil
        engine.onEta = nil

        removeTask = Task {
            do {
                try await engine.removeAppliedTweaks(
                    locations: target.locations,
                    includeStatusBar: target.includeStatusBar)
                await MainActor.run {
                    running = false
                    // A feature is off only when every file it lives
                    // in was nulled by this run.
                    let removedFiles = target.locations
                    let fullyRemoved = record.featureIDs.filter { id in
                        let locs = Set(GNMapping.specs(forFeature: id).map(\.location))
                        return !locs.isEmpty && locs.isSubset(of: removedFiles)
                    }
                    AppliedTweaksStore.recordRemoval(
                        featureIDs: fullyRemoved, statusBar: target.includeStatusBar)
                    for id in fullyRemoved { selection.set(id, false) }
                    record = AppliedTweaksStore.load()
                    outcome = "Removed. Restart your iPhone so the change takes effect."
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    running = false
                    failed = true
                    outcome = cancelling ? "Remove cancelled — re-run to complete it." : message
                }
            }
        }
    }
}
