"""Source policy across job boundaries; actionlint separately validates Actions syntax."""
from pathlib import Path
import re
import unittest

WORKFLOWS = Path(__file__).resolve().parents[1]/'.github/workflows'


def jobs(text):
    names = re.split(r'^  ([\w-]+):\s*$', text.split('\njobs:\n')[1], flags=re.M)
    return dict(zip(names[1::2], names[2::2]))


class Workflows(unittest.TestCase):
    def test_only_pr_runs_share_a_cancellable_ref_group(self):
        ci = (WORKFLOWS/'ci.yml').read_text()
        group = "${{ github.workflow }}-${{ github.event_name }}-${{ github.event_name == 'pull_request' && github.ref || github.sha }}"
        self.assertIn('  group: ' + group + '\n', ci)
        self.assertIn("  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n", ci)

    def test_ci_no_tag_and_one_unprofiled_gate(self):
        text=(WORKFLOWS/'ci.yml').read_text(); events=text.split('permissions:')[0]
        self.assertRegex(events,r'push:\s*branches: \[main\]'); self.assertIn('pull_request:',events)
        self.assertNotIn('tags:',events); steps=text.split('      - name: ')
        if_clause=r"if:.*steps\.benchmark\.outcome\s*!=\s*'skipped'"
        self.assertRegex(next(s for s in steps if s.startswith('Upload benchmark')),if_clause)
        self.assertRegex(next(s for s in steps if s.startswith('Benchmark (')),r'mktemp -d')
        # macOS's stock bash 3.2 does not enable -e in command substitutions by default.
        # A nested build failure must not silently select an older binary.
        self.assertNotIn('$(swift build -c release --show-bin-path)/copia-bench',text)
        bench=[s for s in steps if '--json' in s and 'xctrace' not in s]; self.assertEqual(len(bench),1)
        self.assertNotRegex(bench[0],r'continue-on-error|\|\||until |for |while ')
        self.assertIn('prove-package.sh unsigned',text); self.assertRegex(text,r'(?s)name: bench-.*?if-no-files-found: error')

    def test_ci_smokes_each_architecture_natively_from_digest_bound_bytes(self):
        stages=jobs((WORKFLOWS/'ci.yml').read_text()); build=stages['build-test-bench']; intel=stages['intel']
        self.assertIn('    runs-on: xcode-27\n',build); self.assertIn('    runs-on: macos-26-intel\n',intel)
        self.assertRegex(build,r'native=\$\(scripts/prove-package\.sh --native-arch\); test "\$native" = arm64')
        self.assertRegex(intel,r'native=\$\(scripts/prove-package\.sh --native-arch\); test "\$native" = x86_64')
        self.assertIn('os=$(sw_vers -productVersion); [[ "$os" =~ ^26\\.[0-9]+(\\.[0-9]+)?$ ]]',intel)
        self.assertIn('    needs: build-test-bench\n',intel)
        for key in ('artifact-id','artifact-digest','zip-sha-arm64','zip-sha-x86_64'): self.assertIn(key,build)
        # The four verified files travel as one immutable artifact, received by ID and digest, never by name.
        self.assertRegex(build,r'(?s)name: unsigned-packages-\$\{\{ github\.run_attempt \}\}.*?compression-level: 0')
        self.assertNotIn('download-artifact',intel)
        self.assertRegex(intel,r'(?s)actions/artifacts/\$ARTIFACT_ID/zip.*?release-assets\.py receive .*?prove-package\.sh unsigned "\$WORK/proof" "\$WORK/assets"')
        self.assertRegex(intel,r'    permissions:\n      actions: read\n      contents: read\n')
        for forbidden in ('secrets.','environment:','swift build','build-app.sh','continue-on-error','contents: write'):
            self.assertNotIn(forbidden,intel)

    def test_every_main_wiki_push_checks_its_own_sha_before_mirroring(self):
        wiki = (WORKFLOWS/'publish-wiki.yml').read_text()
        self.assertNotIn('concurrency:',wiki)  # A pending run in a shared group can be dropped.
        publish = jobs(wiki)['publish']
        self.assertIn('fetch-depth: 0',publish)
        self.assertIn('ref: ${{ github.sha }}',publish)
        validation = publish.split('      - name: Check wiki',1)[1].split('      - name:',1)[0]
        self.assertIn('scripts/check-wiki.py',validation); self.assertNotIn('if:',validation)
        self.assertLess(publish.index('scripts/check-wiki.py'),publish.index('scripts/publish-wiki.sh'))
        self.assertNotIn('continue-on-error',publish)
        self.assertNotIn(' push ',publish)  # Only the fast-forward mirror script may push.

    def test_publication_uses_the_same_complete_notes_it_rechecks(self):
        release=jobs((WORKFLOWS/'release.yml').read_text())['publish']
        draft,final=release.split('gh release create',1)
        for phase in (draft,final):
            for output in ('needs.package.outputs.coverage','needs.package.outputs.toolchain','needs.intel.outputs.coverage',
                           'needs.package.outputs.zip-sha-arm64','needs.package.outputs.zip-sha-x86_64'):
                self.assertIn(output,phase)
        self.assertIn('--publishing > "$WORK/notes"',draft)
        self.assertIn('cmp "$WORK/notes" "$WORK/current"',final)
        self.assertEqual(final.count('--notes-file "$WORK/notes"'),2)

    def test_validate_ancestry_before_running_tag_source_and_pin_downstream_checkout(self):
        release=(WORKFLOWS/'release.yml').read_text(); stages=jobs(release)
        validation=next(body for body in stages.values() if 'release-gate.py' in body and 'contents: write' not in body)
        ancestry=validation.find('git merge-base --is-ancestor')
        self.assertGreaterEqual(ancestry,0);self.assertLess(ancestry,validation.index('python3 -I scripts/release-gate.py'))
        for body in stages.values():
            if body != validation: self.assertRegex(body,r'ref: \$\{\{ needs\.\w+\.outputs\.sha \}\}')

    def test_publisher_independently_verifies_the_received_signed_archive_before_drafting(self):
        stages = jobs((WORKFLOWS/'release.yml').read_text())
        [publisher] = [body for body in stages.values() if 'contents: write' in body]
        self.assertIn('    runs-on: macos-latest\n', publisher)
        self.assertNotIn('environment:', publisher)
        self.assertNotIn('continue-on-error:', publisher)
        steps = publisher.split('      - name: ')
        receive = next(i for i, step in enumerate(steps) if 'release-assets.py receive ' in step)
        verify = next(i for i, step in enumerate(steps) if 'release-assets.py verify ' in step)
        draft = next(i for i, step in enumerate(steps) if 'gh release create ' in step)
        self.assertLess(receive, verify)
        self.assertLess(verify, draft)
        self.assertNotIn('if:', steps[verify])
        self.assertRegex(steps[verify], r'(?m)^        run: python3 -I scripts/release-assets\.py verify "\$WORK/assets" "\$VERSION" "\$WORK/unpacked" signed$')

    def test_release_privileges_and_immutable_handoff(self):
        text=(WORKFLOWS/'release.yml').read_text(); j=jobs(text)
        self.assertNotIn('contents: write',text.split('jobs:')[0]); self.assertEqual(text.count('contents: write'),1)
        [(signer,sign)]=[(n,v) for n,v in j.items() if 'environment: release' in v]
        [(publisher,publish)]=[(n,v) for n,v in j.items() if 'contents: write' in v]; self.assertNotEqual(signer,publisher)
        gate=re.search(r'needs: (\w+)',sign)[1]; self.assertIn('release-gate.py',j[gate]);self.assertIn('fetch-depth: 0',j[gate])
        self.assertIn('prove-package.sh signed',sign);self.assertIn('security delete-keychain',sign)
        self.assertRegex(sign,r'native=\$\(scripts/prove-package\.sh --native-arch\); test "\$native" = arm64')
        self.assertNotRegex(publish,r'secrets\.|swift build|--selftest|build-app\.sh'); self.assertRegex(publish,'needs: .*'+signer)
        self.assertRegex(publish,r'(?s)release-assets\.py receive.*?gh release create.*?--draft.*?release-gate\.py.*?--draft=false')
        self.assertRegex(publish,r'(?s)gh release create .*?gh release view .*?release-assets\.py draft "\$WORK/draft\.json" "\$WORK/assets" "\$VERSION".*?--draft=false')
        for workflow in ('ci.yml','release.yml'):
            text=(WORKFLOWS/workflow).read_text()
            self.assertNotRegex(text,r'sw_vers -productVersion \|',workflow)
            self.assertNotRegex(text,r'"\$\((?:xcrun|xcodebuild|swift) ',workflow)
        self.assertEqual([n for n,v in j.items() if 'secrets.SIGNING_' in v],[signer]); self.assertIn('artifact-digest',sign)
        intel=j['intel']; self.assertIn('    runs-on: macos-26-intel\n',intel)
        self.assertRegex(intel,r'needs: \[validate, package\]'); self.assertRegex(publish,r'needs: \[validate, package, intel\]')
        self.assertRegex(intel,r'ref: \$\{\{ needs\.validate\.outputs\.sha \}\}')
        self.assertRegex(intel,r'native=\$\(scripts/prove-package\.sh --native-arch\); test "\$native" = x86_64')
        self.assertIn('os=$(sw_vers -productVersion); [[ "$os" =~ ^26\\.[0-9]+(\\.[0-9]+)?$ ]]',intel)
        self.assertRegex(intel,r'(?s)release-assets\.py receive .*?prove-package\.sh signed "\$WORK/proof" "\$WORK/assets"')
        for forbidden in ('secrets.','environment:','swift build','build-app.sh','contents: write','continue-on-error'):
            self.assertNotIn(forbidden,intel)
        for env in ('TOOLCHAIN','COVERAGE_ARM64','COVERAGE_X86_64','REVIEWED_ARM64','REVIEWED_X86_64'): self.assertIn(env+':',publish)
        self.assertIn('needs.intel.outputs.coverage',publish)
        for action in re.findall(r'uses: (\S+)',text+(WORKFLOWS/'ci.yml').read_text()): self.assertRegex(action,r'@[0-9a-f]{40}$')


if __name__ == '__main__': unittest.main()
