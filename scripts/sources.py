"""Prepare pinned VS Code, iSH, and libarchive sources and shared build helpers."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
REQUIRED_LICENSE_KEYS = ("spdx", "file", "url")

BUILD_INPUT_PATHS = (
    ".gitignore",
    "LICENSE",
    "app/CodiPad",
    "CodiPad.xcodeproj",
    "scripts",
    "build/source-manifest.json",
    "build/runtime-manifest.json",
    "patches",
    "native/CodiPadNode",
    "native/CodiPadProcess",
    "native/CodiPadExtensions",
    "native/CodiPadExecution",
    "native/CodiPadWorkspace/Package.swift",
    "native/CodiPadWorkspace/Sources",
    "workbench/overlay",
    "workbench/notices",
    "workbench/bundle.mjs",
    "workbench/public-bundle.mjs",
    "workbench/workers.mjs",
    "workbench/terminal-state.ts",
    "workbench/terminal-state-build.mjs",
    "workbench/extension-host.mjs",
    "workbench/agent-host.mjs",
    "workbench/product-from-configuration.mjs",
    "workbench/package-extensions.mjs",
    "workbench/window.html",
    "workbench/storage-migration.html",
    "workbench/storage-migration.js",
    "workbench/package.json",
    "workbench/package-lock.json",
    "workbench/product.json",
)


class SourcesError(Exception):
    pass


def tree_digest(source: Path) -> str:
    rows = []
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            rows.append([path.relative_to(source).as_posix(), "symlink", os.readlink(path)])
        elif path.is_file():
            rows.append([path.relative_to(source).as_posix(), path.stat().st_mode & 0o777, sha256_file(path)])
    return hashlib.sha256(json.dumps(rows, separators=(",", ":")).encode()).hexdigest()


def native_toolchain(sdk: str) -> dict:
    sdk_version = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-version"], text=True).strip()
    compiler = subprocess.check_output(["xcrun", "--sdk", sdk, "--find", "clang"], text=True).strip()
    version = subprocess.check_output([compiler, "--version"], text=True).strip()
    return {"sdkVersion": sdk_version, "compiler": compiler, "compilerVersion": version}


def sha256_file(path: Path) -> str:
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_if_changed(path: Path, content: bytes) -> None:
    """Keep generated file mtimes stable when their bytes have not changed."""
    if path.is_file() and path.read_bytes() == content:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def download_verified(url: str, destination: Path, expected_sha256: str, timeout: int = 180) -> Path:
    """Download a file atomically into destination and verify its SHA-256 digest."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.is_file():
        partial = destination.with_name(destination.name + ".partial")
        try:
            print(f"Downloading {url} ...", flush=True)
            request = urllib.request.Request(url, headers={"User-Agent": "CodiPad-build/1"})
            with urllib.request.urlopen(request, timeout=timeout) as response, partial.open("wb") as out:
                shutil.copyfileobj(response, out)
            actual = sha256_file(partial)
            if actual != expected_sha256:
                raise SourcesError(f"Checksum mismatch for {destination.name}: got {actual}, expected {expected_sha256}")
            partial.replace(destination)
        finally:
            partial.unlink(missing_ok=True)
    actual = sha256_file(destination)
    if actual != expected_sha256:
        raise SourcesError(f"Cached checksum mismatch for {destination}: got {actual}, expected {expected_sha256}")
    return destination


def run_git(
    repo: Path, *args: str, check: bool = True, env: dict | None = None
) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    if check and proc.returncode != 0:
        raise SourcesError(
            f"git {' '.join(args)} failed in {repo}: {proc.stderr.strip() or proc.stdout.strip()}"
        )
    return proc


def load_manifest(manifest_path: Path) -> dict:
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SourcesError(f"manifest not found: {manifest_path}")
    except json.JSONDecodeError as exc:
        raise SourcesError(f"manifest is not valid JSON: {exc}")
    if not isinstance(data, dict):
        raise SourcesError("manifest root must be an object")
    return data


def safe_relative(root: Path, value: object, field: str) -> Path:
    """Resolve a manifest path, rejecting absolute paths and escapes from root."""
    if not isinstance(value, str) or not value.strip():
        raise SourcesError(f"{field} must be a non-empty relative path")
    rel = Path(value)
    if rel.is_absolute() or ".." in rel.parts:
        raise SourcesError(f"{field} must be relative and stay inside the project: {value}")
    resolved = (root / rel).resolve()
    if resolved != root and root not in resolved.parents:
        raise SourcesError(f"{field} escapes the project directory: {value}")
    return resolved


