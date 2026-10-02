# NeuralLoop (Mac)

Pip lives in your menu bar. Drop a PDF or EPUB on NeuralLoop and every chapter becomes a learning loop: listen (video +
podcast), read with a guide, recall in your own words and take a quiz, remake the mind map from memory and explore the
concept graph, then flashcards on a spaced-repetition schedule. The book map grows with every chapter you map. NotebookLM
makes everything by default; your own AI takes over whenever NotebookLM can't (or all the time, if you choose).

## Install

Download `NeuralLoop-<version>.dmg`, drag NeuralLoop to Applications, and open it. It isn't signed by Apple yet, so the first
time macOS asks: open System Settings → Privacy & Security and choose **Open Anyway**. Everything it needs is inside the app
(Python, every AI provider, Rumik's voices, NotebookLM, Chromium for videos, and Ollama); the local models download the first
time they're needed.

## Using it

- **Add a book**: drop it on the window or choose Add a book. Pip makes a podcast and video for chapters 1–2 and everything
  else for every chapter; **Prepare more** adds media for every chapter and retries anything that needs another go.
- **Settings** (⌘,): sign in with Google for NotebookLM, pick your AI and keys (kept in the Keychain), voices and podcast
  length, and nudges (at most one a day, never in quiet hours, backing off if you skip them).
- **Menu bar**: pick up where you left off, play the chapter's podcast and video, review due cards, see NotebookLM's allowance.
- Books and progress live in `~/Library/Application Support/app.neuralloop.books/books/`.

## For developers

```bash
make setup     # once: Python dev tools, Playwright + Chromium (for explainer videos)
make check     # linters + every test (Python and Swift)
make mac       # build and open the app (Xcode + XcodeGen: brew install xcodegen)
make package   # dist/NeuralLoop-<version>.dmg
```

- `pipeline/` — the Python pipeline (a book in, `book.json` out); see its README and `CLAUDE.md` for the file map.
- `apple/Sources/NeuralLoopCore` — the app's pure logic with Swift tests; `apple/App` — SwiftUI views and services.
- `scripts/` — the runtime build (hash-locked packages, checksummed Ollama) and packaging.

The rules: pure logic lives in `NeuralLoopCore` and `neuralloop_books`, with tests; screens stay thin. Write the failing test
first, then the change. `CLAUDE.md` has the contracts between the app and the pipeline.

## Google Drive sync

Your library follows you through a private folder in each person's own Google Drive that only NeuralLoop can see (the
`drive.appdata` scope: the app can't read or list any other file). There's no NeuralLoop server: the apps talk to Google
directly, so each person's books and progress stay in their own account.

Google needs to know about the app once. That's an **OAuth client ID**: one for the project, baked into the apps you
build, used by everyone who signs in. It isn't a password (installed apps can't keep secrets), but keep it out of the
public repo so forks register their own app instead of appearing as yours.

### Step 1: set it up for yourself (about 10 minutes)

1. Open <https://console.cloud.google.com/> with the Google account that should own NeuralLoop (ideally a business
   account, not your personal one) and create a project called **NeuralLoop**.
2. **APIs & Services → Library** → **Google Drive API** → **Enable**.
3. **Google Auth Platform → Branding**: app name **NeuralLoop**, a support email you're happy to show people.
4. **Audience**: user type **External**, publishing status **Testing**, and add your own Google account under **Test
   users**.
5. **Data access → Add or remove scopes**: `openid`, `.../auth/userinfo.email`, `.../auth/userinfo.profile` (your name in
   Settings → Account), and `.../auth/drive.appdata`.
6. **Clients → Create client** → application type **iOS**, bundle ID `app.neuralloop.books`. Copy the **Client ID**
   (it ends in `.apps.googleusercontent.com`). One client serves both the Mac and iPad apps; there's no client secret.
7. `cp apple/Config/Google.xcconfig.example apple/Config/Google.xcconfig` and paste the client ID there (the file is in
   `.gitignore`).
