import Foundation

/// A line in a source file: a breakpoint, or where the debugger is stopped.
struct SourceLine: Hashable, Identifiable {
    let file: URL
    let line: Int

    var id: SourceLine { self }
}

struct DebugFrame: Identifiable {
    let id: Int
    let name: String
    let location: SourceLine?  // nil when there is no source (library code)
}

struct DebugVariable: Identifiable {
    let id: Int
    let name: String
    let type: String
    let value: String
}

/// The real path of a file, so paths from the editor and from debug info compare equal.
func canonical(_ url: URL) -> URL {
    guard let path = realpath(url.path, nil) else { return url.standardizedFileURL }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path))
}

// Debugging through lldb-dap. The debugged program's stdio goes to a
// pseudo-terminal, so the console and the stdin field work as in a plain run.
extension EditorModel {
    /// Breakpoint lines in the file being edited.
    var breakpointLines: Set<Int> {
        guard let file = fileURL.map(canonical) else { return [] }
        return Set(breakpoints.filter { $0.file == file }.map(\.line))
    }

    /// The line the debugger is stopped at, if it is in the file being edited.
    var stoppedLine: Int? {
        guard let stoppedAt, fileURL.map(canonical) == stoppedAt.file else { return nil }
        return stoppedAt.line
    }

    // MARK: - Breakpoints

    /// Toggles a breakpoint on a line of the open file, by default the cursor line.
    func toggleBreakpoint(at line: Int? = nil) {
        if fileURL == nil { guard save() else { return } }
        guard let file = fileURL.map(canonical) else { return }
        let breakpoint = SourceLine(file: file, line: line ?? cursorLine)
        if let index = breakpoints.firstIndex(of: breakpoint) {
            breakpoints.remove(at: index)
        } else {
            breakpoints.append(breakpoint)
        }
        syncBreakpoints(in: file)
    }

    func removeBreakpoint(_ breakpoint: SourceLine) {
        breakpoints.removeAll { $0 == breakpoint }
        syncBreakpoints(in: breakpoint.file)
    }

    /// Tells a running debugger the full breakpoint list for one file.
    private func syncBreakpoints(in file: URL) {
        guard isDebugging else { return }
        let lines = breakpoints.filter { $0.file == file }.map { ["line": $0.line] }
        dap?.send("setBreakpoints", ["source": ["path": file.path], "breakpoints": lines])
    }

    // MARK: - Session

    func debug() {
        guard !isRunning else { return }
        showDebugger = true
        compile { [weak self] bin, cwd in
            self?.startDebugger(bin, cwd: cwd)
        }
    }

    private func startDebugger(_ bin: URL, cwd: URL) {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 1024)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else {
            append("openpty failed\n")
            return
        }
        let tty = String(cString: name)

        let client = DAPClient()
        client.onEvent = { [weak self] event, body in self?.handleDebugEvent(event, body) }
        client.onExit = { [weak self] in self?.endDebug() }
        do {
            try client.start()
        } catch {
            close(master)
            close(slave)
            append("could not launch lldb-dap: \(error.localizedDescription)\n")
            return
        }
        dap = client
        masterFD = master
        debugTTY = slave
        debugExit = nil
        isRunning = true
        isDebugging = true
        debugStatus = "Running"
        append("$ lldb-dap \(bin.path)\n")

        // Ends once the session closed our side of the terminal and the program is gone.
        DispatchQueue.global().async {
            self.pump(master)
            DispatchQueue.main.async {
                close(master)
                self.append("\n[\(self.debugExit ?? "debug session ended")]\n")
            }
        }

