import Foundation
import UIKit

/// Custom passcode themes over AirLift, ported from AirCard-iOS HEAD
/// (40640c4: `ios-app/Models.swift` staging/packager/reader/slicing +
/// `ios-app/AppViewModel.swift` `flashPassthm`). A NEW port, not a restore of
/// the pre-migration WorkSlop engine deleted in 9229dda.
///
/// Delivery is AirLift only, never backup/restore: there is no manifest
/// domain for TelephonyUI caches (`Airlift.swift` header comment). The only
/// apply path is `apply(...)` → `Airlift.writeDir` per TelephonyUI
/// directory, with `rc == 0` checked by `Airlift.writeDir` itself. Preview,
/// creator slicing, and `.passthm` export write nothing to the device and
/// are never reported as applied.
///
/// File naming follows AirCard exactly: `<lang>-<digit>-<subtext>--white[-bold].png`,
/// with the special digit rules below and the empty `_big` marker at the
/// staging root — iOS ignores @3x artwork without that marker, and it is
/// the detail most easily lost in a port.
///
/// ## Digit rules (staging, per digit, per language, per weight)
/// - `0`: blank (`<lang>-0---white[-bold].png`) AND plus
///   (`<lang>-0-+--white[-bold].png`) — nothing else.
/// - `1`: blank only.
/// - `2`–`9`: blank + standard Latin subtext (`2 → "A B C"`) + the same
///   subtext without spaces + Cyrillic RU (when lang is `ru`, or when the
///   target is `all` — AirCard writes the Cyrillic variants under EVERY
///   language in `all` mode, wasteful but faithful) + Cyrillic UK (same
///   rule for `uk`).
///
/// ## No Remove
/// AirCard has no code that restores the original keypad artwork, and none
/// is invented here. Changing the theme means flashing another theme.
/// That is labeled in the page UI and flagged as a pending user decision.
///
/// ## Xcframework divergence
/// Same as `WalletCardSkin`: this port stays on WorkSlop's vendored
/// AirliftFFI snapshot, which lacks AirCard HEAD's `al_set_target_host(s)`
/// (see `AirCardGate.swift`). Device testing must prove the default
/// LocalDevVPN route suffices. No parity with AirCard HEAD's binary claimed.
enum PasscodeTheme {
    // MARK: - Targets

