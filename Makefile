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

link: build repl
	tern plugin link "$(CURDIR)/plugin"


test-surface: build repl
	python3 tests/surface.py --sdk "$(SDK)"
