"""Exercise the actual CI test step with a fixture executable, never a Swift toolchain."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
PASS = '✔ Test run with 368 tests in 37 suites passed after 8.211 seconds.'
START = '◇ Test run started.'
EVENTS = ('runStarted', 'testStarted', 'testEnded', 'runEnded')


class SwiftSuite(unittest.TestCase):
    def check(self, expected, stdout=START, stderr=PASS, events=EVENTS, status=0):
        step = re.search(r'^      - name: Test\n(.*?)(?=^      - name:)',
                         (ROOT/'.github/workflows/ci.yml').read_text(), re.M | re.S)[1]
        command = textwrap.dedent(step.split('run:', 1)[1].strip('\n').replace(' |\n', '', 1)).strip()
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp); swift=folder/'swift'; calls=folder/'calls'
            swift.write_text(f'#!{sys.executable} -I\n'+'''import json, os, sys
from pathlib import Path
args=sys.argv[1:]
with Path(os.environ['CALLS']).open('a') as f: print(json.dumps(args), file=f)
if '--event-stream-output-path' in args and os.environ['EVENTS'] != 'null':
    Path(args[args.index('--event-stream-output-path')+1]).write_text(os.environ['EVENTS'])
print(os.environ['STDOUT'], flush=True); print(os.environ['STDERR'], file=sys.stderr, flush=True)
sys.exit(int(os.environ['STATUS']))
''');swift.chmod(0o755)
            # Match the v0 JSONL envelope, including the machine-readable completion event.
            stream = events if isinstance(events,str) else ''.join(json.dumps(dict(version=0,kind='event',payload={'kind':kind}))+'\n' for kind in events)
            env=dict(PATH=f'{folder}:{Path(sys.executable).parent}:/usr/bin:/bin', HOME=tmp, TMPDIR=tmp,
                     RUNNER_TEMP=tmp, CALLS=str(calls), STDOUT=stdout, STDERR=stderr, STATUS=str(status), EVENTS=stream)
            result=subprocess.run(['/bin/bash','-eo','pipefail','-c',command],cwd=ROOT,env=env,capture_output=True,text=True)
            invocations=[json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual(len(invocations),1); args=invocations[0];self.assertEqual(args[0],'test')
            self.assertEqual(args.count('--event-stream-version'), 1)
            self.assertEqual(args[args.index('--event-stream-version') + 1], '0')
            self.assertFalse(any(s in args for s in ('--filter','--skip','--specifier','--maximum-repetitions')))
            self.assertEqual(result.returncode==0,expected,result.stderr+result.stdout)
            if status: self.assertEqual(result.returncode,status)
            self.assertEqual({p.name for p in folder.iterdir()},{'swift','calls'},'test output left behind')

    def test_accepts_one_complete_nonempty_swift_testing_run(self):
        for summary in (PASS,'\x1b[32m✔\x1b[0m Test run with 1 test in 2 suites passed after 0.599 seconds.',
                        'Test run with 1 test passed after 0.001 seconds.'):
            with self.subTest(summary=summary): self.check(True,stderr=summary)

    def test_zero_exit_cannot_hide_a_reported_failure_on_either_channel(self):
        issue='\x1b[31m✘\x1b[0m Test fixture() recorded an issue at Fixture.swift:10:2: Expectation failed'
        for stdout,stderr in [(START,issue+'\n◇ Test next() started.'),(issue,PASS),(START,issue+'\n'+PASS),
                              ('Suite Fixture failed after 0.010 seconds with 1 issue.',PASS)]:
            with self.subTest(stdout=stdout,stderr=stderr): self.check(False,stdout,stderr)
        self.check(False,events=(*EVENTS[:-1],'issueRecorded','runEnded'))

    def test_incomplete_zero_or_malformed_run_is_not_success(self):
        for text in ('','✔ Test fixture() passed after 0.003 seconds.',
                     '✔ Test run with 0 tests passed after 0.001 seconds.',
                     PASS+'\n◇ Test run started.'):
            with self.subTest(text=text): self.check(False,stderr=text)
        for events in ((),EVENTS[:-1],('runStarted','runEnded'),'null','truncated JSON'):
            with self.subTest(events=events): self.check(False,events=events)

    def test_only_v0_event_envelopes_can_complete_a_run(self):
        for version, envelope in [(1, 'event'), (0, 'unknown')]:
            stream = ''.join(json.dumps({'version': version, 'kind': envelope, 'payload': {'kind': k}}) + '\n' for k in EVENTS)
            with self.subTest(version=version, envelope=envelope):
                self.check(False, events=stream)

    def test_one_start_and_no_events_after_completion(self):
        for sequence in [('runStarted', *EVENTS), (*EVENTS, 'testEnded'), (*EVENTS, *EVENTS)]:
            with self.subTest(events=sequence):
                self.check(False, events=sequence)

    def test_command_failure_wins_even_with_complete_passing_reports(self):
        self.check(False,status=17)


if __name__=='__main__': unittest.main()
