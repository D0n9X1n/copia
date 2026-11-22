# Copia Wiki

[简体中文](Home-zh-CN)

Copia keeps clipboard history locally on your Mac. Press ⌘Y, choose a card, then press ⌘V in the destination app. Picking a card copies it; no Accessibility permission is needed. **Start with [Usage](Usage).**

Each release has two downloads for macOS 26 or later: `Copia-<version>-arm64.zip` for Apple silicon Macs.
`Copia-<version>-x86_64.zip` is for Intel Macs.

Each app contains only its own architecture. Not sure which? Apple menu → **About This Mac** shows **Chip** on Apple silicon and **Processor** on Intel. Compare the ZIP’s SHA-256 with its `.sha256` file before extracting. See **Verification** in the [release notes](https://github.com/D0n9X1n/copia/releases) for which Intel hardware and macOS versions it ran on.

### Pages

- [Usage](Usage): install, shortcuts, the strip, privacy and permissions
- [Architecture](Architecture): modules, data flow and how history is stored
- [Performance](Performance): resource budgets, the benchmark and what keeps Copia light
- [Development](Development): toolchain, build, test, CI, icon and release
- [Home](Home): this index