8. Rebuild: `make package` (then install the new DMG), and the iPad app from Xcode. Sign in from **Settings → Account**
   on the Mac and from the profile button → Settings on the iPad, with the same Google account.

While the project is in **Testing**, only test users can sign in (up to 100), and Google asks them to sign in again
about once a week. That's perfect for you and a few friends.

### Step 2: open it to everyone

1. **A home page and a privacy policy.** Google shows both on the sign-in screen. The policy should say plainly: NeuralLoop
   reads your email address to show who's signed in, and stores your library in a hidden app folder in your own Drive;
   there's no NeuralLoop server; nothing is shared or sold; remove everything with Settings → Account → Remove all books,
   and revoke access at <https://myaccount.google.com/permissions>. Host them on a domain you own (a GitHub Pages site on
   your own domain works) and verify the domain in Google Search Console.
2. **Branding → Authorized domains**: add that domain; fill in the home page, privacy policy, and terms links; add the
   logo (Pip's icon from `design/pip/`).
3. **Audience → Publish app** (Testing → In production).
4. **Verification.** `drive.appdata`, `openid`, `email`, and `profile` are all non-sensitive scopes, so no security assessment is
   needed. Because the consent screen shows your name and logo, Google checks the branding (home page, policy, domain
   ownership). Submit it from **Verification Center**; it usually takes a few business days. Until it's verified, people
   see your app without the logo.
5. **Ship the client ID in your release builds.** Build the DMG (and later the iPad app) on a machine that has
   `apple/Config/Google.xcconfig`, or keep the ID as a secret in your release pipeline and write that file before
   building. Everyone who installs that build can sign in.
6. **Watch the quotas** in **APIs & Services → Google Drive API → Quotas**. Each person syncs a few requests every couple
   of minutes; the free per-user limits are far above that.

Before selling NeuralLoop, read `NOTICE.md`: the Rumik voices are licensed for non-commercial use only, and NotebookLM
is used through unofficial interfaces.

### Testing sync without Google

Development builds can sync through a local stand-in for Drive, so you can try the Mac app and the iPad **simulator**
together: `python scripts/fake_drive.py`, then launch both development builds with `-NLFakeDrive http://127.0.0.1:8765`.
(It only listens on this Mac, so it can't reach a physical iPad; use Step 1 for that.)

## Installing on your iPad

For your own iPad, no paid Apple account is needed.

1. **Xcode → Settings → Accounts → +** and sign in with your Apple ID. Select it and note the **Team ID** of your
   Personal Team (Xcode shows it under the team, or at <https://developer.apple.com/account> → Membership).
2. Create `apple/Config/Local.xcconfig` (not committed) with one line: `NEURALLOOP_TEAM = <your Team ID>`.
3. Plug the iPad into the Mac with a cable, unlock it, and tap **Trust**. Then on the iPad: **Settings → Privacy &
   Security → Developer Mode → On** (it appears once Xcode has seen the iPad), and restart when asked.
4. For sync, do "Step 1" above first (the client ID must be in `apple/Config/Google.xcconfig` before building).
5. `cd apple && xcodegen generate && open NeuralLoop.xcodeproj`, choose the **NeuralLoopPad** scheme and your iPad at the
   top, and press **Run** (⌘R).
6. The first time, the iPad won't open it yet: **Settings → General → VPN & Device Management** → your Apple ID → **Trust**.
   Open NeuralLoop again.
7. Profile button → **Settings → Sign in with Google** with the same account as the Mac. Your books appear within a couple
   of minutes; opening a chapter brings its podcast and video.

With a free Apple ID the app keeps working for 7 days; plug in and press Run again to renew it (your books and progress
stay). The paid Apple Developer Program ($99/year) makes installs last a year and allows TestFlight or Ad Hoc links for
others.

## Keeping maintainer notes private

This repository is public. Keep anything personal or business-only (Google Cloud project details, customer notes,
release checklists with account names) in `docs/private/`, which is in `.gitignore`, and keep your client ID and Apple
team in `apple/Config/Google.xcconfig` and `Local.xcconfig`, which are too.
