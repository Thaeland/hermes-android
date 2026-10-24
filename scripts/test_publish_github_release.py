"""Regression tests for RC publication; fixture bytes are not actual APKs."""

import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.publish_github_release import (
    APK_NAMES,
    main,
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


class PublisherMainTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.previous_directory = Path.cwd()
        os.chdir(self.directory)
        self.addCleanup(os.chdir, self.previous_directory)
        (self.directory / "pubspec.yaml").write_text("version: 3.0.0-rc.1+3000\n")
        for name in APK_NAMES:
            (self.directory / name).write_bytes(b"test fixture, not an APK")
        self.head = "a" * 40
        self.target = self.head
        self.reference = {"ref": "refs/tags/v3.0.0-rc.1", "object": {"type": "commit", "sha": self.head}}
        self.tag_objects = {}

    def read_command(self, command, **kwargs):
        if command[:2] == ["git", "rev-parse"]:
            return self.head + "\n"
        if command[:3] == ["gh", "repo", "view"]:
            return "rusty4444/hermes-android\n"
        if command[:2] == ["gh", "api"]:
            if "/git/ref/tags/" in command[2]:
                return json.dumps(self.reference)
            if "/git/tags/" in command[2]:
                return json.dumps(self.tag_objects[command[2].rsplit("/", 1)[1]])
        raise AssertionError(f"Unexpected command: {command}")

    def invoke(self):
        argv = ["publisher", "--tag", "v3.0.0-rc.1", "--target", self.target,
                "--assets-dir", str(self.directory)]
        with mock.patch("sys.argv", argv), mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "rusty4444/hermes-android"}), mock.patch(
            "scripts.publish_github_release.subprocess.check_output", side_effect=self.read_command
        ), mock.patch("scripts.publish_github_release.subprocess.run") as publish:
            main()
            return publish

    def test_rejects_remote_tag_at_a_different_commit(self):
        self.reference["object"]["sha"] = "b" * 40
        with self.assertRaisesRegex(SystemExit, "tag.*verified checkout"):
            self.invoke()
        self.assertFalse((self.directory / "SHA256SUMS").exists())

    def test_matching_lightweight_tag_publishes_rc_only(self):
        publish = self.invoke()
        command = publish.call_args.args[0]
        self.assertIn("--prerelease=true", command)
        self.assertIn("--latest=false", command)
        self.assertIn("--repo", command)
        self.assertIn("rusty4444/hermes-android", command)

    def test_matching_annotated_tag_is_peeled(self):
        tag_sha = "c" * 40
        self.reference["object"] = {"type": "tag", "sha": tag_sha}
        self.tag_objects[tag_sha] = {"sha": tag_sha, "object": {"type": "commit", "sha": self.head}}
        self.invoke().assert_called_once()

    def test_annotated_tag_at_wrong_commit_is_rejected(self):
        tag_sha = "c" * 40
        self.reference["object"] = {"type": "tag", "sha": tag_sha}
        self.tag_objects[tag_sha] = {"sha": tag_sha, "object": {"type": "commit", "sha": "b" * 40}}
        with self.assertRaisesRegex(SystemExit, "tag.*verified checkout"):
            self.invoke()

    def test_unexpected_ref_is_rejected(self):
        self.reference["ref"] = "refs/tags/v3.0.0"
        with self.assertRaises(SystemExit):
            self.invoke()

    def test_invalid_tag_object_fails_closed(self):
        self.reference["object"]["type"] = "tree"
        with self.assertRaises(SystemExit):
            self.invoke()

    def test_cyclic_tag_objects_fail_closed(self):
        tag_sha = "c" * 40
        self.reference["object"] = {"type": "tag", "sha": tag_sha}
        self.tag_objects[tag_sha] = {"sha": tag_sha, "object": {"type": "tag", "sha": tag_sha}}
        with self.assertRaises(SystemExit):
            self.invoke()

    def test_target_cannot_differ_from_checkout(self):
        self.target = "b" * 40
        with self.assertRaisesRegex(SystemExit, "target.*checkout HEAD"):
            self.invoke()


if __name__ == "__main__":
    unittest.main()
