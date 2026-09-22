#!/usr/bin/env bash
#
# Manage FEED_DISPATCH_TOKEN — the credential iCube's CI uses to tell the two
# sideload feeds that a new alpha exists.
#
# Why this script exists
# ---------------------
# Setting the secret by hand went wrong twice in one evening, in two different
# ways, and both are designed out here:
#
#   1. `op read ... | gh secret set ...` OVERWROTE A WORKING SECRET WITH NOTHING.
#      Both sides of a pipe run regardless of the left side's exit status, so a
#      failed `op read` still handed empty stdin to `gh`, which cheerfully stored
#      it and printed a checkmark. Nothing here pipes into `gh` without the value
#      having been read, checked non-empty, and checked plausible first.
#   2. The 1Password field was guessed. Login items keep the secret in
#      `password`, API Credential items in `credential`, and a wrong guess is
#      indistinguishable from a missing item. This resolves the field by asking
#      the item what fields it has.
#
# The token value is never printed, never written to disk, and never passed as an
# argument (argv is world-readable in `ps`). It lives in one shell variable and
# reaches `gh` and `curl` only on stdin or through the environment.
#
# What kind of token this needs
# -----------------------------
# GitHub's REST docs for "Create a repository dispatch event" document exactly
# one working configuration: a CLASSIC personal access token with the `repo`
# scope. They list no fine-grained permission for the endpoint at all. A
# fine-grained PAT with both repositories in its access list and
# `Contents: Read and write` is the commonly reported equivalent and is worth
# trying first for least privilege -- `check` makes a wrong guess cost one
# command rather than a broken deploy -- but if it returns 403, the classic
# token is the documented path, not a workaround.
#
# Usage
#   Tools/icube-feed-token.sh status     # what is deployed and whether it is current
#   Tools/icube-feed-token.sh fields     # field names on the 1Password item (no values)
#   Tools/icube-feed-token.sh check      # can the stored token see both repos?
#   Tools/icube-feed-token.sh install    # check, then store it as the Actions secret
#   Tools/icube-feed-token.sh dispatch   # fire both refreshes now, using the stored token
#
#   Tools/icube-feed-token.sh set        # paste a new token (hidden); test; store it
#   Tools/icube-feed-token.sh set --from-gh-cli
#                                        # reuse the gh CLI's own OAuth token instead
#   ... add --save-to-op to also write it back into the 1Password item
#
# Environment
#   OP_ITEM   1Password secret reference WITHOUT the field, e.g.
#             op://Private/provenance-website-dispatch      (default below)
#   OP_FIELD  Force a field name instead of auto-detecting.
#
set -euo pipefail

OP_ITEM="${OP_ITEM:-op://Private/provenance-website-dispatch}"
OP_FIELD="${OP_FIELD:-}"

ICUBE_REPO='Provenance-Emu/iCube'
SITE_REPO='Provenance-Emu/icube-emu.github.io'
COMBINED_REPO='Provenance-Emu/Provenance'
SECRET_NAME='FEED_DISPATCH_TOKEN'
FEED_URL='https://icube-emu.com/api/altstore'

