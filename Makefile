# Familygram task runner. Tab-indented (real tabs). `make help` lists targets.

SHELL              := /bin/bash
.SHELLFLAGS        := -eu -o pipefail -c
export ANDROID_HOME := $(HOME)/develop/android-sdk
export PATH        := $(HOME)/develop/flutter/bin:$(ANDROID_HOME)/emulator:$(ANDROID_HOME)/platform-tools:$(ANDROID_HOME)/cmdline-tools/latest/bin:$(PATH)

MOBILE      := mobile
BACKEND     := backend

# Gitignored personal overrides — see scripts/dev.env.mk.example.
-include scripts/dev.env.mk

# Android emulator can't see Mac localhost; its loopback is itself. 10.0.2.2
# is the standard emulator → host alias.
DEV_API_BASE         ?= http://localhost:8787
DEV_API_BASE_ANDROID ?= http://10.0.2.2:8787
DEV_ORY_BASE         ?= https://<your-ory-project>.projects.oryapis.com

# Real deployment values live in wrangler.local.jsonc (gitignored). When
# absent, falls back to the template — which has placeholder values and will
# fail at deploy time, by design.
WRANGLER_CONFIG := $(shell test -f $(BACKEND)/wrangler.local.jsonc && echo wrangler.local.jsonc || echo wrangler.jsonc)

DART_DEFINES         := --dart-define=API_BASE=$(DEV_API_BASE) --dart-define=ORY_BASE=$(DEV_ORY_BASE)
DART_DEFINES_ANDROID := --dart-define=API_BASE=$(DEV_API_BASE_ANDROID) --dart-define=ORY_BASE=$(DEV_ORY_BASE)

# Production URLs + ASC keys come from scripts/ship.env (gitignored), sourced
# into the recipe shell by every build-/ship- target.
SHIP_ENV    := set -a && . scripts/ship.env && set +a

.DEFAULT_GOAL := help
.PHONY: help setup deps pods clean dev dev-ios dev-android sim sim-ios sim-android \
        worker worker-migrate worker-migrate-prod worker-deploy \
        analyze tc icon splash arch-diagram \
        build build-ios build-android \
        ship ship-ios ship-android \
        release-doc release-note release-note-add

help:  ## Show this help.
	@printf "Familygram \033[1mtargets\033[0m\n\n"
	@awk 'BEGIN { FS = ":.*?## " } /^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\nDev URLs:\n"
	@printf "  iOS / web         API_BASE=%s\n" "$(DEV_API_BASE)"
	@printf "  Android emulator  API_BASE=%s  (10.0.2.2 = host loopback inside the emulator)\n" "$(DEV_API_BASE_ANDROID)"
	@printf "  ORY_BASE=%s\n" "$(DEV_ORY_BASE)"
	@printf "Prod URLs live in scripts/ship.env and are sourced automatically.\n"

setup: deps pods  ## One-time after fresh clone: install all deps.

deps:  ## Install Flutter and Worker dependencies.
	cd $(MOBILE)  && flutter pub get
	cd $(BACKEND) && npm install

pods:  ## (Re)install iOS native pods.
	cd $(MOBILE)/ios && pod install

clean:  ## Wipe Flutter build artifacts + iOS Pods. Use before a fresh rebuild.
	cd $(MOBILE) && flutter clean
	rm -rf $(MOBILE)/ios/Pods $(MOBILE)/ios/Podfile.lock $(MOBILE)/ios/.symlinks

dev:  ## Run the app on whatever device flutter picks (iPhone sim or Android emulator if booted).
	cd $(MOBILE) && flutter run $(DART_DEFINES)

dev-ios:  ## Run the app on the first connected iOS device or simulator.
	@dev=$$(xcrun simctl list devices booted | grep -E "Booted" | head -1 | sed 's/.*(\([0-9A-F-]*\)).*/\1/'); \
	if [ -z "$$dev" ]; then echo "No iOS simulator booted — run \`make sim-ios\` first."; exit 1; fi; \
	cd $(MOBILE) && flutter run $(DART_DEFINES) -d "$$dev"

dev-android:  ## Run the app on the first connected Android device or emulator.
	@dev=$$(adb devices | awk '$$2=="device" {print $$1; exit}'); \
	if [ -z "$$dev" ]; then echo "No Android device or emulator detected — run 'make sim-android' first."; exit 1; fi; \
	cd $(MOBILE) && flutter run $(DART_DEFINES_ANDROID) -d "$$dev"

sim: sim-ios  ## Alias for `make sim-ios`.

sim-ios:  ## Boot an iOS simulator (first available iPhone) if none is running.
	@booted=$$(xcrun simctl list devices booted | grep -E "Booted" | head -1 | sed 's/.*(\([0-9A-F-]*\)).*/\1/'); \
	if [ -z "$$booted" ]; then \
	  device=$$(xcrun simctl list devices available | grep -E "iPhone [0-9]" | head -1 | sed 's/.*(\([0-9A-F-]*\)).*/\1/'); \
	  xcrun simctl boot "$$device"; \
	  open -a Simulator; \
	  echo "Booted $$device"; \
	else \
	  echo "Already booted: $$booted"; \
	  open -a Simulator; \
	fi

sim-android:  ## Boot the Android emulator. Prefers AVD "familygram-playstore" if present.
	@running=$$(adb devices 2>/dev/null | awk '/^emulator-.*device$$/ {print $$1; exit}'); \
	if [ -n "$$running" ]; then echo "Emulator already running: $$running"; exit 0; fi; \
	avd=$$(emulator -list-avds 2>/dev/null | awk '\
	  $$0 == "familygram-playstore" { pref = $$0 } \
	  NR == 1 { first = $$0 } \
	  END { print (pref != "" ? pref : first) }'); \
	if [ -z "$$avd" ]; then \
	  echo "No Android AVD found. See docs/ANDROID_RELEASE.md to create one."; exit 1; \
	fi; \
	echo "Booting $$avd ..."; \
	nohup emulator -avd "$$avd" >/dev/null 2>&1 &
	@echo "Tip: wait ~15 seconds for the emulator to finish booting, then run 'make dev-android'."

