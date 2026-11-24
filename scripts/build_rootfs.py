#!/usr/bin/env python3
"""Build the Linux ARM64 development rootfs and agent-host native addons via Docker."""

from __future__ import annotations

import argparse
import ast
import base64
import copy
import gzip
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import uuid
from pathlib import Path, PurePosixPath

from sources import ROOT, download_verified, sha256_file

DEFAULT_ROOTFS_DIR = ROOT / ".build/rootfs"
DEFAULT_AGENT_HOST_DIR = ROOT / ".build/agent-host"
CACHE_DIR = ROOT / ".build/cache"


def _docker_cmd(context: str | None) -> list[str]:
    docker = shutil.which("docker")
    if not docker:
        raise ValueError("docker is required to build the Linux ARM64 rootfs and native addons")
    return [docker, "--context", context] if context else [docker]


def _check_docker_arm64(docker: list[str]) -> None:
    try:
        info = json.loads(subprocess.check_output([*docker, "version", "--format", "{{json .Server}}"], text=True, timeout=15))
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        raise ValueError(f"Docker daemon is unavailable: {exc}") from exc
    if info.get("Os") != "linux" or info.get("Arch") not in ("arm64", "aarch64"):
        raise ValueError(
            f"Docker must run a Linux ARM64 engine (found {info.get('Os')}/{info.get('Arch')})"
        )


def _verify_integrity(path: Path, integrity: str) -> None:
    algorithm, expected = integrity.split("-", 1)
    if algorithm != "sha512":
        raise ValueError(f"Unsupported integrity algorithm: {algorithm}")
    with path.open("rb") as stream:
        actual = base64.b64encode(hashlib.file_digest(stream, "sha512").digest()).decode()
    if actual != expected:
        raise ValueError(f"npm integrity mismatch for {path.name}")


