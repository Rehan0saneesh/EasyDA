import SwiftUI
import UIKit

/// A plain-text Verilog editor with syntax colouring and an error-line highlight.
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var errorLine: Int?
    /// The line of the signal picked in another tool.
    var focusLine: Int? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.keyboardAppearance = .dark
        view.alwaysBounceVertical = true
        view.tintColor = UIColor(Theme.accent)
        view.typingAttributes = Highlighter.base
        view.inputAccessoryView = context.coordinator.makeKeyBar(for: view)
        view.text = text
        Highlighter.apply(to: view, errorLine: errorLine, focusLine: focusLine)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
        }
        Highlighter.apply(to: view, errorLine: errorLine, focusLine: focusLine)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Tab inserts two spaces, and Return keeps the current indentation.
            if text == "\t" {
                textView.insertText("  ")
                return false
            }
            if text == "\n" {
                let ns = textView.text as NSString
                let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
                let line = ns.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
                let indent = line.prefix { $0 == " " }
                textView.insertText("\n" + indent)
                return false
            }
            return true
        }

        /// A row of the symbols Verilog leans on, which are buried on the iPad keyboard.
        func makeKeyBar(for textView: UITextView) -> UIView {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.barStyle = .black
            bar.tintColor = UIColor(Theme.accent)
            var items: [UIBarButtonItem] = []
            for symbol in ["~", "&", "|", "^", "?", ":", "=", ";", "(", ")"] {
                let item = UIBarButtonItem(title: symbol, primaryAction: UIAction { [weak textView] _ in
                    textView?.insertText(symbol)
                })
                item.setTitleTextAttributes([.font: UIFont.monospacedSystemFont(ofSize: 19, weight: .medium)], for: .normal)
                items.append(item)
                items.append(UIBarButtonItem(systemItem: .flexibleSpace))
            }
            items.append(UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak textView] _ in
                textView?.resignFirstResponder()
            }))
            bar.items = items
            bar.sizeToFit()
            return bar
        }
    }
}

enum Highlighter {
    static let font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    static let keywordFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .semibold)

    static let base: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        return [.font: font, .foregroundColor: UIColor(white: 1, alpha: 0.72), .paragraphStyle: paragraph]
    }()

    private static let rules: [(NSRegularExpression, UIColor)] = [
        (#"\b(module|endmodule|input|output|wire|assign)\b"#, UIColor.white),
        (#"\b(and|or|not|xor|nand|nor|xnor|buf)\b(?=\s*[\w]*\s*\()"#, UIColor.white),
        (#"\b\d+'[bdhoBDHO][0-9a-fA-F]+\b|\b\d+\b"#, UIColor(white: 1, alpha: 0.7)),
        (#"[~&|^?:=!]"#, UIColor(white: 1, alpha: 0.55)),
        (#"//[^\n]*|/\*[\s\S]*?\*/"#, UIColor(white: 1, alpha: 0.36)),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func apply(to view: UITextView, errorLine: Int?, focusLine: Int? = nil) {
        guard view.markedTextRange == nil else { return }   // don't fight an in-progress composition
        let storage = view.textStorage
        let ns = storage.string as NSString
        let all = NSRange(location: 0, length: ns.length)

        storage.beginEditing()
        storage.setAttributes(base, range: all)
        for (regex, color) in rules {
            regex.enumerateMatches(in: storage.string, range: all) { match, _, _ in
                guard let range = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: color, range: range)
                if color == UIColor.white { storage.addAttribute(.font, value: keywordFont, range: range) }
            }
        }
        func tint(line target: Int?, _ color: UIColor) {
            guard let target, target >= 1 else { return }
            var line = 1
            var location = 0
            while line < target, location < ns.length {
                location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
                line += 1
            }
            guard line == target, location <= ns.length else { return }
            let range = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
            storage.addAttribute(.backgroundColor, value: color, range: range)
        }
        tint(line: focusLine, UIColor(white: 1, alpha: 0.14))
        tint(line: errorLine, UIColor(Theme.bad).withAlphaComponent(0.16))
        storage.endEditing()
        view.typingAttributes = base
    }
}
