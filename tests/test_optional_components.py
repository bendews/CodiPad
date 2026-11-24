import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import vscode_extras
import workbench


class OptionalComponentsTests(unittest.TestCase):
    def test_microsoft_download_hosts_require_the_marketplace_preset(self):
        self.assertEqual(workbench.gallery_settings(None, False), {})
        preset = workbench.gallery_settings(None, True)
        self.assertIs(preset["codipadMicrosoftMarketplace"], True)
        service = preset["extensionsGallery"]["serviceUrl"]
        self.assertEqual(service, "https://marketplace.visualstudio.com/_apis/public/gallery")
        custom = {"serviceUrl": service}
        self.assertEqual(workbench.gallery_settings(custom, False), {"extensionsGallery": custom})
        with self.assertRaises(ValueError):
            workbench.gallery_settings(custom, True)

    def test_prefetch_verifies_both_archives_and_reuses_the_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "fixture"
            archive.write_bytes(b"archive fixture")
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            with patch.multiple(vscode_extras, CACHE_DIR=root / "cache",
                                DARWIN_ARCHIVE_URL=archive.as_uri(), LINUX_ARCHIVE_URL=archive.as_uri(),
                                DARWIN_ARCHIVE_SHA256=digest, LINUX_ARCHIVE_SHA256=digest):
                darwin, linux = vscode_extras.resolve_archives()
                self.assertNotEqual(darwin, linux)
                archive.unlink()
                self.assertEqual(vscode_extras.resolve_archives(), (darwin, linux))
                linux.write_bytes(b"incomplete")
                with self.assertRaisesRegex(vscode_extras.SourcesError, "checksum mismatch"):
                    vscode_extras.resolve_archives()

    def test_switching_build_modes_restores_default_dependency_set(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deps = {"@vscode/copilot-api": "1", "@github/copilot-sdk": "1", "node-pty": "1"}
            package = {"dependencies": deps}
            lock = {"packages": {"": package, **{"node_modules/" + name: {} for name in deps},
                                 "node_modules/@github/copilot-sdk-linux-arm64": {}}}
            (root / "package.json").write_text(json.dumps(package))
            (root / "package-lock.json").write_text(json.dumps(lock))
            target = root / "install"
            (target / "node_modules").mkdir(parents=True)
            with patch.object(workbench, "CACHE", root), patch.object(workbench, "_run") as npm:
                for enabled in (False, True, True, False):
                    workbench.install_npm_deps(Path("/node"), target, root, upstream=True, include_agent=enabled)
                    installed = json.loads((target / "package-lock.json").read_text())["packages"]
                    self.assertEqual("node_modules/@vscode/copilot-api" in installed, enabled)
                    self.assertEqual("node_modules/@github/copilot-sdk-linux-arm64" in installed, enabled)
                    self.assertIn("node_modules/node-pty", installed)
                self.assertEqual(npm.call_count, 3)
            self.assertEqual(json.loads((root / "package-lock.json").read_text()), lock)


if __name__ == "__main__":
    unittest.main()
