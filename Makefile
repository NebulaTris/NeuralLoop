# One command for every check: `make check`. Run `make setup` once first.
#
# `make setup` makes a virtual environment at .venv (with python3.12 when there is one; the Mac app's development
# builds run the pipeline with .venv/bin/python) and installs the hash-locked dev tools into it. Every target uses
# that Python; `PY=...` picks another one instead (CI passes its own: `make setup check PY=python`).
VENV := $(CURDIR)/.venv
PY ?= $(VENV)/bin/python
BASE_PY ?= $(shell command -v python3.12 || command -v python3)
PLAYWRIGHT_FLAGS ?=
UNAME := $(shell uname -s)
# Swift Testing ships with Xcode; with only the Command Line Tools, point swift at their frameworks.
CLT := /Library/Developer/CommandLineTools/Library/Developer
SWIFT_FLAGS := $(if $(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),-Xswiftc -F$(CLT)/Frameworks -Xlinker -F$(CLT)/Frameworks -Xlinker -rpath -Xlinker $(CLT)/Frameworks -Xlinker -rpath -Xlinker $(CLT)/usr/lib,)

.PHONY: setup test check lint check-generated runtime mac package pip

setup:            ## .venv plus every dev tool (scripts/dev-requirements.txt, hash-checked) and Chromium
	@if [ "$(PY)" = "$(VENV)/bin/python" ] && [ ! -x "$(PY)" ]; then \
		if [ -z "$(BASE_PY)" ]; then echo "Python 3.10 or newer is needed (python3.12 is best): https://www.python.org" >&2; exit 1; fi; \
		$(BASE_PY) -c 'import sys; sys.exit(sys.version_info < (3, 10))' || \
			{ echo "$(BASE_PY) is older than Python 3.10; install python3.12 and run make setup again." >&2; exit 1; }; \
		echo "Creating $(VENV) with $(BASE_PY)"; $(BASE_PY) -m venv "$(VENV)"; \
	fi
	$(PY) -m pip install --disable-pip-version-check --require-hashes -r scripts/dev-requirements.txt
	$(PY) -m pip install --disable-pip-version-check --no-deps --no-build-isolation -e pipeline
	$(PY) -m playwright install $(PLAYWRIGHT_FLAGS) chromium

pip:              ## regenerate Pip's artwork (apple/App/Resources and the pipeline's assets); --force redraws every PNG
	$(PY) design/pip/generate_pip.py

check-generated:  ## generated art matches its sources (hashes and sizes only: no browser, the same on every OS)
	$(PY) design/pip/generate_pip.py --check
	$(PY) design/pip/make_app_icon.py --check
	$(PY) design/dmg/make_background.py --check

test:             ## all tests: Python, and Swift on macOS
	cd pipeline && $(PY) -m pytest -q
	@if [ "$(UNAME)" = Darwin ] && command -v swift >/dev/null; then cd apple && swift test $(SWIFT_FLAGS); \
	else echo "Swift tests skipped: they need macOS with Swift (CI runs them in the swift job)"; fi

lint:             ## formatting and linters: Ruff over every Python folder, ShellCheck over scripts/*.sh
	$(PY) -m ruff check pipeline scripts design
	$(PY) -m ruff format --check pipeline scripts design
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh; \
	else echo "ShellCheck skipped: not installed (brew install shellcheck; CI runs it)"; fi

check: lint check-generated test  ## what CI runs

package:          ## NeuralLoop.app with the runtime inside, in dist/NeuralLoop-<version>.dmg (unsigned: "Open Anyway" once)
	scripts/package-mac.sh

runtime:          ## self-contained runtime for the Mac app (build/runtime): Python, pipeline, Rumik, Ollama
	scripts/build-runtime.sh

mac:              ## build and open the SwiftUI Mac app (needs Xcode and XcodeGen: brew install xcodegen)
	scripts/dev-signing-identity.sh
	cd apple && xcodegen generate --quiet && xcodebuild -project NeuralLoop.xcodeproj -scheme NeuralLoop -configuration Debug \
		-derivedDataPath build/dd CODE_SIGN_IDENTITY="NeuralLoop Development" build -quiet
	open apple/build/dd/Build/Products/Debug/NeuralLoop.app
