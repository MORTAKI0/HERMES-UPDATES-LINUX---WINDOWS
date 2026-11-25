#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hermes Operations — Linux check/update CLI
#
# This script is an orchestrator and verifier. It does not implement a new
# updater: it discovers the existing Hermes installation, uses the official
# `hermes update` command exactly once, and verifies the result independently.
#
# Usage:
#   bash skills/hermes-linux/scripts/hermes.sh check  [--backend-url URL]
#   bash skills/hermes-linux/scripts/hermes.sh update [--backend-url URL] [--no-backup]
#
# Exit codes: 0 = requested operation proved its checks; 1 = degraded/partial/
# failed; 2 = blocked/unsafe/ambiguous. See docs/OPERATIONS_SPEC.md.
#
# Test-only environment variable (not part of the public contract):
#   HERMES_OPS_REPORT_DIR  overrides the reports/ output directory.
# ---------------------------------------------------------------------------
set -uo pipefail
# Many state globals are consumed by the report writer even if a given mode
# does not read them directly.
# shellcheck disable=SC2034

SCRIPT_VERSION="1.0.0"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
REPORT_ROOT="${HERMES_OPS_REPORT_DIR:-$REPO_ROOT/reports}"

MODE=""
BACKEND_URL_ARG=""
NO_BACKUP=0
REPORT_PATH=""
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"

TMP_RUN=$(mktemp -d "${TMPDIR:-/tmp}/hermes-ops.XXXXXX")
trap 'rm -rf "$TMP_RUN"' EXIT
CHECK_ROWS="$TMP_RUN/check_rows.md"
TIMELINE_ROWS="$TMP_RUN/timeline_rows.md"
BLOCKED_FILE="$TMP_RUN/blocked.txt"
DEGRADED_FILE="$TMP_RUN/degraded.txt"
UNVERIFIED_FILE="$TMP_RUN/unverified.txt"
CONFIRMED_FILE="$TMP_RUN/confirmed.txt"
LIKELY_FILE="$TMP_RUN/likely.txt"
UNKNOWN_FILE="$TMP_RUN/unknown.txt"
WORKS_FILE="$TMP_RUN/works.txt"
AFFECTED_FILE="$TMP_RUN/affected.txt"
WARNINGS_FILE="$TMP_RUN/warnings.txt"
: >"$CHECK_ROWS" ; : >"$TIMELINE_ROWS" ; : >"$BLOCKED_FILE"
: >"$DEGRADED_FILE" ; : >"$UNVERIFIED_FILE" ; : >"$CONFIRMED_FILE" ; : >"$LIKELY_FILE"
: >"$UNKNOWN_FILE" ; : >"$WORKS_FILE" ; : >"$AFFECTED_FILE" ; : >"$WARNINGS_FILE"

# ---------------------------------------------------------------------------
# Globals populated by discovery. Everything starts as unknown on purpose.
# ---------------------------------------------------------------------------
STATUS="UNKNOWN"
EXIT_CODE=1
FAILURE_PHASE="NONE"
SUMMARY=""
OPERATION_STARTED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OPERATION_STARTED_EPOCH=$(date +%s)
MUTATIONS="none"

OS_NAME="unknown"
HOST_NAME="unknown"
EFFECTIVE_USER="unknown"
EFFECTIVE_UID="unknown"
HERMES_BIN=""
HERMES_REAL=""
HERMES_VERSION="unknown"
HERMES_VERSION_BEFORE="unknown"
HERMES_VERSION_AFTER="not applicable"
CHECKOUT=""
INSTALL_ID="unknown"
INSTALL_KIND="unknown"
CHANNEL="unknown"
STABLE_TARGET="unknown"
STABLE_TARGET_SHA="unknown"
STABLE_TARGET_BEFORE="unknown"
STABLE_TARGET_SHA_BEFORE="unknown"
UPDATE_AVAILABLE="unknown"
UPDATE_CHECK_STATUS="not run"
UPDATE_PLAN_STATUS="not run"
UPDATE_PLAN_OUTPUT=""
PLAN_INSTALL_LINE="unknown"
PLAN_PROFILES=""
RUNNING_SERVICE_LINES=""
GIT_REMOTE="unknown"
GIT_BRANCH="unknown"
GIT_HEAD="unknown"
GIT_HEAD_BEFORE="unknown"
GIT_DIRTY="unknown"
GIT_DIRTY_LINES=""
GIT_STATUS_EXIT="not run"
GIT_INTEGRITY_OK="unknown"
CHECKOUT_OK="unknown"
PROVENANCE_OK="unknown"
DISK_FREE_MB="unknown"
DISK_USED_PCT="unknown"
MIGRATION_RISK="unknown"
MIGRATION_EVIDENCE=""
GATEWAY_UNIT=""
GATEWAY_SCOPE=""
GATEWAY_ACTIVE="unknown"
GATEWAY_SUBSTATE="unknown"
GATEWAY_PID="unknown"
GATEWAY_USER="unknown"
GATEWAY_EXEC="unknown"
SERVE_UNIT=""
SERVE_SCOPE=""
SERVE_ACTIVE="unknown"
SERVE_SUBSTATE="unknown"
SERVE_PID="unknown"
SERVE_USER="unknown"
SERVE_EXEC="unknown"
SERVE_UNIT_EXISTS="unknown"
PRE_SERVE_ACTIVE="unknown"
PRE_GATEWAY_UNIT=""
PRE_GATEWAY_SCOPE=""
PRE_GATEWAY_USER=""
PRE_GATEWAY_EXEC=""
PRE_SERVE_UNIT=""
PRE_SERVE_SCOPE=""
PRE_SERVE_USER=""
PRE_SERVE_UNIT_EXISTS="unknown"
BACKEND_READY="unknown"
LINGER="unknown"
EXPECTED_PROFILES=""
EXPECTED_PROFILE_COUNT="unknown"
REGISTERED_PROFILES=""
PARKED_PROFILES=""
STANDALONE_PROFILES=""
EXPECTED_SERVED_PROFILES=""
REGISTERED_PROFILES_BEFORE=""
PARKED_PROFILES_BEFORE=""
STANDALONE_PROFILES_BEFORE=""
SERVED_PROFILES=""
SERVED_PROFILE_COUNT="unknown"
MISSING_PROFILES=""
PROFILES_OK="unknown"
PROFILE_LIST_STATUS="not run"
BACKEND_URL=""
BACKEND_URL_SOURCE="unknown"
BACKEND_URL_DISPLAY="unknown"
HTTP_CODE="not tested"
HTTP_CONTENT_TYPE="unknown"
HTTP_PROTOCOL="unknown"
HTTP_VERSION="unknown"
HTTP_AUTH_REQUIRED="unknown"
HTTP_PROFILES=""
HTTP_OVERALL="unknown"
HTTP_CHECK="NOT_TESTED"
RECEIPT_PATH="none"
RECEIPT_FRESH="unknown"
RECEIPT_OUTCOME="unknown"
RECEIPT_FOLLOWUP_COUNT="0"
RECEIPT_FOLLOWUP_TEXT=""
RECEIPT_GATEWAY_INCOMPLETE="unknown"
RECEIPT_DESKTOP="unknown"
RECEIPT_CHECK="NOT_TESTED"
RECEIPT_CORRELATION=""
RECEIPT_KIND=""
DOCTOR_STATUS="not run"
DOCTOR_WARNINGS=""
PM_STATUS="not run"
SERVICE_JOURNAL="not collected"
UPDATE_EXIT="not run"
UPDATE_CORRELATION_ID=""
UPDATE_OUTPUT_FILE=""
UPDATE_OUTPUT_TAIL=""
UPDATE_NEEDED="unknown"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*" | sanitize_text; }
warn() { printf 'WARN: %s\n' "$*" | sanitize_text >&2; }
err()  { printf 'ERROR: %s\n' "$*" | sanitize_text >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

trim() {
  local value
  if [ "$#" -gt 0 ]; then value="$*"; else value=$(cat); fi
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

head_lines() {
  local count="$1"
  head -n "$count" 2>/dev/null || true
}

# Redact credentials, URL userinfo, query secrets and common token shapes.
sanitize_text() {
  sed -E \
    -e 's#((https?|ssh|git)://)[^/@[:space:]]+@#\1[REDACTED]@#g' \
    -e 's#([?&][^=[:space:]]+=)[^&[:space:]]+#\1[REDACTED]#g' \
    -e 's#([?&](access_token|token|api[_-]?key|apikey|key|secret|password|passwd|signature|sig|auth|code|client_secret|session|jwt)=)[^&[:space:]]+#\1[REDACTED]#gI' \
    -e 's#([Aa]uthorization:[[:space:]]*).*#\1[REDACTED]#g' \
    -e 's#(Bearer[[:space:]]+)[A-Za-z0-9._~+/-]+=*#\1[REDACTED]#g' \
    -e 's#(([Pp]assword|[Pp]asswd|[Tt]oken|[Ss]ecret|[Aa]pi[_-]?[Kk]ey|[Aa]uth[_-]?[Tt]oken|[Cc]lient[_-]?[Ss]ecret|[Ss]ession[_-]?[Tt]oken)([[:space:]]*[=:][[:space:]]*))[^[:space:]"'\'']+#\1[REDACTED]#g' \
    -e 's#(-----BEGIN [A-Z ]*PRIVATE KEY-----).*#\1[REDACTED]#g' \
    -e 's#(sk-[A-Za-z0-9_-]{12,})#[REDACTED]#g' \
    -e 's#(ghp_[A-Za-z0-9]{20,})#[REDACTED]#g' \
    -e 's#(github_pat_[A-Za-z0-9_]{20,})#[REDACTED]#g' \
    -e 's#(xox[baprs]-[A-Za-z0-9-]{10,})#[REDACTED]#g' \
    -e 's#(AKIA[0-9A-Z]{16})#[REDACTED]#g' \
    2>/dev/null || cat
}

# Sanitize and bound evidence so reports never contain raw logs or secrets.
evidence() {
  local max_lines="${1:-40}"
  local max_chars="${2:-600}"
  sanitize_text | head -n "$max_lines" | cut -c1-"$max_chars"
}

md_escape() {
  local value
  if [ "$#" -gt 0 ]; then value="$1"; else value=$(cat); fi
  printf '%s' "$value" | sanitize_text | tr '\n\r' '  ' | sed 's/|/\\|/g'
}

record_timeline() {
  local phase="$1" command="$2" status="$3" detail="$4"
  printf '| %s | `%s` | %s | %s |\n' \
    "$phase" "$(md_escape "$command")" "$(md_escape "$status")" \
    "$(md_escape "$(printf '%s' "$detail" | evidence 8 300)")" >>"$TIMELINE_ROWS"
}

record_check_row() {
  local check="$1" expected="$2" actual="$3" verdict="$4"
  printf '| %s | %s | %s | %s |\n' \
    "$(md_escape "$check")" "$(md_escape "$expected")" \
    "$(md_escape "$actual")" "$verdict" >>"$CHECK_ROWS"
}

add_blocked() {
  local phase="$1" reason="$2"
  if [ "$FAILURE_PHASE" = "NONE" ]; then FAILURE_PHASE="$phase"; fi
  printf '%s|%s\n' "$phase" "$(printf '%s' "$reason" | evidence 6 500)" >>"$BLOCKED_FILE"
  err "$reason"
}

add_degraded() {
  local phase="$1" reason="$2"
  if [ "$FAILURE_PHASE" = "NONE" ]; then FAILURE_PHASE="$phase"; fi
  printf '%s|%s\n' "$phase" "$(printf '%s' "$reason" | evidence 6 500)" >>"$DEGRADED_FILE"
  warn "$reason"
}

# Essential evidence was not obtained. This is weaker than a failure but it is
# not healthy: it prevents HEALTHY without inventing a service failure.
add_unverified() {
  local phase="$1" reason="$2"
  if [ "$FAILURE_PHASE" = "NONE" ]; then FAILURE_PHASE="$phase"; fi
  printf '%s|%s\n' "$phase" "$(printf '%s' "$reason" | evidence 6 500)" >>"$UNVERIFIED_FILE"
  warn "$reason"
}

add_confirmed() { printf -- '- %s\n' "$(printf '%s' "$*" | evidence 4 500)" >>"$CONFIRMED_FILE"; }
add_likely()    { printf -- '- %s\n' "$(printf '%s' "$*" | evidence 4 500)" >>"$LIKELY_FILE"; }
add_unknown()   { printf -- '- %s\n' "$(printf '%s' "$*" | evidence 4 500)" >>"$UNKNOWN_FILE"; }
add_works()     { printf -- '- %s\n' "$(printf '%s' "$*" | evidence 4 500)" >>"$WORKS_FILE"; }
add_affected()  { printf -- '- %s\n' "$(printf '%s' "$*" | evidence 4 500)" >>"$AFFECTED_FILE"; }
add_warning()   { printf -- '- %s\n' "$(printf '%s' "$*" | evidence 4 500)" >>"$WARNINGS_FILE"; }

count_lines() {
  local file="$1"
  if [ -s "$file" ]; then wc -l <"$file" | tr -d ' '; else printf '0'; fi
}

# Run a command and capture merged output. Timeout 0 means no timeout.
RUN_STATUS=0
RUN_OUTPUT=""
capture() {
  local timeout_s="$1" ; shift
  local out="$TMP_RUN/cmd.$$.out"
  if [ "$timeout_s" -gt 0 ]; then
    timeout "$timeout_s" "$@" >"$out" 2>&1
    RUN_STATUS=$?
  else
    "$@" >"$out" 2>&1
    RUN_STATUS=$?
  fi
  RUN_OUTPUT=$(cat "$out" 2>/dev/null)
  return 0
}

version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

extract_version() {
  grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null | head -n 1 | sed 's/^v//' || true
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  hermes.sh check  [--backend-url URL]
  hermes.sh update [--backend-url URL] [--no-backup]

Modes:
  check   Read-only inspection. Never updates, restarts, migrates or changes config.
  update  Preflight, one official stable update, verified backend refresh, verification.

Exit codes: 0 success, 1 degraded/partial/failed, 2 blocked/unsafe/ambiguous.
USAGE
}

parse_args() {
  if [ "$#" -lt 1 ]; then
    usage >&2
    exit 2
  fi
  case "$1" in
    check|update) MODE="$1" ; shift ;;
    -h|--help|help) usage ; exit 0 ;;
    *) err "Unknown action: $1" ; usage >&2 ; exit 2 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --backend-url)
        [ "$#" -ge 2 ] || { err "--backend-url requires a value" ; exit 2 ; }
        BACKEND_URL_ARG="$2" ; shift 2 ;;
      --backend-url=*)
        BACKEND_URL_ARG="${1#*=}" ; shift ;;
      --no-backup)
        NO_BACKUP=1 ; shift ;;
      -h|--help)
        usage ; exit 0 ;;
      *)
        err "Unknown argument: $1" ; usage >&2 ; exit 2 ;;
    esac
  done
  if [ "$MODE" = "check" ] && [ "$NO_BACKUP" -eq 1 ]; then
    err "--no-backup is only meaningful with update"
    exit 2
  fi
  if [ -n "$BACKEND_URL_ARG" ]; then
    case "$BACKEND_URL_ARG" in
      http://*|https://*) ;;
      *) err "--backend-url must start with http:// or https://" ; exit 2 ;;
    esac
    case "$BACKEND_URL_ARG" in
      *"@"*) err "--backend-url must not contain credentials (userinfo)" ; exit 2 ;;
      *"?"*|*"#"*) err "--backend-url must not contain a query string or fragment" ; exit 2 ;;
    esac
    BACKEND_URL_ARG="${BACKEND_URL_ARG%/}"
  fi
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------
discover_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME="${PRETTY_NAME:-${NAME:-Linux}}"
  else
    OS_NAME=$(uname -s 2>/dev/null || echo unknown)
  fi
  HOST_NAME=$(hostname -s 2>/dev/null || printf 'unknown')
  EFFECTIVE_USER=$(id -un 2>/dev/null || printf 'unknown')
  EFFECTIVE_UID=$(id -u 2>/dev/null || printf 'unknown')
}

