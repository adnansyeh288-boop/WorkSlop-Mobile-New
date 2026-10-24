import SwiftUI
import UniformTypeIdentifiers

/// Import-first PosterBoard file management: the user brings
/// .tendies files; the engine's PosterBoard stage delivers them
/// through the PosterBoard page's own Apply (below), never through
/// general Apply. Plain table, no animation behind the content.
struct PosterBoardFilesView: View {
    @State private var importing = false
    @State private var note: String?
    @State private var files: [String] = TendiesStore.list(kind: "Tendies")

    var body: some View {
        List {
            Section {
                PosterBoardActionsView()
            } header: {
                Text("PosterBoard Apply & Remove")
            } footer: {
                Text("PosterBoard runs through a protective backup and restore, on iOS 26 and 27. It never rides general Apply or Force Partial Restore.")
            }

            Section {
                Button("Import PosterBoard file (.tendies)") { importing = true }
                    .accessibilityIdentifier("pb-import")
                if files.isEmpty {
                    Text("Nothing imported. PosterBoard delivers nothing until at least one .tendies is here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(files, id: \.self) { name in
                        Label(name, systemImage: "doc")
                            .font(.footnote)
                    }
                    .onDelete { offsets in
                        TendiesStore.delete(at: offsets, from: files, kind: "Tendies")
                        files = TendiesStore.list(kind: "Tendies")
                    }
                }
            } header: {
                Text("PosterBoard (.tendies)")
            } footer: {
                Text("Imported files ride the PosterBoard page's own Apply when the Tendies toggle is staged. One apply carries at most 5 files and 10 descriptors in total — files past the limit stay here for a later apply and are named in the apply log.")
            }

            if let note {
                Section {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("PosterBoard Files")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "tendies") ?? .data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var imported = 0
                for url in urls {
                    guard url.pathExtension.lowercased() == "tendies" else { continue }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if TendiesStore.save(url: url, kind: "Tendies") { imported += 1 }
                }
                files = TendiesStore.list(kind: "Tendies")
                note = imported > 0
                    ? "Imported \(imported) .tendies file(s). Stage the Tendies toggle, then use Apply PosterBoard above."
                    : "Nothing imported - this table takes .tendies only."
            case .failure:
                note = "Import cancelled."
            }
        }
    }
}

// MARK: - Tendies store (PosterBoard imports)

enum TendiesStore {
    static func dir(kind: String) -> URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(kind, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func list(kind: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir(kind: kind).path))?.sorted() ?? []
    }

    static func save(url: URL, kind: String) -> Bool {
        // No import-time cap: imports are never refused; the
        // engine decides how much rides one apply.
        let dest = dir(kind: kind).appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            return true
        } catch {
            return false
        }
    }

    static func urls(kind: String) -> [URL] {
        list(kind: kind).map { dir(kind: kind).appendingPathComponent($0) }
    }

    static func delete(at offsets: IndexSet, from files: [String], kind: String) {
        for i in offsets {
            try? FileManager.default.removeItem(at: dir(kind: kind).appendingPathComponent(files[i]))
        }
    }
}

// MARK: - PosterBoard's own Apply and Remove (PosterBoard fix, 2026-10-24)
//
// Two menus, both in the PosterBoard area (this page and the PosterBoard
// tweak list), both running the dedicated `applyPosterBoardOnly` engine
// entry through the original Nugget backup/restore method — never
// general Apply, never Force Partial Restore, never AirLift.
//
// Apply keeps the staged-toggle selection model (D1): it runs exactly
// what is staged — `pb-tendies` (imported .tendies, capped) and/or
// `pb-reset` (all three selective modes). A combined staged selection
// keeps the engine's compile-order rule: reset beats tendies, never
// mixed in one run.
//
// Remove is a separate menu with its own mode multi-select (D3/D4):
// it runs a selective-reset selection only — never `fullReset`, which
// stays engine-dead with zero UI setters (D2). Its confirmation names
// the subtrees and says plainly that it clears everything in them,
// including stock descriptors, and that per-wallpaper removal is
// impossible (delivered descriptors are randomised, no delivered-ID
// record exists). It writes nothing to `AppliedTweaksStore` and never
// touches general Remove Tweaks, which already excludes PosterBoard.
struct PosterBoardActionsView: View {
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var status: StatusStore

    @State private var running = false
    @State private var outcome: String?
    @State private var outcomeIsError = false
    @State private var confirmingReset = false
    @State private var resetModes: Set<PosterBoardResetMode> = Set(PosterBoardResetMode.allCases)
    @State private var runTask: Task<Void, Never>?

    private var tendiesStaged: Bool { selection.isOn("pb-tendies") }
    private var resetStaged: Bool { selection.isOn("pb-reset") }
    private var posterBoardStaged: Bool { tendiesStaged || resetStaged }

