"""Publish an immutable Android release with explicit stable/prerelease flags."""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
from pathlib import Path


VERSION = re.compile(
    r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)
APK_NAMES = (
    "app-armeabi-v7a-release.apk",
    "app-arm64-v8a-release.apk",
    "app-x86_64-release.apk",
)


def release_flags(tag: str) -> list[str]:
    if not tag.startswith("v") or VERSION.fullmatch(tag[1:]) is None:
        raise ValueError(f"Invalid release tag: {tag}")
    if "-" in tag:
        return ["--prerelease=true", "--latest=false"]
    return ["--prerelease=false", "--latest=true"]


def release_command(tag: str, target: str, assets: list[Path]) -> list[str]:
    flags = release_flags(tag)
    if re.fullmatch(r"[0-9a-f]{40}", target) is None:
        raise ValueError("Release target must be a full 40-character commit SHA")
    return [
        "gh", "release", "create", tag,
        "--verify-tag", "--target", target,
        "--title", f"Hermes Android {tag}",
        "--generate-notes", "--draft=false", *flags,
        *(str(path) for path in assets),
    ]


def release_assets(directory: Path) -> list[Path]:
    assets = [directory / name for name in APK_NAMES]
    actual = {path.name for path in directory.glob("*.apk")}
    if actual != set(APK_NAMES) or not all(path.is_file() for path in assets):
        raise ValueError("Release requires exactly the three signed ABI APKs")
    if any(path.stat().st_size == 0 for path in assets):
        raise ValueError("Release APKs must not be empty")
    lines = []
    for path in assets:
        digest_state = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest_state.update(chunk)
        lines.append(f"{digest_state.hexdigest()}  {path.name}\n")
    checksum = directory / "SHA256SUMS"
    checksum.write_text("".join(lines), encoding="utf-8")
    return [*assets, checksum]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--assets-dir", required=True, type=Path)
    args = parser.parse_args()
    release_flags(args.tag)
    match = re.search(
        r"^version:\s*([^\s+]+)\+(\d+)\s*$",
        Path("pubspec.yaml").read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if match is None or args.tag != f"v{match.group(1)}":
        raise SystemExit("Release tag must exactly match pubspec.yaml versionName")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if args.target != head:
        raise SystemExit("Release target must match the verified checkout HEAD")
    command = release_command(args.tag, args.target, release_assets(args.assets_dir))
    # Create-only: a rerun must not silently overwrite an already published APK.
    subprocess.run(command, check=True)


if __name__ == "__main__":
    main()
