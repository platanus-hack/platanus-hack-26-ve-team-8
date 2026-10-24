import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("package_macos", Path(__file__).parents[1] / "package_macos.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "bin").mkdir()
        (self.root / "bin/python3.12").touch()
        (self.root / "bin/python3").symlink_to("python3.12")

    def test_accepts_internal_python_link(self):
        packager.validate_runtime(self.root)

    def test_rejects_virtual_environment(self):
        (self.root / "pyvenv.cfg").write_text("home = /opt/homebrew/bin")
        with self.assertRaisesRegex(ValueError, "entorno virtual"):
            packager.validate_runtime(self.root)

    def test_rejects_external_dependency(self):
        (self.root / "external").symlink_to(self.root.parent)
        with self.assertRaisesRegex(ValueError, "externo"):
            packager.validate_runtime(self.root)

    def test_package_contains_runtime_icon_and_manifest(self):
        from unittest.mock import patch
        import plistlib

        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            binary = repo / "build"
            binary.mkdir()
            (binary / "Guardian").write_bytes(b"app")
            icon = repo / "apps/macos/Icon/AppIcon.icns"
            icon.parent.mkdir(parents=True)
            icon.write_bytes(b"icon")
            with patch.object(packager.subprocess, "run") as run, patch.object(
                packager.subprocess, "check_output", return_value=str(binary)
            ):
                packager.package(repo, self.root)
            contents = repo / ".guardian/Arkangel.app/Contents"
            self.assertEqual((contents / "Resources/AppIcon.icns").read_bytes(), b"icon")
            self.assertTrue((contents / "Resources/Python/bin/python3").is_file())
            with (contents / "Info.plist").open("rb") as stream:
                self.assertEqual(plistlib.load(stream)["CFBundleIconFile"], "AppIcon.icns")
            install = next(call.args[0] for call in run.call_args_list if "pip" in call.args[0])
            self.assertIn("Resources/Python/bin/python3", install[0])
            self.assertNotIn("-e", install)
            with self.assertRaisesRegex(ValueError, "ya existe"):
                packager.package(repo, self.root)
