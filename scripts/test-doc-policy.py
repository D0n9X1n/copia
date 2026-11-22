"""User-facing instructions must agree across landing pages and the two usage guides."""
from pathlib import Path
import re
import unittest

ROOT=Path(__file__).resolve().parents[1]
LANDING=['README.md','wiki/Home.md','wiki/Home-zh-CN.md','wiki/Usage.md','wiki/Usage-zh-CN.md']
INSTALL=['README.md','wiki/Usage.md','wiki/Usage-zh-CN.md']
APPLE=r'(?:Apple silicon|Apple 芯片)'


def download_problems(text, install):
    """Each page names one ZIP per chip, mapped the right way round, and none of the old universal download."""
    problems=[]
    lines=text.splitlines()
    arm=[l for l in lines if '-arm64.zip' in l]; intel=[l for l in lines if '-x86_64.zip' in l]
    if not arm or not intel: problems.append('missing a per-architecture ZIP')
    if any(re.search(APPLE,l) is None for l in arm): problems.append('arm64 ZIP not labelled Apple silicon')
    if any('Intel' not in l or re.search(APPLE,l) for l in intel): problems.append('x86_64 ZIP not labelled Intel')
    if re.search(r'\b[Uu]niversal\b|通用的 `?Copia-|通用(?:包|应用|二进制|版本|构建)|`Copia-<[^>]*>\.zip`', text): problems.append('universal download wording')
    if install:
        if 'About This Mac' not in text and '关于本机' not in text: problems.append('no chip identification guidance')
        if '.sha256' not in text: problems.append('no checksum guidance')
    return problems


class Docs(unittest.TestCase):
    def test_landing_and_usage_describe_copy_only_per_architecture_release(self):
        for filename in LANDING:
            text=(ROOT/filename).read_text()
            with self.subTest(page=filename):
                self.assertIn('macOS 26',text);self.assertIn('Intel',text);self.assertIn('⌘V',text)
                self.assertIn('Verification',text)
                self.assertNotIn('Copia-0.0.1.zip',text);self.assertNotIn('⌘T',text)
                self.assertEqual(download_problems(text, True),[])
                if 'Home' not in filename:
                    for key in ['⌘A','⌘P','Tab']: self.assertIn(key,text)

    def test_download_policy_rejects_reversed_missing_or_universal_instructions(self):
        good=(ROOT/'wiki/Usage.md').read_text()
        arm=next(l for l in good.splitlines() if '-arm64.zip' in l)
        reversed_page=good.replace('-arm64.zip','-TMP.zip').replace('-x86_64.zip','-arm64.zip').replace('-TMP.zip','-x86_64.zip')
        cases={'reversed':reversed_page, 'missing Intel':good.replace('-x86_64.zip','.zip'),
               'universal':good+'\nDownload the universal `Copia-<version>.zip`.\n',
               'universal binaries':good+'\nBoth downloads are universal binaries.\n',
               'zh universal':good+'\n两个下载都是通用二进制文件。\n',
               'no chip help':good.replace('About This Mac','the Apple menu'),
               'no checksum':good.replace('.sha256','')}
        self.assertEqual(download_problems(good,True),[])
        for label,text in cases.items():
            with self.subTest(case=label): self.assertNotEqual(download_problems(text,True),[])
        home=(ROOT/'wiki/Home.md').read_text()
        swapped=home.replace('Apple silicon','CHIP').replace('Intel','Apple silicon').replace('CHIP','Intel')
        self.assertNotEqual(download_problems(swapped,False),[])

    def test_readme_build_example_names_the_per_architecture_outputs(self):
        text=(ROOT/'README.md').read_text()
        self.assertIn('dist/<arch>/Copia.app',text); self.assertNotIn('# dist/Copia.app and the ZIP',text)

    def test_development_points_to_gated_release_in_both_languages(self):
        for name in ('Development.md','Development-zh-CN.md'):
            text=(ROOT/'wiki'/name).read_text()
            with self.subTest(page=name):
                for word in ('VERSION','AV5CFZA3T3','scripts/test-release-tools.sh','macOS 26','--selftest','`v*`',
                             'dist/<arch>/Copia.app','Copia-<VERSION>-arm64.zip','Copia-<VERSION>-x86_64.zip','macos-26-intel',
                             'gh issue list --repo D0n9X1n/copia --state open --limit 1 --json number --jq length'):
                    self.assertIn(word,text)
                self.assertNotIn('git tag v0.0.1',text)
                self.assertNotIn('render-icon.swift dist/Copia.app',text)
                self.assertNotRegex(text,r'same machine code|not how fast|机器码|运行速度')
                self.assertRegex(text, r'(?s)gh issue list.*?`0`.*?v\$\(cat VERSION\)')


if __name__=='__main__':unittest.main()
