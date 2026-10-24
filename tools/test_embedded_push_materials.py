#!/usr/bin/env python3
"""Offline regression tests for the embedded Library's source/relink materials."""
import io
import json
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
import zipfile

import embedded_push_materials as materials


class EmbeddedPushMaterialsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="embedded-push-materials-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for relative in [materials.SOURCES, materials.LICENCE, Path("third_party/embedded-push-notice.md"), Path("third_party/embedded-push-relink.md"), Path("tools/embedded_push_materials.py")]:
            source = materials.ROOT / relative
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copyfile(source, target)

    def test_retained_sources_and_tagged_licence_match(self):
        self.assertEqual(materials.verify(self.root)["verified_kotlin_files"], 13)
        output = self.root / "extracted"
        materials.extract_source(self.root, output)
        self.assertTrue((output / materials.LIBRARY_ROOT / "gradlew").is_file())
        self.assertEqual((output / materials.LIBRARY_ROOT / "LICENSE").read_bytes(), (self.root / materials.LICENCE).read_bytes())

    def test_tampered_published_source_is_rejected(self):
        path = self.root / materials.SOURCES / "embedded-fcm-distributor-3.1.0-sources.jar"
        path.write_bytes(path.read_bytes() + b"fixture tamper")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            materials.verify(self.root)

    def test_tampered_licence_and_nonpublished_aar_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "AAR hash mismatch"):
            materials.verify(self.root, self.root / materials.LICENCE)
        (self.root / materials.LICENCE).write_text("fixture tamper")
        with self.assertRaisesRegex(ValueError, "licence hash mismatch"):
            materials.verify(self.root)

    def test_extraction_rejects_path_traversal_before_writes(self):
        archive = self.root / materials.SOURCES / "embedded-fcm-distributor-3.1.0-upstream.tar.gz"
        with tarfile.open(archive, "w:gz") as fixture:
            member = tarfile.TarInfo("../outside")
            member.size = 3
            fixture.addfile(member, io.BytesIO(b"bad"))
        with patch.object(materials, "verify"), self.assertRaisesRegex(ValueError, "Unsafe"):
            materials.extract_source(self.root, self.root / "extracted")
        self.assertFalse((self.root / "outside").exists())

    def test_bundle_is_exact_commit_and_excludes_untracked_material(self):
        def git(*args):
            return subprocess.check_output(["git", *args], cwd=self.root, text=True).strip()
        git("init", "-q")
        git("add", "third_party", "tools")
        git("-c", "user.name=Hermes Agent", "-c", "user.email=hermes-agent@users.noreply.github.com", "commit", "-qm", "fixture source materials")
        commit = git("rev-parse", "HEAD")
        (self.root / "untracked-secret").write_text("test-only sentinel")
        output = self.root / "bundle.zip"
        report = materials.source_bundle(self.root, commit, output, [])
        self.assertEqual(report["application_commit"], commit)
        with zipfile.ZipFile(output) as bundle:
            manifest = json.loads(bundle.read("distribution-manifest.json"))
            application = bundle.read("hermes-android-source.tar.gz")
            self.assertEqual(manifest["application_source_sha256"], materials.sha256(application))
            with tarfile.open(fileobj=io.BytesIO(application), mode="r:gz") as source:
                self.assertNotIn("untracked-secret", source.getnames())
                self.assertIn(str(materials.LICENCE), source.getnames())
        (self.root / "third_party/embedded-push-notice.md").write_text("uncommitted fixture")
        with self.assertRaisesRegex(ValueError, "differ from the requested commit"):
            materials.source_bundle(self.root, commit, self.root / "rejected.zip", [])


if __name__ == "__main__":
    unittest.main()
