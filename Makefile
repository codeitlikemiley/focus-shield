SHELL := /bin/bash

APP_NAME := Focus Shield
APP_PATH := /Applications/$(APP_NAME).app
SWIFT_ENV := env HOME=/tmp CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/clang-module-cache
SIMULATOR ?= iPhone 16
TEAM_ID ?=

ifneq (,$(wildcard .env))
include .env
export
endif

.DEFAULT_GOAL := help

.PHONY: help advanced build release install run open clean verify \
	run-local rebuild scripts generate-xcode open-xcode \
	build-ios run-ios list-sims build-macos-signed install-macos-signed run-macos-signed archive-macos archive-ios \
	uninstall aliases diagnose

help:
	@echo "FocusShield Common Commands"
	@echo ""
	@echo "  make build              Build debug binary with SwiftPM (no system extension)"
	@echo "  make install            Install the macOS app bundle"
	@echo "                          Uses signed Xcode build automatically when TEAM_ID is set"
	@echo "  make run                Install and open the macOS app"
	@echo "                          Uses signed Xcode build automatically when TEAM_ID is set"
	@echo "  make open               Open the installed app"
	@echo "  make verify             Run build and shell-script checks"
	@echo "  make release            Build release binary with SwiftPM (no system extension)"
	@echo "  make clean              Remove SwiftPM build artifacts"
	@echo "  make uninstall          Remove installed app and helper"
	@echo ""
	@echo "  make advanced           Show less-used commands"

advanced:
	@echo "FocusShield Advanced Commands"
	@echo ""
	@echo "  make run-local          Run the local debug binary directly"
	@echo "  make rebuild            Clean then build"
	@echo "  make scripts            Validate shell scripts with bash -n"
	@echo "  make aliases            Refresh CLI wrapper aliases"
	@echo "  make diagnose           Print a macOS enforcement diagnostic report"
	@echo "  make generate-xcode     Regenerate FocusShield.xcodeproj"
	@echo "  make open-xcode         Open the Xcode project"
	@echo "  make list-sims          List available iOS simulators"
	@echo "  make build-ios          Build iOS app for SIMULATOR=\"$(SIMULATOR)\""
	@echo "  make run-ios            Build and launch on SIMULATOR=\"$(SIMULATOR)\""
	@echo "  make build-macos-signed Build signed macOS app (uses .env TEAM_ID)"
	@echo "  make install-macos-signed Install signed macOS app (uses .env TEAM_ID)"
	@echo "  make run-macos-signed  Install and open signed macOS app (uses .env TEAM_ID)"
	@echo "  make archive-macos      Archive macOS app (uses .env TEAM_ID)"
	@echo "  make archive-ios        Archive iOS app (uses .env TEAM_ID)"

build:
	$(SWIFT_ENV) swift build

release:
	$(SWIFT_ENV) swift build -c release

install:
ifeq ($(strip $(TEAM_ID)),)
	./install.sh
else
	./build.sh install-macos-signed "$(TEAM_ID)"
endif

open:
	open -a "$(APP_PATH)"

run: install
	open -a "$(APP_PATH)"

run-local: build
	"$$($(SWIFT_ENV) swift build --show-bin-path)/FocusShield"

clean:
	$(SWIFT_ENV) swift package clean

rebuild: clean build

scripts:
	bash -n install.sh
	bash -n update_aliases.sh
	bash -n focusshield-cli-guard.sh

verify: build scripts

aliases:
	./update_aliases.sh

generate-xcode:
	./build.sh generate

open-xcode:
	open FocusShield.xcodeproj

list-sims:
	./build.sh list-sims

build-ios:
	./build.sh build-ios "$(SIMULATOR)"

run-ios:
	./build.sh run-ios "$(SIMULATOR)"

build-macos-signed:
	@if [ -z "$(TEAM_ID)" ]; then echo "TEAM_ID is required"; exit 1; fi
	./build.sh build-macos-signed "$(TEAM_ID)"

install-macos-signed:
	@if [ -z "$(TEAM_ID)" ]; then echo "TEAM_ID is required"; exit 1; fi
	./build.sh install-macos-signed "$(TEAM_ID)"

run-macos-signed:
	@if [ -z "$(TEAM_ID)" ]; then echo "TEAM_ID is required"; exit 1; fi
	./build.sh run-macos-signed "$(TEAM_ID)"

archive-macos:
	@if [ -z "$(TEAM_ID)" ]; then echo "TEAM_ID is required"; exit 1; fi
	./build.sh archive-macos "$(TEAM_ID)"

archive-ios:
	@if [ -z "$(TEAM_ID)" ]; then echo "TEAM_ID is required"; exit 1; fi
	./build.sh archive-ios "$(TEAM_ID)"

uninstall:
	./install.sh --uninstall

