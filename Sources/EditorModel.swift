import AppKit
import SwiftUI

struct FileNode: Identifiable {
    let url: URL
    var children: [FileNode]?  // nil for regular files

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor
final class EditorModel: ObservableObject {
    static let template = """
        #include <iostream>

        int main() {
            std::cout << "Hello, world!" << std::endl;
            return 0;
        }

        """

    @Published var text = EditorModel.template { didSet { isDirty = true } }
    @Published var fileURL: URL?
    /// The opened folder is the project: it fills the sidebar and is built as a whole.
    @Published var folderURL: URL?
    @Published var tree: [FileNode] = []
    @Published var isDirty = false
    @Published var output = ""
    @Published var isRunning = false
    // Lives here rather than in a view @State: the SwiftUI macro plugin behind
    // @State ships with Xcode only, not the Command Line Tools.
    @Published var input = ""

    // Debugger state; the logic lives in Debugger.swift.
    @Published var showDebugger = false
    @Published var breakpoints: [SourceLine] = []
    @Published var isDebugging = false
    @Published var isPaused = false
    @Published var debugStatus = "Not running"
    @Published var frames: [DebugFrame] = []
    @Published var selectedFrame: Int?
    @Published var variables: [DebugVariable] = []
    @Published var stoppedAt: SourceLine?
    /// Kept up to date by the editor; not published, it changes on every cursor move.
    var cursorLine = 1
    /// Autocomplete index, see SymbolIndex.swift. Nil until something is opened or saved.
    var symbols: SymbolIndex?
    var dap: DAPClient?
    var debugThread = 0
    var debugTTY: Int32 = -1
    var debugExit: String?

    private var process: Process?
    var masterFD: Int32 = -1

    var title: String {
        let file = (fileURL?.lastPathComponent ?? "untitled.cpp") + (isDirty ? " — edited" : "")
        guard let folderURL else { return file }
        return folderURL.lastPathComponent + " — " + file
    }

    /// Untitled buffers count as C++; other project files (Makefile, notes) stay plain.
    var isCpp: Bool {
        guard let fileURL else { return true }
        return CppHighlighter.extensions.contains(fileURL.pathExtension.lowercased())
    }

    // MARK: - Files

    func newFile() {
        guard confirmDiscard() else { return }
        text = EditorModel.template
        fileURL = nil
        isDirty = false
    }

    /// Opens a file, or a folder as the project.
    func open() {
        guard leaveCurrentFile() else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.hasDirectoryPath {
            openFolder(url)
        } else {
            load(url)
        }
    }

    /// Sidebar selection: switches the editor to another project file.
    func select(_ url: URL?) {
        guard let url, url != fileURL, !url.hasDirectoryPath, leaveCurrentFile() else { return }
        load(url)
    }

    func reloadTree() {
        tree = folderURL.map(scan) ?? []
    }

    private func openFolder(_ url: URL) {
        folderURL = url
        reloadTree()
        let main = url.appendingPathComponent("main.cpp")
        if FileManager.default.fileExists(atPath: main.path) {
            load(main)
        } else {
            text = ""
            fileURL = nil
            isDirty = false
        }
        loadIndex()
    }

    func load(_ url: URL) {
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            fileURL = url
            isDirty = false
            // A file opened on its own has its own index; a project has one for all files.
            if folderURL == nil { loadIndex() }
        } catch {
            alert("Could not open file", error.localizedDescription)
        }
    }

    /// Before switching files: saves edits to a file on disk, asks about an
    /// untitled buffer.
    func leaveCurrentFile() -> Bool {
        guard isDirty else { return true }
        return fileURL == nil ? confirmDiscard() : save()
    }

    private func scan(_ dir: URL) -> [FileNode] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .map { FileNode(url: $0, children: $0.hasDirectoryPath ? scan($0) : nil) }
            .sorted {
                // Folders first, then by name.
                if ($0.children == nil) != ($1.children == nil) { return $0.children != nil }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    @discardableResult
    func save() -> Bool {
        if fileURL == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "main.cpp"
            panel.directoryURL = folderURL
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            fileURL = url
        }
        do {
            let isNew = !FileManager.default.fileExists(atPath: fileURL!.path)
            try text.write(to: fileURL!, atomically: true, encoding: .utf8)
            isDirty = false
            if isNew { reloadTree() }
            reindex()
            return true
        } catch {
            alert("Could not save file", error.localizedDescription)
            return false
        }
    }

