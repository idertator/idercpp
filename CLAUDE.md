# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

IderCpp is a native macOS C++ editor in SwiftUI (Apple silicon, macOS 14+) that builds with the Xcode command line tools only. See `README.md` for features and user-facing usage.

## Build and run

```sh
make            # build build/IderCpp.app (compiles every Sources/*.swift in one swiftc call, then ad-hoc signs)
make run        # build and launch
make clean
```

New source files are picked up by the `Sources/*.swift` wildcard; nothing to register. The icon is generated at build time from `Sources/AppIcon.swift` + `Tools/MakeIcon.swift`.

There is no test suite and no linter. To check a change without a GUI, write a throwaway harness with its own `@main` (keep it out of the repo) and compile it with the app sources, leaving out the two files that cannot be linked into it:

```sh
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  $(ls Sources/*.swift | grep -v -e '/App.swift' -e AppIcon.swift) harness.swift -o harness
```

Smoke test the real app: run `build/IderCpp.app/Contents/MacOS/IderCpp` in the background for a few seconds and confirm it is still alive.

Pitfalls when driving the model from a harness:
- `EditorModel` is `@MainActor`; `save()` (called by compile/debug) opens a modal `NSSavePanel` for an untitled buffer and `NSAlert` on errors, which hangs a headless run. `load()` a real file first.
- `EditorModel.init()` restores the last project and reads `CommandLine.arguments`, so a harness that takes its own arguments will have them treated as a project path.
- SwiftUI `ScrollView` content does not render through `ImageRenderer` or `cacheDisplay` headlessly; render the inner content view instead (see how `HelpView` is split from `HelpContent`).

## Toolchain constraint

The command line tools lack the SwiftUI macro plugin, so **`@State` does not compile** (`plugin for module 'SwiftUIMacros' not found`). Keep view state as `@Published` on `EditorModel` (see `input`, `showConsole`, `showHelp`). `@StateObject`, `@EnvironmentObject`, `@Published` are fine.

## Architecture

**One model, spread over several files.** `EditorModel` (`@MainActor ObservableObject`, in `EditorModel.swift`) owns all app state. The debugger (`Debugger.swift`) and the autocomplete glue (`SymbolIndex.swift`) are `extension EditorModel`. Swift extensions cannot hold stored properties, so every stored property those extensions use is declared in `EditorModel.swift`, which is why some of them (`dap`, `debugTTY`, `masterFD`, `append`, `load`, `leaveCurrentFile`) are not `private`.

**Process execution goes through a pseudo-terminal.** `launch()` runs a child on an `openpty` pair so stdout is line-buffered and prompts appear before `cin` blocks. `pump()` copies the master side to `output`. The terminal's own echo is turned off (`quiet()`) because `ConsoleView` draws the line being typed itself and `typeInput()` echoes the sent line; leaving echo on prints everything twice. `masterFD` is shared by plain runs and debug sessions, so `typeInput`/`sendEOF` work for both.

**Compile is shared.** `build(andRun:)` and `debug()` both go through `compile(then:)`, which saves, builds the project (all `.cpp/.cc/.cxx` under the opened folder, skipping `build/` and `cmake-build*`, or just the open file when no folder is open) and then calls back with the binary. It also forces `showConsole = true`.

**Debugging is a DAP client over `lldb-dap`.** `DAPClient` frames `Content-Length` JSON over pipes; `Debugger.swift` drives it. Non-obvious requirements found by probing the real adapter:
- `initialize` must include `pathFormat: "path"` or it fails.
- The debuggee's stdio is redirected to the pty slave with `initCommands` (`settings set target.input-path/output-path/error-path <tty>`), so the console works the same as in a plain run.
- Breakpoints are sent on the `initialized` event, followed by `configurationDone`.
- Breakpoints are stored as `SourceLine(file, line)` with paths run through `canonical()` (realpath) so editor paths and debug-info paths compare equal.

**Editor is AppKit wrapped for SwiftUI.** `CodeEditor` (`NSViewRepresentable`) hosts an `EditorTextView`, not `TextEditor`, to avoid smart quotes. `rehighlight` re-colours the whole document on every change (`CppHighlighter`), then paints breakpoint and stopped-line backgrounds as `.backgroundColor` on the text storage. `LineNumberGutter` is an `NSRulerView` that does its own hit-testing for breakpoint clicks. Switching files clears the undo stack; without that, ⌘Z can replay edits from the previous file and crash.

**Vim mode edits through the text view.** `EditorTextView.keyDown` gives `VimEngine` the first chance at each key. The engine changes text only via `textView.shouldChangeText` + `textStorage.replaceCharacters` + `didChangeText`, so undo, highlighting, and the model binding all follow. The block cursor is a temporary attribute from `updateCursor()`, not a real caret.

**Autocomplete index.** `SymbolIndex` reads and writes the binary `.autocmp` file (layout documented in the doc comment at the top of `SymbolIndex.swift` and in the README). It is memory-mapped and searched in place, never parsed. It is rebuilt off the main thread on every save and on opening a project; `.autocmp` is gitignored.

**Persistence** is `UserDefaults` only: `vimEnabled`, `lastFolder`, `lastFile`. `init()` opens the first non-dash command-line argument if given, otherwise the remembered project.

## Keeping things in sync

- `HelpView.swift` lists the key bindings by hand. Update it when a shortcut in `App.swift`, `VimEngine.swift` or `ConsoleView.swift` changes.
- The `.autocmp` layout is described in both `SymbolIndex.swift` and `README.md`.

## Commits

Conventional Commits, no `Co-Authored-By` trailer.
