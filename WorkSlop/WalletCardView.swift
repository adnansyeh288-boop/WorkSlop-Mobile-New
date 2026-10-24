import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Apple Wallet card skins — a STANDALONE page, not a tweak and not an
/// Apply method. It never touches staging, `ApplyView`, or any method card:
/// scan (syslog) → photo + crop → flash over AirLift, exactly the way
/// `PosterBoardFilesView` stands beside Apply rather than inside it.
///
/// The flash chain ends in `Airlift.writeDir` (`WalletCardSkin.flash`),
/// with `rc == 0` checked there. A success message is only shown when that
/// write actually succeeded. Preview/crop alone applies nothing.
///
/// Scope limits, stated here because hiding them would be the gimmick:
/// - Apple Card cannot be skinned (dynamic Metal rendering).
/// - Cache invalidation is best-effort (some iOS versions have no
///   `.cache`/`.pkcache` folders); the artwork write is what counts.
/// - Apple Books must be installed and opened at least once, or AirLift
///   writes fail with a misleading error.
/// - There is NO Remove for Wallet skins in AirCard, and none is invented
///   here: changing artwork means flashing another skin. WorkSlop does not
///   restore originals. (Pending user decision — see the report.)
/// - Blocked outright on iOS 27.3+ (AirTraffic patch boundary), enforced
///   before any tunnel work, on this page only.
struct WalletCardView: View {
    @State private var cards: [WalletCardSkin.StoredCard] = WalletCardSkin.loadCards()
    @State private var scanner = WalletCardScanner()
    @State private var scanning = false
    @State private var stopScan: (() -> Void)?
    @State private var selectedId: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var showingCrop = false
    @State private var flashing = false
    @State private var log: [String] = []
    @State private var note: String?
    @State private var blockedReason: String?
    @State private var deviceVersion = ""

