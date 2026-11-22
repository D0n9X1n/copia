"""Read-only release preflight. Emit notes only after Git and GitHub agree on all evidence."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_api import gh, pages, positive, require
from release_scope import markdown, release_scope
from version import STABLE, version


def green(repo, sha, workflow, names):
    query = f'repos/{repo}/actions/workflows/{workflow}/runs?branch=main&event=push&head_sha={sha}&per_page=100'
    runs = pages(query, 'workflow_runs')
    require(len({r['id'] for r in runs}) == len(runs), 'duplicate workflow run')
    run = max(runs, key=lambda r: (positive(r['run_number']), positive(r['run_attempt'])))
    rid, attempt = positive(run['id']), positive(run['run_attempt'])
    latest = gh(f'repos/{repo}/actions/runs/{rid}')
    for row in (run, latest):
        require(row['id'] == rid and row['run_attempt'] == attempt and row['status'] == 'completed' and
                row['conclusion'] == 'success' and row['head_sha'] == sha and row['head_branch'] == 'main' and
                row['event'] == 'push' and row['head_repository']['full_name'].lower() == repo.lower() and
                row['path'] == '.github/workflows/'+workflow, f'{workflow}: latest exact main push is not green')
    jobs = pages(f'repos/{repo}/actions/runs/{rid}/attempts/{attempt}/jobs?per_page=100', 'jobs')
    url = f'https://github.com/{repo}/actions/runs/{rid}'
    links = []
    for name in names:
        required = [j for j in jobs if j['name'] == name]
        require(len(required) == 1, f'missing or duplicated required job: {name}'); job = required[0]
        require(job['run_id'] == rid and job['head_sha'] == sha and job['run_attempt'] == attempt and
                job['status'] == 'completed' and job['conclusion'] == 'success', f'{name}: required job not green')
        links.append(f'[{name}]({url}/job/{positive(job["id"])})')
    return rid, attempt, f'[{workflow} attempt {attempt}]({url}/attempts/{attempt}) · ' + ' · '.join(links)


def benchmark(repo, rid, attempt):
    artifacts = pages(f'repos/{repo}/actions/runs/{rid}/artifacts?per_page=100', 'artifacts')
    found = [a for a in artifacts if a['name'] == f'bench-{attempt}']
    require(len(found) == 1 and found[0]['expired'] is False, 'missing accepted benchmark artifact')
    a = found[0]; aid = positive(a['id'])
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)/'bench.zip'
        with path.open('xb') as out:
            subprocess.run(['gh','api','--hostname','github.com',f'repos/{repo}/actions/artifacts/{aid}/zip'], stdout=out, check=True, timeout=90)
        require(path.stat().st_size <= 8*1024**2 and 'sha256:'+hashlib.sha256(path.read_bytes()).hexdigest() == a['digest'],
                'oversized benchmark or digest mismatch')
        with zipfile.ZipFile(path) as z:
            require(z.namelist() == ['bench.json'] and z.infolist()[0].file_size <= 8*1024**2, 'unexpected benchmark artifact')
            b = json.loads(z.read('bench.json'))
    # idleCPUPercent is rounded to three decimals in JSON. The bench exit status and
    # empty failed array use the unrounded strict comparison, not this display value.
    require(b['failed'] == [] and positive(b['privateBoardPolls']) and b['idleSeconds'] == 60 and b['opens'] == 50 and
            type(b['idleCPUPercent']) in (float,int) and 0 <= b['idleCPUPercent'] <= .15 and
            b['arch'] in ('arm64','x86_64') and b['path'] in ('proxy','screenCaptureKit'), 'invalid unprofiled benchmark')
    coverage = '120 Hz presented-frame coverage unavailable (proxy)'
    if b['path'] == 'screenCaptureKit':
        # BenchPlan uses 119.5 Hz, so a nominal 120 Hz display rounds into the gate.
        hz = b['refreshHz']
        require(type(hz) in (int,float) and 0 < hz < float('inf') and b['presentedFramesGate'] is (hz >= 119.5), 'invalid refresh evidence')
        coverage = f'{hz:g} Hz; 120 Hz presented-frame checks ' + ('gated' if b['presentedFramesGate'] else 'not exercised')
    return f'[Unprofiled benchmark](https://github.com/{repo}/actions/runs/{rid}/artifacts/{aid}): {b["idleCPUPercent"]}% idle CPU over 60 s (strict budget <0.15%), {b["arch"]}, {coverage}.'


def release_jobs(repo, sha, rid, attempt):
    rows = pages(f'repos/{repo}/actions/runs/{rid}/attempts/{attempt}/jobs?per_page=100', 'jobs')
    links = []
    for name in ('validate', 'package', 'intel', 'publish'):
        matches = [j for j in rows if j['name'] == name]
        require(len(matches) == 1, f'missing tag job: {name}')
        j = matches[0]
        require(j['run_id'] == rid and j['run_attempt'] == attempt and j['head_sha'] == sha and
                ((j['status'], j['conclusion']) == ('in_progress', None) if name == 'publish' else
                 (j['status'], j['conclusion']) == ('completed', 'success')), f'unexpected tag job state: {name}')
        links.append(f'[{name}](https://github.com/{repo}/actions/runs/{rid}/job/{positive(j["id"])})')
    return ', '.join(links)


def package_evidence(ver):
    """Bind each archive's reviewed digest and native runtime line to its own name, architecture and OS."""
    env = {key: os.environ[key] for key in ('TOOLCHAIN','COVERAGE_ARM64','COVERAGE_X86_64','REVIEWED_ARM64','REVIEWED_X86_64')}
    require(all(value.isprintable() and value == value.strip() for value in env.values()), 'control characters in package evidence')
    version = r'[0-9]+\.[0-9]+(?:\.[0-9]+)?'
    require(re.fullmatch(rf'Built with Xcode {version}, Build version [0-9A-Za-z]+; Apple Swift version {version}(?: \([^()\n;]+\))?; macOS SDK {version}\.',
                         env['TOOLCHAIN']), 'incomplete toolchain evidence')
    cycles = r'passed [1-9][0-9]*0 cycles'
    for arch, os_pattern in (('arm64', version), ('x86_64', r'26\.[0-9]+(?:\.[0-9]+)?')):
        name = re.escape(f'Copia-{ver}-{arch}.zip')
        line = env['COVERAGE_' + arch.upper()]
        require(re.fullmatch(rf'`{name}`: packaged `--selftest` {cycles} on native {arch}, macOS ({os_pattern}); macOS 26: (?:tested|not tested)\.', line),
                f'{arch} runtime evidence does not name its archive, native architecture and OS')
        major = re.search(r'macOS ([0-9]+)', line)[1]
        require(line.endswith('macOS 26: tested.') == (major == '26'), f'{arch} macOS 26 flag contradicts the observed OS')
        require(re.fullmatch('[0-9a-f]{64}', env['REVIEWED_' + arch.upper()]), f'missing reviewed {arch} ZIP digest')
    require(env['REVIEWED_ARM64'] != env['REVIEWED_X86_64'], 'architecture downloads are identical')
    rows = [env['TOOLCHAIN'], env['COVERAGE_ARM64'], env['COVERAGE_X86_64'],
            'Rosetta: not tested on these signed release archives.']
    rows += [f'ZIP SHA-256 (`Copia-{ver}-{arch}.zip`): `{env["REVIEWED_" + arch.upper()]}`' for arch in ('arm64', 'x86_64')]
    return ''.join(f'\n- {row}' for row in rows)


