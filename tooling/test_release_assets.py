"""Tests for the version checks in tooling/release_assets.py.

    python3 -m unittest discover -s tooling -p 'test_*.py'
"""

import unittest

from build_number import MAX_VERSION_CODE
from release_assets import BADGING_RE, ReleaseError, release_build


class ReleaseBuildTest(unittest.TestCase):
    def test_both_flavors_agree(self):
        apks = {"arm64": ("1.2.0", 10251234), "x64": ("1.2.0", 10251234)}
        self.assertEqual(release_build("1.2.0", None, apks), 10251234)
        self.assertEqual(release_build("1.2.0", 10251234, apks), 10251234)

    def test_flavors_built_at_different_minutes(self):
        with self.assertRaisesRegex(ReleaseError, "different build numbers"):
            release_build("1.2.0", None, {"arm64": ("1.2.0", 10251234), "x64": ("1.2.0", 10251301)})

    def test_version_name_mismatch(self):
        with self.assertRaisesRegex(ReleaseError, "x64"):
            release_build("1.2.0", None, {"arm64": ("1.2.0", 10251234), "x64": ("1.1.0", 10251234)})

    def test_placeholder_build_number(self):
        for code in [0, 1, MAX_VERSION_CODE + 1]:
            with self.assertRaisesRegex(ReleaseError, "placeholder"):
                release_build("1.0.0", None, {"arm64": ("1.0.0", code)})

    def test_explicit_version_must_match(self):
        with self.assertRaisesRegex(ReleaseError, r"\+7"):
            release_build("1.2.0", 7, {"arm64": ("1.2.0", 10251234)})

    def test_badging_line(self):
        line = ("package: name='io.github.ccch1mneyyy.dsh_app' versionCode='10251234' versionName='1.2.0-beta.1' "
                "platformBuildVersionName='16'\nminSdkVersion:'26'\n")
        m = BADGING_RE.search(line)
        self.assertEqual((m.group(1), m.group(2)), ("10251234", "1.2.0-beta.1"))


if __name__ == "__main__":
    unittest.main()
