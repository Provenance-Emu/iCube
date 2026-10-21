#!/bin/bash
set -euo pipefail
if [[ "${CONFIGURATION:-}" == Debug* && "${ICUBE_FAST_DEV_SKIP_LOCALIZATION:-}" == "1" ]]; then
  echo "note: unchanged localization inputs; fast DEV reuses storyboard translations"
  exit 0
fi
exec "$PROJECT_DIR/venv/bin/python3" "$PROJECT_DIR/Project/Scripts/TransferCoreStringsToStoryboard.py" \
  "$PROJECT_DIR/DolphiniOS" "$PROJECT_DIR/Common/UI/Localization/"
