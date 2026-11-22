"""Require Swift Testing to finish one nonempty, issue-free run, not just return zero."""
import json
from pathlib import Path
import re
import subprocess
import tempfile

ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
SUMMARY = re.compile(r'(?:✔️?\s*)?Test run with [1-9][0-9]* tests?(?: in [0-9]+ suites?)? '
                     r'passed after [0-9]+(?:\.[0-9]+)? seconds?\.')
FAILURE = re.compile(r'^(?:✘️?\s*)?(?:Test|Suite)\b.*\b(?:recorded (?:an issue|[0-9]+ issues?)|failed after)\b')


def check_events(path):
    started = ended = tested = False
    with path.open(encoding='utf-8') as stream:
        for line in stream:
            row = json.loads(line)
            if row['kind'] == 'test':  # discovery, not execution
                continue
            if row['kind'] != 'event' or row['version'] != 0:
                raise ValueError('unexpected Swift Testing event format')
            kind = row['payload']['kind']
            if ended or kind == 'issueRecorded' or (kind == 'runStarted' and started):
                raise ValueError('failed or repeated Swift Testing run')
            if kind == 'runStarted':
                started = True
            elif kind == 'testEnded':
                tested = tested or started
            elif kind == 'runEnded':
                if not started or not tested:
                    raise ValueError('empty Swift Testing run')
                ended = True
    if not ended:
        raise ValueError('missing Swift Testing runEnded')


def main():
    # Keep the structured report private and ephemeral; no new CI artifacts.
    with tempfile.TemporaryDirectory(prefix='copia-swift-test-') as folder:
        events = Path(folder)/'events.jsonl'
        summaries = 0
        failed = False
        with subprocess.Popen(['swift','test','--event-stream-version','0','--event-stream-output-path',str(events)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace') as proc:
            for line in proc.stdout:
                print(line, end='', flush=True)
                text = ANSI.sub('',line).strip()
                if SUMMARY.fullmatch(text):
                    summaries += 1
                elif FAILURE.search(text) or (summaries and text.endswith('Test run started.')):
                    failed = True
            status = proc.wait()
        if status:
            return status if status > 0 else 128-status
        if failed or summaries != 1:
            raise ValueError('reported failure or missing complete nonempty Swift Testing success summary')
        check_events(events)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f'Swift test gate: {error}')
