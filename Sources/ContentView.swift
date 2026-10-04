import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: EditorModel

    private let mono = Font.system(size: 12, design: .monospaced)

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
                    completions: { model.completions(for: $0) }
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
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.output)
                        .font(mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .id("end")
                }
                .onChange(of: model.output) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            Divider()
            TextField("stdin — press Return to send", text: $model.input)
                .textFieldStyle(.plain)
                .font(mono)
                .padding(6)
                .disabled(!model.isRunning)
                .onSubmit {
                    model.send(model.input)
                    model.input = ""
                }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
