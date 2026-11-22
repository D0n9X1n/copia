import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS=Path(__file__).resolve().parent


class PackageProof(unittest.TestCase):
    def proof(self, ok, *args):
        r=subprocess.run([sys.executable,'-I',SCRIPTS/'package-proof.py',*map(str,args)],capture_output=True,text=True)
        self.assertEqual(r.returncode==0,ok,r.stderr); return r.stdout.strip()

    def test_runtime_line_names_the_zip_and_only_what_ran(self):
        with tempfile.TemporaryDirectory() as tmp:
            smoke=Path(tmp)/'smoke.json'; good=dict(schema=4,settingsFirstAction=True,displays=1,cycles=10,samples=[{}]*10,violations=[])
            smoke.write_text(json.dumps(good))
            line=self.proof(True,'runtime',smoke,'Copia-1.2.3-arm64.zip','arm64','27.2')
            self.assertEqual(line,'`Copia-1.2.3-arm64.zip`: packaged `--selftest` passed 10 cycles on native arm64, macOS 27.2; macOS 26: not tested.')
            for term in ('Xcode','Swift','SDK','Rosetta'): self.assertNotIn(term,line)
            line=self.proof(True,'runtime',smoke,'Copia-1.2.3-x86_64.zip','x86_64','26.6.1')
            self.assertEqual(line,'`Copia-1.2.3-x86_64.zip`: packaged `--selftest` passed 10 cycles on native x86_64, macOS 26.6.1; macOS 26: tested.')
            self.proof(False,'runtime',smoke,'Copia-1.2.3-arm64.zip','x86_64','26.6.1')
            self.proof(False,'runtime',smoke,'Copia-1.2.3.zip','arm64','27.2')
            self.proof(False,'runtime',smoke,'Copia-1.2.3-arm64.zip','i386','27.2')
            self.proof(False,'runtime',smoke,'Copia-1.2.3-arm64.zip','arm64','')
            for bad_os in ('26','26.6.1\n27.0','26.x','macOS 26.6'):
                with self.subTest(os=bad_os): self.proof(False,'runtime',smoke,'Copia-1.2.3-x86_64.zip','x86_64',bad_os)
            for key, value in [('schema',3),('settingsFirstAction',False),('settingsFirstAction',None),('schema',None)]:
                changed=good.copy()
                if value is None: del changed[key]
                else: changed[key]=value
                smoke.write_text(json.dumps(changed))
                with self.subTest(field=key,value=value): self.proof(False,'runtime',smoke,'Copia-1.2.3-arm64.zip','arm64','27.2')
            smoke.write_text('{"displays":0,"cycles":0,"samples":[],"violations":[]}');self.proof(False,'runtime',smoke,'Copia-1.2.3-arm64.zip','arm64','27.2')
            smoke.write_text('{"displays":1,"cycles":10,"samples":[],"violations":["failure"]}');self.proof(False,'runtime',smoke,'Copia-1.2.3-arm64.zip','arm64','27.2')

    def test_toolchain_line_comes_from_the_build_host(self):
        line=self.proof(True,'toolchain','27.2','Xcode 27.2\nBuild version A001','Apple Swift version 6.4\nTarget: arm64')
        self.assertEqual(line,'Built with Xcode 27.2, Build version A001; Apple Swift version 6.4; macOS SDK 27.2.')
        self.proof(False,'toolchain','','Xcode 27.2','Swift 6.4'); self.proof(False,'toolchain','27.2','','Swift')
        good=('27.2','Xcode 27.2\nBuild version A001','Apple Swift version 6.4\nTarget: arm64')
        for index,bad in [(0,'27.2\n26.0'),(0,'..'),(1,'Xcode .\nBuild version A'),(1,'Xcode 27.2'),(1,'Xcode 27.2\nBuild version A001\nextra'),
                          (2,'Apple Swift version unknown'),(2,'Swift 6.4')]:
            args=list(good); args[index]=bad
            with self.subTest(index=index,bad=bad): self.proof(False,'toolchain',*args)

    def test_native_runtime_selection_fails_closed_without_hardware_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            tool=Path(tmp)/'sysctl';tool.write_text('#!/bin/sh\ncase "$*" in\n"-in hw.optional.arm64") echo "$VALUE";;\n'
                                                    '"-in sysctl.proc_translated") echo "$TRANSLATED";;\nesac\n');tool.chmod(0o755)
            host=Path(tmp)/'uname';host.write_text('#!/bin/sh\necho x86_64\n[ "$UNAME_FAIL" = 1 ] && exit 1\nexit 0\n');host.chmod(0o755)
            for cpu in ('0',''):
                with self.subTest(cpu=cpu,uname='fails'):
                    result=subprocess.run(['bash',SCRIPTS/'prove-package.sh','--native-arch'],
                        env=dict(PATH=f'{tmp}:/usr/bin:/bin',VALUE=cpu,TRANSLATED='0',UNAME_FAIL='1'),capture_output=True,text=True)
                    self.assertNotEqual(result.returncode,0,result.stdout); self.assertEqual(result.stdout.strip(),'')
            tool.write_text('#!/bin/sh\ncase "$*" in\n"-in hw.optional.arm64") echo "$VALUE";;\n'
                            '"-in sysctl.proc_translated") [ "$TRANSLATED" = fail ] && exit 1; echo "$TRANSLATED";;\nesac\n')
            for cpu,translated,expected in [('1','','arm64'),('0','0','x86_64'),('','','x86_64'),('unknown','',''),
                                            ('','1',''),('0','1',''),('1','1',''),('0','fail',''),('1','fail',''),('0','2','')]:
                with self.subTest(cpu=cpu,translated=translated):
                    result=subprocess.run(['bash',SCRIPTS/'prove-package.sh','--native-arch'],
                        env=dict(PATH=f'{tmp}:/usr/bin:/bin',VALUE=cpu,TRANSLATED=translated),capture_output=True,text=True)
                    self.assertEqual(result.returncode==0,bool(expected),result.stderr)
                    self.assertEqual(result.stdout.strip(),expected)

    def received_fixture(self, tmp):
        """A throwaway checkout whose two ZIPs hold shell stand-ins that record which one ran."""
        import zipfile, plistlib, shutil
        root=Path(tmp)/'root'; (root/'scripts').mkdir(parents=True); bin_=Path(tmp)/'bin'; bin_.mkdir()
        for name in ('prove-package.sh','release-assets.py','check-archs.sh','version.py','package-proof.py'):
            shutil.copy2(SCRIPTS/name, root/'scripts'/name)
        (root/'VERSION').write_text('1.2.3\n')
        for name, body in [('sw_vers','[ "$1" = -productVersion ] || exit 64\nexec /usr/bin/sw_vers -productVersion\n[ "$SW_VERS_FAIL" = 1 ] && exit 1'),
                           ('sysctl','case "$*" in\n"-in sysctl.proc_translated") echo 0;;\n*) exec /usr/sbin/sysctl "$@";;\nesac'),
                           ('lipo','[ "$1" = -archs ] && sed -n "s/^# arch://p" "$2"'),
                           ('xcrun','printf "platform MACOS\\nminos 26.0\\n"')]:
            (bin_/name).write_text('#!/bin/sh\n'+body+'\n'); (bin_/name).chmod(0o755)
        received=Path(tmp)/'received'; received.mkdir()
        smoke=json.dumps(dict(schema=4,settingsFirstAction=True,displays=1,cycles=10,samples=[{}]*10,violations=[]))
        base='Copia.app/Contents/'; loc='Resources/KeyboardShortcuts_KeyboardShortcuts.bundle/Contents/Resources/en.lproj/Localizable.strings'
        plist=plistlib.dumps(dict(CFBundleVersion='1.2.3',CFBundleShortVersionString='1.2.3',LSMinimumSystemVersion='26.0',
                                  CFBundleIdentifier='app.copia.Copia',CFBundleExecutable='Copia',CFBundlePackageType='APPL',
                                  CFBundleIconName='AppIcon',CFBundleIconFile='AppIcon',LSUIElement=True))
        for arch in ('arm64','x86_64'):
            exe=f"#!/bin/sh\n# arch:{arch}\necho {arch} >> \"$(dirname \"$2\")/ran\"\nprintf '%s' '{smoke}' > \"$2\"\n"
            name=f'Copia-1.2.3-{arch}.zip'
            with zipfile.ZipFile(received/name,'w') as z:
                for member,(mode,data) in {base+'MacOS/Copia':(0o100755,exe.encode()),base+'Info.plist':(0o100644,plist),
                                           base+'Resources/Assets.car':(0o100644,b'i'),base+'Resources/AppIcon.icns':(0o100644,b'i'),
                                           base+loc:(0o100644,b'l')}.items():
                    info=zipfile.ZipInfo(member); info.external_attr=mode<<16; z.writestr(info,data)
            (received/(name+'.sha256')).write_text(f'{hashlib.sha256((received/name).read_bytes()).hexdigest()}  {name}\n')
        return root, bin_, received

    def test_received_assets_keep_shipped_sidecars_and_smoke_only_the_native_app(self):
        native=subprocess.check_output(['bash',SCRIPTS/'prove-package.sh','--native-arch'],text=True).strip()
        with tempfile.TemporaryDirectory() as tmp:
            root,bin_,received=self.received_fixture(tmp); out=Path(tmp)/'github-output'; out.touch()
            env=dict(PATH=f'{bin_}:/usr/bin:/bin',GITHUB_OUTPUT=str(out))
            work=Path(tmp)/'proof'
            result=subprocess.run(['bash',root/'scripts/prove-package.sh','unsigned',work,received],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((work/'ran').read_text().splitlines(),[native])
            for arch in ('arm64','x86_64'):
                shipped=(received/f'Copia-1.2.3-{arch}.zip.sha256').read_text().split()[0]
                self.assertIn(f'zip-sha-{arch}={shipped}',out.read_text().splitlines())
            self.assertIn(f'`Copia-1.2.3-{native}.zip`: packaged `--selftest` passed 10 cycles on native {native}',(work/'coverage.txt').read_text())
            (bin_/'sw_vers').write_text('#!/bin/sh\n/usr/bin/sw_vers -productVersion\n[ "$SW_VERS_FAIL" = 1 ] && exit 1\nexit 0\n')
            work=Path(tmp)/'proof-os-probe'
            result=subprocess.run(['bash',root/'scripts/prove-package.sh','unsigned',work,received],
                                  env=dict(env,SW_VERS_FAIL='1'),capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0); self.assertFalse((work/'coverage.txt').exists() and (work/'coverage.txt').read_text())
            # A corrupt shipped sidecar must stop the proof before any app runs; regenerating it would hide the corruption.
            side=received/'Copia-1.2.3-x86_64.zip.sha256'; side.write_text('0'*64+'  Copia-1.2.3-x86_64.zip\n')
            work=Path(tmp)/'proof-bad'
            result=subprocess.run(['bash',root/'scripts/prove-package.sh','unsigned',work,received],env=env,capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0); self.assertFalse((work/'ran').exists())

    def test_draft_asset_set_and_remote_digests_match_reviewed_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); release=root/'release.json'; p=root/'payload';p.mkdir()
            digest=lambda f: hashlib.sha256((p/f).read_bytes()).hexdigest()
            for arch in ('arm64','x86_64'):
                name=f'Copia-9.0.3-{arch}.zip';(p/name).write_bytes(b'fixture '+arch.encode())
                (p/(name+'.sha256')).write_text(f'{digest(name)}  {name}\n')
            obj=dict(isDraft=True,tagName='v9.0.3',assets=[dict(name=f.name,state='uploaded',digest='sha256:'+digest(f.name)) for f in sorted(p.iterdir())])
            args=[sys.executable,'-I',SCRIPTS/'release-assets.py','draft',release,p,'9.0.3']
            def check(ok):
                release.write_text(json.dumps(obj));r=subprocess.run(args,capture_output=True,text=True);self.assertEqual(r.returncode==0,ok,r.stderr)
            check(True)
            for i in range(4):
                for key,bad in [('state','new'),('digest','sha256:'+'1'*64)]:
                    with self.subTest(asset=i,key=key):
                        old=obj['assets'][i][key];obj['assets'][i][key]=bad;check(False);obj['assets'][i][key]=old
            for key,bad in [('isDraft',False),('tagName','v9.0.2')]:
                old=obj[key];obj[key]=bad;check(False);obj[key]=old
            obj['assets'].append(dict(name='Copia-9.0.3.zip',state='uploaded',digest='sha256:'+'2'*64));check(False)
            obj['assets'].pop();obj['assets'].pop();check(False)


if __name__=='__main__':unittest.main()
