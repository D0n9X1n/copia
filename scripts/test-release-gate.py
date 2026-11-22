"""Offline end-to-end release evidence: real isolated Git history; recorded GitHub API pages."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).resolve().parent
REPO = 'fixture/Copia'; TAG = 'v0.0.2'; PR = 12


class ReleaseGate(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.repo=self.root/'repo'; self.repo.mkdir()
        self.bin=self.root/'bin'; self.bin.mkdir(); self.api=self.root/'api.json'
        self.env=dict(PATH=f'{self.bin}:/usr/bin:/bin', HOME=str(self.root), GIT_CONFIG_NOSYSTEM='1',
                      GIT_CONFIG_GLOBAL='/dev/null', GIT_ALLOW_PROTOCOL='file', GITHUB_REPOSITORY=REPO,
                      GITHUB_REF_NAME=TAG, GITHUB_RUN_ID='900',GITHUB_RUN_ATTEMPT='1', FIXTURE=str(self.api))
        self.git('init','-q','-b','main'); self.git('config','user.name','Fixture');self.git('config','user.email','fixture@example.test')
        self.commit('0.0.1','base'); self.git('tag','v0.0.1'); self.base=self.git('rev-parse','HEAD')
        self.commit('0.0.2','Ship the release (#12)'); self.sha=self.git('rev-parse','HEAD');self.git('tag',TAG)
        self.git('remote','add','origin',str(self.repo)); self.env['GITHUB_SHA']=self.sha
        fake=self.bin/'gh';fake.write_text(f'#!{sys.executable} -I\n'+'''import os,json,sys
from pathlib import Path
args=sys.argv[1:]; data=json.loads(Path(os.environ['FIXTURE']).read_text()); assert args.pop(0)=='api'
if 'graphql' in args:
    assert '-f' in args
    fields=dict(t.split('=',1) for t in args if '=' in t); query=fields['query']
    kind='pullRequest' if 'closingIssuesReferences(' in query else 'issue'; assert 'mutation' not in query
    node=data[kind+fields['number']+fields.get('cursor','')]; print(json.dumps({'data':{'repository':{kind:node}}})); sys.exit()
endpoint=next(x for x in args if x.startswith('repos/')); key=endpoint.split('fixture/Copia/')[1]
if key.endswith('/zip'):
    sys.stdout.buffer.write(bytes.fromhex(data[key])); sys.exit()
pages=data[key]; print(json.dumps(pages if '--slurp' in args and '--paginate' in args else pages[0]))
''');fake.chmod(0o755)
        self.data={}; self.jobs={}; self.runs={}
        for i,(file,job) in enumerate([('ci.yml','build-test-bench'),('publish-wiki.yml','publish')],101):
            record=dict(id=i,run_number=8, run_attempt=2,status='completed',conclusion='success',head_branch='main',
                        event='push',head_sha=self.sha,head_repository={'full_name':REPO},path='.github/workflows/'+file)
            key=f'actions/workflows/{file}/runs?branch=main&event=push&head_sha={self.sha}&per_page=100';self.runs[file]=key
            self.data[key]=[{'total_count':2,'workflow_runs':[dict(record,id=i-10,run_number=7,conclusion='failure')]},
                            {'total_count':2,'workflow_runs':[record]}]
            self.data[f'actions/runs/{i}']=[record.copy()]
            self.jobs[file]=f'actions/runs/{i}/attempts/2/jobs?per_page=100'
            self.data[self.jobs[file]]=[{'total_count':1,'jobs':[dict(id=1000+i,name=job,status='completed',conclusion='success',run_id=i,run_attempt=2,head_sha=self.sha)]}]
        self.data[f'commits/{self.sha}/pulls?per_page=100']=[[dict(number=PR)]]
        milestone=dict(number=1,title=TAG); self.data['milestones?state=all&per_page=100']=[[milestone]]
        self.data['issues?state=open&per_page=100']=[[dict(number=88,pull_request={})],[]]
        self.data['issues?milestone=1&state=all&per_page=100']=[[dict(number=n) for n in range(2,12)]+[dict(number=PR,pull_request={})]]
        end=dict(hasNextPage=False,endCursor=None); ref=dict(nameWithOwner=REPO)
        self.data['pullRequest12']=dict(number=PR,repository=ref,merged=True,mergeCommit=dict(oid=self.sha),baseRefName='main',
            milestone=milestone,body='Closes #2',closingIssuesReferences=dict(nodes=[dict(number=2,repository=ref)],pageInfo=dict(hasNextPage=True,endCursor='next')))
        self.data['pullRequest12next']=dict(self.data['pullRequest12'],closingIssuesReferences=dict(nodes=[dict(number=3,repository=ref)],pageInfo=end))
        for n in range(2,12):
            closer=({'__typename':'PullRequest','number':PR,'repository':ref,'merged':True,'mergeCommit':{'oid':self.sha}} if n==2 else
                    {'__typename':'Commit','oid':self.sha if n==3 else self.base,'repository':ref} if n!=4 else None)
            instant='2026-11-01T00:00:00Z'
            self.data[f'issue{n}']=dict(number=n,title=f'Issue {n}',repository=ref,state='CLOSED',closedAt=instant,
                stateReason='NOT_PLANNED' if n==5 else 'COMPLETED',milestone=milestone,
                timelineItems=dict(nodes=[dict(createdAt=instant,closer=closer)],pageInfo=end))
        self.report=dict(privateBoardPolls=118,path='screenCaptureKit',idleSeconds=60,idleCPUPercent=0.123,failed=[],opens=50,arch='arm64',refreshHz=60,presentedFramesGate=False)
        self.bench()

    def bench(self):
        b=io.BytesIO()
        with zipfile.ZipFile(b,'w') as z: z.writestr('bench.json',json.dumps(self.report))
        raw=b.getvalue(); d=hashlib.sha256(raw).hexdigest()
        self.data['actions/runs/101/artifacts?per_page=100']=[dict(total_count=1,artifacts=[dict(id=800,name='bench-2',expired=False,digest='sha256:'+d)])]
        self.data['actions/artifacts/800/zip']=raw.hex()

    def git(self,*args):
        return subprocess.check_output(['git','-C',self.repo,*args],env=self.env,text=True,stderr=subprocess.PIPE).strip()

    def commit(self,version,subject):
        (self.repo/'VERSION').write_text(version+'\n'); self.git('add','VERSION'); self.git('commit','-qm',subject)

    def gate(self,ok,*options):
        self.api.write_text(json.dumps(self.data)); result=subprocess.run([sys.executable,'-I',SCRIPTS/'release-gate.py',self.repo,*options],env=self.env,capture_output=True,text=True)
        self.assertEqual(result.returncode==0,ok,result.stderr)
        return result.stdout if ok else result.stderr

    def test_notes_only_credit_closure_in_the_validated_range(self):
        text=self.gate(True); resolved=text.split('## Resolved issues')[1].split('## ')[0]
        for n in (2,3): self.assertIn(f'/issues/{n})',resolved)
        for n in range(4,12): self.assertNotIn(f'/issues/{n})',resolved)
        for s in ('# Copia v0.0.2','## Downloads','## Changes since v0.0.1','## Verification',self.sha,
                  '/issues/4)', '/issues/5)', '0.123%', '60 Hz','/actions/runs/101','/actions/runs/102','/job/1101','/pull/12',
                  '/releases/download/v0.0.2/Copia-0.0.2.zip)', '/releases/download/v0.0.2/Copia-0.0.2.zip.sha256)'):
            self.assertIn(s,text)

    def test_newer_main_attempt_or_missing_required_job_blocks(self):
        for f,key in self.runs.items():
            r=self.data[key][-1]['workflow_runs'][0]
            for field,val in [('status','in_progress'),('conclusion','cancelled'),('event','pull_request'),('head_sha',self.base)]:
                old=r[field];r[field]=val
                with self.subTest(workflow=f,field=field): self.gate(False)
                r[field]=old
            latest=self.data[f"actions/runs/{r['id']}"][0];latest['run_attempt']+=1;self.gate(False);latest['run_attempt']-=1
            jobs=self.data[self.jobs[f]][0]['jobs'];old=jobs[0]['conclusion'];jobs[0]['conclusion']='skipped';self.gate(False);jobs[0]['conclusion']=old
            jobs[0]['name']='unrelated'; self.gate(False);jobs[0]['name']='build-test-bench' if f=='ci.yml' else 'publish'

    def test_release_requires_real_merge_and_every_linked_issue_in_milestone(self):
        for key,field,val in [('pullRequest12','merged',False),('pullRequest12','mergeCommit',{'oid':self.base}),
                              ('pullRequest12','baseRefName','develop'),('pullRequest12','milestone',None),('issue3','milestone',None),
                              ('issue3','closedAt',None),('issue3','stateReason',None)]:
            old=self.data[key][field];self.data[key][field]=val
            with self.subTest(key=key,field=field): self.gate(False)
            self.data[key][field]=old
        members=self.data['issues?milestone=1&state=all&per_page=100'][0]
        pr=members.pop();self.gate(False);members.append(pr)
        self.data['issues?state=open&per_page=100'][1].append(dict(number=99));self.gate(False)

    def test_event_sha_cannot_be_a_ref_that_happens_to_resolve_to_the_tag(self):
        self.env['GITHUB_SHA']='HEAD'
        self.assertIn('event', self.gate(False))
        self.env['GITHUB_SHA']=self.base
        self.assertIn('event', self.gate(False))

    def test_committed_version_must_match_even_with_correct_working_copy(self):
        for wrong in ('9.8.7\n',TAG[1:]+'\n\n'):
            with self.subTest(committed=wrong):
                (self.repo/'VERSION').write_text(wrong)
                self.git('commit','-qam','Invalid committed version');self.git('tag','-f',TAG,'HEAD')
                self.env['GITHUB_SHA']=self.git('rev-parse','HEAD');(self.repo/'VERSION').write_text(TAG[1:]+'\n')
                self.assertIn('tracked VERSION', self.gate(False))

    def test_stable_predecessor_version_must_be_lower_than_the_tag(self):
        self.git('tag','-d','v0.0.1'); self.git('tag','v0.1.0',self.base)
        self.assertIn('non-increasing',self.gate(False))

    def test_tag_must_be_the_merge_not_a_direct_push_after_an_unrelated_merge(self):
        original=self.sha
        self.git('commit','--allow-empty','-qm','Direct push')
        sha=self.git('rev-parse','HEAD');self.git('tag','-f',TAG,sha);self.env['GITHUB_SHA']=sha
        # The current tag has valid exact CI and wiki evidence but no associated merge.
        self.data=json.loads(json.dumps(self.data).replace(original,sha))
        self.data[f'commits/{original}/pulls?per_page=100']=[[dict(number=PR)]]
        self.data[f'commits/{sha}/pulls?per_page=100']=[[]]
        for k in ('pullRequest12','pullRequest12next'): self.data[k]['mergeCommit']['oid']=original
        self.data['issue2']['timelineItems']['nodes'][0]['closer']['mergeCommit']['oid']=original
        self.gate(False)

    def test_reverted_closing_commit_is_not_credited(self):
        reverted=self.sha
        subject='This reverts commit '+reverted+'.'
        self.git('commit','--allow-empty','-qm','Revert change','-m',subject)
        sha=self.git('rev-parse','HEAD');self.git('tag','-f',TAG,sha);self.env['GITHUB_SHA']=sha
        self.data=json.loads(json.dumps(self.data).replace(reverted,sha))
        self.data[f'commits/{reverted}/pulls?per_page=100']=[[]]
        self.data['issue3']['timelineItems']['nodes'][0]['closer']['oid']=reverted
        self.data['issue7']['timelineItems']['nodes'][0]['closer']['repository']={'nameWithOwner':'fixture/Other'}
        text=self.gate(True)
        resolved=text.split('## Resolved issues')[1].split('## ')[0]
        self.assertIn('/issues/2)',resolved);self.assertNotIn('/issues/3)',resolved)
        other=text.split('## Other milestone closures')[1].split('## ')[0]
        for n, reason in [(3,'reverted'),(4,'manually closed'),(5,'not planned'),(6,'outside'),(7,'another repository')]:
            with self.subTest(issue=n): self.assertRegex(other,rf'/issues/{n}\)[^\n]*{reason}')
        for n in range(2,12): self.assertEqual(1,(resolved+other).count(f'/issues/{n})'))

    def test_presented_frame_coverage_follows_benchmark_gate_not_host_assumptions(self):
        for hz, gate, valid in [(60,False,True),(60,True,False),(119.49,False,True),(119.5,True,True),
                                (120,True,True),(120,False,False),(144,True,True)]:
            with self.subTest(hz=hz, gate=gate):
                self.report.update(refreshHz=hz,presentedFramesGate=gate);self.bench()
                text=self.gate(valid)
                if valid: self.assertIn(f'{hz:g} Hz; 120 Hz presented-frame checks '+('gated' if gate else 'not exercised'),text)
        self.report['path']='proxy';del self.report['refreshHz'],self.report['presentedFramesGate'];self.bench()
        self.assertIn('120 Hz presented-frame coverage unavailable (proxy)', self.gate(True))

    def test_paused_polling_cannot_be_the_accepted_idle_sample(self):
        self.report['privateBoardPolls']=0;self.bench();self.gate(False)

    def test_git_or_api_error_is_not_an_empty_range_or_clean_tracker(self):
        key='issues?state=open&per_page=100'; old=self.data.pop(key);self.gate(False);self.data[key]=old
        self.git('tag','-d','v0.0.1');self.gate(False);self.git('tag','v0.0.1',self.base)
        self.git('branch','-m','off-main');self.git('branch','main',self.base);self.gate(False)

    def test_final_notes_link_to_the_actual_release_jobs(self):
        jobs=[dict(id=200+i,run_id=900,run_attempt=1,head_sha=self.sha,name=name,
                   status='in_progress' if i==2 else 'completed',conclusion=None if i==2 else 'success')
              for i,name in enumerate(('validate','package','publish'))]
        self.data['actions/runs/900/attempts/1/jobs?per_page=100']=[dict(total_count=3,jobs=jobs)]
        smoke=self.root/'smoke.json'
        smoke.write_text(json.dumps(dict(schema=4,settingsFirstAction=True,displays=1,cycles=10,samples=[{}]*10,violations=[])))
        coverage=subprocess.check_output([sys.executable,'-I',SCRIPTS/'package-proof.py',smoke,'arm64','27.2','27.2',
                                          'Xcode 27.2','Swift 6.4'],text=True).strip()
        digest=hashlib.sha256(b'fixture asset bytes').hexdigest()
        self.env.update(COVERAGE=coverage, REVIEWED_ZIP=digest)
        final=self.gate(True,'--publishing')
        for j in jobs: self.assertIn('/job/'+str(j['id']),final)
        lines=final.split('## Verification')[1].splitlines()
        self.assertIn('- '+coverage,lines);self.assertIn(f'- ZIP SHA-256 (`Copia-{TAG[1:]}.zip`): `{digest}`',lines)
        for key in ('COVERAGE','REVIEWED_ZIP'):
            old=self.env.pop(key);self.gate(False,'--publishing');self.env[key]=old
        jobs[1]['conclusion']='skipped';self.gate(False,'--publishing')

    def test_external_and_listed_closing_references_cannot_escape_milestone(self):
        for body in ('Fixes #2, #80', 'Resolves fixture/other#2', 'Closes fixture/Copia#81'):
            for key in ('pullRequest12','pullRequest12next'): self.data[key]['body']=body
            with self.subTest(body=body): self.gate(False)

    def test_deleted_remote_predecessor_is_not_a_release_range(self):
        # Separate file-backed origin. No checkout or network outside this fixture.
        remote=self.root/'origin';self.git('clone','--bare','--quiet',str(self.repo),str(remote));self.git('remote','set-url','origin',str(remote))
        subprocess.run(['git','-C',remote,'tag','-d','v0.0.1'],env=self.env,check=True,stdout=subprocess.DEVNULL)
        self.gate(False)

    def test_no_missing_or_corrupt_benchmark_substitution(self):
        key='actions/runs/101/artifacts?per_page=100';artifact=self.data[key][0]['artifacts'][0]
        artifact['expired']=True;self.gate(False);artifact['expired']=False
        artifact['digest']='sha256:'+'a'*64;self.gate(False)
        self.report['idleSeconds']=2;self.bench();self.gate(False)
        self.report['idleSeconds']=60;self.report['failed']=['over budget'];self.bench();self.gate(False)


if __name__=='__main__': unittest.main()
