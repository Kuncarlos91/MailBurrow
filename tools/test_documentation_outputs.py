"""Protect relocated documentation outputs and unchanged notice/config paths."""
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import dependency_notices
import native_dependency_inventory


class DocumentationOutputTests(unittest.TestCase):
    def test_notice_generator_uses_new_inventory_and_keeps_root_notice_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".dart_tool").mkdir()
            (root / "docs/development").mkdir(parents=True)
            package = root / "fixture-package"
            package.mkdir()
            license_text = "Permission is hereby granted. Synthetic fixture license.\n"
            (package / "LICENSE").write_text(license_text, encoding="utf-8")
            (root / ".dart_tool/package_config.json").write_text(json.dumps({
                "packages": [{"name": "fixture", "rootUri": "../fixture-package"}]}), encoding="utf-8")
            (root / "pubspec.lock").write_text('packages:\n  fixture:\n    dependency: direct main\n    version: "1.0.0"\nsdks:\n', encoding="utf-8")
            config = root / "keystore.properties"
            config.write_text("synthetic configuration sentinel", encoding="utf-8")
            with patch.object(dependency_notices, "ROOT", root), contextlib.redirect_stdout(io.StringIO()):
                dependency_notices.main()
            protected = [root / "docs/development/dependencies.md", root / "THIRD_PARTY_NOTICES.md", config]
            before = [(path.read_bytes(), path.stat().st_mtime_ns) for path in protected]
            with patch.object(dependency_notices, "ROOT", root), contextlib.redirect_stdout(io.StringIO()):
                dependency_notices.main(["--check"])
            self.assertEqual(before, [(path.read_bytes(), path.stat().st_mtime_ns) for path in protected])
            (package / "LICENSE").write_text("Different synthetic notice", encoding="utf-8")
            with patch.object(dependency_notices, "ROOT", root), self.assertRaises(SystemExit):
                dependency_notices.main(["--check"])
            self.assertEqual(before, [(path.read_bytes(), path.stat().st_mtime_ns) for path in protected])
            self.assertTrue((root / "docs/development/dependencies.md").is_file())
            self.assertFalse((root / "DEPENDENCIES.md").exists())
            self.assertIn(license_text, (root / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8"))
            self.assertEqual(config.read_text(encoding="utf-8"), "synthetic configuration sentinel")

    def test_native_generator_uses_relocated_inventory_without_root_duplicate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docs/development").mkdir(parents=True)
            report = root / "fixture.txt"
            report.write_text("+--- synthetic:library:1.0.0\nBUILD SUCCESSFUL\n", encoding="utf-8")
            with patch.object(native_dependency_inventory, "__file__", str(root / "tools/native_dependency_inventory.py")), patch.object(native_dependency_inventory.sys, "argv", ["inventory", str(report)]), patch.object(Path, "home", return_value=root / "fixture-home"), contextlib.redirect_stdout(io.StringIO()):
                native_dependency_inventory.main()
            inventory = root / "docs/development/native-dependencies.md"
            self.assertTrue(inventory.is_file())
            self.assertFalse((root / "NATIVE_DEPENDENCIES.md").exists())
            self.assertIn("synthetic:library", inventory.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
