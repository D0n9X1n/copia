"""Read the single stable release version, optionally checking its tag."""
import re
import sys
from pathlib import Path

STABLE = r'(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}'


def version(path, tag=None):
    value = Path(path).read_text().removesuffix('\n')
    if not re.fullmatch(STABLE, value) or (tag is not None and tag != 'v' + value):
        raise ValueError(f'invalid VERSION or mismatched release tag: {value!r}, {tag!r}')
    return value


if __name__ == '__main__':
    print(version(*sys.argv[1:]))
