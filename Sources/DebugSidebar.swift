import SwiftUI

struct DebugSidebar: View {
    @EnvironmentObject var model: EditorModel

    private let mono = Font.system(size: 12, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Text(model.debugStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            Divider()
            List {
                Section("Breakpoints") { breakpoints }
                Section("Call Stack") { callStack }
                Section("Variables") { variables }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            if model.isDebugging {
                if model.isPaused {
                    button("Continue (⌃⌘Y)", "play.fill") { model.debugContinue() }
                } else {
                    button("Pause", "pause.fill") { model.debugPause() }
                }
            } else {
                button("Debug (⌘D)", "ladybug.fill") { model.debug() }
                    .disabled(model.isRunning)
            }
            Group {
                button("Step Over (F6)", "arrow.right.to.line") { model.stepOver() }
                button("Step Into (F7)", "arrow.down.to.line") { model.stepInto() }
                button("Step Out (F8)", "arrow.up.to.line") { model.stepOut() }
            }
            .disabled(!model.isPaused)
            button("Stop (⌘.)", "stop.fill") { model.stop() }
                .disabled(!model.isDebugging)
            Spacer()
        }
        .padding(10)
    }

    private func button(_ help: String, _ image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image).frame(width: 18, height: 16)
        }
        .help(help)
    }

    @ViewBuilder
    private var breakpoints: some View {
        if model.breakpoints.isEmpty {
            hint("Click a line number, or press ⌘\\ on the cursor line")
        }
        ForEach(model.breakpoints) { breakpoint in
            HStack {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.red)
                Text("\(breakpoint.file.lastPathComponent):\(breakpoint.line)")
                    .font(mono)
                Spacer()
                Button { model.removeBreakpoint(breakpoint) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Remove breakpoint")
            }
        }
    }

    @ViewBuilder
    private var callStack: some View {
        if model.frames.isEmpty {
            hint(model.isDebugging ? "Program is running" : "Not debugging")
        }
        ForEach(model.frames) { frame in
            HStack {
                Text(frame.name)
                    .font(mono)
                    .fontWeight(frame.id == model.selectedFrame ? .bold : .regular)
                    .lineLimit(1)
                Spacer()
                if let location = frame.location {
                    Text("\(location.file.lastPathComponent):\(location.line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(frame.location == nil ? .secondary : .primary)
            .contentShape(Rectangle())
            .onTapGesture { model.selectFrame(frame.id) }
        }
    }

    @ViewBuilder
    private var variables: some View {
        if model.variables.isEmpty {
            hint(model.isPaused ? "No local variables" : "Shown while paused")
        }
        ForEach(model.variables) { variable in
            VStack(alignment: .leading, spacing: 1) {
                Text("\(variable.name) = \(variable.value)")
                    .font(mono)
                    .textSelection(.enabled)
                Text(variable.type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
