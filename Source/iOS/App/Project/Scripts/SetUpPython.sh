#!/bin/bash

set -e

VENV_DIR="$PROJECT_DIR/venv"

# Recreate venv if python3 binary is missing or broken (e.g. stale Xcode symlink)
if [ -d "$VENV_DIR" ] && ! "$VENV_DIR/bin/python3" --version &>/dev/null; then
  echo "SetUpPython: stale venv detected, recreating..."
  rm -rf "$VENV_DIR"
fi

if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python3" -m pip install polib
