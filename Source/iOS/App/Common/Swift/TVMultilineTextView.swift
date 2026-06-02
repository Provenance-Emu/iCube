import SwiftUI
import UIKit

#if os(tvOS)
struct TVMultilineTextView: UIViewRepresentable {
  @Binding var text: String

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.isScrollEnabled = true
    view.alwaysBounceVertical = true
    view.font = UIFont.preferredFont(forTextStyle: .body)
    view.textColor = .white
    view.backgroundColor = .clear
    view.text = text
    view.delegate = context.coordinator
    return view
  }

  func updateUIView(_ uiView: UITextView, context: Context) {
    if uiView.text != text {
      uiView.text = text
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: TVMultilineTextView
    init(_ parent: TVMultilineTextView) { self.parent = parent }
    func textViewDidChange(_ textView: UITextView) { parent.text = textView.text ?? "" }
  }
}
#endif
