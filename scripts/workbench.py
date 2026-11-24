"""Bundle the iPad VS Code workbench from pinned upstream source and overlay."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from sources import (
    ROOT,
    assert_remote,
    assert_revision,
    download_verified,
    exact_patched_tree,
    run_git,
    sha256_file,
    validate,
)
import vscode_extras

CACHE = ROOT / ".build/workbench"
NODE_VERSION = "24.18.0"
NODE_SHA256 = "e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1"

BROWSER_RUNTIME_FILES = {
    "vscode-textmate": ("release/main.js", "LICENSE.md"),
    "vscode-oniguruma": ("release/main.js", "release/onig.wasm", "LICENSE.txt", "NOTICES.txt"),
    "@vscode/vscode-languagedetection": (
        "dist/lib/index.js.LICENSE.txt", "dist/lib/979.js.LICENSE.txt",
        "model/model.json", "model/group1-shard1of1.bin", "LICENSE",
    ),
    "@vscode/iconv-lite-umd": ("lib/iconv-lite-umd.js", "lib/iconv-lite-umd.js.LICENSE.txt", "LICENSE"),
    "jschardet": ("dist/jschardet.min.js", "LICENSE"),
    "katex": ("dist/katex.min.js", "dist/katex.min.css", "LICENSE"),
    "@xterm/xterm": ("lib/xterm.js", "LICENSE"),
    "@xterm/addon-clipboard": ("lib/addon-clipboard.js", "LICENSE"),
    "@xterm/addon-image": ("lib/addon-image.js", "LICENSE"),
    "@xterm/addon-ligatures": ("lib/addon-ligatures.js", "LICENSE"),
    "@xterm/addon-progress": ("lib/addon-progress.js", "LICENSE"),
    "@xterm/addon-search": ("lib/addon-search.js", "LICENSE"),
    "@xterm/addon-serialize": ("lib/addon-serialize.js",),
    "@xterm/addon-unicode11": ("lib/addon-unicode11.js", "LICENSE"),
    "@xterm/addon-webgl": ("lib/addon-webgl.js", "LICENSE"),
    "@xterm/headless": (),  # Its code is bundled into terminal-state.js.
}


def _run(args, **kwargs):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True, **kwargs)


def node_tool() -> Path:
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        raise ValueError("CodiPad builds require an Apple silicon Mac (darwin/arm64)")
    tools = CACHE / "tools"
    name = f"node-v{NODE_VERSION}-darwin-arm64"
    archive = download_verified(
        f"https://nodejs.org/dist/v{NODE_VERSION}/{name}.tar.gz",
        tools / f"{name}.tar.gz",
        NODE_SHA256,
    )
    node = tools / name / "bin/node"
    if not node.exists():
        with tarfile.open(archive) as source:
            source.extractall(tools, filter="data")
    if subprocess.check_output([node, "--version"], text=True).strip() != f"v{NODE_VERSION}":
        raise ValueError("Host Node runtime version mismatch")
    return node


def install_npm_deps(node: Path, target: Path, package_source: Path, upstream: bool = False,
                     include_agent: bool = False) -> None:
    target.mkdir(parents=True, exist_ok=True)
    if upstream:
        package = json.loads((package_source / "package.json").read_bytes())
        lock = json.loads((package_source / "package-lock.json").read_bytes())
        if not include_agent:
            agent_packages = ("@vscode/copilot-api", "@github/copilot-sdk")
            for name in agent_packages:
                del package["dependencies"][name]
                del lock["packages"][""]["dependencies"][name]
            # The Copilot SDK pins platform-specific packages and nested dependencies.
            for key in list(lock["packages"]):
                if key == "node_modules/@vscode/copilot-api" or key.startswith("node_modules/@github/copilot-sdk"):
                    del lock["packages"][key]
        for name, data in (("package.json", package), ("package-lock.json", lock)):
            (target / name).write_text(json.dumps(data, indent=2) + "\n")
    key = sha256_file(target / "package-lock.json")
    marker = target / ".codipad-dependencies"
    if marker.exists() and marker.read_text().strip() == key and (target / "node_modules").is_dir():
        return
    npm = node.parent.parent / "lib/node_modules/npm/bin/npm-cli.js"
    args = [node, npm, "ci", "--ignore-scripts", "--no-audit", "--no-fund", "--prefix", target]
    if upstream:
        args += ["--omit=dev", "--legacy-peer-deps"]
    log_name = "npm-upstream.log" if upstream else "npm-tools.log"
    print(f"Installing {'VS Code' if upstream else 'workbench'} npm dependencies...", flush=True)
    with (CACHE / log_name).open("wb") as log:
        # npm ci replaces node_modules, even if installation later fails.
        marker.unlink(missing_ok=True)
        _run(args, stdout=log, stderr=subprocess.STDOUT)
    marker.write_text(key + "\n")


def artifact_files(directory: Path, include_host_receipt: bool = False) -> list[dict]:
    if directory.is_symlink() or any(p.is_symlink() for p in directory.rglob("*")):
        raise ValueError("Generated artifacts must not contain symlinks")
    return [
        {"path": p.relative_to(directory).as_posix(), "sha256": sha256_file(p)}
        for p in sorted(directory.rglob("*"))
        if p.is_file() and not (p.parent == directory and (p.name == "WorkbenchReceipt.json" or (p.name == "ExthostReceipt.json" and not include_host_receipt)))
    ]


def stage_browser_runtime_resources(dependencies: Path, output: Path) -> None:
    packages = json.loads((dependencies / "package-lock.json").read_bytes())["packages"]
    for name, relatives in BROWSER_RUNTIME_FILES.items():
        package_root = dependencies / "node_modules" / name
        manifest = json.loads((package_root / "package.json").read_bytes())
        pinned_version = packages.get(f"node_modules/{name}", {}).get("version")
        if not pinned_version or manifest.get("name") != name or manifest.get("version") != pinned_version:
            raise ValueError(f"Browser runtime package does not match lockfile: {name}")
        if name == "@vscode/vscode-languagedetection":
            model = json.loads((package_root / "model/model.json").read_bytes())
            shards = [path for group in model["weightsManifest"] for path in group["paths"]]
            if shards != ["group1-shard1of1.bin"]:
                raise ValueError("Language detection model has unexpected weights")
        if name == "katex":
            css = (package_root / "dist/katex.min.css").read_text()
            fonts = set(re.findall(r"url\(([^)]+)\)", css))
            if not fonts or any(not re.fullmatch(r"fonts/[\w.-]+", font) for font in fonts):
                raise ValueError("Invalid or missing KaTeX font references")
            relatives += tuple(f"dist/{font}" for font in sorted(fonts))
        for relative in ("package.json", "README.md", *relatives):
            source = package_root / relative
            if source.is_symlink() or not source.is_file():
                raise ValueError(f"Missing browser runtime file: {source}")
            destination = output / "node_modules" / name / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)


def stage_webview_resources(source: Path, output: Path) -> None:
    html = (source / "index.html").read_text()
    script = re.search(r'<script async type="module">([\s\S]*?)</script>', html)
    if not script:
        raise ValueError("Upstream webview shell has no module script")
    digest = base64.b64encode(hashlib.sha256(script.group(1).encode()).digest()).decode()
    if f"script-src 'sha256-{digest}'" not in html:
        raise ValueError("Upstream webview shell CSP does not match its script")
    output.mkdir(parents=True, exist_ok=True)
    for name in ("index.html", "service-worker.js", "fake.html"):
        shutil.copyfile(source / name, output / name)


def validate_overlay() -> Path:
    overlay = ROOT / "workbench/overlay"
    if overlay.is_symlink() or any(p.is_symlink() for p in overlay.rglob("*")):
        raise ValueError("workbench/overlay must not contain symlinks")
    entrypoint = overlay / "src/vs/workbench/workbench.ipad.main.ts"
    if not entrypoint.is_file():
        raise ValueError(f"Missing workbench entrypoint: {entrypoint}")
    return overlay


def load_extension_gallery(path: Path) -> dict:
    gallery = json.loads(path.read_text())
    fields = {"serviceUrl", "itemUrl", "publisherUrl"}
    if not isinstance(gallery, dict) or "serviceUrl" not in gallery or not gallery.keys() <= fields:
        raise ValueError("Gallery configuration requires serviceUrl and accepts itemUrl and publisherUrl")
    for key, value in gallery.items():
        if not isinstance(value, str) or any(c.isspace() for c in value) or "\\" in value:
            raise ValueError(f"Invalid gallery URL for {key}")
        url = urlsplit(value)
        if (url.scheme != "https" or not url.hostname or url.username is not None or url.password is not None
                or url.query or url.fragment or url.port == 0):
            raise ValueError(f"{key} must be an HTTPS URL without credentials, query, or fragment")
    return gallery


def gallery_settings(custom_gallery: dict | None, microsoft_marketplace: bool) -> dict:
    if microsoft_marketplace:
        if custom_gallery is not None:
            raise ValueError("Choose either Microsoft Marketplace or a custom extension gallery")
        return {
            "codipadMicrosoftMarketplace": True,
            "extensionsGallery": {
                "serviceUrl": "https://marketplace.visualstudio.com/_apis/public/gallery",
                "itemUrl": "https://marketplace.visualstudio.com/items",
                "publisherUrl": "https://marketplace.visualstudio.com/publishers",
            },
        }
    return {"extensionsGallery": custom_gallery} if custom_gallery is not None else {}


def build(reuse_existing: bool = True, vscode_darwin_archive: Path | None = None, minify: bool = False,
          extension_gallery: dict | None = None, microsoft_marketplace: bool = False) -> dict:
    gallery = gallery_settings(extension_gallery, microsoft_marketplace)
    manifest, resolved = validate(ROOT / "build/source-manifest.json")
    vendor = resolved["vendor"]
    extras = vscode_extras.inspect_darwin_archive(vscode_darwin_archive) if vscode_darwin_archive else None

    assert_remote(vendor, manifest["upstream"]["repository"])
    revision = assert_revision(vendor, manifest["upstream"])
    if run_git(vendor, "rev-parse", "HEAD").stdout.strip() != revision:
        raise ValueError("VS Code checkout HEAD differs from source-manifest.json")
    if not exact_patched_tree(vendor, revision, resolved["patches"]):
        raise ValueError("VS Code checkout differs from pinned revision + patch series")
    overlay = validate_overlay()

    node = node_tool()
    dependencies = CACHE / "upstream-deps"
    install_npm_deps(node, dependencies, vendor, upstream=True, include_agent=bool(extras))
    install_npm_deps(node, ROOT / "workbench", ROOT / "workbench")

    inputs = [p for p in sorted(overlay.rglob("*")) if p.is_file()]
    inputs += [
        ROOT / "workbench" / name
        for name in (
            "bundle.mjs", "public-bundle.mjs", "workers.mjs", "terminal-state.ts", "terminal-state-build.mjs",
            "window.html", "storage-migration.html", "storage-migration.js",
            "package.json", "package-lock.json", "product.json",
        )
    ]
    inputs += [Path(__file__).resolve(), ROOT / "scripts/vscode_extras.py"]
    input_snapshot = [{"path": p.relative_to(ROOT).as_posix(), "sha256": sha256_file(p)} for p in inputs]

    identity = {
        "schemaVersion": 1,
        "upstreamRevision": revision,
        "upstreamLockSha256": sha256_file(vendor / "package-lock.json"),
        "node": NODE_VERSION,
        "patches": [{"path": p.relative_to(ROOT).as_posix(), "sha256": sha256_file(p)} for p in resolved["patches"]],
        "inputs": input_snapshot,
        "vscodeExtras": extras[2] if extras else None,
        "extensionGallery": gallery.get("extensionsGallery"),
        "microsoftMarketplace": microsoft_marketplace,
        "minify": minify,
    }

    destination = ROOT / "app/generated/Workbench"
    receipt_path = destination / "WorkbenchReceipt.json"
    if reuse_existing and destination.is_dir() and not destination.is_symlink() and receipt_path.is_file():
        try:
            existing = json.loads(receipt_path.read_text())
            if all(existing.get(k) == v for k, v in identity.items()) and artifact_files(destination) == existing.get("files"):
                print(f"Workbench ready: {destination}", flush=True)
                return existing
        except (OSError, ValueError, json.JSONDecodeError):
            pass

    print("Bundling Workbench...", flush=True)
    attempt = CACHE / f"attempt-{uuid.uuid4().hex[:12]}"
    stage, output = attempt / "source", attempt / "Workbench"
    stage.mkdir(parents=True)
    output.mkdir(parents=True)

    try:
        shutil.copytree(vendor / "src", stage / "src")
        shutil.copytree(overlay / "src", stage / "src", dirs_exist_ok=True)
        bundle_cmd = [node, ROOT / "workbench/bundle.mjs", stage, output, dependencies]
        if minify:
            bundle_cmd.append("--minify")
        _run(bundle_cmd)

        stage_browser_runtime_resources(dependencies, output)

        (output / "out").mkdir(exist_ok=True)
        product = json.loads((vendor / "product.json").read_text())
        product.update(json.loads((ROOT / "workbench/product.json").read_text()))
        product.pop("extensionsGallery", None)
        product.pop("codipadMicrosoftMarketplace", None)
        product.update(gallery)
        if extras:
            vscode_extras.stage_workbench(extras, output, product)
        product["commit"] = revision

        package = json.loads((vendor / "package.json").read_text())
        bootstrap = (
            'globalThis._VSCODE_FILE_ROOT = new URL("./out/", location.href).href;\n'
            "globalThis.__codipadExtensionWorkerHostReady = true;\n"
            'globalThis._CODIPAD_WORKBENCH_SCRIPT_URL = new URL("workbench.js", location.href).href;\n'
            f"globalThis.__codipadMicrosoftSigning = {str(bool(extras)).lower()};\n"
            f"globalThis._VSCODE_PRODUCT_JSON = {json.dumps(product)};\n"
            f"globalThis._VSCODE_PACKAGE_JSON = {json.dumps(package)};\n"
        )
        (output / "configuration.js").write_text(bootstrap)

        template = (ROOT / "workbench/window.html").read_text()
        for name, title, stylesheet, entry in (
            ("index.html", "CodiPad", "workbench.css", '<script src="workbench.js"></script>'),
            ("agents.html", "CodiPad Agents", "agents.css", '<script>globalThis._CODIPAD_WORKBENCH_SCRIPT_URL = new URL("agents.js", location.href).href;</script>\n<script src="agents.js"></script>'),
        ):
            page = template.replace("{{TITLE}}", title).replace("{{STYLESHEET}}", stylesheet).replace("{{ENTRY_SCRIPT}}", entry)
            (output / name).write_text(page)
        for name in ("storage-migration.html", "storage-migration.js"):
            shutil.copy2(ROOT / "workbench" / name, output / name)
        stage_webview_resources(vendor / "src/vs/workbench/contrib/webview/browser/pre", output / "webview-pre")
        for name in ("LICENSE.txt", "ThirdPartyNotices.txt"):
            if (vendor / name).exists():
                shutil.copy2(vendor / name, output / name)

        record = {**identity, "files": artifact_files(output)}
        (output / "WorkbenchReceipt.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")

        destination.parent.mkdir(parents=True, exist_ok=True)
        previous = destination.with_name(f".Workbench-prev-{uuid.uuid4().hex[:8]}")
        had_previous = destination.exists()
        if had_previous:
            os.replace(destination, previous)
        try:
            os.replace(output, destination)
        except OSError:
            if had_previous:
                os.replace(previous, destination)
            raise
        if had_previous:
            shutil.rmtree(previous)
    finally:
        shutil.rmtree(attempt, ignore_errors=True)

    print(f"Built Workbench: {destination}", flush=True)
    return record
