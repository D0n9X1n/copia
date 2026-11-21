# Copia

Read first: [wiki/Architecture.md](wiki/Architecture.md), [wiki/Performance.md](wiki/Performance.md) and [wiki/Development.md](wiki/Development.md).

- Build with `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; Command Line Tools alone lack the macro plugins.
- `swift test` must pass, and `copia-bench` budgets must hold, before a change is done.
- `wiki/` is the only documentation: no `docs/` folder, no changelog. Change the English page and its `-zh-CN` pair together, then run `python3 scripts/check-wiki.py`.
- KeyboardShortcuts is the only dependency. Ask before adding another.
- README images come from fixture data via `scripts/readme-media.sh`. Never capture a real desktop.