discover_hermes() {
  HERMES_BIN=$(command -v hermes 2>/dev/null || true)
  if [ -z "$HERMES_BIN" ]; then
    add_blocked PRECHECK "hermes executable not found on PATH for user $EFFECTIVE_USER"
    add_unknown "Intended installation path or launcher; no hermes command is resolvable"
    record_check_row "Hermes executable" "resolvable on PATH" "not found" "FAIL"
    return 1
  fi
  HERMES_REAL=$(readlink -f "$HERMES_BIN" 2>/dev/null || printf '%s' "$HERMES_BIN")
  record_check_row "Hermes executable" "resolvable on PATH" "$HERMES_BIN -> $HERMES_REAL" "PASS"

  capture 30 "$HERMES_BIN" --version
  local version_out="$RUN_OUTPUT"
  if [ "$RUN_STATUS" -ne 0 ]; then
    add_blocked PRECHECK "hermes --version failed (exit $RUN_STATUS)"
    record_check_row "hermes --version" "exit 0" "exit $RUN_STATUS: $(printf '%s' "$version_out" | evidence 3 200)" "FAIL"
  else
    HERMES_VERSION=$(printf '%s\n' "$version_out" | extract_version)
    [ -n "$HERMES_VERSION" ] || HERMES_VERSION="unknown"
    [ "$HERMES_VERSION_BEFORE" = unknown ] && HERMES_VERSION_BEFORE="$HERMES_VERSION"
    CHECKOUT=$(printf '%s\n' "$version_out" | sed -n 's/^Install directory:[[:space:]]*//p' | head -n 1)
    INSTALL_KIND=$(printf '%s\n' "$version_out" | sed -n 's/^Install method:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)
    CHANNEL=$(printf '%s\n' "$version_out" | sed -n 's/.*·[[:space:]]*\(stable\|canary\|main\)[[:space:]]*·.*/\1/p' | head -n 1)
    [ -n "$INSTALL_KIND" ] || INSTALL_KIND="unknown"
    [ -n "$CHANNEL" ] || CHANNEL="unknown"
    record_timeline "L1" "hermes --version" "exit $RUN_STATUS" "$(printf '%s' "$version_out" | head -n 1)"
    record_check_row "Installed version / channel" "discoverable stable install" "v$HERMES_VERSION · $CHANNEL · $INSTALL_KIND" "PASS"
  fi

  capture 30 "$HERMES_BIN" update --install-id
  if [ "$RUN_STATUS" -eq 0 ]; then
    INSTALL_ID=$(printf '%s\n' "$RUN_OUTPUT" | head -n 1)
    [ -n "$INSTALL_ID" ] || INSTALL_ID="unknown"
    record_timeline "L1" "hermes update --install-id" "exit 0" "install id $INSTALL_ID"
  else
    record_timeline "L1" "hermes update --install-id" "exit $RUN_STATUS" "$(printf '%s' "$RUN_OUTPUT" | evidence 2 200)"
  fi

  if [ -z "$CHECKOUT" ] || [ ! -d "$CHECKOUT" ]; then
    add_blocked PRECHECK "Hermes install directory could not be confirmed (got '$CHECKOUT')"
    record_check_row "Source checkout" "existing directory" "$CHECKOUT" "FAIL"
    return 1
  fi
  CHECKOUT=$(cd "$CHECKOUT" 2>/dev/null && pwd || printf '%s' "$CHECKOUT")
  record_check_row "Source checkout" "existing directory" "$CHECKOUT" "PASS"
  return 0
}

discover_git() {
  [ -n "$CHECKOUT" ] || return 0
  local integrity_ok="yes"
  capture 30 git -C "$CHECKOUT" rev-parse --is-inside-work-tree
  if [ "$RUN_STATUS" -ne 0 ] || ! printf '%s' "$RUN_OUTPUT" | grep -Fxq true; then
    GIT_INTEGRITY_OK="no"
    add_blocked PRECHECK "install directory '$CHECKOUT' is not a readable Git worktree"
    record_check_row "Git worktree" "readable official checkout" "not a Git worktree" "FAIL"
    return 0
  fi

  capture 30 git -C "$CHECKOUT" remote get-url origin
  if [ "$RUN_STATUS" -eq 0 ] && [ -n "$RUN_OUTPUT" ]; then
    GIT_REMOTE=$(printf '%s\n' "$RUN_OUTPUT" | head -n 1)
  else
    GIT_REMOTE="unknown"
    integrity_ok="no"
    add_degraded PRECHECK "origin remote could not be read (git exit $RUN_STATUS)"
  fi

  capture 30 git -C "$CHECKOUT" symbolic-ref --short -q HEAD
  case "$RUN_STATUS" in
    0) GIT_BRANCH=$(printf '%s\n' "$RUN_OUTPUT" | head -n 1); [ -n "$GIT_BRANCH" ] || { GIT_BRANCH="unknown"; integrity_ok="no"; } ;;
    1) GIT_BRANCH="detached" ;;
    *) GIT_BRANCH="unknown"; integrity_ok="no"; add_degraded PRECHECK "checkout branch could not be read (git exit $RUN_STATUS)" ;;
  esac

  capture 30 git -C "$CHECKOUT" rev-parse HEAD
  if [ "$RUN_STATUS" -eq 0 ] && [ -n "$RUN_OUTPUT" ]; then
    GIT_HEAD=$(printf '%s\n' "$RUN_OUTPUT" | head -n 1)
  else
    GIT_HEAD="unknown"
    integrity_ok="no"
    add_degraded PRECHECK "HEAD revision could not be read (git exit $RUN_STATUS)"
  fi

  capture 60 git -C "$CHECKOUT" status --porcelain --untracked-files=normal
  GIT_STATUS_EXIT="$RUN_STATUS"
  if [ "$RUN_STATUS" -ne 0 ]; then
    GIT_DIRTY="unknown"
    GIT_DIRTY_LINES=""
    integrity_ok="no"
    add_degraded PRECHECK "git status failed (exit $RUN_STATUS); repository cleanliness cannot be proven"
    add_confirmed "Repository status could not be read; it is not treated as clean"
  else
    GIT_DIRTY_LINES=$(printf '%s\n' "$RUN_OUTPUT" | sed '/^[[:space:]]*$/d' | head -n 8)
    if [ -n "$GIT_DIRTY_LINES" ]; then
      GIT_DIRTY="yes"
    else
      GIT_DIRTY="no"
    fi
  fi

  case "$GIT_REMOTE" in
    https://github.com/NousResearch/hermes-agent|https://github.com/NousResearch/hermes-agent.git|git@github.com:NousResearch/hermes-agent.git|git@github.com:NousResearch/hermes-agent|ssh://git@github.com/NousResearch/hermes-agent|ssh://git@github.com/NousResearch/hermes-agent.git)
      PROVENANCE_OK="yes" ;;
    *) PROVENANCE_OK="no" ;;
  esac
  case "$GIT_BRANCH" in
    detached|main|master) CHECKOUT_OK="yes" ;;
    *) CHECKOUT_OK="no" ;;
  esac
  [ "$integrity_ok" = yes ] && GIT_INTEGRITY_OK="yes" || GIT_INTEGRITY_OK="no"

  local worktree_verdict="PASS"
  [ "$GIT_DIRTY" = yes ] && worktree_verdict="FAIL"
  [ "$GIT_DIRTY" = unknown ] && worktree_verdict="UNKNOWN"
  record_check_row "Git provenance" "official NousResearch/hermes-agent" "$GIT_REMOTE" \
    "$([ "$PROVENANCE_OK" = yes ] && echo PASS || echo FAIL)"
  record_check_row "Git worktree" "clean, stable-compatible branch" \
    "$GIT_BRANCH @ $GIT_HEAD; dirty=$GIT_DIRTY; integrity=$GIT_INTEGRITY_OK" "$worktree_verdict"
  record_timeline "L1" "git status" "exit $GIT_STATUS_EXIT" "remote=$GIT_REMOTE branch=$GIT_BRANCH head=$GIT_HEAD dirty=$GIT_DIRTY integrity=$GIT_INTEGRITY_OK"
  if [ "$GIT_DIRTY" = yes ]; then
    add_degraded PRECHECK "checkout has uncommitted changes (update would be unsafe; files were not touched)"
    add_confirmed "Checkout is dirty. First entries: $(printf '%s' "$GIT_DIRTY_LINES" | tr '\n' '; ' | evidence 2 400)"
  fi
  if [ "$GIT_INTEGRITY_OK" != yes ]; then
    add_degraded PRECHECK "Git repository integrity/provenance could not be fully proven"
  fi
  if [ "$PROVENANCE_OK" != yes ]; then
    add_degraded PRECHECK "origin remote is not the official NousResearch/hermes-agent repository"
  fi
  if [ "$CHECKOUT_OK" != yes ]; then
    add_degraded PRECHECK "checkout is on custom branch '$GIT_BRANCH'; a stable update could switch or discard it"
  fi
}

discover_update_target() {
  [ -n "$HERMES_BIN" ] || return 0
  capture 120 "$HERMES_BIN" update --check
  UPDATE_CHECK_STATUS="exit $RUN_STATUS"
  local out="$RUN_OUTPUT"
  if [ "$RUN_STATUS" -ne 0 ]; then
    add_degraded PRECHECK "hermes update --check failed (exit $RUN_STATUS)"
    record_check_row "Upstream stable target" "readable" "exit $RUN_STATUS" "FAIL"
  else
    local target_line
    target_line=$(printf '%s\n' "$out" | grep -iE 'available|selected release' | head -n 1)
    if [ -n "$target_line" ]; then
      STABLE_TARGET=$(printf '%s' "$target_line" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1 | tr -d 'v')
    else
      STABLE_TARGET=$(printf '%s\n' "$out" | extract_version)
    fi
    [ -n "$STABLE_TARGET" ] || STABLE_TARGET="unknown"
    STABLE_TARGET_SHA=$(printf '%s\n' "${target_line:-$out}" | sed -n 's/.*(\([0-9a-f]\{7,40\}\)).*/\1/p' | head -n 1)
    [ -n "$STABLE_TARGET_SHA" ] || STABLE_TARGET_SHA="unknown"
    local parsed_channel
    parsed_channel=$(printf '%s\n' "$out" | sed -n 's/.*Update channel:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' | head -n 1)
    [ -n "$parsed_channel" ] && CHANNEL="$parsed_channel"
    if printf '%s\n' "$out" | grep -qiE 'no update|up[ -]?to[ -]?date|already current|latest version installed'; then
      UPDATE_AVAILABLE="no"
    elif [ "$STABLE_TARGET" != unknown ]; then
      if version_gt "$HERMES_VERSION" "$STABLE_TARGET"; then
        UPDATE_AVAILABLE="downgrade"
      elif [ "$HERMES_VERSION" = "$STABLE_TARGET" ]; then
        UPDATE_AVAILABLE="no"
      else
        UPDATE_AVAILABLE="yes"
      fi
    else
      UPDATE_AVAILABLE="unknown"
    fi
    record_timeline "L1" "hermes update --check" "exit 0" "$(printf '%s' "$out" | head -n 3)"
    record_check_row "Upstream stable release" "readable stable channel" \
      "$UPDATE_CHECK_STATUS; installed v$HERMES_VERSION; available v$STABLE_TARGET (${STABLE_TARGET_SHA:-unknown}); update=$UPDATE_AVAILABLE" "INFO"
    if [ "$UPDATE_AVAILABLE" = downgrade ]; then
      add_degraded PRECHECK "stable target v$STABLE_TARGET is older than installed v$HERMES_VERSION (downgrade risk)"
    fi
  fi
  if [ "$CHANNEL" = unknown ]; then
    add_degraded PRECHECK "update channel could not be discovered"
  fi
  if [ "$INSTALL_KIND" != git ]; then
    add_degraded PRECHECK "install method '$INSTALL_KIND' is not a managed git source checkout"
  fi
}

discover_disk() {
  [ -n "$CHECKOUT" ] || return 0
  local line
  line=$(df -Pm "$CHECKOUT" 2>/dev/null | awk 'NR==2 {print $4" "$5}')
  DISK_FREE_MB=$(printf '%s' "$line" | awk '{print $1}')
  DISK_USED_PCT=$(printf '%s' "$line" | awk '{print $2}')
  [ -n "$DISK_FREE_MB" ] || DISK_FREE_MB="unknown"
  [ -n "$DISK_USED_PCT" ] || DISK_USED_PCT="unknown"
  record_check_row "Free disk for updater" ">= ${HERMES_OPS_MIN_FREE_MB:-2048} MiB" \
    "${DISK_FREE_MB} MiB free (${DISK_USED_PCT} used)" \
    "$([ "$DISK_FREE_MB" != unknown ] && [ "$DISK_FREE_MB" -ge "${HERMES_OPS_MIN_FREE_MB:-2048}" ] && echo PASS || echo FAIL)"
  if [ "$DISK_FREE_MB" != unknown ] && [ "$DISK_FREE_MB" -lt "${HERMES_OPS_MIN_FREE_MB:-2048}" ]; then
    add_degraded PRECHECK "only ${DISK_FREE_MB} MiB free; updater needs at least ${HERMES_OPS_MIN_FREE_MB:-2048} MiB"
  fi
  if [ "$DISK_USED_PCT" != unknown ]; then
    local pct="${DISK_USED_PCT%\%}"
    if [ "${pct:-0}" -ge 90 ]; then
      add_warning "Filesystem is ${DISK_USED_PCT} used (${DISK_FREE_MB} MiB free); monitor space during update"
    fi
  fi
}

