import AppKit

/// The editor's text view: gives the Vim engine first go at every key.
final class EditorTextView: NSTextView {
    let vim = VimEngine()
    var onToggleVim: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        // ⌃M normally arrives through the menu; this covers the case where it does not.
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "m" {
            onToggleVim()
            return
        }
        if vim.handle(event) { return }
        super.keyDown(with: event)
    }
}

/// Vim-like modal editing: a deliberately small subset of Vim.
///
///     modes      normal, insert, visual (v), visual line (V)
///     motions    h j k l  w b e  0 ^ $  gg G  (with counts)
///     operators  d c y + motion or iw, doubled for lines (dd cc yy), in visual mode
///     edits      x D C r J p P u ⌃R
///     insert     i a I A o O, Esc to leave
final class VimEngine {
    enum Mode: String {
        case normal = "NORMAL"
        case insert = "INSERT"
        case visual = "VISUAL"
        case visualLine = "V-LINE"
    }

    weak var textView: NSTextView?
    var onModeChange: (Mode) -> Void = { _ in }
    private(set) var mode = Mode.normal

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            resetPending()
            mode = .normal
            if isEnabled { move(to: clamp(cursor)) } else { updateCursor() }
        }
    }

    /// True when typed characters go into the text.
    var isInserting: Bool { !isEnabled || mode == .insert }

    private var count = 0
    private var pendingOperator: Character?  // d, c or y, waiting for its motion
    private var pendingPrefix: Character?  // g, r, or i (text object)
    // Visual mode: the selection runs from anchor to head, both included.
    private var anchor = 0
    private var head = 0
    /// Column that j and k aim for, kept while moving through shorter lines.
    private var stickyColumn: Int?
    private var register = ""
    private var registerIsLinewise = false

    private static let escape: Character = "\u{1B}"

    private struct Motion {
        var target: Int
        var linewise = false
        var inclusive = false
    }

    // MARK: - Keys

    /// Returns true if the key was consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        let flags = event.modifierFlags
        if flags.contains(.command) { return false }
        let control = flags.contains(.control)
        guard let key = (control ? event.charactersIgnoringModifiers : event.characters)?.first else {
            // A dead key: nothing to type outside insert mode.
            return mode != .insert
        }
        // Arrows and other function keys keep their native behaviour.
        if let scalar = key.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) { return false }
        if control, key == "[" { return press(Self.escape) }
        return press(key, control: control)
    }

    /// Feeds one key to the engine. Returns true if it was consumed.
    func press(_ key: Character, control: Bool = false) -> Bool {
        guard isEnabled, let textView else { return false }

        if mode == .insert {
            guard key == Self.escape, !control else { return false }
            setMode(.normal)
            move(to: max(lineStart(cursor), cursor - 1))
            return true
        }

        // A selection made with the mouse becomes a visual selection.
        let selection = textView.selectedRange()
        if mode == .normal, selection.length > 0 {
            anchor = selection.location
            head = NSMaxRange(selection) - 1
            setMode(.visual)
        }

        if control {
            if key == "r" {
                textView.undoManager?.redo()
                move(to: clamp(cursor))
            }
            resetPending()
            return true
        }
        if key == Self.escape {
            resetPending()
            if isVisual {
                setMode(.normal)
                move(to: clamp(head))
            }
            return true
        }
        if pendingPrefix == "r" {
            if cursor < lineEnd(cursor) { replace(NSRange(location: cursor, length: 1), with: String(key), cursor: cursor) }
            resetPending()
            return true
        }
        let position = isVisual ? head : cursor
        if key.isASCII, key.isNumber, key != "0" || count > 0 {
            count = count * 10 + key.wholeNumberValue!
            return true
        }

        let column = stickyColumn
        stickyColumn = nil
        if key == "j" || key == "k" || key == "\r" { stickyColumn = column ?? position - lineStart(position) }
        if !command(key) { resetPending() }
        return true
    }

    /// Runs one command key. Returns true while the command is still incomplete.
    private func command(_ key: Character) -> Bool {
        let times = max(count, 1)
        let position = isVisual ? head : cursor

        if pendingPrefix == "i" {
            if key == "w", let op = pendingOperator { operate(op, on: wordRange(at: cursor), linewise: false) }
            return false
        }
        if pendingPrefix == "g" {
            if key == "g" { apply(Motion(target: lineTarget(count > 0 ? count : 1), linewise: true)) }
            return false
        }
        if key == "g" {
            pendingPrefix = "g"
            return true
        }
        if key == "i", pendingOperator != nil {
            pendingPrefix = "i"
            return true
        }
        if let motion = motion(key, from: position, times: times) {
            apply(motion)
            return false
        }
        return isVisual ? visualCommand(key) : normalCommand(key, times: times)
    }

    private func normalCommand(_ key: Character, times: Int) -> Bool {
        guard let textView else { return false }
        let position = cursor
        switch key {
        case "i":
            setMode(.insert)
        case "a":
            move(to: min(position + 1, lineEnd(position)))
            setMode(.insert)
        case "I":
            move(to: firstNonBlank(position))
            setMode(.insert)
        case "A":
            move(to: lineEnd(position))
            setMode(.insert)
        case "o":
            let end = lineEnd(position)
            let indent = indentation(at: position)
            replace(NSRange(location: end, length: 0), with: "\n" + indent, cursor: end + 1 + indent.utf16.count)
            setMode(.insert)
        case "O":
            let start = lineStart(position)
            let indent = indentation(at: position)
            replace(NSRange(location: start, length: 0), with: indent + "\n", cursor: start + indent.utf16.count)
            setMode(.insert)
        case "x":
            let length = min(times, lineEnd(position) - position)
            if length > 0 { operate("d", on: NSRange(location: position, length: length), linewise: false) }
        case "D", "C":
            let end = lineEnd(position)
            operate(key == "D" ? "d" : "c", on: NSRange(location: position, length: end - position), linewise: false)
        case "d", "c", "y":
            if pendingOperator == key {
                // dd, cc, yy: whole lines.
                apply(Motion(target: vertical(position, times - 1), linewise: true))
                return false
            }
            guard pendingOperator == nil else { return false }
            pendingOperator = key
            return true
        case "p", "P":
            paste(after: key == "p")
        case "u":
            textView.undoManager?.undo()
            move(to: clamp(cursor))
        case "J":
            let end = lineEnd(position)
            guard end < text.length else { break }
            var next = end + 1
            while next < text.length, isBlank(next) { next += 1 }
            replace(NSRange(location: end, length: next - end), with: " ", cursor: end)
        case "r":
            pendingPrefix = "r"
            return true
        case "v", "V":
            anchor = position
            head = position
            setMode(key == "v" ? .visual : .visualLine)
            showVisualSelection()
        default:
            break
        }
        return false
    }

    private func visualCommand(_ key: Character) -> Bool {
        switch key {
        case "d", "x", "c", "y":
            operate(key == "x" ? "d" : key, on: visualRange, linewise: mode == .visualLine)
        case "v", "V":
            let target = key == "v" ? Mode.visual : Mode.visualLine
            if mode == target {
                setMode(.normal)
                move(to: clamp(head))
            } else {
                setMode(target)
                showVisualSelection()
            }
        default:
            break
        }
        return false
    }

    private func resetPending() {
        count = 0
        pendingOperator = nil
        pendingPrefix = nil
    }

    // MARK: - Motions

    private func motion(_ key: Character, from position: Int, times: Int) -> Motion? {
        switch key {
        case "h", "\u{7F}":
            return Motion(target: max(lineStart(position), position - times))
        case "l", " ":
            return Motion(target: min(lineEnd(position), position + times))
        case "j", "\r":
            return Motion(target: vertical(position, times), linewise: true)
        case "k":
            return Motion(target: vertical(position, -times), linewise: true)
        case "w":
            // cw changes to the end of the word, like ce.
            if pendingOperator == "c", position < text.length, wordClass(position) != 0 {
                return self.motion("e", from: position, times: times)
            }
            var target = position
            for _ in 0..<times { target = nextWord(target) }
            // An operator with w stays on its line: dw on the last word keeps the line break.
            if pendingOperator != nil { target = min(target, lineEnd(position)) }
            return Motion(target: target)
        case "b":
            var target = position
            for _ in 0..<times { target = previousWord(target) }
            return Motion(target: target)
        case "e":
            var target = position
            for _ in 0..<times { target = wordEnd(target) }
            return Motion(target: target, inclusive: true)
        case "0":
            return Motion(target: lineStart(position))
        case "^":
            return Motion(target: firstNonBlank(position))
        case "$":
            return Motion(target: max(lineStart(position), lineEnd(position) - 1), inclusive: true)
        case "G":
            return Motion(target: lineTarget(count > 0 ? count : nil), linewise: true)
        default:
            return nil
        }
    }

    /// Moves the cursor, extends the visual selection, or completes a pending operator.
    private func apply(_ motion: Motion) {
        if let op = pendingOperator {
            let low = min(cursor, motion.target)
            var high = max(cursor, motion.target)
            if motion.linewise {
                operate(op, on: lines(from: low, to: high), linewise: true)
            } else {
                if motion.inclusive { high = min(high + 1, lineEnd(high)) }
                operate(op, on: NSRange(location: low, length: high - low), linewise: false)
            }
        } else if isVisual {
            head = min(motion.target, max(text.length - 1, 0))
            showVisualSelection()
        } else {
            move(to: clamp(motion.target))
        }
    }

    /// Position `delta` lines down (or up), keeping the column where the line is long enough.
    private func vertical(_ position: Int, _ delta: Int) -> Int {
        let column = stickyColumn ?? position - lineStart(position)
        var start = lineStart(position)
        for _ in 0..<abs(delta) {
            if delta > 0 {
                let line = text.lineRange(for: NSRange(location: start, length: 0))
                // The last line: nothing after it, not even an empty line.
                if NSMaxRange(line) == text.length, lineEnd(start) == text.length { break }
                start = NSMaxRange(line)
            } else {
                if start == 0 { break }
                start = lineStart(start - 1)
            }
        }
        return min(start + column, lineEnd(start))
    }

    /// First non-blank of a 1-based line; of the last line when `line` is nil or too large.
    private func lineTarget(_ line: Int?) -> Int {
        if let line, let range = CodeEditor.Coordinator.lineRange(line, in: text) {
            return firstNonBlank(range.location)
        }
        var end = text.length
        if end > 0, text.character(at: end - 1) == 10 { end -= 1 }  // skip the final line break
        return firstNonBlank(end)
    }

    /// 0 for blanks and line breaks, 1 for identifier characters, 2 for punctuation.
    private func wordClass(_ index: Int) -> Int {
        guard let scalar = UnicodeScalar(text.character(at: index)) else { return 1 }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return 0 }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar) ? 1 : 2
    }

    private func nextWord(_ position: Int) -> Int {
        var index = position
        guard index < text.length else { return index }
        let start = wordClass(index)
        if start != 0 { while index < text.length, wordClass(index) == start { index += 1 } }
        while index < text.length, wordClass(index) == 0 { index += 1 }
        return index
    }

    private func previousWord(_ position: Int) -> Int {
        var index = position
        while index > 0, wordClass(index - 1) == 0 { index -= 1 }
        guard index > 0 else { return 0 }
        let start = wordClass(index - 1)
        while index > 0, wordClass(index - 1) == start { index -= 1 }
        return index
    }

    private func wordEnd(_ position: Int) -> Int {
        var index = position + 1
        while index < text.length, wordClass(index) == 0 { index += 1 }
        guard index < text.length else { return max(text.length - 1, 0) }
        let start = wordClass(index)
        while index + 1 < text.length, wordClass(index + 1) == start { index += 1 }
        return index
    }

    /// The run of same-class characters under the cursor: the `iw` text object.
    private func wordRange(at position: Int) -> NSRange {
        guard position < lineEnd(position) else { return NSRange(location: position, length: 0) }
        let kind = wordClass(position)
        var low = position
        var high = position
        while low > lineStart(position), wordClass(low - 1) == kind { low -= 1 }
        while high < lineEnd(position), wordClass(high) == kind { high += 1 }
        return NSRange(location: low, length: high - low)
    }

    // MARK: - Operators

    private func operate(_ op: Character, on range: NSRange, linewise: Bool) {
        var yanked = text.substring(with: range)
        if linewise, !yanked.hasSuffix("\n") { yanked += "\n" }
        register = yanked
        registerIsLinewise = linewise

        switch op {
        case "y":
            setMode(.normal)
            move(to: clamp(range.location))
        case "d":
            setMode(.normal)
            var doomed = range
            // Deleting the last line also takes the line break before it.
            if linewise, !text.substring(with: range).hasSuffix("\n"), doomed.location > 0 {
                doomed.location -= 1
                doomed.length += 1
            }
            replace(doomed, with: "", cursor: doomed.location)
            move(to: linewise ? firstNonBlank(cursor) : clamp(cursor))
        case "c":
            var doomed = range
            var kept = ""
            if linewise {
                // Keep the line itself and its indentation.
                if text.substring(with: doomed).hasSuffix("\n") { doomed.length -= 1 }
                kept = indentation(at: doomed.location)
            }
            replace(doomed, with: kept, cursor: doomed.location + kept.utf16.count)
            setMode(.insert)
        default:
            break
        }
    }

    private func paste(after: Bool) {
        guard !register.isEmpty else { return }
        let position = cursor
        if registerIsLinewise {
            var pasted = register
            var location = lineStart(position)
            var landing = location
            if after {
                location = NSMaxRange(text.lineRange(for: NSRange(location: position, length: 0)))
                landing = location
                if lineEnd(position) == text.length {
                    // After a last line that has no line break of its own.
                    pasted = "\n" + pasted.dropLast()
                    landing += 1
                }
            }
            replace(NSRange(location: location, length: 0), with: pasted, cursor: landing)
            move(to: firstNonBlank(landing))
        } else {
            let location = after ? min(position + 1, lineEnd(position)) : position
            replace(
                NSRange(location: location, length: 0), with: register,
                cursor: location + register.utf16.count - 1)
        }
    }

    // MARK: - Text view access

    private var text: NSString { (textView?.string ?? "") as NSString }
    private var cursor: Int { textView?.selectedRange().location ?? 0 }
    private var isVisual: Bool { mode == .visual || mode == .visualLine }

    private var visualRange: NSRange {
        let low = min(anchor, head)
        let high = max(anchor, head)
        if mode == .visualLine { return lines(from: low, to: high) }
        return NSRange(location: low, length: min(high + 1, text.length) - low)
    }

    private func lineStart(_ position: Int) -> Int {
        text.lineRange(for: NSRange(location: min(position, text.length), length: 0)).location
    }

    /// End of the line's content, before its line break.
    private func lineEnd(_ position: Int) -> Int {
        var end = 0
        text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: min(position, text.length), length: 0))
        return end
    }

    private func lines(from low: Int, to high: Int) -> NSRange {
        let first = lineStart(low)
        let last = text.lineRange(for: NSRange(location: min(high, text.length), length: 0))
        return NSRange(location: first, length: NSMaxRange(last) - first)
    }

    private func isBlank(_ index: Int) -> Bool {
        let character = text.character(at: index)
        return character == 32 || character == 9
    }

    private func firstNonBlank(_ position: Int) -> Int {
        var index = lineStart(position)
        let end = lineEnd(position)
        while index < end, isBlank(index) { index += 1 }
        return index
    }

    private func indentation(at position: Int) -> String {
        let start = lineStart(position)
        return text.substring(with: NSRange(location: start, length: firstNonBlank(position) - start))
    }

    /// In normal mode the cursor sits on a character, never past the end of a line.
    private func clamp(_ position: Int) -> Int {
        let position = min(position, text.length)
        let start = lineStart(position)
        let end = lineEnd(position)
        return position >= end && end > start ? end - 1 : position
    }

    /// Edits through the text view, so undo, highlighting and the model all follow.
    private func replace(_ range: NSRange, with string: String, cursor: Int) {
        guard let textView, textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        move(to: min(cursor, text.length))
    }

    private func move(to position: Int) {
        guard let textView else { return }
        let range = NSRange(location: max(0, min(position, text.length)), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        updateCursor()
    }

    private func showVisualSelection() {
        guard let textView else { return }
        textView.setSelectedRange(visualRange)
        textView.scrollRangeToVisible(NSRange(location: min(head, text.length), length: 0))
    }

    private func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        onModeChange(newMode)
        updateCursor()
    }

    /// Normal mode shows a block cursor: a tint on the character under it.
    func updateCursor() {
        guard let textView, let layout = textView.layoutManager else { return }
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
        let selection = textView.selectedRange()
        guard isEnabled, mode == .normal, selection.length == 0, selection.location < lineEnd(selection.location)
        else { return }
        layout.addTemporaryAttribute(
            .backgroundColor, value: NSColor.textColor.withAlphaComponent(0.35),
            forCharacterRange: NSRange(location: selection.location, length: 1))
    }
}
