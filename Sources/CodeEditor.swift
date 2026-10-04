import AppKit
import SwiftUI

/// Plain-text NSTextView: SwiftUI's TextEditor applies smart quotes/dashes,
/// which corrupt source code.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var highlight = true
    var breakpoints: Set<Int> = []
    /// Line the debugger is stopped at; the editor scrolls to it.
    var currentLine: Int?
    var onCursorLine: (Int) -> Void = { _ in }
    /// Called with the line number clicked in the gutter.
    var onToggleBreakpoint: (Int) -> Void = { _ in }
    /// Symbols starting with the word being typed.
    var completions: (String) -> [String] = { _ in [] }
    /// Vim-like modal editing, see VimEngine.swift.
    var vim = false
    var onVimMode: (String) -> Void = { _ in }
    var onToggleVim: () -> Void = {}
    var onHelp: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorTextView.scrollableTextView()
        let tv = scroll.documentView as! EditorTextView
        tv.delegate = context.coordinator
        tv.vim.textView = tv
        tv.vim.onModeChange = { [coordinator = context.coordinator] in coordinator.parent.onVimMode($0.rawValue) }
        tv.onToggleVim = { [coordinator = context.coordinator] in coordinator.parent.onToggleVim() }
        tv.vim.onHelp = { [coordinator = context.coordinator] in coordinator.parent.onHelp() }
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.string = text

        let gutter = LineNumberGutter(textView: tv, scrollView: scroll)
        gutter.onToggle = { [coordinator = context.coordinator] in coordinator.parent.onToggleBreakpoint($0) }
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.rehighlight(tv)
        tv.vim.isEnabled = vim
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scroll.documentView as! EditorTextView
        let coordinator = context.coordinator
        if tv.vim.isEnabled != vim { tv.vim.isEnabled = vim }
        let moved = coordinator.currentLine != currentLine
        if tv.string != text {
            tv.string = text
            // Undo steps recorded for the previous text do not fit this one.
            tv.undoManager?.removeAllActions()
            coordinator.rehighlight(tv)
        } else if coordinator.highlighted != highlight || coordinator.breakpoints != breakpoints || moved {
            coordinator.rehighlight(tv)
        }
        if moved, let currentLine, let range = Coordinator.lineRange(currentLine, in: tv.string as NSString) {
            tv.scrollRangeToVisible(range)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var highlighted = true
        var breakpoints: Set<Int> = []
        var currentLine: Int?
        private var typedIdentifier = false

        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            rehighlight(tv)
            if typedIdentifier {
                typedIdentifier = false
                // Vim's normal-mode edits (r, for one) are not typing.
                let typing = (tv as? EditorTextView)?.vim.isInserting ?? true
                if typing, tv.rangeForUserCompletion.length >= 2 {
                    DispatchQueue.main.async { tv.complete(nil) }
                }
            }
        }

        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Only a typed identifier character opens the completion list:
            // not pasting, deleting, or the list inserting its own choice.
            typedIdentifier = replacementString?.count == 1
                && replacementString!.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            return true
        }

        func textView(
            _ tv: NSTextView, completions words: [String], forPartialWordRange range: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            // Nothing preselected, so Return and Tab keep their meaning until
            // an entry is picked with the arrow keys.
            index?.pointee = -1
            return parent.completions((tv.string as NSString).substring(with: range))
        }

        func rehighlight(_ tv: NSTextView) {
            // Leave in-progress input method composition alone.
            guard let storage = tv.textStorage, !tv.hasMarkedText() else { return }
            highlighted = parent.highlight
            breakpoints = parent.breakpoints
            currentLine = parent.currentLine
            if let gutter = tv.enclosingScrollView?.verticalRulerView as? LineNumberGutter {
                gutter.breakpoints = breakpoints
                gutter.currentLine = currentLine
            }
            CppHighlighter.highlight(storage, enabled: highlighted)

            // Debugger marks: breakpoint lines and the line execution is stopped at.
            let text = storage.string as NSString
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
            for line in breakpoints {
                guard let range = Coordinator.lineRange(line, in: text) else { continue }
                storage.addAttribute(
                    .backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.25), range: range)
            }
            if let currentLine, let range = Coordinator.lineRange(currentLine, in: text) {
                storage.addAttribute(
                    .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: range)
            }
            storage.endEditing()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            (tv as? EditorTextView)?.vim.updateCursor()
            let head = (tv.string as NSString).substring(to: tv.selectedRange().location)
            parent.onCursorLine(head.reduce(1) { $1.isNewline ? $0 + 1 : $0 })
        }

        /// Range of a 1-based line, including its line break.
        static func lineRange(_ line: Int, in text: NSString) -> NSRange? {
            var location = 0
            for _ in 1..<max(line, 1) {
                location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
                if location >= text.length { return nil }
            }
            return text.lineRange(for: NSRange(location: location, length: 0))
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            let sel = tv.selectedRange()
            if selector == #selector(NSResponder.insertTab(_:)) {
                tv.insertText("    ", replacementRange: sel)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                // Carry the current line's indentation onto the new line.
                let s = tv.string as NSString
                let lineStart = s.lineRange(for: NSRange(location: sel.location, length: 0)).location
                let head = s.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
                let indent = head.prefix { $0 == " " || $0 == "\t" }
                tv.insertText("\n" + indent, replacementRange: sel)
                return true
            }
            return false
        }
    }
}
