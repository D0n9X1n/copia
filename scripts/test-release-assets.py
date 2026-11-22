"""Synthetic archives only. Never launch code supplied by a ZIP."""
import hashlib
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).resolve().parent
NAME = 'Copia-1.2.3.zip'
BASE = 'Copia.app/Contents/'
LOC = 'Resources/KeyboardShortcuts_KeyboardShortcuts.bundle/Contents/Resources/en.lproj/Localizable.strings'


class ArchiveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.download = self.work/'download'; self.download.mkdir()
        self.fixture = self.work/'tools'; self.fixture.mkdir()
        self.output = self.work/'unpacked'
        self.env = dict(PATH=f'{self.fixture}:/usr/bin:/bin')
        # check-archs.sh has its own positive and negative transcript tests.
        self.tool('lipo', 'echo "arm64 x86_64"')
        self.tool('xcrun', 'printf "platform MACOS\\nminos 26.0\\n"')
        self.signature = 'Identifier=app.copia.Copia\nAuthority=Apple Development: Fixture\nTeamIdentifier=AV5CFZA3T3\nTimestamp=Nov 1, 2026 at 12:00:00'
        self.sign()
        self.plist = dict(CFBundleVersion='1.2.3', CFBundleShortVersionString='1.2.3',
                          LSMinimumSystemVersion='26.0', CFBundleIdentifier='app.copia.Copia', CFBundleExecutable='Copia',
                          CFBundlePackageType='APPL', CFBundleIconName='AppIcon', CFBundleIconFile='AppIcon', LSUIElement=True)
        self.entries = {BASE+'MacOS/Copia': (0o100755, b'not runnable'), BASE+'Resources/Assets.car': (0o100644,b'icon'),
                        BASE+'Resources/AppIcon.icns': (0o100644,b'icon'), BASE+LOC: (0o100644,b'labels')}

    def tool(self, name, body):
        path = self.fixture/name; path.write_text('#!/bin/sh\n'+body+'\n'); path.chmod(0o755)

    def sign(self, valid=True):
        self.tool('codesign', f'case "$1" in --verify) exit {0 if valid else 1};; esac\ncat <<\'SIG\' >&2\n{self.signature}\nSIG')

    def write(self):
        self.entries[BASE+'Info.plist'] = (0o100644, plistlib.dumps(self.plist))
        path = self.download/NAME
        with zipfile.ZipFile(path, 'w') as archive:
            for name,(mode,data) in self.entries.items():
                member=zipfile.ZipInfo(name); member.external_attr=mode<<16
                archive.writestr(member,data)
        self.digest = hashlib.sha256(path.read_bytes()).hexdigest()
        (self.download/(NAME+'.sha256')).write_text(f'{self.digest}  {NAME}\n')

    def run_verify(self, ok, mode='signed'):
        result=subprocess.run([sys.executable,'-I',SCRIPTS/'release-assets.py','verify',self.download,
                               '1.2.3',self.output,mode], env=self.env, capture_output=True,text=True,timeout=15)
        self.assertEqual(ok,result.returncode==0,result.stderr)

    def test_extracts_verified_bundle_preserving_executable_mode(self):
        self.write(); self.run_verify(True)
        self.assertEqual(stat.S_IMODE((self.output/(BASE+'MacOS/Copia')).stat().st_mode),0o755)
        self.run_verify(False)  # Never reuse a directory, even on a rerun.

    @unittest.skipUnless(sys.platform == 'darwin', 'requires macOS archive metadata')
    def test_signed_app_round_trips_native_extended_metadata(self):
        self.write()
        source = self.work/'source'; source.mkdir(); (source/'Copia.app').mkdir()
        for name,(mode,data) in self.entries.items():
            path=source/name; path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data);path.chmod(mode & 0o777)
        binary=source/(BASE+'MacOS/Copia')
        subprocess.run(['xattr','-w','app.copia.fixture','retained',binary],check=True)
        archive=self.download/NAME
        subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',source/'Copia.app',archive],check=True)
        (self.download/(NAME+'.sha256')).write_text(f'{hashlib.sha256(archive.read_bytes()).hexdigest()}  {NAME}\n')
        self.run_verify(True)
        self.assertEqual(subprocess.check_output(['xattr','-p','app.copia.fixture',self.output/(BASE+'MacOS/Copia')]).strip(),b'retained')

    def test_refuses_unsafe_paths_and_types_before_extracting(self):
        for name, mode in [('../outside',0o100644),('/tmp/outside',0o100644),(BASE+'link',0o120777),
                           (BASE+'link/sub',0o010644),(BASE+'../escape',0o100644),('other',0o100644),
                           ('__MACOSX/Copia.app/Contents/._absent',0o100644),('__MACOSX/._../x',0o100644),
                           (BASE+'macos/copia',0o100644),(BASE+'MacOS/Copia/file',0o100644)]:
            with self.subTest(name=name):
                self.entries[name]=(mode,b'../outside'); self.write(); self.run_verify(False)
                del self.entries[name]
                self.assertFalse(self.output.exists()); self.assertFalse((self.work/'outside').exists())

    def test_rejects_malformed_asset_sets_and_checksums(self):
        self.write(); side=self.download/(NAME+'.sha256')
        for bad in [f'{"f"*64}  {NAME}\n',f'{self.digest}  ../{NAME}\n','']:
            side.write_text(bad); self.run_verify(False)
        self.write(); (self.download/'extra').touch(); self.run_verify(False)

    def test_codesign_verification_applies_apple_anchor_app_identifier_and_team(self):
        self.write()
        log=self.work/'verify-arguments';self.env['VERIFY_ARGS']=str(log)
        self.tool('codesign', 'if [ "$1" = --verify ]; then printf "%s\\n" "$@" > "$VERIFY_ARGS"; exit 0; fi\n'
                  + "cat <<'SIG' >&2\n"+self.signature+'\nSIG')
        self.run_verify(True)
        args=log.read_text().splitlines();self.assertIn('--strict',args);self.assertIn('--all-architectures',args)
        self.assertEqual(args[args.index('-R')+1], '=anchor apple generic and identifier "app.copia.Copia" and certificate leaf[subject.OU] = "AV5CFZA3T3"')
        self.assertEqual(args[-1],str(self.output/'Copia.app'))

    def test_signer_metadata_is_checked_on_each_architecture(self):
        self.write()
        self.tool('codesign', 'case "$1" in --verify) exit 0;; esac\n'
                  '[ "$2" = --architecture ] || exit 64\ncat <<\'SIG\' >&2\n'+self.signature+'\nSIG')
        self.run_verify(True)
        self.output=self.work/'bad-intel'
        self.tool('codesign', 'case "$1" in --verify) exit 0;; esac\n'
                  'if [ "$3" = x86_64 ]; then cat <<\'SIG\' >&2\n'+self.signature.replace('AV5CFZA3T3','WRONG')+
                  '\nSIG\nelse cat <<\'SIG\' >&2\n'+self.signature+'\nSIG\nfi')
        self.run_verify(False)

    def test_rejects_bad_signature_identity_timestamp_or_plist(self):
        self.write(); self.sign(False); self.run_verify(False)
        for field in ['Identifier=', 'Authority=Apple Development:', 'TeamIdentifier=', 'Timestamp=']:
            with self.subTest(field=field):
                self.output=self.work/field; self.tool('codesign', "cat <<'EOF' >&2\n"+self.signature.replace(field,'Other=')+'\nEOF'); self.run_verify(False)
        self.sign()
        for key in self.plist:
            old=self.plist[key]; self.plist[key]='wrong'; self.write(); self.output=self.work/key
            with self.subTest(key=key): self.run_verify(False,'unsigned')
            self.plist[key]=old

    def test_unsigned_still_checks_archived_resources_and_floors(self):
        self.write(); self.run_verify(True,'unsigned')
        for name in [BASE+LOC,BASE+'Resources/Assets.car',BASE+'Resources/AppIcon.icns']:
            item=self.entries.pop(name); self.write(); self.output=self.work/Path(name).name
            with self.subTest(name=name): self.run_verify(False,'unsigned')
            self.entries[name]=item
        self.tool('xcrun','echo "minos 27.0"'); self.output=self.work/'badfloor'; self.write(); self.run_verify(False,'unsigned')

    def test_transport_digest_and_exact_payload_before_unpacking(self):
        self.write(); outer=self.work/'transport.zip'
        def transport(extra, bad=False, swapped=False):
            with zipfile.ZipFile(outer,'w') as z:
                for item in self.download.iterdir(): z.write(item,item.name)
                if extra: z.writestr('notes.md','unexpected')
            digest=hashlib.sha256(outer.read_bytes()).hexdigest()
            return subprocess.run([sys.executable,'-I',SCRIPTS/'release-assets.py','receive',outer,
                                   'f'*64 if bad else digest, '0'*64 if swapped else self.digest, '1.2.3',self.output],capture_output=True)
        self.assertNotEqual(transport(True).returncode,0); self.assertNotEqual(transport(False,True).returncode,0)
        self.assertNotEqual(transport(False,swapped=True).returncode,0)
        self.output=self.work/'accepted'
        result=transport(False); self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.output/NAME).read_bytes(),(self.download/NAME).read_bytes())


if __name__ == '__main__': unittest.main()
