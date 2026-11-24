#!/usr/bin/env python3
"""Build the pinned libarchive static library for iOS or iOS Simulator."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

from build_node import verify_macho
from sources import native_toolchain, tree_digest, ROOT, SourcesError, libarchive_patch, libarchive_repository, sha256_file, verify_runtime_sources


def default_output(sdk: str) -> Path:
    return ROOT / ".build" / sdk / "libarchive"


def is_cached_valid(output_dir: Path, sdk: str, locked: dict, headers: Path) -> bool:
    receipt_path = output_dir / "receipt.json"
    archive = output_dir / f"products/Release-{sdk}/libarchive.a"
    if not receipt_path.is_file() or not archive.is_file():
        return False
    try:
        receipt = json.loads(receipt_path.read_text())
        patch = libarchive_patch(locked)
        return (
            receipt.get("sdk") == sdk
            and receipt.get("toolchain") == native_toolchain(sdk)
            and receipt.get("archive") == str(archive)
            and receipt.get("revision") == locked["libarchiveRevision"]
            and receipt.get("patches") == {patch.name: sha256_file(patch)}
            and receipt.get("headersSha256") == tree_digest(headers)
            and receipt.get("sha256") == sha256_file(archive)
        )
    except (OSError, ValueError, json.JSONDecodeError):
        return False


def build(sdk: str = "iphoneos", output_dir: Path | None = None, force: bool = False) -> Path:
    locked = json.loads((ROOT / "build/runtime-manifest.json").read_text())["ish"]
    origin, source_repo, headers = verify_runtime_sources(locked)
    output = (output_dir or default_output(sdk)).resolve()
    if not force and is_cached_valid(output, sdk, locked, headers):
        print(f"libarchive ({sdk}) ready: {output}", flush=True)
        return output

    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    repository = libarchive_repository(origin, locked)
    headers_sha = tree_digest(headers)
    private = output / "source"
    private.mkdir()

    for repo, revision, paths, destination, name in [
        (origin, locked["revision"], ["deps/libarchive.xcodeproj", "deps/config.h"], private, "project"),
        (source_repo, locked["libarchiveRevision"], [], private / "deps/libarchive", "libarchive"),
    ]:
        tar_path = output / f"{name}.tar"
        subprocess.run(["git", "-C", str(repo), "archive", revision, "--output", str(tar_path), *paths], check=True)
        destination.mkdir(parents=True, exist_ok=True)
        with tarfile.open(tar_path) as stream:
            stream.extractall(destination, filter="data")
        tar_path.unlink()

    patch = libarchive_patch(locked)
    staged_source = private / "deps/libarchive"
    patch_cmd = ["patch", "-p1", "--batch", "--forward", "--fuzz=0", "-i", str(patch)]
    subprocess.run([*patch_cmd, "--dry-run"], cwd=staged_source, check=True)
    subprocess.run(patch_cmd, cwd=staged_source, check=True)

    project = private / "deps/libarchive.xcodeproj"
    command = [
        "xcodebuild", "-jobs", "2", "-project", str(project), "-target", "libarchive",
        "-configuration", "Release", "-sdk", sdk, "-arch", "arm64",
        "IPHONEOS_DEPLOYMENT_TARGET=18.0", "CODE_SIGNING_ALLOWED=NO",
        f"SYMROOT={output / 'products'}", f"OBJROOT={output / 'objects'}", "build",
    ]
    print(f"Building libarchive ({sdk})...", flush=True)
    with (output / "build.log").open("wb") as log:
        subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)

    archive = output / f"products/Release-{sdk}/libarchive.a"
    members = verify_macho([archive], 7 if sdk == "iphonesimulator" else 2, "18.0")
    receipt = {
        "sdk": sdk,
        "toolchain": native_toolchain(sdk),
        "revision": locked["libarchiveRevision"],
        "repository": repository,
        "patches": {patch.name: sha256_file(patch)},
        "headersSha256": headers_sha,
        "archive": str(archive),
        "sha256": sha256_file(archive),
        "verifiedMachOMembers": members,
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Built libarchive ({sdk}): {output}", flush=True)
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), default="iphoneos")
    parser.add_argument("--output", type=Path, help="Output directory (default: .build/<sdk>/libarchive)")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    try:
        build(sdk=args.sdk, output_dir=args.output, force=args.force)
        return 0
    except (OSError, ValueError, SourcesError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"build_libarchive.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
