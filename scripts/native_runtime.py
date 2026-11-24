"""Verify locally built native runtime libraries and generate Xcode link settings."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

from build_ish import ARCHIVES as ISH_ARCHIVES, IMPORTER_ARCHIVE, default_output as default_ish_dir, is_cached_valid as ish_valid
from build_libarchive import default_output as default_libarchive_dir, is_cached_valid as libarchive_valid
from build_node import default_output as default_node_dir, header_digest, is_cached_valid as node_valid
from build_rootfs import DEFAULT_ROOTFS_DIR
from sources import ROOT, sha256_file, verify_runtime_sources, write_if_changed


def default_rootfs_archive() -> Path:
    return DEFAULT_ROOTFS_DIR / "rootfs.tar.gz"


def verify_node(sdk: str, node_dir: Path | None = None) -> tuple[Path, dict]:
    build_dir = (node_dir or default_node_dir(sdk)).resolve()
    if not node_valid(build_dir, sdk):
        raise ValueError(
            f"Node.js build for {sdk} is missing or out of date at {build_dir}. "
            f"Run: python3 scripts/build.py --build-deps --sdk {sdk}"
        )
    receipt = json.loads((build_dir / "codipad-build.json").read_text())
    source = build_dir / "source"
    if receipt.get("headersSha256") != header_digest(source):
        raise ValueError("Node.js embedding headers changed since archives were built")
    return source, receipt


def verify_shell(sdk: str, rootfs_override: Path | None = None) -> dict:
    locked = json.loads((ROOT / "build/runtime-manifest.json").read_text())["ish"]
    origin, _, libarchive_headers = verify_runtime_sources(locked)

    ish_dir = default_ish_dir(sdk).resolve()
    if not ish_valid(ish_dir, sdk, locked, libarchive_headers):
        raise ValueError(
            f"iSH kernel build for {sdk} is missing or out of date at {ish_dir}. "
            f"Run: python3 scripts/build.py --build-deps --sdk {sdk}"
        )
    ish_receipt = json.loads((ish_dir / "receipt.json").read_text())

    libarchive_dir = default_libarchive_dir(sdk).resolve()
    if not libarchive_valid(libarchive_dir, sdk, locked, libarchive_headers):
        raise ValueError(
            f"libarchive build for {sdk} is missing or out of date at {libarchive_dir}. "
            f"Run: python3 scripts/build.py --build-deps --sdk {sdk}"
        )
    libarchive_receipt = json.loads((libarchive_dir / "receipt.json").read_text())

    rootfs = (rootfs_override or default_rootfs_archive()).resolve()
    if not rootfs.is_file() or rootfs.is_symlink():
        raise ValueError(
            f"Linux rootfs archive not found at {rootfs}. "
            "Run scripts/build_rootfs.py or pass --rootfs <path>."
        )
    rootfs_sha = sha256_file(rootfs)

    ish_build = Path(ish_receipt["buildDirectory"])
    inputs = {str(ish_build / name): digest for name, digest in ish_receipt["archives"].items()}
    inputs[str(ish_build / IMPORTER_ARCHIVE)] = ish_receipt["deviceImporter"]["sha256"]
    inputs[libarchive_receipt["archive"]] = libarchive_receipt["sha256"]
    inputs[str(rootfs)] = rootfs_sha

    revision = subprocess.check_output(["git", "-C", str(origin), "rev-parse", "HEAD"], text=True).strip()
    return {
        "revision": revision,
        "sdk": sdk,
        "inputs": inputs,
        "rootfsSha256": rootfs_sha,
        "rootfsArchive": str(rootfs),
        "sourceDirectory": ish_receipt["sourceDirectory"],
        "buildDirectory": ish_receipt["buildDirectory"],
        "libarchiveHeadersDirectory": str(libarchive_headers),
        "patches": ish_receipt["patches"],
        "patchOrder": ish_receipt["patchOrder"],
    }


def prepare_app(
    sdk: str,
    node_dir: Path | None = None,
    shared_execution: bool = True,
    rootfs_override: Path | None = None,
) -> dict:
    source, node_record = verify_node(sdk, node_dir)
    shell = verify_shell(sdk, rootfs_override)
    if shared_execution and "native-execution-region.patch" not in shell["patches"]:
        raise ValueError("Shared execution requires a kernel built with native-execution-region.patch")

    generated = ROOT / "app/generated"
    generated.mkdir(parents=True, exist_ok=True)

    includes = [
        source / "src",
        source / "deps/v8/include",
        source / "deps/uv/include",
        ROOT / "native/CodiPadProcess",
        ROOT / "native/CodiPadExecution",
        Path(shell["sourceDirectory"]),
        Path(shell["buildDirectory"]),
        Path(shell["buildDirectory"]) / "deps",
        Path(shell["libarchiveHeadersDirectory"]),
    ]
    libraries = []
    for name in node_record["runtimeArchives"]:
        path = str(source / "out/Release" / name)
        libraries.append(json.dumps(f"-Wl,-force_load,{path}" if name in node_record["forceLoad"] else path))
    libraries += [json.dumps(path) for path in shell["inputs"] if path.endswith(".a")]

    rootfs = generated / "ShellRootfs.tar.gz"
    if not rootfs.is_file() or sha256_file(rootfs) != shell["rootfsSha256"]:
        shutil.copyfile(shell["rootfsArchive"], rootfs)

    shared_flags = ""
    if shared_execution:
        shared_flags = (
            "GCC_PREPROCESSOR_DEFINITIONS = $(inherited) CODIPAD_ENABLE_SHARED_EXECUTION=1\n"
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) CODIPAD_ENABLE_SHARED_EXECUTION\n"
        )

    xcconfig = (
        "// Generated by scripts/native_runtime.py — do not edit manually.\n"
        "CLANG_CXX_LANGUAGE_STANDARD = c++20\n"
        "GCC_ENABLE_CPP_EXCEPTIONS = NO\n"
        "IPHONEOS_DEPLOYMENT_TARGET = 18.0\n"
        "HEADER_SEARCH_PATHS = $(inherited) " + " ".join(json.dumps(str(p)) for p in includes) + "\n"
        "OTHER_LDFLAGS = $(inherited) -lc++ -lsqlite3 -lresolv -liconv -lbz2 -lpthread "
        "-framework Foundation -framework Security -framework CoreFoundation -framework SystemConfiguration "
        + " ".join(libraries)
        + "\n"
        + shared_flags
    )
    write_if_changed(generated / "NativeRuntime.xcconfig", xcconfig.encode())

    receipt = {
        "node": node_record,
        "shell": shell,
        "sharedExecution": shared_execution,
        "configurationSha256": sha256_file(generated / "NativeRuntime.xcconfig"),
    }
    return receipt


def verify_prepared_app(receipt: dict, sdk: str, node_dir: Path | None = None,
                        shared_execution: bool = True, rootfs_override: Path | None = None) -> None:
    """Verify the generated link settings and runtime inputs against the shipped receipt."""
    _, node_record = verify_node(sdk, node_dir)
    generated = ROOT / "app/generated"
    if receipt.get("node") != node_record or receipt.get("shell") != verify_shell(sdk, rootfs_override):
        raise ValueError("Native runtime inputs differ from the build receipt")
    if receipt.get("configurationSha256") != sha256_file(generated / "NativeRuntime.xcconfig"):
        raise ValueError("Native runtime xcconfig changed unexpectedly")
    if sha256_file(generated / "ShellRootfs.tar.gz") != receipt["shell"]["rootfsSha256"]:
        raise ValueError("Bundled ShellRootfs.tar.gz changed unexpectedly")
    if receipt.get("sharedExecution") != shared_execution:
        raise ValueError("Shared execution flag differs from the build receipt")