diagnose:
	@echo ""
	@echo "═══════════════════════════════════════════════"
	@echo "  FocusShield Enforcement Diagnostic Report"
	@echo "═══════════════════════════════════════════════"
	@echo ""
	@echo "── Helper & Sudoers ──"
	@printf "  Helper binary:   "; [ -f /usr/local/bin/focusshield-helper ] && echo "✅ Present" || echo "❌ Missing"
	@printf "  Sudoers file:    "; [ -f /etc/sudoers.d/focusshield ] && echo "✅ Present" || echo "❌ Missing"
	@printf "  Alias manager:   "; [ -f /usr/local/lib/focusshield/update_aliases.sh ] && echo "✅ Present" || echo "❌ Missing"
	@printf "  CLI guard:       "; [ -f /usr/local/lib/focusshield/focusshield-cli-guard ] && echo "✅ Present" || echo "❌ Missing"
	@printf "  DNS proxy:       "; [ -f /usr/local/bin/focusshield-dns ] && echo "✅ Present" || echo "❌ Missing"
	@echo ""
	@echo "── Network Extension ──"
	@printf "  App bundle:      "; [ -d "$(APP_PATH)" ] && echo "✅ Present" || echo "❌ Missing"
	@FOCUS_LINE=$$(systemextensionsctl list 2>/dev/null | grep -F "com.focusshield.macos.filter-data" || true); \
	 if [ -n "$$FOCUS_LINE" ]; then \
	   echo "  System extension: $$FOCUS_LINE"; \
	 else \
	   echo "  System extension: — Not listed"; \
	 fi
	@echo ""
	@echo "── PAC Proxy ──"
	@PAC_DIR="$$HOME/Library/Application Support/FocusShield"; \
	 PAC_FILE="$$PAC_DIR/proxy.pac"; \
	 if [ -f "$$PAC_FILE" ]; then \
	   echo "  PAC file: ✅ Present ($$PAC_FILE)"; \
	   echo "  First 5 lines:"; \
	   head -5 "$$PAC_FILE" | sed 's/^/    /'; \
	   if grep -q 'PROXY 127.0.0.1:9' "$$PAC_FILE" 2>/dev/null; then \
	     echo "  PAC health: ✅ Contains blocking rules"; \
	   else \
	     echo "  PAC health: ⚠️  No blocking rules found (DIRECT-only or empty)"; \
	   fi; \
	 else \
	   echo "  PAC file: ❌ Missing"; \
	 fi
	@echo ""
	@echo "── System Proxy (scutil) ──"
	@scutil --proxy 2>/dev/null | grep -E 'ProxyAutoConfig|URL' | sed 's/^/  /' || echo "  ⚠️  Could not read proxy config"
	@echo ""
	@echo "── Managed Browser Policies ──"
	@printf "  Chrome:    "; [ -f "/Library/Managed Preferences/com.google.Chrome.plist" ] && echo "✅ Present" || echo "— Not installed"
	@printf "  Chromium:  "; [ -f "/Library/Managed Preferences/org.chromium.Chromium.plist" ] && echo "✅ Present" || echo "— Not installed"
	@printf "  Brave:     "; [ -f "/Library/Managed Preferences/com.brave.Browser.plist" ] && echo "✅ Present" || echo "— Not installed"
	@printf "  Edge:      "; [ -f "/Library/Managed Preferences/com.microsoft.edgemac.plist" ] && echo "✅ Present" || echo "— Not installed"
	@printf "  Firefox:   "; [ -f "/Library/Application Support/Mozilla/managed-policies.json" ] && echo "✅ Present" || echo "— Not installed"
	@echo ""
	@echo "── DNS Proxy Status ──"
	@PID_FILE="/tmp/focusshield-dns.pid"; \
	 if [ -f "$$PID_FILE" ]; then \
	   DNS_PID=$$(cat "$$PID_FILE"); \
	   if kill -0 "$$DNS_PID" 2>/dev/null; then \
	     echo "  DNS proxy: ✅ Running (PID $$DNS_PID)"; \
	   else \
	     echo "  DNS proxy: ⚠️  PID file exists but process not running"; \
	   fi; \
	 else \
	   echo "  DNS proxy: — Not running (no PID file)"; \
	 fi
	@echo ""
	@echo "── Active Profile (SQLite) ──"
	@DB_PATH="$$HOME/Library/Application Support/FocusShield/focusshield.sqlite"; \
	 if [ -f "$$DB_PATH" ]; then \
	   echo "  Database: ✅ Present"; \
	   ACTIVE_ID=$$(sqlite3 "$$DB_PATH" "SELECT activeProfileID FROM settings WHERE id = 1 LIMIT 1" 2>/dev/null || echo ""); \
	   ENABLED=$$(sqlite3 "$$DB_PATH" "SELECT masterEnabled FROM settings WHERE id = 1 LIMIT 1" 2>/dev/null || echo ""); \
	   if [ -n "$$ACTIVE_ID" ] && [ "$$ACTIVE_ID" != "" ]; then \
	     PROFILE_NAME=$$(sqlite3 "$$DB_PATH" "SELECT name FROM profiles WHERE id=$$ACTIVE_ID" 2>/dev/null || echo "unknown"); \
	     echo "  Active profile: $$PROFILE_NAME (ID $$ACTIVE_ID)"; \
	     echo "  Master enabled: $$ENABLED"; \
	     APP_RULES=$$(sqlite3 "$$DB_PATH" "SELECT COUNT(*) FROM app_rules WHERE profileID=$$ACTIVE_ID" 2>/dev/null || echo 0); \
	     CLI_RULES=$$(sqlite3 "$$DB_PATH" "SELECT COUNT(*) FROM app_rules WHERE profileID=$$ACTIVE_ID AND ruleType='cliTool'" 2>/dev/null || echo 0); \
	     DOMAIN_RULES=$$(sqlite3 "$$DB_PATH" "SELECT COUNT(*) FROM domain_rules WHERE profileID=$$ACTIVE_ID" 2>/dev/null || echo 0); \
	     echo "  App rules: $$APP_RULES, CLI rules: $$CLI_RULES, Domain rules: $$DOMAIN_RULES"; \
	   else \
	     echo "  Active profile: — None set"; \
	   fi; \
	 else \
	   echo "  Database: ❌ Missing"; \
	 fi
	@echo ""
	@echo "═══════════════════════════════════════════════"