# Fields a token might live in, most specific first.
CANDIDATE_FIELDS=(credential password token api_key notesPlain)

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
bad()  { printf '\033[31m  ✗\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }

# ── 1Password ────────────────────────────────────────────────────────────────

item_ref() { printf '%s' "${OP_ITEM#op://}"; }

cmd_fields() {
  need op
  local vault item ref
  ref="$(item_ref)"
  vault="${ref%%/*}"
  item="${ref#*/}"
  info "Fields on ${vault}/${item} (names and types only — no values):"
  # Projecting away .value on purpose: this prints what the fields are called,
  # never what is in them.
  op item get "$item" --vault "$vault" --format json \
    | jq -r '"  category: \(.category)", (.fields[]? | "  \(.id)\t\(.label // "-")\t[\(.type)]")'
}

# Echoes the token on stdout. Callers must capture it, never let it reach a tty.
read_token() {
  need op
  local ref f value
  ref="$(item_ref)"

  if [ -n "$OP_FIELD" ]; then
    op read "op://${ref}/${OP_FIELD}" 2>/dev/null || die "no field '${OP_FIELD}' on ${ref}"
    return
  fi

  for f in "${CANDIDATE_FIELDS[@]}"; do
    if value="$(op read "op://${ref}/${f}" 2>/dev/null)" && [ -n "$value" ]; then
      printf '%s' "$value"
      return
    fi
  done

  die "could not find a non-empty token field on ${ref}.
  Run '$0 fields' to see what the item actually has, then re-run with
  OP_FIELD=<name>."
}

# A GitHub token is an opaque string, but every current format is prefixed and
# has no whitespace. Catching an obviously-wrong value here is what stops a
# stray error message or a Base64 blob from becoming the secret.
validate_shape() {
  local t="$1"
  [ -n "$t" ] || die "the token is empty — refusing to store it"
  case "$t" in
    *[[:space:]]*) die "the token contains whitespace — that is not a GitHub token" ;;
    ghp_*|github_pat_*|gho_*|ghu_*|ghs_*|ghr_*) : ;;
    *) die "the value does not look like a GitHub token.
  Expected one of the ghp_ / github_pat_ / gho_ / ghu_ / ghs_ / ghr_ prefixes.
  If it came from 1Password, the field may be the wrong one -- try '$0 fields'." ;;
  esac
}

# ── Probes ───────────────────────────────────────────────────────────────────
#
# There is no read-only probe for this. The obvious one -- GET /repos/{o}/{r} --
# is worthless here and was actively misleading when this script was first
# written: both feed repositories are PUBLIC, so any valid token gets a 200, and
# the `permissions` object it returns describes the USER's role on the repo, not
# the token's scope. A token that cannot dispatch at all reported "can reach"
# for both repos.
#
# So the dispatch is the test. It is idempotent and harmless -- it asks the two
# feeds to regenerate from sources they already poll -- and it is the only thing
# that answers the actual question.

# Prints the token's login, or fails if the token is not valid at all. This part
# genuinely is side-effect free, and it separates "expired/revoked" from
# "valid but not permitted", which need different fixes.
token_identity() {
  local token="$1"
  GH_TOKEN="$token" gh api /user --jq '.login' 2>/dev/null
}

# 204 = accepted. 403 = the token can see the repo but lacks Contents: write.
# 404 = the repo is not in the token's repository access list at all. Those are
# different mistakes on the token settings page, so name them separately.
try_dispatch() {
  local token="$1" repo="$2" out
  if out="$(GH_TOKEN="$token" gh api "repos/${repo}/dispatches" \
       -f event_type=companion-release \
       -F 'client_payload[app]=icube' 2>&1)"; then
    ok "${repo}: dispatch accepted"
    return 0
  fi
  case "$out" in
    *403*|*"not accessible"*)
      bad "${repo}: 403 — the token can see the repo but is not permitted to dispatch"
      warn "  GitHub documents only ONE configuration for this endpoint:"
      warn "  a CLASSIC personal access token with the 'repo' scope."
      warn "  Fine-grained PATs have no documented permission for it; 'Contents:"
      warn "  Read and write' is the commonly reported answer but is a guess."
      warn "  Try that first (this script re-tests cheaply); if it still 403s,"
      warn "  use a classic token with 'repo'." ;;
    *404*|*"Not Found"*)
      bad "${repo}: 404 — repo is not in the token's repository access list"
      warn "  add ${repo} under 'Repository access'" ;;
    *401*|*"Bad credentials"*)
      bad "${repo}: 401 — the token is expired or revoked" ;;
    *)
      bad "${repo}: ${out}" ;;
  esac
  return 1
}

