#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// Simple SwiftUI wrapper for UIDocumentPickerViewController
struct DocumentPickerView: UIViewControllerRepresentable {
    /// The allowed content types for the picker
    let contentTypes: [UTType]
    /// Called when a single URL is picked
    let onPick: (URL) -> Void

    static var softwareContentTypes: [UTType] {
        [
            UTType("me.oatmealdome.dolphinios.generic-software")!,
            UTType("me.oatmealdome.dolphinios.gamecube-software")!,
            UTType("me.oatmealdome.dolphinios.wii-software")!,
            UTType(importedAs: "public.iso-image") ?? UTType(filenameExtension: "iso") ?? .data, // ISO images
            UTType("me.oatmealdome.dolphinios.rvz-image")!,
            UTType("me.oatmealdome.dolphinios.dol-executable")!,
            UTType("me.oatmealdome.dolphinios.elf-executable")!,
            UTType.archive,
            UTType.data
        ].compactMap { $0 }
    }

    static var binType: UTType { UTType(filenameExtension: "bin") ?? .data }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            controller = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        } else {
            controller = UIDocumentPickerViewController(documentTypes: contentTypes.map { $0.identifier }, in: .import)
        }
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        controller.modalPresentationStyle = .pageSheet
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
#endif
