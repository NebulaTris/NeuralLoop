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
providers locked down, and a hash-verified runtime.
