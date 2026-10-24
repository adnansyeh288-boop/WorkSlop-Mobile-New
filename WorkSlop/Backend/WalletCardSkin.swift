import Foundation
import UIKit

/// Apple Wallet card skins over AirLift, ported from AirCard-iOS HEAD
/// (40640c4: `ios-app/Models.swift` skin generation + `ios-app/AppViewModel.swift`
/// `flashCards`). This is a NEW port, not a restore of the pre-migration
/// WorkSlop engine deleted in 9229dda — AirCard HEAD is richer (full parser,
/// multi-resolution + PDF skins, crop view) and the WorkSlop seams have moved
/// since (pairing path, version gate, standalone pages).
///
/// Delivery is AirLift only, never backup/restore: there is no manifest
/// domain for Passbook caches, so `mobilebackup2` cannot carry card artwork
/// (`Airlift.swift` header comment). The flash chain is:
///
/// 1. `prepareAllCardSkins` renders the source photo into the 11 files
///    AirCard writes (4 names × @3x/@2x + 3 transit PDFs).
/// 2. `Airlift.writeDir` writes that staging directory to
///    `/var/mobile/Library/Passes/Cards/<cleanId>.pkpass`, with `rc == 0`
///    checked by `Airlift.writeDir` itself — a failed artwork write is a
///    hard failure for that card, never a silent skip.
/// 3. Cache invalidation writes the literal bytes "corrupted" as
///    `FrontFace`/`Preview`/`PlaceHolder` into `<cleanId>.cache` and
///    `<cleanId>.pkcache`. This step is BEST-EFFORT by design (AirCard's
///    own comment: some iOS versions have neither folder): its `rc` is
///    logged, never thrown. A card whose artwork wrote but whose cache
///    invalidation failed still counts as flashed; the user force-closes
///    Wallet to re-render.
///
/// What this file deliberately does NOT do: there is no Remove/restore of
/// the original artwork anywhere in AirCard, and none is invented here.
/// Changing artwork means flashing another skin; WorkSlop does not restore
/// originals. That is labeled in the page UI and flagged as a pending user
/// decision, not hidden.
///
/// Xcframework divergence (coordinator decision, see `AirCardGate.swift`):
/// this port stays on WorkSlop's vendored AirliftFFI snapshot, which lacks
/// AirCard HEAD's `al_set_target_host(s)`. The write path uses the default
/// LocalDevVPN route that PosterBoard-over-AirLift already uses; device
/// testing must prove the default route suffices for the Wallet syslog
/// stream too. No parity with AirCard HEAD's binary is claimed.
enum WalletCardSkin {
    // MARK: - Card identifier

