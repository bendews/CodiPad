#!/usr/bin/env python3
"""Build the pinned iSH ARM64 virtual kernel static archives for iOS or iOS Simulator."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

from build_node import verify_macho
from sources import native_toolchain, tree_digest, ROOT, SourcesError, sha256_file, verify_runtime_sources

ARCHIVES = ("libish.a", "libish_emu.a", "libfakefs.a")
IMPORTER_ARCHIVE = "libfakefs_import.a"


def default_output(sdk: str) -> Path:
    return ROOT / ".build" / sdk / "ish"


def selected_patches(locked: dict, sdk: str) -> dict[str, str]:
    order = locked["patchOrder"][sdk]
    result = {}
    for name in order:
        path = ROOT / "patches/ish" / name
        if not path.is_file():
            raise ValueError(f"Missing iSH patch: {path}")
        result[name] = sha256_file(path)
    return result


def selected_external_headers(locked: dict) -> dict[str, str]:
    result = {}
    for name in locked.get("externalHeaders", []):
        path = ROOT / name
        if not path.is_file():
            raise ValueError(f"Missing iSH external header: {path}")
        result[name] = sha256_file(path)
    return result


def is_cached_valid(output_dir: Path, sdk: str, locked: dict, dependency_headers: Path) -> bool:
    receipt_path = output_dir / "receipt.json"
    build_dir = output_dir / "build"
    if not receipt_path.is_file() or not build_dir.is_dir():
        return False
    try:
        receipt = json.loads(receipt_path.read_text())
        patches = selected_patches(locked, sdk)
        external = selected_external_headers(locked)
        if (
            receipt.get("sdk") != sdk
            or receipt.get("toolchain") != native_toolchain(sdk)
            or receipt.get("revision") != locked["revision"]
            or receipt.get("patches") != patches
            or receipt.get("patchOrder") != list(patches)
            or receipt.get("externalHeaders") != external
            or receipt.get("buildDirectory") != str(build_dir)
            or receipt.get("sourceDirectory") != str(output_dir / "source")
            or set(receipt.get("archives", {})) != set(ARCHIVES)
            or receipt.get("deviceImporter", {}).get("headersSha256") != tree_digest(dependency_headers)
        ):
            return False
        for name, digest in receipt.get("archives", {}).items():
            if not (build_dir / name).is_file() or sha256_file(build_dir / name) != digest:
                return False
        importer = build_dir / IMPORTER_ARCHIVE
        return importer.is_file() and sha256_file(importer) == receipt["deviceImporter"]["sha256"]
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return False


def build(
    sdk: str = "iphoneos",
    output_dir: Path | None = None,
    jobs: int | None = None,
    force: bool = False,
) -> Path:
    locked = json.loads((ROOT / "build/runtime-manifest.json").read_text())["ish"]
    origin, _, dependency_headers = verify_runtime_sources(locked)
    destination = (output_dir or default_output(sdk)).resolve()
    if not force and is_cached_valid(destination, sdk, locked, dependency_headers):
        print(f"iSH kernel ({sdk}) ready: {destination}", flush=True)
        return destination

    meson = shutil.which("meson")
    ninja = shutil.which("ninja")
    if not meson or not ninja:
        raise ValueError("meson and ninja must be installed (e.g. brew install meson ninja)")

    patches = selected_patches(locked, sdk)
    external_headers = selected_external_headers(locked)
    include_dirs = sorted({str((ROOT / name).parent) for name in external_headers})
    jobs = jobs or max(1, min(os.cpu_count() or 4, 8))

    sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    compiler = subprocess.check_output(["xcrun", "--sdk", sdk, "--find", "clang"], text=True).strip()
    simulator = sdk == "iphonesimulator"
    target = "arm64-apple-ios18.0" + ("-simulator" if simulator else "")
    minimum = "-mios-simulator-version-min=18.0" if simulator else "-miphoneos-version-min=18.0"

    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    source = destination / "source"
    build_dir = destination / "build"
    source.mkdir()

    env = os.environ.copy()
    for var in ("CFLAGS", "CPPFLAGS", "LDFLAGS", "CC", "AR", "STRIP"):
        env.pop(var, None)

    print(f"Building iSH kernel ({sdk}, {len(patches)} patches)...", flush=True)
    with (destination / "build.log").open("wb") as log:
        def run(command, cwd=ROOT):
            subprocess.run([str(p) for p in command], cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)

        archive = destination / "source.tar"
        run(["git", "-C", origin, "archive", locked["revision"], "--output", archive])
        with tarfile.open(archive) as stream:
            stream.extractall(source, filter="data")
        archive.unlink()

        for name in patches:
            patch_cmd = ["patch", "-p1", "--batch", "--forward", "--fuzz=0", "-i", ROOT / "patches/ish" / name]
            run([*patch_cmd, "--dry-run"], cwd=source)
            run(patch_cmd, cwd=source)

        cross = destination / f"{sdk}.cross"
        cross.write_text(
            "[binaries]\n"
            f"c = {compiler!r}\n"
            "ar = 'ar'\n"
            "strip = 'strip'\n\n"
            "[host_machine]\n"
            "system = 'darwin'\n"
            "cpu_family = 'aarch64'\n"
            "cpu = 'aarch64'\n"
            "endian = 'little'\n\n"
            "[built-in options]\n"
            "c_args = " + repr(["-target", target, "-isysroot", sdk_path, minimum, *[f"-I{d}" for d in include_dirs]]) + "\n\n"
            "[properties]\n"
            "needs_exe_wrapper = true\n"
        )
        run([
            meson, "setup", build_dir, source, "--cross-file", cross, "--buildtype=debugoptimized",
            "-Dguest_arch=arm64", "-Dengine=asbestos", "-Dkernel=ish", "-Djit=true", "-Djit_emit=true",
        ])
        run([ninja, "-j", str(jobs), "-C", build_dir, *ARCHIVES])

        importer = build_dir / "fakefs_import.o"
        run([compiler, "-target", target, "-isysroot", sdk_path, "-I", source, "-I", dependency_headers, "-c", source / "tools/fakefs.c", "-o", importer])
        run(["xcrun", "--sdk", sdk, "libtool", "-static", "-o", build_dir / IMPORTER_ARCHIVE, importer])

    checked_members = verify_macho(
        [build_dir / name for name in (*ARCHIVES, IMPORTER_ARCHIVE)],
        7 if simulator else 2,
        "18.0",
    )
    record = {
        "revision": locked["revision"],
        "sdk": sdk,
        "toolchain": native_toolchain(sdk),
        "target": target,
        "verifiedMachOMembers": checked_members,
        "patches": patches,
        "patchOrder": list(patches),
        "externalHeaders": external_headers,
        "sourceDirectory": str(source),
        "buildDirectory": str(build_dir),
        "sourceTreeSha256": tree_digest(source),
        "archives": {name: sha256_file(build_dir / name) for name in ARCHIVES},
        "deviceImporter": {
            "archive": IMPORTER_ARCHIVE,
            "sha256": sha256_file(build_dir / IMPORTER_ARCHIVE),
            "headersSha256": tree_digest(dependency_headers),
        },
    }
    (destination / "receipt.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"Built iSH kernel ({sdk}): {destination}", flush=True)
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), default="iphoneos")
    parser.add_argument("--output", type=Path, help="Output directory (default: .build/<sdk>/ish)")
    parser.add_argument("--jobs", type=int, default=max(1, min(os.cpu_count() or 4, 8)))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    try:
        build(sdk=args.sdk, output_dir=args.output, jobs=args.jobs, force=args.force)
        return 0
    except (OSError, ValueError, SourcesError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"build_ish.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