discover_update_plan() {
  [ -n "$HERMES_BIN" ] || return 0
  capture 90 "$HERMES_BIN" update --plan
  UPDATE_PLAN_STATUS="exit $RUN_STATUS"
  UPDATE_PLAN_OUTPUT="$RUN_OUTPUT"
  if [ "$RUN_STATUS" -ne 0 ]; then
    add_degraded PRECHECK "hermes update --plan failed (exit $RUN_STATUS)"
    record_check_row "Update plan" "readable" "exit $RUN_STATUS" "FAIL"
    return 0
  fi
  PLAN_INSTALL_LINE=$(printf '%s\n' "$RUN_OUTPUT" | grep -m1 -E '^[[:space:]]*Install:' || true)
  PLAN_PROFILES=$(printf '%s\n' "$RUN_OUTPUT" | sed -n 's/^[[:space:]]*Profiles:[[:space:]]*//p' | head -n 1)
  RUNNING_SERVICE_LINES=$(printf '%s\n' "$RUN_OUTPUT" | grep -E '^[[:space:]]*[•]|^[[:space:]]*restart:' || true)
  record_timeline "L1" "hermes update --plan" "exit 0" \
    "$(printf '%s\n%s' "$PLAN_INSTALL_LINE" "$(printf '%s' "$RUNNING_SERVICE_LINES" | tr '\n' ' ')" | evidence 6 500)"
  record_check_row "Update plan" "read-only plan available" \
    "$UPDATE_PLAN_STATUS; $(trim "$PLAN_INSTALL_LINE")" "PASS"
  if [ -n "$PLAN_PROFILES" ]; then
    EXPECTED_PROFILES=$(printf '%s' "$PLAN_PROFILES" | tr -d ' ' )
  fi
}

discover_migration_risk() {
  [ -n "$HERMES_BIN" ] || return 0
  capture 120 "$HERMES_BIN" gateway migrate --multiplex --dry-run
  local out="$RUN_OUTPUT"
  MIGRATION_EVIDENCE=$(printf '%s' "$out" | evidence 12 400)
  if [ "$RUN_STATUS" -ne 0 ]; then
    MIGRATION_RISK="unknown"
    add_degraded PRECHECK "gateway migrate --multiplex --dry-run failed (exit $RUN_STATUS); topology change risk cannot be excluded"
    record_check_row "Multiplex topology" "dry run readable, no unapproved fold" "exit $RUN_STATUS" "FAIL"
    return 0
  fi
  # "nothing changed" is only the dry-run banner; it is not proof that the
  # topology is already multiplexed. Require the explicit already-multiplexed
  # statement before declaring the topology safe.
  if printf '%s\n' "$out" | grep -qiE 'already multiplexing|already multiplexed|no migration (needed|required)'; then
    MIGRATION_RISK="no"
  elif printf '%s\n' "$out" | grep -qiE 'would migrate|will migrate|fold|convert|→|migration plan'; then
    MIGRATION_RISK="yes"
    add_degraded PRECHECK "gateway dry run indicates a planned multiplex topology change; update requires explicit owner approval"
  else
    MIGRATION_RISK="unknown"
    add_degraded PRECHECK "gateway dry run output did not clearly exclude a topology change"
  fi
  record_check_row "Multiplex topology" "already multiplexed; no implicit fold" \
    "migration_risk=$MIGRATION_RISK" "$([ "$MIGRATION_RISK" = no ] && echo PASS || echo FAIL)"
  record_timeline "L1" "hermes gateway migrate --multiplex --dry-run" "exit $RUN_STATUS" "$MIGRATION_EVIDENCE"
}

# systemd unit discovery ----------------------------------------------------
SYS_UNITS=""
USER_UNITS=""

systemctl_for() {
  local scope="$1" ; shift
  if [ "$scope" = user ]; then
    systemctl --user "$@"
  else
    systemctl "$@"
  fi
}

unit_show() {
  local scope="$1" unit="$2" field="$3"
  systemctl_for "$scope" show "$unit" -p "$field" --value 2>/dev/null | head -n 1 || true
}

discover_unit_lists() {
  SYS_UNITS=$(systemctl list-unit-files --no-legend 'hermes*' 2>/dev/null | awk '{print $1}')
  if systemctl --user list-unit-files --no-legend 'hermes*' >/dev/null 2>&1; then
    USER_UNITS=$(systemctl --user list-unit-files --no-legend 'hermes*' 2>/dev/null | awk '{print $1}')
  else
    USER_UNITS=""
  fi
}

# Find the unit for a role by exact name first, then by a conservative role
# heuristic. A "Desktop Remote Gateway" unit must never be mistaken for the
# messaging gateway merely because its description contains "Gateway".
role_matches() {
  local role="$1" unit="$2" desc="$3" exec="$4"
  if [ "$role" = gateway ]; then
    case "$unit" in *gateway*) return 0 ;; esac
    case "$desc" in
      *"Hermes Agent Gateway"*) return 0 ;;
      *"Desktop Remote Gateway"*|*[Dd]ashboard*|*serve*) return 1 ;;
      *[Gg]ateway*) return 0 ;;
    esac
    return 1
  fi
  case "$unit" in *serve*|*dashboard*) return 0 ;; esac
  case "$desc" in *"Desktop Remote Gateway"*|*[Dd]ashboard*) return 0 ;; esac
  case "$exec" in *" dashboard "*|*" serve "*) return 0 ;; esac
  return 1
}

find_role_units() {
  local role="$1" exact="$2" found_sys="" found_user="" sys_all="" user_all="" u desc exec count
  if printf '%s\n' "$SYS_UNITS" | grep -Fxq "$exact"; then found_sys="$exact"; fi
  if printf '%s\n' "$USER_UNITS" | grep -Fxq "$exact"; then found_user="$exact"; fi
  if [ -z "$found_sys" ]; then
    for u in $SYS_UNITS; do
      [ -n "$u" ] || continue
      desc=$(unit_show system "$u" Description)
      exec=$(unit_show system "$u" ExecStart)
      if role_matches "$role" "$u" "$desc" "$exec"; then sys_all="${sys_all}${sys_all:+,}$u"; fi
    done
    count=$(printf '%s' "$sys_all" | awk -F, 'NF && $0!="" {print NF}')
    [ -n "$count" ] || count=0
    if [ "$count" -eq 1 ]; then found_sys="$sys_all"; fi
    if [ "$count" -gt 1 ]; then ROLE_AMBIGUOUS="system:$sys_all"; fi
  fi
  if [ -z "$found_user" ]; then
    for u in $USER_UNITS; do
      [ -n "$u" ] || continue
      desc=$(unit_show user "$u" Description)
      exec=$(unit_show user "$u" ExecStart)
      if role_matches "$role" "$u" "$desc" "$exec"; then user_all="${user_all}${user_all:+,}$u"; fi
    done
    count=$(printf '%s' "$user_all" | awk -F, 'NF && $0!="" {print NF}')
    [ -n "$count" ] || count=0
    if [ "$count" -eq 1 ]; then found_user="$user_all"; fi
    if [ "$count" -gt 1 ]; then ROLE_AMBIGUOUS="user:$user_all"; fi
  fi
  ROLE_SYS="$found_sys"
  ROLE_USER="$found_user"
}