    private var applySummary: String {
        var parts: [String] = []
        if tendiesStaged {
            parts.append("\(TendiesStore.list(kind: "Tendies").count) imported .tendies file(s)")
        }
        if resetStaged { parts.append("Reset PosterBoard (all three areas)") }
        return parts.isEmpty
            ? "Nothing staged. Stage Tendies wallpapers and/or Reset PosterBoard above first."
            : "Staged: " + parts.joined(separator: "; ") + "."
    }

    private var resetDetail: String {
        resetModes.sorted(by: { $0.rawValue < $1.rawValue })
            .map { "\($0.rawValue) — \($0.detail)" }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // MARK: Apply
            Text("Apply PosterBoard")
                .font(.headline)
            Text("Delivers what is staged, through a protective backup and restore. Reboot the device when it finishes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(applySummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Apply PosterBoard") { runApply() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pb-apply")
                .disabled(!status.unlocked || running || !posterBoardStaged)
            if !status.unlocked {
                Text("Connect first: import the pairing file and open the VPN tunnel (same gate as Apply).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // MARK: Remove (selective reset)
            Text("Remove PosterBoard wallpapers")
                .font(.headline)
            Text("Clears the areas below from the PosterBoard store. This is a reset, not per-wallpaper removal: it clears all descriptors in the selected areas, including stock wallpapers, and PosterBoard rebuilds its index from what remains after a reboot.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(PosterBoardResetMode.allCases) { mode in
                Toggle(isOn: Binding(
                    get: { resetModes.contains(mode) },
                    set: { on in
                        if on { resetModes.insert(mode) } else { resetModes.remove(mode) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.rawValue)
                        Text(mode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("pb-reset-mode-\(mode.rawValue)")
            }
            Button("Remove PosterBoard wallpapers", role: .destructive) {
                confirmingReset = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("pb-remove")
            .disabled(!status.unlocked || running || resetModes.isEmpty)
            if resetModes.isEmpty {
                Text("Select at least one area to clear.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if running {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Running — progress is on the Log page.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { GoldenNuggetEngine.shared.requestCancel() }
                        .font(.footnote)
                }
            }
            if let outcome {
                Text(outcome)
                    .font(.footnote)
                    .foregroundStyle(outcomeIsError ? .red : .secondary)
            }
        }
        .alert("Remove PosterBoard wallpapers?", isPresented: $confirmingReset) {
            Button("Remove", role: .destructive) { runReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears ALL descriptors in these areas, including stock wallpapers — not just wallpapers this app delivered:\n\(resetDetail)\n\nPosterBoard rebuilds its index from what remains after a reboot. Per-wallpaper removal is not possible: delivered descriptors are randomised and no record maps them back to packs.")
        }
    }

    private func runApply() {
        let build = GNSelectionBuilder.buildPosterBoard(staged: selection.staged)
        guard build.selection.isActive else {
            outcome = "Nothing staged to apply — stage Tendies wallpapers and/or Reset PosterBoard first."
            outcomeIsError = true
            return
        }
        var notes: [String] = []
        for name in build.tendieFailures { notes.append("Skipped unreadable .tendies file: \(name)") }
        for skip in build.tendieLimitSkips { notes.append("Skipped .tendies file: \(skip)") }
        // Reset takes precedence in `PosterBoard.compile` (reset modes
        // return before tendies are compiled), so a combined staged
        // selection delivers the reset only — say so up front rather
        // than letting the success note imply new wallpapers landed.
        let hasReset = !build.selection.resetModes.isEmpty
        if hasReset && !build.selection.tendies.isEmpty {
            notes.insert("Reset takes precedence: the tendies in this run are not delivered — run Apply again with Reset unstaged to deliver them.", at: 0)
        }
        let successNote = hasReset
            ? "PosterBoard areas cleared — reboot the device, then PosterBoard rebuilds from what remains."
            : "PosterBoard applied — reboot the device so the store picks the new wallpapers up."
        startRun(build.selection, successNote: successNote,
                 notes: notes)
    }

    private func runReset() {
        var reset = PosterBoardSelection()
        reset.resetModes = resetModes
        startRun(reset, successNote: "PosterBoard areas cleared — reboot the device, then PosterBoard rebuilds from what remains.",
                 notes: [])
    }

    private func startRun(_ pbSelection: PosterBoardSelection,
                          successNote: String, notes: [String]) {
        guard !running else { return }
        BackendBootstrap.start()
        running = true
        outcome = nil
        outcomeIsError = false
        runTask = Task {
            let identity = await DeviceIdentity.read()
            let version = identity.version.isEmpty ? DeviceInfoEx.fullVersion : identity.version
            do {
                try await GoldenNuggetEngine.shared.applyPosterBoardOnly(pbSelection, deviceVersion: version)
                await MainActor.run {
                    running = false
                    outcome = ([successNote] + notes).joined(separator: " ")
                    outcomeIsError = false
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    running = false
                    outcome = ([message] + notes).joined(separator: " ")
                    outcomeIsError = true
                }
            }
        }
    }
}
