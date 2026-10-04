APP        := IderCpp
BUNDLE     := build/$(APP).app
BIN        := $(BUNDLE)/Contents/MacOS/$(APP)
ICON       := $(BUNDLE)/Contents/Resources/AppIcon.icns
SOURCES    := $(wildcard Sources/*.swift)
SWIFTC     := xcrun swiftc
SWIFTFLAGS := -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library

GLOBAL_DIR := /Applications
USER_DIR   := $(HOME)/Applications
DIST_DIR   := dist

.PHONY: all build run install install-user uninstall uninstall-user clean help \
	release-patch-version release-minor-version release-major-version _release

all: build

build: $(BIN)

$(BIN): $(SOURCES) Info.plist $(ICON)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	$(SWIFTC) $(SWIFTFLAGS) $(SOURCES) -o $@
	codesign --force --sign - $(BUNDLE)

# The bundle icon (Finder, Launchpad) is rendered from the same code that draws
# the Dock icon at run time, by a small tool built from Sources/AppIcon.swift.
# $(BIN) depends on it so the icon is in place before the bundle is signed.
$(ICON): Sources/AppIcon.swift Tools/MakeIcon.swift
	mkdir -p build/tools $(BUNDLE)/Contents/Resources
	$(SWIFTC) $(SWIFTFLAGS) Sources/AppIcon.swift Tools/MakeIcon.swift -o build/tools/make-icon
	rm -rf build/AppIcon.iconset
	build/tools/make-icon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $@

run: build
	open $(BUNDLE)

# Global install, for all users. Use `sudo make install` if /Applications
# is not writable by your account.
install: build
	rm -rf "$(GLOBAL_DIR)/$(APP).app"
	cp -R $(BUNDLE) "$(GLOBAL_DIR)/"

# Per-user install, no admin rights needed.
install-user: build
	mkdir -p "$(USER_DIR)"
	rm -rf "$(USER_DIR)/$(APP).app"
	cp -R $(BUNDLE) "$(USER_DIR)/"

uninstall:
	rm -rf "$(GLOBAL_DIR)/$(APP).app"

uninstall-user:
	rm -rf "$(USER_DIR)/$(APP).app"

clean:
	rm -rf build $(DIST_DIR)

# Tag, build and publish a patch release (X.Y.Z+1).
release-patch-version: BUMP := patch
release-patch-version: _release

# Tag, build and publish a minor release (X.Y+1.0).
release-minor-version: BUMP := minor
release-minor-version: _release

# Tag, build and publish a major release (X+1.0.0).
release-major-version: BUMP := major
release-major-version: _release

# _release is the shared body of the three release-*-version targets, which
# set BUMP as a target-specific variable before depending on it. It is not
# meant to be run directly: on its own it fails on the BUMP case below rather
# than silently doing nothing.
#
# It refuses a dirty tree — a release has to be exactly what is tagged. There
# is no test suite to run first; the build prerequisite failing stops the
# release before anything is tagged. The next version comes from the latest
# vX.Y.Z tag, bumped by BUMP; with no tag yet, that base is v0.0.0.
#
# The bundle in build/ is left alone. A copy of it goes to dist/vX.Y.Z, has the
# version written into its Info.plist (the checked-in one keeps a placeholder)
# and is signed again, since editing the plist breaks the signature. It is
# zipped with ditto, which keeps the bundle's metadata and signature intact
# where a plain zip may not. The app is Apple silicon only, so there is one
# archive.
#
# A headless `claude` agent writes the release notes from the commit messages
# since the last tag — grounded in those messages alone, with no tool access,
# so it cannot touch the working tree or invent what it was not told. Only then
# does it tag, push the tag, and publish the archive as a GitHub release
# carrying those notes.
#
# The build is a prerequisite rather than a $(MAKE) call, because a recipe line
# that mentions $(MAKE) is always executed by GNU Make even under "make -n" —
# recursing here would make the dry run release for real.
_release: build
	@set -e; \
	if ! git diff --quiet || ! git diff --cached --quiet; then \
		echo "working tree is dirty; commit or stash before releasing" >&2; exit 1; \
	fi; \
	if ! command -v gh >/dev/null; then \
		echo "gh (the GitHub CLI) is required to publish a release" >&2; exit 1; \
	fi; \
	if ! command -v claude >/dev/null; then \
		echo "claude (Claude Code) is required to write the release notes" >&2; exit 1; \
	fi; \
	prev_tag=$$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -1); \
	current=$${prev_tag:-v0.0.0}; \
	current=$${current#v}; \
	major=$$(echo "$$current" | cut -d. -f1); \
	minor=$$(echo "$$current" | cut -d. -f2); \
	patch=$$(echo "$$current" | cut -d. -f3); \
	case "$(BUMP)" in \
		major) major=$$((major + 1)); minor=0; patch=0 ;; \
		minor) minor=$$((minor + 1)); patch=0 ;; \
		patch) patch=$$((patch + 1)) ;; \
		*) echo "internal: BUMP must be major, minor or patch" >&2; exit 1 ;; \
	esac; \
	next="v$$major.$$minor.$$patch"; \
	echo "==> releasing $$next (was v$$current)"; \
	outdir="$(DIST_DIR)/$$next"; \
	name="$(APP)-$$next-macos-arm64"; \
	rm -rf "$$outdir"; \
	mkdir -p "$$outdir"; \
	cp -R $(BUNDLE) "$$outdir/"; \
	plist="$$outdir/$(APP).app/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $${next#v}" "$$plist"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $${next#v}" "$$plist"; \
	codesign --force --sign - "$$outdir/$(APP).app"; \
	(cd "$$outdir" && ditto -c -k --keepParent "$(APP).app" "$$name.zip" && rm -rf "$(APP).app"); \
	(cd "$$outdir" && shasum -a 256 * > SHA256SUMS); \
	echo "==> writing release notes"; \
	range="HEAD"; \
	[ -n "$$prev_tag" ] && range="$$prev_tag..HEAD"; \
	prompt=$$(mktemp) || { echo "cannot create the release-notes prompt file" >&2; exit 1; }; \
	notesfile="$(DIST_DIR)/$$next-notes.md"; \
	printf '%s\n' \
		"Write release notes in Markdown for $(APP) $$next, a native macOS C++ editor." \
		"Audience: users of the editor, not its contributors — skip internal refactors and" \
		"doc-only changes unless they change user-visible behavior. Group related changes under" \
		"short headings when it helps; a flat list is fine otherwise. Be concise and skimmable." \
		"" \
		"Base every statement only on the commit messages given below. Do not invent or assume" \
		"anything they do not say — no download, platform, packaging or compatibility claims —" \
		"unless a commit message actually describes it." \
		"" \
		"Output raw Markdown only: no code fence around the whole output, no top-level title (the" \
		"release title already carries the version), no preamble, no closing remarks." \
		"" \
		"Commit messages since the last release, each separated by a line of dashes:" \
		> "$$prompt"; \
	git log $$range --pretty='format:commit %s%n%n%b%n---%n' >> "$$prompt"; \
	claude -p "$$(cat "$$prompt")" --output-format text --permission-prompts none \
		--disallowedTools "Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch" \
		> "$$notesfile" || \
		{ rm -f "$$prompt"; echo "claude failed to write the release notes" >&2; exit 1; }; \
	rm -f "$$prompt"; \
	if [ ! -s "$$notesfile" ]; then \
		echo "claude produced no release notes" >&2; exit 1; \
	fi; \
	echo "==> release notes written to $$notesfile"; \
	echo "==> tagging $$next"; \
	git tag -a "$$next" -m "$(APP) $$next"; \
	git push origin "$$next"; \
	echo "==> publishing the release"; \
	gh release create "$$next" "$$outdir"/* \
		--title "$(APP) $$next" \
		--notes-file "$$notesfile"; \
	echo "==> released $$next: $$outdir and $$notesfile"

help:
	@echo "make build          build $(BUNDLE)"
	@echo "make run            build and launch"
	@echo "make install        install to $(GLOBAL_DIR) (all users)"
	@echo "make install-user   install to $(USER_DIR) (current user)"
	@echo "make uninstall      remove from $(GLOBAL_DIR)"
	@echo "make uninstall-user remove from $(USER_DIR)"
	@echo "make clean          remove build and release output"
	@echo "make release-patch-version  tag, build and publish X.Y.Z+1"
	@echo "make release-minor-version  tag, build and publish X.Y+1.0"
	@echo "make release-major-version  tag, build and publish X+1.0.0"