discover_units() {
  if [ ! -d /run/systemd/system ]; then
    add_blocked PRECHECK "systemd is not running on this host (missing /run/systemd/system)"
    record_check_row "systemd" "running" "not running" "FAIL"
    return 0
  fi
  discover_unit_lists
  ROLE_AMBIGUOUS=""
  find_role_units gateway "hermes-gateway.service"
  local gw_sys="$ROLE_SYS" gw_user="$ROLE_USER" gw_ambiguous="$ROLE_AMBIGUOUS"
  ROLE_AMBIGUOUS=""
  find_role_units serve "hermes-serve.service"
  local sv_sys="$ROLE_SYS" sv_user="$ROLE_USER" sv_ambiguous="$ROLE_AMBIGUOUS"

  if [ -n "$gw_ambiguous" ]; then
    add_blocked PRECHECK "multiple gateway candidates in one scope ($gw_ambiguous); refuse to guess"
    record_check_row "Gateway supervisor" "one unambiguous unit" "$gw_ambiguous" "FAIL"
  fi
  if [ -n "$sv_ambiguous" ]; then
    add_blocked PRECHECK "multiple Desktop backend candidates in one scope ($sv_ambiguous); refuse to guess"
    record_check_row "Backend supervisor" "one unambiguous unit" "$sv_ambiguous" "FAIL"
  fi

  if [ -n "$gw_sys" ] && [ -n "$gw_user" ]; then
    add_blocked PRECHECK "gateway service exists in both system ('$gw_sys') and user ('$gw_user') scopes"
    record_check_row "Gateway supervisor" "one unambiguous scope" "system=$gw_sys user=$gw_user" "FAIL"
    return 0
  fi
  if [ -n "$gw_sys" ]; then GATEWAY_SCOPE=system; GATEWAY_UNIT="$gw_sys";
  elif [ -n "$gw_user" ]; then GATEWAY_SCOPE=user; GATEWAY_UNIT="$gw_user";
  else
    add_blocked PRECHECK "no Hermes gateway systemd unit could be discovered"
    record_check_row "Gateway supervisor" "discovered unit" "none" "FAIL"
  fi

  if [ -n "$sv_sys" ] && [ -n "$sv_user" ]; then
    add_blocked PRECHECK "Desktop backend exists in both system ('$sv_sys') and user ('$sv_user') scopes"
    record_check_row "Backend supervisor" "one unambiguous scope" "system=$sv_sys user=$sv_user" "FAIL"
    return 0
  fi
  if [ -n "$sv_sys" ]; then SERVE_SCOPE=system; SERVE_UNIT="$sv_sys"; SERVE_UNIT_EXISTS=yes;
  elif [ -n "$sv_user" ]; then SERVE_SCOPE=user; SERVE_UNIT="$sv_user"; SERVE_UNIT_EXISTS=yes;
  else SERVE_UNIT_EXISTS=no;
  fi

  if [ -n "$GATEWAY_UNIT" ]; then
    GATEWAY_ACTIVE=$(unit_show "$GATEWAY_SCOPE" "$GATEWAY_UNIT" ActiveState)
    GATEWAY_SUBSTATE=$(unit_show "$GATEWAY_SCOPE" "$GATEWAY_UNIT" SubState)
    GATEWAY_PID=$(unit_show "$GATEWAY_SCOPE" "$GATEWAY_UNIT" MainPID)
    GATEWAY_USER=$(unit_show "$GATEWAY_SCOPE" "$GATEWAY_UNIT" User)
    GATEWAY_EXEC=$(unit_show "$GATEWAY_SCOPE" "$GATEWAY_UNIT" ExecStart)
    if [ -z "$GATEWAY_USER" ] && [ "$GATEWAY_SCOPE" = user ]; then GATEWAY_USER="$EFFECTIVE_USER"; fi
    [ -n "$GATEWAY_USER" ] || GATEWAY_USER="root (systemd default)"
    local gateway_verdict="FAIL"
    if [ "$GATEWAY_ACTIVE" = active ] && [ -n "$GATEWAY_PID" ] && [ "$GATEWAY_PID" != "0" ] && [ "$GATEWAY_PID" != "unknown" ]; then
      gateway_verdict="PASS"
    fi
    record_check_row "Gateway service" "active/running" \
      "$GATEWAY_UNIT ($GATEWAY_SCOPE) $GATEWAY_ACTIVE/$GATEWAY_SUBSTATE pid=${GATEWAY_PID:-none} user=$GATEWAY_USER" \
      "$gateway_verdict"
    if [ "$GATEWAY_ACTIVE" != active ]; then
      add_degraded GATEWAY "gateway unit $GATEWAY_UNIT is ${GATEWAY_ACTIVE:-unknown}/${GATEWAY_SUBSTATE:-unknown}"
    elif [ -z "$GATEWAY_PID" ] || [ "$GATEWAY_PID" = "0" ] || [ "$GATEWAY_PID" = "unknown" ]; then
      add_degraded GATEWAY "gateway unit $GATEWAY_UNIT is active but its MainPID is unavailable"
    fi
    local gw_user_effective="${GATEWAY_USER%% *}"
    if [ "$gw_user_effective" != "$EFFECTIVE_USER" ]; then
      add_blocked PRECHECK "gateway unit runs as '$gw_user_effective' but this script runs as '$EFFECTIVE_USER'"
    fi
  fi

  if [ "$SERVE_UNIT_EXISTS" = yes ]; then
    SERVE_ACTIVE=$(unit_show "$SERVE_SCOPE" "$SERVE_UNIT" ActiveState)
    SERVE_SUBSTATE=$(unit_show "$SERVE_SCOPE" "$SERVE_UNIT" SubState)
    SERVE_PID=$(unit_show "$SERVE_SCOPE" "$SERVE_UNIT" MainPID)
    SERVE_USER=$(unit_show "$SERVE_SCOPE" "$SERVE_UNIT" User)
    SERVE_EXEC=$(unit_show "$SERVE_SCOPE" "$SERVE_UNIT" ExecStart)
    if [ -z "$SERVE_USER" ] && [ "$SERVE_SCOPE" = user ]; then SERVE_USER="$EFFECTIVE_USER"; fi
    [ -n "$SERVE_USER" ] || SERVE_USER="root (systemd default)"
    local serve_verdict="NOT_TESTED"
    if [ "$SERVE_ACTIVE" = active ] && [ -n "$SERVE_PID" ] && [ "$SERVE_PID" != "0" ] && [ "$SERVE_PID" != "unknown" ]; then
      serve_verdict="PASS"
    elif [ "$SERVE_ACTIVE" = active ] || [ "$SERVE_ACTIVE" = inactive ]; then
      serve_verdict="FAIL"
    fi
    record_check_row "Desktop backend service" "active/running" \
      "$SERVE_UNIT ($SERVE_SCOPE) $SERVE_ACTIVE/$SERVE_SUBSTATE pid=${SERVE_PID:-none} user=$SERVE_USER" \
      "$serve_verdict"
    if [ "$SERVE_ACTIVE" != active ]; then
      add_degraded SERVE_BACKEND "Desktop backend unit $SERVE_UNIT is ${SERVE_ACTIVE:-unknown}/${SERVE_SUBSTATE:-unknown}"
    elif [ -z "$SERVE_PID" ] || [ "$SERVE_PID" = "0" ] || [ "$SERVE_PID" = "unknown" ]; then
      add_degraded SERVE_BACKEND "Desktop backend unit $SERVE_UNIT is active but its MainPID is unavailable"
    fi
    local sv_user_effective="${SERVE_USER%% *}"
    if [ "$sv_user_effective" != "$EFFECTIVE_USER" ]; then
      add_blocked PRECHECK "backend unit runs as '$sv_user_effective' but this script runs as '$EFFECTIVE_USER'"
    fi
  else
    add_unknown "No separately supervised Desktop backend unit was discovered; remote Desktop health cannot be inferred"
    record_check_row "Desktop backend service" "discovered unit" "none" "NOT_TESTED"
  fi

  # Verify both units execute the discovered checkout, not a different one.
  local role unit scope exec path resolved belongs
  for role in gateway serve; do
    if [ "$role" = gateway ]; then unit="$GATEWAY_UNIT"; scope="$GATEWAY_SCOPE"; exec="$GATEWAY_EXEC";
    else unit="$SERVE_UNIT"; scope="$SERVE_SCOPE"; exec="$SERVE_EXEC"; fi
    [ -n "$unit" ] || continue
    path=$(printf '%s' "$exec" | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n 1)
    [ -n "$path" ] || path="unknown"
    resolved=$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")
    belongs="no"
    case "$resolved" in "$CHECKOUT"/*) belongs="yes" ;; esac
    if [ "$belongs" != yes ] && [ -f "$path" ] && head -n 30 "$path" 2>/dev/null | grep -Fq "$CHECKOUT"; then
      belongs="yes"
    fi
    if [ "$belongs" != yes ]; then
      add_blocked PRECHECK "$role unit $unit ExecStart ('$path') does not resolve to the discovered checkout $CHECKOUT"
      record_check_row "$role checkout binding" "ExecStart uses $CHECKOUT" "path=$path resolved=$resolved" "FAIL"
    else
      record_check_row "$role checkout binding" "ExecStart uses $CHECKOUT" "path=$path" "PASS"
    fi
  done

  if [ "$GATEWAY_SCOPE" = user ]; then
    LINGER=$(loginctl show-user "$EFFECTIVE_USER" -p Linger --value 2>/dev/null | head -n 1 || true)
    [ -n "$LINGER" ] || LINGER="unknown"
    record_check_row "systemd linger" "enabled for user-scope gateway" "Linger=$LINGER" \
      "$([ "$LINGER" = yes ] && echo PASS || echo FAIL)"
    if [ "$LINGER" != yes ]; then
      add_degraded GATEWAY "user-scope gateway without linger may not survive logout/reboot"
    fi
  else
    LINGER="not applicable (system scope)"
  fi
}

recompute_profile_counts() {
  local p expected_n=0 served_n=0 missing=""
  for p in $(printf '%s' "$EXPECTED_PROFILES" | tr ',' ' '); do
    [ -n "$p" ] || continue
    expected_n=$((expected_n + 1))
    if ! printf '%s\n' "$SERVED_PROFILES" | tr ',' '\n' | grep -Fxq "$p"; then
      missing="${missing}${missing:+,}$p"
    fi
  done
  for p in $(printf '%s' "$SERVED_PROFILES" | tr ',' ' '); do
    [ -n "$p" ] && served_n=$((served_n + 1))
  done
  EXPECTED_PROFILE_COUNT="$expected_n"
  SERVED_PROFILE_COUNT="$served_n"
  MISSING_PROFILES="$missing"
  if [ "$expected_n" -eq 0 ]; then
    PROFILES_OK="unknown"
  elif [ -z "$SERVED_PROFILES" ]; then
    PROFILES_OK="unknown"
  elif [ -z "$missing" ]; then
    PROFILES_OK="yes"
  else
    PROFILES_OK="no"
  fi
}

discover_profiles() {
  [ -n "$HERMES_BIN" ] || return 0

  capture 90 "$HERMES_BIN" profile list
  PROFILE_LIST_STATUS="exit $RUN_STATUS"
  local registered="" served="" parked="" standalone=""
  if [ "$RUN_STATUS" -eq 0 ]; then
    registered=$(printf '%s\n' "$RUN_OUTPUT" | awk '
      /^[[:space:]]*[◆*]?[A-Za-z0-9_.-]+[[:space:]]/ {
        name=$1; sub(/^[◆*]+/, "", name);
        if (name == "Profile") next;
        if (NF < 3) next;
        if (name ~ /:$/) next;
        if ($0 ~ /Model|Gateway|Alias|Distribution|─/) next;
        if (tolower($0) ~ /deleted/) next;
        print name
      }' | sort -u | tr '\n' ',' | sed 's/,$//')
    served=$(printf '%s\n' "$RUN_OUTPUT" | awk '
      /^[[:space:]]*[◆*]?[A-Za-z0-9_.-]+[[:space:]]/ {
        name=$1; sub(/^[◆*]+/, "", name);
        if (name == "Profile") next;
        if (NF < 3) next;
        if (name ~ /:$/) next;
        if ($0 ~ /Model|Gateway|Alias|Distribution|─/) next;
        if (tolower($0) ~ /deleted/) next;
        if (tolower($0) ~ /parked/) next;
        if (tolower($0) ~ /standalone/) next;
        if ($0 ~ /running|connected/) print name
      }' | sort -u | tr '\n' ',' | sed 's/,$//')
    parked=$(printf '%s\n' "$RUN_OUTPUT" | awk '
      /^[[:space:]]*[◆*]?[A-Za-z0-9_.-]+[[:space:]]/ {
        name=$1; sub(/^[◆*]+/, "", name);
        if (name == "Profile") next;
        if (NF < 3) next;
        if (name ~ /:$/) next;
        if ($0 ~ /Model|Gateway|Alias|Distribution|─/) next;
        if (tolower($0) ~ /deleted/) next;
        if (tolower($0) ~ /parked/) print name
      }' | sort -u | tr '\n' ',' | sed 's/,$//')
    standalone=$(printf '%s\n' "$RUN_OUTPUT" | awk '
      /^[[:space:]]*[◆*]?[A-Za-z0-9_.-]+[[:space:]]/ {
        name=$1; sub(/^[◆*]+/, "", name);
        if (name == "Profile") next;
        if (NF < 3) next;
        if (name ~ /:$/) next;
        if ($0 ~ /Model|Gateway|Alias|Distribution|─/) next;
        if (tolower($0) ~ /deleted/) next;
        if (tolower($0) ~ /standalone/) print name
      }' | sort -u | tr '\n' ',' | sed 's/,$//')
  fi
  REGISTERED_PROFILES="$registered"
  PARKED_PROFILES="$parked"
  STANDALONE_PROFILES="$standalone"
  EXPECTED_SERVED_PROFILES="$registered"
  if [ -n "$parked" ]; then
    for p in $(printf '%s' "$parked" | tr ',' ' '); do
      EXPECTED_SERVED_PROFILES=$(printf '%s' "$EXPECTED_SERVED_PROFILES" | tr ',' '\n' | grep -Fxv "$p" | tr '\n' ',' | sed 's/,$//')
    done
  fi
  if [ -n "$standalone" ]; then
    for p in $(printf '%s' "$standalone" | tr ',' ' '); do
      EXPECTED_SERVED_PROFILES=$(printf '%s' "$EXPECTED_SERVED_PROFILES" | tr ',' '\n' | grep -Fxv "$p" | tr '\n' ',' | sed 's/,$//')
    done
  fi
  if [ -z "$EXPECTED_PROFILES" ]; then
    if [ -n "$PLAN_PROFILES" ]; then
      EXPECTED_PROFILES="$PLAN_PROFILES"
    elif [ -n "$registered" ]; then
      EXPECTED_PROFILES="$registered"
    fi
  fi
  if [ -n "$registered" ] && [ -n "$EXPECTED_PROFILES" ]; then
    local filtered="" p
    for p in $(printf '%s' "$EXPECTED_PROFILES" | tr ',' ' '); do
      [ -n "$p" ] || continue
      if printf '%s\n' "$registered" | tr ',' '\n' | grep -Fxq "$p"; then
        filtered="${filtered}${filtered:+,}$p"
      fi
    done
    [ -n "$filtered" ] && EXPECTED_PROFILES="$filtered"
  fi
  if [ -n "$EXPECTED_SERVED_PROFILES" ]; then
    EXPECTED_PROFILES="$EXPECTED_SERVED_PROFILES"
  fi

  if [ -n "$HTTP_PROFILES" ]; then
    SERVED_PROFILES="$HTTP_PROFILES"
  else
    SERVED_PROFILES="$served"
  fi
  recompute_profile_counts
  local profile_verdict="UNKNOWN"
  [ "$PROFILES_OK" = yes ] && profile_verdict="PASS"
  [ "$PROFILES_OK" = no ] && profile_verdict="FAIL"
  record_check_row "Expected / served profiles" "$EXPECTED_PROFILE_COUNT expected" \
    "$SERVED_PROFILE_COUNT served; missing=${MISSING_PROFILES:-none}" "$profile_verdict"
  if [ -n "$MISSING_PROFILES" ]; then
    add_degraded GATEWAY "expected profile(s) not served: $MISSING_PROFILES"
    add_affected "Profile(s) not served: $MISSING_PROFILES (multiplexed gateway may intentionally park duplicates; verify before changing)"
  elif [ "$PROFILES_OK" = unknown ]; then
    add_unverified GATEWAY "profile inventory is incomplete; expected/served profiles could not be proven"
  fi
  record_timeline "L2" "hermes profile list" "$PROFILE_LIST_STATUS" "served=${served:-none}"
}

discover_gateway_status() {
  [ -n "$HERMES_BIN" ] || return 0
  capture 120 "$HERMES_BIN" gateway status
  local relevant
  relevant=$(printf '%s\n' "$RUN_OUTPUT" | grep -E 'System gateway|Configured to run|starts at boot|gateway service|Active:|failed|inactive|error' | awk 'length($0) <= 240' | head -n 8)
  record_timeline "L2" "hermes gateway status" "exit $RUN_STATUS" "$relevant"
  if [ "$RUN_STATUS" -ne 0 ]; then
    add_degraded GATEWAY "hermes gateway status failed (exit $RUN_STATUS)"
  fi
}

discover_doctor() {
  [ -n "$HERMES_BIN" ] || return 0
  capture 60 "$HERMES_BIN" doctor
  DOCTOR_STATUS="exit $RUN_STATUS"
  DOCTOR_WARNINGS=$(printf '%s\n' "$RUN_OUTPUT" | grep -E '^[[:space:]]*⚠' | head -n 10)
  local warning_count
  warning_count=$(printf '%s\n' "$DOCTOR_WARNINGS" | grep -c . 2>/dev/null)
  [ -n "$warning_count" ] || warning_count=0
  record_timeline "L1" "hermes doctor" "$DOCTOR_STATUS" "warnings=$warning_count"
  if [ "$RUN_STATUS" -eq 124 ]; then
    add_warning "hermes doctor timed out after 60s; diagnostic not completed (not counted as a service failure)"
    add_unknown "hermes doctor result (timed out; optional-provider impact not classified)"
    record_check_row "hermes doctor" "completed diagnostics" "timeout" "NOT_TESTED"
  elif [ "$RUN_STATUS" -ne 0 ]; then
    add_degraded PRECHECK "hermes doctor failed (exit $RUN_STATUS)"
    record_check_row "hermes doctor" "exit 0" "exit $RUN_STATUS" "FAIL"
  else
    record_check_row "hermes doctor" "exit 0" "exit 0; $warning_count warning(s)" "PASS"
  fi
  if [ -n "$DOCTOR_WARNINGS" ]; then
    add_warning "doctor warnings (classify impact, not automatically fatal): $(printf '%s' "$DOCTOR_WARNINGS" | head -n 3 | tr '\n' ' ' | evidence 2 400)"
  fi
}

discover_pm_status() {
  [ -n "$HERMES_BIN" ] || return 0
  capture 60 "$HERMES_BIN" pm status
  PM_STATUS="exit $RUN_STATUS"
  record_timeline "L1" "hermes pm status" "$PM_STATUS" "$(printf '%s' "$RUN_OUTPUT" | head -n 2 | evidence 2 200)"
  if [ "$RUN_STATUS" -ne 0 ]; then
    add_degraded PRECHECK "hermes pm status failed (exit $RUN_STATUS)"
  fi
}

# Backend URL + HTTP --------------------------------------------------------
discover_backend_url() {
  local host="" port="" candidate="" candidate_source=""
  if [ -n "$SERVE_UNIT" ]; then
    host=$(printf '%s' "$SERVE_EXEC" | sed -n 's/.*--host[ =]\([^ ;]*\).*/\1/p' | head -n 1)
    port=$(printf '%s' "$SERVE_EXEC" | sed -n 's/.*--port[ =]\([0-9][0-9]*\).*/\1/p' | head -n 1)
    if [ -n "$port" ]; then
      candidate="http://${host:-127.0.0.1}:$port"
      candidate_source="unit ExecStart"
    else
      # Confirm the listening socket belongs to the backend MainPID.
      local ss_line
      ss_line=$(ss -ltnp 2>/dev/null | grep -F "pid=$SERVE_PID," | head -n 1 || true)
      if [ -n "$ss_line" ]; then
        local addr
        addr=$(printf '%s\n' "$ss_line" | awk '{print $4}' | head -n 1)
        port="${addr##*:}"
        host="${addr%:*}"
        host="${host#[}"; host="${host%]}"
        [ "$host" = "0.0.0.0" ] && host="127.0.0.1"
        [ "$host" = "::" ] && host="127.0.0.1"
        candidate="http://${host}:$port"
        candidate_source="listening socket for pid $SERVE_PID"
      fi
    fi
    # The documented fallback is allowed only when the real service
    # configuration confirms 9119; never assume the port.
    if [ -z "$candidate" ] && printf '%s' "$SERVE_EXEC" | grep -qE -- '--port[ =]9119'; then
      candidate="http://127.0.0.1:9119"
      candidate_source="confirmed 9119 in unit ExecStart"
    fi
  fi

  if [ -n "$BACKEND_URL_ARG" ]; then
    BACKEND_URL="$BACKEND_URL_ARG"
    BACKEND_URL_SOURCE="explicit argument"
    if [ -n "$candidate" ] && [ "$candidate" != "$BACKEND_URL" ]; then
      add_warning "explicit backend URL differs from the verified unit configuration ($candidate); saved Desktop selection was not modified"
      record_check_row "Backend URL consistency" "explicit URL matches verified unit configuration" \
        "explicit=$BACKEND_URL; unit=$candidate" "INFO"
    fi
    return 0
  fi
  BACKEND_URL="$candidate"
  BACKEND_URL_SOURCE="$candidate_source"
  [ -n "$BACKEND_URL" ] || BACKEND_URL_SOURCE="not discoverable from verified service configuration"
}