probe_all() {
  local token="$1" rc=0 repo
  for repo in "$COMBINED_REPO" "$SITE_REPO"; do
    try_dispatch "$token" "$repo" || rc=1
  done
  return $rc
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_check() {
  need gh; need jq
  local token who
  info "Reading the token from ${OP_ITEM} ..."
  token="$(read_token)"
  validate_shape "$token"
  ok "found a plausible token (value not shown)"

  who="$(token_identity "$token")" || die "the token is not valid — expired, revoked, or malformed"
  ok "valid; authenticates as ${who}"

  info "Dispatching to both feeds — this is the only real test, and it is harmless."
  if probe_all "$token"; then
    ok "this token can refresh both feeds"
    return 0
  fi
  warn "Fix at github.com/settings/personal-access-tokens."
  warn "Editing a fine-grained PAT does NOT regenerate it, so an already-stored secret stays valid."
  return 1
}

cmd_install() {
  need gh; need jq
  local token who force="${1:-}"
  token="$(read_token)"
  validate_shape "$token"
  who="$(token_identity "$token")" || die "the token is not valid — refusing to store it"
  ok "valid; authenticates as ${who}"

  info "Testing before installing ..."
  if ! probe_all "$token"; then
    if [ "$force" != "--force" ]; then
      die "this token cannot refresh the feeds, so storing it would achieve nothing.
  Fix its permissions first, or re-run with: $0 install --force"
    fi
    warn "installing anyway (--force)"
  fi

  printf '%s' "$token" | gh secret set "$SECRET_NAME" --repo "$ICUBE_REPO"
  ok "stored ${SECRET_NAME} in ${ICUBE_REPO}"
  info "GitHub secrets are write-only, so this cannot be read back to confirm."
}

cmd_dispatch() {
  need gh
  local token repo
  token="$(read_token)"
  validate_shape "$token"
  for repo in "$COMBINED_REPO" "$SITE_REPO"; do
    if GH_TOKEN="$token" gh api "repos/${repo}/dispatches" \
         -f event_type=companion-release \
         -F 'client_payload[app]=icube' >/dev/null 2>&1; then
      ok "dispatched to ${repo}"
    else
      bad "dispatch to ${repo} refused"
    fi
  done
}

# Take a token from somewhere other than 1Password, test it, and store it.
#
# Stdin is read with `read -rs`: not echoed, not in argv (which `ps` exposes),
# not in shell history. That is the whole reason this is a command rather than a
# one-liner in a README -- every hand-written version of this either echoed the
# token or piped into `gh` in a way that could not fail safely.
#
# There is no API to CREATE a GitHub token: the classic Authorizations API was
# removed in 2020 and fine-grained PATs are web-UI only. So either paste one, or
# use --from-gh-cli to reuse the token `gh` already holds.
cmd_set() {
  need gh
  local token from_gh=0 save_op=0 arg who

  for arg in "$@"; do
    case "$arg" in
      --from-gh-cli) from_gh=1 ;;
      --save-to-op)  save_op=1 ;;
      *) die "unknown flag '$arg' (expected --from-gh-cli and/or --save-to-op)" ;;
    esac
  done

  if [ "$from_gh" = 1 ]; then
    # `gh auth token` already has whatever scopes you granted the CLI, and the
    # docs' documented path for this endpoint is an OAuth/classic token with
    # `repo`. Convenient, but understand the trade: it is YOUR CLI credential,
    # usually with much broader scopes than this job needs, and it can rotate
    # when you re-auth, which would silently break CI.
    token="$(gh auth token 2>/dev/null)" || die "gh has no token — run 'gh auth login'"
    warn "using the gh CLI's own token; its scopes are broader than this job needs"
  else
    printf 'Paste the token (input hidden), then Enter: ' >&2
    IFS= read -rs token || die "no input"
    printf '\n' >&2
  fi

  validate_shape "$token"
  who="$(token_identity "$token")" || die "that token is not valid — nothing stored"
  ok "valid; authenticates as ${who}"

  info "Testing before storing ..."
  probe_all "$token" || die "that token cannot refresh the feeds — nothing stored.
  Classic token with the 'repo' scope is the configuration GitHub documents."

  printf '%s' "$token" | gh secret set "$SECRET_NAME" --repo "$ICUBE_REPO"
  ok "stored ${SECRET_NAME} in ${ICUBE_REPO}"

  if [ "$save_op" = 1 ]; then
    need op
    local ref vault item
    ref="$(item_ref)"; vault="${ref%%/*}"; item="${ref#*/}"
    # Caveat, stated rather than hidden: `op item edit` takes the value as an
    # argument, so it is briefly visible in `ps` on this machine. Everything
    # else here avoids argv; 1Password's CLI offers no stdin path for editing a
    # single field, so this is opt-in instead of default.
    op item edit "$item" --vault "$vault" "token[password]=${token}" >/dev/null \
      && ok "updated ${vault}/${item} field 'token'" \
      || warn "could not update the 1Password item — the CI secret is set regardless"
  else
    info "Not written to 1Password. Add --save-to-op if you want 'check'/'install' to work later."
  fi
}

