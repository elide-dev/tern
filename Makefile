ELIDE_SOURCE ?= ../elide
# Lua 5.4 from mise (`.mise.toml`) when the shell has not activated it.
LUA ?= $(or $(shell command -v lua 2>/dev/null),mise exec -- lua)

.PHONY: build broker test test-unit fmt check types smoke link repl test-surface android test-android test-android-unit
build: android broker
broker:
	cargo build --release -p elide-tern-broker
	mkdir -p dist
	cp target/release/elide-tern-broker dist/.elide-tern-broker.new
	mv dist/.elide-tern-broker.new dist/elide-tern-broker
	cp target/release/elide-tern-worker dist/.elide-tern-worker.new
	mv dist/.elide-tern-worker.new dist/elide-tern-worker
android:
	bun scripts/build-android.ts
test-android-unit:
	bun test tests/android-elide.test.ts tests/android-sdk.test.ts
test-android: android
	python3 tests/android.py --image "$(ANDROID_IMAGE)" $(if $(ANDROID_SDK),--sdk "$(ANDROID_SDK)")
.PHONY: test-android-run
test-android-run: android
	python3 -u tests/android_run.py --runtime "$(RUNTIME)" --project "$(ANDROID_PROJECT)"
.PHONY: previewing
previewing:
	$(MAKE) -C "$(ELIDE_SOURCE)" build-compose-preview
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/compose_preview" dist/.elide-tern-compose.new
	mv dist/.elide-tern-compose.new dist/elide-tern-compose
.PHONY: test-compose
test-compose: previewing
	python3 -u tests/compose.py --runtime "$(RUNTIME)" --project "$(COMPOSE_PROJECT)" --file "$(COMPOSE_FILE)"
test: test-unit
test-unit: broker
	$(LUA) tests/links.lua
	$(LUA) tests/source.lua
	$(LUA) tests/diagnostics.lua
	$(LUA) tests/shell.lua
	$(MAKE) test-android-unit
	cargo test --workspace
	python3 tests/broker.py
	python3 tests/install.py
fmt:
	cargo fmt -p elide-tern-broker
	stylua plugin/host.luau plugin/window.luau plugin/lib
check:
	cargo fmt -p elide-tern-broker --check
	cargo clippy -p elide-tern-broker --all-targets -- -D warnings
	stylua --check plugin/host.luau plugin/window.luau plugin/lib
types:
	tern plugin types plugin
smoke: build
	python3 tests/broker.py --sdk "$(SDK)"
repl:
	$(MAKE) -C "$(ELIDE_SOURCE)" build-repl-surface
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/embedded_surface" dist/.elide-tern-repl.new
	mv dist/.elide-tern-repl.new dist/elide-tern-repl

link: build
	tern plugin link "$(CURDIR)/plugin"


test-surface: build $(if $(RUNTIME),,repl)
	python3 tests/surface.py --sdk "$(SDK)" $(if $(RUNTIME),--runtime "$(RUNTIME)")

.PHONY: serve test-serve
serve:
	$(MAKE) -C "$(ELIDE_SOURCE)" build-serve-surface
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/serve_surface" dist/.elide-tern-serve.new
	mv dist/.elide-tern-serve.new dist/elide-tern-serve

test-serve: serve
	python3 tests/serve.py $(if $(RUNTIME),--runtime "$(RUNTIME)")

.PHONY: test-telemetry
test-telemetry: serve
	python3 tests/telemetry.py --runtime "$(RUNTIME)"

.PHONY: testing test-testing
testing:
	$(MAKE) -C "$(ELIDE_SOURCE)" build-test-surface
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/test_surface" dist/.elide-tern-test.new
	mv dist/.elide-tern-test.new dist/elide-tern-test

test-testing: testing
	python3 tests/testing.py --runtime "$(RUNTIME)"

.PHONY: test-project
test-project: build
	python3 -u tests/project.py $(if $(SDK),--sdk "$(SDK)") $(if $(RUNTIME),--runtime "$(RUNTIME)") $(if $(PROJECT),--project "$(PROJECT)")

.PHONY: project test-sessions
project:
	$(MAKE) -C "$(ELIDE_SOURCE)" build-project-surface
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/project_surface" dist/.elide-tern-project.new
	mv dist/.elide-tern-project.new dist/elide-tern-project

test-sessions: build project
	python3 tests/sessions.py $(if $(RUNTIME),--runtime "$(RUNTIME)")

.PHONY: test-coverage
test-coverage: build project
	python3 -u tests/coverage.py $(if $(RUNTIME),--runtime "$(RUNTIME)")

.PHONY: debugging test-debug
debugging:
	$(MAKE) -C "$(ELIDE_SOURCE)" build-debug-surface
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/debug_surface" dist/.elide-tern-debug.new
	mv dist/.elide-tern-debug.new dist/elide-tern-debug

test-debug: build
	python3 -u tests/debug.py $(if $(RUNTIME),--runtime "$(RUNTIME)")

.PHONY: building test-building
building:
	$(MAKE) -C "$(ELIDE_SOURCE)" build-build-surface
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/build_surface" dist/.elide-tern-build.new
	mv dist/.elide-tern-build.new dist/elide-tern-build

test-building: building
	python3 -u tests/build.py --runtime "$(RUNTIME)"

.PHONY: running test-running
running:
	$(MAKE) -C "$(ELIDE_SOURCE)" build-run-surface
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/run_surface" dist/.elide-tern-run.new
	mv dist/.elide-tern-run.new dist/elide-tern-run

test-running: running
	python3 -u tests/run.py --runtime "$(RUNTIME)"

.PHONY: installing test-installing
installing:
	$(MAKE) -C "$(ELIDE_SOURCE)" build-install-surface
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/install_surface" dist/.elide-tern-install.new
	mv dist/.elide-tern-install.new dist/elide-tern-install

test-installing: installing
	python3 -u tests/install_surface.py --runtime "$(RUNTIME)"

.PHONY: help test-help
help:
	cd "$(ELIDE_SOURCE)" && PATH=/usr/bin:$$PATH cargo build -p cli --example help_surface
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/help_surface" dist/.elide-tern-help.new
	mv dist/.elide-tern-help.new dist/elide-tern-help

test-help: help
	python3 tests/help.py --runtime "$(RUNTIME)"

.PHONY: test-workspace
test-workspace: build
	python3 -u tests/workspace.py $(if $(HEADLESS),--headless)

.PHONY: test-install
test-install:
	python3 tests/install.py
