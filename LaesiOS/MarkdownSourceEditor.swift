import SwiftUI
import UIKit

/// A note's Markdown while editing on iPhone and iPad, in a fixed-width font. A list item's wrapped lines start
/// under its text, not under its marker. Selection is in UTF-16, as UIKit counts.
struct MarkdownSourceEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityLabel = "Note in Markdown"
        view.text = text
        Self.style(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true   // what follows changes the view, not the bindings
        defer { context.coordinator.updating = false }
        if view.text != text, view.markedTextRange == nil {
            view.text = text
            Self.style(view)
        }
        if view.selectedRange != selection, NSMaxRange(selection) <= (view.text as NSString).length {
            view.selectedRange = selection
            view.scrollRangeToVisible(selection)
        }
        if isFocused, !view.isFirstResponder { view.becomeFirstResponder() }
        if !isFocused, view.isFirstResponder { view.resignFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// The font, and per list item an indent as wide as its marker for the lines after its first.
    static func style(_ view: UITextView) {
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular))
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let text = view.text as NSString, all = NSRange(location: 0, length: text.length)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        let storage = view.textStorage
        storage.beginEditing()
        storage.setAttributes(base, range: all)
        text.enumerateSubstrings(in: all, options: .byParagraphs) { line, _, paragraph, _ in
            guard let line else { return }
            let parsed = MarkdownLine(line)
            switch parsed.kind { case .bullet, .number, .task: break; case .text, .heading: return }
            let hanging = NSMutableParagraphStyle()
            hanging.headIndent = CGFloat(line.count - parsed.body.count) * advance
            storage.addAttribute(.paragraphStyle, value: hanging, range: paragraph)
        }
        storage.endEditing()
        view.typingAttributes = base
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownSourceEditor
        var updating = false
        init(parent: MarkdownSourceEditor) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            if view.markedTextRange == nil { MarkdownSourceEditor.style(view) }   // not mid-way through composing a character
            parent.text = view.text
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            if !updating, parent.selection != view.selectedRange { parent.selection = view.selectedRange }
        }

        func textViewDidBeginEditing(_ view: UITextView) { if !updating, !parent.isFocused { parent.isFocused = true } }
        func textViewDidEndEditing(_ view: UITextView) { if !updating, parent.isFocused { parent.isFocused = false } }
    }
}
