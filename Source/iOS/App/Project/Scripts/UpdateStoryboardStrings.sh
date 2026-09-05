#!/bin/bash
export PATH="$PATH:/opt/homebrew/bin"

set -e

cd "$PROJECT_DIR"

# BartyCrouch regenerates the .strings files from the storyboards. It is a
# developer convenience, not a build input: the .strings are committed, and the
# archive is identical whether or not this ran.
#
# It is not installed on GitHub's runners — build.yml's "Install Build Utilities"
# step is commented out, and it only ever existed on the old self-hosted runner.
# Under `set -e` the missing binary failed the whole archive:
#
#   UpdateStoryboardStrings.sh: line 9: bartycrouch: command not found
#   Command PhaseScriptExecution failed with a nonzero exit code
#   ** ARCHIVE FAILED **
#
# Skip when absent rather than taking the build down. Installing it in CI would
# also work, but it would add install time to every run in order to regenerate
# files that are already committed and that CI never commits back.
if ! command -v bartycrouch >/dev/null 2>&1; then
  echo "note: bartycrouch not installed — skipping storyboard strings update (brew install bartycrouch)"
  exit 0
fi

bartycrouch update -x
