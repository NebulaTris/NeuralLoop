# One command for every check: `make check`. Run `make setup` once first.
PY ?= python3
CARGO_ENV ?=
# Swift Testing ships with Xcode; with only the Command Line Tools, point swift at their frameworks.
CLT := /Library/Developer/CommandLineTools/Library/Developer
SWIFT_FLAGS := $(if $(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),-Xswiftc -F$(CLT)/Frameworks -Xlinker -F$(CLT)/Frameworks -Xlinker -rpath -Xlinker $(CLT)/Frameworks -Xlinker -rpath -Xlinker $(CLT)/usr/lib,)

.PHONY: setup test check lint site app runtime mac package

setup:            ## install dev tools for every part
	cd pipeline && $(PY) -m pip install -e ".[dev]" playwright && $(PY) -m playwright install chromium
	cd pipeline/site && npm install
	npm install

site:             ## rebuild the study site bundle (pipeline/site/app.js)
	cd pipeline/site && npm run build

test: site        ## all tests: Python, JavaScript, Rust, Swift, and browser tests
	cd pipeline && $(PY) -m pytest -q
	cd pipeline/site && npm test
	cd src && npm test
	PYTHONPATH=pipeline $(PY) -m pytest -q tests
	cd src-tauri && $(CARGO_ENV) cargo test --lib
	@if command -v swift >/dev/null; then cd apple && swift test $(SWIFT_FLAGS); \
	else echo "Swift tests skipped: no swift here (CI runs them on macOS)"; fi

lint:             ## formatting and linters
	cd pipeline && ruff check . && ruff format --check .
	cd pipeline/site && npx prettier --check src test
	cd src-tauri && $(CARGO_ENV) cargo fmt --check && $(CARGO_ENV) cargo clippy --all-targets -- -D warnings

check: lint test  ## what CI runs

app:              ## build the desktop app for this computer
	npm run build

package:          ## NeuralLoop.app with the runtime inside, in dist/NeuralLoop-<version>.dmg (unsigned: "Open Anyway" once)
	scripts/package-mac.sh

runtime:          ## self-contained runtime for the Mac app (build/runtime): Python, pipeline, Rumik, Ollama
	scripts/build-runtime.sh

mac:              ## build and open the SwiftUI Mac app (needs Xcode and XcodeGen: brew install xcodegen)
	scripts/dev-signing-identity.sh
	cd apple && xcodegen generate --quiet && xcodebuild -project NeuralLoop.xcodeproj -scheme NeuralLoop -configuration Debug \
		-derivedDataPath build/dd CODE_SIGN_IDENTITY="NeuralLoop Development" build -quiet
	open apple/build/dd/Build/Products/Debug/NeuralLoop.app
