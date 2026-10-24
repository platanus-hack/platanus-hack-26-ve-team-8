#!/bin/sh
# Genera un artefacto de desarrollo ejecutable. La verificación usa comprobaciones de tipos aparte.
set -eu
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift build --package-path "$REPO_ROOT/apps/macos" --product Guardian
export GUARDIAN_PACKAGE_ROOT="$REPO_ROOT"
"$REPO_ROOT/.venv/bin/python" - <<'PY'
import os
import plistlib
import shutil
from pathlib import Path

root = Path(os.environ['GUARDIAN_PACKAGE_ROOT'])
contents = root / '.guardian/Arkangel.app/Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'apps/macos/.build/debug/Guardian', contents / 'MacOS/Guardian')
(contents / 'Resources').mkdir(exist_ok=True)
shutil.copy2(root / 'apps/macos/Icon/AppIcon.icns', contents / 'Resources/AppIcon.icns')
with (contents / 'Info.plist').open('wb') as stream:
    plistlib.dump({
        'CFBundleExecutable': 'Guardian', 'CFBundleDevelopmentRegion': 'es', 'CFBundleIdentifier': 'local.guardian.app',
        'CFBundleName': 'Arkangel', 'CFBundleDisplayName': 'Arkangel', 'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'AppIcon',
        'CFBundleVersion': '2', 'CFBundleShortVersionString': '0.2.0',
        'LSMinimumSystemVersion': '15.0', 'NSHighResolutionCapable': True,
    }, stream)
print(contents.parent)
PY
codesign --force --sign - "$REPO_ROOT/.guardian/Arkangel.app"