        // lldb-dap rejects an initialize request without pathFormat.
        client.send("initialize", [
            "adapterID": "lldb", "pathFormat": "path", "linesStartAt1": true, "columnsStartAt1": true,
        ])
        client.send("launch", [
            "program": bin.path,
            "cwd": cwd.path,
            "initCommands": [
                "settings set target.input-path \(tty)",
                "settings set target.output-path \(tty)",
                "settings set target.error-path \(tty)",
            ],
        ]) { [weak self] body in
            guard body == nil else { return }
            self?.append("lldb could not launch the program\n")
            self?.endDebug()
        }
    }

    private func handleDebugEvent(_ event: String, _ body: DAPClient.JSON) {
        switch event {
        case "initialized":
            for file in Set(breakpoints.map(\.file)) { syncBreakpoints(in: file) }
            dap?.send("configurationDone")
        case "stopped":
            debugThread = body["threadId"] as? Int ?? debugThread
            isPaused = true
            debugStatus = "Paused — " + (body["description"] as? String ?? body["reason"] as? String ?? "stopped")
            loadFrames()
        case "continued":
            resumed()
        case "exited":
            debugExit = "exit \(body["exitCode"] as? Int ?? 0)"
        case "terminated":
            endDebug()
        default:
            break
        }
    }

    func endDebug() {
        guard isDebugging else { return }
        isDebugging = false
        isRunning = false
        resumed()
        debugStatus = "Not running"

        let client = dap
        dap = nil
        client?.onExit = nil
        client?.send("disconnect", ["terminateDebuggee": true]) { _ in client?.terminate() }
        // In case the adapter never answers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { client?.terminate() }

        masterFD = -1
        close(debugTTY)
        debugTTY = -1
    }

    // MARK: - Stepping

    func debugContinue() { resume(with: "continue") }
    func stepOver() { resume(with: "next") }
    func stepInto() { resume(with: "stepIn") }
    func stepOut() { resume(with: "stepOut") }

    func debugPause() {
        guard isDebugging, !isPaused else { return }
        dap?.send("pause", ["threadId": debugThread])
    }

    private func resume(with command: String) {
        guard isPaused else { return }
        resumed()
        dap?.send(command, ["threadId": debugThread])
    }

    private func resumed() {
        isPaused = false
        debugStatus = "Running"
        frames = []
        variables = []
        selectedFrame = nil
        stoppedAt = nil
    }

    // MARK: - Stack and variables

    private func loadFrames() {
        dap?.send("stackTrace", ["threadId": debugThread, "levels": 64]) { [weak self] body in
            guard let self, self.isPaused, let raw = body?["stackFrames"] as? [DAPClient.JSON] else { return }
            self.frames = raw.compactMap { frame in
                guard let id = frame["id"] as? Int else { return nil }
                var location: SourceLine?
                if let path = (frame["source"] as? DAPClient.JSON)?["path"] as? String,
                   let line = frame["line"] as? Int,
                   FileManager.default.fileExists(atPath: path) {
                    location = SourceLine(file: canonical(URL(fileURLWithPath: path)), line: line)
                }
                return DebugFrame(id: id, name: frame["name"] as? String ?? "?", location: location)
            }
            // A crash usually stops inside a library: start at the first frame of our code.
            self.selectFrame((self.frames.first { $0.location != nil } ?? self.frames.first)?.id)
        }
    }

    /// Shows a stack frame: its source line in the editor and its local variables.
    func selectFrame(_ id: Int?) {
        guard let frame = frames.first(where: { $0.id == id }) else { return }
        selectedFrame = frame.id
        variables = []
        if let location = frame.location {
            if fileURL.map(canonical) != location.file, leaveCurrentFile() {
                load(location.file)
            }
            stoppedAt = location
        }
        dap?.send("scopes", ["frameId": frame.id]) { [weak self] body in
            guard let scopes = body?["scopes"] as? [DAPClient.JSON],
                  let locals = scopes.first(where: { $0["name"] as? String == "Locals" }) ?? scopes.first,
                  let reference = locals["variablesReference"] as? Int
            else { return }
            self?.dap?.send("variables", ["variablesReference": reference]) { [weak self] body in
                guard let self, self.selectedFrame == frame.id,
                      let raw = body?["variables"] as? [DAPClient.JSON]
                else { return }
                self.variables = raw.enumerated().map { index, variable in
                    DebugVariable(
                        id: index,
                        name: variable["name"] as? String ?? "?",
                        type: variable["type"] as? String ?? "",
                        value: variable["value"] as? String ?? "")
                }
            }
        }
    }
}
