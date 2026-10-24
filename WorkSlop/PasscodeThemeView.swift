import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Custom passcode themes — a STANDALONE page, not a tweak and not an
/// Apply method. It never touches staging, `ApplyView`, or any method card:
/// import a `.passthm` or create keys, preview the dialer, then flash over
/// AirLift, the way `PosterBoardFilesView` stands beside Apply.
///
/// The flash chain ends in `Airlift.writeDir` (`PasscodeTheme.apply`),
/// with `rc == 0` checked per TelephonyUI directory. A success message is
/// only shown when every target directory wrote. Preview, creator slicing,
/// and `.passthm` export write nothing to the device and are never
/// reported as applied.
///
/// Scope limits, stated here because hiding them would be the gimmick:
/// - Apple Books must be installed and opened at least once, or AirLift
///   writes fail with a misleading error.
/// - There is NO Remove for passcode themes in AirCard, and none is invented
///   here: changing the theme means flashing another theme. WorkSlop does
///   not restore the original keypad artwork. (Pending user decision.)
/// - Blocked outright on iOS 27.3+ (AirTraffic patch boundary), enforced
///   before any tunnel work, on this page only.
struct PasscodeThemeView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case applyTheme = "Apply .passthm"
        case create = "Create theme"
        var id: String { rawValue }
    }

    enum SliceMode: String, CaseIterable, Identifiable {
        case poster = "Poster slice"
        case circles = "Circle keys"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .applyTheme
    @State private var importing = false
    @State private var loadedName: String?
    @State private var loadedKeys: [String: Data] = [:]
    @State private var creatorKeys: [String: UIImage] = [:]
    @State private var posterItem: PhotosPickerItem?
    @State private var posterImage: UIImage?
    @State private var sliceMode: SliceMode = .poster
    @State private var sliceZoom: CGFloat = 1.0
    @State private var keyDigit = "1"
    @State private var keyItem: PhotosPickerItem?
    @State private var telephonyVersion: PasscodeTheme.TelephonyVersion = .v10
    @State private var languageTarget: PasscodeTheme.LanguageTarget = .detected
    @State private var boldTarget: PasscodeTheme.BoldTarget = .both
    @State private var flashing = false
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var log: [String] = []
    @State private var note: String?
    @State private var blockedReason: String?

    /// Keys for preview: creator keys win when present, else the loaded theme.
    private var previewImages: [String: UIImage] {
        if !creatorKeys.isEmpty { return creatorKeys }
        var out: [String: UIImage] = [:]
        for (digit, data) in loadedKeys {
            if let img = UIImage(data: data) { out[digit] = img }
        }
        return out
    }

    /// Keys for flashing, as raw PNG data (creator images converted).
    private var flashKeys: [String: Data] {
        if !creatorKeys.isEmpty {
            var out: [String: Data] = [:]
            for (digit, img) in creatorKeys {
                if let png = img.pngData() { out[digit] = png }
            }
            return out
        }
        return loadedKeys
    }

    var body: some View {
        List {
            if let blockedReason {
                Section {
                    Label(blockedReason, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } header: {
                    Text("Unavailable on this iOS version")
                }
            }

            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("passcode-mode")
            } footer: {
                Text("Preview and export never touch the device. Only the Flash button writes, over AirLift.")
            }

            if mode == .applyTheme {
                Section {
                    Button("Import .passthm file") { importing = true }
                        .accessibilityIdentifier("passcode-import")
                    if let loadedName {
                        Text("Loaded: \(loadedName) — \(flashKeys.count) key(s).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("A .passthm is a zip of key images (Cawabunga/Nugget format also reads). Import one, preview it below, then flash.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !loadedKeys.isEmpty {
                        Button("Clear loaded theme") {
                            loadedKeys = [:]
                            loadedName = nil
                        }
                        .foregroundStyle(.red)
                    }
                } header: {
                    Text("Theme file")
                }
            } else {
                Section {
                    PhotosPicker(selection: $posterItem, matching: .images) {
                        Label("Choose poster photo", systemImage: "photo")
                    }
                    .accessibilityIdentifier("passcode-poster-picker")
                    Picker("Slice style", selection: $sliceMode) {
                        ForEach(SliceMode.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    HStack {
                        Text("Zoom")
                        Slider(value: $sliceZoom, in: 1...3) { Text("Zoom") }
                        Text("\(sliceZoom, specifier: "%.1f")×")
                            .font(.subheadline.monospacedDigit())
                            .fixedSize()
                    }
                    Button("Slice poster into keys") {
                        if let posterImage {
                            creatorKeys = PasscodeTheme.slicePoster(
                                image: posterImage, zoom: sliceZoom,
                                maskToCircles: sliceMode == .circles)
                            note = "Sliced poster into \(creatorKeys.count) key(s) (poster grid 915×1148)."
                            log.append("passcode: sliced poster (\(sliceMode.rawValue), zoom \(sliceZoom)) → \(creatorKeys.count) keys.")
                        }
                    }
                    .disabled(posterImage == nil)
                    .accessibilityIdentifier("passcode-slice")
                    Picker("Key", selection: $keyDigit) {
                        ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], id: \.self) { d in
                            Text(d).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    PhotosPicker(selection: $keyItem, matching: .images) {
                        Label("Choose photo for key \(keyDigit)", systemImage: "photo")
                    }
                    .accessibilityIdentifier("passcode-key-picker")
                    if !creatorKeys.isEmpty {
                        Button("Clear created keys") { creatorKeys = [:] }
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Theme creator")
                } footer: {
                    Text("Poster slice cuts one photo across the keypad grid; circle keys cut round tiles. Or set keys one by one with the key picker (circular crop).")
                }
            }

            if !previewImages.isEmpty {
                Section {
                    PasscodeDialerPreview(images: previewImages)
                } header: {
                    Text("Keypad preview")
                } footer: {
                    Text("Preview only — what you see here is the local render, not a device write.")
                }
            }

            Section {
                Picker("TelephonyUI version", selection: $telephonyVersion) {
                    ForEach(PasscodeTheme.TelephonyVersion.allCases) { v in
                        Text(v.title).tag(v)
                    }
                }
                Picker("Language", selection: $languageTarget) {
                    ForEach(PasscodeTheme.LanguageTarget.allCases) { l in
                        Text(l.title).tag(l)
                    }
                }
                Picker("Bold text", selection: $boldTarget) {
                    ForEach(PasscodeTheme.BoldTarget.allCases) { b in
                        Text(b.title).tag(b)
                    }
                }
            } header: {
                Text("Flash targets")
            }

            Section {
                Button(flashing ? "Flashing…" : "Flash passcode theme") {
                    flash()
                }
                .disabled(flashKeys.isEmpty || flashing || blockedReason != nil)
                .accessibilityIdentifier("passcode-flash")
                Button("Export as .passthm") {
                    export()
                }
                .disabled(previewImages.isEmpty)
                .accessibilityIdentifier("passcode-export")
            } footer: {
                Text("Changing the theme means flashing another theme. WorkSlop does not restore the original keypad artwork — there is no Remove for passcode themes. Lock your iPhone (or restart) to see the new keypad.")
            }

            Section {
                Text("Apple Books must be installed and opened at least once, or AirLift writes fail with a misleading error. A pairing file must be imported on the home page first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Requirements")
            }

            if let note {
                Section {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !log.isEmpty {
                Section {
                    ForEach(log.indices, id: \.self) { i in
                        Text(log[i])
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Flash log")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Passcode Themes")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let version = await AirCardPageVersion.resolve()
            blockedReason = AirCardGate.blockedReason(deviceVersion: version)
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "passthm") ?? .data]) { result in
            switch result {
            case .success(let url):
                guard url.pathExtension.lowercased() == "passthm" else {
                    note = "Nothing imported — this table takes .passthm only."
                    return
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                Task {
                    do {
                        let keys = try await PasscodeTheme.readPassthm(url: url)
                        await MainActor.run {
                            loadedKeys = keys
                            loadedName = url.deletingPathExtension().lastPathComponent
                            creatorKeys = [:]
                            note = "Loaded \(url.lastPathComponent): \(keys.count) key(s)."
                            log.append("passcode: imported \(url.lastPathComponent) → \(keys.count) key(s).")
                        }
                    } catch {
                        await MainActor.run {
                            note = "Import failed: \(error.localizedDescription)"
                        }
                    }
                }
            case .failure:
                note = "Import cancelled."
            }
        }
        .onChange(of: posterItem) { _, item in
            guard let item else { return }
            Task {
                if let img = await item.loadAirCardImage() {
                    await MainActor.run { posterImage = img }
                }
            }
        }
        .onChange(of: keyItem) { _, item in
            guard let item else { return }
            let digit = keyDigit
            Task {
                if let img = await item.loadAirCardImage(),
                   let tile = PasscodeTheme.cropToCircle(image: img) {
                    await MainActor.run {
                        creatorKeys[digit] = tile
                        log.append("passcode: key \(digit) set from photo (circular crop).")
                    }
                }
            }
        }
        .sheet(isPresented: $exporting) {
            if let exportURL {
                DocumentExportPicker(url: exportURL) { _ in
                    exporting = false
                    note = "Theme exported."
                } onCancelled: {
                    exporting = false
                }
            }
        }
    }

    // MARK: - Flash / export

    private func flash() {
        let keys = flashKeys
        guard !keys.isEmpty else { return }
        flashing = true
        note = nil
        let version = telephonyVersion
        let target = languageTarget
        let bold = boldTarget
        Task {
            do {
                let deviceVersion = await AirCardPageVersion.resolve()
                try await PasscodeTheme.apply(
                    keys: keys,
                    telephonyVersion: version,
                    target: target,
                    bold: bold,
                    deviceVersion: deviceVersion,
                    pairingPath: AppPaths.pairingFile.path
                ) { line in
                    Task { @MainActor in log.append(line) }
                }
                await MainActor.run {
                    note = "Passcode theme applied to \(version.title). Lock your iPhone to see it."
                    log.append("passcode: theme applied (\(keys.count) key(s)).")
                    flashing = false
                }
            } catch {
                await MainActor.run {
                    note = "Flash failed: \(error.localizedDescription)"
                    log.append("passcode: flash failed: \(error.localizedDescription)")
                    flashing = false
                }
            }
        }
    }

    private func export() {
        let images = previewImages
        guard !images.isEmpty else { return }
        do {
            let data = try PasscodeTheme.buildPassthm(keys: images,
                                                      telephonyVersion: telephonyVersion,
                                                      target: languageTarget,
                                                      bold: boldTarget)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkSlop_Theme_\(Int(Date().timeIntervalSince1970)).passthm")
            try data.write(to: url)
            exportURL = url
            exporting = true
            log.append("passcode: exported .passthm (\(data.count) bytes, stored zip).")
        } catch {
            note = "Export failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Dialer preview (local render only)

/// A 3-column keypad preview: digit + letters over the key image when one
/// exists. This renders locally; it is not a device write and never claims
/// to be one.
struct PasscodeDialerPreview: View {
    let images: [String: UIImage]

    /// Keypad rows, with key 0 centered on the last row like the real dialer.
    private var rows: [[PasscodeTheme.KeypadButton?]] {
        let byDigit = Dictionary(uniqueKeysWithValues: PasscodeTheme.allButtons.map { ($0.digit, $0) })
        return [
            ["1", "2", "3"].map { byDigit[$0] },
            ["4", "5", "6"].map { byDigit[$0] },
            ["7", "8", "9"].map { byDigit[$0] },
            [nil, byDigit["0"], nil],
        ]
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 12) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        if let btn = rows[r][c] {
                            ZStack {
                                if let img = images[btn.digit] {
                                    Image(uiImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    Color.secondary.opacity(0.15)
                                }
                                VStack(spacing: 0) {
                                    Text(btn.digit)
                                        .font(.title3.weight(.semibold))
                                    if !btn.letters.isEmpty {
                                        Text(btn.letters)
                                            .font(.caption2)
                                    }
                                }
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                            }
                            .frame(height: 64)
                            .clipShape(Circle())
                        } else {
                            Color.clear.frame(height: 64)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