    private var selectedCard: WalletCardSkin.StoredCard? {
        cards.first { $0.id == selectedId }
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
                Text("Scan finds your cards from Wallet's own logs while you open Apple Pay — no card numbers are read, only the card identifier Wallet logs. Cards stay saved here so you can flash later without the card in the reader.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(scanning ? "Stop scanning" : "Scan for cards") {
                    if scanning { stopScanning() } else { startScanning() }
                }
                .disabled(blockedReason != nil)
                .accessibilityIdentifier("wallet-scan")
                if scanning {
                    Text("Open Apple Pay (double-click the Side button) and tap a card…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Cards")
            } footer: {
                Text("Apple Card cannot be skinned: it uses dynamic Metal rendering, not static artwork. Force-close the Wallet app from the App Switcher (or reboot) after flashing to see the new artwork.")
            }

            if cards.isEmpty {
                Section {
                    Text("No cards found yet. Scan while Wallet is open, or come back after a scan — found cards are saved here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(cards) { card in
                        Button {
                            selectedId = card.id
                        } label: {
                            HStack {
                                if let img = WalletCardSkin.skinImage(for: card) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 64, height: 40)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    Image(systemName: "creditcard")
                                        .frame(width: 64, height: 40)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(card.title)
                                    Text(String(card.id.prefix(16)) + "…")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if card.id == selectedId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("wallet-card-\(card.id.prefix(8))")
                    }
                    .onDelete { offsets in
                        cards.remove(atOffsets: offsets)
                        WalletCardSkin.saveCards(cards)
                        if let selectedId, !cards.contains(where: { $0.id == selectedId }) {
                            self.selectedId = nil
                        }
                    }
                } header: {
                    Text("Found cards")
                }
            }

            if let selectedCard {
                Section {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose card photo", systemImage: "photo")
                    }
                    .accessibilityIdentifier("wallet-photo-picker")
                    if let img = pickedImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Button("Use this photo as the skin") {
                            assignSkin(image: img, to: selectedCard)
                        }
                        .accessibilityIdentifier("wallet-use-photo")
                    }
                    if selectedCard.skinFile != nil {
                        Button(flashing ? "Flashing…" : "Flash skin to this card") {
                            flash(card: selectedCard)
                        }
                        .disabled(flashing || blockedReason != nil)
                        .accessibilityIdentifier("wallet-flash")
                    } else {
                        Text("Choose a photo first — the skin is the cropped 1536×969 image, not the raw photo.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Skin for \(selectedCard.title)")
                } footer: {
                    Text("Changing artwork means flashing another skin. WorkSlop does not restore the card's original artwork — there is no Remove for Wallet skins.")
                }
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
        .navigationTitle("Wallet Card Skins")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            deviceVersion = await AirCardPageVersion.resolve()
            blockedReason = AirCardGate.blockedReason(deviceVersion: deviceVersion)
        }
        .onDisappear {
            stopScanning()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let img = await item.loadAirCardImage() {
                    await MainActor.run {
                        pickedImage = img
                        showingCrop = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingCrop) {
            if let pickedImage {
                WalletPhotoCropView(image: pickedImage) { cropped in
                    self.pickedImage = cropped
                }
            }
        }
    }

    // MARK: - Scan

    private func startScanning() {
        guard blockedReason == nil else { return }
        guard FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) else {
            note = "AirLift needs a pairing record and none is stored. Import one on the home page first."
            return
        }
        scanning = true
        log.append("wallet: scan started — open Apple Pay and tap a card.")
        Task {
            do {
                // Fresh gate (not the stale .task page state): re-resolve the
                // version right before streaming, mirroring the flash gates.
                let version = await AirCardPageVersion.resolve()
                guard AirCardGate.blockedReason(deviceVersion: version) == nil else {
                    await MainActor.run {
                        scanning = false
                        note = "AirCard is blocked on this iOS version."
                    }
                    return
                }
                let stop = try await Airlift.streamSyslog(
                    pairingPath: AppPaths.pairingFile.path
                ) { line in
                    guard WalletCardScanner.prefilter(line) else { return }
                    Task { @MainActor in
                        let found = scanner.process(line: line)
                        for card in found {
                            if let idx = cards.firstIndex(where: { $0.id == card.id }) {
                                if cards[idx].network == nil, let net = card.network {
                                    cards[idx].network = net
                                    WalletCardSkin.saveCards(cards)
                                }
                            } else {
                                cards.append(WalletCardSkin.StoredCard(id: card.id,
                                                                       network: card.network,
                                                                       skinFile: nil))
                                WalletCardSkin.saveCards(cards)
                                log.append("wallet: found card \(card.id)"
                                    + (card.network.map { " (\($0))" } ?? ""))
                                if selectedId == nil { selectedId = card.id }
                            }
                        }
                    }
                }
                await MainActor.run { stopScan = stop }
            } catch {
                await MainActor.run {
                    scanning = false
                    note = "Card scan failed: \(error.localizedDescription)"
                    log.append("wallet: scan failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopScanning() {
        // Guard the log line: a non-scanning disappear (e.g. plain page exit)
        // must not append a misleading "scan stopped" line.
        guard scanning || stopScan != nil else { return }
        stopScan?()
        stopScan = nil
        scanning = false
        WalletCardSkin.saveCards(cards)
        log.append("wallet: scan stopped (\(cards.count) card(s) saved).")
    }

    // MARK: - Skin + flash

    private func assignSkin(image: UIImage, to card: WalletCardSkin.StoredCard) {
        guard let png = WalletCardSkin.prepareCardImage(from: image),
              let file = WalletCardSkin.saveSkin(png, for: card.id) else {
            note = "Could not prepare the skin from this photo."
            return
        }
        if let idx = cards.firstIndex(where: { $0.id == card.id }) {
            cards[idx].skinFile = file
            WalletCardSkin.saveCards(cards)
        }
        pickedImage = nil
        note = "Skin saved for \(card.title). Flash it to write it to the card."
        log.append("wallet: skin staged for \(card.id) (\(png.count) bytes, 1536×969).")
    }

    private func flash(card: WalletCardSkin.StoredCard) {
        guard let image = WalletCardSkin.skinImage(for: card) else {
            note = "No skin image saved for this card."
            return
        }
        flashing = true
        note = nil
        Task {
            do {
                let version = await AirCardPageVersion.resolve()
                let cacheLines = try await WalletCardSkin.flash(
                    cardId: card.id,
                    sourceImage: image,
                    deviceVersion: version,
                    pairingPath: AppPaths.pairingFile.path
                ) { line in
                    Task { @MainActor in log.append(line) }
                }
                await MainActor.run {
                    for line in cacheLines { log.append(line) }
                    note = "Skin flashed to \(card.title). Force-close Wallet to see it. "
                        + "Cache invalidation is best-effort — see the log."
                    flashing = false
                }
            } catch {
                await MainActor.run {
                    note = "Flash failed: \(error.localizedDescription)"
                    log.append("wallet: flash failed: \(error.localizedDescription)")
                    flashing = false
                }
            }
        }
    }
}

// MARK: - Photo crop (aspect 1536:969)

/// Drag/pinch crop for a card photo. "Use Photo" renders the visible
/// viewport into exactly 1536×969 — the size the skin generator expects.
/// Back dismisses without changing the picked photo.
struct WalletPhotoCropView: View {
    let image: UIImage
    let onUse: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1.0
    @State private var lastZoom: CGFloat = 1.0
    @State private var offset = CGSize.zero
    @State private var lastOffset = CGSize.zero
    @State private var viewportSize = CGSize(width: 300, height: 300 * 969.0 / 1536.0)

    private var aspect: CGFloat { WalletCardSkin.cardAspect }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    let width = max(0, min(geometry.size.width, geometry.size.height * aspect))
                    let height = width / aspect
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width, height: height)
                            .scaleEffect(zoom)
                            .offset(offset)
                            .clipped()
                    }
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(.secondary.opacity(0.4), lineWidth: 1)
                    }
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset }
                            .simultaneously(with:
                                MagnificationGesture()
                                    .onChanged { value in
                                        zoom = max(1.0, min(5.0, lastZoom * value))
                                    }
                                    .onEnded { _ in lastZoom = zoom }
                            )
                    )
                    .onAppear { viewportSize = CGSize(width: width, height: height) }
                    .onChange(of: geometry.size) { _, _ in
                        viewportSize = CGSize(width: width, height: height)
                    }
                }
                Text("Drag to position. Pinch to zoom.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Slider(value: $zoom, in: 1...5) { Text("Zoom") }
                    Text("\(zoom, specifier: "%.1f")×")
                        .font(.subheadline.monospacedDigit())
                        .fixedSize()
                    Button("Reset") {
                        zoom = 1.0
                        lastZoom = 1.0
                        offset = .zero
                        lastOffset = .zero
                    }
                    .fixedSize()
                }
            }
            .padding()
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Adjust Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Photo") {
                        if let cropped = croppedImage() { onUse(cropped) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    /// Renders the visible viewport into 1536×969, applying the same
    /// cover-fit + zoom + pan math the preview shows.
    private func croppedImage() -> UIImage? {
        let vw = viewportSize.width
        let vh = viewportSize.height
        guard vw > 0, vh > 0, image.size.width > 0, image.size.height > 0 else { return nil }
        let baseScale = max(vw / image.size.width, vh / image.size.height)
        let dw = image.size.width * baseScale * zoom
        let dh = image.size.height * baseScale * zoom
        let ox = (vw - dw) / 2 + offset.width
        let oy = (vh - dh) / 2 + offset.height
        let scale = 1536.0 / vw
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1536, height: 969), format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(x: ox * scale, y: oy * scale,
                                  width: dw * scale, height: dh * scale))
        }
    }
}