    /// Normalizes a card identifier: strips paths, quotes, whitespace, and
    /// the `.pkpass`/`.cache`/`.pkcache` suffixes. Ported from AirCard's
    /// `CardItem.cleanCardId`.
    static func cleanCardId(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}"))
        if s.contains("/") {
            s = (s as NSString).lastPathComponent
        }
        for ext in [".pkpass", ".cache", ".pkcache"] where s.hasSuffix(ext) {
            s = String(s.dropLast(ext.count))
        }
        guard s.count >= 20, s.count <= 80 else { return nil }
        return s
    }

    /// Filesystem-safe form for local staging/storage names.
    static func safeCardId(_ cleanId: String) -> String {
        cleanId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    // MARK: - Skin generation

    /// Card artwork aspect ratio (1536:969), shared with the crop view.
    static let cardAspect: CGFloat = 1536.0 / 969.0

    /// Decodes image data at reduced dimensions via ImageIO, so a 48MP
    /// camera photo never lands as a full uncompressed bitmap (Jetsam).
    static func safeImageFromData(_ data: Data, maxDimension: CGFloat = 2048) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return UIImage(data: data).map { normalizeAndDownsample($0, maxDimension: maxDimension) }
        }
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ] as CFDictionary
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(data: data).map { normalizeAndDownsample($0, maxDimension: maxDimension) }
    }

    /// Normalizes orientation and downsamples to `maxDimension`.
    static func normalizeAndDownsample(_ image: UIImage, maxDimension: CGFloat = 2048) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let targetSize = CGSize(width: max(1, floor(size.width * scale)),
                                height: max(1, floor(size.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: targetSize)) }
    }

    /// Cover-resizes an image to exactly `targetSize` (center-cropped fill).
    static func resizeImage(_ image: UIImage, targetSize: CGSize) -> Data? {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return nil }
        let scale = max(targetSize.width / imgSize.width, targetSize.height / imgSize.height)
        let scaledSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
        let origin = CGPoint(x: (targetSize.width - scaledSize.width) / 2,
                             y: (targetSize.height - scaledSize.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let out = renderer.image { _ in image.draw(in: CGRect(origin: origin, size: scaledSize)) }
        return out.pngData()
    }

    /// The primary 1536×969 PNG preview/storage image.
    static func prepareCardImage(from image: UIImage) -> Data? {
        let normalized = normalizeAndDownsample(image, maxDimension: 2560)
        return resizeImage(normalized, targetSize: CGSize(width: 1536, height: 969))
    }

    /// All 11 files AirCard writes per card, from one source photo:
    /// `cardBackgroundCombined`/`diffuse`/`background`/`strip` at @3x
    /// (1536×969) and @2x (1024×646), plus the vector PDF variants for
    /// transit passes (Suica/Pasmo/ICOCA). The PNG data is shared per
    /// resolution and the PDF is one render reused for all three names —
    /// exactly as AirCard's `prepareAllCardSkins` does it. No sub-part is
    /// faked: the transit PDF is a real `UIGraphicsPDFRenderer` render of
    /// the source image at 1536×969.
    static func prepareAllCardSkins(from image: UIImage) -> [String: Data] {
        let normalized = normalizeAndDownsample(image, maxDimension: 2560)
        var skins: [String: Data] = [:]

        if let data3x = resizeImage(normalized, targetSize: CGSize(width: 1536, height: 969)) {
            skins["cardBackgroundCombined@3x.png"] = data3x
            skins["diffuse@3x.png"] = data3x
            skins["background@3x.png"] = data3x
            skins["strip@3x.png"] = data3x
        }
        if let data2x = resizeImage(normalized, targetSize: CGSize(width: 1024, height: 646)) {
            skins["cardBackgroundCombined@2x.png"] = data2x
            skins["diffuse@2x.png"] = data2x
            skins["background@2x.png"] = data2x
            skins["strip@2x.png"] = data2x
        }

        let pdfRect = CGRect(origin: .zero, size: CGSize(width: 1536, height: 969))
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: pdfRect)
        let pdfData = pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            normalized.draw(in: pdfRect)
        }
        skins["cardBackgroundCombined.pdf"] = pdfData
        skins["background.pdf"] = pdfData
        skins["strip.pdf"] = pdfData

        return skins
    }

    // MARK: - Local store

    /// One discovered card, persisted so a flash can run later without the
    /// card being in the reader again (AirCard's `saveCards` behaviour).
    struct StoredCard: Codable, Equatable, Identifiable {
        var id: String
        var network: String?
        /// Local 1536×969 skin PNG, stored beside the JSON (a skin is ~MB,
        /// which is why this is a file, not a UserDefaults blob).
        var skinFile: String?

        var title: String {
            if let net = network, !net.isEmpty {
                return net.hasSuffix("Card") ? net : "\(net) Card"
            }
            return "Payment Card"
        }
    }

    static let storeDir = URL.documents.appendingPathComponent("WalletCards", isDirectory: true)
    private static let storeFile = "cards.json"

    static func loadCards() -> [StoredCard] {
        let url = storeDir.appendingPathComponent(storeFile)
        guard let data = try? Data(contentsOf: url),
              let cards = try? JSONDecoder().decode([StoredCard].self, from: data) else { return [] }
        return cards
    }

    static func saveCards(_ cards: [StoredCard]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cards) else { return }
        try? data.write(to: storeDir.appendingPathComponent(storeFile), options: .atomic)
    }

    /// Persists a 1536×969 skin PNG for a card; returns the stored filename.
    static func saveSkin(_ pngData: Data, for cleanId: String) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let name = "card_\(safeCardId(cleanId)).png"
        do {
            try pngData.write(to: storeDir.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func skinImage(for card: StoredCard) -> UIImage? {
        guard let file = card.skinFile else { return nil }
        guard let data = try? Data(contentsOf: storeDir.appendingPathComponent(file)) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Flash

    /// Flashes one card's skin. The gate runs FIRST, before any tunnel work.
    ///
    /// - Returns: the cache-invalidation lines for the log (best-effort
    ///   results, never thrown). The artwork write itself throws on failure
    ///   via `Airlift.writeDir` (`rc == 0` checked there).
    /// - Throws: gate refusal, missing pairing file, skin-generation failure,
    ///   or the artwork write itself.
    @discardableResult
    static func flash(cardId: String,
                      sourceImage: UIImage,
                      deviceVersion: String,
                      pairingPath: String,
                      log: @escaping @Sendable (String) -> Void) async throws -> [String] {
        try AirCardGate.requireUnpatched(deviceVersion: deviceVersion)
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw GoldenNuggetError("AirLift needs a pairing record and none is stored. "
                + "Import one on the home page first.")
        }
        guard let cleanId = cleanCardId(cardId) else {
            throw GoldenNuggetError("Cannot flash card \(cardId): the identifier is not a valid card id.")
        }
        let skins = prepareAllCardSkins(from: sourceImage)
        guard !skins.isEmpty else {
            throw GoldenNuggetError("Could not generate card skins from this photo.")
        }

        let fm = FileManager.default
        let stageDir = fm.temporaryDirectory
            .appendingPathComponent("airlift_card_\(safeCardId(cleanId))_\(UUID().uuidString)")
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }
        for (name, data) in skins {
            try data.write(to: stageDir.appendingPathComponent(name))
        }

        let pkpassTarget = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass"
        log("wallet: writing \(skins.count) skin files to \(pkpassTarget)")
        try await Airlift.writeDir(pairingPath: pairingPath,
                                   sourceDir: stageDir.path,
                                   targetDir: pkpassTarget)
        log("wallet: skins written to \(cleanId).pkpass (rc 0)")

        // Cache invalidation — best-effort, rc logged, never thrown.
        let invDir = fm.temporaryDirectory
            .appendingPathComponent("airlift_inv_\(UUID().uuidString)")
        try? fm.createDirectory(at: invDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: invDir) }
        for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
            try? Data("corrupted".utf8).write(to: invDir.appendingPathComponent(leaf))
        }
        var lines: [String] = []
        for ext in [".cache", ".pkcache"] {
            let cacheTarget = "/var/mobile/Library/Passes/Cards/\(cleanId)\(ext)"
            do {
                try await Airlift.writeDir(pairingPath: pairingPath,
                                           sourceDir: invDir.path,
                                           targetDir: cacheTarget)
                lines.append("wallet: cache invalidated at \(cacheTarget)")
            } catch {
                // Some iOS versions have neither folder; the artwork write
                // above already succeeded, so this stays a log line.
                lines.append("wallet: cache invalidation skipped for \(cacheTarget) "
                    + "(best-effort, may not exist on this iOS version): \(error.localizedDescription)")
            }
        }
        return lines
    }
}
