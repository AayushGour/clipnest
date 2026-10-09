# Clipnest developer entry point. Run `make` (or `make help`) for the target list.
#
# Thin wrappers only: every recipe delegates to an existing script
# (scripts/*.sh, packaging/linux/**) or to the documented command from
# README.md / .claude/coding-standards.md. No build logic lives here.
#
# Linux has no host Swift toolchain by design: builds, tests and .debs run in
# Docker (the same recipes CI uses). macOS targets use the host toolchain.
# Only install-linux / uninstall-linux elevate (pkexec); nothing calls sudo.

SHELL         := bash
.SHELLFLAGS   := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ---------------------------------------------------------------- tunables --
# Override on the command line, e.g. `make deb OUT=/tmp/debs`.

UNAME_S       := $(shell uname -s)
APP_ID        := app.clipnest.Clipnest
BIN_PATH      := /usr/bin/clipnest
PACKAGES      := clipnest clipnest-ocr clipnest-ocr-data

# Version comes from debian/changelog (the packaging source of truth).
VERSION       := $(shell awk -F'[()]' 'NR==1 {print $$2}' debian/changelog)
# Local builds get a strictly-greater version so apt upgrades over a released
# install. Evaluated once per make run; override LOCAL_SUFFIX= to pin it
# (empty = the exact release version, which `tarball` needs).
LOCAL_SUFFIX  ?= +local$(shell date +%Y%m%d%H%M%S)
DEB_SERIES    ?= noble
DEB_ARCH      := $(shell dpkg --print-architecture 2>/dev/null || echo amd64)

OUT           ?= $(CURDIR)/build/linux
TARBALL_OUT   ?= $(OUT)/tarball

# Docker images. The two build images are created on first use from SWIFT_IMAGE.
SWIFT_IMAGE      ?= swift:6.0-$(DEB_SERIES)
BUILD_IMAGE      ?= clipnest-build:latest
DEB_IMAGE        ?= clipnest-deb:latest
VNC_IMAGE        ?= clipnest-vnc:latest
SCRATCH_VOLUME   ?= clipnest-scratch
VNC_PORT         ?= 6080
VNC_DOCKERFILE   := packaging/linux/vnc/Dockerfile

# apt build deps: Package.swift `providers:` + libsqlite3-dev (same list as
# .github/workflows/ci.yml "Install system dependencies").
SWIFT_APT_DEPS := pkg-config libgtk-4-dev libx11-dev libxfixes-dev libxtst-dev libsqlite3-dev
DEB_APT_DEPS   := build-essential debhelper devscripts dpkg-dev fakeroot $(SWIFT_APT_DEPS)

# Swift sources linted by swift-format (coding-standards.md "Formatter / linter").
CORE_PATHS     := Sources Tests
APP_PATHS      := ClipnestApp/Sources

XCODE_PROJECT  := ClipnestApp/ClipnestApp.xcodeproj

# A SEPARATE scratch volume for .build: the host .build mixes static-stdlib and
# normal artifacts, and Linux containers must not clobber it.
DOCKER_RUN_SRC := docker run --rm -v "$(CURDIR)":/src -v $(SCRATCH_VOLUME):/src/.build -w /src

# ------------------------------------------------------------ guards --------
# $(call require-os,Linux) / $(call require-cmd,docker): fail clearly.
require-os  = $(if $(filter $(1),$(UNAME_S)),,$(error 'make $@' is $(1)-only (this machine is $(UNAME_S))))
require-cmd = $(if $(shell command -v $(1)),,$(error '$(1)' not found on PATH (needed by 'make $@')))

# ------------------------------------------------------------------ help ----
.PHONY: help
help: ## Show this list
	@echo "Clipnest $(VERSION) -- host: $(UNAME_S)"; echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-16s %s\n", $$1, $$2}'
	@echo; echo "Only install-linux and uninstall-linux elevate (pkexec GUI password prompt). Override vars: make deb OUT=/tmp/debs"

# ----------------------------------------------------------------- tests ----
.PHONY: test test-linux test-mac
test: ## Run unit tests (host swift on macOS, Docker on Linux)
ifeq ($(UNAME_S),Darwin)
	@$(MAKE) --no-print-directory test-mac
else
	@$(MAKE) --no-print-directory test-linux
endif

test-linux: ## Run `swift test` in Docker (Linux)
	@$(call require-os,Linux)
	@$(MAKE) --no-print-directory images-build
	$(DOCKER_RUN_SRC) $(BUILD_IMAGE) swift test

test-mac: ## Run `swift test` on the host (macOS)
	@$(call require-os,Darwin)
	swift test

# ------------------------------------------------------------- lint/format --
.PHONY: lint format
lint: ## swift-format lint --strict via scripts/lint.sh (Docker on Linux; CI's pinned binary)
ifeq ($(UNAME_S),Darwin)
	scripts/lint.sh $(CORE_PATHS)
	swift format lint --recursive --strict $(APP_PATHS)
else
	@$(MAKE) --no-print-directory images-build
	$(DOCKER_RUN_SRC) $(BUILD_IMAGE) scripts/lint.sh $(CORE_PATHS)
endif

format: ## swift-format auto-fix in place (macOS host toolchain)
	@$(call require-os,Darwin)
	swift format format --in-place --recursive $(CORE_PATHS) $(APP_PATHS)

# ----------------------------------------------------------------- build ----
.PHONY: build build-linux build-mac
build: ## Build for this OS (debug in Docker on Linux, Release .app on macOS)
ifeq ($(UNAME_S),Darwin)
	@$(MAKE) --no-print-directory build-mac