def parse_series(series_path: Path) -> list[Path]:
    """Return patch paths in file order. Blank lines and # comments are ignored."""
    patches: list[Path] = []
    seen: set[Path] = set()
    for lineno, raw in enumerate(series_path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("/") or Path(line).is_absolute() or ".." in Path(line).parts:
            raise SourcesError(f"{series_path}:{lineno}: patch path must stay inside the series directory: {line}")
        patch = (series_path.parent / line).resolve()
        if series_path.parent.resolve() not in patch.parents:
            raise SourcesError(f"{series_path}:{lineno}: patch path escapes the series directory: {line}")
        if not patch.is_file():
            raise SourcesError(f"{series_path}:{lineno}: patch file not found: {line}")
        if patch in seen:
            raise SourcesError(f"{series_path}:{lineno}: duplicate patch: {line}")
        seen.add(patch)
        patches.append(patch)
    return patches


def validate(manifest_path: Path) -> tuple[dict, dict]:
    """Validate build/source-manifest.json and its VS Code patch series."""
    manifest = load_manifest(manifest_path)
    root = manifest_path.resolve().parent.parent

    if manifest.get("schemaVersion") != 1:
        raise SourcesError("schemaVersion must be 1")

    upstream = manifest.get("upstream")
    if not isinstance(upstream, dict):
        raise SourcesError("upstream must be an object")

    for key in ("repository", "tag"):
        if not isinstance(upstream.get(key), str) or not upstream[key].strip():
            raise SourcesError(f"upstream.{key} must be a non-empty string")
    revision = upstream.get("revision")
    if not isinstance(revision, str) or not REVISION_RE.fullmatch(revision):
        raise SourcesError("upstream.revision must be a full 40-character lowercase commit hash")

    license_info = upstream.get("license")
    if not isinstance(license_info, dict):
        raise SourcesError("upstream.license must be an object")
    for key in REQUIRED_LICENSE_KEYS:
        if not isinstance(license_info.get(key), str) or not license_info[key].strip():
            raise SourcesError(f"upstream.license.{key} must be a non-empty string")

    vendor_path = safe_relative(root, upstream.get("vendorPath"), "upstream.vendorPath")
    vendor_rel = Path(upstream["vendorPath"])
    series_path = safe_relative(root, upstream.get("patchSeries"), "upstream.patchSeries")
    if not series_path.is_file():
        raise SourcesError(f"patch series file not found: {series_path}")
    patches = parse_series(series_path)

    return manifest, {
        "root": root,
        "upstream": upstream,
        "vendor": vendor_path,
        "vendor_rel": vendor_rel,
        "patches": patches,
    }


def check_no_symlink(root: Path, destination: Path) -> None:
    """Reject a destination reached through a symlink so prepare cannot escape the project."""
    current = root
    for part in destination.relative_to(root).parts:
        current = current / part
        if current.is_symlink():
            raise SourcesError(f"destination path must not contain symlinks: {current}")


def exact_patched_tree(repo: Path, revision: str, patches: list[Path]) -> bool:
    """True when the worktree matches revision + the ordered patch series with no extra files."""
    fd, index_path = tempfile.mkstemp(prefix="codipad-index-")
    os.close(fd)
    env = {**os.environ, "GIT_INDEX_FILE": index_path}
    try:
        run_git(repo, "read-tree", revision, env=env)
        for patch in patches:
            proc = run_git(repo, "apply", "--cached", str(patch), check=False, env=env)
            if proc.returncode != 0:
                raise SourcesError(
                    f"patch does not apply to the pinned revision: {patch.name}\n{proc.stderr.strip()}"
                )
        diff = run_git(repo, "diff", "--exit-code", check=False, env=env)
        others = run_git(repo, "ls-files", "--others", "--exclude-standard", env=env).stdout
        return diff.returncode == 0 and not others.strip()
    finally:
        os.unlink(index_path)


def assert_clean(repo: Path) -> None:
    status = run_git(repo, "status", "--porcelain").stdout.strip()
    if status:
        raise SourcesError("checkout has uncommitted changes; refusing to reset or clean it:\n" + status)


def assert_revision(repo: Path, upstream: dict) -> str:
    revision = upstream["revision"]
    tag = upstream["tag"]
    peeled_ref = f"refs/tags/{tag}^{{commit}}"
    if run_git(repo, "rev-parse", "--verify", "--quiet", peeled_ref, check=False).returncode == 0:
        tagged = run_git(repo, "rev-parse", peeled_ref).stdout.strip()
        if tagged != revision:
            raise SourcesError(f"tag {tag} resolves to {tagged}, but the manifest pins {revision}")
    if run_git(repo, "cat-file", "-e", f"{revision}^{{commit}}", check=False).returncode != 0:
        raise SourcesError(f"pinned revision {revision} is not available in the checkout")
    return revision


def assert_remote(repo: Path, repository: str) -> None:
    proc = run_git(repo, "remote", "get-url", "origin", check=False)
    if proc.returncode != 0:
        raise SourcesError("checkout has no origin remote")
    actual = proc.stdout.strip()
    if actual != repository:
        raise SourcesError(f"checkout origin is {actual}, but the manifest pins {repository}")


def fetch_revision(repo: Path, upstream: dict) -> None:
    tag = upstream["tag"]
    run_git(repo, "fetch", "--depth", "1", "--force", "origin", f"+refs/tags/{tag}:refs/tags/{tag}")
    assert_revision(repo, upstream)


def apply_series(repo: Path, patches: list[Path]) -> None:
    for patch in patches:
        forward = run_git(repo, "apply", "--check", str(patch), check=False)
        if forward.returncode == 0:
            run_git(repo, "apply", str(patch))
            continue
        reverse = run_git(repo, "apply", "--reverse", "--check", str(patch), check=False)
        if reverse.returncode == 0:
            continue
        raise SourcesError(f"patch does not apply cleanly: {patch.name}\n{forward.stderr.strip()}")


def prepare_vscode(manifest_path: Path = ROOT / "build/source-manifest.json") -> None:
    _, resolved = validate(manifest_path)
    upstream = resolved["upstream"]
    root = resolved["root"]
    destination = resolved["vendor"]
    patches = resolved["patches"]

    check_no_symlink(root, root / resolved["vendor_rel"])
    if destination.exists() and not destination.is_dir():
        raise SourcesError(f"destination exists and is not a directory: {destination}")

    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.mkdir()
        run_git(destination.parent, "init", "--quiet", str(destination))
        run_git(destination, "remote", "add", "origin", upstream["repository"])
        fetch_revision(destination, upstream)
        run_git(destination, "checkout", "--quiet", "--detach", upstream["revision"])
    else:
        git_meta = destination / ".git"
        if git_meta.is_symlink() or not git_meta.is_dir():
            raise SourcesError(f"existing destination has no real .git directory: {destination}")
        assert_remote(destination, upstream["repository"])
        if run_git(destination, "cat-file", "-e", f"{upstream['revision']}^{{commit}}", check=False).returncode != 0:
            fetch_revision(destination, upstream)
        assert_revision(destination, upstream)
        head = run_git(destination, "rev-parse", "HEAD").stdout.strip()
        if head != upstream["revision"]:
            raise SourcesError(f"checkout HEAD is {head}, but manifest pins {upstream['revision']}; refusing to move it")

    if exact_patched_tree(destination, upstream["revision"], patches):
        print(f"VS Code ready: {destination.relative_to(root)} ({upstream['tag']})", flush=True)
        return
    assert_clean(destination)
    apply_series(destination, patches)
    print(f"Prepared VS Code: {destination.relative_to(root)} ({upstream['tag']}, {len(patches)} patches)", flush=True)


# --- iSH + libarchive runtime sources ---

def runtime_source_paths(locked: dict, origin: Path | None = None) -> tuple[Path, Path, Path]:
    repo = Path(origin).resolve() if origin else safe_relative(ROOT, locked["sourceRepository"], "ish.sourceRepository")
    return repo, repo / "deps/libarchive", repo / "deps/libarchive/libarchive"


def libarchive_repository(origin: Path, locked: dict) -> str:
    entry = run_git(origin, "ls-tree", locked["revision"], "deps/libarchive").stdout.strip().split()
    if entry[:2] != ["160000", "commit"] or entry[2] != locked["libarchiveRevision"]:
        raise SourcesError("libarchive revision differs from the pinned iSH gitlink")
    return run_git(
        origin, "config", "--blob", f"{locked['revision']}:.gitmodules", "--get", "submodule.deps/libarchive.url"
    ).stdout.strip()


def libarchive_patch(locked: dict) -> Path:
    patch = ROOT / "patches/ish" / locked["libarchivePatch"]
    if not patch.is_file():
        raise SourcesError(f"libarchive patch not found: {patch}")
    return patch


def _checkout_commit(repo: Path, repository: str, revision: str) -> None:
    if not isinstance(revision, str) or not REVISION_RE.fullmatch(revision):
        raise SourcesError("Runtime source revisions must be full lowercase commit hashes")
    if not isinstance(repository, str) or not repository:
        raise SourcesError("Runtime source repository must be nonempty")
    if not (repo / ".git").exists():
        repo.mkdir(parents=True, exist_ok=True)
        if any(repo.iterdir()):
            raise SourcesError(f"Refusing to initialize a nonempty source directory: {repo}")
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        run_git(repo, "remote", "add", "origin", repository)
    assert_remote(repo, repository)
    head = run_git(repo, "rev-parse", "--verify", "HEAD", check=False)
    if head.returncode != 0:
        if run_git(repo, "ls-files").stdout.strip() or run_git(repo, "ls-files", "--others", "--exclude-standard").stdout.strip():
            raise SourcesError(f"Refusing to overwrite an unfinished source checkout with local files: {repo}")
        if run_git(repo, "cat-file", "-e", f"{revision}^{{commit}}", check=False).returncode != 0:
            run_git(repo, "fetch", "--depth", "1", "origin", revision)
        run_git(repo, "checkout", "--detach", "-q", revision)
    if run_git(repo, "rev-parse", "HEAD").stdout.strip() != revision:
        raise SourcesError(f"Existing source directory differs from its pinned revision: {repo}")


def verify_runtime_sources(locked: dict, origin: Path | None = None) -> tuple[Path, Path, Path]:
    origin, archive, headers = runtime_source_paths(locked, origin)
    if run_git(origin, "rev-parse", "HEAD").stdout.strip() != locked["revision"]:
        raise SourcesError("iSH source checkout differs from its pinned revision")
    assert_remote(origin, locked["repository"])
    if (run_git(origin, "diff", "--ignore-submodules=all", "HEAD", "--").stdout.strip()
            or run_git(origin, "ls-files", "--others", "--exclude-standard").stdout.strip()):
        raise SourcesError("iSH source checkout has local edits")
    expected_url = libarchive_repository(origin, locked)
    if run_git(archive, "rev-parse", "HEAD").stdout.strip() != locked["libarchiveRevision"]:
        raise SourcesError("libarchive source checkout differs from its pinned revision")
    assert_remote(archive, expected_url)
    patch = libarchive_patch(locked)
    if not exact_patched_tree(archive, locked["libarchiveRevision"], [patch]):
        raise SourcesError("libarchive must match its pin plus the locale patch")
    if not (headers / "archive.h").is_file():
        raise SourcesError("Pinned libarchive headers are missing")
    return origin, archive, headers


def prepare_runtime_sources() -> tuple[Path, Path, Path]:
    locked = json.loads((ROOT / "build/runtime-manifest.json").read_text())["ish"]
    origin, archive, _ = runtime_source_paths(locked)
    _checkout_commit(origin, locked["repository"], locked["revision"])
    repository = libarchive_repository(origin, locked)
    _checkout_commit(archive, repository, locked["libarchiveRevision"])
    patch = libarchive_patch(locked)
    if not exact_patched_tree(archive, locked["libarchiveRevision"], [patch]):
        assert_clean(archive)
        run_git(archive, "apply", "--check", str(patch))
        run_git(archive, "apply", str(patch))
    origin, archive, headers = verify_runtime_sources(locked)
    print(f"iSH & libarchive ready: {origin.relative_to(ROOT)}", flush=True)
    return origin, archive, headers


def prepare_all() -> None:
    prepare_vscode()
    prepare_runtime_sources()


def source_state(root: Path = ROOT) -> dict:
    root = root.resolve()
    files = []
    for name in BUILD_INPUT_PATHS:
        path = root / name
        if path.is_symlink():
            raise ValueError(f"build input must not be a symlink: {name}")
        if not path.exists():
            raise ValueError(f"missing build input: {name}")
        candidates = sorted(path.rglob("*")) if path.is_dir() else [path]
        for item in candidates:
            relative = item.relative_to(root)
            if "__pycache__" in relative.parts or "xcuserdata" in relative.parts:
                continue
            if item.suffix in (".pyc", ".xcuserstate"):
                continue
            if item.is_symlink():
                raise ValueError(f"build input must not be a symlink: {relative}")
            if item.is_file():
                files.append({"path": relative.as_posix(), "sha256": sha256_file(item)})
    files.sort(key=lambda row: row["path"])
    encoded = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    try:
        revision = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], stderr=subprocess.DEVNULL, text=True
        ).strip()
        dirty = bool(subprocess.check_output(
            ["git", "-C", str(root), "status", "--porcelain", "--untracked-files=all"],
            stderr=subprocess.DEVNULL,
        ).strip())
    except (OSError, subprocess.CalledProcessError):
        revision, dirty = None, None
    return {
        "revision": revision,
        "dirty": dirty,
        "input_sha256": hashlib.sha256(encoded).hexdigest(),
        "files": files,
    }


if __name__ == "__main__":
    prepare_all()
