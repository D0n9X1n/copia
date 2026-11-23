"""Verify the four public assets: one ZIP and checksum per architecture. Extract only regular files and directories, never run them."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time
import zipfile

SCRIPTS = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(SCRIPTS))  # -I: trust this checked-out directory, never the downloaded archive.
from version import STABLE


def require(ok, message):
    if not ok:
        raise ValueError(message)


ARCHS = ('arm64', 'x86_64')


def names(version):
    require(re.fullmatch(STABLE, version), 'invalid version')
    return {arch: (f'Copia-{version}-{arch}.zip', f'Copia-{version}-{arch}.zip.sha256') for arch in ARCHS}


def all_names(version):
    return {name for pair in names(version).values() for name in pair}


def sha(path):
    with path.open('rb') as f:
        digest = hashlib.sha256()
        for block in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(block)
        return digest.hexdigest()


def assets(directory, version):
    require({p.name for p in directory.iterdir()} == all_names(version), 'unexpected release asset set')
    for path in directory.iterdir():
        require(stat.S_ISREG(path.lstat().st_mode), 'not a regular release asset')
    archives = {}
    for arch, (name, sidecar) in names(version).items():
        archive = directory/name
        require((directory/sidecar).stat().st_size < 256 and
                (directory/sidecar).read_bytes() == f'{sha(archive)}  {name}\n'.encode(), f'{arch} checksum mismatch')
        archives[arch] = archive
    require(len({sha(a) for a in archives.values()}) == len(ARCHS), 'architecture downloads are identical')
    return archives


def unpack(path, dest, allowed, app=False):
    # One ZIP parser for inspection AND extraction. No symlinks (including intermediate
    # components), special files, case-fold aliases or duplicate paths. AppleDouble
    # metadata may only be restored onto an existing validated bundle member.
    with zipfile.ZipFile(path) as z:
        entries = z.infolist()
        require(entries and len(entries) <= 10000 and sum(i.file_size for i in entries) <= 512*1024**2,
                'empty or oversized archive')
        seen, files, components, sidecars = set(), set(), {}, {}
        for info in entries:
            parts = info.orig_filename.removesuffix('/').split('/')
            require((parts[0] in allowed or (app and parts[0] == "__MACOSX")) and all(re.fullmatch(r'[A-Za-z0-9_+@ .-]+', p) and
                    p not in ('.', '..') and not p.endswith((' ', '.')) for p in parts), 'unsafe archive path')
            mode = info.external_attr >> 16
            kind = stat.S_IFMT(mode)
            require(kind in (0, stat.S_IFDIR if info.is_dir() else stat.S_IFREG) and not mode & 0o7000,
                    'unsafe archive member type or permissions')
            require(app or (len(parts) == 1 and not info.is_dir()), 'unexpected transport member')
            member = '/'.join(parts)
            require(member not in seen, 'duplicate archive member'); seen.add(member)
            if parts[0] == '__MACOSX':
                require(len(parts) == 1 or parts[1] == 'Copia.app' or parts == ['__MACOSX','._Copia.app'],
                        'metadata outside app')
                if not info.is_dir():
                    require(len(parts) >= 2 and parts[-1].startswith('._') and parts[-1][2:] not in ('','.','..'),
                            'invalid metadata name')
                    sidecars[member] = '/'.join(parts[1:-1] + [parts[-1][2:]])
            elif app:
                require(not any(p.startswith('._') for p in parts), 'ambiguous inline metadata')
            if not info.is_dir():
                files.add(member)
            for n in range(1, len(parts)+1):
                prefix = '/'.join(parts[:n]); key = prefix.lower()
                require(components.setdefault(key, prefix) == prefix, 'aliased path')
        require(all(str(p) not in files for name in components.values() for p in Path(name).parents),
                'member under non-directory')
        require(app or files == set(allowed), 'missing transport member')
        require(all(target in components.values() for target in sidecars.values()), 'orphan metadata')
        dest.mkdir(mode=0o700)  # Must be a new directory, never a previous extraction.
        metadata_entries = []
        for info in entries:
            if info.filename.startswith('__MACOSX/'):
                if info.is_dir():
                    continue
                target = dest/sidecars[info.filename]; target = target.with_name('._'+target.name)
            else:
                target = dest/info.filename
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True); metadata_entries.append((target, info)); continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(info) as src, target.open('xb') as out:
                shutil.copyfileobj(src, out)
            if info.filename not in sidecars:
                metadata_entries.append((target, info))
        if sidecars:
            # Merge AppleDouble resources/xattrs natively without handing a second ZIP
            # parser the original archive. No archive paths or symlinks are followed.
            subprocess.run(['/usr/sbin/dot_clean','--keep=dotbar',dest],check=True)
            require(not any(dest.rglob('._*')), 'unmerged package metadata')
        for target, info in sorted(metadata_entries, reverse=True):
            metadata(target, info, app)


def metadata(path, info, app):
    if app:
        # ZipFile.extractall discards execute bits: restore the shipped mode and mtime.
        path.chmod(stat.S_IMODE(info.external_attr >> 16))
        t = time.mktime((*info.date_time, 0, 0, -1)); os.utime(path, (t, t))


def receive(outer, digest, reviewed, version, dest):
    require(re.fullmatch('[0-9a-f]{64}', digest) and sha(outer) == digest, 'immutable artifact digest mismatch')
    unpack(outer, dest, all_names(version))
    for arch, archive in assets(dest, version).items():
        require(sha(archive) == reviewed[arch], f'{arch} ZIP differs from the reviewed package')


def verify(directory, version, dest, mode):
    require(mode in ('signed', 'unsigned'), 'invalid verification mode')
    archives = assets(directory, version)
    dest.mkdir(mode=0o700)  # Must be a new directory, never a previous extraction.
    for arch, archive in archives.items():
        unpack(archive, dest/arch, {'Copia.app'}, app=True)
        verify_app(dest/arch/'Copia.app', arch, version, mode)


def verify_app(app, arch, version, mode):
    contents = app/'Contents'; binary = contents/'MacOS/Copia'
    expected = dict(CFBundleVersion=version, CFBundleShortVersionString=version,
                    LSMinimumSystemVersion='26.0', CFBundleIdentifier='app.copia.Copia', CFBundleExecutable='Copia',
                    CFBundlePackageType='APPL', CFBundleIconFile='AppIcon', CFBundleIconName='AppIcon', LSUIElement=True)
    plist = plistlib.loads((contents/'Info.plist').read_bytes())
    for key, value in expected.items():
        require(type(plist[key]) is type(value) and plist[key] == value, f'wrong archived {key}')
    for resource in ('Assets.car', 'AppIcon.icns',
                     'KeyboardShortcuts_KeyboardShortcuts.bundle/Contents/Resources/en.lproj/Localizable.strings'):
        p = contents/'Resources'/resource
        require(p.is_file() and p.stat().st_size > 0, f'missing archived resource: {resource}')
    require(binary.is_file() and os.access(binary, os.X_OK), 'missing archived executable or execute bit')
    subprocess.run([SCRIPTS/'check-archs.sh', binary, arch], check=True)
    if mode == 'signed':
        subprocess.run(['codesign', '--verify', '--all-architectures', '--deep', '--strict', '-R',
                        '=anchor apple generic and identifier "app.copia.Copia" and certificate leaf[subject.OU] = "AV5CFZA3T3"', app], check=True)
        desc = subprocess.run(['codesign', '-dvvv', '--architecture', arch, app], capture_output=True, text=True, check=True).stderr.splitlines()
        require('Identifier=app.copia.Copia' in desc and 'TeamIdentifier=AV5CFZA3T3' in desc and
                next((s for s in desc if s.startswith('Authority=')), '').startswith('Authority=Apple Development: ') and
                any(re.fullmatch(r'Timestamp=.*\d.*', s) for s in desc), f'unexpected {arch} signing identity or timestamp')


if __name__ == '__main__':
    if sys.argv[1] == 'receive':
        _, _, path, digest, arm, intel, ver, dest = sys.argv
        receive(Path(path), digest, dict(zip(ARCHS, (arm, intel))), ver, Path(dest))
    elif sys.argv[1] == 'verify':
        _, _, directory, ver, dest, mode = sys.argv
        verify(Path(directory), ver, Path(dest), mode)
    elif sys.argv[1] == 'draft':
        _, _, response, directory, ver = sys.argv
        directory = Path(directory); assets(directory, ver)
        draft = json.loads(Path(response).read_text()); rows = draft['assets']
        require(draft['isDraft'] is True and draft['tagName'] == 'v'+ver and len(rows) == 4 and
                {a['name'] for a in rows} == all_names(ver), 'unexpected draft or remote assets')
        for a in rows:
            require(a['state'].lower() == 'uploaded' and a['digest'] == 'sha256:'+sha(directory/a['name']),
                    'remote draft asset changed')
    else:
        sys.exit('expected receive, verify or draft')
