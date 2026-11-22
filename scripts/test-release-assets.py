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
ARCHS = ('arm64', 'x86_64')
NAMES = {arch: f'Copia-1.2.3-{arch}.zip' for arch in ARCHS}
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
        # check-archs.sh has its own transcript tests; here the fake lipo reports what each fixture binary claims.
        self.tool('lipo', '[ "$1" = -archs ] && sed -n "s/^arch://p" "$2"')
        self.tool('xcrun', 'printf "platform MACOS\\nminos 26.0\\n"')
        self.signature = 'Identifier=app.copia.Copia\nAuthority=Apple Development: Fixture\nTeamIdentifier=AV5CFZA3T3\nTimestamp=Nov 1, 2026 at 12:00:00'
        self.sign()
        self.plist = dict(CFBundleVersion='1.2.3', CFBundleShortVersionString='1.2.3',
                          LSMinimumSystemVersion='26.0', CFBundleIdentifier='app.copia.Copia', CFBundleExecutable='Copia',
                          CFBundlePackageType='APPL', CFBundleIconName='AppIcon', CFBundleIconFile='AppIcon', LSUIElement=True)
        self.binaries = {arch: f'arch:{arch}\n'.encode() for arch in ARCHS}
        self.entries = {BASE+'Resources/Assets.car': (0o100644,b'icon'),
                        BASE+'Resources/AppIcon.icns': (0o100644,b'icon'), BASE+LOC: (0o100644,b'labels')}
        self.extra = {arch: {} for arch in ARCHS}

    def tool(self, name, body):
        path = self.fixture/name; path.write_text('#!/bin/sh\n'+body+'\n'); path.chmod(0o755)

    def sign(self, valid=True):
        self.tool('codesign', f'case "$1" in --verify) exit {0 if valid else 1};; esac\ncat <<\'SIG\' >&2\n{self.signature}\nSIG')

    def write(self, sidecars=True):
        self.digests = {}
        for arch in ARCHS:
            entries = dict(self.entries, **{BASE+'Info.plist': (0o100644, plistlib.dumps(self.plist)),
                                            BASE+'MacOS/Copia': (0o100755, self.binaries[arch])}, **self.extra[arch])
            path = self.download/NAMES[arch]
            with zipfile.ZipFile(path, 'w') as archive:
                for name,(mode,data) in entries.items():
                    member=zipfile.ZipInfo(name); member.external_attr=mode<<16
                    archive.writestr(member,data)
            self.digests[arch] = hashlib.sha256(path.read_bytes()).hexdigest()
            if sidecars:
                (self.download/(NAMES[arch]+'.sha256')).write_text(f'{self.digests[arch]}  {NAMES[arch]}\n')

    def run_verify(self, ok, mode='signed'):
        result=subprocess.run([sys.executable,'-I',SCRIPTS/'release-assets.py','verify',self.download,
                               '1.2.3',self.output,mode], env=self.env, capture_output=True,text=True,timeout=15)
        self.assertEqual(ok,result.returncode==0,result.stderr)
        return result

    def next_output(self, name):
        self.output = self.work/name

    def test_extracts_each_architecture_into_its_own_new_bundle(self):
        self.write(); self.run_verify(True)
        for arch in ARCHS:
            binary = self.output/arch/(BASE+'MacOS/Copia')
            self.assertEqual(stat.S_IMODE(binary.stat().st_mode),0o755)
            self.assertEqual(binary.read_bytes(), self.binaries[arch])
        self.run_verify(False)  # Never reuse a directory, even on a rerun.

    def test_each_zip_must_hold_exactly_its_named_architecture(self):
        cases = [('swapped', {'arm64': b'arch:x86_64\n', 'x86_64': b'arch:arm64\n'}),
                 ('universal under a thin name', {'arm64': b'arch:arm64 x86_64\n'}),
                 ('wrong Intel slice', {'x86_64': b'arch:arm64\n'}),
                 ('missing slice', {'arm64': b'arch:\n'})]
        for label, binaries in cases:
            with self.subTest(case=label):
                saved = dict(self.binaries); self.binaries.update(binaries)
                self.write(); self.next_output(label.replace(' ','-')); self.run_verify(False, 'unsigned')
                self.binaries = saved

    def test_asset_set_is_exactly_both_architectures(self):
        self.write()
        legacy = self.download/'Copia-1.2.3.zip'; legacy.write_bytes(b'old universal')
        self.run_verify(False); legacy.unlink()
        for arch in ARCHS:
            with self.subTest(missing=arch):
                held = {p: p.read_bytes() for p in self.download.glob(f'*-{arch}.zip*')}
                for p in held: p.unlink()
                self.next_output('missing-'+arch); self.run_verify(False)
                for p, data in held.items(): p.write_bytes(data)
        self.next_output('complete'); self.run_verify(True)

    def test_identical_archives_are_rejected(self):
        self.binaries['x86_64'] = self.binaries['arm64']; self.write(sidecars=False)
        data = (self.download/NAMES['arm64']).read_bytes()
        (self.download/NAMES['x86_64']).write_bytes(data)
        for arch in ARCHS:
            (self.download/(NAMES[arch]+'.sha256')).write_text(f'{hashlib.sha256(data).hexdigest()}  {NAMES[arch]}\n')
        self.run_verify(False, 'unsigned')

    def test_rejects_malformed_or_swapped_sidecars(self):
        self.write(); side=self.download/(NAMES['arm64']+'.sha256')
        for bad in [f'{"f"*64}  {NAMES["arm64"]}\n', f'{self.digests["arm64"]}  ../{NAMES["arm64"]}\n', '',
                    f'{self.digests["x86_64"]}  {NAMES["arm64"]}\n', f'{self.digests["arm64"]}  {NAMES["x86_64"]}\n']:
            with self.subTest(sidecar=bad):
                side.write_text(bad); self.next_output(str(abs(hash(bad)))); self.run_verify(False)
        self.write(); (self.download/'extra').touch(); self.next_output('extra'); self.run_verify(False)

    @unittest.skipUnless(sys.platform == 'darwin', 'requires macOS archive metadata')
    def test_signed_app_round_trips_native_extended_metadata(self):
        self.write()
        for arch in ARCHS:
            source = self.work/('source-'+arch); source.mkdir(); (source/'Copia.app').mkdir()
            entries = dict(self.entries, **{BASE+'Info.plist': (0o100644, plistlib.dumps(self.plist)),
                                            BASE+'MacOS/Copia': (0o100755, self.binaries[arch])})
            for name,(mode,data) in entries.items():
                path=source/name; path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data);path.chmod(mode & 0o777)
            subprocess.run(['xattr','-w','app.copia.fixture','retained-'+arch,source/(BASE+'MacOS/Copia')],check=True)
            archive=self.download/NAMES[arch]; archive.unlink()
            subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',source/'Copia.app',archive],check=True)
            (self.download/(NAMES[arch]+'.sha256')).write_text(f'{hashlib.sha256(archive.read_bytes()).hexdigest()}  {NAMES[arch]}\n')
        self.run_verify(True)
        for arch in ARCHS:
            value = subprocess.check_output(['xattr','-p','app.copia.fixture',self.output/arch/(BASE+'MacOS/Copia')]).strip()
            self.assertEqual(value, ('retained-'+arch).encode())

    def test_refuses_unsafe_paths_and_types_before_extracting(self):
        for name, mode in [('../outside',0o100644),('/tmp/outside',0o100644),(BASE+'link',0o120777),
                           (BASE+'link/sub',0o010644),(BASE+'../escape',0o100644),('other',0o100644),
                           ('__MACOSX/Copia.app/Contents/._absent',0o100644),('__MACOSX/._../x',0o100644),
                           (BASE+'macos/copia',0o100644),(BASE+'MacOS/Copia/file',0o100644)]:
            for arch in ARCHS:
                with self.subTest(name=name, arch=arch):
                    self.extra[arch] = {name: (mode,b'../outside')}; self.write(); self.run_verify(False)
                    self.extra[arch] = {}
                    self.assertFalse((self.output/'arm64').exists() and (self.output/'x86_64').exists())
                    self.assertFalse((self.work/'outside').exists())
                    if self.output.exists(): self.next_output(f'{arch}-{abs(hash(name))}')

    def test_codesign_verification_applies_apple_anchor_app_identifier_and_team(self):
        self.write()
        log=self.work/'verify-arguments';self.env['VERIFY_ARGS']=str(log)
        self.tool('codesign', 'if [ "$1" = --verify ]; then printf "%s\\n" "$@" >> "$VERIFY_ARGS"; exit 0; fi\n'
                  + "cat <<'SIG' >&2\n"+self.signature+'\nSIG')
        self.run_verify(True)
        args=log.read_text().splitlines();self.assertIn('--strict',args);self.assertIn('--all-architectures',args)
        self.assertEqual(args.count('-R'), 2)
        self.assertEqual(args[args.index('-R')+1], '=anchor apple generic and identifier "app.copia.Copia" and certificate leaf[subject.OU] = "AV5CFZA3T3"')
        for arch in ARCHS: self.assertIn(str(self.output/arch/'Copia.app'), args)

    def test_signer_metadata_is_checked_for_the_architecture_each_zip_holds(self):
        self.write()
        log=self.work/'describe'; self.env['DESCRIBE']=str(log)
        self.tool('codesign', 'case "$1" in --verify) exit 0;; esac\n'
                  '[ "$2" = --architecture ] || exit 64\necho "$3 $4" >> "$DESCRIBE"\ncat <<\'SIG\' >&2\n'+self.signature+'\nSIG')
        self.run_verify(True)
        self.assertEqual(sorted(log.read_text().split('\n')[:-1]),
                         sorted(f'{arch} {self.output/arch/"Copia.app"}' for arch in ARCHS))
        self.next_output('bad-intel')
        self.tool('codesign', 'case "$1" in --verify) exit 0;; esac\n'
                  'if [ "$3" = x86_64 ]; then cat <<\'SIG\' >&2\n'+self.signature.replace('AV5CFZA3T3','WRONG')+
                  '\nSIG\nelse cat <<\'SIG\' >&2\n'+self.signature+'\nSIG\nfi')
        self.run_verify(False)

    def test_rejects_bad_signature_identity_timestamp_or_plist(self):
        self.write(); self.sign(False); self.run_verify(False)
        for field in ['Identifier=', 'Authority=Apple Development:', 'TeamIdentifier=', 'Timestamp=']:
            with self.subTest(field=field):
                self.next_output(field); self.tool('codesign', "cat <<'EOF' >&2\n"+self.signature.replace(field,'Other=')+'\nEOF'); self.run_verify(False)
        self.sign()
        for key in self.plist:
            old=self.plist[key]; self.plist[key]='wrong'; self.write(); self.next_output(key)
            with self.subTest(key=key): self.run_verify(False,'unsigned')
            self.plist[key]=old

    def test_unsigned_still_checks_archived_resources_and_floors(self):
        self.write(); self.run_verify(True,'unsigned')
        for name in [BASE+LOC,BASE+'Resources/Assets.car',BASE+'Resources/AppIcon.icns']:
            item=self.entries.pop(name); self.write(); self.next_output(Path(name).name)
            with self.subTest(name=name): self.run_verify(False,'unsigned')
            self.entries[name]=item
        self.tool('xcrun','echo "minos 27.0"'); self.next_output('badfloor'); self.write(); self.run_verify(False,'unsigned')

    def test_transport_digest_binds_each_reviewed_archive_before_unpacking(self):
        self.write(); outer=self.work/'transport.zip'
        def transport(extra=False, bad=False, reviewed=None):
            with zipfile.ZipFile(outer,'w') as z:
                for item in self.download.iterdir(): z.write(item,item.name)
                if extra: z.writestr('notes.md','unexpected')
            digest=hashlib.sha256(outer.read_bytes()).hexdigest()
            arm, intel = reviewed or (self.digests['arm64'], self.digests['x86_64'])
            if self.output.exists(): self.next_output(str(len(list(self.work.iterdir()))))
            return subprocess.run([sys.executable,'-I',SCRIPTS/'release-assets.py','receive',outer,
                                   'f'*64 if bad else digest, arm, intel, '1.2.3',self.output],capture_output=True,text=True)
        self.assertNotEqual(transport(extra=True).returncode,0); self.assertNotEqual(transport(bad=True).returncode,0)
        for reviewed in [('0'*64, self.digests['x86_64']), (self.digests['arm64'], '0'*64),
                         (self.digests['x86_64'], self.digests['arm64'])]:
            with self.subTest(reviewed=reviewed): self.assertNotEqual(transport(reviewed=reviewed).returncode,0)
        result=transport(); self.assertEqual(result.returncode,0,result.stderr)
        for arch in ARCHS:
            self.assertEqual((self.output/NAMES[arch]).read_bytes(),(self.download/NAMES[arch]).read_bytes())


if __name__ == '__main__': unittest.main()