probe_backend() {
  if [ -z "$BACKEND_URL" ]; then
    HTTP_CHECK="NOT_TESTED"
    if [ "$SERVE_UNIT_EXISTS" = yes ] && [ "$SERVE_ACTIVE" = active ]; then
      record_check_row "Backend HTTP + JSON" "GET /api/status" "backend active but URL not discovered" "UNKNOWN"
      [ "${PROBE_QUIET:-no}" != yes ] && add_unverified SERVE_BACKEND "backend service is active but HTTP health was not verified (no verified URL)"
    else
      record_check_row "Backend HTTP + JSON" "GET /api/status" "no verified backend URL" "NOT_TESTED"
      add_unknown "Desktop backend URL was not discoverable and none was supplied"
    fi
    return 0
  fi
  BACKEND_URL_DISPLAY=$(printf '%s' "$BACKEND_URL" | sanitize_text)
  local body="$TMP_RUN/http_body.json" headers="$TMP_RUN/http_headers.txt"
  local meta
  local probe_timeout="${PROBE_TIMEOUT:-8}"
  [ "$probe_timeout" -lt 1 ] && probe_timeout=1
  capture "$probe_timeout" curl -sS -m "$probe_timeout" --connect-timeout "$probe_timeout" -o "$body" -D "$headers" -w '%{http_code}|%{content_type}|%{time_total}' "$BACKEND_URL/api/status"
  local curl_status="$RUN_STATUS"
  meta="$RUN_OUTPUT"
  HTTP_CODE=$(printf '%s' "$meta" | cut -d'|' -f1)
  HTTP_CONTENT_TYPE=$(printf '%s' "$meta" | cut -d'|' -f2)
  local elapsed
  elapsed=$(printf '%s' "$meta" | cut -d'|' -f3)
  if [ "$curl_status" -ne 0 ]; then
    HTTP_CHECK="FAIL"
    record_check_row "Backend HTTP + JSON" "HTTP 2xx with Hermes JSON" \
      "curl exit $curl_status from $BACKEND_URL_DISPLAY" "FAIL"
    [ "${PROBE_QUIET:-no}" != yes ] && add_degraded NETWORK "Desktop backend did not answer GET /api/status (curl exit $curl_status at $BACKEND_URL_DISPLAY)"
    record_timeline "L3" "curl GET $BACKEND_URL/api/status" "curl exit $curl_status" "no response"
    return 0
  fi
  record_timeline "L3" "curl GET $BACKEND_URL/api/status" "HTTP $HTTP_CODE (${elapsed}s)" "content-type=$HTTP_CONTENT_TYPE bytes=$(wc -c <"$body" 2>/dev/null | tr -d ' ')"
  case "$HTTP_CODE" in
    401|403)
      HTTP_CHECK="AUTH_REQUIRED"
      record_check_row "Backend HTTP + JSON" "HTTP 2xx with Hermes JSON" \
        "HTTP $HTTP_CODE; listener answered, authentication not proven" "FAIL"
      [ "${PROBE_QUIET:-no}" != yes ] && add_degraded AUTH "backend answered HTTP $HTTP_CODE; this proves a listener, not a healthy authenticated Hermes session"
      add_unknown "Authenticated Desktop session and WebSocket were not tested"
      ;;
    2*)
      local parsed
      parsed=$(python3 - "$body" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
        data = json.load(fh)
except Exception as exc:
    print("invalid\t\t\t\t\t\t")
    raise SystemExit(0)
if not isinstance(data, dict):
    print("invalid\t\t\t\t\t\t")
    raise SystemExit(0)
markers = sum(1 for k in ("auth_required", "auth_providers", "gateway_running", "version", "components", "install_id") if k in data)
version = str(data.get("version") or "")
auth = str(data.get("auth_required"))
profiles = ",".join(str(x) for x in (data.get("profiles") or []))
overall = str(data.get("overall") or "")
dashboard = ""
components = data.get("components")
if isinstance(components, dict) and isinstance(components.get("dashboard"), dict):
    dashboard = str(components["dashboard"].get("status") or "")
print(("hermes" if markers >= 2 and version else "invalid") + "\t" + version + "\t" + auth + "\t" + profiles + "\t" + overall + "\t" + dashboard)
PY
)
      if [ -z "$parsed" ]; then
        # No python3: fall back to a conservative textual marker check.
        if grep -q '"auth_required"' "$body" 2>/dev/null && grep -q '"version"' "$body" 2>/dev/null; then
          parsed="hermes\tunknown\tunknown\t\t\t"
        else
          parsed="invalid\t\t\t\t\t\t"
        fi
      fi
      local kind
      kind=$(printf '%s' "$parsed" | cut -f1)
      HTTP_VERSION=$(printf '%s' "$parsed" | cut -f2)
      HTTP_AUTH_REQUIRED=$(printf '%s' "$parsed" | cut -f3)
      HTTP_PROFILES=$(printf '%s' "$parsed" | cut -f4)
      HTTP_OVERALL=$(printf '%s' "$parsed" | cut -f5)
      local dashboard_status
      dashboard_status=$(printf '%s' "$parsed" | cut -f6)
      if [ "$kind" = hermes ]; then
        HTTP_PROTOCOL="hermes-json"
        HTTP_CHECK="PASS"
        if [ -n "$HTTP_PROFILES" ]; then
          SERVED_PROFILES="$HTTP_PROFILES"
          local p expected_n=0 served_n=0 missing=""
          for p in $(printf '%s' "$EXPECTED_PROFILES" | tr ',' ' '); do
            [ -n "$p" ] || continue
            expected_n=$((expected_n + 1))
            if ! printf '%s\n' "$SERVED_PROFILES" | tr ',' '\n' | grep -Fxq "$p"; then
              missing="${missing}${missing:+,}$p"
            fi
          done
          for p in $(printf '%s' "$SERVED_PROFILES" | tr ',' ' '); do [ -n "$p" ] && served_n=$((served_n + 1)); done
          EXPECTED_PROFILE_COUNT="$expected_n"
          SERVED_PROFILE_COUNT="$served_n"
          MISSING_PROFILES="$missing"
          if [ "$expected_n" -gt 0 ] && [ -z "$missing" ]; then PROFILES_OK="yes"; else PROFILES_OK="no"; fi
        fi
        record_check_row "Backend HTTP + JSON" "HTTP 2xx with Hermes JSON" \
          "HTTP 200; version=${HTTP_VERSION:-unknown}; auth_required=${HTTP_AUTH_REQUIRED:-unknown}; overall=${HTTP_OVERALL:-unknown}" "PASS"
        if [ "$HTTP_AUTH_REQUIRED" = True ] || [ "$HTTP_AUTH_REQUIRED" = true ]; then
          [ "${PROBE_QUIET:-no}" != yes ] && add_unknown "Backend advertises auth_required=true; authenticated session is not proven by this probe"
        fi
        if [ -n "$dashboard_status" ] && [ "$dashboard_status" != ok ]; then
          [ "${PROBE_QUIET:-no}" != yes ] && add_degraded SERVE_BACKEND "backend reports dashboard component status '$dashboard_status'"
        fi
      else
        HTTP_PROTOCOL="invalid-json-or-shape"
        HTTP_CHECK="FAIL"
        record_check_row "Backend HTTP + JSON" "HTTP 2xx with Hermes JSON" \
          "HTTP 200 but response is not recognizable Hermes JSON (content-type=$HTTP_CONTENT_TYPE)" "FAIL"
        [ "${PROBE_QUIET:-no}" != yes ] && add_degraded PROTOCOL "HTTP 200 from $BACKEND_URL_DISPLAY did not contain recognizable Hermes status JSON"
        add_confirmed "Backend returned HTTP 200 with content-type '$HTTP_CONTENT_TYPE' but failed Hermes payload validation"
        add_unknown "Raw response body omitted from the report to avoid leaking configuration"
      fi
      ;;
    *)
      HTTP_CHECK="FAIL"
      record_check_row "Backend HTTP + JSON" "HTTP 2xx with Hermes JSON" "HTTP $HTTP_CODE" "FAIL"
      [ "${PROBE_QUIET:-no}" != yes ] && add_degraded PROTOCOL "backend returned HTTP $HTTP_CODE from $BACKEND_URL_DISPLAY"
      add_confirmed "Backend listener answered with HTTP $HTTP_CODE"
      ;;
  esac
}

# Native update receipt -----------------------------------------------------
receipt_correlation_id() {
  python3 - "$1" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
        print(str(json.load(fh).get("correlation_id") or ""))
except Exception:
    print("")
PY
}

discover_receipt() {
  local receipt_dir="$HERMES_HOME_DIR/logs/update_receipts"
  if [ ! -d "$receipt_dir" ]; then
    RECEIPT_PATH="none"
    RECEIPT_CHECK="NOT_TESTED"
    record_check_row "Update receipt" "update receipt evidence" "receipt directory absent" "UNKNOWN"
    add_unverified RECEIPT "no native update receipt evidence was available; updater follow-ups could not be checked"
    return 0
  fi
  local newest="" latest="$receipt_dir/latest.json" latest_kind=""
  newest=$(find "$receipt_dir" -maxdepth 1 -type f -name 'update_*.json' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)
  if [ -n "$UPDATE_CORRELATION_ID" ]; then
    local f cid
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      cid=$(receipt_correlation_id "$f")
      if [ "$cid" = "$UPDATE_CORRELATION_ID" ]; then
        newest="$f"
        break
      fi
    done < <(find "$receipt_dir" -maxdepth 1 -type f -name 'update_*.json' 2>/dev/null)
  fi
  if [ -f "$latest" ]; then
    latest_kind=$(python3 - "$latest" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
        print(str(json.load(fh).get("kind") or ""))
except Exception:
    print("unreadable")
PY
)
    if [ -z "$newest" ]; then
      newest="$latest"
    elif [ "$latest_kind" != "plugin-check" ] && [ "$latest_kind" != "unreadable" ] && [ "$latest" -nt "$newest" ]; then
      newest="$latest"
    fi
  fi
  if [ -z "$newest" ]; then
    RECEIPT_PATH="none"
    RECEIPT_CHECK="NOT_TESTED"
    record_check_row "Update receipt" "update_*.json or latest.json present" "none" "UNKNOWN"
    add_unverified RECEIPT "no native update receipt evidence was available; updater follow-ups could not be checked"
    return 0
  fi
  RECEIPT_PATH="$newest"
  local parsed
  parsed=$(python3 - "$newest" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
        data = json.load(fh)
except Exception:
    print("unreadable\t0\t\tunknown\tunknown")
    raise SystemExit(0)
followups = data.get("followups") or []
if isinstance(followups, dict):
    followups = [followups]
text = "; ".join(str(x.get("reason", x)) if isinstance(x, dict) else str(x) for x in followups)
gw = data.get("gateway_restart")
incomplete = ""
if isinstance(gw, dict):
    incomplete = str(gw.get("incomplete", ""))
desktop = data.get("desktop")
desktop_text = ""
if isinstance(desktop, dict):
    desktop_text = str(desktop.get("status") or desktop.get("result") or "")
print("%s\t%d\t%s\t%s\t%s\t%s\t%s" % (str(data.get("outcome") or "unknown"), len(followups), text, incomplete, desktop_text or "unknown", str(data.get("correlation_id") or ""), str(data.get("kind") or "")))
PY
)
  RECEIPT_OUTCOME=$(printf '%s' "$parsed" | cut -f1)
  RECEIPT_FOLLOWUP_COUNT=$(printf '%s' "$parsed" | cut -f2)
  RECEIPT_FOLLOWUP_TEXT=$(printf '%s' "$parsed" | cut -f3)
  RECEIPT_GATEWAY_INCOMPLETE=$(printf '%s' "$parsed" | cut -f4)
  RECEIPT_DESKTOP=$(printf '%s' "$parsed" | cut -f5)
  RECEIPT_CORRELATION=$(printf '%s' "$parsed" | cut -f6)
  RECEIPT_KIND=$(printf '%s' "$parsed" | cut -f7)
  local receipt_mtime
  receipt_mtime=$(stat -c %Y "$newest" 2>/dev/null || echo 0)
  if [ "${receipt_mtime:-0}" -ge "$OPERATION_STARTED_EPOCH" ]; then RECEIPT_FRESH="yes"; else RECEIPT_FRESH="no"; fi

  if [ "$RECEIPT_OUTCOME" = unreadable ]; then
    RECEIPT_CHECK="FAIL"
    add_degraded RECEIPT "newest update receipt is unreadable: $newest"
  elif [ -n "$RECEIPT_KIND" ] && [ "$RECEIPT_KIND" = plugin-check ]; then
    RECEIPT_CHECK="FAIL"
    add_degraded RECEIPT "selected receipt is a plugin-check artifact, not an update receipt: $newest"
  elif [ "$RECEIPT_FOLLOWUP_COUNT" != 0 ] || [ "$RECEIPT_GATEWAY_INCOMPLETE" = True ] || [ "$RECEIPT_GATEWAY_INCOMPLETE" = true ]; then
    RECEIPT_CHECK="FAIL"
    add_degraded RECEIPT "native update receipt has ${RECEIPT_FOLLOWUP_COUNT:-0} unresolved follow-up(s)${RECEIPT_FOLLOWUP_TEXT:+: $RECEIPT_FOLLOWUP_TEXT}"
    add_confirmed "Exit code 0 is not treated as success while the receipt records follow-ups"
  elif printf '%s' "$RECEIPT_OUTCOME" | grep -qiE '^(ok|success)$'; then
    RECEIPT_CHECK="PASS"
  else
    RECEIPT_CHECK="FAIL"
    add_degraded RECEIPT "native update receipt outcome is '${RECEIPT_OUTCOME:-unknown}'"
  fi
  record_check_row "Update receipt / follow-ups" "outcome ok/success, no follow-ups" \
    "outcome=$RECEIPT_OUTCOME followups=$RECEIPT_FOLLOWUP_COUNT gateway_incomplete=${RECEIPT_GATEWAY_INCOMPLETE:-unknown} desktop=$RECEIPT_DESKTOP fresh=$RECEIPT_FRESH" "$RECEIPT_CHECK"
  record_timeline "RECEIPT" "read $newest" "$RECEIPT_OUTCOME" "$(printf '%s' "$RECEIPT_FOLLOWUP_TEXT" | evidence 4 400)"
}

# Collect everything read-only.
collect_all() {
  local label="$1"
  record_timeline "$label" "collect read-only state" "start" "no mutation"
  discover_os
  if [ "$EFFECTIVE_UID" = 0 ]; then
    add_blocked PRECHECK "script must run as the Hermes install owner, not root"
    record_check_row "Execution account" "non-root install owner" "uid=0 ($EFFECTIVE_USER)" "FAIL"
  else
    record_check_row "Execution account" "non-root install owner" "$EFFECTIVE_USER (uid $EFFECTIVE_UID)" "PASS"
  fi
  if ! discover_hermes; then
    return 0
  fi
  discover_git
  discover_update_target
  discover_update_plan
  discover_disk
  discover_migration_risk
  discover_unit_lists
  discover_units
  discover_gateway_status
  discover_doctor
  discover_pm_status
  discover_backend_url
  probe_backend
  discover_profiles
  discover_receipt
  return 0
}

