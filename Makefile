# TextTap Makefile
# Build and install TextTap using Swift Package Manager

ARCH ?= $(shell uname -m)
VERSION := $(shell v=$$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//'); [ -n "$$v" ] && echo "$$v" || echo "dev")
APP_NAME = TextTap
APP_BUNDLE = $(APP_NAME).app
BUILD_DIR = .build/release

.PHONY: build install clean help resolve icons

icons:
	@echo "Generating icons..."
	@# Generate menu bar icons from SVG
	@magick -density 1024 -background none assets/appicon.svg -resize 18x18 -depth 8 assets/icon.png
	@magick -density 1024 -background none assets/appicon.svg -resize 36x36 -depth 8 assets/icon@2x.png
	@# Compile .icon to Assets.car
	@cd assets && actool --compile . --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist /tmp/actool-info.plist AppIcon.icon > /dev/null
	@echo "Icons generated"

help:
	@echo "TextTap Build System"
	@echo ""
	@echo "Usage:"
	@echo "  make icons          - Generate app icons from SVG"
	@echo "  make build          - Build TextTap.app (release)"
	@echo "  make install        - Build and install to /Applications"
	@echo "  make clean          - Clean build artifacts"
	@echo "  make resolve        - Resolve SPM dependencies"
	@echo ""
	@echo "Architecture:"
	@echo "  make ARCH=arm64 build    (default on Apple Silicon)"
	@echo "  make ARCH=x86_64 build   (Intel Mac)"
	@echo ""
	@echo "First time: make build && make install"

resolve:
	swift package resolve

build: resolve icons
	@echo "Building TextTap..."
	swift build -c release --arch $(ARCH)
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/TextTap $(APP_BUNDLE)/Contents/MacOS/
	@cp Info.plist $(APP_BUNDLE)/Contents/
	@if [ -f assets/icon.png ]; then cp assets/icon.png $(APP_BUNDLE)/Contents/Resources/; fi
	@if [ -f assets/icon@2x.png ]; then cp assets/icon@2x.png $(APP_BUNDLE)/Contents/Resources/; fi
	@if [ -f assets/AppIcon.icns ]; then cp assets/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/; fi
	@if [ -f assets/Assets.car ]; then cp assets/Assets.car $(APP_BUNDLE)/Contents/Resources/; fi
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(APP_BUNDLE)/Contents/Info.plist
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE) v$(VERSION)"

install: build
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

clean:
	@rm -rf $(APP_BUNDLE)
	@rm -rf .build
	@echo "Clean complete"
