#!/bin/bash
set -euo pipefail
if [[ "${CONFIGURATION:-}" == Debug* && "${ICUBE_FAST_DEV_SKIP_LOCALIZATION:-}" == "1" ]]; then
  echo "note: unchanged localization inputs; fast DEV reuses core strings"
  exit 0
fi
exec "$PROJECT_DIR/venv/bin/python3" "$PROJECT_DIR/Project/Scripts/UpdateCoreStrings.py" \
  "$PROJECT_DIR/../../../Languages/po/" "$PROJECT_DIR/Common/UI/Localization"