# ---------------------------------------------------------------------------
# Decisions
# ---------------------------------------------------------------------------
decide_check() {
  local blocks degraded unverified
  blocks=$(count_lines "$BLOCKED_FILE")
  degraded=$(count_lines "$DEGRADED_FILE")
  unverified=$(count_lines "$UNVERIFIED_FILE")
  if [ "$blocks" -gt 0 ]; then
    STATUS="BLOCKED" ; EXIT_CODE=2
    SUMMARY=$(head -n 1 "$BLOCKED_FILE" | cut -d'|' -f2-)
  elif [ "$degraded" -gt 0 ]; then
    STATUS="DEGRADED" ; EXIT_CODE=1
    SUMMARY=$(head -n 1 "$DEGRADED_FILE" | cut -d'|' -f2-)
  elif [ "$unverified" -gt 0 ]; then
    STATUS="UNKNOWN" ; EXIT_CODE=1
    SUMMARY=$(head -n 1 "$UNVERIFIED_FILE" | cut -d'|' -f2-)
  else
    STATUS="HEALTHY" ; EXIT_CODE=0
    if [ "$UPDATE_AVAILABLE" = yes ]; then
      SUMMARY="Local runtime checks passed; update v$STABLE_TARGET is available."
    else
      SUMMARY="All locally verifiable checks passed."
    fi
  fi
  add_unknown "Windows-side network, authentication and authenticated WebSocket were not tested from this Linux host"
  add_unknown "Active chat sessions were not exercised"
  add_works "Gateway supervisor, PID, profiles, backend HTTP payload and update receipt were inspected read-only"
  add_affected "No service was restarted and no configuration was changed during check"
}

exec_signature() {
  local exec="$1" path argv
  path=$(printf '%s' "$exec" | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n 1)
  argv=$(printf '%s' "$exec" | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p' | head -n 1)
  printf '%s|%s' "$path" "$argv"
}

check_update_execution_context() {
  local proc_root="${HERMES_OPS_PROC_ROOT:-/proc}"
  local ancestor=$$ cgroup parent
  while [ "$ancestor" -gt 1 ] 2>/dev/null; do
    [ -r "$proc_root/$ancestor/status" ] && [ -r "$proc_root/$ancestor/cgroup" ] || {
      add_blocked PRECHECK "process ancestry cannot be verified; run the update from an independent terminal"
      return 1
    }
    cgroup=$(cat "$proc_root/$ancestor/cgroup" 2>/dev/null)
    [ -n "$cgroup" ] || {
      add_blocked PRECHECK "process cgroup evidence is unavailable; run the update from an independent terminal"
      return 1
    }
    if [ -n "$GATEWAY_PID" ] && [ "$GATEWAY_PID" != unknown ] && [ "$ancestor" = "$GATEWAY_PID" ]; then
      add_blocked PRECHECK "update was launched from the Hermes gateway process; use an independent SSH or terminal session"
      return 1
    fi
    if [ -n "$SERVE_PID" ] && [ "$SERVE_PID" != unknown ] && [ "$ancestor" = "$SERVE_PID" ]; then
      add_blocked PRECHECK "update was launched from the Hermes backend process; use an independent SSH or terminal session"
      return 1
    fi
    if [ -n "$GATEWAY_UNIT" ] && printf '%s' "$cgroup" | grep -Fq "$GATEWAY_UNIT"; then
      add_blocked PRECHECK "update was launched inside the gateway service cgroup; use an independent SSH or terminal session"
      return 1
    fi
    if [ -n "$SERVE_UNIT" ] && printf '%s' "$cgroup" | grep -Fq "$SERVE_UNIT"; then
      add_blocked PRECHECK "update was launched inside the backend service cgroup; use an independent SSH or terminal session"
      return 1
    fi
    parent=$(awk '/^PPid:/ {print $2}' "$proc_root/$ancestor/status" 2>/dev/null)
    [ -n "$parent" ] && [ "$parent" != "$ancestor" ] || {
      add_blocked PRECHECK "process ancestry cannot be verified; run the update from an independent terminal"
      return 1
    }
    ancestor="$parent"
  done
  return 0
}

update_preflight() {
  local n=0
  check_update_execution_context || true
  # Re-derive hard blockers from collected evidence.
  if [ "$EFFECTIVE_UID" = 0 ]; then add_blocked PRECHECK "refusing update as root"; fi
  if [ -z "$CHECKOUT" ]; then add_blocked PRECHECK "source checkout not resolved"; fi
  if [ "$PROVENANCE_OK" != yes ]; then add_blocked PRECHECK "not an official NousResearch/hermes-agent checkout ('$GIT_REMOTE')"; fi
  if [ "$INSTALL_KIND" != git ]; then add_blocked PRECHECK "install method '$INSTALL_KIND' is not a managed git checkout"; fi
  if [ "$CHANNEL" != stable ]; then add_blocked PRECHECK "update channel is '$CHANNEL', not stable"; fi
  if [ "$UPDATE_AVAILABLE" = yes ] && { [ -z "$STABLE_TARGET" ] || [ "$STABLE_TARGET" = unknown ]; }; then add_blocked PRECHECK "stable target version could not be established"; fi
  if [ "$UPDATE_AVAILABLE" = yes ] && { [ -z "$STABLE_TARGET_SHA" ] || [ "$STABLE_TARGET_SHA" = unknown ]; }; then add_blocked PRECHECK "stable target revision could not be established"; fi
  if [ "$GIT_INTEGRITY_OK" != yes ]; then add_blocked PRECHECK "Git repository integrity could not be proven; refusing update"; fi
  if [ "$GIT_DIRTY" != no ]; then add_blocked PRECHECK "checkout cleanliness is '$GIT_DIRTY'; refusing to stash/reset/assume clean (see git status evidence)"; fi
  if [ "$CHECKOUT_OK" != yes ]; then add_blocked PRECHECK "checkout is on custom branch '$GIT_BRANCH'"; fi
  if [ "$UPDATE_AVAILABLE" = downgrade ]; then add_blocked PRECHECK "stable target v$STABLE_TARGET is older than installed v$HERMES_VERSION"; fi
  if [ "$UPDATE_AVAILABLE" = unknown ]; then add_blocked PRECHECK "update availability/target could not be established"; fi
  if [ "$MIGRATION_RISK" != no ]; then add_blocked PRECHECK "multiplex topology change risk is '$MIGRATION_RISK'; explicit owner approval required"; fi
  if [ "$DISK_FREE_MB" != unknown ] && [ "$DISK_FREE_MB" -lt "${HERMES_OPS_MIN_FREE_MB:-2048}" ]; then
    add_blocked PRECHECK "insufficient free disk: ${DISK_FREE_MB} MiB"
  fi
  if [ -z "$GATEWAY_UNIT" ]; then add_blocked PRECHECK "gateway unit not discovered"; fi
  if [ "$GATEWAY_ACTIVE" != active ]; then add_blocked PRECHECK "gateway is not active before update; refusing to change an intentionally stopped state"; fi
  if [ "$SERVE_UNIT_EXISTS" = yes ] && [ "$SERVE_ACTIVE" != active ]; then
    add_blocked SERVE_BACKEND "Desktop backend is not active before update; resolve its state separately rather than masking it"
  fi
  if [ "$SERVE_UNIT_EXISTS" = yes ] && [ "$SERVE_SCOPE" = system ]; then
    if ! sudo -n true >/dev/null 2>&1; then
      add_blocked PRECHECK "system-scope backend refresh needs passwordless sudo, which is unavailable non-interactively"
    fi
  fi
  if [ -e "$CHECKOUT/.git/hermes-update-pull" ]; then
    add_blocked PRECHECK "another Hermes update lock exists (.git/hermes-update-pull)"
  fi
  if [ "$HTTP_AUTH_REQUIRED" = unknown ] && [ "$SERVE_ACTIVE" = active ]; then
    add_warning "Backend /api/status was not validated before update; post-update comparison will be partial"
  fi
  if [ -z "$REGISTERED_PROFILES" ]; then
    add_blocked PRECHECK "authoritative registered profile inventory could not be established"
  fi
  n=$(count_lines "$BLOCKED_FILE")
  if [ "$n" -gt 0 ]; then
    return 1
  fi
  add_warning "Update restarts the gateway and may briefly interrupt active sessions; native drain logic is used (no --force)"
  return 0
}

monotonic_now() {
  local file="${HERMES_OPS_UPTIME_FILE:-/proc/uptime}"
  awk '{print int($1)}' "$file" 2>/dev/null | head -n 1
}

poll_backend_ready() {
  local start now remaining sleep_s budget="${HERMES_OPS_READY_BUDGET:-90}"
  start=$(monotonic_now)
  [ -n "$start" ] || { add_degraded SERVE_BACKEND "monotonic clock unavailable for readiness polling"; return 1; }
  BACKEND_READY="no"
  while :; do
    now=$(monotonic_now)
    [ -n "$now" ] || break
    remaining=$((budget - (now - start)))
    [ "$remaining" -le 0 ] && break
    SERVE_ACTIVE=$(unit_show "$SERVE_SCOPE" "$SERVE_UNIT" ActiveState)
    SERVE_PID=$(unit_show "$SERVE_SCOPE" "$SERVE_UNIT" MainPID)
    PROBE_TIMEOUT=$remaining
    [ "$PROBE_TIMEOUT" -gt 8 ] && PROBE_TIMEOUT=8
    [ "$PROBE_TIMEOUT" -lt 1 ] && PROBE_TIMEOUT=1
    PROBE_QUIET=yes
    discover_backend_url
    probe_backend
    PROBE_QUIET=no
    if [ "$HTTP_CHECK" = PASS ] && [ "$HTTP_VERSION" = "$HERMES_VERSION" ] && [ "$HTTP_OVERALL" = ok ] && backend_listener_owned; then
      BACKEND_READY="yes"
      return 0
    fi
    now=$(monotonic_now)
    [ -n "$now" ] || break
    remaining=$((budget - (now - start)))
    [ "$remaining" -le 1 ] && break
    sleep_s=2
    [ "$sleep_s" -gt "$remaining" ] && sleep_s=$remaining
    [ "$sleep_s" -gt 0 ] && sleep "$sleep_s"
  done
  BACKEND_READY="no"
  add_degraded SERVE_BACKEND "backend did not become ready within the ${budget}-second readiness budget"
  return 1
}

perform_update() {
  [ "$UPDATE_AVAILABLE" = yes ] || return 0
  UPDATE_NEEDED="yes"
  UPDATE_CORRELATION_ID="hermes-ops-${OPERATION_STARTED_EPOCH}-$$"
  local -a cmd=("$HERMES_BIN" update --yes)
  if [ "$NO_BACKUP" -eq 1 ]; then cmd+=(--no-backup); fi
  UPDATE_OUTPUT_FILE="$TMP_RUN/update_output.log"
  say "Running one official stable update: ${cmd[*]}"
  record_timeline "SOURCE_UPDATE" "${cmd[*]}" "started" "single official updater invocation"
  HERMES_UPDATE_CORRELATION_ID="$UPDATE_CORRELATION_ID" "${cmd[@]}" >"$UPDATE_OUTPUT_FILE" 2>&1
  UPDATE_EXIT=$?
  UPDATE_OUTPUT_TAIL=$(tail -n 40 "$UPDATE_OUTPUT_FILE" 2>/dev/null | evidence 40 500)
  record_timeline "SOURCE_UPDATE" "${cmd[*]}" "exit $UPDATE_EXIT" "$(printf '%s' "$UPDATE_OUTPUT_TAIL" | tail -n 5)"
  MUTATIONS="hermes update --yes$([ "$NO_BACKUP" -eq 1 ] && printf ' --no-backup')"
  # Version after the update comes from a fresh read, never from updater output.
  if [ -n "$HERMES_BIN" ]; then
    capture 30 "$HERMES_BIN" --version
    if [ "$RUN_STATUS" -eq 0 ]; then
      HERMES_VERSION_AFTER=$(printf '%s\n' "$RUN_OUTPUT" | extract_version)
      [ -n "$HERMES_VERSION_AFTER" ] || HERMES_VERSION_AFTER="unknown"
      HERMES_VERSION="$HERMES_VERSION_AFTER"
    fi
  fi
  return 0
}

gateway_live_revision_matches() {
  local installed live_rev
  installed=$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null || true)
  live_rev=$(printf '%s\n' "$UPDATE_PLAN_OUTPUT" | awk '
    /gateway/ && /@/ { for (i=1;i<=NF;i++) if ($i=="@") { print $(i+1); exit } }')
  [ -n "$installed" ] && [ -n "$live_rev" ] || return 1
  case "$installed" in
    "$live_rev"*) return 0 ;;
  esac
  return 1
}

verify_gateway_runtime() {
  [ -n "$GATEWAY_UNIT" ] || { add_degraded GATEWAY "gateway unit missing after update"; return; }
  if [ "$GATEWAY_UNIT" != "$PRE_GATEWAY_UNIT" ] || [ "$GATEWAY_SCOPE" != "$PRE_GATEWAY_SCOPE" ] || [ "$GATEWAY_USER" != "$PRE_GATEWAY_USER" ]; then
    add_degraded GATEWAY "gateway identity changed after update (unit=$GATEWAY_UNIT scope=$GATEWAY_SCOPE user=$GATEWAY_USER)"
  fi
  if [ -z "$GATEWAY_ACTIVE" ] || [ "$GATEWAY_ACTIVE" != active ]; then
    add_degraded GATEWAY "gateway is not active after update (${GATEWAY_ACTIVE:-unknown})"
  fi
  local gw_exec_sig pre_exec_sig
  gw_exec_sig=$(printf '%s' "$GATEWAY_EXEC" | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n 1)
  pre_exec_sig=$(printf '%s' "$PRE_GATEWAY_EXEC" | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n 1)
  if [ -n "$gw_exec_sig" ] && [ "$gw_exec_sig" != "$pre_exec_sig" ]; then
    add_degraded GATEWAY "gateway ExecStart changed after update"
  fi
  if ! printf '%s' "$GATEWAY_EXEC" | grep -Fq "$CHECKOUT"; then
    add_degraded GATEWAY "gateway checkout binding changed after update"
  fi
  if ! gateway_live_revision_matches; then
    add_degraded GATEWAY "live gateway revision could not be verified against the installed release"
  fi
}

backend_listener_owned() {
  [ -n "$BACKEND_URL" ] && [ -n "$SERVE_PID" ] || return 1
  local port line
  port=$(printf '%s' "$BACKEND_URL" | sed -n 's#.*:\([0-9][0-9]*\).*#\1#p')
  [ -n "$port" ] || return 1
  command -v ss >/dev/null 2>&1 || return 1
  line=$(ss -ltnp 2>/dev/null | grep -F ":$port " | head -n 1 || true)
  [ -n "$line" ] || return 1
  printf '%s' "$line" | grep -Fq "pid=$SERVE_PID,"
}

