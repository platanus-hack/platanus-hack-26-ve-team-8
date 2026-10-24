#!/bin/sh
set -eu
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ ! -x "$REPO_ROOT/.venv/bin/python" ]; then
    "${GUARDIAN_PYTHON:-python3}" -m venv "$REPO_ROOT/.venv"
fi
"$REPO_ROOT/.venv/bin/python" -m pip install -e "$REPO_ROOT/services/agent"
echo "Guardian agent environment ready. Open the app to connect your Anthropic key."
