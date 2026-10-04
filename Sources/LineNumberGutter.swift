import AppKit

/// Line numbers beside the editor. Clicking a number toggles a breakpoint.
final class LineNumberGutter: NSRulerView {
    var breakpoints: Set<Int> = [] { didSet { needsDisplay = true } }
    var currentLine: Int? { didSet { needsDisplay = true } }
    var onToggle: (Int) -> Void = { _ in }

    private weak var textView: NSTextView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        // Without this a ruler paints over the text view on macOS 14+.
        clipsToBounds = true

        // Numbers move with scrolling and with re-wrapping on resize.
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        center.addObserver(
            self, selector: #selector(refresh), name: NSView.frameDidChangeNotification, object: textView)
        center.addObserver(
            self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    @objc private func refresh() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer
        else { return }
        let text = textView.string as NSString
        let visible = layout.characterRange(
            forGlyphRange: layout.glyphRange(forBoundingRect: textView.visibleRect, in: container),
            actualGlyphRange: nil)

        var line = Self.lineNumber(at: visible.location, in: text)
        var index = visible.location
        while index < text.length && index <= NSMaxRange(visible) {
            let glyph = layout.glyphIndexForCharacter(at: index)
            drawLabel(line, beside: layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            line += 1
        }
        // The empty last line (after a trailing line break, or in an empty file).
        if index >= text.length, !layout.extraLineFragmentRect.isEmpty {
            drawLabel(line, beside: layout.extraLineFragmentRect)
        }
    }

    /// Draws one line number, level with a line fragment of the text view.
    private func drawLabel(_ line: Int, beside fragment: NSRect) {
        guard let textView else { return }
        let top = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerInset.height), from: textView).y
        let row = NSRect(x: 0, y: top, width: bounds.width - 1, height: fragment.height)

        if line == currentLine {
            NSColor.systemYellow.withAlphaComponent(0.4).setFill()
            row.fill()
        }
        var color = NSColor.secondaryLabelColor
        if breakpoints.contains(line) {
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: row.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
            color = .white
        }
        let label = NSAttributedString(string: "\(line)", attributes: [.font: font, .foregroundColor: color])
        let size = label.size()
        label.draw(at: NSPoint(x: row.maxX - size.width - 7, y: row.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer
        else { return }
        let text = textView.string as NSString
        let y = textView.convert(event.locationInWindow, from: nil).y - textView.textContainerInset.height
        // The rects below are only valid for text that has been laid out.
        layout.ensureLayout(for: container)

        let extra = layout.extraLineFragmentRect
        // Clicks below the last line do not count.
        if !extra.isEmpty, y >= extra.minY {
            if y < extra.maxY { onToggle(Self.lineNumber(at: text.length, in: text)) }
            return
        }
        guard text.length > 0, y <= layout.usedRect(for: container).maxY else { return }
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        onToggle(Self.lineNumber(at: layout.characterIndexForGlyph(at: glyph), in: text))
    }

    /// 1-based number of the line holding the character at `index`.
    static func lineNumber(at index: Int, in text: NSString) -> Int {
        var line = 1
        var location = 0
        while location < index {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            if next > index || next == location { break }
            line += 1
            location = next
        }
        return line
    }
}
