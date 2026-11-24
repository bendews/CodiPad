#!/usr/bin/env python3
"""Build CodiPad for iPadOS (sources, native dependencies, workbench, and Xcode app)."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from pathlib import Path

import build_ish
import build_libarchive
import build_node
import build_rootfs
import native_runtime
import vscode_extras
import workbench
from sources import ROOT, SourcesError, check_no_symlink, prepare_all, sha256_file, source_state, validate, write_if_changed


def _git_output(*argv: str) -> str:
    return subprocess.check_output(argv, cwd=ROOT, text=True).strip()


def _extension_host_inputs(sqlite_dir: Path, parcel_dir: Path, include_agent: bool) -> dict:
    manifest_path = ROOT / "build/source-manifest.json"
    manifest, resolved = validate(manifest_path)
    vendor = resolved["vendor"]

    notices = manifest["agentHost"]["noticeInputs"]["notices"]
    input_paths = [
        ROOT / "scripts/vscode_extras.py",
        ROOT / "build/runtime-manifest.json",
        ROOT / "build/source-manifest.json",
        ROOT / "workbench/extension-host.mjs",
        ROOT / "workbench/public-bundle.mjs",
        ROOT / "workbench/agent-host.mjs",
        ROOT / "workbench/product-from-configuration.mjs",
        ROOT / "workbench/package-extensions.mjs",
        ROOT / "workbench/package.json",
        ROOT / "workbench/package-lock.json",
        ROOT / "workbench/product.json",
        ROOT / "app/generated/Workbench/configuration.js",
        ROOT / "patches/node/NODE-LICENSE",
        ROOT / "patches/node/A-SHELL-LICENSE.txt",
        ROOT / "native/CodiPadNode/NOTICE",
        ROOT / "app/CodiPad/Extensions/NativeExtensionCatalog.swift",
        ROOT / "scripts/extension-catalog/layout.swift",
        Path(__file__).resolve(),
        vendor / "package.json",
        vendor / "package-lock.json",
        vendor / "product.json",
        vendor / "build/lib/extensions.ts",
        vendor / "build/package.json",
        vendor / "extensions/package.json",
        vendor / "extensions/package-lock.json",
        ROOT / ".build/workbench/upstream-deps/.codipad-dependencies",
        ROOT / ".build/workbench/upstream-deps/package-lock.json",
    ]
    if include_agent:
        input_paths.extend([
            sqlite_dir / "receipt.json",
            sqlite_dir / "package/build/Release/vscode-sqlite3.node",
            parcel_dir / "watcher.node",
            *(ROOT / item["path"] for item in notices.values()),
        ])
    rows = []
    for path in input_paths:
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Extension host input is missing: {path}")
        rel = path.relative_to(ROOT).as_posix() if ROOT in path.parents else str(path)
        rows.append({"path": rel, "mode": path.stat().st_mode & 0o777, "sha256": sha256_file(path)})
    patches = [{"path": p.relative_to(ROOT).as_posix(), "sha256": sha256_file(p)} for p in resolved["patches"]]
    return {"schemaVersion": 1, "upstreamRevision": manifest["upstream"]["revision"], "patches": patches, "inputs": rows}


def prepare_extension_host(
    force: bool = False,
    linux_vsda=None,
    linux_copilot=None,
    sqlite_dir: Path = build_rootfs.DEFAULT_AGENT_HOST_DIR / "sqlite",
    parcel_dir: Path = build_rootfs.DEFAULT_AGENT_HOST_DIR / "parcel-watcher",
    minify: bool = False,
) -> list[dict]:
    output_root = ROOT / "app/generated/Exthost"
    cache_path = output_root / "ExthostReceipt.json"
    # Recover the previous generation if the process died between the two renames.
    backups = list(output_root.parent.glob(".Exthost-prev-*"))
    if not os.path.lexists(output_root) and backups:
        if len(backups) != 1:
            raise ValueError("Multiple interrupted extension-host generations require inspection")
        os.replace(backups[0], output_root)
    if output_root.is_symlink():
        raise ValueError("Extension host output must not be a symlink")
    include_agent = linux_copilot is not None
    if include_agent != (linux_vsda is not None):
        raise ValueError("VS Code extras require both signing and Copilot inputs")
    identity = _extension_host_inputs(sqlite_dir, parcel_dir, include_agent)
    identity["linuxVSDA"] = linux_vsda[1] if linux_vsda else None
    identity["linuxCopilot"] = linux_copilot[2] if linux_copilot else None
    identity["minify"] = minify

    if not force and output_root.is_dir() and not output_root.is_symlink() and cache_path.is_file():
        try:
            cached = json.loads(cache_path.read_text())
            files = workbench.artifact_files(output_root)
            if cached.get("identity") == identity and cached.get("files") == files:
                print(f"Extension host ready: {output_root}", flush=True)
                return workbench.artifact_files(output_root, include_host_receipt=True)
        except (OSError, ValueError, json.JSONDecodeError):
            pass

    print("Packaging extension host & built-in extensions...", flush=True)
    output_root.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".Exthost-attempt-", dir=output_root.parent) as temporary:
        staged = Path(temporary) / "Exthost"
        node = workbench.node_tool()
        exthost_cmd = [
            str(node), str(ROOT / "workbench/extension-host.mjs"),
            str(ROOT / "vendor/vscode"), str(staged),
            str(ROOT / ".build/workbench/upstream-deps"),
            str(ROOT / "app/generated/Workbench/configuration.js"),
            str(sqlite_dir), str(parcel_dir),
        ]
        if include_agent:
            exthost_cmd.append("--with-vscode-extras")
        if minify:
            exthost_cmd.append("--minify")
        subprocess.run(exthost_cmd, cwd=ROOT, check=True)
        if linux_vsda and linux_copilot:
            vscode_extras.stage_exthost(linux_vsda, linux_copilot, staged)

        validator = Path(temporary) / "catalog-layout-check"
        subprocess.run(
            ["xcrun", "swiftc", "-O", "-o", str(validator),
             "app/CodiPad/Extensions/NativeExtensionCatalog.swift",
             "scripts/extension-catalog/layout.swift"], cwd=ROOT, check=True,
        )
        subprocess.run([str(validator), str(staged)], cwd=ROOT, check=True)
        files = workbench.artifact_files(staged)
        (staged / "ExthostReceipt.json").write_text(
            json.dumps({"identity": identity, "files": files}, sort_keys=True, indent=2) + "\n"
        )
        previous = output_root.with_name(f".Exthost-prev-{uuid.uuid4().hex[:8]}")
        had_previous = output_root.exists()
        if had_previous:
            os.replace(output_root, previous)
        try:
            os.replace(staged, output_root)
        except OSError:
            if had_previous:
                os.replace(previous, output_root)
            raise
        if had_previous:
            shutil.rmtree(previous)
    print(f"Built extension host: {output_root}", flush=True)
    return workbench.artifact_files(output_root, include_host_receipt=True)



def build_receipt(
    sdk: str,
    configuration: str,
    team: str | None,
    bundle_id: str | None,
    shared_execution: bool,
    extended_virtual_addressing: bool,
    workbench_record: dict,
    runtime_record: dict,
    extension_host_files: list[dict],
    vscode_extras_enabled: bool,
) -> dict:
    manifest_path = ROOT / "build/source-manifest.json"
    manifest, resolved = validate(manifest_path)
    record = {
        "schemaVersion": 1,
        "source": source_state(ROOT),
        "sourceManifest": manifest,
        "upstreamRevision": _git_output("git", "-C", str(resolved["vendor"]), "rev-parse", "HEAD"),
        "workbench": workbench_record,
        "nativeRuntime": runtime_record,
        "extensionHostBundle": extension_host_files,
        "toolchain": {
            "xcode": _git_output("xcodebuild", "-version"),
            "sdk": sdk,
            "sdkVersion": _git_output("xcrun", "--sdk", sdk, "--show-sdk-version"),
        },
        "configuration": configuration,
        "bundleIdentifier": bundle_id or "com.bendews.codipad",
        "vscodeExtras": vscode_extras_enabled,
        "signing": {
            "enabled": bool(team) or sdk == "iphonesimulator",
            "team": team,
            "extendedVirtualAddressing": extended_virtual_addressing,
        },
        "sharedExecution": shared_execution,
    }
    record["buildInputSha256"] = hashlib.sha256(
        json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return record


def ensure_dependencies(args) -> None:
    prepare_all()
    build_node.build(sdk=args.sdk, output_dir=args.node_build, jobs=args.jobs, force=args.rebuild)
    build_libarchive.build(sdk=args.sdk, force=args.rebuild)
    build_ish.build(sdk=args.sdk, jobs=args.jobs, force=args.rebuild)
    if not args.rootfs:
        build_rootfs.build_rootfs(docker_context=args.docker_context, force=args.rebuild)
    if args.with_vscode_extras:
        build_rootfs.build_agent_sqlite(docker_context=args.docker_context, force=args.rebuild)
        build_rootfs.prepare_parcel_watcher(force=args.rebuild)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-sources", action="store_true", help="Clone and patch pinned VS Code, iSH, and libarchive sources, then exit")
    parser.add_argument("--build-deps", action="store_true", help="Build and cache native dependencies, including agent-host addons when extras are enabled, then exit")
    parser.add_argument("--skip-deps", action="store_true", help="Skip building native dependencies (verify existing cached builds only)")
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), default="iphoneos")
    parser.add_argument("--configuration", choices=("Debug", "Release"), default="Release")
    parser.add_argument("--team", help="Apple Development Team ID for code signing")
    parser.add_argument("--bundle-id", help="Override PRODUCT_BUNDLE_IDENTIFIER (default: com.bendews.codipad)")
    parser.add_argument("--allow-provisioning-updates", action="store_true", help="Pass -allowProvisioningUpdates to xcodebuild")
    parser.add_argument("--extended-virtual-addressing", action="store_true", help="Enable the extended virtual addressing entitlement (Debug builds)")
    parser.add_argument("--rootfs", type=Path, help="Use a prebuilt Linux ARM64 rootfs .tar.gz instead of building one with Docker")
    parser.add_argument("--docker-context", help="Optional Docker context for Linux rootfs and SQLite builds")
    parser.add_argument("--node-build", type=Path, help="Use an existing native Node.js build directory")
    execution = parser.add_mutually_exclusive_group()
    execution.add_argument("--shared-execution", action="store_true", help="Enable shared Linux/Node execution (default)")
    execution.add_argument("--embedded-only", action="store_true", help="Build with embedded Node only (disable shared Linux execution)")
    parser.add_argument("--with-vscode-extras", action="store_true", help="Download and stage the VS Code signer, Copilot extension and agent host for a separately authorized local build")
    gallery = parser.add_mutually_exclusive_group()
    gallery.add_argument("--with-microsoft-marketplace", action="store_true",
                         help="Configure the Microsoft Visual Studio Marketplace for an authorized build")
    gallery.add_argument("--extension-gallery", type=Path, help="JSON configuration for an authorized HTTPS extension gallery")
    parser.add_argument("--vscode-darwin-archive", type=Path, help="Local VSCode-darwin-arm64.zip for --with-vscode-extras")
    parser.add_argument("--vscode-linux-archive", type=Path, help="Local vscode-server-linux-arm64.tar.gz for --with-vscode-extras")
    parser.add_argument("--rebuild", action="store_true", help="Force rebuilding generated artifacts instead of reusing cached outputs")
    parser.add_argument("--jobs", type=int, default=max(1, min(os.cpu_count() or 4, 8)), help="Parallel build jobs")
    args = parser.parse_args(argv)

    if not args.prepare_sources and (not hasattr(hashlib, "file_digest") or not hasattr(tarfile, "data_filter")):
        parser.error("the build requires hashlib.file_digest and tarfile extraction filters; use Python 3.12 or later")
    if args.allow_provisioning_updates and not args.team:
        parser.error("--allow-provisioning-updates requires --team")
    if args.extended_virtual_addressing and (not args.team or args.configuration != "Debug"):
        parser.error("--extended-virtual-addressing requires a signed Debug build")
    if (args.vscode_darwin_archive or args.vscode_linux_archive) and not args.with_vscode_extras:
        args.with_vscode_extras = True

    shared_execution = not args.embedded_only

    lock_path = ROOT / ".build/build.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _run_build(args, shared_execution)


def _run_build(args, shared_execution: bool) -> int:
    try:
        gallery = workbench.load_extension_gallery(args.extension_gallery) if args.extension_gallery else None
        if args.prepare_sources:
            prepare_all()
            return 0
        if args.build_deps:
            ensure_dependencies(args)
            return 0
        if not args.skip_deps:
            ensure_dependencies(args)

        darwin_archive = linux_archive = None
        if args.with_vscode_extras:
            darwin_archive, linux_archive = vscode_extras.resolve_archives(
                args.vscode_darwin_archive, args.vscode_linux_archive
            )

        minify = args.configuration == "Release"
        workbench_record = workbench.build(
            reuse_existing=not args.rebuild,
            vscode_darwin_archive=darwin_archive,
            extension_gallery=gallery,
            microsoft_marketplace=args.with_microsoft_marketplace,
            minify=minify,
        )
        runtime_record = native_runtime.prepare_app(
            sdk=args.sdk,
            node_dir=args.node_build,
            shared_execution=shared_execution,
            rootfs_override=args.rootfs,
        )
        linux_vsda, linux_copilot = (
            vscode_extras.inspect_linux_archive(linux_archive) if linux_archive else (None, None)
        )
        exthost_files = prepare_extension_host(
            force=args.rebuild,
            linux_vsda=linux_vsda,
            linux_copilot=linux_copilot,
            minify=minify,
        )
        record = build_receipt(
            sdk=args.sdk,
            configuration=args.configuration,
            team=args.team,
            bundle_id=args.bundle_id,
            shared_execution=shared_execution,
            extended_virtual_addressing=args.extended_virtual_addressing,
            workbench_record=workbench_record,
            runtime_record=runtime_record,
            extension_host_files=exthost_files,
            vscode_extras_enabled=args.with_vscode_extras,
        )

        generated = ROOT / "app/generated"
        receipt_path = generated / "BuildReceipt.json"
        write_if_changed(receipt_path, (json.dumps(record, sort_keys=True, indent=2) + "\n").encode())

        native_runtime.verify_prepared_app(runtime_record, args.sdk, args.node_build, shared_execution, args.rootfs)

        platform = "iOS" if args.sdk == "iphoneos" else "iOS Simulator"
        build_root = ROOT / ".build" / args.sdk
        build_root.mkdir(parents=True, exist_ok=True)
        product = build_root / f"DerivedData/Build/Products/{args.configuration}-{args.sdk}/CodiPad.app"
        if os.path.lexists(product):
            check_no_symlink(ROOT, product)
            shutil.rmtree(product)

        command = [
            "xcodebuild", "-project", "CodiPad.xcodeproj", "-scheme", "CodiPad",
            "-configuration", args.configuration, "-sdk", args.sdk,
            "-destination", f"generic/platform={platform}",
            "-derivedDataPath", str(build_root / "DerivedData"),
            "build",
        ]
        if args.bundle_id:
            command.append(f"PRODUCT_BUNDLE_IDENTIFIER={args.bundle_id}")
        if args.team:
            command.append(f"DEVELOPMENT_TEAM={args.team}")
        elif args.sdk == "iphonesimulator":
            command += ["CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
        else:
            command.append("CODE_SIGNING_ALLOWED=NO")
        if args.extended_virtual_addressing:
            command.append("CODIPAD_APP_ENTITLEMENTS=app/CodiPad/Development.entitlements")
        if args.allow_provisioning_updates:
            command.append("-allowProvisioningUpdates")

        log_path = build_root / f"xcodebuild-{args.configuration}.log"
        print(f"Building CodiPad.app ({args.configuration}, {args.sdk})...", flush=True)
        started = time.perf_counter()
        with log_path.open("wb") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        elapsed = round(time.perf_counter() - started, 1)

        if result.returncode != 0:
            print(f"xcodebuild failed after {elapsed}s (log: {log_path}):", file=sys.stderr)
            print("\n".join(log_path.read_text(errors="replace").splitlines()[-50:]), file=sys.stderr)
            return result.returncode

        if (product / "BuildReceipt.json").read_bytes() != receipt_path.read_bytes():
            raise ValueError("Bundled BuildReceipt.json differs from generated receipt")

        label = (
            "Signed app" if args.team
            else "Simulator app" if args.sdk == "iphonesimulator"
            else "Unsigned app"
        )
        print(f"{label} ready ({elapsed}s): {product}")
        return 0
    except (SourcesError, ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"build.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
