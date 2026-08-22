# Fader — build the SwiftPM executable, wrap in a .app bundle, ad-hoc sign, run.

APP_NAME := Fader
BUNDLE_ID := com.fader.app
CONFIG := release
BUILD_DIR := .build
APP_BUNDLE := build/$(APP_NAME).app
EXECUTABLE := $(BUILD_DIR)/$(CONFIG)/$(APP_NAME)
INFO_PLIST := Sources/Fader/Resources/Info.plist
ENTITLEMENTS := Sources/Fader/Resources/Fader.entitlements

# Use Xcode's full toolchain when it's actually installed; fall back to
# plain `swift` (Command Line Tools) otherwise. Checking for the directory
# itself, not just a non-empty `xcode-select -p`, matters because CLT-only
# machines report a valid (non-Xcode) path there too.
XCODE_DEV := /Applications/Xcode.app/Contents/Developer
ifneq ($(wildcard $(XCODE_DEV)),)
SWIFT := DEVELOPER_DIR=$(XCODE_DEV) xcrun swift
else
SWIFT := swift
endif

DMG := build/$(APP_NAME).dmg
DMG_RW := build/$(APP_NAME)-rw.dmg
DMG_STAGING := build/dmg-staging

.PHONY: build bundle sign run debug dmg clean

build:
	$(SWIFT) build -c $(CONFIG)

bundle: build icon
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(EXECUTABLE) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp $(INFO_PLIST) $(APP_BUNDLE)/Contents/Info.plist
	cp Resources/Icon/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@touch $(APP_BUNDLE)/Contents/PkgInfo
	@echo "APPL????" > $(APP_BUNDLE)/Contents/PkgInfo

icon:
	@if [ ! -f Resources/Icon/AppIcon.icns ] || [ Resources/Icon/AppIcon.svg -nt Resources/Icon/AppIcon.icns ]; then \
		echo "Rendering AppIcon..."; \
		mkdir -p Resources/Icon/AppIcon.iconset; \
		for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
		            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
		            "512:512x512" "1024:512x512@2x"; do \
			size="$${spec%%:*}"; name="$${spec##*:}"; \
			rsvg-convert -w "$$size" -h "$$size" Resources/Icon/AppIcon.svg \
				-o "Resources/Icon/AppIcon.iconset/icon_$${name}.png"; \
		done; \
		iconutil -c icns Resources/Icon/AppIcon.iconset -o Resources/Icon/AppIcon.icns; \
	fi

sign: bundle
	codesign --force --deep --sign - \
	  --entitlements $(ENTITLEMENTS) \
	  --options runtime \
	  $(APP_BUNDLE)
	@codesign -dvv $(APP_BUNDLE) 2>&1 | head -5

run: sign
	@echo "Launching $(APP_BUNDLE)..."
	@pkill -x $(APP_NAME) 2>/dev/null || true
	open $(APP_BUNDLE)

debug:
	$(SWIFT) build -c debug
	@$(MAKE) bundle CONFIG=debug
	@$(MAKE) sign CONFIG=debug
	open $(APP_BUNDLE)

dmg: sign
	@rm -rf $(DMG_STAGING) $(DMG) $(DMG_RW)
	@mkdir -p $(DMG_STAGING)
	cp -R $(APP_BUNDLE) $(DMG_STAGING)/
	@ln -s /Applications $(DMG_STAGING)/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(DMG_STAGING) -ov -format UDRW -fs HFS+ $(DMG_RW)
	@MOUNT_DIR=$$(hdiutil attach $(DMG_RW) -nobrowse -readwrite | tail -1 | awk -F '\t' '{print $$NF}'); \
	echo "Mounted at $$MOUNT_DIR"; \
	cp Resources/Icon/AppIcon.icns "$$MOUNT_DIR/.VolumeIcon.icns"; \
	SetFile -c icnC "$$MOUNT_DIR/.VolumeIcon.icns"; \
	SetFile -a C "$$MOUNT_DIR"; \
	hdiutil detach "$$MOUNT_DIR"
	hdiutil convert $(DMG_RW) -format UDZO -ov -o $(DMG)
	@rm -f $(DMG_RW)
	@rm -rf $(DMG_STAGING)
	@# The volume-icon dance above only covers the icon shown once the dmg
	@# is mounted. Finder shows the .dmg FILE itself (e.g. sitting in
	@# ~/Downloads, unmounted) with a plain generic disk-image icon unless
	@# we also stamp one directly onto the file via its resource fork —
	@# same "has custom icon" mechanism, just applied to the outer file
	@# instead of the volume root.
	@cp Resources/Icon/AppIcon.icns /tmp/fader-dmg-icon.icns
	@sips -i /tmp/fader-dmg-icon.icns >/dev/null
	@DeRez -only icns /tmp/fader-dmg-icon.icns > /tmp/fader-dmg-icon.rsrc
	@Rez -append /tmp/fader-dmg-icon.rsrc -o $(DMG)
	@SetFile -a C $(DMG)
	@rm -f /tmp/fader-dmg-icon.icns /tmp/fader-dmg-icon.rsrc
	@echo "Created $(DMG)"

clean:
	rm -rf $(BUILD_DIR) build