    private func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let a = NSAlert()
        a.messageText = "Discard unsaved changes?"
        a.addButton(withTitle: "Discard")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }

    // MARK: - Build & run

    func build(andRun: Bool) {
        compile { [weak self] bin, cwd in
            guard let self, andRun else { return }
            self.append("$ \(bin.path)\n")
            self.launch(bin.path, [], cwd: cwd) { [weak self] _, status in
                self?.append("\n[\(status)]\n")
            }
        }
    }

    /// Saves and compiles the project (or the single open file), then hands
    /// over the binary and the directory to run it in.
    func compile(then: @escaping @MainActor (_ bin: URL, _ cwd: URL) -> Void) {
        guard !isRunning else { return }
        // In a project an untouched untitled buffer is not part of the build.
        if folderURL == nil || fileURL != nil || isDirty {
            guard save() else { return }
        }
        let cwd: URL
        let name: String
        var sources: [String]
        if let folderURL {
            cwd = folderURL
            name = folderURL.lastPathComponent
            sources = projectSources(in: folderURL)
            guard !sources.isEmpty else {
                output = "no C++ sources (.cpp, .cc, .cxx) in \(folderURL.path)\n"
                return
            }
            sources = ["-I", "."] + sources
        } else {
            guard let src = fileURL else { return }
            cwd = src.deletingLastPathComponent()
            name = src.deletingPathExtension().lastPathComponent
            sources = [src.path]
        }
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("idercpp")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let bin = outDir.appendingPathComponent(name)

        let args = [
            "clang++", "-std=c++20", "-arch", "arm64", "-Wall", "-Wextra", "-g",
            "-fno-color-diagnostics",
        ] + sources + ["-o", bin.path]
        output = "$ " + args.joined(separator: " ") + "\n"
        launch("/usr/bin/xcrun", args, cwd: cwd) { [weak self] ok, status in
            guard let self else { return }
            guard ok else {
                self.append("[build failed: \(status)]\n")
                return
            }
            self.append("[build ok]\n")
            then(bin, cwd)
        }
    }

    /// Every C++ source under the project, as paths relative to it. Skips
    /// hidden files and build output folders (their sources are not ours).
    private func projectSources(in folder: URL) -> [String] {
        let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let root = folder.standardizedFileURL.path + "/"
        var result: [String] = []
        while let url = walker?.nextObject() as? URL {
            if url.hasDirectoryPath {
                let dir = url.lastPathComponent
                if dir == "build" || dir.hasPrefix("cmake-build") { walker?.skipDescendants() }
            } else if ["cpp", "cc", "cxx"].contains(url.pathExtension.lowercased()) {
                let path = url.standardizedFileURL.path
                result.append(path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path)
            }
        }
        return result.sorted()
    }

    func stop() {
        if isDebugging {
            endDebug()
        } else {
            process?.terminate()
        }
    }

    /// Sends a line to the running program's stdin.
    func send(_ line: String) {
        guard isRunning, masterFD >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        _ = write(masterFD, bytes, bytes.count)
    }

    func append(_ s: String) {
        output += s
        // Keep the console bounded if a program spams output.
        if output.count > 200_000 { output = String(output.suffix(150_000)) }
    }

    /// Runs a process attached to a pseudo-terminal, so the child's stdout is
    /// line-buffered and prompts show up before it blocks on input.
    private func launch(
        _ exe: String, _ args: [String], cwd: URL,
        done: @escaping @MainActor (_ ok: Bool, _ status: String) -> Void
    ) {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            append("openpty failed\n")
            return
        }
        let tty = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardInput = tty
        p.standardOutput = tty
        p.standardError = tty
        do {
            try p.run()
        } catch {
            close(master)
            close(slave)
            append("could not launch \(exe): \(error.localizedDescription)\n")
            return
        }
        close(slave)
        process = p
        masterFD = master
        isRunning = true

        DispatchQueue.global().async {
            self.pump(master)
            p.waitUntilExit()
            let code = p.terminationStatus
            let crashed = p.terminationReason == .uncaughtSignal
            DispatchQueue.main.async {
                close(master)
                self.masterFD = -1
                self.process = nil
                self.isRunning = false
                done(!crashed && code == 0, crashed ? "killed by signal \(code)" : "exit \(code)")
            }
        }
    }

    /// Copies a pseudo-terminal's output to the console until the other end closes.
    nonisolated func pump(_ master: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(master, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            let s = String(decoding: buf[0..<n], as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
            DispatchQueue.main.async { self.append(s) }
        }
    }
}
