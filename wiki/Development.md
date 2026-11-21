# Development

[简体中文](Development-zh-CN)

### Toolchain

Copia targets macOS 27 and builds with SwiftPM using the Xcode 27.2 toolchain. Command Line Tools alone lack the SwiftUI and SwiftData macro plugins, so point `DEVELOPER_DIR` at Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The only dependency is [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), pinned to exactly 3.1.0.

### Build and test

```sh
swift build
swift test
swift build -c release --arch arm64 --arch x86_64
```

Tests use Swift Testing and need no environment variables. The store tests run against temporary directories with a fault-injecting `FileOps`.

### See it

- `swift run copia-render --output renders`: opens each strip state as a real window over fixed wallpapers and captures it to `renders/` for design review. Add `--only NAME` to render one state. It needs Screen Recording permission for the terminal. `--only icon-review` writes only `12-icon-review.png`: the app icon from `Resources/AppIcon.icon` at 1024, 128, 32 and 16 px on a light and a dark row, composed from Icon Composer's exports with no window and no screen capture.
- `scripts/readme-media.sh`: renders the README's screenshots and icons from fixture data into `.github/media/` (WebP, light and dark). It covers the top-left of the main display with a generated wallpaper for about a minute, so only Copia's own windows are captured. It also needs `cwebp`.
- `"$(swift build --show-bin-path)/Copia" --selftest out.json`: opens and closes the strip ten times on every display through the same path as ⌘Y. Each time it checks that the panel is key, Copia did not become the active app, typing reaches the search, the panel opened on the screen under the pointer, and the panel frame is exactly the layout frame for that screen's visible frame and lies inside it. It exits nonzero on any violation. It uses a temporary store, paused capture and the private `copia-selftest` defaults suite, and it never reads or writes the clipboard's contents (the paused watcher reads only the change count). It moves the pointer and types into its own panel, so run it on an idle desktop.

### App bundle and icon

`scripts/build-app.sh` builds a universal release binary and assembles `dist/Copia.app`. The bundle includes the KeyboardShortcuts resource bundle and the icon compiled by `actool` from `Resources/AppIcon.icon`. The script then signs with the Apple Development identity, fails unless the binary has both the arm64 and the x86_64 slice (`scripts/check-archs.sh`), and writes `dist/Copia-0.0.1.zip`. Use `--unsigned` in CI.

The Garland icon is an Icon Composer package: three cards hanging from a curved line with yellow pegs over a violet gradient. Six SVG layers separate the cards, their details, the pegs and the line. macOS 27 adds the Liquid Glass material and highlights. Both light and dark appearances keep the chosen light artwork: a violet background and white cards. Preview it with `swift scripts/render-icon.swift dist/Copia.app icon.png`.

### CI

`.github/workflows/ci.yml` runs on every push on the `xcode-27` runner. It checks the wiki and the release scripts' self-tests, runs the universal build, tests and the benchmark, and assembles an unsigned bundle. Actions are pinned to commit SHAs.

### Wiki

`wiki/` is the only documentation. Every page has an English `Page.md` and a Chinese `Page-zh-CN.md` with the same heading depths. Line 3 of each links to the other language. Pages link by bare page name, and `_Sidebar.md` lists every page in both languages. `python3 scripts/check-wiki.py` enforces this, and `--self-test` proves each check fails on its own fixture. After every push to `main`, `.github/workflows/publish-wiki.yml` mirrors `wiki/` to the GitHub Wiki. There is no `docs/` folder and no changelog.

### Release

Releases are built and signed by GitHub Actions; nothing is uploaded from a local `dist/`. First a local build of the same commit, signed with the same certificate, is proven by hand; the tag is pushed only after that proof passes.

1. Merge the release pull request after CI passes, then check out the merged commit: `git switch main && git pull`.
2. Build and sign it: `scripts/build-app.sh`. It signs with the Apple Development identity, so the certificate must be in your keychain, and it fails unless the binary has both the arm64 and the x86_64 slice.
3. Mark the build as downloaded, as a browser would, and confirm the mark is set: `xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Copia;" dist/Copia.app`, then `xattr -p com.apple.quarantine dist/Copia.app` must print that value.
4. Run `spctl -a -vv dist/Copia.app` and paste its full output into the release pull request. The build is not notarized, so Gatekeeper is expected to reject it; the record shows which verdict ships.
5. Open that quarantined `dist/Copia.app`. On first launch macOS blocks it: click **Open Anyway** in System Settings → Privacy & Security. Check that the Shortcuts recorder shows its labels.
6. Check by hand on that app: copy in TextEdit, then ⌘Y and ↩ pastes it; image and link cards show saved previews; deleting a card removes its files from `~/Library/Application Support/Copia`; a fresh onboarding updates after granting Accessibility; Launch at login reads back; a rebound shortcut replaces the old one; Settings shows its General, Shortcuts and Privacy tabs, and Erase History asks first and Cancel keeps the history; the strip opens over a full-screen app.
7. Only after every step above passes, tag the same commit: `git tag v0.0.1 && git push origin v0.0.1`. `.github/workflows/release.yml` runs the tests, builds the universal app, signs it with the certificate stored in the `release` environment, verifies it, and publishes `Copia-0.0.1.zip` with its SHA-256 as a GitHub Release. Its log repeats the `spctl -a -vv` verdict for the published build.
8. Download the published zip into a new temporary folder, compare `shasum -a 256` with the published `.sha256`, and open it there once.

One-time signing setup, before the first tag: in Keychain Access, export only the "Apple Development" certificate with its private key as a `.p12` with a password, then run `scripts/setup-release-signing.sh path/to/certificate.p12` in a terminal. It makes the `release` environment accept only the `v*` tag: it removes every other deployment policy and adds that one if it is missing, and it stops before storing any secret if a policy call fails or another policy remains. Then it stores the certificate and password as the environment's secrets, asking for the password without echoing it. `scripts/test-setup-release-signing.sh` checks this against a fake `gh`. Delete the `.p12` afterwards. Pull requests and branch builds never see the secrets; CI builds them unsigned.

The build is signed with an Apple Development certificate, so it keeps one identity across releases (Accessibility stays granted after an update) but is not notarized. Notarization needs a Developer ID certificate from the paid Apple Developer Program.
