"""Source checks that do not invoke SwiftPM or actool."""
import pathlib
import unittest
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


class PackagePolicy(unittest.TestCase):
    def test_one_release_floor_and_version_source(self):
        self.assertIn('.macOS(.v26)', (ROOT / 'Package.swift').read_text())
        build = (ROOT / 'scripts/build-app.sh').read_text()
        self.assertIn('--minimum-deployment-target 26.0', build)
        self.assertIn('<key>LSMinimumSystemVersion</key><string>26.0</string>', build)
        self.assertRegex((ROOT / 'VERSION').read_text(), r'^\d+\.\d+\.\d+\n\Z')
        self.assertNotRegex(build, r'COPIA_VERSION:-\d')

    def test_stable_tag_matches_version_file_exactly(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / 'VERSION'
            for value, tag, ok in [('12.3.45', 'v12.3.45', True), ('1.2.3', 'v1.2.4', False),
                                   ('01.2.3', 'v01.2.3', False), ('1.2.3-beta', 'v1.2.3-beta', False),
                                   ('1.2.3', '1.2.3', False), ('1.2.3\nX', 'v1.2.3', False)]:
                path.write_text(value + '\n')
                result = subprocess.run([sys.executable, '-I', ROOT/'scripts/version.py', path, tag],
                                        capture_output=True, text=True)
                with self.subTest(value=value, tag=tag):
                    self.assertEqual(result.returncode == 0, ok, result.stderr)
                    if ok:
                        self.assertEqual(result.stdout.strip(), value)


if __name__ == '__main__':
    unittest.main()
