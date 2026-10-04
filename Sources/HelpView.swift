import SwiftUI

/// The key bindings sheet. Keep it in step with the menus (App.swift),
/// the Vim engine (VimEngine.swift) and the console (ConsoleView.swift).
struct HelpView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            Text("Key bindings")
                .font(.title2.bold())
                .padding(16)
            Divider()
            ScrollView { HelpContent().padding(20) }
            Divider()
            HStack {
                Spacer()
                Button("Close") { model.showHelp = false }
                    .keyboardShortcut(.cancelAction)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 600)
    }
}

struct HelpContent: View {
    private struct Section: Identifiable {
        let title: String
        let rows: [(keys: String, action: String)]
        var id: String { title }
    }

    private static let sections: [Section] = [
        Section(title: "Files", rows: [
            ("⌘N", "New file"),
            ("⌘O", "Open a file, or a folder as the project"),
            ("⌘S", "Save, and refresh the autocomplete index"),
        ]),
        Section(title: "Build and run", rows: [
            ("⌘B", "Compile"),
            ("⌘R", "Compile and run"),
            ("⌘.", "Stop the running program or debugger"),
            ("⌘J", "Show or hide the terminal"),
        ]),
        Section(title: "Debug", rows: [
            ("⌘D", "Compile and debug"),
            ("⌘\\", "Toggle a breakpoint on the cursor line"),
            ("Click a line number", "Toggle a breakpoint"),
            ("⌃⌘Y", "Continue"),
            ("F6  F7  F8", "Step over, into, out"),
        ]),
        Section(title: "Editor", rows: [
            ("Tab", "Indent to the next 4-space stop, or indent the selected lines"),
            ("⇧Tab", "Remove one level from the selected lines"),
            ("Return", "New line, keeping the indentation, one level deeper after { ( ["),
            ("}", "On a blank line, lines up with its {"),
            ("Delete", "In the leading spaces, back one level"),
            ("Typing a word", "Autocomplete list from 2 letters: ↑ ↓ pick, Return or Tab insert, Esc close"),
            ("⌃M", "Turn Vim mode on or off"),
            ("?", "This help, see below"),
        ]),
        Section(title: "Terminal", rows: [
            ("Typing", "Answer the running program (cin)"),
            ("Return", "Send the line"),
            ("⌃D", "End of input, on an empty line"),
            ("⌃C", "Stop the program"),
            ("⌘V", "Paste into the program"),
        ]),
        Section(title: "Vim: modes", rows: [
            ("Esc  ⌃[", "Back to normal mode"),
            ("i  a  I  A", "Insert before, after, at line start, at line end"),
            ("o  O", "Open a line below, above"),
            ("v  V", "Select characters, select lines"),
        ]),
        Section(title: "Vim: moving", rows: [
            ("h  j  k  l", "Left, down, up, right"),
            ("w  b  e", "Next word, previous word, end of word"),
            ("0  ^  $", "Line start, first character, line end"),
            ("gg  G", "First line, last line (3G: line 3)"),
            ("3w  5j …", "A number repeats a motion"),
        ]),
        Section(title: "Vim: editing", rows: [
            ("d  c  y", "Delete, change, copy: then a motion, or iw for the word"),
            ("dd  cc  yy", "The same on whole lines"),
            ("x  D  C", "Delete character, delete or change to line end"),
            ("r  J", "Replace a character, join lines"),
            ("p  P", "Paste after, before"),
            ("u  ⌃R", "Undo, redo"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Self.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.headline)
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 4) {
                        ForEach(section.rows, id: \.keys) { row in
                            GridRow {
                                Text(row.keys)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 150, alignment: .leading)
                                Text(row.action)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            Text("""
                ? opens this help from Vim normal mode, from the terminal when no program is \
                running, and as ⌘? from anywhere. Elsewhere it types a question mark.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
