# Security

NeuralLoop handles people's books, study progress, API keys, and Google sign-ins, so security reports matter a lot.

## Reporting a problem

Please report privately through GitHub: **Security → Report a vulnerability** on this repository (a private security
advisory). Don't open a public issue for a security problem. Include what you found, how to reproduce it, and what could
happen. You'll get a reply within a week.

## What's in scope

The Mac and iPad apps, the book pipeline, the packaging scripts, and Google Drive sync. Out of scope: problems that need
someone to already run code as the same user on the same Mac, and third-party services (NotebookLM, AI providers).

## How NeuralLoop is built to be safe

`docs/ARCHITECTURE.md` → "How it's kept safe" describes the design: keys only in the Keychain and environment, Google
sign-in with PKCE and only NeuralLoop's own hidden Drive folder, untrusted book and Drive content contained, agent
providers locked down, and a hash-verified runtime (hash-locked Python packages; Ollama by checksum and Developer ID;
Chromium, which Playwright downloads over HTTPS, by a SHA-256 recorded over its installed files).

## How the Mac app is signed

The DMG made by `scripts/package-mac.sh` is **ad-hoc signed** and **not notarized**, and the **hardened runtime is off**
(the bundled Python and its native libraries haven't been tested under it yet). That's why macOS asks once for
**System Settings → Privacy & Security → Open Anyway**. Ollama inside the runtime keeps its own Developer ID signature,
which the build checks.

Because an ad-hoc signature changes with every build, macOS may ask once after an update whether NeuralLoop may use the
keys it saved before (API keys and Google sign-in tokens in the Keychain): "NeuralLoop wants to use your confidential
information stored in … in your keychain." Enter your Mac's login password and click **Always Allow**. If you click
**Deny**, NeuralLoop can't read them until you allow it or enter them again in Settings. `docs/DEVELOPMENT.md` → "Signing" lists what a
Developer ID build with the hardened runtime would need.
