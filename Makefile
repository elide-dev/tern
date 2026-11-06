ELIDE_SOURCE ?= ../elide

.PHONY: build test fmt check types smoke link repl test-surface
build:
	cargo build --release -p elide-tern-broker
	mkdir -p dist
	cp target/release/elide-tern-broker dist/.elide-tern-broker.new
	mv dist/.elide-tern-broker.new dist/elide-tern-broker
	cp target/release/elide-tern-worker dist/.elide-tern-worker.new
	mv dist/.elide-tern-worker.new dist/elide-tern-worker
test: build
	cargo test --workspace
	python3 tests/broker.py
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
test-telemetry:
	python3 tests/telemetry.py --runtime "$(RUNTIME)"

.PHONY: testing test-testing
testing:
	$(MAKE) -C "$(ELIDE_SOURCE)" build-test-surface
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/test_surface" dist/.elide-tern-test.new
	mv dist/.elide-tern-test.new dist/elide-tern-test

test-testing:
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
test-coverage: build
	python3 -u tests/coverage.py $(if $(RUNTIME),--runtime "$(RUNTIME)")

.PHONY: debugging test-debug
debugging:
	$(MAKE) -C "$(ELIDE_SOURCE)" build-debug-surface
	mkdir -p dist
	cp "$(ELIDE_SOURCE)/target/debug/examples/debug_surface" dist/.elide-tern-debug.new
	mv dist/.elide-tern-debug.new dist/elide-tern-debug

test-debug: build
	python3 -u tests/debug.py $(if $(RUNTIME),--runtime "$(RUNTIME)")

.PHONY: test-workspace
test-workspace: build
	python3 -u tests/workspace.py $(if $(HEADLESS),--headless)

.PHONY: test-install
test-install:
	python3 tests/install.py
