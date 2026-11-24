"""Optional VS Code extras (vsda signing & Linux Copilot built-in) for separately authorized local builds.

Off by default. When enabled via --with-vscode-extras, this fetches (or reads locally)
the pinned official VS Code 1.143.1 archives, verifies their SHA-256 digests, and stages:
  - Web vsda WASM + product proposal policies into Workbench (for Remote SSH & Copilot APIs)
  - Linux ARM64 vsda.node + built-in Copilot extension into Exthost

These components remain subject to Microsoft's VS Code license and are never redistributed
as part of the public source tree.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath
from zipfile import ZipFile

from sources import ROOT, SourcesError, download_verified, sha256_file

REVISION = "e646868227c3e3a9e3f24277c8c7220be42c0be7"
VERSION = "1.143.1"

DARWIN_ARCHIVE_SHA256 = "65ced7020e995c296e121881b10cd7ba46638cebc5dde0cb921bc82de13cd772"
DARWIN_ARCHIVE_URL = (
    f"https://vscode.download.prss.microsoft.com/dbazure/download/stable/{REVISION}/VSCode-darwin-arm64.zip"
)
DARWIN_ROOT = "Visual Studio Code.app/Contents/Resources/app/"
DARWIN_FILES = {
    "node_modules/vsda/rust/web/vsda.js": "node_modules/vsda/rust/web/vsda.js",
    "node_modules/vsda/rust/web/vsda_bg.wasm": "node_modules/vsda/rust/web/vsda_bg.wasm",
    "LICENSE.rtf": "Microsoft-VSCode-LICENSE.rtf",
    "ThirdPartyNotices.txt": "Microsoft-VSCode-ThirdPartyNotices.txt",
}

LINUX_ARCHIVE_SHA256 = "bfcbb281e241b0080d04c2ffff927660070aeab608885df71dfdbf2720f3516e"
LINUX_ARCHIVE_URL = f"https://update.code.visualstudio.com/commit:{REVISION}/server-linux-arm64/stable"
LINUX_ROOT = "vscode-server-linux-arm64/"
LINUX_FILES = {
    "node_modules/vsda/index.js": "node_modules/vsda/index.js",
    "node_modules/vsda/package.json": "node_modules/vsda/package.json",
    "node_modules/vsda/build/Release/vsda.node": "node_modules/vsda/build/Release/vsda.node",
    "LICENSE": "Microsoft-VSCode-Server-LICENSE.txt",
}

COPILOT_PREFIX = LINUX_ROOT + "extensions/copilot/"
TARGET_DIRECTORY = "copilot"
TARGET_MANIFEST = "builtin-runtime-targets.json"
MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024
MAX_ENTRIES = 1000
CACHE_DIR = ROOT / ".build/cache/vscode-extras"


def resolve_archives(darwin_path: Path | None = None, linux_path: Path | None = None) -> tuple[Path, Path]:
    """Return verified local paths for the pinned VS Code macOS and Linux server archives."""
    darwin = (
        darwin_path.resolve()
        if darwin_path
        else download_verified(DARWIN_ARCHIVE_URL, CACHE_DIR / f"VSCode-darwin-arm64-{VERSION}.zip", DARWIN_ARCHIVE_SHA256)
    )
    linux = (
        linux_path.resolve()
        if linux_path
        else download_verified(
            LINUX_ARCHIVE_URL, CACHE_DIR / f"vscode-server-linux-arm64-{VERSION}.tar.gz", LINUX_ARCHIVE_SHA256
        )
    )
    return darwin, linux


def _validate_linux_arm64_elf(data: bytes, message: str) -> None:
    if len(data) < 20 or data[:6] != b"\x7fELF\x02\x01" or int.from_bytes(data[18:20], "little") != 183:
        raise ValueError(message)


def inspect_darwin_archive(path: Path):
    if sha256_file(path) != DARWIN_ARCHIVE_SHA256:
        raise ValueError(f"VS Code macOS archive SHA-256 does not match the {VERSION} pin")
    with ZipFile(path) as archive:
        names = archive.namelist()
        wanted = [DARWIN_ROOT + name for name in (*DARWIN_FILES, "product.json")]
        if any(names.count(name) != 1 for name in wanted):
            raise ValueError("VS Code macOS archive has missing or duplicate entries")
        data = {name: archive.read(DARWIN_ROOT + name) for name in (*DARWIN_FILES, "product.json")}
    product = json.loads(data.pop("product.json"))
    if product.get("commit") != REVISION or product.get("version") != VERSION:
        raise ValueError("VS Code macOS product version does not match the pinned source")
    license_lines = product.get("serverLicense")
    if not isinstance(license_lines, list) or not license_lines or not all(isinstance(x, str) for x in license_lines):
        raise ValueError("VS Code serverLicense is missing or invalid")
    proposals = product.get("extensionEnabledApiProposals")
    if not isinstance(proposals, dict) or not proposals or not all(
        isinstance(k, str) and k and isinstance(v, list) and all(isinstance(n, str) and n for n in v)
        for k, v in proposals.items()
    ):
        raise ValueError("VS Code proposed API policy is missing or invalid")
    receipt = {
        "scope": "local-vscode-extras",
        "revision": REVISION,
        "version": VERSION,
        "archiveSHA256": DARWIN_ARCHIVE_SHA256,
        "files": {DARWIN_FILES[name]: hashlib.sha256(content).hexdigest() for name, content in data.items()},
        "serverLicenseSHA256": hashlib.sha256("\n".join(license_lines).encode()).hexdigest(),
        "extensionEnabledApiProposalsSHA256": hashlib.sha256(
            json.dumps(proposals, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest(),
    }
    return data, license_lines, receipt, proposals


def stage_workbench(inputs, output: Path, product: dict) -> dict:
    data, license_lines, receipt, proposals = inputs
    for source, destination in DARWIN_FILES.items():
        target = output / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data[source])
    product["serverLicense"] = license_lines
    product["commit"] = REVISION
    product["extensionEnabledApiProposals"] = proposals
    return receipt


def inspect_linux_archive(path: Path):
    if sha256_file(path) != LINUX_ARCHIVE_SHA256:
        raise ValueError(f"VS Code Linux server archive SHA-256 does not match the {VERSION} pin")
    wanted = {LINUX_ROOT + name for name in (*LINUX_FILES, "product.json")}
    signing, files, modes, count, total = {}, {}, {}, 0, 0
    with tarfile.open(path, "r:gz") as archive:
        for member in archive:
            if member.name in wanted:
                if not member.isfile() or member.name in signing or member.size > 2_000_000:
                    raise ValueError("VS Code Linux server archive has invalid or duplicate signing entries")
                with archive.extractfile(member) as stream:
                    signing[member.name] = stream.read()
            if not member.name.startswith(COPILOT_PREFIX):
                continue
            relative = member.name[len(COPILOT_PREFIX):]
            if not relative:
                continue
            if member.isdir() and relative.endswith("/"):
                relative = relative[:-1]
            parts = relative.split("/")
            if relative.startswith("/") or any(p in ("", ".", "..") for p in parts) or "\\" in relative:
                raise ValueError("Invalid built-in extension archive path")
            count += 1
            if count > MAX_ENTRIES or not (member.isfile() or member.isdir()):
                raise ValueError("Unsupported built-in extension archive entry")
            if member.isdir():
                continue
            if relative in files or member.size < 0 or member.size > MAX_FILE_BYTES:
                raise ValueError("Invalid or duplicate built-in extension file")
            total += member.size
            if total > MAX_TOTAL_BYTES:
                raise ValueError("Built-in extension exceeds size limit")
            with archive.extractfile(member) as source:
                content = source.read()
            if len(content) != member.size:
                raise ValueError("Incomplete built-in extension file")
            files[relative] = content
            modes[relative] = member.mode & 0o777
    return _linux_vsda_inputs(signing, wanted), _copilot_inputs(files, modes)


def _linux_vsda_inputs(data: dict, wanted: set[str]):
    if set(data) != wanted:
        raise ValueError("VS Code Linux server archive is missing signing entries")
    product = json.loads(data.pop(LINUX_ROOT + "product.json"))
    if product.get("commit") != REVISION or product.get("version") != VERSION:
        raise ValueError("VS Code Linux server product does not match the pinned source")
    package = json.loads(data[LINUX_ROOT + "node_modules/vsda/package.json"])
    if package.get("name") != "vsda":
        raise ValueError("Unexpected VSDA package metadata")
    _validate_linux_arm64_elf(
        data[LINUX_ROOT + "node_modules/vsda/build/Release/vsda.node"],
        "VSDA addon is not a Linux ARM64 ELF binary",
    )
    receipt = {
        "scope": "local-vscode-extras",
        "revision": REVISION,
        "archiveSHA256": LINUX_ARCHIVE_SHA256,
        "files": {target: hashlib.sha256(data[LINUX_ROOT + name]).hexdigest() for name, target in LINUX_FILES.items()},
    }
    return data, receipt


def _copilot_inputs(files: dict, modes: dict):
    required = [
        "package.json",
        "LICENSE.txt",
        "ThirdPartyNotices.txt",
        "dist/extension.js",
        "node_modules/@github/copilot/shims.txt",
        "node_modules/@github/copilot/sdk/prebuilds/linux-arm64/cli-native.node",
        "node_modules/@github/copilot/sdk/prebuilds/linux-arm64/runtime.node",
        "node_modules/@github/copilot/sdk/ripgrep/bin/linux-arm64/rg",
    ]
    if any(name not in files for name in required):
        raise ValueError("Linux Copilot built-in extension is incomplete")
    manifest = json.loads(files["package.json"])
    if (manifest.get("publisher"), manifest.get("name")) != ("GitHub", "copilot-chat"):
        raise ValueError("Unexpected Linux Copilot built-in extension identity")
    for name in required[-3:]:
        _validate_linux_arm64_elf(files[name], f"Built-in native binary is not Linux ARM64 ELF: {name}")
    receipt = {
        "scope": "local-vscode-extras",
        "revision": REVISION,
        "archiveSHA256": LINUX_ARCHIVE_SHA256,
        "extension": {
            "publisher": manifest["publisher"],
            "name": manifest["name"],
            "version": manifest.get("version"),
            "target": "linux-arm64",
        },
        "files": {
            name: {"sha256": hashlib.sha256(data).hexdigest(), "mode": modes[name]}
            for name, data in sorted(files.items())
        },
    }
    return files, modes, receipt


def stage_exthost(linux_vsda, linux_copilot, output: Path) -> None:
    data, _ = linux_vsda
    for name, target in LINUX_FILES.items():
        destination = output / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data[LINUX_ROOT + name])

    files, modes, _ = linux_copilot
    target_dir = output / "extensions" / TARGET_DIRECTORY
    marker = output / TARGET_MANIFEST
    manifest = output / "executable-modes.json"
    mode_data = json.loads(manifest.read_text())
    entries = mode_data["entries"]
    known = {row["path"] for row in entries}
    for name, mode in sorted(modes.items()):
        if mode & 0o111:
            resource = f"extensions/{TARGET_DIRECTORY}/{name}"
            if resource not in known:
                entries.append({"path": resource, "mode": mode})
                known.add(resource)
    entries.sort(key=lambda row: row["path"])
    marker.write_text(json.dumps({"schemaVersion": 1, "targets": {TARGET_DIRECTORY: "linux-arm64"}}, sort_keys=True) + "\n")
    target_dir.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        destination = target_dir.joinpath(*PurePosixPath(name).parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
        destination.chmod(modes[name])
    manifest.write_text(json.dumps(mode_data, indent=2) + "\n")


def unstage_exthost(output: Path) -> None:
    """Remove any previously staged VS Code extras from Exthost."""
    for rel in ("node_modules/vsda", "extensions/" + TARGET_DIRECTORY):
        path = output / rel
        if path.is_symlink():
            path.unlink()
        elif path.exists():
            shutil.rmtree(path)
    for rel in ("Microsoft-VSCode-Server-LICENSE.txt", TARGET_MANIFEST):
        path = output / rel
        if path.is_symlink() or path.exists():
            path.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=(
        "Download and verify the pinned Microsoft VS Code archives for a separately authorized CodiPad build."
    ))
    parser.parse_args()
    lock_path = ROOT / ".build/build.lock"
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            archives = resolve_archives()
        for archive in archives:
            print(f"Verified {archive.relative_to(ROOT)}")
        print("To include these components, build with: python3 scripts/build.py --with-vscode-extras")
        return 0
    except (SourcesError, OSError, ValueError) as error:
        print(f"vscode_extras.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
