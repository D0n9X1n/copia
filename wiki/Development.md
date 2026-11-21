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
- `Copia --selftest out.json`: opens and closes the strip ten times on every display through the same path as ⌘Y and records the key window, the frontmost app and the panel's screen. It exits nonzero on any violation.

### App bundle and icon

`scripts/build-app.sh` builds a universal release binary and assembles `dist/Copia.app`. The bundle includes the KeyboardShortcuts resource bundle and the icon compiled by `actool` from `Resources/AppIcon.icon`. The script then signs with the Apple Development identity and writes `dist/Copia-0.0.1.zip`. Use `--unsigned` in CI.

The icon is an Icon Composer package: three SVG card layers over a persimmon-to-raspberry gradient. macOS 27 adds the Liquid Glass material, highlights and the dark and tinted variants. Preview it with `swift scripts/render-icon.swift dist/Copia.app icon.png`.

### CI

`.github/workflows/ci.yml` runs on every push on the `xcode-27` runner. It checks the wiki, runs the universal build, tests and the benchmark, and assembles an unsigned bundle. Actions are pinned to commit SHAs.

### Wiki

`wiki/` is the only documentation. Every page has an English `Page.md` and a Chinese `Page-zh-CN.md` with the same heading depths. Line 3 of each links to the other language. Pages link by bare page name, and `_Sidebar.md` lists every page in both languages. `python3 scripts/check-wiki.py` enforces this, and `--self-test` proves each check fails on its own fixture. After every push to `main`, `.github/workflows/publish-wiki.yml` mirrors `wiki/` to the GitHub Wiki. There is no `docs/` folder and no changelog.

### Release

Releases are built and signed by GitHub Actions; nothing is uploaded from a local `dist/`.

1. Merge the release pull request after CI passes.
2. Push a tag: `git tag v0.0.1 && git push origin v0.0.1`. `.github/workflows/release.yml` runs the tests, builds the universal app, signs it with the certificate stored in the `release` environment, verifies it, and publishes `Copia-0.0.1.zip` with its SHA-256 as a GitHub Release. The log shows the `spctl -a -vv` verdict.
3. Download the zip into a new temporary folder, open it there and check that the Shortcuts recorder shows its labels.
4. Check by hand on that app: copy in TextEdit, then ⌘Y and ↩ pastes it; image and link cards show saved previews; deleting a card removes its files from `~/Library/Application Support/Copia`; a fresh onboarding updates after granting Accessibility; Launch at login reads back; a rebound shortcut replaces the old one; Settings shows its General, Shortcuts and Privacy tabs, and Erase History asks first and Cancel keeps the history; the strip opens over a full-screen app.

One-time signing setup, before the first tag: in Keychain Access, export only the "Apple Development" certificate with its private key as a `.p12` with a password, then run `scripts/setup-release-signing.sh path/to/certificate.p12` in a terminal. It creates the `release` environment, which only `v*` tags can use, stores the certificate and password as its secrets, and asks for the password without echoing it. Delete the `.p12` afterwards. Pull requests and branch builds never see the secrets; CI builds them unsigned.

The build is signed with an Apple Development certificate, so it keeps one identity across releases (Accessibility stays granted after an update) but is not notarized. Notarization needs a Developer ID certificate from the paid Apple Developer Program.
