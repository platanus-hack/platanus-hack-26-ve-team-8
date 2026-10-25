"""Build a relocatable macOS app from a python-build-standalone install_only tree."""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def validate_runtime(runtime: Path):
    if (runtime / "pyvenv.cfg").exists() or not (runtime / "bin/python3").is_file():
        raise ValueError("Usa un Python portátil install_only, no un entorno virtual.")
    for path in runtime.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(runtime.resolve()):
            raise ValueError(f"El entorno depende de un archivo externo: {path}")


def package(root: Path, runtime: Path):
    validate_runtime(runtime)
    output = root / ".guardian/Arkangel.app"
    if output.exists():
        raise ValueError(f"La salida ya existe; muévela antes de empaquetar: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swift", "build", "--package-path", str(root / "apps/macos"),
                    "--product", "Guardian", "-c", "release"], check=True)
    bin_path = subprocess.check_output(
        ["swift", "build", "--package-path", str(root / "apps/macos"),
         "-c", "release", "--show-bin-path"], text=True).strip()
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        app = Path(temporary) / "Arkangel.app"
        contents = app / "Contents"
        resources = contents / "Resources"
        (contents / "MacOS").mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(Path(bin_path) / "Guardian", contents / "MacOS/Guardian")
        shutil.copy2(root / "apps/macos/Icon/AppIcon.icns", resources / "AppIcon.icns")
        bundled = resources / "Python"
        shutil.copytree(runtime, bundled, symlinks=True)
        python = bundled / "bin/python3"
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("PYTHON")}
        # Install into the copied runtime, never an editable link to the checkout.
        subprocess.run([str(python), "-I", "-m", "pip", "--isolated", "install",
                        "--no-cache-dir", str(root / "services/agent")],
                       env=environment, check=True)
        validate_runtime(bundled)
        # Imports exercise native dependencies without starting a service or contacting a model.
        subprocess.run([str(python), "-I", "-c",
                        "import sys, pathlib, ssl, sqlite3, guardian, truststore, claude_agent_sdk; "
                        "assert sys.version_info >= (3, 11); "
                        "assert pathlib.Path(guardian.__file__).is_relative_to(sys.prefix); "
                        "assert (pathlib.Path(claude_agent_sdk.__file__).parent / '_bundled/claude').is_file()"],
                       cwd=temporary, env=environment, check=True)
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump({
                "CFBundleExecutable": "Guardian", "CFBundleDevelopmentRegion": "es",
                "CFBundleIdentifier": "local.guardian.app", "CFBundleName": "Arkangel",
                "CFBundleDisplayName": "Arkangel", "CFBundlePackageType": "APPL",
                "CFBundleIconFile": "AppIcon.icns", "CFBundleVersion": "6",
                "CFBundleShortVersionString": "0.6.0", "LSMinimumSystemVersion": "15.0",
                "NSHighResolutionCapable": True,
            }, stream)
        # Sign nested native libraries and the SDK CLI before sealing the outer app.
        for path in bundled.rglob("*"):
            if path.is_file() and not path.is_symlink():
                with path.open("rb") as stream:
                    magic = stream.read(4)
                if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
                    subprocess.run(["codesign", "--force", "--sign", "-", str(path)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        app.rename(output)
    print(f"App autónoma creada: {output}")


if __name__ == "__main__":
    try:
        package(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"No se pudo empaquetar Arkangel: {error}")
