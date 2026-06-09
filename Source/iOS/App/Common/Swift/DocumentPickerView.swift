#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI wrapper for `UIDocumentPickerViewController`.
struct DocumentPickerView: UIViewControllerRepresentable {
  /// Allowed content types for the picker.
  let contentTypes: [UTType]
  /// Whether the user may select multiple files at once.
  var allowsMultipleSelection: Bool = false
  /// Called when one or more URLs are picked.
  let onPick: ([URL]) -> Void

  /// UTTypes offered by the software import picker.
  static var softwareContentTypes: [UTType] {
    ImportableFileTypes.documentPickerTypes
  }

  /// UTType for `.bin` NAND imports.
  static var binType: UTType {
    ImportableFileTypes.binPickerType
  }

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let controller: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      controller = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
    } else {
      controller = UIDocumentPickerViewController(documentTypes: contentTypes.map { $0.identifier }, in: .open)
    }
    controller.delegate = context.coordinator
    controller.allowsMultipleSelection = allowsMultipleSelection
    controller.modalPresentationStyle = .pageSheet
    return controller
  }

  func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
    uiViewController.allowsMultipleSelection = allowsMultipleSelection
  }

  func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    let onPick: ([URL]) -> Void
    init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      guard !urls.isEmpty else { return }
      onPick(urls)
    }
  }
}
#endif
