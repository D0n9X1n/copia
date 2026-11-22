"""User-facing instructions must agree across landing pages and the two usage guides."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]


class Docs(unittest.TestCase):
    def test_landing_and_usage_describe_copy_only_universal_release(self):
        for filename in ['README.md','wiki/Home.md','wiki/Home-zh-CN.md','wiki/Usage.md','wiki/Usage-zh-CN.md']:
            text=(ROOT/filename).read_text()
            with self.subTest(page=filename):
                self.assertIn('macOS 26',text);self.assertIn('Intel',text);self.assertIn('⌘V',text)
                self.assertIn('Verification',text)
                self.assertRegex(text, 'Intel 实机' if 'zh-CN' in filename else 'Intel hardware')
                self.assertNotIn('Copia-0.0.1.zip',text);self.assertNotIn('⌘T',text)
                if 'Home' not in filename:
                    for key in ['⌘A','⌘P','Tab']: self.assertIn(key,text)

    def test_development_points_to_gated_release_in_both_languages(self):
        for name in ('Development.md','Development-zh-CN.md'):
            text=(ROOT/'wiki'/name).read_text()
            with self.subTest(page=name):
                for word in ('VERSION','AV5CFZA3T3','scripts/test-release-tools.sh','macOS 26','--selftest','`v*`'):
                    self.assertIn(word,text)
                self.assertNotIn('git tag v0.0.1',text)


if __name__=='__main__':unittest.main()
