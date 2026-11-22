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

    def test_both_architectures_share_one_app_identity_and_history_location(self):
        # Switching between the Apple silicon and Intel downloads must keep the same history and settings.
        build = (ROOT / 'scripts/build-app.sh').read_text()
        self.assertEqual(build.count('<key>CFBundleIdentifier</key><string>app.copia.Copia</string>'), 1)
        self.assertNotRegex(build, r'CFBundleIdentifier.*\$arch')
        live = (ROOT / 'Sources/CopiaApp/AppController.swift').read_text().split('public static func live()', 1)[1].split('\n\t}', 1)[0]
        self.assertIn('.applicationSupportDirectory, in: .userDomainMask', live)
        self.assertIn('.appendingPathComponent("Copia", isDirectory: true)', live)
        self.assertIn('defaults: .standard', live)
        self.assertNotRegex(live, r'arm64|x86_64|#if arch')

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
