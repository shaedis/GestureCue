# GestureCue — build and run shortcuts.
#
#   make build   compile the app (Debug)
#   make test    build + run the XCTest suite
#   make app     build + stage a ready-to-open GestureCue.app under build/
#   make run     build, stage, and open the app
#   make open    open the staged app without rebuilding
#   make reinstall  stage + replace /Applications copy (host updates, no reboot)
#   make clean   remove local build artifacts
#
# Override: make build CONFIG=Release

SCHEME ?= GestureCue
CONFIG ?= Debug
DESTINATION ?= platform=macOS
DERIVED_DATA ?= build/DerivedData
APP_NAME := GestureCue.app
BUILT_APP := $(DERIVED_DATA)/Build/Products/$(CONFIG)/$(APP_NAME)
STAGED_APP := build/$(APP_NAME)

XCODEBUILD := xcodebuild -allowProvisioningUpdates -scheme $(SCHEME) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA)

.PHONY: help build test app run open reinstall clean

help:
	@echo "Targets: build test app run open reinstall clean (CONFIG=Debug|Release)"

build:
	$(XCODEBUILD) -configuration $(CONFIG) build

test:
	$(XCODEBUILD) -configuration $(CONFIG) test

app: build
	rm -rf "$(STAGED_APP)"
	cp -R "$(BUILT_APP)" "$(STAGED_APP)"
	@echo "Ready to open: $(STAGED_APP)"

run: app open

open:
	@test -d "$(STAGED_APP)" || (echo "No staged app. Run 'make app' first."; exit 1)
	@pkill -x GestureCue 2>/dev/null || true
	@sleep 0.5
	open "$(STAGED_APP)"

# Host-only update: replaces the /Applications copy without touching the
# staged extension (same version+bits, activation is a no-op restage).
# Reboot only when GestureCueCameraExtension/ sources changed.
reinstall: app
	@pkill -x GestureCue 2>/dev/null || true
	@sleep 0.5
	rm -rf "/Applications/$(APP_NAME)"
	cp -R "$(STAGED_APP)" "/Applications/$(APP_NAME)"
	@echo "Installed to /Applications. Open it, Start camera, Enable Camera."

clean:
	rm -rf build
