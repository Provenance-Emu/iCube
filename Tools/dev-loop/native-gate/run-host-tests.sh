#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
bin=$(mktemp "${TMPDIR:-/tmp}/icube-native-gate.XXXXXX")
trap 'rm -f "$bin"' EXIT
/usr/bin/clang++ -std=c++20 -Wall -Wextra -Werror -pthread -I "$root/Source/Core" "$root/Tools/dev-loop/native-gate/controller_input_gate_test.cpp" -o "$bin"
"$bin"