verify_backend_runtime() {
  if [ "$PRE_SERVE_UNIT_EXISTS" != yes ]; then
    return 0
  fi
  if [ "$SERVE_UNIT_EXISTS" != yes ] || [ -z "$SERVE_UNIT" ]; then
    add_degraded SERVE_BACKEND "backend disappeared after update"
    return 0
  fi
  if [ "$SERVE_UNIT" != "$PRE_SERVE_UNIT" ] || [ "$SERVE_SCOPE" != "$PRE_SERVE_SCOPE" ] || [ "$SERVE_USER" != "$PRE_SERVE_USER" ]; then
    add_degraded SERVE_BACKEND "backend identity changed after update"
  fi
  if [ "$SERVE_ACTIVE" != active ]; then
    add_degraded SERVE_BACKEND "backend is not active after update (${SERVE_ACTIVE:-unknown})"
  fi
  if [ -n "$BACKEND_URL" ] && [ "$HTTP_CHECK" != PASS ]; then
    add_degraded SERVE_BACKEND "backend HTTP health failed after update ($HTTP_CHECK)"
  fi
  if [ -z "$HTTP_VERSION" ] || [ "$HTTP_VERSION" = unknown ] || [ "$HTTP_VERSION" != "$HERMES_VERSION" ]; then
    add_degraded SERVE_BACKEND "backend version could not be verified as $HERMES_VERSION (reported=${HTTP_VERSION:-unknown})"
  fi
  if [ -z "$HTTP_OVERALL" ] || [ "$HTTP_OVERALL" != ok ]; then
    add_degraded SERVE_BACKEND "backend overall status is not ok (${HTTP_OVERALL:-unknown})"
  fi
  if [ -n "$BACKEND_URL" ] && ! backend_listener_owned; then
    add_degraded SERVE_BACKEND "backend listener ownership could not be verified for $BACKEND_URL"
  fi
}

verify_profile_inventory() {
  if [ -z "$REGISTERED_PROFILES_BEFORE" ]; then
    return 0
  fi
  local p
  for p in $(printf '%s' "$REGISTERED_PROFILES_BEFORE" | tr ',' ' '); do
    [ -n "$p" ] || continue
    if ! printf '%s\n' "$REGISTERED_PROFILES" | tr ',' '\n' | grep -Fxq "$p"; then
      add_degraded GATEWAY "registered profile disappeared after update: $p"
    fi
  done
  for p in $(printf '%s' "$REGISTERED_PROFILES" | tr ',' ' '); do
    [ -n "$p" ] || continue
    if ! printf '%s\n' "$REGISTERED_PROFILES_BEFORE" | tr ',' '\n' | grep -Fxq "$p"; then
      add_degraded GATEWAY "unexpected profile registration after update: $p"
    fi
  done
  if [ "$PARKED_PROFILES" != "$PARKED_PROFILES_BEFORE" ]; then
    add_degraded GATEWAY "parked profile state changed after update"
  fi
  if [ "$STANDALONE_PROFILES" != "$STANDALONE_PROFILES_BEFORE" ]; then
    add_degraded GATEWAY "standalone profile state changed after update"
  fi
  if [ -n "$MISSING_PROFILES" ]; then
    add_degraded GATEWAY "expected profile(s) not served after update: $MISSING_PROFILES"
  fi
}

decide_update() {
  local blocks problems unverified degraded
  blocks=$(count_lines "$BLOCKED_FILE")
  problems=0
  unverified=$(count_lines "$UNVERIFIED_FILE")
  degraded=$(count_lines "$DEGRADED_FILE")
  if [ "$UPDATE_EXIT" != "not run" ] && [ "$UPDATE_EXIT" -ne 0 ]; then
    problems=$((problems + 1))
    add_degraded SOURCE_UPDATE "official updater exited $UPDATE_EXIT; not retried"
  fi
  if [ "$UPDATE_NEEDED" = yes ] && [ "$UPDATE_EXIT" = "0" ]; then
    if [ "$HERMES_VERSION_AFTER" = unknown ] || [ "$HERMES_VERSION_AFTER" = "$HERMES_VERSION_BEFORE" ]; then
      problems=$((problems + 1))
      add_degraded SOURCE_UPDATE "code version did not advance from v$HERMES_VERSION_BEFORE (after=${HERMES_VERSION_AFTER:-unknown})"
    elif [ "$STABLE_TARGET" != unknown ] && version_lt "$HERMES_VERSION_AFTER" "$STABLE_TARGET"; then
      problems=$((problems + 1))
      add_degraded SOURCE_UPDATE "updated version v$HERMES_VERSION_AFTER is still older than stable target v$STABLE_TARGET"
    fi
    if [ "$GIT_HEAD_BEFORE" != unknown ] && { [ "$GIT_HEAD" = unknown ] || [ "$GIT_HEAD" = "$GIT_HEAD_BEFORE" ]; }; then
      problems=$((problems + 1))
      add_degraded SOURCE_UPDATE "Git revision did not advance from $GIT_HEAD_BEFORE (after=${GIT_HEAD:-unknown})"
    fi
    if [ "$STABLE_TARGET_SHA_BEFORE" != unknown ] && [ "$GIT_HEAD" != unknown ]; then
      case "$GIT_HEAD" in
        "$STABLE_TARGET_SHA_BEFORE"*) ;;
        *) problems=$((problems + 1)); add_degraded SOURCE_UPDATE "installed Git revision $GIT_HEAD does not match selected stable revision $STABLE_TARGET_SHA_BEFORE" ;;
      esac
    fi
    if [ -n "$UPDATE_CORRELATION_ID" ] && [ "$RECEIPT_CORRELATION" != "$UPDATE_CORRELATION_ID" ]; then
      problems=$((problems + 1))
      add_degraded RECEIPT "native receipt correlation_id '${RECEIPT_CORRELATION:-missing}' does not match update '$UPDATE_CORRELATION_ID'"
    fi
    if [ "$STABLE_TARGET" != unknown ] && [ "$HERMES_VERSION_AFTER" != "$STABLE_TARGET" ]; then
      problems=$((problems + 1))
      add_degraded SOURCE_UPDATE "installed version v$HERMES_VERSION_AFTER does not equal selected stable release v$STABLE_TARGET"
    fi
    if [ "$STABLE_TARGET_BEFORE" != unknown ] && [ "$STABLE_TARGET" != unknown ] && [ "$STABLE_TARGET" != "$STABLE_TARGET_BEFORE" ]; then
      problems=$((problems + 1))
      add_degraded SOURCE_UPDATE "stable target changed during execution: $STABLE_TARGET_BEFORE -> $STABLE_TARGET"
    fi
    if [ "$STABLE_TARGET_SHA_BEFORE" != unknown ] && [ "$STABLE_TARGET_SHA" != unknown ] && [ "$STABLE_TARGET_SHA" != "$STABLE_TARGET_SHA_BEFORE" ]; then
      problems=$((problems + 1))
      add_degraded SOURCE_UPDATE "stable target revision changed during execution"
    fi
    if [ "$PROVENANCE_OK" != yes ]; then
      problems=$((problems + 1))
      add_degraded SOURCE_UPDATE "repository provenance is not official after update"
    fi
    if [ "$GIT_INTEGRITY_OK" != yes ]; then
      problems=$((problems + 1))
      add_degraded SOURCE_UPDATE "repository integrity could not be proven after update"
    fi
    if [ "$GIT_DIRTY" != no ]; then
      problems=$((problems + 1))
      add_degraded SOURCE_UPDATE "checkout is dirty after update"
    fi
  fi
  if [ "$degraded" -gt 0 ] || [ "$unverified" -gt 0 ]; then
    problems=$((problems + 1))
  fi
  if [ "$GATEWAY_ACTIVE" != active ]; then
    problems=$((problems + 1))
    add_degraded GATEWAY "gateway is not active after update (${GATEWAY_ACTIVE:-unknown})"
  fi
  if [ "$PROFILES_OK" != yes ]; then
    problems=$((problems + 1))
    add_degraded GATEWAY "not all expected profiles are served after update (missing=${MISSING_PROFILES:-unknown})"
  fi
  if [ "$SERVE_UNIT_EXISTS" = yes ]; then
    if [ "$PRE_SERVE_ACTIVE" = active ] && [ "$SERVE_ACTIVE" != active ]; then
      problems=$((problems + 1))
      add_degraded SERVE_BACKEND "backend unit is not active after update (${SERVE_ACTIVE:-unknown})"
    fi
  fi
  if { [ "$SERVE_UNIT_EXISTS" = yes ] || [ -n "$BACKEND_URL_ARG" ]; } && [ "$HTTP_CHECK" != PASS ]; then
    problems=$((problems + 1))
    add_degraded PROTOCOL "post-update backend HTTP check is '$HTTP_CHECK' (HTTP ${HTTP_CODE:-unknown})"
  fi
  if [ "$UPDATE_NEEDED" = yes ] && [ "$UPDATE_EXIT" = "0" ] && [ -n "$BACKEND_URL" ] && [ "$BACKEND_READY" != yes ]; then
    problems=$((problems + 1))
    add_degraded SERVE_BACKEND "backend did not become ready after bounded polling"
  fi
  if [ "$UPDATE_NEEDED" = yes ] && [ "$RECEIPT_FRESH" != yes ]; then
    problems=$((problems + 1))
    add_degraded RECEIPT "no fresh native update receipt was found for this run"
  fi
  if [ "$RECEIPT_CHECK" != PASS ]; then
    problems=$((problems + 1))
    add_degraded RECEIPT "native update receipt did not report a clean success"
  fi

  if [ "$blocks" -gt 0 ]; then
    if [ "$UPDATE_EXIT" != "not run" ]; then
      if [ "$UPDATE_EXIT" -ne 0 ]; then
        STATUS="FAILED" ; EXIT_CODE=1
        SUMMARY="Official updater exited $UPDATE_EXIT; post-update verification also recorded: $(head -n 1 "$BLOCKED_FILE" | cut -d'|' -f2-)"
      else
        STATUS="PARTIAL" ; EXIT_CODE=1
        SUMMARY="Update ran, but post-update verification found: $(head -n 1 "$BLOCKED_FILE" | cut -d'|' -f2-)"
      fi
    else
      STATUS="BLOCKED" ; EXIT_CODE=2
      SUMMARY=$(head -n 1 "$BLOCKED_FILE" | cut -d'|' -f2-)
    fi
  elif [ "$UPDATE_EXIT" != "not run" ] && [ "$UPDATE_EXIT" -ne 0 ]; then
    STATUS="FAILED" ; EXIT_CODE=1
    SUMMARY="Official updater exited $UPDATE_EXIT; no retry was attempted."
  elif [ "$UPDATE_NEEDED" = no ] && [ "$problems" -eq 0 ]; then
    STATUS="ALREADY_CURRENT" ; EXIT_CODE=0
    SUMMARY="No update was available; all verified checks passed."
  elif [ "$UPDATE_NEEDED" = no ]; then
    STATUS="PARTIAL" ; EXIT_CODE=1
    SUMMARY="No update was available, but pre-existing degradation remains (no mutation)."
  elif [ "$problems" -gt 0 ]; then
    STATUS="PARTIAL" ; EXIT_CODE=1
    SUMMARY="Code update ran, but one or more runtime/receipt/HTTP checks remain unresolved."
  else
    STATUS="UPDATED" ; EXIT_CODE=0
    SUMMARY="Official stable update and all locally verifiable checks passed."
  fi
  add_unknown "Windows Desktop authentication and authenticated WebSocket were not tested from this host"
  add_unknown "A 200 /api/status response does not prove a Windows Desktop session"
  add_works "Updater exit code, installed version, gateway, profiles, backend PID/service, HTTP JSON and receipt were re-checked independently"
  add_affected "Hermes updater owned service lifecycle; wrapper performed no service restarts"
  if [ "$NO_BACKUP" -eq 1 ]; then
    add_affected "Hermes' default quick snapshot was skipped at explicit user request (--no-backup)"
  elif [ "$UPDATE_NEEDED" = yes ]; then
    add_works "Upstream default quick snapshot remained enabled (no --no-backup)"
  fi
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
next_action_for_phase() {
  case "$1" in
    PRECHECK)
      NEXT_ACTION="Resolve the first PRECHECK blocker, then rerun check/update."
      NEXT_COMMAND="bash skills/hermes-linux/scripts/hermes.sh check"
      NEXT_PERMISSION="No, unless the blocker is sudo/user/unit related."
      ;;
    SOURCE_UPDATE)
      NEXT_ACTION="Inspect the updater output and native receipt before any retry; do not run a second updater."
      NEXT_COMMAND="jq '{outcome,followups,gateway_restart}' ~/.hermes/logs/update_receipts/latest.json"
      NEXT_PERMISSION="No; reading evidence only."
      ;;
    GATEWAY)
      if [ -n "$MISSING_PROFILES" ]; then
        NEXT_ACTION="Confirm whether missing profile(s) '$MISSING_PROFILES' are intentionally parked; do not delete, re-enable, or restart anything until that is known."
        NEXT_COMMAND="hermes profile list; hermes gateway migrate --multiplex --dry-run"
        NEXT_PERMISSION="No; read-only."
      else
        NEXT_ACTION="Inspect the verified gateway unit and restart only that unit if it is genuinely unhealthy."
        NEXT_COMMAND="${GATEWAY_UNIT:+systemctl status $GATEWAY_UNIT --no-pager}"
        NEXT_PERMISSION="System scope may require separately approved sudo."
      fi
      ;;
    SERVE_BACKEND)
      NEXT_ACTION="Inspect the backend unit journal; do not change ExecStart or credentials to mask a startup error."
      NEXT_COMMAND="${SERVE_UNIT:+journalctl -u $SERVE_UNIT -n 60 --no-pager}"
      NEXT_PERMISSION="Journal access may require elevated read permission."
      ;;
    NETWORK|PROTOCOL|AUTH)
      NEXT_ACTION="Re-test the discovered backend URL and inspect the service binding; do not expose the port publicly."
      NEXT_COMMAND="curl -sS -D - ${BACKEND_URL:-<verified-url>}/api/status -o /dev/null"
      NEXT_PERMISSION="No."
      ;;
    RECEIPT)
      if [ "$RECEIPT_PATH" = "none" ]; then
        NEXT_ACTION="Establish whether a native update receipt exists for this install before claiming update health; do not fabricate or edit one."
        NEXT_COMMAND="ls -la \"$HERMES_HOME_DIR/logs/update_receipts\" 2>&1 || true"
        NEXT_PERMISSION="No; reading evidence only."
      else
        NEXT_ACTION="Read the native receipt follow-ups and complete the exact deferred step; exit code 0 alone is not success."
        NEXT_COMMAND="jq '{outcome,followups,gateway_restart}' $RECEIPT_PATH"
        NEXT_PERMISSION="No; reading evidence only."
      fi
      ;;
    *)
      NEXT_ACTION="Rerun the read-only check and inspect the first failed row."
      NEXT_COMMAND="bash skills/hermes-linux/scripts/hermes.sh check"
      NEXT_PERMISSION="No."
      ;;
  esac
}

