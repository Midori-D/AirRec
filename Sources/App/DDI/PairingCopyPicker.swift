import SwiftUI
import UIKit

/// Ask Files to hand AirRec a local copy of the chosen pairing record.
struct PairingCopyPicker: UIViewControllerRepresentable {
    let onSelection: (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: PairingFileStore.supportedContentTypes,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelection: (URL?) -> Void

        init(onSelection: @escaping (URL?) -> Void) {
            self.onSelection = onSelection
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onSelection(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onSelection(nil)
        }
    }
}