cmd_status() {
  need gh; need jq
  local updated newest feed bv url

  info "Actions secret"
  updated="$(gh secret list --repo "$ICUBE_REPO" --json name,updatedAt \
    --jq ".[] | select(.name==\"${SECRET_NAME}\") | .updatedAt" 2>/dev/null || true)"
  if [ -n "$updated" ]; then ok "${SECRET_NAME} last set ${updated}"
  else bad "${SECRET_NAME} is not set on ${ICUBE_REPO}"; fi

  info "Has a dispatch ever arrived?"
  for repo in "$COMBINED_REPO" "$SITE_REPO"; do
    n="$(gh api "repos/${repo}/actions/runs?event=repository_dispatch&per_page=1" \
      --jq '.total_count' 2>/dev/null || echo '?')"
    if [ "$n" = "0" ]; then bad "${repo}: never (${n} runs)"
    else ok "${repo}: ${n} runs"; fi
  done

  info "Newest immutable alpha tag vs what the live feed links"
  newest="$(gh release list --repo "$ICUBE_REPO" --limit 100 --json tagName \
    --jq '.[].tagName' 2>/dev/null | grep -E '^alpha-[0-9]+$' | sort -t- -k2 -n -r | head -1 || true)"
  ok "newest published: ${newest:-<none yet>}"

  feed="$(curl -fsSL "${FEED_URL}?cb=$(date +%s)" 2>/dev/null \
    | jq -c '.apps[0].versions[0] | {version, buildVersion, downloadURL}' 2>/dev/null || true)"
  if [ -z "$feed" ]; then
    bad "could not read ${FEED_URL}"
    return 0
  fi
  bv="$(printf '%s' "$feed" | jq -r '.buildVersion')"
  url="$(printf '%s' "$feed" | jq -r '.downloadURL')"
  ok "feed offers buildVersion ${bv}"
  case "$url" in
    */alpha-*/*)
      if [ -n "$newest" ] && [ "$url" = "${url%/${newest}/*}" ]; then
        warn "feed links an older pinned build than ${newest} — it will refresh on the next deploy"
      else
        ok "feed links the newest immutable build"
      fi ;;
    */alpha/*)
      warn "feed still links the ROLLING alpha tag; its metadata can go stale and break installs" ;;
    *) warn "unexpected downloadURL: ${url}" ;;
  esac
}

case "${1:-status}" in
  status)   cmd_status ;;
  fields)   cmd_fields ;;
  check)    cmd_check ;;
  install)  shift || true; cmd_install "${1:-}" ;;
  set)      shift || true; cmd_set "$@" ;;
  dispatch) cmd_dispatch ;;
  -h|--help|help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' — try: status | fields | check | install | set | dispatch" ;;
esac