write_report() {
  local operation="$1"
  local phase_for_report="$FAILURE_PHASE"
  [ "$phase_for_report" = "NONE" ] && phase_for_report="NONE"
  next_action_for_phase "$phase_for_report"
  local utc
  utc=$(date -u +%Y%m%dT%H%M%SZ)
  local safe_host
  safe_host=$(printf '%s' "$HOST_NAME" | tr -c 'A-Za-z0-9._-' '_')
  mkdir -p "$REPORT_ROOT/$safe_host" 2>/dev/null || true
  REPORT_PATH="$REPORT_ROOT/$safe_host/${utc}-${operation}.md"
  local version_before="$HERMES_VERSION_BEFORE"
  local version_after="$HERMES_VERSION_AFTER"
  [ "$operation" = check ] && version_after="not applicable (check is read-only)"

  {
    printf '# Hermes Operations — Incident Report (%s)\n\n' "$operation"
    printf '> Generated by `skills/hermes-linux/scripts/hermes.sh` v%s. Redacted. Do not commit.\n\n' "$SCRIPT_VERSION"
    printf '## 1. Verdict\n\n'
    printf -- '- **Status:** `%s`\n' "$STATUS"
    printf -- '- **Operation:** `%s`\n' "$operation"
    printf -- '- **Failure phase and classification:** `%s`\n' "$phase_for_report"
    printf -- '- **One-line summary:** %s\n\n' "$(printf '%s' "$SUMMARY" | evidence 3 500)"
    printf '## 2. Exact environment\n\n'
    printf '| Field | Observed value |\n|---|---|\n'
    printf '| Timestamp (UTC) | %s (started %s) |\n' "$(md_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "$(md_escape "$OPERATION_STARTED_UTC")"
    printf '| Host / operating system | %s / %s |\n' "$(md_escape "$HOST_NAME")" "$(md_escape "$OS_NAME")"
    printf '| Effective account and supervisor scope | %s (uid %s); gateway=%s backend=%s |\n' \
      "$(md_escape "$EFFECTIVE_USER")" "$(md_escape "$EFFECTIVE_UID")" \
      "$(md_escape "${GATEWAY_SCOPE:-unknown}")" "$(md_escape "${SERVE_SCOPE:-none}")"
    printf '| Hermes executable path | %s |\n' "$(md_escape "${HERMES_BIN:-not found}")"
    printf '| Installation type / Windows package owner | %s / not applicable (Linux) |\n' "$(md_escape "$INSTALL_KIND")"
    printf '| Installed version before/after | v%s / %s |\n' "$(md_escape "$version_before")" "$(md_escape "$version_after")"
    printf '| Upstream stable target / distributor channel | %s / %s |\n' "$(md_escape "v$STABLE_TARGET (${STABLE_TARGET_SHA:-unknown})")" "$(md_escape "$CHANNEL")"
    printf '| Backend URL (no userinfo or tokens) | %s (source: %s) |\n' "$(md_escape "${BACKEND_URL_DISPLAY:-not discovered}")" "$(md_escape "$BACKEND_URL_SOURCE")"
    printf '| Mutations actually made | %s |\n\n' "$(md_escape "$MUTATIONS")"
    printf '## 3. Expected vs actual\n\n'
    printf '| Check | Expected | Actual | PASS/FAIL/NOT_TESTED/UNKNOWN |\n|---|---|---|---|\n'
    cat "$CHECK_ROWS"
    printf '\n## 4. Timeline and last successful step\n\n'
    printf '| Step | Command or verification | Exit/status | Sanitized evidence |\n|---|---|---|---|\n'
    cat "$TIMELINE_ROWS"
    printf '\n**Last confirmed successful step:** %s\n' \
      "$(tac "$TIMELINE_ROWS" 2>/dev/null | awk -F'|' '$4 ~ /exit 0|HTTP 2[0-9][0-9]|PASS/ {print $2 "|" $3; exit}' | md_escape | awk 'NF{print; found=1} END{if(!found) print "none recorded"}')"
    printf '**First confirmed failed step:** %s\n\n' \
      "$(grep -m1 -E '\| (FAIL|exit [1-9][0-9]*) \|' "$TIMELINE_ROWS" 2>/dev/null | cut -d'|' -f2-3 | md_escape | awk 'NF{print; found=1} END{if(!found) print "none observed"}')"
    printf '## 5. Exact errors and references\n\n'
    printf -- '- **Error text (redacted, concise):** %s\n' "$(printf '%s' "$SUMMARY" | evidence 3 500)"
    printf -- '- **Hermes receipt:** `%s`; outcome=`%s`; followups=%s%s; gateway_restart.incomplete=%s\n' \
      "$(md_escape "$RECEIPT_PATH")" "$(md_escape "$RECEIPT_OUTCOME")" \
      "$(md_escape "$RECEIPT_FOLLOWUP_COUNT")" \
      "$([ -n "$RECEIPT_FOLLOWUP_TEXT" ] && printf ' (%s)' "$(printf '%s' "$RECEIPT_FOLLOWUP_TEXT" | evidence 2 400)")" \
      "$(md_escape "$RECEIPT_GATEWAY_INCOMPLETE")"
    printf -- '- **Relevant systemd unit / journal excerpt:** gateway=`%s` (%s); backend=`%s` (%s)\n' \
      "$(md_escape "${GATEWAY_UNIT:-none}")" "$(md_escape "$GATEWAY_ACTIVE")" \
      "$(md_escape "${SERVE_UNIT:-none}")" "$(md_escape "$SERVE_ACTIVE")"
    if [ "$SERVICE_JOURNAL" != "not collected" ]; then
      printf '\n```text\n%s\n```\n' "$(printf '%s' "$SERVICE_JOURNAL" | sanitize_text | cut -c1-500)"
    fi
    printf -- '- **Relevant Windows installer/WinGet error and exit code:** not applicable on Linux\n'
    if [ -n "$UPDATE_OUTPUT_TAIL" ]; then
      printf -- '- **Updater output (bounded, redacted):** %s\n' "$(printf '%s' "$UPDATE_OUTPUT_TAIL" | evidence 5 700)"
    fi
    printf -- '- **HTTP status / response type / WebSocket close code, if tested:** HTTP %s; type=%s; protocol=%s; WS=NOT_TESTED\n' \
      "$(md_escape "$HTTP_CODE")" "$(md_escape "$HTTP_CONTENT_TYPE")" "$(md_escape "$HTTP_PROTOCOL")"
    printf -- '- **Evidence files kept locally (do not upload automatically):** `%s`; updater output kept only as a bounded redacted excerpt\n\n' "$(md_escape "$REPORT_PATH")"
    printf '## 6. Diagnosis and impact\n\n'
    printf '**Recorded blockers, degradations, and unverified essentials (exact reasons):**\n\n'
    if [ -s "$BLOCKED_FILE" ] || [ -s "$DEGRADED_FILE" ] || [ -s "$UNVERIFIED_FILE" ]; then
      while IFS='|' read -r phase reason; do
        [ -n "$phase" ] && printf -- '- [%s] %s\n' "$phase" "$(printf '%s' "$reason" | md_escape)"
      done < <(cat "$BLOCKED_FILE" "$DEGRADED_FILE" "$UNVERIFIED_FILE" 2>/dev/null)
    else
      printf -- '- None.\n'
    fi
    printf '\n**Confirmed cause(s) with evidence:**\n\n'
    if [ -s "$CONFIRMED_FILE" ]; then cat "$CONFIRMED_FILE"; else printf -- '- No single confirmed failure cause; see failed rows above.\n'; fi
    printf '\n**Likely cause(s), explicitly labeled hypotheses:**\n\n'
    if [ -s "$LIKELY_FILE" ]; then cat "$LIKELY_FILE"; else printf -- '- None asserted without evidence.\n'; fi
    printf '\n**Unknowns / tests not performed:**\n\n'
    cat "$UNKNOWN_FILE"
    printf '\n**What still works:**\n\n'
    if [ -s "$WORKS_FILE" ]; then cat "$WORKS_FILE"; else printf -- '- Not established.\n'; fi
    printf '\n**What is degraded / number of affected profiles:**\n\n'
    printf -- '- Expected profiles: %s; served: %s; missing: %s\n' "$EXPECTED_PROFILE_COUNT" "$SERVED_PROFILE_COUNT" "$(printf '%s' "${MISSING_PROFILES:-none}" | md_escape)"
    if [ -s "$AFFECTED_FILE" ]; then cat "$AFFECTED_FILE"; fi
    printf '\n**Any service stopped or left running:**\n\n'
    printf -- '- Gateway `%s` is `%s`; backend `%s` is `%s`.\n' \
      "$(md_escape "${GATEWAY_UNIT:-none}")" "$(md_escape "$GATEWAY_ACTIVE")" \
      "$(md_escape "${SERVE_UNIT:-none}")" "$(md_escape "$SERVE_ACTIVE")"
    printf '\n## 7. Lowest-risk next action\n\n'
    printf -- '- **Recommended action (exactly one first action):** %s\n' "$(printf '%s' "$NEXT_ACTION" | evidence 3 500)"
    printf -- '- **Exact command, only if confirmed safe:** `%s`\n' "$(md_escape "$NEXT_COMMAND")"
    printf -- '- **Requires new permission or credentials?** %s\n' "$(md_escape "$NEXT_PERMISSION")"
    printf -- '- **Actions deliberately NOT taken and why:** No reinstall, reset, stash discard, forced update, migration, firewall/auth change, unit creation, credential change, or retry loop. Check mode is read-only; update mode issued at most one official updater command.\n'
    if [ -s "$WARNINGS_FILE" ]; then
      printf '\n**Warnings recorded (non-fatal):**\n\n'
      cat "$WARNINGS_FILE"
    fi
    printf '\n## 8. Re-verification / closure\n\n'
    printf -- '- **Commands to rerun:** `bash skills/hermes-linux/scripts/hermes.sh check`; for updates also inspect the latest native receipt.\n'
    printf -- '- **Criteria for `HEALTHY`/`UPDATED`:** gateway active; all expected profiles served; backend active with a refreshed PID; `/api/status` returns Hermes JSON; receipt outcome ok/success with zero follow-ups; no unapproved topology change.\n'
    printf -- '- **Current incident state:** `%s`\n\n' "$([ "$EXIT_CODE" -eq 0 ] && echo VERIFIED_RESOLVED || echo OPEN)"
    printf -- '---\n\n**Security:** generated locally and redacted. Never include raw `.env`, auth stores, cookies, bearer headers, API tokens, SSH keys, or unsanitized journal/environment output. This report is ignored by Git.\n'
  } >"$REPORT_PATH" 2>/dev/null
  chmod 600 "$REPORT_PATH" 2>/dev/null || true
  return 0
}

print_summary() {
  say ""
  say "STATUS: $STATUS"
  say "SUMMARY: $SUMMARY"
  if [ "$STATUS" = BLOCKED ] || [ "$STATUS" = FAILED ] || [ "$STATUS" = PARTIAL ] || [ "$STATUS" = DEGRADED ] || [ "$STATUS" = UNKNOWN ]; then
    say "FAILURE PHASE: $FAILURE_PHASE"
  fi
  say "REPORT: $REPORT_PATH"
  if [ -n "$BACKEND_URL_DISPLAY" ] && [ "$BACKEND_URL_DISPLAY" != unknown ]; then
    say "BACKEND: $BACKEND_URL_DISPLAY ($HTTP_CHECK)"
  fi
  if [ "$MODE" = update ] && [ "$MUTATIONS" != none ]; then
    say "MUTATIONS: $MUTATIONS"
  fi
  say "EXIT: $EXIT_CODE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  say "Hermes Operations (Linux) v$SCRIPT_VERSION — mode=$MODE"
  say "Host: $(hostname -s 2>/dev/null || echo unknown) — read-only discovery first"
  collect_all "preflight"

  if [ "$MODE" = check ]; then
    decide_check
    write_report check
    print_summary
    exit "$EXIT_CODE"
  fi

  if ! update_preflight; then
    STATUS="BLOCKED"
    EXIT_CODE=2
    SUMMARY=$(head -n 1 "$BLOCKED_FILE" | cut -d'|' -f2-)
    add_unknown "No update command was run; the live deployment was not mutated"
    add_works "Preflight completed read-only; the previous installed version remains in place"
    add_affected "No service was restarted; the existing install may still be behind stable"
    write_report update
    print_summary
    exit "$EXIT_CODE"
  fi

  # Preflight passed. Record exactly what was true before mutation.
  PRE_SERVE_ACTIVE="$SERVE_ACTIVE"
  PRE_GATEWAY_UNIT="$GATEWAY_UNIT"
  PRE_GATEWAY_SCOPE="$GATEWAY_SCOPE"
  PRE_GATEWAY_USER="$GATEWAY_USER"
  PRE_GATEWAY_EXEC="$GATEWAY_EXEC"
  PRE_SERVE_UNIT="$SERVE_UNIT"
  PRE_SERVE_SCOPE="$SERVE_SCOPE"
  PRE_SERVE_USER="$SERVE_USER"
  PRE_SERVE_UNIT_EXISTS="$SERVE_UNIT_EXISTS"
  GIT_HEAD_BEFORE="$GIT_HEAD"
  STABLE_TARGET_BEFORE="$STABLE_TARGET"
  STABLE_TARGET_SHA_BEFORE="$STABLE_TARGET_SHA"
  REGISTERED_PROFILES_BEFORE="$REGISTERED_PROFILES"
  PARKED_PROFILES_BEFORE="$PARKED_PROFILES"
  STANDALONE_PROFILES_BEFORE="$STANDALONE_PROFILES"
  if [ "$UPDATE_AVAILABLE" = no ]; then
    UPDATE_NEEDED="no"
    UPDATE_EXIT="not run"
  else
    perform_update
  fi

  # Re-collect post-state read-only. Keep timeline; replace check rows so the
  # report's comparison table reflects verified post-update state.
  : >"$CHECK_ROWS"
  : >"$BLOCKED_FILE"
  : >"$DEGRADED_FILE"
  : >"$UNVERIFIED_FILE"
  collect_all "post-update"
  if [ "$UPDATE_NEEDED" = yes ] && [ "$HERMES_VERSION" != unknown ]; then
    HERMES_VERSION_AFTER="$HERMES_VERSION"
  fi
  # Never restart services after a failed updater run: diagnose the code and
  # existing service state first, as required by the operations spec.
  if [ "$UPDATE_NEEDED" = yes ] && [ "$UPDATE_EXIT" = "0" ]; then
    # Hermes owns service lifecycle. Verify backend readiness with bounded polling.
    if [ -n "$BACKEND_URL" ]; then
      poll_backend_ready || true
    fi
    verify_gateway_runtime
    verify_backend_runtime
    verify_profile_inventory
  fi
  decide_update
  write_report update
  print_summary
  exit "$EXIT_CODE"
}

main "$@"
