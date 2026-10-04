import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 400)
        } detail: {
            VSplitView {
                CodeEditor(
                    text: $model.text, highlight: model.isCpp,
                    breakpoints: model.breakpointLines, currentLine: model.stoppedLine,
                    onCursorLine: { model.cursorLine = $0 },
                    onToggleBreakpoint: { model.toggleBreakpoint(at: $0) },
                    completions: { model.completions(for: $0) },
                    vim: model.vimEnabled,
                    onVimMode: { model.vimMode = $0 },
                    onToggleVim: { model.vimEnabled.toggle() }
                )
                .frame(minHeight: 200)
                console
                    .frame(minHeight: 120)
            }
            .inspector(isPresented: $model.showDebugger) {
                DebugSidebar()
                    .inspectorColumnWidth(min: 220, ideal: 280, max: 500)
            }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.vimEnabled ? model.vimMode : "")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.open() } label: { Label("Open", systemImage: "folder") }
                    .help("Open (⌘O)")
                Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .help("Save (⌘S)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.build(andRun: false) } label: { Label("Compile", systemImage: "hammer") }
                    .help("Compile (⌘B)")
                    .disabled(model.isRunning)
                Button { model.build(andRun: true) } label: { Label("Run", systemImage: "play.fill") }
                    .help("Compile and run (⌘R)")
                    .disabled(model.isRunning)
                Button { model.debug() } label: { Label("Debug", systemImage: "ladybug.fill") }
                    .help("Compile and debug (⌘D)")
                    .disabled(model.isRunning)
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Stop (⌘.)")
                    .disabled(!model.isRunning)
                Button { model.showDebugger.toggle() } label: { Label("Debugger", systemImage: "sidebar.right") }
                    .help("Show or hide the debugger")
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if model.folderURL == nil {
            VStack(spacing: 8) {
                Text("No folder opened")
                    .foregroundStyle(.secondary)
                Button("Open Folder…") { model.open() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let selection = Binding(get: { model.fileURL }, set: { model.select($0) })
            List(model.tree, children: \.children, selection: selection) { node in
                Label(node.name, systemImage: node.children == nil ? "doc.text" : "folder")
            }
            .contextMenu {
                Button("Reload") { model.reloadTree() }
            }
        }
    }

    private var console: some View {
        ConsoleView(
            output: model.output, input: model.input, isRunning: model.isRunning,
            onText: { model.typeInput($0) },
            onDelete: { model.deleteInput() },
            onEOF: { model.sendEOF() },
            onInterrupt: { model.stop() }
        )
    }
}
