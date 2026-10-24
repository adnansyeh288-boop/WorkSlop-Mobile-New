import SwiftUI
import UniformTypeIdentifiers

/// A Files save picker for one file, in export mode
/// (`UIDocumentPickerViewController(forExporting:)`).
///
/// SwiftUI's `.fileExporter` is the wrong tool here: it needs the file
/// as an in-memory `FileDocument`, and a backup package zip can be
/// hundreds of megabytes. The URL-based UIKit picker copies the file
/// to the user's chosen location without loading it, and the original
/// stays where it was — nothing is moved out of WorkSlop's storage
/// by exporting.
struct DocumentExportPicker: UIViewControllerRepresentable {
    /// The file to offer. Must be a file URL the picker can read.
    let url: URL
    /// Called with the destination the system copied the file to.
    var onExported: (URL) -> Void
    /// Called when the user dismisses the picker without saving.
    var onCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onExported: onExported, onCancelled: onCancelled)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onExported: (URL) -> Void
        let onCancelled: () -> Void

        init(onExported: @escaping (URL) -> Void, onCancelled: @escaping () -> Void) {
            self.onExported = onExported
            self.onCancelled = onCancelled
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let destination = urls.first {
                onExported(destination)
            } else {
                onCancelled()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancelled()
        }
    }
}
