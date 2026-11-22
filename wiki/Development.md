# Development

[简体中文](Development-zh-CN)

### Toolchain

Copia targets macOS 26 or later on arm64 and x86_64 and builds with SwiftPM using the Xcode 27.2 toolchain. Command Line Tools alone lack the SwiftUI and SwiftData macro plugins, so point `DEVELOPER_DIR` at Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The only dependency is [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), pinned to exactly 3.1.0.

### Build and test

```sh
swift build
swift test
scripts/test-release-tools.sh
swift build -c release --arch arm64 --arch x86_64
```

Tests use Swift Testing and need no environment variables. The store tests run against temporary directories with a fault-injecting `FileOps`.

### See it

- `swift run copia-render --output renders`: opens each strip state as a real window over fixed wallpapers and captures it to `renders/` for design review. Add `--only NAME` to render one state. It needs Screen Recording permission for the terminal. `--only icon-review` writes only `12-icon-review.png`: the app icon from `Resources/AppIcon.icon` at 1024, 128, 32 and 16 px on a light and a dark row, composed from Icon Composer's exports with no window and no screen capture.
- `scripts/readme-media.sh`: renders the README's screenshots and icons from fixture data into `.github/media/` (WebP, light and dark). It covers the top-left of the main display with a generated wallpaper for about a minute, so only Copia's own windows are captured. It also needs `cwebp`.
- `"$(swift build --show-bin-path)/Copia" --selftest out.json`: runs ten open/close cycles on each enumerated display without moving the real pointer. Events go only to the test panel. It checks panel identity, focus, frame, typing and cleanup, then opens Settings once from the inactive accessory and checks that it becomes key and main. If a presentation is interrupted, the self-test fails and records the first affected cycle. It does not type into a hidden panel or reopen it to continue. Package proof requires schema 4, `settingsFirstAction: true`, all cycles and no violations. The store, defaults and pasteboard are private to the test; use an idle desktop because real windows open.

### App bundle and icon

`scripts/build-app.sh` builds one thin release app per architecture, each from its own SwiftPM scratch path, and assembles `dist/<arch>/Copia.app` for `arm64` and `x86_64`. Each bundle includes the KeyboardShortcuts resource bundle and the icon compiled by `actool` from `Resources/AppIcon.icon`. The script signs each app with the Apple Development identity and fails unless its binary holds exactly that one architecture with a macOS 26.0 floor (`scripts/check-archs.sh BINARY ARCH`). It then writes `dist/Copia-<VERSION>-arm64.zip` and `dist/Copia-<VERSION>-x86_64.zip`. Use `--unsigned` in CI. `--debug` builds only the host app at `dist/Copia.app` and no ZIP.

The Garland icon is an Icon Composer package: three cards hanging from a curved line with yellow pegs over a violet gradient. Six SVG layers separate the cards, their details, the pegs and the line. macOS adds the Liquid Glass material and highlights. Both light and dark appearances keep the chosen light artwork: a violet background and white cards. Preview it with `swift scripts/render-icon.swift dist/arm64/Copia.app icon.png` after a release build, or with `dist/Copia.app` after `--debug`.

### CI

`.github/workflows/ci.yml` runs on pull requests and pushes to `main` (not tag pushes) on the `xcode-27` runner. It checks the wiki and the release scripts' self-tests, compiles both architectures, runs the tests and the benchmark, and builds both unsigned ZIPs. It verifies each ZIP’s contents, resource bundle, versions, single architecture and deployment floor, then runs the native arm64 app's `--selftest`. A second job, `intel`, runs on the hosted `macos-26-intel` runner. It requires native x86_64 (not Rosetta) on macOS 26, receives the four verified files by artifact ID and digest, verifies them again and runs the Intel app's `--selftest`. Actions are pinned to commit SHAs. If the benchmark fails, a separate, bounded Time Profiler run targets only `copia-bench` and uploads `failure-profile` for seven days. Its instrumented numbers are diagnostic only and never replace the failed unprofiled gate.

### Wiki

`wiki/` is the only documentation. Every page has an English `Page.md` and a Chinese `Page-zh-CN.md` with the same heading depths. Line 3 of each links to the other language. Pages link by bare page name, and `_Sidebar.md` lists every page in both languages. `python3 scripts/check-wiki.py` enforces this, and `--self-test` proves each check fails on its own fixture. After every push to `main`, `.github/workflows/publish-wiki.yml` mirrors `wiki/` to the GitHub Wiki. There is no `docs/` folder and no changelog.

### Release

The stable tag must be `v` followed by the exact tracked `VERSION`. Use the matching milestone for the release PR and every linked issue. Merge the PR to `main`; do not tag until both **CI** and **Publish wiki** are green on the merged SHA’s main push. A PR check, dispatch run or older successful attempt is not a substitute.

1. Check the quarantined app on an idle test Mac before tagging. Record the actual `spctl -a -vv` verdict and the Open Anyway result. Check copy and manual ⌘V, shortcut labels, settings recovery, previews and full-screen behavior. Record which macOS, hardware and display were exercised; never infer native Intel, Rosetta, macOS 26 or 120 Hz coverage from slice inspection.
2. Immediately before tagging, run `gh issue list --repo D0n9X1n/copia --state open --limit 1 --json number --jq length`. Tag only if the command succeeds and prints `0`; an open issue or a failed query stops the release. Then tag the checked commit with `v$(cat VERSION)`. The read-only preflight checks full ancestry and the prior stable tag, latest exact-SHA main push runs and their required jobs, the unprofiled benchmark report, the merged PRs and milestone, and the tracker. Any open repository issue (not PR) blocks publication. Do not close unrelated issues to unblock it.
3. Only then can the signing job use the existing `release` environment, which accepts deployments from `v*` tags only. This environment restriction does not establish a repository tag ruleset or require a reviewer. The job signs with the existing Apple Development identity (team `AV5CFZA3T3`). The signing job runs on Apple silicon. It deletes the temporary keychain, checks both ZIPs in a new directory, verifies each app's secure timestamp, resources, single architecture and macOS 26.0 floor, and runs the arm64 app's packaged `--selftest`. A separate `intel` job on `macos-26-intel`, with no secrets or environment, receives the signed artifact by ID and digest. It requires native x86_64 on macOS 26 and runs the signed Intel app's `--selftest`.
4. A separate publisher needs both runtime jobs. It receives only the immutable artifact ID and digest, verifies all four upload files and both signed apps, and stages a draft with exactly those four assets. The notes bind each ZIP to its own digest and runtime line; neither architecture can publish alone. It checks the draft’s asset digests and live release evidence again before making it public. Notes account for every milestone issue: only an unreverted closing change in the range is credited; other closures are listed separately with the reason. If a check fails, the release stays unpublished; inspect the failing job rather than replacing its evidence.
5. After publication, download both ZIPs and their `.sha256` files into a new empty directory. Compare the digest before opening the app. This is an Apple Development signature, **not notarization**; the release does not provision certificates or alter secrets.
