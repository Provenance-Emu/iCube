#!/usr/bin/env bash
# Run the shared PVWebServer 1.3.0 transfer benchmark.
# Pass the web server URL shown by iCube or --service "iCube (hostname)".
set -euo pipefail

revision=537ba583742a19992e2c8955fec0614fefd145a8
sha256=8a479b309a50296c47c7f0e35275b1b0ce73a080ed995b575f9748c5026f16e4
url="https://raw.githubusercontent.com/Provenance-Emu/PVWebServer/${revision}/Scripts/webserver_transfer_bench.sh"

script=$(mktemp "${TMPDIR:-/tmp}/pvweb-bench-script.XXXXXX")
trap 'rm -f "$script"' EXIT
curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout 10 --max-time 30 -o "$script" "$url"
if ! printf '%s  %s\n' "$sha256" "$script" | shasum -a 256 -c >/dev/null; then
  echo "webserver-bench: PVWebServer 1.3.0 script checksum mismatch" >&2
  exit 1
fi

bash "$script" "$@"
