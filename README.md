# IderCpp

A small native macOS editor for C++, written in SwiftUI for Apple silicon. It
builds with the Xcode command line tools and a Makefile, with no Xcode project
and no third-party dependencies.

It edits, compiles, runs and debugs C++ projects:

- Syntax highlighting and a line number gutter with clickable breakpoints
- A project sidebar for the opened folder
- Compile and run with an interactive terminal pane, so `cin` works
- Debugging through `lldb-dap`: breakpoints, stepping, call stack, locals
- Autocompletion from a binary symbol index, no language server
- Smart indentation with four spaces
- Optional Vim-style modal editing

## Requirements

- Apple silicon Mac (the build targets `arm64`)
- macOS 14 or later
- Xcode command line tools: `xcode-select --install`

Full Xcode is not needed. It provides `swiftc`, `clang++`, `codesign`,
`iconutil` and `lldb-dap`, which are all this project uses.

## Build

```sh
make            # build build/IderCpp.app
make run        # build and launch
```

| Target | What it does |
|---|---|
| `make` / `make build` | Build `build/IderCpp.app` |
| `make run` | Build and launch |
| `make install` | Copy to `/Applications` for all users (`sudo make install` if not writable) |
| `make install-user` | Copy to `~/Applications` |
| `make uninstall` / `make uninstall-user` | Remove the installed copy |
| `make clean` | Delete `build/` and `dist/` |
| `make release-patch-version` / `-minor-` / `-major-` | Bump the latest `vX.Y.Z` tag, package the app as a `.zip` and a `.dmg` installer in `dist/`, tag, push and publish a GitHub release (needs `gh` and `claude`, clean tree) |
| `make help` | List the targets |

The app is signed ad hoc, which is enough to run it on the Mac that built it.

## Usage

Start the app with no arguments and it reopens the last project and file. To
open something else, pass a folder or a file:

```sh
open build/IderCpp.app --args ~/code/myproject
build/IderCpp.app/Contents/MacOS/IderCpp ~/code/myproject/main.cpp
```

Arguments are only read at launch, so `open --args` has no effect on an
instance that is already running. Or use **⌘O** and pick a file, or a folder
as the project.

### Projects

An opened folder is the project. The left sidebar shows its files; click one to
edit it. On opening a folder, `main.cpp` at its root is loaded if it exists.

Compile and Run build **every** `.cpp`, `.cc` and `.cxx` file under the folder
into one binary, with `-I .`, so exactly one of them should define `main`.
Folders named `build` or `cmake-build*` are skipped. With no folder open, only
the current file is built.

Compiles use `clang++ -std=c++20 -Wall -Wextra -g`. The binary goes to a
temporary directory, not into your project.

### Running

**⌘R** compiles and runs. Output appears in the terminal pane at the bottom.
While a program runs, type straight into that pane to answer it:

- **Return** sends the line
- **⌃D** on an empty line ends the input
- **⌃C** stops the program

**⌘J** shows or hides the terminal pane. It comes back by itself when you
compile or run.

### Debugging

**⌘D** compiles and starts a debug session; the debugger sidebar opens on the
right.

- Click a line number, or press **⌘\\**, to toggle a breakpoint
- **⌃⌘Y** continues; **F6**, **F7**, **F8** step over, into and out
- Click a stack frame to jump to its line and see its local variables

### Autocompletion

Saving writes the identifiers of the project to a binary file, `.autocmp`, in
the project folder (beside the file, when one is opened on its own). Typing two
or more characters of a word shows matching symbols from that file, found by
binary search over the memory-mapped index. Arrow keys pick one; Return or Tab
inserts it.

There is no parsing of types or scope: the list is every identifier that starts
with what you typed, plus C++ keywords and common standard types. Add
`.autocmp` to your project's `.gitignore`.

### Vim mode

**⌃M** turns a small Vim subset on or off, and the choice is remembered. It
covers normal, insert and visual modes, the usual motions with counts, the `d`,
`c` and `y` operators, and `x p P u ⌃R J r`. There are no `.`, `/`, `:` or
macros.

### Key bindings

Press **⌘?**, or `?` in Vim normal mode or an idle terminal, for the full list.

## Project layout

| Path | Purpose |
|---|---|
| `Sources/App.swift` | App entry, menus, shortcuts |
| `Sources/ContentView.swift` | Window layout, toolbar, sidebar |
| `Sources/EditorModel.swift` | Files, projects, compile and run |
| `Sources/CodeEditor.swift` | The text editor |
| `Sources/CppHighlighter.swift` | Syntax highlighting |
| `Sources/SmartIndent.swift` | Indentation rules |
| `Sources/LineNumberGutter.swift` | Line numbers and breakpoint clicks |
| `Sources/ConsoleView.swift` | Terminal pane |
| `Sources/Debugger.swift`, `DAPClient.swift`, `DebugSidebar.swift` | Debugging through `lldb-dap` |
| `Sources/SymbolIndex.swift` | `.autocmp` format, indexing and lookup |
| `Sources/VimEngine.swift` | Vim mode |
| `Sources/HelpView.swift` | Key bindings sheet |
| `Sources/AppIcon.swift`, `Tools/MakeIcon.swift`, `assets/` | App icon |

### The `.autocmp` format

All integers are little-endian.

```
"ACMP" | version: u32 | count: u32
count × { offset: u32, length: u32 }   one record per symbol, sorted by name bytes
names, UTF-8, back to back             offset is from the start of the file
```

## Notes for contributors

- The command line tools do not include the SwiftUI macro plugin, so `@State`
  does not compile. Keep view state in a model class as `@Published` instead.
- Run the build with `make`; the Makefile compiles all of `Sources/*.swift` in
  one `swiftc` call, so a new source file needs no registration.

## Limitations

- Apple silicon only; no Intel build, no universal binary
- One file open at a time, no tabs
- Breakpoints are plain line numbers: they do not move when lines are inserted,
  and they are not saved between launches
- Debugger variables are shown flat, without expanding containers
- The Vim mode is a subset