def evidence(root, publishing=False):
    repo, tag = os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_REF_NAME']; url=f'https://github.com/{repo}'
    def git(*args):
        return subprocess.check_output(['git','-C',root,*args], text=True, timeout=90).rstrip('\n')
    ver = version(root/'VERSION', tag)
    require(git('rev-parse','--is-shallow-repository') == 'false', 'release needs full history')
    git('fetch','--tags','origin','+refs/heads/main:refs/remotes/origin/main', f'refs/tags/{tag}:refs/tags/{tag}')
    # Fetch doesn't drop deleted tags. Don't compute a predecessor from stale local refs.
    remote = {ref: oid for oid, ref in (row.split('\t') for row in git('ls-remote','--refs','--tags','origin').splitlines())}
    for name in git('tag','--list').splitlines():
        if re.fullmatch('v'+STABLE,name):
            ref='refs/tags/'+name
            require(remote.get(ref)==git('rev-parse','--verify',ref), 'missing or changed remote release tag')
    sha = git('rev-parse','--verify',f'refs/tags/{tag}^{{commit}}')
    event = os.environ['GITHUB_SHA']
    require(re.fullmatch('[0-9a-f]{40}', event) and git('rev-parse','HEAD') == sha == git('rev-parse','--verify',event+'^{commit}'),
            'event, tag and checkout must match')
    committed = subprocess.check_output(['git','-C',root,'show',sha+':VERSION'], timeout=90)
    require(committed == (root/'VERSION').read_bytes(), 'tracked VERSION differs from validated working copy')
    git('merge-base','--is-ancestor',sha,'refs/remotes/origin/main')
    tags = [t for t in git('tag','--merged',sha+'^').splitlines() if re.fullmatch('v'+STABLE,t)]
    require(tags, 'no stable release predecessor')
    prior = git('describe','--tags','--abbrev=0',*(arg for t in tags for arg in ('--match',t)),sha+'^')
    require(tuple(map(int,prior[1:].split('.'))) < tuple(map(int,ver.split('.'))), 'non-increasing release version')
    revs=f'{prior}..{sha}'; commits=git('rev-list','--topo-order',revs).splitlines()
    ci, attempt, ci_link = green(repo,sha,'ci.yml',('build-test-bench','intel'))
    _, _, wiki_link = green(repo,sha,'publish-wiki.yml',('publish',)); bench=benchmark(repo,ci,attempt)
    mid, merges, resolved, other = release_scope(repo,tag,sha,commits,git)
    changes='\n'.join(f'- {markdown(git("show","-s","--format=%s",oid))} ([{oid[:9]}]({url}/commit/{oid}))' for oid in commits)
    merge_links=', '.join(f'[#{n}]({url}/pull/{n})' for n in sorted(merges))
    rid, attempt = (positive(int(os.environ[key])) for key in ('GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT'))
    run=f'{url}/actions/runs/{rid}/attempts/{attempt}'
    jobs=release_jobs(repo,sha,rid,attempt) if publishing else 'read-only preflight'
    package = ''
    if publishing:
        package = package_evidence(ver)
    # Last network check, including on the publisher's final invocation. Never mutate tracker state.
    for item in pages(f'repos/{repo}/issues?state=open&per_page=100'):
        positive(item['number']); require(isinstance(item.get('pull_request'),dict),'open repository issue blocks publication')
    return f'''# Copia {tag}

## Downloads

- Apple silicon (M-series), macOS 26+: [Copia-{ver}-arm64.zip]({url}/releases/download/{tag}/Copia-{ver}-arm64.zip). Compare its [SHA-256]({url}/releases/download/{tag}/Copia-{ver}-arm64.zip.sha256) before unpacking.
- Intel, macOS 26+: [Copia-{ver}-x86_64.zip]({url}/releases/download/{tag}/Copia-{ver}-x86_64.zip). Compare its [SHA-256]({url}/releases/download/{tag}/Copia-{ver}-x86_64.zip.sha256) before unpacking.
- Not sure which? Apple menu → About This Mac: **Chip** means Apple silicon, **Processor** means Intel. Each app contains only its own architecture; before publication the Intel app runs as native Intel x86_64 on macOS 26 (see Verification).
- Apple Development signed, not notarized. Move Copia.app to Applications; use System Settings → Privacy & Security → Open Anyway if blocked.

## Resolved issues

{chr(10).join(resolved) or 'No issues proven resolved in this range.'}

## Other milestone closures (not credited as release fixes)

{chr(10).join(other) or 'None.'}

## Changes since {prior}

{changes}

## Verification

- [Tag {tag}]({url}/tree/{tag}) · [source `{sha}`]({url}/commit/{sha}) · [milestone]({url}/milestone/{mid}) · merged PRs: {merge_links}.
- Exact main push: {ci_link}; {wiki_link}.
- {bench}
- [Tag workflow]({run}): {jobs}.{package}'''


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkout',type=Path)
    parser.add_argument('--publishing',action='store_true')
    args=parser.parse_args()
    print(evidence(args.checkout.resolve(),args.publishing))
