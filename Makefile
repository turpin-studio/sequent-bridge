# Sequent: the bridge between DJ gear and the apps that follow it.
# `make test` runs the self-tests; `make app`, `make dmg` and `make deb` build.

.PHONY: test app dmg image deb record replay compare

# The Linux bridge's self-test, and the recording replayer's tests. The Mac
# app's self-tests need a build: make app && python3 tools/check_app.py build/Sequent.app
# && python3 tools/check_lead.py build/Sequent.app
test:
	@python3 tools/check_app.py helper/linux/sequent
	@python3 -m unittest discover -s tests

# Sequent.app, the CDJ connection as a Mac menu-bar app (helper/mac), built
# for Apple silicon and Intel with the command-line tools; no Xcode needed.
# Signed ad hoc by default: built here it just opens, but downloaded it needs
# System Settings > Privacy & Security > Open Anyway the first time. The
# pipeline passes SIGN, a Developer ID Application identity, and signs with
# the hardened runtime and a secure timestamp, as notarising requires.
APP := build/Sequent.app
SIGN ?= -
# Ad hoc can take neither the hardened runtime nor a timestamp from Apple.
SIGN_FLAGS := $(if $(filter -,$(SIGN)),,--options runtime --timestamp)
# The app's version and build number, stamped into its Info.plist. The
# release pipeline sets APP_VERSION from the app-v<version> tag. macOS wants
# the version as at most three integers, so a build that isn't a release says
# 0.0.0 and is told apart by its build number, the commit count.
APP_VERSION ?= 0.0.0
APP_BUILD ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

app:
	@rm -rf $(APP) build/icon.iconset && mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources build/icon.iconset
	@swiftc -O -swift-version 5 -target arm64-apple-macos13 -o build/Sequent-arm64 helper/mac/main.swift
	@swiftc -O -swift-version 5 -target x86_64-apple-macos13 -o build/Sequent-x86_64 helper/mac/main.swift
	@lipo -create -output $(APP)/Contents/MacOS/Sequent build/Sequent-arm64 build/Sequent-x86_64
	@cp helper/mac/Info.plist $(APP)/Contents/
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(APP_VERSION)" -c "Set :CFBundleVersion $(APP_BUILD)" $(APP)/Contents/Info.plist
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s helper/icon-512.png --out build/icon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) helper/icon-512.png --out build/icon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	@iconutil -c icns build/icon.iconset -o $(APP)/Contents/Resources/AppIcon.icns
	@codesign --force $(SIGN_FLAGS) --sign "$(SIGN)" $(APP)
	@echo "Built $(APP). Open it with: open $(APP)"

# The disk image people install from: drag Sequent onto Applications. Needs
# dmgbuild (`pip install dmgbuild`); the pipeline installs it.
# `image` makes it from the app already built, which the pipeline needs, since
# it notarises and staples the app before putting it in the image.
DMGBUILD ?= dmgbuild
dmg: app image
image:
	@tiffutil -cathidpicheck helper/mac/dmg/background.png helper/mac/dmg/background@2x.png -out build/dmg-background.tiff
	@rm -f build/Sequent.dmg
	@$(DMGBUILD) -s helper/mac/dmg/settings.py -D app=$(APP) -D background=build/dmg-background.tiff Sequent build/Sequent.dmg >/dev/null
	@$(if $(filter -,$(SIGN)),,codesign --force --timestamp --sign "$(SIGN)" build/Sequent.dmg)
	@echo "Built build/Sequent.dmg"

# The Linux helper (helper/linux), the same job as Sequent.app in the tray, as
# a Debian package for any processor. Plain Python builds it, so it builds
# here too; .github/workflows/linux.yml installs and runs it on Debian and
# Ubuntu. A build that isn't a release is 0.0.0-dev.<commit count>.
DEB_VERSION ?= 0.0.0-dev.$(APP_BUILD)
deb:
	@python3 tools/check_app.py helper/linux/sequent
	@python3 tools/build_deb.py $(DEB_VERSION) build/Sequent-$(DEB_VERSION).deb

# The decks' Pro DJ Link traffic, recorded with Sequent.app running and
# played back into it later, so the page follows decks that aren't there.
# make record NAME=set1 [SECONDS=120]; make replay FILE=set1 [LOOP=1]
record:
	@tools/djlink-record.sh $(or $(NAME),$(shell date +%Y-%m-%d-%H%M)) $(or $(SECONDS),120)
replay:
	@python3 tools/djlink_replay.py $(or $(FILE),two-decks-2026-10-08) $(if $(LOOP),--loop)

# What changed between two recordings, type by type: make compare OLD=... NEW=...
compare:
	@python3 tools/compare_recordings.py $(OLD) $(NEW)
