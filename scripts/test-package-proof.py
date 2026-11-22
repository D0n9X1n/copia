import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS=Path(__file__).resolve().parent


class PackageProof(unittest.TestCase):
    def test_notes_use_measured_host_sdk_and_nonempty_smoke(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp); smoke=p/'smoke.json'; smoke.write_text(json.dumps(dict(schema=4,settingsFirstAction=True,displays=1,cycles=10,samples=[{}]*10,violations=[])))
            args=[sys.executable,'-I',SCRIPTS/'package-proof.py',smoke,'arm64','27.2','27.2','Xcode 27.2\nBuild version A001','Apple Swift version 6.4']
            def run(ok):
                r=subprocess.run(args,capture_output=True,text=True); self.assertEqual(r.returncode==0,ok,r.stderr);return r.stdout
            notes=run(True)
            for term in ('arm64','27.2','SDK','Xcode','Swift','native Intel','translation','macOS 26','not tested'): self.assertIn(term,notes)
            args[4:6]=['x86_64','26.1'];self.assertIn('native Intel: tested',run(True));self.assertIn('macOS 26: tested',run(True))
            good=json.loads(smoke.read_text())
            for key, value in [('schema',3),('settingsFirstAction',False),('settingsFirstAction',None),('schema',None)]:
                changed=good.copy()
                if value is None: del changed[key]
                else: changed[key]=value
                smoke.write_text(json.dumps(changed))
                with self.subTest(field=key,value=value): run(False)
            smoke.write_text('{"displays":0,"cycles":0,"samples":[],"violations":[]}');run(False)
            smoke.write_text('{"displays":1,"cycles":10,"samples":[],"violations":["failure"]}');run(False)

    def test_native_runtime_selection_fails_closed_without_hardware_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            tool=Path(tmp)/'sysctl';tool.write_text('#!/bin/sh\n[ "$*" = "-in hw.optional.arm64" ] && echo "$VALUE"\n');tool.chmod(0o755)
            host=Path(tmp)/'uname';host.write_text('#!/bin/sh\necho x86_64\n');host.chmod(0o755)
            for cpu,expected in [('1','arm64'),('0','x86_64'),('','x86_64'),('unknown','')]:
                with self.subTest(cpu=cpu):
                    result=subprocess.run(['bash',SCRIPTS/'prove-package.sh','--native-arch'],
                        env=dict(PATH=f'{tmp}:/usr/bin:/bin',VALUE=cpu),capture_output=True,text=True)
                    self.assertEqual(result.returncode==0,bool(expected),result.stderr)
                    self.assertEqual(result.stdout.strip(),expected)

    def test_draft_asset_set_and_remote_digests_match_reviewed_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            import hashlib
            root=Path(tmp); release=root/'release.json'; p=root/'payload';p.mkdir();name='Copia-9.0.3.zip';(p/name).write_bytes(b'fixture')
            digest=lambda f: hashlib.sha256((p/f).read_bytes()).hexdigest()
            (p/(name+'.sha256')).write_text(f'{digest(name)}  {name}\n')
            obj=dict(isDraft=True,tagName='v9.0.3',assets=[dict(name=f.name,state='uploaded',digest='sha256:'+digest(f.name)) for f in p.iterdir()])
            args=[sys.executable,'-I',SCRIPTS/'release-assets.py','draft',release,p,'9.0.3']
            def check(ok):
                release.write_text(json.dumps(obj));r=subprocess.run(args,capture_output=True,text=True);self.assertEqual(r.returncode==0,ok,r.stderr)
            check(True)
            for target,key,bad in [(obj,'isDraft',False),(obj,'tagName','v9.0.2'),
                                   (obj['assets'][0],'state','new'),(obj['assets'][1],'state','deleted'),
                                   (obj['assets'][0],'digest','sha256:'+'1'*64)]:
                with self.subTest(key=key,bad=bad):
                    old=target[key];target[key]=bad;check(False);target[key]=old
            obj['assets'].pop();check(False)


if __name__=='__main__':unittest.main()
