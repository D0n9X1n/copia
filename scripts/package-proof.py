"""Summarize only runtime coverage actually exercised by the packaged native self-test."""
import json
from pathlib import Path
import sys

smoke, arch, os_version, sdk, xcode, swift = sys.argv[1:]
report = json.loads(Path(smoke).read_text())
if not (arch in ('arm64','x86_64') and report.get('schema') == 4 and report.get('settingsFirstAction') is True and
        type(report['displays']) is int and report['displays'] > 0 and report['violations'] == [] and
        len(report['samples']) == report['cycles'] == 10 * report['displays'] and all((os_version,sdk,xcode,swift))):
    sys.exit('incomplete native package smoke or toolchain evidence')
print(f'Packaged `--selftest`: {report["cycles"]} cycles on native {arch}, macOS {os_version}; '
      f'native Intel: {"tested" if arch == "x86_64" else "not tested"}; translation (Rosetta): not tested; '
      f'macOS 26: {"tested" if os_version.split(".")[0] == "26" else "not tested"}. '
      f'{", ".join(xcode.splitlines())}; {swift.splitlines()[0]}; macOS SDK {sdk}.')