worker:  ## Start `wrangler dev` (local Worker on :8787, local D1/R2 emulation).
	cd $(BACKEND) && npx wrangler dev -c $(WRANGLER_CONFIG)

worker-migrate:  ## Apply pending D1 migrations to the LOCAL database.
	cd $(BACKEND) && npx wrangler d1 migrations apply familygram --local -c $(WRANGLER_CONFIG)

worker-migrate-prod:  ## Apply pending D1 migrations to PRODUCTION.
	@if [ ! -f $(BACKEND)/wrangler.local.jsonc ]; then \
	  echo "Refusing to migrate prod — $(BACKEND)/wrangler.local.jsonc is missing."; \
	  echo "Copy $(BACKEND)/wrangler.jsonc → $(BACKEND)/wrangler.local.jsonc and fill in real values first."; \
	  exit 2; \
	fi
	cd $(BACKEND) && npx wrangler d1 migrations apply familygram --remote -c wrangler.local.jsonc

worker-deploy:  ## Deploy the Worker to Cloudflare (production).
	@if [ ! -f $(BACKEND)/wrangler.local.jsonc ]; then \
	  echo "Refusing to deploy — $(BACKEND)/wrangler.local.jsonc is missing."; \
	  echo "Copy $(BACKEND)/wrangler.jsonc → $(BACKEND)/wrangler.local.jsonc and fill in real values first."; \
	  exit 2; \
	fi
	cd $(BACKEND) && npx wrangler deploy -c wrangler.local.jsonc

analyze:  ## flutter analyze (mobile) — fast lint pass.
	cd $(MOBILE) && flutter analyze

tc:  ## Typecheck both the Worker (tsc) and Flutter (analyze).
	cd $(BACKEND) && npx tsc --noEmit
	cd $(MOBILE)  && flutter analyze

icon:  ## Regenerate the app icon source PNG + full iOS + Android icon set.
	cd $(MOBILE) && dart run tool/generate_icon.dart && dart run flutter_launcher_icons

splash:  ## Regenerate the iOS + Android launch screens from pubspec config.
	cd $(MOBILE) && dart run flutter_native_splash:create

arch-diagram:  ## Re-render docs/images/architecture.svg from the Mermaid source.
	npx -y --package=@mermaid-js/mermaid-cli mmdc \
	  -i docs/images/architecture.mmd \
	  -o docs/images/architecture.svg \
	  --iconPacks @iconify-json/logos @iconify-json/simple-icons \
	  -b white

build: build-ios build-android  ## Build release IPA + AAB. No version bump, no upload.

build-ios:  ## flutter build ipa --release (with prod URLs from ship.env).
	$(SHIP_ENV) && cd $(MOBILE) && flutter build ipa --release \
	  --dart-define=API_BASE="$$API_BASE" --dart-define=ORY_BASE="$$ORY_BASE"
	@echo "▸ IPA: $(MOBILE)/build/ios/ipa/*.ipa"

build-android:  ## flutter build appbundle --release (with prod URLs from ship.env).
	$(SHIP_ENV) && cd $(MOBILE) && flutter build appbundle --release \
	  --dart-define=API_BASE="$$API_BASE" --dart-define=ORY_BASE="$$ORY_BASE"
	@echo "▸ AAB: $(MOBILE)/build/app/outputs/bundle/release/app-release.aab"

ship: VERSION ?=
ship:  ## Auto-generate release notes, build + upload to TestFlight and Play Console. Optional VERSION=x.y.z.
	@if [ -z "$(VERSION)" ]; then \
	  echo "VERSION=x.y.z is required for `make ship` (so we know what release-notes entry to create)."; \
	  exit 2; \
	fi
	@echo "▸ Generating release-notes entry for v$(VERSION)…"
	@./scripts/add-release-note.sh $(VERSION) || true
	@RELEASE_NOTES="$$(./scripts/release-notes-body.sh $(VERSION))"; \
	  export RELEASE_NOTES; \
	  $(MAKE) ship-ios VERSION=$(VERSION) && \
	  $(MAKE) ship-android

ship-ios:  ## Bump build number, build IPA, upload to TestFlight. Optional VERSION=x.y.z.
	VERSION=$(VERSION) RELEASE_NOTES="$$RELEASE_NOTES" ./scripts/ship-testflight.sh

ship-android:  ## Build the Android AAB and upload to Play Console (Internal testing by default). Optional TRACK=alpha|beta|production.
	$(SHIP_ENV) && cd $(MOBILE) && flutter build appbundle --release \
	  --dart-define=API_BASE="$$API_BASE" --dart-define=ORY_BASE="$$ORY_BASE"
	@if [ ! -d scripts/node_modules ]; then \
	  echo "▸ Installing scripts/ deps (one-time)…"; \
	  cd scripts && npm install --silent; \
	fi
	@RELEASE_NOTES="$$RELEASE_NOTES" node scripts/ship-playstore.js $(TRACK)

release-doc:  ## Open the TestFlight release doc.
	open scripts/RELEASE.md

release-note:  ## Open docs/RELEASE_NOTES.md in $EDITOR.
	@editor=$${EDITOR:-$${VISUAL:-open}}; $$editor docs/RELEASE_NOTES.md

release-note-add:  ## Auto-generate a new entry from commits since the last release. Optional VERSION=x.y.z to override.
	./scripts/add-release-note.sh $(VERSION)
