import Foundation

/// Indentation rules of the editor: four spaces a level, never a tab character.
///
///     Return     keeps the indentation, one level deeper after { ( [ and case/default labels
///     }          on a blank line, lines up with the line of its {
///     Tab        spaces up to the next stop; indents the lines of a multi-line selection
///     ⇧Tab       removes one level from the selected lines
///     Delete     in the leading spaces, goes back one stop
///
/// Everything here is pure: it looks at the text and answers with the edit to make.
enum SmartIndent {
    static let width = 4
    static let unit = String(repeating: " ", count: width)

    struct Edit {
        var range: NSRange
        var string: String
        /// Where the selection goes once the edit is made.
        var selection: NSRange
    }

    private static let closers: [Character: unichar] = ["{": 125, "(": 41, "[": 93]

    // MARK: - Edits

    static func newline(in text: NSString, selection: NSRange) -> Edit {
        let indent = indentation(in: text, after: selection.location)
        let inserted = "\n" + indent
        // Between a pair of brackets the closing one gets a line of its own.
        var tail = ""
        let end = NSMaxRange(selection)
        if let closer = code(in: text, before: selection.location).last.flatMap({ closers[$0] }),
            end < text.length, text.character(at: end) == closer
        {
            tail = "\n" + blanks(in: text, from: lineStart(text, selection.location), to: selection.location)
        }
        return Edit(
            range: selection, string: inserted + tail,
            selection: NSRange(location: selection.location + inserted.utf16.count, length: 0))
    }

    /// Indentation for a line opened after `position`: the blanks leading up to
    /// it, one level deeper if the line opens a block there.
    static func indentation(in text: NSString, after position: Int) -> String {
        let indent = blanks(in: text, from: lineStart(text, position), to: position)
        return opensBlock(code(in: text, before: position)) ? indent + unit : indent
    }

    /// A `}` typed on a blank line takes the indentation of the line of its `{`.
    static func closingBrace(in text: NSString, selection: NSRange) -> Edit? {
        let start = lineStart(text, selection.location)
        guard blanks(in: text, from: start, to: selection.location).utf16.count == selection.location - start,
            let open = matchingBrace(in: text, before: start)
        else { return nil }
        let string = blanks(in: text, from: lineStart(text, open), to: open) + "}"
        return Edit(
            range: NSRange(location: start, length: NSMaxRange(selection) - start), string: string,
            selection: NSRange(location: start + string.utf16.count, length: 0))
    }

    static func tab(in text: NSString, selection: NSRange) -> Edit? {
        if text.substring(with: selection).contains("\n") { return shift(in: text, selection: selection, outdent: false) }
        let column = selection.location - lineStart(text, selection.location)
        let count = width - column % width
        return Edit(
            range: selection, string: String(repeating: " ", count: count),
            selection: NSRange(location: selection.location + count, length: 0))
    }

    /// Adds or removes one level on every line the selection touches.
    static func shift(in text: NSString, selection: NSRange, outdent: Bool) -> Edit? {
        let block = text.lineRange(for: selection)
        var removedFromFirst = 0
        let lines = text.substring(with: block).components(separatedBy: "\n").enumerated().map { index, line -> String in
            guard outdent else { return line.isEmpty || line == "\r" ? line : unit + line }
            let drop = line.hasPrefix("\t") ? 1 : min(width, line.prefix { $0 == " " }.count)
            if index == 0 { removedFromFirst = drop }
            return String(line.dropFirst(drop))
        }
        let string = lines.joined(separator: "\n")
        guard string.utf16.count != block.length else { return nil }
        let after = selection.length == 0
            ? NSRange(location: max(block.location, selection.location - removedFromFirst), length: 0)
            : NSRange(location: block.location, length: string.utf16.count)
        return Edit(range: block, string: string, selection: after)
    }

    /// Deleting in the leading spaces of a line goes back to the previous stop.
    static func backspace(in text: NSString, selection: NSRange) -> Edit? {
        guard selection.length == 0 else { return nil }
        let start = lineStart(text, selection.location)
        let column = selection.location - start
        let lead = text.substring(with: NSRange(location: start, length: column))
        guard column > 0, lead.allSatisfy({ $0 == " " }) else { return nil }
        let count = (column - 1) % width + 1
        // A single space is the ordinary delete.
        guard count > 1 else { return nil }
        let range = NSRange(location: selection.location - count, length: count)
        return Edit(range: range, string: "", selection: NSRange(location: range.location, length: 0))
    }

    // MARK: - Reading the text

    private static func lineStart(_ text: NSString, _ position: Int) -> Int {
        text.lineRange(for: NSRange(location: position, length: 0)).location
    }

    /// The spaces and tabs starting at `start`, no further than `end`.
    private static func blanks(in text: NSString, from start: Int, to end: Int) -> String {
        var index = start
        while index < end, text.character(at: index) == 32 || text.character(at: index) == 9 { index += 1 }
        return text.substring(with: NSRange(location: start, length: index - start))
    }

    /// The line up to `position`, without a trailing `//` comment or blanks.
    private static func code(in text: NSString, before position: Int) -> String {
        let start = lineStart(text, position)
        var result = ""
        var quote: Character?
        var escaped = false
        for character in text.substring(with: NSRange(location: start, length: position - start)) {
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "/", result.last == "/" {
                result.removeLast()
                break
            }
            result.append(character)
        }
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }

    private static func opensBlock(_ code: String) -> Bool {
        guard let last = code.last else { return false }
        if closers[last] != nil { return true }
        guard last == ":", !code.hasSuffix("::") else { return false }
        let label = code.drop { $0 == " " || $0 == "\t" }
        return label.hasPrefix("case ") || label.hasPrefix("default")
    }

    /// The `{` still open before `position`. Braces in strings and comments are
    /// counted too: good enough to line a `}` up.
    private static func matchingBrace(in text: NSString, before position: Int) -> Int? {
        var depth = 0
        var index = position - 1
        while index >= 0 {
            switch text.character(at: index) {
            case 125: depth += 1
            case 123:
                if depth == 0 { return index }
                depth -= 1
            default: break
            }
            index -= 1
        }
        return nil
    }
}
