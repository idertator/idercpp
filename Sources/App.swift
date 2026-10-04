import AppKit
import SwiftUI

@main
struct IderCppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EditorModel()

    var body: some Scene {
        Window("IderCpp", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 700, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { model.newFile() }.keyboardShortcut("n")
                Button("Open…") { model.open() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }.keyboardShortcut("s")
            }
            CommandMenu("Build") {
                Button("Compile") { model.build(andRun: false) }
                    .keyboardShortcut("b")
                    .disabled(model.isRunning)
                Button("Run") { model.build(andRun: true) }
                    .keyboardShortcut("r")
                    .disabled(model.isRunning)
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.isRunning)
            }
            CommandMenu("Debug") {
                Button("Debug") { model.debug() }
                    .keyboardShortcut("d")
                    .disabled(model.isRunning)
                Button("Toggle Breakpoint") { model.toggleBreakpoint() }
                    .keyboardShortcut("\\")
                Divider()
                Button("Continue") { model.debugContinue() }
                    .keyboardShortcut("y", modifiers: [.control, .command])
                    .disabled(!model.isPaused)
                Button("Step Over") { model.stepOver() }
                    .keyboardShortcut(functionKey(NSF6FunctionKey), modifiers: [])
                    .disabled(!model.isPaused)
                Button("Step Into") { model.stepInto() }
                    .keyboardShortcut(functionKey(NSF7FunctionKey), modifiers: [])
                    .disabled(!model.isPaused)
                Button("Step Out") { model.stepOut() }
                    .keyboardShortcut(functionKey(NSF8FunctionKey), modifiers: [])
                    .disabled(!model.isPaused)
            }
        }
    }
}

private func functionKey(_ code: Int) -> KeyEquivalent {
    KeyEquivalent(Character(UnicodeScalar(code)!))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundle icon is the light one; the Dock icon follows the appearance.
        AppIcon.install()
    }
}
