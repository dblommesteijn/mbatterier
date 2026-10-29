# Local settings, not committed (.gitignore): plain NAME=value lines, such as
# TEAM=ABCDE12345. A value given on the command line still wins.
-include .env

PREFIX ?= $(HOME)/.local
BIN := mbatterier
GOVULNCHECK := golang.org/x/vuln/cmd/govulncheck@v1.9.0
LABEL := it.blommesteijn.mbatterier.watch
PLIST := $(LABEL).plist

.PHONY: build install install-system install-agent uninstall-agent test vet vuln check icon alfred clean
.PHONY: menulet install-menulet uninstall-menulet reload-control symbols

build:
	go -C src build -o $(CURDIR)/$(BIN) ./cmd/mbatterier

install: build
	install -d $(PREFIX)/bin
	install -m 0755 $(BIN) $(PREFIX)/bin/$(BIN)
	ln -sf $(BIN) $(PREFIX)/bin/mbat

test:
	go -C src test ./...

vet:
	@test -z "$$(gofmt -l src)" || { gofmt -l src; echo "gofmt: files need formatting"; exit 1; }
	go -C src vet ./...

vuln:
	go -C src run $(GOVULNCHECK) ./...

check: vet test vuln

clean:
	rm -f $(BIN) mbatterier.alfredworkflow
	rm -rf $(MENULET_BUILD)

# Generated, not committed: made on the first `make alfred` and again only when
# the generator changes. python3 comes with the Command Line Tools. The glyph
# comes from the file name.
ICONS := icon boost unplug watch low status stop
ICON_FILES := $(ICONS:%=alfred/%.png)

alfred/%.png: tools/icon.py
	python3 -I tools/icon.py $@

icon: $(ICON_FILES)

# The Control Center controls' battery symbols. Generated, not committed: made
# on the first `make menulet` and again only when the generator changes; `make
# symbols` forces it. The catalog's Contents.json stands for the whole catalog,
# and is deleted if the generator fails, so a half-written catalog is redone.
# The centred controls' charge is drawn from the system font, whose outlines
# glyphs.swift reads first.
SYMBOLS := menulets/MBatteryControl/Assets.xcassets/Contents.json

$(SYMBOLS): tools/symbols.py menulets/MBatteryControl/glyphs.swift
	rm -rf menulets/MBatteryControl/Assets.xcassets
	mkdir -p $(MENULET_BUILD)
	xcrun swift menulets/MBatteryControl/glyphs.swift > $(MENULET_BUILD)/glyphs.json
	python3 -I tools/symbols.py $(MENULET_BUILD)/glyphs.json || { rm -f $@; exit 1; }

symbols:
	rm -f $(SYMBOLS)
	$(MAKE) $(SYMBOLS)

alfred: $(ICON_FILES)
	plutil -lint alfred/info.plist
	rm -f mbatterier.alfredworkflow
	cd alfred && zip -q -r ../mbatterier.alfredworkflow . -x '*.DS_Store'

# Root-owned copy in /usr/local/bin, for the passwordless sudo rule and Alfred.
install-system: build
	sudo install -o root -g wheel -m 0755 $(BIN) /usr/local/bin/$(BIN)
	sudo ln -sf $(BIN) /usr/local/bin/mbat

# LaunchDaemon that runs `mbat watch` at boot. It runs the root-owned binary,
# so install-system has to be current.
install-agent: install-system
	plutil -lint launchd/$(PLIST)
	sudo install -o root -g wheel -m 0644 launchd/$(PLIST) /Library/LaunchDaemons/$(PLIST)
	-sudo launchctl bootout system/$(LABEL) 2>/dev/null
	sudo launchctl bootstrap system /Library/LaunchDaemons/$(PLIST)

uninstall-agent:
	-sudo launchctl bootout system/$(LABEL) 2>/dev/null
	sudo rm -f /Library/LaunchDaemons/$(PLIST)

# The menu bar app. All of it lives under menulets/, the one Swift corner of
# this repo; `make check` and every Go target stay Swift-free.
MENULET := MBatterier
MENULET_ID := it.blommesteijn.mbatterier.menulet
MENULET_DIR := menulets/$(MENULET)
MENULET_BUILD := $(MENULET_DIR)/build
MENULET_APP := $(MENULET_BUILD)/$(MENULET).app
MENULET_AGENT := $(HOME)/Library/LaunchAgents/$(MENULET_ID).plist
MENULET_INSTALLED := $(HOME)/Applications/$(MENULET).app

