"""Regression tests for RC publication; fixture bytes are not actual APKs."""

import hashlib
import tempfile
import unittest
from pathlib import Path

from scripts.publish_github_release import (
    APK_NAMES,
    release_assets,
    release_command,
    release_flags,
)


class PublishReleaseTest(unittest.TestCase):
    def test_rc_is_prerelease_and_not_latest(self):
        self.assertEqual(
            release_flags("v3.0.0-rc.1"),
            ["--prerelease=true", "--latest=false"],
        )

    def test_other_prerelease_is_not_latest(self):
        self.assertEqual(
            release_flags("v3.0.0-beta.2"),
            ["--prerelease=true", "--latest=false"],
        )

    def test_stable_is_explicitly_stable(self):
        self.assertEqual(
            release_flags("v3.0.0"),
            ["--prerelease=false", "--latest=true"],
        )

    def test_invalid_tag_is_rejected(self):
        for tag in ("3.0.0", "v3.0", "v03.0.0", "v3.0.0-", "v3.0.0\n"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_flags(tag)

    def test_target_requires_full_sha(self):
        with self.assertRaises(ValueError):
            release_command("v3.0.0-rc.1", "abc123", [])

    def test_command_cannot_clobber_an_existing_release(self):
        command = release_command(
            "v3.0.0-rc.1", "a" * 40, [Path("app-arm64-v8a-release.apk")]
        )
        self.assertEqual(command[:4], ["gh", "release", "create", "v3.0.0-rc.1"])
        for flag in ("--verify-tag", "--draft=false", "--prerelease=true", "--latest=false"):
            self.assertIn(flag, command)
        self.assertNotIn("--clobber", command)

    def test_exact_three_splits_and_checksums(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            for apk_name in APK_NAMES:
                (directory / apk_name).write_bytes(apk_name.encode())
            assets = release_assets(directory)
            self.assertEqual([path.name for path in assets], [*APK_NAMES, "SHA256SUMS"])
            lines = (directory / "SHA256SUMS").read_text().splitlines()
            self.assertEqual(len(lines), 3)
            for apk_name, line in zip(APK_NAMES, lines):
                self.assertEqual(line, f"{hashlib.sha256(apk_name.encode()).hexdigest()}  {apk_name}")

    def test_missing_split_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            with self.assertRaises(ValueError):
                release_assets(Path(name))

    def test_extra_apk_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            for apk_name in (*APK_NAMES, "unverified.apk"):
                (directory / apk_name).write_bytes(b"test fixture")
            with self.assertRaises(ValueError):
                release_assets(directory)

    def test_empty_split_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            for apk_name in APK_NAMES:
                (directory / apk_name).touch()
            with self.assertRaises(ValueError):
                release_assets(directory)


if __name__ == "__main__":
    unittest.main()
