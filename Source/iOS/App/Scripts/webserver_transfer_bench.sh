#!/usr/bin/env bash
#
# webserver_transfer_bench.sh — compare WebDAV PUT vs browser PUT vs multipart POST throughput.
#
# Discovers iCube via Bonjour (_http._tcp "iCube") or use --url.
# Requires: curl, dns-sd (macOS), dd. Open iCube Settings so the upload server starts.
#
# Example output (device on LAN, 3 runs each):
#   size,method,run,http_code,seconds,bytes,mbps
#   small,webdav,1,201,0.038,262144,55.1
#   small,http_put,1,201,0.040,262144,52.4
#   small,http_post,1,200,0.052,262357,40.3
#   ...
#   SUMMARY (median): small webdav 54.2 MB/s | http_post 39.8 MB/s | ratio 1.36x
#
set -euo pipefail

SERVICE_NAME="iCube"
BENCH_SUBDIR="bench"
RESULTS_FILE=""

URL=""
TIMEOUT=10
RUNS=3
SIZES_SPEC="256k,8m,64m"
DO_CLEANUP=1
DO_DOWNLOAD=0
JSON_OUTPUT=0

usage() {
  cat <<'EOF'
Usage: webserver_transfer_bench.sh [options]

Compare WebDAV PUT, browser-style PUT /files/…, and multipart POST /upload (small / medium / large).

Options:
  --url URL         Base URL (e.g. http://My-iPhone.local:8080/) — skip Bonjour
  --timeout SEC     Bonjour browse timeout (default: 10)
  --runs N          Repetitions per size/method (default: 3)
  --sizes SPEC      Comma list: 256k,8m,64m (default)
  --no-cleanup      Leave bench/*.bin on device after run
  --download        Also benchmark GET /files/bench/... after each upload
  --json            Print summary as JSON at end
  -h, --help        Show this help

Examples:
  ./Scripts/webserver_transfer_bench.sh
  ./Scripts/webserver_transfer_bench.sh --url http://192.168.1.42:8080/
  make webserver-bench
EOF
}

die() {
  echo "webserver-bench: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

# Parse human size (256k, 8m, 64m, 1g) to bytes.
parse_size() {
  local spec="$1"
  local num="${spec%[kKmMgG]}"
  local suffix="${spec:${#num}}"
  if [[ ! "$num" =~ ^[0-9]+$ ]]; then
    die "invalid size: $spec"
  fi
  case "$(echo "$suffix" | tr '[:upper:]' '[:lower:]')" in
    k|K) echo $((num * 1024)) ;;
    m|M) echo $((num * 1024 * 1024)) ;;
    g|G) echo $((num * 1024 * 1024 * 1024)) ;;
    "") echo "$num" ;;
    *) die "invalid size suffix in: $spec" ;;
  esac
}

# Label for a byte count (small / medium / large by order in list).
size_label() {
  local idx="$1"
  case "$idx" in
    0) echo "small" ;;
    1) echo "medium" ;;
    2) echo "large" ;;
    *) echo "size${idx}" ;;
  esac
}

normalize_url() {
  local u="$1"
  u="${u%/}/"
  [[ "$u" == http://* || "$u" == https://* ]] || u="http://${u}"
  echo "$u"
}

discover_bonjour_url() {
  local browse_tmp resolve_tmp
  browse_tmp=$(mktemp "${TMPDIR:-/tmp}/ifly-bench-browse.XXXXXX")
  resolve_tmp=$(mktemp "${TMPDIR:-/tmp}/ifly-bench-resolve.XXXXXX")

  local stype found=0
  for stype in _http._tcp _webdav._tcp; do
    echo "webserver-bench: browsing Bonjour ${stype} for '${SERVICE_NAME}' (${TIMEOUT}s)…" >&2
    : >"$browse_tmp"
    dns-sd -B "$stype" local. >"$browse_tmp" 2>&1 &
    local browse_pid=$!
    sleep "$TIMEOUT"
    kill "$browse_pid" 2>/dev/null || true
    wait "$browse_pid" 2>/dev/null || true

    if grep -F "$SERVICE_NAME" "$browse_tmp" | grep -q 'Add'; then
      found=1
      break
    fi
  done

  if [[ "$found" -ne 1 ]]; then
    echo "webserver-bench: Bonjour browse saw (last lines):" >&2
    tail -15 "$browse_tmp" >&2 || true
    rm -f "$browse_tmp" "$resolve_tmp"
    return 1
  fi
  rm -f "$browse_tmp"

  echo "webserver-bench: resolving '${SERVICE_NAME}'…" >&2
  : >"$resolve_tmp"
  dns-sd -L "$SERVICE_NAME" _http._tcp local. >"$resolve_tmp" 2>&1 &
  local resolve_pid=$!
  sleep 4
  kill "$resolve_pid" 2>/dev/null || true
  wait "$resolve_pid" 2>/dev/null || true

  local line host port
  line=$(grep -E 'can be reached at' "$resolve_tmp" | head -1 || true)
  rm -f "$resolve_tmp"

  if [[ -z "$line" ]]; then
    return 1
  fi

  if [[ "$line" =~ can\ be\ reached\ at\ ([^:]+):([0-9]+) ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    host="${host%.}"
    if [[ "$port" == "80" ]]; then
      echo "http://${host}/"
    else
      echo "http://${host}:${port}/"
    fi
    return 0
  fi
  return 1
}

preflight() {
  local base="$1"
  echo "webserver-bench: preflight GET ${base}…" >&2
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "${base}" 2>/dev/null) || code="000"
  if [[ "$code" != "200" ]]; then
    die "server not reachable at ${base} (HTTP ${code})"
  fi
  # Debug API optional — don't fail if absent
  curl -sf --connect-timeout 3 --max-time 5 "${base}api/health" >/dev/null 2>&1 \
    && echo "webserver-bench: debug API available" >&2 \
    || echo "webserver-bench: debug API not enabled (upload bench still runs)" >&2
}

generate_payload() {
  local path="$1"
  local bytes="$2"
  echo "webserver-bench: generating ${bytes} byte payload…" >&2
  # Prefer dd — macOS mkfile treats "Nb" as N×512-byte blocks, not N bytes.
  if (( bytes >= 1048576 && bytes % 1048576 == 0 )); then
    dd if=/dev/zero of="$path" bs=1048576 count=$((bytes / 1048576)) 2>/dev/null
  elif (( bytes >= 1024 && bytes % 1024 == 0 )); then
    dd if=/dev/zero of="$path" bs=1024 count=$((bytes / 1024)) 2>/dev/null
  else
    dd if=/dev/zero of="$path" bs=1 count="$bytes" 2>/dev/null
  fi
  local actual
  actual=$(wc -c <"$path" | tr -d '[:space:]')
  [[ -f "$path" && "$actual" -eq "$bytes" ]] \
    || die "failed to create payload $path (wanted ${bytes} bytes, got ${actual:-0})"
}

webdav_ok_code() {
  local code="$1"
  [[ "$code" == "201" || "$code" == "204" ]]
}

http_post_ok_code() {
  local code="$1"
  [[ "$code" == "200" ]]
}

http_put_ok_code() {
  local code="$1"
  [[ "$code" == "201" || "$code" == "204" ]]
}

run_upload() {
  local method="$1"
  local file="$2"
  local label="$3"
  local base="$4"
  local run_num="$5"
  local bytes="$6"

  local code time_total size_upload mbps
  local bench_name="${label}.${method}.bin"
  case "$method" in
    webdav)
      read -r code time_total size_upload < <(
        curl -sS -o /dev/null \
          -w '%{http_code} %{time_total} %{size_upload}' \
          -X PUT -T "$file" \
          -H 'User-Agent: iFly-bench/rclone/' \
          -H 'Overwrite: T' \
          --connect-timeout 10 --max-time 600 \
          "${base}${BENCH_SUBDIR}/${bench_name}"
      )
      webdav_ok_code "$code" || die "WebDAV PUT failed: HTTP $code for ${label} run $run_num"
      ;;
    http_put)
      read -r code time_total size_upload < <(
        curl -sS -o /dev/null \
          -w '%{http_code} %{time_total} %{size_upload}' \
          -X PUT -T "$file" \
          -H 'User-Agent: Mozilla/5.0 (iFly-bench)' \
          -H 'Overwrite: T' \
          --connect-timeout 10 --max-time 600 \
          "${base}files/${BENCH_SUBDIR}/${bench_name}"
      )
      http_put_ok_code "$code" || die "HTTP PUT /files/ failed: HTTP $code for ${label} run $run_num"
      ;;
    http_post)
      read -r code time_total size_upload < <(
        curl -sS -o /dev/null \
          -w '%{http_code} %{time_total} %{size_upload}' \
          -X POST \
          -F "file=@${file};filename=${bench_name}" \
          --connect-timeout 10 --max-time 600 \
          "${base}upload?path=${BENCH_SUBDIR}"
      )
      http_post_ok_code "$code" || die "HTTP POST failed: HTTP $code for ${label} run $run_num"
      ;;
    *)
      die "unknown method: $method"
      ;;
  esac

  if awk -v t="$time_total" 'BEGIN { exit (t > 0) ? 0 : 1 }'; then
    mbps=$(awk -v b="$size_upload" -v t="$time_total" 'BEGIN { printf "%.2f", (b * 8 / 1000000) / t }')
  else
    mbps="0.00"
  fi

  echo "${label},${method},${run_num},${code},${time_total},${size_upload},${mbps}"
}

run_download() {
  local label="$1"
  local base="$2"
  local run_num="$3"

  local code time_total size_download mbps
  read -r code time_total size_download < <(
    curl -sS -o /dev/null \
      -w '%{http_code} %{time_total} %{size_download}' \
      --connect-timeout 10 --max-time 600 \
      "${base}files/${BENCH_SUBDIR}/${label}.bin"
  )
  [[ "$code" == "200" ]] || die "HTTP GET download failed: HTTP $code for ${label} run $run_num"

  if awk -v t="$time_total" 'BEGIN { exit (t > 0) ? 0 : 1 }'; then
    mbps=$(awk -v b="$size_download" -v t="$time_total" 'BEGIN { printf "%.2f", (b * 8 / 1000000) / t }')
  else
    mbps="0.00"
  fi

  echo "${label},http_get,${run_num},${code},${time_total},${size_download},${mbps}"
}

cleanup_file() {
  local label="$1"
  local base="$2"
  local method="${3:-}"
  local suffix=""
  if [[ -n "$method" ]]; then
    suffix=".${method}"
  fi
  curl -sS -o /dev/null -X DELETE \
    --connect-timeout 5 --max-time 30 \
    "${base}files/${BENCH_SUBDIR}/${label}${suffix}.bin" 2>/dev/null \
    || curl -sS -o /dev/null -X DELETE \
      --connect-timeout 5 --max-time 30 \
      -H 'User-Agent: iFly-bench/rclone/' \
      "${base}${BENCH_SUBDIR}/${label}${suffix}.bin" 2>/dev/null \
    || true
}

print_summary() {
  local results="$1"
  echo ""
  echo "=== Summary (median seconds / MB/s) ==="
  awk -F, '
    NR == 1 { next }
    $2 != "method" && $4 ~ /^[0-9]+$/ {
      key = $1 SUBSEP $2
      n[key]++
      t[key,n[key]] = $5 + 0
      m[key,n[key]] = $7 + 0
    }
    END {
      for (k in n) {
        split(k, parts, SUBSEP)
        label = parts[1]
        method = parts[2]
        cnt = n[k]
        for (i = 1; i <= cnt; i++) {
          ti[i] = t[k,i]
          mi[i] = m[k,i]
        }
        for (i = 1; i <= cnt; i++) {
          for (j = i + 1; j <= cnt; j++) {
            if (ti[i] > ti[j]) { tmp = ti[i]; ti[i] = ti[j]; ti[j] = tmp }
            if (mi[i] > mi[j]) { tmp = mi[i]; mi[i] = mi[j]; mi[j] = tmp }
          }
        }
        mid = int((cnt + 1) / 2)
        med_t = ti[mid]
        med_m = mi[mid]
        printf "  %-8s %-12s  %.3fs  %.1f MB/s\n", label, method, med_t, med_m
        if (method == "webdav") med_m_webdav[label] = med_m
        if (method == "http_put") med_m_http_put[label] = med_m
        if (method == "http_post") med_m_http_post[label] = med_m
      }
      print ""
      print "=== HTTP PUT /files/ (browser path) vs WebDAV (median MB/s, >1 = WebDAV faster) ==="
      for (label in med_m_webdav) {
        if (med_m_http_put[label] > 0 && med_m_webdav[label] > 0) {
          ratio = med_m_webdav[label] / med_m_http_put[label]
          printf "  %-8s  %.2fx\n", label, ratio
        }
      }
      print ""
      print "=== HTTP POST (multipart) vs WebDAV (median MB/s, >1 = WebDAV faster) ==="
      for (label in med_m_webdav) {
        if (med_m_http_post[label] > 0 && med_m_webdav[label] > 0) {
          ratio = med_m_webdav[label] / med_m_http_post[label]
          printf "  %-8s  %.2fx\n", label, ratio
        }
      }
    }
  ' "$results"

  if [[ "$JSON_OUTPUT" -eq 1 ]]; then
    echo ""
    echo "=== JSON summary ==="
    awk -F, '
      NR == 1 { next }
      $2 != "method" {
        key = $1 SUBSEP $2
        n[key]++
        t[key,n[key]] = $5 + 0
        m[key,n[key]] = $7 + 0
      }
      END {
        printf "{ \"results\": [\n"
        first = 1
        for (k in n) {
          split(k, parts, SUBSEP)
          label = parts[1]
          method = parts[2]
          cnt = n[k]
          for (i = 1; i <= cnt; i++) { ti[i] = t[k,i]; mi[i] = m[k,i] }
          for (i = 1; i <= cnt; i++) {
            for (j = i + 1; j <= cnt; j++) {
              if (ti[i] > ti[j]) { tmp = ti[i]; ti[i] = ti[j]; ti[j] = tmp }
              if (mi[i] > mi[j]) { tmp = mi[i]; mi[i] = mi[j]; mi[j] = tmp }
            }
          }
          mid = int((cnt + 1) / 2)
          if (!first) printf ",\n"
          first = 0
          printf "  {\"size\":\"%s\",\"method\":\"%s\",\"median_seconds\":%.4f,\"median_mbps\":%.2f,\"runs\":%d}",
            label, method, ti[mid], mi[mid], cnt
        }
        printf "\n]}\n"
      }
    ' "$results"
  fi
}

# --- CLI ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL=$(normalize_url "$2"); shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --sizes) SIZES_SPEC="$2"; shift 2 ;;
    --no-cleanup) DO_CLEANUP=0; shift ;;
    --download) DO_DOWNLOAD=1; shift ;;
    --json) JSON_OUTPUT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

require_cmd curl
require_cmd dns-sd
require_cmd dd
require_cmd awk

if [[ -z "$URL" ]]; then
  URL=$(discover_bonjour_url) || die "Bonjour discovery failed — start iFly web server, stay on the same Wi‑Fi, or pass --url http://host:port/"
fi
URL=$(normalize_url "$URL")

preflight "$URL"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ifly-bench.XXXXXX")
RESULTS_FILE=$(mktemp "${TMPDIR:-/tmp}/ifly-bench-results.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

IFS=',' read -ra SIZE_SPECS <<<"$SIZES_SPEC"
declare -a SIZE_BYTES=()
declare -a SIZE_LABELS=()

idx=0
for spec in "${SIZE_SPECS[@]}"; do
  spec="${spec// /}"
  [[ -n "$spec" ]] || continue
  bytes=$(parse_size "$spec")
  label=$(size_label "$idx")
  SIZE_BYTES+=("$bytes")
  SIZE_LABELS+=("$label")
  generate_payload "${WORK_DIR}/${label}.bin" "$bytes"
  idx=$((idx + 1))
done

[[ ${#SIZE_BYTES[@]} -gt 0 ]] || die "no sizes parsed from: $SIZES_SPEC"

echo "size,method,run,http_code,seconds,bytes,mbps" | tee "$RESULTS_FILE"
echo "webserver-bench: URL=$URL runs=$RUNS sizes=${SIZE_LABELS[*]}" >&2

for i in "${!SIZE_BYTES[@]}"; do
  label="${SIZE_LABELS[$i]}"
  file="${WORK_DIR}/${label}.bin"
  bytes="${SIZE_BYTES[$i]}"

  for method in webdav http_put http_post; do
    for ((run = 1; run <= RUNS; run++)); do
      cleanup_file "${label}" "$URL" "$method"
      row=$(run_upload "$method" "$file" "$label" "$URL" "$run" "$bytes")
      echo "$row" | tee -a "$RESULTS_FILE"
    done
  done

  if [[ "$DO_DOWNLOAD" -eq 1 ]]; then
    for ((run = 1; run <= RUNS; run++)); do
      row=$(run_download "$label" "$URL" "$run")
      echo "$row" | tee -a "$RESULTS_FILE"
    done
  fi
done

print_summary "$RESULTS_FILE"

if [[ "$DO_CLEANUP" -eq 1 ]]; then
  echo "webserver-bench: cleaning up ${BENCH_SUBDIR}/…" >&2
  for label in "${SIZE_LABELS[@]}"; do
    for method in webdav http_put http_post; do
      cleanup_file "$label" "$URL" "$method"
    done
    cleanup_file "$label" "$URL"
  done
fi

echo "webserver-bench: done" >&2
