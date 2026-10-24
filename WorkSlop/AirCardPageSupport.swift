import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Shared helpers for the two standalone AirCard pages. Neither page goes
/// through ApplyView, staging, or any method card — they are standalone the
/// way `PosterBoardFilesView` is standalone.
enum AirCardPageVersion {
    /// The device iOS version for the AirCard gate, read fresh at action
    /// time (not the polled copy a page was drawn with).
    ///
    /// Falls back to this device's own OS version when lockdown does not
    /// answer: WorkSlop runs on the device it pairs with (self-pairing),
    /// so the host OS is the device OS. Empty only when both fail, and an
    /// empty version blocks the AirCard pages (fail closed, page-local).
    static func resolve() async -> String {
        let version = await DeviceIdentity.read().version
        if !version.isEmpty { return version }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}

extension PhotosPickerItem {
    /// Loads a photo-picker image, handling HEIC, Live Photos, ProRAW, and
    /// iCloud downloads. Ported from AirCard's `PhotosPickerItem` loader:
    /// transferable data first, raw data second, file representation last.
    func loadAirCardImage(maxDimension: CGFloat = 2048) async -> UIImage? {
        struct ImageTransferable: Transferable {
            let data: Data
            static var transferRepresentation: some TransferRepresentation {
                DataRepresentation(importedContentType: .image) { data in
                    ImageTransferable(data: data)
                }
            }
        }
        if let result = try? await loadTransferable(type: ImageTransferable.self),
           let img = WalletCardSkin.safeImageFromData(result.data, maxDimension: maxDimension) {
            return img
        }
        if let data = try? await loadTransferable(type: Data.self),
           let img = WalletCardSkin.safeImageFromData(data, maxDimension: maxDimension) {
            return img
        }
        struct FileImageTransferable: Transferable {
            let url: URL
            static var transferRepresentation: some TransferRepresentation {
                FileRepresentation(importedContentType: .image) { received in
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "_" + received.file.lastPathComponent)
                    try? FileManager.default.copyItem(at: received.file, to: tmp)
                    return FileImageTransferable(url: tmp)
                }
            }
        }
        if let fileResult = try? await loadTransferable(type: FileImageTransferable.self) {
            defer { try? FileManager.default.removeItem(at: fileResult.url) }
            if let data = try? Data(contentsOf: fileResult.url),
               let img = WalletCardSkin.safeImageFromData(data, maxDimension: maxDimension) {
                return img
            }
        }
        return nil
    }
}
