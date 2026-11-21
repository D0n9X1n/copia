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

- `swift run copia-render --output renders`: opens each strip state as a real window over fixed wallpapers and captures it to `renders/` for design review. Add `--only NAME` to render one state. It needs Screen Recording permission for the terminal.
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

1. Merge the release pull request after CI passes.
2. Run `scripts/build-app.sh` and verify with `codesign --verify --deep --strict dist/Copia.app`.
3. Tag `v0.0.1` and run `gh release create v0.0.1 dist/Copia-0.0.1.zip`.