else
	@$(MAKE) --no-print-directory build-linux
endif

build-linux: ## `swift build` in Docker (Linux)
	@$(call require-os,Linux)
	@$(MAKE) --no-print-directory images-build
	$(DOCKER_RUN_SRC) $(BUILD_IMAGE) swift build

build-mac: ## xcodegen + archive -> build/Clipnest.app (scripts/build.sh; macOS)
	@$(call require-os,Darwin)
	scripts/build.sh

# ------------------------------------------------------- Linux packaging ----
.PHONY: deb tarball
deb: ## Build local .debs into OUT (changelog version + LOCAL_SUFFIX, series DEB_SERIES; Docker)
	@$(call require-cmd,docker)
	@$(MAKE) --no-print-directory images-deb
	mkdir -p "$(OUT)"
	rm -rf "$(OUT)/src" && mkdir -p "$(OUT)/src"
	git archive HEAD | tar -x -C "$(OUT)/src"
	docker run --rm -v "$(OUT)":/build -w /build/src $(DEB_IMAGE) bash -c \
	  'dch -v "$(VERSION)$(LOCAL_SUFFIX)" -D $(DEB_SERIES) "Local build." && dpkg-buildpackage -us -uc -b -d; rc=$$?; chown -R $(shell id -u):$(shell id -g) /build; exit $$rc'
	rm -rf "$(OUT)/src"
	@echo; echo "Built in $(OUT):"; ls "$(OUT)"/*.deb

tarball: ## Release tarball from release-version .debs in OUT (LOCAL_SUFFIX= make deb first)
	@$(call require-os,Linux)
	packaging/linux/dist/build-tarball.sh "$(VERSION)" "$(DEB_ARCH)" "$(OUT)" "$(TARBALL_OUT)"

# ------------------------------------------------ Linux install / run -------
.PHONY: install-linux uninstall-linux run restart logs
install-linux: ## Build .debs, install them (pkexec prompt), restart the app
	@$(call require-os,Linux)
	rm -f "$(OUT)"/*.deb
	@$(MAKE) --no-print-directory deb
	pkexec apt-get install -y $(foreach p,$(PACKAGES),$$(ls "$(OUT)"/$(p)_*.deb))
	@$(MAKE) --no-print-directory restart

uninstall-linux: ## Remove the installed packages (pkexec prompt)
	@$(call require-os,Linux)
	pkexec apt-get remove -y $(PACKAGES)

run: ## Launch the installed app (Linux)
	@$(call require-os,Linux)
	gtk-launch $(APP_ID)

restart: ## Kill and relaunch the installed app (Linux)
	@$(call require-os,Linux)
	pkill -f '^$(BIN_PATH)' || true
	gtk-launch $(APP_ID)

logs: ## Follow the installed app's journal (Linux)
	@$(call require-os,Linux)
	journalctl --user -t $(APP_ID) -f

# ------------------------------------------------------------ macOS ship ----
.PHONY: install-mac dmg
install-mac: ## Build + sign with local dev identity + install (run scripts/dev-cert.sh once first)
	@$(call require-os,Darwin)
	scripts/dev-install.sh

dmg: ## Build and package build/Clipnest.dmg (sign/notarize via scripts/ for a release)
	@$(call require-os,Darwin)
	scripts/build.sh
	scripts/package_dmg.sh

# ------------------------------------------------------------------- dev ----
.PHONY: dev-linux dev-mac
dev-linux: ## Build this tree into the VNC container and run it (http://localhost:VNC_PORT/vnc.html)
	@$(call require-cmd,docker)
	docker build -f $(VNC_DOCKERFILE) -t $(VNC_IMAGE) .
	@echo "Open http://localhost:$(VNC_PORT)/vnc.html  (Ctrl+C stops and removes the container)"
	docker run --rm -it -p $(VNC_PORT):6080 $(VNC_IMAGE)

dev-mac: ## Generate the Xcode project and open it (macOS)
	@$(call require-os,Darwin)
	@$(call require-cmd,xcodegen)
	cd ClipnestApp && xcodegen generate
	open $(XCODE_PROJECT)

# ----------------------------------------------------- docker build images --
# Created on first use from SWIFT_IMAGE, reused afterwards. `make images-rebuild`
# refreshes them. Both carry the same toolchain; the split keeps existing names.
define IMAGE_DOCKERFILE
FROM $(SWIFT_IMAGE)
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $(DEB_APT_DEPS) && rm -rf /var/lib/apt/lists/*
endef
export IMAGE_DOCKERFILE

.PHONY: images-build images-deb images-rebuild
images-build images-deb: images-%:
	@$(call require-cmd,docker)
	@img=$(if $(filter build,$*),$(BUILD_IMAGE),$(DEB_IMAGE)); \
	  if ! docker image inspect $$img >/dev/null 2>&1; then echo "Creating $$img ..."; printf "%s\n" "$$IMAGE_DOCKERFILE" | docker build -t $$img -; fi

images-rebuild: ## Recreate the Docker build images from scratch
	docker rmi $(BUILD_IMAGE) $(DEB_IMAGE) || true
	@$(MAKE) --no-print-directory images-build images-deb

# ----------------------------------------------------------------- clean ----
.PHONY: clean
clean: ## Remove build/ and the Docker scratch volume (images are kept)
	rm -rf build
	docker volume rm $(SCRATCH_VOLUME) >/dev/null 2>&1 || true
