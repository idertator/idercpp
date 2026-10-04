APP        := IderCpp
BUNDLE     := build/$(APP).app
BIN        := $(BUNDLE)/Contents/MacOS/$(APP)
ICON       := $(BUNDLE)/Contents/Resources/AppIcon.icns
SOURCES    := $(wildcard Sources/*.swift)
SWIFTC     := xcrun swiftc
SWIFTFLAGS := -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library

GLOBAL_DIR := /Applications
USER_DIR   := $(HOME)/Applications

.PHONY: all build run install install-user uninstall uninstall-user clean help

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
	rm -rf build

help:
	@echo "make build          build $(BUNDLE)"
	@echo "make run            build and launch"
	@echo "make install        install to $(GLOBAL_DIR) (all users)"
	@echo "make install-user   install to $(USER_DIR) (current user)"
	@echo "make uninstall      remove from $(GLOBAL_DIR)"
	@echo "make uninstall-user remove from $(USER_DIR)"
	@echo "make clean          remove build output"
