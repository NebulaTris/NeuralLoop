# One command for every check: `make check`. Run `make setup` once first.
PY ?= python3
CARGO_ENV ?=

.PHONY: setup test check lint site app

setup:            ## install dev tools for every part
	cd pipeline && $(PY) -m pip install -e ".[dev]" playwright && $(PY) -m playwright install chromium
	cd pipeline/site && npm install
	npm install

site:             ## rebuild the study site bundle (pipeline/site/app.js)
	cd pipeline/site && npm run build

test: site        ## all tests: Python, JavaScript, Rust, and browser tests
	cd pipeline && $(PY) -m pytest -q
	cd pipeline/site && npm test
	cd src && npm test
	PYTHONPATH=pipeline $(PY) -m pytest -q tests
	cd src-tauri && $(CARGO_ENV) cargo test --lib

lint:             ## formatting and linters
	cd pipeline && ruff check . && ruff format --check .
	cd pipeline/site && npx prettier --check src test
	cd src-tauri && $(CARGO_ENV) cargo fmt --check && $(CARGO_ENV) cargo clippy --all-targets -- -D warnings

check: lint test  ## what CI runs

app:              ## build the desktop app for this computer
	npm run build
