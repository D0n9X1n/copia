"""Summarize only what actually ran: the packaged native self-test per ZIP, and the build host's toolchain."""
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from version import STABLE


def runtime(smoke, name, arch, os_version):
    report = json.loads(Path(smoke).read_text())
    if not (arch in ('arm64','x86_64') and re.fullmatch(rf'Copia-{STABLE}-{arch}\.zip', name) and
            re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', os_version) and
            report.get('schema') == 4 and report.get('settingsFirstAction') is True and
            type(report['displays']) is int and report['displays'] > 0 and report['violations'] == [] and
            len(report['samples']) == report['cycles'] == 10 * report['displays']):
        sys.exit('incomplete native package smoke evidence')
    tested = 'tested' if os_version.split('.')[0] == '26' else 'not tested'
    return f'`{name}`: packaged `--selftest` passed {report["cycles"]} cycles on native {arch}, macOS {os_version}; macOS 26: {tested}.'


def toolchain(sdk, xcode, swift):
    xcode_lines, swift_line = xcode.splitlines(), (swift.splitlines() or [''])[0]
    if not (re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', sdk) and len(xcode_lines) == 2 and
            re.fullmatch(r'Xcode [0-9]+\.[0-9]+(?:\.[0-9]+)?', xcode_lines[0]) and
            re.fullmatch(r'Build version [0-9A-Za-z]+', xcode_lines[1]) and
            re.fullmatch(r'Apple Swift version [0-9]+\.[0-9]+(?:\.[0-9]+)?(?: \([^()\n;]+\))?', swift_line)):
        sys.exit('incomplete toolchain evidence')
    return f'Built with {", ".join(xcode_lines)}; {swift_line}; macOS SDK {sdk}.'


if __name__ == '__main__':
    kind, *args = sys.argv[1:]
    line = {'runtime': runtime, 'toolchain': toolchain}[kind](*args)
    if not line.isprintable():
        sys.exit('control characters in evidence')
    print(line)
