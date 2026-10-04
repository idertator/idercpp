import AppKit
import SwiftUI

/// The console: program output, and a terminal-like input line typed straight
/// into it while a program runs. Return sends the line to the program's stdin.
struct ConsoleView: NSViewRepresentable {
    var output: String
    /// The line being typed, not yet sent.
    var input: String
    var isRunning: Bool
    var onText: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onEOF: () -> Void = {}
    var onInterrupt: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ConsoleTextView.scrollableTextView()
        let tv = scroll.documentView as! ConsoleTextView
        tv.isEditable = false
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        update(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        update(scroll.documentView as! ConsoleTextView)
    }

    private func update(_ tv: ConsoleTextView) {
        tv.onText = onText
        tv.onDelete = onDelete
        tv.onEOF = onEOF
        tv.onInterrupt = onInterrupt

        let started = isRunning && !tv.isRunning
        tv.isRunning = isRunning
        if started {
            // A program was started: keystrokes should reach it without a click.
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }

        // SwiftUI calls this on every model change; only redraw for our own.
        let shown = output + "\u{0}" + input + (isRunning ? "1" : "0")
        guard tv.shown != shown else { return }
        tv.shown = shown

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = NSMutableAttributedString(
            string: output + input, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        if isRunning {
            text.append(NSAttributedString(
                string: "█", attributes: [.font: font, .foregroundColor: NSColor.controlAccentColor]))
        }
        tv.textStorage?.setAttributedString(text)
        tv.scrollToEndOfDocument(nil)
    }
}

final class ConsoleTextView: NSTextView {
    var isRunning = false
    var shown = ""
    var onText: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onEOF: () -> Void = {}
    var onInterrupt: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        guard isRunning, !flags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        if flags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "c": onInterrupt()
            case "d": onEOF()
            default: break
            }
            return
        }
        guard let characters = event.characters, let first = characters.unicodeScalars.first else { return }
        switch first.value {
        case 0x7F, 0x08:
            onDelete()
        case 0x0D, 0x03:
            onText("\n")
        case 0xF700...0xF8FF, 0x1B:
            break  // arrows, function keys, Esc: nothing to send
        default:
            onText(characters)
        }
    }

    override func paste(_ sender: Any?) {
        guard isRunning, let text = NSPasteboard.general.string(forType: .string) else { return }
        onText(text)
    }
}