# The Control Center control: a WidgetKit extension inside the menulet, built
# by hand like the menulet itself. Its tap and its value come through App
# Intents, which only work with the intent metadata Xcode would extract.
CONTROL := MBatteryControl
CONTROL_DIR := menulets/$(CONTROL)
CONTROL_APPEX := $(MENULET_APP)/Contents/PlugIns/$(CONTROL).appex
CONTROL_TARGET := $(shell uname -m)-apple-macos26.0
OBJ := $(MENULET_BUILD)/obj
SHARED := menulets/Shared/*.swift
# The two bundles share an App Group, which takes a real team identity: they
# are signed with your Apple Development certificate, not ad hoc. TEAM has no
# default and must be given (in .env, make TEAM=... or exported): it is
# the certificate's OU (codesign -dv shows it as TeamIdentifier), not the id in
# parentheses in its name. The App Group must start with it, or macOS keeps the
# control out of the shared container. See the README.
SIGN_ID ?= Apple Development
TEAM ?=
GROUP := $(TEAM).it.blommesteijn.mbatterier
SDK = $(shell xcrun --sdk macosx --show-sdk-path)
TOOLCHAIN = $(abspath $(dir $(shell xcrun --find swiftc))/../..)
XCODE_BUILD = $(shell xcodebuild -version | sed -n 's/^Build version //p')
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUILD_NUMBER := $(shell date +%Y%m%d%H%M%S)

menulet: $(SYMBOLS)
	@test -n "$(TEAM)" || { echo "error: set TEAM to your Apple Developer Team ID, e.g. make TEAM=ABCDE12345 $(MAKECMDGOALS) (see the README, Control Center: Signing)"; exit 1; }
	plutil -lint $(MENULET_DIR)/Info.plist $(CONTROL_DIR)/Info.plist
	rm -rf $(MENULET_APP) $(OBJ)
	mkdir -p $(MENULET_APP)/Contents/MacOS $(CONTROL_APPEX)/Contents/MacOS $(OBJ)
	sed 's|__GROUP__|$(GROUP)|' $(MENULET_DIR)/Info.plist > $(MENULET_APP)/Contents/Info.plist
	sed 's|__GROUP__|$(GROUP)|' $(CONTROL_DIR)/Info.plist > $(CONTROL_APPEX)/Contents/Info.plist
	# A build number of its own for every build: chronod only fetches the
	# control's list of controls for an extension whose version changed, and
	# without that list Control Center shows the control as a dashed app
	# placeholder.
	plutil -replace CFBundleVersion -string $(BUILD_NUMBER) $(MENULET_APP)/Contents/Info.plist
	# The app icon, which Edit Controls shows beside the controls: the Alfred
	# logo (tools/icon.py), set on the macOS icon grid (an 824pt tile on a
	# 1024pt canvas) and packed into an .icns.
	mkdir -p $(OBJ)/AppIcon.iconset $(MENULET_APP)/Contents/Resources
	python3 -I tools/icon.py $(OBJ)/icon.png
	sips -z 824 824 $(OBJ)/icon.png --out $(OBJ)/tile.png >/dev/null
	sips --padToHeightWidth 1024 1024 $(OBJ)/tile.png --out $(OBJ)/AppIcon.iconset/icon_512x512@2x.png >/dev/null
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s $(OBJ)/AppIcon.iconset/icon_512x512@2x.png --out $(OBJ)/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  sips -z $$((s * 2)) $$((s * 2)) $(OBJ)/AppIcon.iconset/icon_512x512@2x.png --out $(OBJ)/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns $(OBJ)/AppIcon.iconset -o $(MENULET_APP)/Contents/Resources/AppIcon.icns
	# The same icon as an asset catalog app icon (CFBundleIconName): Control
	# Center's Edit Controls looks there, not at the .icns.
	mkdir -p $(OBJ)/App.xcassets/AppIcon.appiconset
	cp $(OBJ)/AppIcon.iconset/*.png $(OBJ)/App.xcassets/AppIcon.appiconset/
	printf '{"images":[%s],"info":{"author":"xcode","version":1}}' \
	  "$$(for s in 16 32 128 256 512; do printf '{"idiom":"mac","size":"%sx%s","scale":"1x","filename":"icon_%sx%s.png"},{"idiom":"mac","size":"%sx%s","scale":"2x","filename":"icon_%sx%s@2x.png"},' $$s $$s $$s $$s $$s $$s $$s $$s; done | sed 's/,$$//')" \
	  > $(OBJ)/App.xcassets/AppIcon.appiconset/Contents.json
	printf '{"info":{"author":"xcode","version":1}}' > $(OBJ)/App.xcassets/Contents.json
	xcrun actool $(OBJ)/App.xcassets --compile $(MENULET_APP)/Contents/Resources \
	  --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
	  --output-partial-info-plist $(OBJ)/appicon-info.plist >/dev/null
	plutil -replace CFBundleVersion -string $(BUILD_NUMBER) $(CONTROL_APPEX)/Contents/Info.plist
	sed 's|__GROUP__|$(GROUP)|' $(MENULET_DIR)/$(MENULET).entitlements > $(OBJ)/$(MENULET).entitlements
	sed 's|__GROUP__|$(GROUP)|' $(CONTROL_DIR)/$(CONTROL).entitlements > $(OBJ)/$(CONTROL).entitlements
	swiftc -O -swift-version 5 -framework AppKit -framework IOKit -framework WidgetKit \
	  -o $(MENULET_APP)/Contents/MacOS/$(MENULET) $(MENULET_DIR)/Sources/*.swift $(SHARED)
	# The extension: Foundation's extension main as the entry point, and the
	# compile-time values of its App Intents for the metadata step below.
	plutil -extract constValueProtocols json -o $(OBJ)/protocols.json \
	  $(TOOLCHAIN)/usr/share/swift/SwiftConstantValues/AppIntents.json
	ls $(CONTROL_DIR)/Sources/*.swift $(SHARED) > $(OBJ)/sources.txt
	echo $(OBJ)/$(CONTROL).swiftconstvalues > $(OBJ)/constvalues.txt
	# WidgetKit as the SDK declares it, plus what it leaves out
	# (WidgetKitSPI.swiftinterface), first on the extension's import path.
	mkdir -p $(OBJ)/spi/WidgetKit.swiftmodule
	cat $(SDK)/System/Library/Frameworks/WidgetKit.framework/Modules/WidgetKit.swiftmodule/arm64e-apple-macos.swiftinterface \
	  $(CONTROL_DIR)/WidgetKitSPI.swiftinterface > $(OBJ)/spi/WidgetKit.swiftmodule/arm64e-apple-macos.swiftinterface
	swiftc -O -wmo -swift-version 5 -parse-as-library -application-extension \
	  -target $(CONTROL_TARGET) -module-name $(CONTROL) -I $(OBJ)/spi \
	  -emit-const-values-path $(OBJ)/$(CONTROL).swiftconstvalues \
	  -Xfrontend -const-gather-protocols-file -Xfrontend $(OBJ)/protocols.json \
	  -Xlinker -e -Xlinker _NSExtensionMain \
	  -o $(CONTROL_APPEX)/Contents/MacOS/$(CONTROL) $$(cat $(OBJ)/sources.txt)
	xcrun appintentsmetadataprocessor --output $(CONTROL_APPEX)/Contents/Resources \
	  --toolchain-dir $(TOOLCHAIN) --module-name $(CONTROL) --sdk-root $(SDK) \
	  --xcode-version $(XCODE_BUILD) --platform-family macOS --deployment-target 26.0 \
	  --target-triple $(CONTROL_TARGET) --source-file-list $(OBJ)/sources.txt \
	  --swift-const-vals-list $(OBJ)/constvalues.txt --force
	# The control's battery symbols, generated by `make symbols`.
	xcrun actool $(CONTROL_DIR)/Assets.xcassets --compile $(CONTROL_APPEX)/Contents/Resources \
	  --platform macosx --minimum-deployment-target 26.0 \
	  --output-partial-info-plist $(OBJ)/assets.plist --output-format human-readable-text
	# Inside out: the extension first, then the app that seals it.
	codesign -s "$(SIGN_ID)" --force --timestamp=none \
	  --entitlements $(OBJ)/$(CONTROL).entitlements $(CONTROL_APPEX)
	codesign -s "$(SIGN_ID)" --force --timestamp=none \
	  --entitlements $(OBJ)/$(MENULET).entitlements $(MENULET_APP)

# A per-user LaunchAgent (gui/, no sudo), unlike every other install target
# here: the menulet needs the GUI session and no privileges.
install-menulet: menulet
	mkdir -p $(HOME)/Applications $(HOME)/Library/LaunchAgents
	rm -rf $(MENULET_INSTALLED)
	cp -R $(MENULET_APP) $(MENULET_INSTALLED)
	# Register the installed copy, so Control Center lists the control and
	# the control's tap reaches it, without logging out first.
	$(LSREGISTER) -f $(MENULET_INSTALLED)
	pluginkit -a $(MENULET_INSTALLED)/Contents/PlugIns/$(CONTROL).appex
	sed 's|__APP__|$(MENULET_INSTALLED)|' menulets/launchd/$(MENULET_ID).plist > $(MENULET_AGENT)
	plutil -lint $(MENULET_AGENT)
	-launchctl bootout gui/$$(id -u)/$(MENULET_ID) 2>/dev/null
	# bootout returns before the old instance is gone, and a bootstrap that
	# races it fails, so try once more after a moment.
	launchctl bootstrap gui/$$(id -u) $(MENULET_AGENT) || \
	  { sleep 2; launchctl bootstrap gui/$$(id -u) $(MENULET_AGENT); }

# Run after install-menulet when the control still runs old code: its
# extension (MBatteryControl) outlives the copy and keeps serving the old
# one, and Control Center keeps what it drew, symbols included: it caches
# them by name. macOS starts both again on its own. Waits a moment first for
# macOS to index the new copy.
#
# chronod won't cache the list of controls of a development-signed
# extension, so the restarted Control Center can't find the control and shows
# it as a dashed app placeholder, until Edit Controls is opened, which fetches
# the list live.
reload-control:
	sleep 3
	-killall $(CONTROL) 2>/dev/null
	-killall ControlCenter 2>/dev/null

uninstall-menulet:
	-launchctl bootout gui/$$(id -u)/$(MENULET_ID) 2>/dev/null
	rm -f $(MENULET_AGENT)
	rm -rf $(MENULET_INSTALLED)