def _verify_elf64_aarch64(path: Path) -> None:
    with path.open("rb") as stream:
        header = stream.read(64)
    if len(header) < 64 or header[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<HH", header, 16) != (3, 183):
        raise ValueError(f"Not a little-endian AArch64 shared ELF: {path}")


def _extract_npm_package(archive_path: Path, destination: Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    with tarfile.open(archive_path, "r:*") as tar:
        for member in tar.getmembers():
            parts = PurePosixPath(member.name).parts[1:]
            if not parts or any(p in ("", "..") for p in parts):
                continue
            target = destination.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as src, target.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
                target.chmod(member.mode & 0o777)


def _normalize_rootfs_tar(exported: Path, destination: Path) -> int:
    """Normalize an exported Docker container tar into a deterministic gzipped PAX rootfs."""
    def clean(name: str) -> str:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"Unsafe rootfs member: {name!r}")
        return str(path).removeprefix("./").rstrip("/")

    with tarfile.open(exported) as source, destination.open("wb") as raw:
        members = {clean(m.name): m for m in source.getmembers() if clean(m.name)}
        emitted: set[str] = set()
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as target:
                def emit(name: str) -> None:
                    if name in emitted or name in (".dockerenv",):
                        return
                    member = members[name]
                    emitted.add(name)
                    if member.islnk():
                        dep = clean(member.linkname)
                        if dep in members:
                            emit(dep)
                    copied = copy.copy(member)
                    copied.name = name
                    copied.mtime = 0
                    copied.uname = copied.gname = ""
                    copied.pax_headers = {
                        k: v for k, v in copied.pax_headers.items() if k not in ("atime", "ctime", "mtime")
                    }
                    data = source.extractfile(member) if member.isfile() else None
                    try:
                        target.addfile(copied, data)
                    finally:
                        if data is not None:
                            data.close()

                for name in sorted(members):
                    emit(name)
    return len(emitted)


def build_rootfs(
    output_dir: Path = DEFAULT_ROOTFS_DIR,
    docker_context: str | None = None,
    force: bool = False,
) -> Path:
    """Build the Linux ARM64 development rootfs tarball in Docker."""
    spec = json.loads((ROOT / "build/runtime-manifest.json").read_text())["rootfs"]
    output_dir = output_dir.resolve()
    archive_path = output_dir / "rootfs.tar.gz"
    receipt_path = output_dir / "receipt.json"

    if not force and archive_path.is_file() and receipt_path.is_file():
        try:
            receipt = json.loads(receipt_path.read_text())
            if receipt.get("spec") == spec and receipt.get("sha256") == sha256_file(archive_path):
                print(f"Linux rootfs ready: {archive_path}", flush=True)
                return archive_path
        except (OSError, ValueError, json.JSONDecodeError):
            pass

    docker = _docker_cmd(docker_context)
    _check_docker_arm64(docker)

    uv = spec["uv"]
    uv_tarball = download_verified(uv["url"], CACHE_DIR / f"uv-{uv['version']}-aarch64.tar.gz", uv["sha256"])
    license_paths = {
        name: download_verified(entry["url"], CACHE_DIR / f"uv-{uv['version']}-{name}", entry["sha256"])
        for name, entry in uv["licenseFiles"].items()
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    tag = f"codipad-rootfs:{uuid.uuid4().hex[:12]}"
    container_name = f"codipad-rootfs-{uuid.uuid4().hex[:12]}"
    with tempfile.TemporaryDirectory(prefix="codipad-rootfs-ctx.") as tmp:
        ctx = Path(tmp)
        with tarfile.open(uv_tarball, "r:gz") as tar:
            root = uv["archiveRoot"]
            for exe in ("uv", "uvx"):
                member = tar.getmember(f"{root}/{exe}")
                with tar.extractfile(member) as src, (ctx / exe).open("wb") as dst:
                    shutil.copyfileobj(src, dst)
                (ctx / exe).chmod(0o755)
        for name, path in license_paths.items():
            shutil.copy2(path, ctx / name)

        apt_packages = " ".join(spec["aptPackages"])
        license_copies = "\n".join(
            f"COPY {name} /{entry['path']}" for name, entry in uv["licenseFiles"].items()
        )
        dockerfile = f"""FROM --platform=linux/arm64 {spec['baseImage']}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends {apt_packages} \
    && rm -rf /var/lib/apt/lists/* /var/cache/ldconfig/aux-cache /var/log/alternatives.log
COPY uv /usr/local/bin/uv
COPY uvx /usr/local/bin/uvx
RUN chmod 0755 /usr/local/bin/uv /usr/local/bin/uvx
{license_copies}
"""
        (ctx / "Dockerfile").write_text(dockerfile)
        print(f"Building Linux ARM64 rootfs from {spec['baseImage']}...", flush=True)
        subprocess.run([*docker, "build", "--platform", "linux/arm64", "-t", tag, str(ctx)], check=True)
        exported = ctx / "export.tar"
        try:
            subprocess.run([*docker, "create", "--platform", "linux/arm64", "--name", container_name, tag], check=True)
            subprocess.run([*docker, "export", "--output", str(exported), container_name], check=True)
            pending = output_dir / "rootfs.tar.gz.pending"
            members = _normalize_rootfs_tar(exported, pending)
            pending.replace(archive_path)
        finally:
            subprocess.run([*docker, "rm", "-f", container_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run([*docker, "rmi", "-f", tag], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    digest = sha256_file(archive_path)
    receipt = {
        "schemaVersion": 1,
        "spec": spec,
        "archive": str(archive_path),
        "sha256": digest,
        "bytes": archive_path.stat().st_size,
        "members": members,
    }
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Built Linux rootfs: {archive_path} ({digest[:16]}...)", flush=True)
    return archive_path


def prepare_parcel_watcher(output_dir: Path = DEFAULT_AGENT_HOST_DIR / "parcel-watcher", force: bool = False) -> Path:
    """Download and verify the pinned Linux ARM64 @parcel/watcher prebuild."""
    pin = json.loads((ROOT / "build/source-manifest.json").read_text())["agentHost"]["parcel"]
    output_dir = output_dir.resolve()
    receipt_path = output_dir / ".codipad-parcel.json"
    binary = output_dir / "watcher.node"

    if not force and binary.is_file() and receipt_path.is_file():
        try:
            receipt = json.loads(receipt_path.read_text())
            if receipt.get("pin") == pin and receipt.get("binarySha256") == sha256_file(binary):
                print(f"@parcel/watcher ready: {output_dir}", flush=True)
                return output_dir
        except (OSError, ValueError, json.JSONDecodeError):
            pass

    archive = download_verified(
        pin["url"], CACHE_DIR / f"parcel-watcher-linux-arm64-glibc-{pin['version']}.tgz", pin["sha256"]
    )
    _verify_integrity(archive, pin["integrity"])
    _extract_npm_package(archive, output_dir)
    _verify_elf64_aarch64(binary)
    receipt = {"schemaVersion": 1, "pin": pin, "binarySha256": sha256_file(binary)}
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Prepared @parcel/watcher: {output_dir}", flush=True)
    return output_dir



def build_agent_sqlite(
    output_dir: Path = DEFAULT_AGENT_HOST_DIR / "sqlite",
    docker_context: str | None = None,
    force: bool = False,
) -> Path:
    """Compile the pinned @vscode/sqlite3 Node-API addon for Linux ARM64 in Docker."""
    source_manifest = json.loads((ROOT / "build/source-manifest.json").read_text())
    sqlite_pin = source_manifest["agentHost"]["sqlite"]
    napi_pin = sqlite_pin["nodeAddonApi"]
    base_image = json.loads((ROOT / "build/runtime-manifest.json").read_text())["rootfs"]["baseImage"]

    output_dir = output_dir.resolve()
    receipt_path = output_dir / "receipt.json"
    artifact_path = output_dir / "package/build/Release/vscode-sqlite3.node"

    if not force and artifact_path.is_file() and receipt_path.is_file():
        try:
            receipt = json.loads(receipt_path.read_text())
            if (
                receipt.get("completionState") == "passed"
                and receipt.get("sqlitePin") == sqlite_pin
                and receipt.get("baseImage") == base_image
                and receipt.get("artifact", {}).get("sha256") == sha256_file(artifact_path)
            ):
                print(f"@vscode/sqlite3 ready: {output_dir}", flush=True)
                return output_dir
        except (OSError, ValueError, json.JSONDecodeError):
            pass

    docker = _docker_cmd(docker_context)
    _check_docker_arm64(docker)

    sqlite_tgz = download_verified(sqlite_pin["url"], CACHE_DIR / f"sqlite3-{sqlite_pin['version']}.tgz", sqlite_pin["sha256"])
    _verify_integrity(sqlite_tgz, sqlite_pin["integrity"])
    napi_tgz = download_verified(napi_pin["url"], CACHE_DIR / f"node-addon-api-{napi_pin['version']}.tgz", napi_pin["sha256"])
    _verify_integrity(napi_tgz, napi_pin["integrity"])

    if output_dir.exists():
        shutil.rmtree(output_dir)
    package_dir = output_dir / "package"
    _extract_npm_package(sqlite_tgz, package_dir)
    _extract_npm_package(napi_tgz, package_dir / "node_modules/node-addon-api")

    binding = ast.literal_eval((package_dir / "binding.gyp").read_text())["targets"][0]
    sqlite_gyp = ast.literal_eval((package_dir / "deps/sqlite3.gyp").read_text())
    common = ast.literal_eval((package_dir / "deps/common-sqlite.gypi").read_text())
    sqlite_target = next(t for t in sqlite_gyp["targets"] if t["target_name"] == "sqlite3")
    napi_except = ast.literal_eval((package_dir / "node_modules/node-addon-api/except.gypi").read_text())

    amalgamation = output_dir / "amalgamation"
    amalgamation.mkdir()
    sqlite_ver = common["variables"]["sqlite_version%"]
    with tarfile.open(package_dir / f"deps/sqlite-autoconf-{sqlite_ver}.tar.gz", "r:gz") as tar:
        for member in tar.getmembers():
            name = PurePosixPath(member.name).name
            if member.isfile() and name in ("sqlite3.c", "sqlite3.h", "sqlite3ext.h", "README.txt"):
                with tar.extractfile(member) as src, (amalgamation / name).open("wb") as dst:
                    shutil.copyfileobj(src, dst)

    release_defs = [f"-D{d}" for d in common["target_defaults"]["configurations"]["Release"]["defines"]]
    sqlite_defs = [f"-D{d}" for d in sqlite_target["defines"]]
    sqlite_flags = sqlite_gyp["target_defaults"]["cflags"]
    binding_defs = [f"-D{d}" for d in (binding["defines"] + napi_except["defines"] + sqlite_target["direct_dependent_settings"]["defines"])]
    binding_flags = binding["cflags"]
    sources = binding["sources"]

    # Compile inside a throwaway linux/arm64 container using the exact base image's Node 24 headers & glibc.
    compile_lines = [
        "set -eu",
        "apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential >/dev/null",
        "mkdir -p /work/objects /work/package/build/Release",
        "COMMON='-fPIC -fstack-protector-strong -pthread -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 "
        + " ".join(release_defs)
        + " -I/usr/local/include/node -I/work/amalgamation'",
        f"gcc $COMMON {' '.join(sqlite_flags)} -O3 {' '.join(sqlite_defs)} -c /work/amalgamation/sqlite3.c -o /work/objects/sqlite3.o",
        "ar rcsD /work/objects/sqlite3.a /work/objects/sqlite3.o",
    ]
    objs = []
    for src in sources:
        obj = f"/work/objects/{Path(src).stem}.o"
        objs.append(obj)
        compile_lines.append(
            f"g++ $COMMON -std=c++17 -fexceptions -fno-rtti -I/work/package/node_modules/node-addon-api "
            f"{' '.join(binding_flags)} {' '.join(binding_defs)} -c /work/package/{src} -o {obj}"
        )
    compile_lines.append(
        f"g++ -shared {' '.join(objs)} /work/objects/sqlite3.a -pthread -lm -Wl,--build-id=sha1 -Wl,-z,noexecstack "
        "-o /work/package/build/Release/vscode-sqlite3.node"
    )
    compile_lines.append("nm --dynamic --defined-only /work/package/build/Release/vscode-sqlite3.node | grep -q ' napi_register_module_v1$'")

    print(f"Building @vscode/sqlite3 ({sqlite_pin['version']}) for linux/arm64 in Docker...", flush=True)
    subprocess.run(
        [
            *docker, "run", "--rm", "--platform", "linux/arm64",
            "-v", f"{output_dir}:/work",
            base_image, "sh", "-c", "\n".join(compile_lines),
        ],
        check=True,
    )

    _verify_elf64_aarch64(artifact_path)
    receipt = {
        "schemaVersion": 1,
        "completionState": "passed",
        "target": "linux-aarch64",
        "baseImage": base_image,
        "sqlitePin": sqlite_pin,
        "artifact": {
            "path": "package/build/Release/vscode-sqlite3.node",
            "sha256": sha256_file(artifact_path),
            "bytes": artifact_path.stat().st_size,
            "format": "ELF64 little-endian AArch64 ET_DYN",
            "export": "napi_register_module_v1",
        },
    }
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Built @vscode/sqlite3: {artifact_path}", flush=True)
    return output_dir


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker-context", help="Optional Docker context (uses active context by default)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--rootfs-only", action="store_true", help="Only build the Linux rootfs archive")
    mode.add_argument("--addons-only", action="store_true", help="Only prepare native agent-host addons")
    parser.add_argument("--force", action="store_true", help="Rebuild even if cached outputs match")
    args = parser.parse_args()
    try:
        if not args.addons_only:
            build_rootfs(docker_context=args.docker_context, force=args.force)
        if not args.rootfs_only:
            build_agent_sqlite(docker_context=args.docker_context, force=args.force)
            prepare_parcel_watcher(force=args.force)
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"build_rootfs.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
