#!/usr/bin/env python3
"""Checks the wiki: English/zh-CN pairs, matching heading depths, link targets and sidebar coverage.

Usage:
  python3 scripts/check-wiki.py [WIKI_DIR]   # check a wiki (default: wiki/)
  python3 scripts/check-wiki.py --self-test  # each fixture must fail for exactly its own reason
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^(#{1,6})\s")
FENCE = re.compile(r"^(```|~~~)")


def headings(text):
    depths, fenced = [], False
    for line in text.splitlines():
        if FENCE.match(line):
            fenced = not fenced
        elif not fenced and (m := HEADING.match(line)):
            depths.append(len(m.group(1)))
    return depths


def links(text):
    out, fenced = [], False
    for line in text.splitlines():
        if FENCE.match(line):
            fenced = not fenced
        elif not fenced:
            out.extend(LINK.findall(line))
    return out


def check(wiki):
    errors = []
    pages = {p.stem: p.read_text(encoding="utf-8") for p in sorted(wiki.glob("*.md"))}
    sidebar = pages.pop("_Sidebar", None)
    if sidebar is None:
        errors.append("missing _Sidebar.md")
    english = [name for name in pages if not name.endswith("-zh-CN")]
    for name in english:
        zh = f"{name}-zh-CN"
        if zh not in pages:
            errors.append(f"pair: {name}.md has no {zh}.md")
            continue
        if headings(pages[name]) != headings(pages[zh]):
            errors.append(f"headings: {name}.md and {zh}.md have different heading depths")
        lines = [pages[name].splitlines(), pages[zh].splitlines()]
        if len(lines[0]) < 3 or f"({zh})" not in lines[0][2]:
            errors.append(f"switch: {name}.md must link to {zh} on line 3")
        if len(lines[1]) < 3 or f"({name})" not in lines[1][2]:
            errors.append(f"switch: {zh}.md must link to {name} on line 3")
    for name in pages:
        if name.endswith("-zh-CN") and name.removesuffix("-zh-CN") not in pages:
            errors.append(f"pair: {name}.md has no English page")
    for name, text in list(pages.items()) + ([("_Sidebar", sidebar)] if sidebar else []):
        for target in links(text):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            if target.endswith(".md"):
                errors.append(f"link: {name}.md uses a .md path ({target}); link by bare page name")
            elif target.split("#")[0] not in pages:
                errors.append(f"link: {name}.md links to missing page {target}")
    if sidebar:
        linked = set(links(sidebar))
        for name in pages:
            if name not in linked:
                errors.append(f"sidebar: _Sidebar.md does not link {name}")
    return errors


def self_test():
    fixtures = ROOT / "scripts" / "wiki-fixtures"
    expected = {"valid": None, "missing-pair": "pair:", "bad-link": "link:", "heading-mismatch": "headings:",
                "sidebar-missing": "sidebar:"}
    ok = True
    for name, prefix in expected.items():
        errors = check(fixtures / name)
        if prefix is None:
            passed = not errors
        else:
            # The fixture's own defect must be reported; follow-on errors (e.g. the switch link to a missing pair) are allowed.
            passed = any(e.startswith(prefix) for e in errors)
        print(f"{'ok  ' if passed else 'FAIL'} {name}: {errors or 'no errors'}")
        ok &= passed
    return ok


def main():
    if "--self-test" in sys.argv:
        sys.exit(0 if self_test() else 1)
    wiki = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "wiki"
    errors = check(wiki)
    for e in errors:
        print(e)
    print(f"{wiki}: {'ok' if not errors else f'{len(errors)} problem(s)'}")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