    /// TelephonyUI cache directory version. Default is -10 (iOS 18+).
    enum TelephonyVersion: String, CaseIterable, Identifiable {
        case all = "all"
        case v10 = "TelephonyUI-10"
        case v9 = "TelephonyUI-9"
        case v8 = "TelephonyUI-8"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All versions (-10, -9, -8)"
            case .v10: return "-10 (iOS 18+)"
            case .v9: return "-9 (iOS 16–17)"
            case .v8: return "-8 (iOS 14–15)"
            }
        }
        var directories: [String] {
            switch self {
            case .all: return ["TelephonyUI-10", "TelephonyUI-9", "TelephonyUI-8"]
            case .v10: return ["TelephonyUI-10"]
            case .v9: return ["TelephonyUI-9"]
            case .v8: return ["TelephonyUI-8"]
            }
        }
    }

    /// Bold/regular weight target, as AirCard's `PasscodeBoldTarget`.
    enum BoldTarget: String, CaseIterable, Identifiable {
        case both = "both"
        case boldOnly = "bold"
        case regularOnly = "regular"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .both: return "Regular + Bold"
            case .boldOnly: return "Bold text only"
            case .regularOnly: return "Regular text only"
            }
        }
        var suffixes: [String] {
            switch self {
            case .both: return ["", "-bold"]
            case .boldOnly: return ["-bold"]
            case .regularOnly: return [""]
            }
        }
    }

    /// Language target, as AirCard's `PasscodeLanguageTarget`.
    enum LanguageTarget: String, CaseIterable, Identifiable {
        case all, uk, ru, en, other, es, de, fr, pl, it, pt, tr, ja, ko, zh, ar, he

        var id: String { rawValue }
        var code: String {
            switch self {
            case .all: return "all"
            default: return rawValue
            }
        }
        var title: String {
            switch self {
            case .all: return "All languages"
            case .uk: return "Ukrainian (uk)"
            case .ru: return "Russian (ru)"
            case .en: return "English (en)"
            case .other: return "Other / fallback"
            case .es: return "Spanish (es)"
            case .de: return "German (de)"
            case .fr: return "French (fr)"
            case .pl: return "Polish (pl)"
            case .it: return "Italian (it)"
            case .pt: return "Portuguese (pt)"
            case .tr: return "Turkish (tr)"
            case .ja: return "Japanese (ja)"
            case .ko: return "Korean (ko)"
            case .zh: return "Chinese (zh)"
            case .ar: return "Arabic (ar)"
            case .he: return "Hebrew (he)"
            }
        }

        /// The device's own language as a target, from the preferred locale.
        static var detected: LanguageTarget {
            let lang = Locale.preferredLanguages.first ?? "en"
            let code = lang.split(separator: "-").first.map(String.init) ?? "en"
            return LanguageTarget(rawValue: code) ?? .en
        }
    }

    // MARK: - Keypad data (AirCard `KeypadLocales` / `KeypadLayout`)

    /// All 17 locale codes AirCard stages in `all` mode, in AirCard's order.
    static let allLocales: [String] = [
        "en", "other", "ru", "uk", "es", "fr", "de", "it", "pt", "tr", "pl", "nl",
        "ja", "ko", "zh", "ar", "he",
    ]

    static let subtexts: [String: String] = [
        "0": "+", "1": "", "2": "A B C", "3": "D E F",
        "4": "G H I", "5": "J K L", "6": "M N O",
        "7": "P Q R S", "8": "T U V", "9": "W X Y Z",
    ]

    static let cyrillicRU: [String: String] = [
        "2": "А Б В Г", "3": "Д Е Ж З", "4": "И Й К Л", "5": "М Н О П",
        "6": "Р С Т У", "7": "Ф Х Ц Ч", "8": "Ш Щ Ъ Ы", "9": "Ь Э Ю Я",
    ]

    static let cyrillicUK: [String: String] = [
        "2": "А Б В Г", "3": "Д Е Ж З", "4": "І Ї Й К", "5": "Л М Н О",
        "6": "П Р С Т", "7": "У Ф Х Ц", "8": "Ч Ш Щ Ь", "9": "Ю Я",
    ]

    /// Keypad button geometry for the preview dialer and poster slicing.
    struct KeypadButton: Identifiable {
        var id: String { digit }
        let digit: String
        let letters: String
        let row: Int
        let col: Int
    }

    static let allButtons: [KeypadButton] = [
        KeypadButton(digit: "1", letters: "", row: 0, col: 0),
        KeypadButton(digit: "2", letters: "A B C", row: 0, col: 1),
        KeypadButton(digit: "3", letters: "D E F", row: 0, col: 2),
        KeypadButton(digit: "4", letters: "G H I", row: 1, col: 0),
        KeypadButton(digit: "5", letters: "J K L", row: 1, col: 1),
        KeypadButton(digit: "6", letters: "M N O", row: 1, col: 2),
        KeypadButton(digit: "7", letters: "P Q R S", row: 2, col: 0),
        KeypadButton(digit: "8", letters: "T U V", row: 2, col: 1),
        KeypadButton(digit: "9", letters: "W X Y Z", row: 2, col: 2),
        KeypadButton(digit: "0", letters: "+", row: 3, col: 1),
    ]

    // MARK: - Staging (pure: no device involved)

    /// Languages a flash stages for a target: `all` → all 17 locales;
    /// a single language → that language + `other` + the device language
    /// when it differs (AirCard `flashPassthm`).
    static func languagesForFlash(target: LanguageTarget, detected: LanguageTarget) -> [String] {
        if target == .all { return allLocales }
        var langs = [target.code]
        if target.code != "other" { langs.append("other") }
        if target.code != detected.code, detected.code != "other", !langs.contains(detected.code) {
            langs.append(detected.code)
        }
        return langs
    }

    /// Languages a `.passthm` package carries: `all` → all 17; a single
    /// language → that language + `other` (AirCard's packager does NOT add
    /// the detected device language — kept faithful, not unified).
    static func languagesForPackage(target: LanguageTarget) -> [String] {
        if target == .all { return allLocales }
        return target.code == "other" ? ["other"] : [target.code, "other"]
    }

    /// The staged file entries for one digit's PNG data — every
    /// `<lang>-<digit>-<subtext>--white[-bold].png` name AirCard writes,
    /// without the `_big` marker (callers add it where it belongs: staging
    /// root for a flash, `<ver>/_big` per version for a package).
    static func stagedEntries(digit: String,
                              pngData: Data,
                              languages: [String],
                              targetIsAll: Bool,
                              bold: BoldTarget) -> [(name: String, data: Data)] {
        var entries: [(name: String, data: Data)] = []
        let stdSubtext = subtexts[digit] ?? ""
        for lang in languages {
            for suffix in bold.suffixes {
                if digit == "0" {
                    entries.append(("\(lang)-0---white\(suffix).png", pngData))
                    entries.append(("\(lang)-0-+--white\(suffix).png", pngData))
                } else if digit == "1" {
                    entries.append(("\(lang)-1---white\(suffix).png", pngData))
                } else {
                    entries.append(("\(lang)-\(digit)---white\(suffix).png", pngData))
                    if !stdSubtext.isEmpty {
                        entries.append(("\(lang)-\(digit)-\(stdSubtext)--white\(suffix).png", pngData))
                        let noSpace = stdSubtext.replacingOccurrences(of: " ", with: "")
                        if noSpace != stdSubtext {
                            entries.append(("\(lang)-\(digit)-\(noSpace)--white\(suffix).png", pngData))
                        }
                    }
                    if (lang == "ru" || targetIsAll), let ruSub = cyrillicRU[digit] {
                        entries.append(("\(lang)-\(digit)-\(ruSub)--white\(suffix).png", pngData))
                    }
                    if (lang == "uk" || targetIsAll), let ukSub = cyrillicUK[digit] {
                        entries.append(("\(lang)-\(digit)-\(ukSub)--white\(suffix).png", pngData))
                    }
                }
            }
        }
        return entries
    }

    /// The full staging tree for a flash: all digits' entries plus the
    /// empty `_big` marker. Returns the staging directory URL; the caller
    /// owns removing it.
    static func stageDirectory(keys: [String: Data],
                               target: LanguageTarget,
                               bold: BoldTarget) throws -> URL {
        let langs = languagesForFlash(target: target, detected: .detected)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("airlift_passthm_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (digit, data) in keys {
            for entry in stagedEntries(digit: digit, pngData: data,
                                       languages: langs, targetIsAll: target == .all, bold: bold) {
                try entry.data.write(to: dir.appendingPathComponent(entry.name))
            }
        }
        // iOS TelephonyUI @3x high-res indicator marker — without it, @3x
        // artwork is not used. Empty file, at the staging root.
        try Data().write(to: dir.appendingPathComponent("_big"))
        return dir
    }

    // MARK: - Apply (the only device write)

    /// Flashes a theme: the gate runs FIRST, then one `Airlift.writeDir`
    /// per TelephonyUI directory. Like AirCard, a failed directory marks
    /// the whole apply failed but does not roll back directories already
    /// written — and the error names which directory failed.
    static func apply(keys: [String: Data],
                      telephonyVersion: TelephonyVersion,
                      target: LanguageTarget,
                      bold: BoldTarget,
                      deviceVersion: String,
                      pairingPath: String,
                      log: @escaping @Sendable (String) -> Void) async throws {
        try AirCardGate.requireUnpatched(deviceVersion: deviceVersion)
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw GoldenNuggetError("AirLift needs a pairing record and none is stored. "
                + "Import one on the home page first.")
        }
        guard !keys.isEmpty else {
            throw GoldenNuggetError("No key images loaded. Import a .passthm or create a theme first.")
        }
        let stageDir = try stageDirectory(keys: keys, target: target, bold: bold)
        defer { try? FileManager.default.removeItem(at: stageDir) }
        log("passcode: staged \(keys.count) key image(s) + _big marker; writing to "
            + telephonyVersion.directories.joined(separator: ", "))
        var failures: [String] = []
        for dirName in telephonyVersion.directories {
            let targetPath = "/var/mobile/Library/Caches/\(dirName)"
            do {
                try await Airlift.writeDir(pairingPath: pairingPath,
                                           sourceDir: stageDir.path,
                                           targetDir: targetPath)
                log("passcode: written to \(dirName) (rc 0)")
            } catch {
                failures.append("\(dirName): \(error.localizedDescription)")
                log("passcode: write to \(dirName) failed: \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw GoldenNuggetError("Passcode theme write failed for: "
                + failures.joined(separator: "; ")
                + ". Directories written before the failure were not rolled back.")
        }
    }

    // MARK: - .passthm export (stored-only ZIP, AirCard's writer)

    /// Builds a `.passthm` archive in memory: stored (compression 0) ZIP
    /// entries `<TelephonyUI-n>/<lang>-<digit>-<subtext>--white[-bold].png`
    /// plus `<TelephonyUI-n>/_big` per version, UTF-8 filenames, CRC-32
    /// (ISO 3309). Ported from AirCard's `PasscodeThemePackager`.
    static func buildPassthm(keys: [String: UIImage],
                             telephonyVersion: TelephonyVersion,
                             target: LanguageTarget,
                             bold: BoldTarget) throws -> Data {
        var zipData = Data()
        var centralDirectory = Data()
        var centralDirCount: UInt16 = 0

        func addEntry(name: String, content: Data) {
            guard let nameData = name.data(using: .utf8) else { return }
            let crc = crc32(content)
            let localHeader = makeLocalFileHeader(name: nameData, content: content, crc: crc)
            let offset = UInt32(zipData.count)
            zipData.append(localHeader)
            zipData.append(content)
            centralDirectory.append(
                makeCentralDirEntry(name: nameData, content: content, crc: crc, offset: offset))
            centralDirCount += 1
        }

        let langs = languagesForPackage(target: target)
        for ver in telephonyVersion.directories {
            addEntry(name: "\(ver)/_big", content: Data())
            for (digit, image) in keys {
                guard let pngData = image.pngData() else { continue }
                for entry in stagedEntries(digit: digit, pngData: pngData,
                                           languages: langs, targetIsAll: target == .all, bold: bold) {
                    addEntry(name: "\(ver)/\(entry.name)", content: entry.data)
                }
            }
        }

        let cdOffset = UInt32(zipData.count)
        let cdSize = UInt32(centralDirectory.count)
        zipData.append(centralDirectory)
        zipData.append(makeEndRecord(count: centralDirCount, size: cdSize, offset: cdOffset))
        return zipData
    }

    private static func makeLocalFileHeader(name: Data, content: Data, crc: UInt32) -> Data {
        var d = Data()
        d.appendLE32(0x04034b50)
        d.appendLE16(20)
        d.appendLE16(0x0800) // flags: UTF-8 filenames (bit 11)
        d.appendLE16(0) // compression: stored
        d.appendLE16(0)
        d.appendLE16(0)
        d.appendLE32(crc)
        d.appendLE32(UInt32(content.count))
        d.appendLE32(UInt32(content.count))
        d.appendLE16(UInt16(name.count))
        d.appendLE16(0)
        d.append(name)
        return d
    }

    private static func makeCentralDirEntry(name: Data, content: Data, crc: UInt32, offset: UInt32) -> Data {
        var d = Data()
        d.appendLE32(0x02014b50)
        d.appendLE16(20)
        d.appendLE16(20)
        d.appendLE16(0x0800)
        d.appendLE16(0)
        d.appendLE16(0)
        d.appendLE16(0)
        d.appendLE32(crc)
        d.appendLE32(UInt32(content.count))
        d.appendLE32(UInt32(content.count))
        d.appendLE16(UInt16(name.count))
        d.appendLE16(0)
        d.appendLE16(0)
        d.appendLE16(0)
        d.appendLE16(0)
        d.appendLE32(0)
        d.appendLE32(offset)
        d.append(name)
        return d
    }

    private static func makeEndRecord(count: UInt16, size: UInt32, offset: UInt32) -> Data {
        var d = Data()
        d.appendLE32(0x06054b50)
        d.appendLE16(0)
        d.appendLE16(0)
        d.appendLE16(count)
        d.appendLE16(count)
        d.appendLE32(size)
        d.appendLE32(offset)
        d.appendLE16(0)
        return d
    }

    /// CRC-32 (ISO 3309 / ITU-T V.42).
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            var b = UInt32(byte)
            for _ in 0..<8 {
                let mixed = (crc ^ b) & 1
                crc >>= 1
                if mixed != 0 { crc ^= 0xEDB8_8320 }
                b >>= 1
            }
        }
        return ~crc
    }

    // MARK: - .passthm import (reader over the existing extractor)

    /// Reads a `.passthm` file into raw per-digit PNG data, via the
    /// existing `Airlift.extractPassthm` (Rust `al_passthm_extract`, which
    /// handles deflated AND stored entries — so third-party Cowabunga/Nugget
    /// themes read even though this app's own writer is stored-only).
    /// First image per digit wins; the digit comes from the filename.
    static func readPassthm(url: URL) async throws -> [String: Data] {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("airlift_inspect_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        _ = try await Airlift.extractPassthm(archivePath: url.path, destDir: tempDir.path)
        let files = fm.subpaths(atPath: tempDir.path) ?? []
        guard !files.isEmpty else {
            throw GoldenNuggetError("Could not read .passthm: the archive is empty.")
        }
        var raw: [String: Data] = [:]
        var fileCount = 0
        for file in files {
            guard !file.hasPrefix("."), !file.contains("__MACOSX") else { continue }
            let lower = file.lowercased()
            guard lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") else { continue }
            fileCount += 1
            let filename = (file as NSString).lastPathComponent
            if let digit = extractDigit(from: filename), raw[digit] == nil {
                let filePath = tempDir.appendingPathComponent(file).path
                if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                    raw[digit] = data
                }
            }
        }
        guard !raw.isEmpty else {
            throw GoldenNuggetError("Could not read .passthm: no key images found "
                + "(\(fileCount) image files, none with a recognizable digit filename).")
        }
        return raw
    }

    /// Digit from a theme filename, AirCard's rule: optional language prefix
    /// + digit, then a single-digit fallback scan.
    static func extractDigit(from filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension
        let stemClean = stem
            .replacingOccurrences(of: "--white", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "-white", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "@3x", with: "")
            .replacingOccurrences(of: "@2x", with: "")
        if let regex = try? NSRegularExpression(pattern: #"(?:^[a-zA-Z]+-)?([0-9*#])"#,
                                                options: .caseInsensitive) {
            let nsString = stemClean as NSString
            if let match = regex.firstMatch(in: stemClean,
                                            range: NSRange(location: 0, length: nsString.length)),
               match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                if range.location != NSNotFound {
                    let d = nsString.substring(with: range)
                    if "0123456789".contains(d) { return d }
                }
            }
        }
        for ch in stemClean where "0123456789".contains(ch) { return String(ch) }
        return nil
    }

    // MARK: - Theme creator slicing (AirCard `ImageEngine.slicePoster` / `cropToCircle`)

    /// Slices a poster photo into per-digit tiles on AirCard's 915×1148 grid
    /// (3 columns × 287pt rows, key 0 spanning the full width in poster mode).
    /// Poster mode: unclipped cell tiles (305×287, 915×287 for key 0).
    /// Circle mode: exact 225×225 circular tiles at each button's center.
    static func slicePoster(image: UIImage,
                            zoom: CGFloat = 1.0,
                            offset: CGPoint = .zero,
                            maskToCircles: Bool = false) -> [String: UIImage] {
        let normalized = WalletCardSkin.normalizeAndDownsample(image, maxDimension: 2048)
        let imgW = normalized.size.width
        let imgH = normalized.size.height
        guard imgW > 0, imgH > 0 else { return [:] }

        let gridW: CGFloat = 915.0
        let gridH: CGFloat = 1148.0
        let colW: CGFloat = 305.0
        let rowH: CGFloat = 287.0

        let imgAspect = imgW / imgH
        let gridAspect = gridW / gridH
        let safeZoom = max(0.2, min(5.0, zoom))
        let scaledW: CGFloat
        let scaledH: CGFloat
        if imgAspect > gridAspect {
            scaledH = gridH * safeZoom
            scaledW = scaledH * imgAspect
        } else {
            scaledW = gridW * safeZoom
            scaledH = scaledW / imgAspect
        }
        let imageX = (gridW - scaledW) / 2.0 + offset.x * 3.0
        let imageY = (gridH - scaledH) / 2.0 + offset.y * 3.0

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        var results: [String: UIImage] = [:]
        for btn in allButtons {
            if maskToCircles {
                let cellX = CGFloat(btn.col) * colW
                let cellY = CGFloat(btn.row) * rowH
                let btnCenterX = cellX + colW / 2.0
                let btnCenterY = cellY + rowH / 2.0
                let d: CGFloat = 225.0
                let circleOriginX = btnCenterX - d / 2.0
                let circleOriginY = btnCenterY - d / 2.0
                let tileSize = CGSize(width: d, height: d)
                let destX = imageX - circleOriginX
                let destY = imageY - circleOriginY
                let renderer = UIGraphicsImageRenderer(size: tileSize, format: format)
                let tile = autoreleasepool {
                    renderer.image { _ in
                        UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: d, height: d)).addClip()
                        normalized.draw(in: CGRect(x: destX, y: destY, width: scaledW, height: scaledH))
                    }
                }
                results[btn.digit] = tile
            } else {
                let isZeroSeamless = btn.digit == "0"
                let tileW: CGFloat = isZeroSeamless ? gridW : colW
                let tileH: CGFloat = rowH
                let tileSize = CGSize(width: tileW, height: tileH)
                let cellX: CGFloat = isZeroSeamless ? 0.0 : CGFloat(btn.col) * colW
                let cellY: CGFloat = CGFloat(btn.row) * rowH
                let destX = imageX - cellX
                let destY = imageY - cellY
                let renderer = UIGraphicsImageRenderer(size: tileSize, format: format)
                let tile = renderer.image { _ in
                    normalized.draw(in: CGRect(x: destX, y: destY, width: scaledW, height: scaledH))
                }
                results[btn.digit] = tile
            }
        }
        return results
    }

    /// Crops one photo into a single circular key tile (individual-key mode).
    static func cropToCircle(image: UIImage,
                             targetSize: CGSize = CGSize(width: 225, height: 225),
                             circleDiameter: CGFloat = 222.0,
                             zoom: CGFloat = 1.0,
                             offset: CGPoint = .zero) -> UIImage? {
        let normalized = WalletCardSkin.normalizeAndDownsample(image, maxDimension: 1024)
        let imgW = normalized.size.width
        let imgH = normalized.size.height
        guard imgW > 0, imgH > 0 else { return nil }
        let safeZoom = max(0.2, min(5.0, zoom))
        let baseScale = max(circleDiameter / imgW, circleDiameter / imgH) * safeZoom
        let scaledW = imgW * baseScale
        let scaledH = imgH * baseScale
        let circleX = (targetSize.width - circleDiameter) / 2.0
        let circleY = (targetSize.height - circleDiameter) / 2.0
        let destX = circleX + (circleDiameter - scaledW) / 2.0 + offset.x * 3.0
        let destY = circleY + (circleDiameter - scaledH) / 2.0 + offset.y * 3.0
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            UIBezierPath(ovalIn: CGRect(x: circleX, y: circleY,
                                        width: circleDiameter, height: circleDiameter)).addClip()
            normalized.draw(in: CGRect(x: destX, y: destY, width: scaledW, height: scaledH))
        }
    }
}

private extension Data {
    mutating func appendLE16(_ v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE32(_ v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}
