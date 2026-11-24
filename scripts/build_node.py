#!/usr/bin/env python3
"""Build pinned native Node.js static archives for iOS or iOS Simulator."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

from sources import ROOT, download_verified, native_toolchain, sha256_file

# LC_BUILD_VERSION platform values: 1 macOS, 2 iOS device, 7 iOS simulator.
PLATFORM_NAMES = {1: "macOS", 2: "iOS", 7: "iOS simulator"}


def load_node_manifest() -> dict:
    return json.loads((ROOT / "build/runtime-manifest.json").read_text())["node"]


def default_output(sdk: str) -> Path:
    return ROOT / ".build" / sdk / "node"


def header_digest(source: Path) -> str:
    rows = []
    for relative in ("src", "deps/v8/include", "deps/uv/include"):
        for path in sorted((source / relative).rglob("*.h")):
            rows.append([path.relative_to(source).as_posix(), sha256_file(path)])
    return hashlib.sha256(json.dumps(rows, separators=(",", ":")).encode()).hexdigest()


def object_platform(path: Path) -> int | None:
    text = subprocess.check_output(["xcrun", "otool", "-l", str(path)], text=True, errors="replace")
    match = re.search(r"\bplatform (\d+)", text)
    return int(match.group(1)) if match else None


def archive_build_versions(archive: Path) -> list[dict]:
    """Read (name, platform, minos) for every Mach-O member in a static archive."""
    text = subprocess.check_output(["xcrun", "otool", "-l", str(archive)], text=True, errors="replace")
    members, current = [], None
    for line in text.splitlines():
        if line.startswith("Archive : "):
            continue
        header = re.match(r"^.*\(([^()]+)\):$", line)
        if header:
            current = {"name": header.group(1), "platform": None, "minos": None}
            members.append(current)
            continue
        if current is None:
            continue
        platform = re.search(r"^\s*platform (\d+)$", line)
        if platform:
            current["platform"] = int(platform.group(1))
        minos = re.search(r"^\s*minos (\d+(?:\.\d+)*)$", line)
        if minos:
            current["minos"] = minos.group(1)
    return members


def verify_macho(archives: list[Path], want_platform: int, deployment: str) -> int:
    checked = 0
    expected_minos = [int(x) for x in deployment.split(".")]
    for archive in archives:
        members = archive_build_versions(archive)
        if not members:
            raise ValueError(f"{archive.name}: no Mach-O members to verify")
        for member in members:
            if member["platform"] is None:
                raise ValueError(f"{archive.name}({member['name']}): missing LC_BUILD_VERSION")
            if member["platform"] != want_platform:
                got = PLATFORM_NAMES.get(member["platform"], str(member["platform"]))
                raise ValueError(
                    f"{archive.name}({member['name']}): platform is {got}, expected {PLATFORM_NAMES[want_platform]}"
                )
            if not member["minos"]:
                raise ValueError(f"{archive.name}({member['name']}): missing minos")
            if [int(x) for x in member["minos"].split(".")] != expected_minos:
                raise ValueError(
                    f"{archive.name}({member['name']}): minos {member['minos']} != deployment target {deployment}"
                )
            checked += 1
    return checked


def current_identity(sdk: str) -> dict:
    pin = load_node_manifest()
    patches = sorted((ROOT / "patches/node").glob("*.patch"))
    toolchain = native_toolchain(sdk)
    return {
        "pin": pin,
        "patches": {p.name: sha256_file(p) for p in patches},
        "sdk": sdk,
        "sdkVersion": toolchain["sdkVersion"],
        "toolchain": toolchain,
    }


def is_cached_valid(build_dir: Path, sdk: str) -> bool:
    receipt_path = build_dir / "codipad-build.json"
    source = build_dir / "source"
    if not receipt_path.is_file() or not source.is_dir():
        return False
    try:
        receipt = json.loads(receipt_path.read_text())
        identity = current_identity(sdk)
        if any(receipt.get(k) != identity[k] for k in ("pin", "patches", "sdk", "sdkVersion", "toolchain")):
            return False
        archives = receipt.get("archives")
        runtime = receipt.get("runtimeArchives")
        force_load = receipt.get("forceLoad")
        if not isinstance(archives, dict) or not isinstance(runtime, list) or not isinstance(force_load, list):
            return False
        if not runtime or not force_load or set(archives) != set(runtime) or not set(force_load).issubset(archives):
            return False
        for name, digest in archives.items():
            if not re.fullmatch(r"lib[\w.-]+\.a", name):
                return False
            archive = source / "out/Release" / name
            if not archive.is_file() or sha256_file(archive) != digest:
                return False
        return True
    except (OSError, ValueError, TypeError, AttributeError):
        return False


def _run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def build(
    sdk: str = "iphoneos",
    output_dir: Path | None = None,
    python_bin: str | None = None,
    jobs: int | None = None,
    force: bool = False,
) -> Path:
    build_dir = (output_dir or default_output(sdk)).resolve()
    if not force and is_cached_valid(build_dir, sdk):
        print(f"Node.js ({sdk}) ready: {build_dir}", flush=True)
        return build_dir

    pin = load_node_manifest()
    python_bin = python_bin or sys.executable
    jobs = jobs or max(1, min(os.cpu_count() or 4, 8))
    cache = ROOT / ".build/cache"
    archive = download_verified(pin["url"], cache / pin["url"].rsplit("/", 1)[-1], pin["sha256"])

    patches = sorted((ROOT / "patches/node").glob("*.patch"))
    identity = current_identity(sdk)
    source = build_dir / "source"
    stamp = source / ".codipad-inputs.json"

    if source.exists() and (force or not stamp.exists() or json.loads(stamp.read_text()) != identity):
        shutil.rmtree(source)
    if not source.exists():
        staging = build_dir / "staging"
        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir(parents=True)
        with tarfile.open(archive) as tar:
            tar.extractall(staging, filter="data")
        tree = staging / f"node-v{pin['version']}"
        for patch in patches:
            _run("patch", "-p1", "-f", "--dry-run", "-d", tree, "-i", patch)
            _run("patch", "-p1", "-f", "-d", tree, "-i", patch)
        (tree / ".codipad-inputs.json").write_text(json.dumps(identity, indent=2) + "\n")
        tree.replace(source)
        staging.rmdir()

    (build_dir / "codipad-build.json").unlink(missing_ok=True)
    env = dict(os.environ)
    for var in ("CC", "CXX", "CC_host", "CXX_host", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH"):
        env.pop(var, None)

    sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    deployment = pin.get("deploymentTarget", "18.0")
    triple = f"arm64-apple-ios{deployment}" + ("" if sdk == "iphoneos" else "-simulator")
    want_platform = 2 if sdk == "iphoneos" else 7

    # c-ares checks HAVE_SYS_RANDOM_H on Darwin but uses arc4random_buf on Apple platforms.
    shim = build_dir / "shims/include/sys"
    shim.mkdir(parents=True, exist_ok=True)
    (shim / "random.h").write_text("/* empty: iOS SDK has no sys/random.h; c-ares uses arc4random_buf */\n")
    target_flags = f"-target {triple} -isysroot {sdk_path} -I{build_dir / 'shims/include'}"

    env.update(
        PYTHON=str(python_bin),
        GYP_DEFINES="target_arch=arm64 host_os=mac target_os=ios",
        CFLAGS=f"-g0 {target_flags}",
        CXXFLAGS=f"-g0 -std=gnu++20 {target_flags}",
        LDFLAGS=target_flags,
        CFLAGS_host="-g0 -std=gnu17",
        CXXFLAGS_host="-g0 -std=gnu++20",
    )
    flags = [
        "--dest-os=ios",
        "--dest-cpu=arm64",
        "--cross-compiling",
        "--openssl-no-asm",
        "--with-intl=small-icu",
        "--without-node-code-cache",
        "--without-node-snapshot",
    ]
    if sdk == "iphonesimulator":
        flags.append("--ios-simulator")

    makefile = source / "out/Makefile"
    gyp_inputs = list(source.rglob("*.gyp")) + list(source.rglob("*.gypi"))
    stale = (
        not (source / "config.gypi").exists()
        or not makefile.exists()
        or any(f.stat().st_mtime > makefile.stat().st_mtime for f in gyp_inputs)
    )
    if stale:
        print(f"Configuring Node.js {pin['version']} for {sdk}...", flush=True)
        _run(python_bin, "configure.py", *flags, cwd=source, env=env)

    config = json.loads((source / "config.gypi").read_text().split("\n", 1)[1])["variables"]
    v8_mk = (source / "out/tools/v8_gypfiles/v8_base_without_compiler.target.mk").read_text()
    defines = v8_mk.split("DEFS_Release :=", 1)[1].split("\n\n", 1)[0]
    for feature in ("TURBOFAN", "SPARKPLUG", "MAGLEV", "WEBASSEMBLY"):
        if f"-DV8_ENABLE_{feature}" not in defines:
            raise ValueError(f"Required V8 feature disabled: {feature}")
    if config.get("v8_enable_lite_mode") or "jitless" in config.get("node_v8_options", ""):
        raise ValueError("Jitless/lite mode is not supported")

    node_make = (source / "out/node.target.mk").read_text()
    link_line = re.search(r"^\$\(builddir\)/node: LD_INPUTS := (.+)$", node_make, re.M)
    if not link_line:
        raise ValueError("Generated Node link closure is missing")

    flat = re.findall(r"\$\(builddir\)/(lib[^\s/()]+\.a)", link_line.group(1))
    deep = re.findall(r"\$\(obj\)\.target/([^\s()]*/)?(lib[^\s/()]+\.a)", link_line.group(1))
    if flat:
        layout = "flat"
        runtime_archives = list(dict.fromkeys(flat))
        deep_by_name = {name: "" for name in runtime_archives}
    elif deep:
        layout = "deep"
        deep_by_name = {name: (directory or "") for directory, name in deep}
        runtime_archives = list(dict.fromkeys(name for _, name in deep))
    else:
        raise ValueError("Generated Node link closure has 0 archives")

    ldflags = node_make.split("LDFLAGS_Release :=", 1)[1].split("\n\n", 1)[0] if "LDFLAGS_Release :=" in node_make else ""
    force_load = re.findall(r"-Wl,-force_load,\$\(builddir\)/(lib[^\s/()]+\.a)", ldflags) or pin.get("forceLoad", [])
    if not force_load or any(name not in runtime_archives for name in force_load):
        raise ValueError("Invalid forceLoad archive closure")

    release = source / "out/Release"
    target_objects = release / "obj.target"
    if target_objects.exists():
        sample = next(target_objects.rglob("*.o"), None)
        existing = object_platform(sample) if sample else None
        if existing is not None and existing != want_platform:
            shutil.rmtree(target_objects)

    goals = [
        release / deep_by_name[name] / name if deep_by_name[name] else release / name
        for name in runtime_archives
    ]
    env["CODIPAD_HOST_LIBS"] = "-framework CoreFoundation -framework Foundation"
    no_gnu_groups = (
        "cmd_link=$(LINK.$(TOOLSET)) -o $@ $(GYP_LDFLAGS) $(LDFLAGS.$(TOOLSET)) "
        "$(LD_INPUTS) $(LIBS) $(CODIPAD_HOST_LIBS)"
    )
    print(f"Building Node.js {pin['version']} ({sdk}, -j{jobs})...", flush=True)
    _run("make", "-C", "out", "BUILDTYPE=Release", f"-j{jobs}", no_gnu_groups, *goals, cwd=source, env=env)

    produced = []
    for name, goal in zip(runtime_archives, goals):
        if not goal.exists():
            raise ValueError(f"Node build did not produce {goal.relative_to(source)}")
        members = subprocess.check_output(["ar", "t", str(goal)], text=True).split()
        if not [m for m in members if not m.startswith("__.SYMDEF")]:
            raise ValueError(f"Node archive has no object members: {goal.relative_to(source)}")
        destination = release / name
        if goal != destination:
            shutil.copyfile(goal, destination)
        produced.append(destination)

    checked_objects = verify_macho(produced, want_platform, deployment)
    symbols = subprocess.check_output(["xcrun", "nm", "-gU", str(release / "libnode_base.a")], text=True)
    if "InitializeOncePerProcess" not in symbols:
        raise ValueError("Node archive lacks InitializeOncePerProcess entrypoint")

    result = {
        **identity,
        "runtimeArchives": runtime_archives,
        "forceLoad": force_load,
        "layout": layout,
        "archives": {p.name: sha256_file(p) for p in produced},
        "headersSha256": header_digest(source),
        "macho": {"platform": want_platform, "minos": deployment, "objectsChecked": checked_objects},
    }
    (build_dir / "codipad-build.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Built Node.js ({sdk}): {build_dir}", flush=True)
    return build_dir


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), default="iphoneos")
    parser.add_argument("--output", type=Path, help="Output directory (default: .build/<sdk>/node)")
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--jobs", type=int, default=max(1, min(os.cpu_count() or 4, 8)))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    build(sdk=args.sdk, output_dir=args.output, python_bin=args.python, jobs=args.jobs, force=args.force)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
