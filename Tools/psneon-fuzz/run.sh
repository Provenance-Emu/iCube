#!/bin/sh
# Host fuzz for the CIRPsNeon fast path (Interpreter_Paired.cpp), Apple Silicon Mac only.
#
# Extracts the NEON helpers VERBATIM from Interpreter_Paired.cpp, then compares every accepted
# fast-path result against the real scalar NI_* / Force25Bit / ForceSingle bit for bit, in both
# NI modes and with cpu_info.bFlushToZero both ways. Exits non-zero on any mismatch.
# Run it after touching the PsNeon guards. `MUTATE=1 ./run.sh` loosens the result guard to the
# smallest normal double and must report mismatches, proving the harness can see a bad guard.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 - "$root/Source/Core/Core/PowerPC/Interpreter/Interpreter_Paired.cpp" "$out/psneon_extract.inc" "${MUTATE:-0}" <<'PY'
import sys
src = open(sys.argv[1]).read()
a = src.index("namespace\n{\n// NEON paired-single fast-path flags")
b = src.index("}  // namespace\n", a) + len("}  // namespace\n")
c = src.index("#include <arm_neon.h>")
d = src.index("#endif  // ARM64", c)
text = src[a:b] + "\n" + src[c:d]
if sys.argv[3] == "1":
    old = "return BothZeroOrFiniteAtLeast<0x3810000000000000ULL>(v);"
    assert old in text
    text = text.replace(old, "return BothZeroOrFiniteAtLeast<0x0010000000000000ULL>(v);")
open(sys.argv[2], "w").write(text)
PY
cp "$here/psneon_fuzz.cpp" "$out/"
xcrun clang++ -std=c++2b -O1 -arch arm64 -D_M_ARM_64=1 -D_ARCH_64=1 \
  -I "$root/Source/Core" -I "$root/Externals/fmt/fmt/include" \
  "$out/psneon_fuzz.cpp" -o "$out/psneon_fuzz"
"$out/psneon_fuzz"
