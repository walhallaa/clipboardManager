# Mahmut Clipboard Manager

macOS 26 menu bar clipboard manager. SwiftUI + The Composable Architecture (TCA), Core Data, Liquid Glass.
Bundle ID `com.walhallaa.clipboardManager`, team `37TC2VKVJ6`, App Store name "Mahmut: Clipboard Manager".

## Building

- CLI builds need `-skipMacroValidation` (TCA macros): `xcodebuild -project clipboardManager.xcodeproj -scheme clipboardManager -configuration Debug -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`
- SourceKit "No such module" and "Cannot find type" diagnostics right after an edit are index noise. Trust `xcodebuild`.

## Releasing (read before touching anything release related)

- Work happens on `dev`. Releases go out only through `scripts/deploy.sh`, run from `dev`. It bumps the marketing version and the build number, merges `dev` into `main` and pushes `main`.
- **Pushing `main` starts a real TestFlight upload** (any push that isn't docs only). Never push `main` by hand, never run `scripts/deploy.sh`, and never start the `TestFlight` or `App Store Review` workflows unless the user explicitly asks in that message. Pushing `dev` is safe: no workflow triggers on it.
- To try a workflow fix without touching `main`, push `dev` and run `gh workflow run "<name>" --repo walhallaa/clipboardManager --ref dev`.
- Build numbers never reset: macOS requires them to increase across marketing versions. The project holds the current number, the deploy script adds 1, and CI uses the higher of that and App Store Connect's latest plus 1.
- After a TestFlight upload, the `submit-for-review` job waits for the user's approval of the `app-store-review` environment, then submits to App Store review. Releasing after approval stays manual (`automatic_release false`).
- Secrets live in GitHub Actions (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`, `DIST_CERT_P12`, `DIST_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`). Never print, log or ask for their values.
- Runners are Blacksmith: `blacksmith-6vcpu-macos-latest` for the Xcode upload, `blacksmith-2vcpu-ubuntu-2404` for anything that only calls the App Store Connect API. Keep minutes low.
- `.github/scripts/` holds the helpers (`asc.py`, `release_notes.py`, `project-settings.sh`) with tests: `python3 -m unittest discover -s .github/scripts -p 'test_*.py'` (needs Python 3.10 or newer).

## Release notes ("What's New")

App Store review refuses a version without them, so every release needs fresh text in `fastlane/release_notes/`:

- `default.txt` is used for every language. `<locale>.txt` (`en-US.txt`, `tr.txt`) overrides it for that language.
- `scripts/deploy.sh` refuses to ship if the folder hasn't changed since the last deploy. Interactively it offers to draft the text with `claude -p` from the commits going out, and the user approves it.
- One plain sentence per user visible change, one per line. No title, no bullets, no markdown. Leave out anything internal (CI, scripts, refactors, docs). Lead with what the user gets, not how it was built.
- Rules enforced by `release_notes.py check` (also run in CI before submission):
  - No en or em dashes. Use colons, commas, full stops or "to".
  - No command key glyph (App Store Connect rejects it). Write "Command-K".
  - Never the word "free". The app is not marketed as free, and future paid features are never mentioned.
  - No TODO left in, 4000 characters at most.

## Store copy everywhere

The same rules apply to the README, screenshots captions and any App Store text: no en or em dashes, never call the app free, never hint at future paid features.

## Architecture

- TCA throughout. Dependencies live in `Dependencies/`, features in `Features/`, persistence in `Persistence/`.
- Keep the app fast and memory safe: never hold image blobs in memory beyond ingest, thumbnails only in lists.
- Hover and press feedback on cards must never change geometry.
- Improve, don't remove: redesigns keep existing buttons, hints, titles and shortcuts.
