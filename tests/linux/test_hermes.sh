#!/usr/bin/env bash
# Focused mock-driven tests for skills/hermes-linux/scripts/hermes.sh.
# No network, no real systemd, no live Hermes installation is touched.
set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/skills/hermes-linux/scripts/hermes.sh"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/hermes-ops-linux-tests.XXXXXX")
trap 'if [ "${KEEP_TESTS:-0}" != 1 ]; then rm -rf "$BASE"; fi' EXIT

PASS=0
FAIL=0
FAILED_NAMES=""

ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES="${FAILED_NAMES} $1"; printf 'FAIL  %s: %s\n' "$1" "$2"; }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$name"; else bad "$name" "expected '$expected', got '$actual'"; fi
}

assert_contains() {
  local name="$1" needle="$2" file="$3"
  if grep -Fq -- "$needle" "$file" 2>/dev/null; then ok "$name"; else bad "$name" "missing '$needle' in $file"; fi
}

assert_not_contains() {
  local name="$1" needle="$2" file="$3"
  if grep -Fq -- "$needle" "$file" 2>/dev/null; then bad "$name" "unexpected '$needle' in $file"; else ok "$name"; fi
}

count_matches() {
  local needle="$1" file="$2"
  grep -Fc -- "$needle" "$file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Sandbox construction
# ---------------------------------------------------------------------------
new_sandbox() {
  local name="$1"
  SBX="$BASE/$name"
  mkdir -p "$SBX/bin" "$SBX/home/.hermes/logs/update_receipts" "$SBX/reports" \
           "$SBX/fixtures" "$SBX/pids" "$SBX/checkout/.hermes/bin"
  export FAKE_SBX="$SBX"
  export FAKE_CHECKOUT="$SBX/checkout"
  : >"$SBX/calls.log"

  # Fake source checkout with official provenance.
  git -C "$SBX/checkout" init -q
  git -C "$SBX/checkout" config user.email "test@example.invalid"
  git -C "$SBX/checkout" config user.name "Hermes Ops Test"
  printf '#!/bin/sh\nexec "%s/.hermes/bin/hermes" "$@"\n' "$SBX/checkout" >"$SBX/checkout/.hermes/bin/hermes"
  chmod +x "$SBX/checkout/.hermes/bin/hermes"
  echo "test checkout" >"$SBX/checkout/README"
  git -C "$SBX/checkout" add README .hermes/bin/hermes
  git -C "$SBX/checkout" commit -q -m "initial"
  git -C "$SBX/checkout" remote add origin https://github.com/NousResearch/hermes-agent.git
  git -C "$SBX/checkout" checkout -q --detach HEAD

  # Fixtures.
  cat >"$SBX/fixtures/version.txt" <<EOF
Hermes Agent v0.23.2 (2026.9.24) · stable · local $(git -C "$SBX/checkout" rev-parse --short=12 HEAD)
Install directory: $SBX/checkout
Install method: git
Python: 3.14.9
EOF
  cat >"$SBX/fixtures/version_after.txt" <<EOF
Hermes Agent v0.23.3 (2026.11.20) · stable · local $(git -C "$SBX/checkout" rev-parse --short=12 HEAD)
Install directory: $SBX/checkout
Install method: git
Python: 3.14.9
EOF
  cat >"$SBX/fixtures/update_check.txt" <<'EOF'
→ Update channel: stable
→ Selected release available: stable v0.23.3 (caafe5389ae5)
  Run `hermes update` to install it.
EOF
  cat >"$SBX/fixtures/update_current.txt" <<'EOF'
→ Update channel: stable
→ Already up to date: stable v0.23.3
EOF
  cat >"$SBX/fixtures/migrate.txt" <<'EOF'
Migration plan (dry run — nothing changed)
  ✓ The default gateway is already multiplexing (serving default, alpha, beta).
EOF
  cat >"$SBX/fixtures/migrate_risk.txt" <<'EOF'
Migration plan (dry run — nothing changed)
  profile old-a    gateway pid 111   systemd (system)
  → would migrate old-a into the default multiplexed gateway
EOF
  cat >"$SBX/fixtures/profile_list.txt" <<'EOF'
 Profile     Model       Gateway   Alias   Distribution
 ─────────   ─────────   ───────   ─────   ────────────
 ◆default    model        running   —       —
  alpha      model        running   alpha   —
  beta       model        running   beta    —
EOF
  cat >"$SBX/fixtures/doctor.txt" <<'EOF'
◆ Required Packages
  ✓ OpenAI SDK
  ⚠ optional-provider (optional, not installed)
EOF
  cat >"$SBX/fixtures/gateway_status.txt" <<'EOF'
✓ System gateway service is running
Configured to run as: ubuntu
✓ System service starts at boot without requiring systemd linger
EOF
  : >"$SBX/fixtures/user_units.txt"
  cat >"$SBX/fixtures/sys_units.txt" <<'EOF'
hermes-gateway.service enabled enabled
hermes-serve.service enabled enabled
hermes-tunnel.service enabled enabled
EOF
  cat >"$SBX/fixtures/http_body.json" <<'EOF'
{"version":"0.23.2","auth_required":true,"auth_providers":["basic"],"gateway_running":true,"overall":"ok","profiles":["default","alpha","beta"],"components":{"dashboard":{"status":"ok"}}}
EOF
  echo "200" >"$SBX/fixtures/http_code.txt"
  echo "5151" >"$SBX/pids/serve"
  echo "4242" >"$SBX/pids/gateway"
  write_receipt "$SBX/home/.hermes/logs/update_receipts/update_20260101_000000_initial.json" 0
  touch -d '2026-01-01 00:00:00 UTC' "$SBX/home/.hermes/logs/update_receipts/update_20260101_000000_initial.json"

  install_mocks
}

write_receipt() {
  local path="$1" followups="$2" outcome="${3:-success}"
  if [ "$followups" -gt 0 ]; then
    cat >"$path" <<EOF
{"schema":1,"outcome":"$outcome","followups":[{"step":"gateway_restart","reason":"serve/dashboard unit(s) hermes-serve were not restarted"}],"gateway_restart":{"incomplete":true,"failed_units":["hermes-serve"]}}
EOF
  else
    cat >"$path" <<EOF
{"schema":1,"outcome":"$outcome","followups":[],"gateway_restart":{"incomplete":false,"failed_units":[]},"desktop":{"status":"ok"}}
EOF
  fi
}

install_mocks() {
  # hermes mock -------------------------------------------------------------
  cat >"$SBX/bin/hermes" <<'MOCK'
#!/usr/bin/env bash
set -u
log="$FAKE_SBX/calls.log"
printf '%s\n' "$*" >>"$log"
fixtures="$FAKE_SBX/fixtures"
current_version() { grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$fixtures/version.txt" | head -n1 | tr -d v; }
case "${1:-}" in
  --version)
    sed "s#@CHECKOUT@#$FAKE_CHECKOUT#g" "$fixtures/version.txt" ;;
  update)
    case "${2:-}" in
      --install-id) echo "test-install-id" ;;
      --check)
        if grep -q 'v0.23.3' "$fixtures/version.txt"; then cat "$fixtures/update_current.txt"; else cat "$fixtures/update_check.txt"; fi ;;
      --plan)
        rev=$(git -C "$FAKE_CHECKOUT" rev-parse --short=8 HEAD)
        printf 'Update plan:\n  Install: git (v%s @ %s)\n  Profiles: default, alpha, beta\n  Running services to restart (2):\n    • gateway [default] pid %s — systemd @ %s\n      restart: systemctl restart (drain-first SIGUSR1 when supported)\n    • dashboard [default] pid %s — systemd\n      restart: systemctl restart (drain-first SIGUSR1 when supported)\n' \
          "$(current_version)" "$rev" "$(cat "$FAKE_SBX/pids/gateway")" "$rev" "$(cat "$FAKE_SBX/pids/serve")" ;;
      --set-channel)
        if [ -f "$fixtures/update_fail" ]; then echo "simulated updater failure"; exit 1; fi
        cp "$fixtures/version_after.txt" "$fixtures/version.txt"
        if [ ! -f "$fixtures/no_upstream_gateway_restart" ]; then
          echo $(( $(cat "$FAKE_SBX/pids/gateway") + 100 )) >"$FAKE_SBX/pids/gateway"
        fi
        if [ -f "$fixtures/upstream_restarts_serve" ]; then
          echo $(( $(cat "$FAKE_SBX/pids/serve") + 100 )) >"$FAKE_SBX/pids/serve"
        fi
        if [ -f "$fixtures/receipt_followup_after" ]; then
          write_followup="$fixtures/../home/.hermes/logs/update_receipts/update_$(date +%s%N).json"
          printf '%s\n' '{"schema":1,"outcome":"success","followups":[{"step":"gateway_restart","reason":"deferred backend restart"}],"gateway_restart":{"incomplete":true}}' >"$write_followup"
        else
          printf '%s\n' '{"schema":1,"outcome":"success","followups":[],"gateway_restart":{"incomplete":false},"desktop":{"status":"ok"}}' >"$FAKE_SBX/home/.hermes/logs/update_receipts/update_$(date +%s%N).json"
        fi
        echo "simulated successful update" ;;
      *) echo "unsupported update args: $*" >&2; exit 9 ;;
    esac ;;
  gateway)
    case "${2:-}" in
      status) cat "$fixtures/gateway_status.txt" ;;
      restart)
        echo $(( $(cat "$FAKE_SBX/pids/gateway") + 200 )) >"$FAKE_SBX/pids/gateway"
        echo "simulated gateway restart" ;;
      migrate) cat "$fixtures/migrate.txt" ;;
      *) echo "unsupported gateway args: $*" >&2; exit 9 ;;
    esac ;;
  profile) [ "${2:-}" = list ] && cat "$fixtures/profile_list.txt" || exit 9 ;;
  doctor) cat "$fixtures/doctor.txt" ;;
  pm) echo '{"outcome":"ok","followups":[]}' ;;
  *) echo "unexpected hermes args: $*" >&2; exit 9 ;;
esac
MOCK

  # systemctl mock ----------------------------------------------------------
  cat >"$SBX/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -u
scope=system
if [ "${1:-}" = "--user" ]; then scope=user; shift; fi
cmd="${1:-}"; shift || true
log="$FAKE_SBX/calls.log"
fixtures="$FAKE_SBX/fixtures"
case "$cmd" in
  list-unit-files)
    if [ "$scope" = user ]; then cat "$fixtures/user_units.txt"; else cat "$fixtures/sys_units.txt"; fi ;;
  show)
    unit="${1:-}"; shift || true
    field=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -p) field="${2:-}"; shift 2 ;;
        --value) shift ;;
        *) shift ;;
      esac
    done
    active=active
    if [ -f "$fixtures/unit_inactive_$unit" ]; then active=inactive; fi
    case "$unit" in
      hermes-gateway.service)
        pid=$(cat "$FAKE_SBX/pids/gateway" 2>/dev/null || echo 0)
        desc="Hermes Agent Gateway - Messaging Platform Integration"
        exec="{ path=$FAKE_CHECKOUT/.hermes/bin/hermes ; argv[]=$FAKE_CHECKOUT/.hermes/bin/hermes gateway run ; }"
        if [ -f "$fixtures/gateway_wrong_checkout" ]; then exec="{ path=/opt/other/hermes ; argv[]=/opt/other/hermes gateway run ; }"; fi
        ;;
      hermes-serve.service)
        pid=$(cat "$FAKE_SBX/pids/serve" 2>/dev/null || echo 0)
        desc="Hermes Desktop Remote Gateway"
        exec="{ path=$FAKE_CHECKOUT/.hermes/bin/hermes ; argv[]=$FAKE_CHECKOUT/.hermes/bin/hermes dashboard --host 127.0.0.1 --port 9119 --no-open ; }"
        ;;
      hermes-tunnel.service)
        pid=999
        desc="Hermes private tunnel"
        exec="{ path=/usr/local/bin/tunnel-client ; argv[]=tunnel-client run ; }"
        ;;
      *) pid=0; desc="unknown"; exec="{ path=/bin/false ; argv[]=/bin/false ; }" ;;
    esac
    if [ "$active" = inactive ]; then pid=0; fi
    case "$field" in
      ActiveState) echo "$active" ;;
      SubState) [ "$active" = active ] && echo running || echo dead ;;
      MainPID) echo "$pid" ;;
      User) if [ "$scope" = user ]; then echo ""; else echo "ubuntu"; fi ;;
      Description) echo "$desc" ;;
      ExecStart) echo "$exec" ;;
      *) echo "" ;;
    esac ;;
  restart)
    unit="${1:-}"; printf 'restart %s\n' "$unit" >>"$log"
    if [ "$unit" = hermes-serve.service ]; then
      echo $(( $(cat "$FAKE_SBX/pids/serve") + 100 )) >"$FAKE_SBX/pids/serve"
    elif [ "$unit" = hermes-gateway.service ]; then
      echo $(( $(cat "$FAKE_SBX/pids/gateway") + 100 )) >"$FAKE_SBX/pids/gateway"
    fi
    exit 0 ;;
  status) echo "simulated systemctl status" ;;
  *) exit 0 ;;
esac
MOCK

  # curl mock ---------------------------------------------------------------
  cat >"$SBX/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -u
out=""; hdr=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    -m|--connect-timeout) shift 2 ;;
    -w) shift 2 ;;
    -s|-S|-sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ -f "$FAKE_SBX/fixtures/http_network_fail" ]; then exit 7; fi
[ -n "$out" ] && cp "$FAKE_SBX/fixtures/http_body.json" "$out"
[ -n "$hdr" ] && printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\n' "$(cat "$FAKE_SBX/fixtures/http_code.txt")" >"$hdr"
printf '%s|application/json|0.01\n' "$(cat "$FAKE_SBX/fixtures/http_code.txt")"
MOCK

  # ss mock -----------------------------------------------------------------
  cat >"$SBX/bin/ss" <<'MOCK'
#!/usr/bin/env bash
pid=$(cat "$FAKE_SBX/pids/serve")
printf 'LISTEN 0 2048 127.0.0.1:9119 0.0.0.0:* users:(("hermes",pid=%s,fd=9))\n' "$pid"
MOCK

  # loginctl mock -----------------------------------------------------------
  cat >"$SBX/bin/loginctl" <<'MOCK'
#!/usr/bin/env bash
echo yes
MOCK

  # sudo mock ---------------------------------------------------------------
  cat >"$SBX/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo-invoked\n' >>"$FAKE_SBX/calls.log"
if [ -f "$FAKE_SBX/fixtures/no_sudo" ]; then exit 1; fi
if [ "${1:-}" = "-n" ]; then shift; fi
exec "$@"
MOCK

  # journalctl mock ---------------------------------------------------------
  cat >"$SBX/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
printf 'fake journal: backend failed to start\nAuthorization: Bearer super-secret-token-value\n'
MOCK

  chmod +x "$SBX/bin/"*
}

run_script() {
  local dir="$1"; shift
  env PATH="$dir/bin:/usr/bin:/bin" HOME="$dir/home" \
      HERMES_HOME="$dir/home/.hermes" HERMES_OPS_REPORT_DIR="$dir/reports" \
      FAKE_SBX="$dir" FAKE_CHECKOUT="$dir/checkout" \
      bash "$SCRIPT" "$@" >"$dir/stdout.txt" 2>"$dir/stderr.txt"
  echo $? >"$dir/status.txt"
}

status_of() { cat "$1/status.txt"; }
report_of() { find "$1/reports" -type f -name '*.md' | head -n 1; }

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
test_check_healthy() {
  new_sandbox check_healthy
  run_script "$SBX" check
  assert_eq "check healthy exit" "0" "$(status_of "$SBX")"
  assert_contains "check healthy status" "STATUS: HEALTHY" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "check healthy report" '`HEALTHY`' "$report"
  assert_not_contains "check is non-mutating (no set-channel)" "--set-channel" "$SBX/calls.log"
  assert_not_contains "check is non-mutating (no restart)" "restart hermes-serve.service" "$SBX/calls.log"
  assert_contains "check did run update --check" "update --check" "$SBX/calls.log"
}

test_check_dirty_checkout() {
  new_sandbox check_dirty
  echo "local edit" >>"$SBX/checkout/README"
  run_script "$SBX" check
  assert_eq "dirty check exit" "1" "$(status_of "$SBX")"
  assert_contains "dirty check verdict" "STATUS: DEGRADED" "$SBX/stdout.txt"
  assert_contains "dirty check reason" "uncommitted changes" "$SBX/stdout.txt"
  assert_not_contains "dirty check does not update" "--set-channel" "$SBX/calls.log"
}

test_check_root_blocked() {
  new_sandbox check_root
  cat >"$SBX/bin/id" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  -u) echo 0 ;;
  -un) echo root ;;
  *) exec /usr/bin/id "$@" ;;
esac
MOCK
  chmod +x "$SBX/bin/id"
  run_script "$SBX" check
  assert_eq "root check exit" "2" "$(status_of "$SBX")"
  assert_contains "root check verdict" "STATUS: BLOCKED" "$SBX/stdout.txt"
  assert_contains "root check reason" "not root" "$SBX/stdout.txt"
}

test_check_missing_hermes() {
  new_sandbox check_missing
  rm -f "$SBX/bin/hermes"
  run_script "$SBX" check
  assert_eq "missing hermes exit" "2" "$(status_of "$SBX")"
  assert_contains "missing hermes reason" "not found on PATH" "$SBX/stdout.txt"
}

test_check_conflicting_units() {
  new_sandbox check_conflict
  echo "hermes-gateway.service enabled enabled" >"$SBX/fixtures/user_units.txt"
  run_script "$SBX" check
  assert_eq "conflicting units exit" "2" "$(status_of "$SBX")"
  assert_contains "conflicting units reason" "both system" "$SBX/stdout.txt"
}

test_check_http_wrong_payload() {
  new_sandbox check_wrong_payload
  echo '{"hello":"world"}' >"$SBX/fixtures/http_body.json"
  run_script "$SBX" check
  assert_eq "wrong payload exit" "1" "$(status_of "$SBX")"
  assert_contains "wrong payload verdict" "STATUS: DEGRADED" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "wrong payload reason" "recognizable Hermes" "$report"
}

test_check_http_401() {
  new_sandbox check_401
  echo "401" >"$SBX/fixtures/http_code.txt"
  run_script "$SBX" check
  assert_eq "401 check exit" "1" "$(status_of "$SBX")"
  assert_contains "401 not treated as success" "STATUS: DEGRADED" "$SBX/stdout.txt"
  assert_contains "401 classified as auth" "AUTH" "$SBX/stdout.txt"
}

test_check_backend_down() {
  new_sandbox check_backend_down
  : >"$SBX/fixtures/unit_inactive_hermes-serve.service"
  run_script "$SBX" check
  assert_eq "backend down exit" "1" "$(status_of "$SBX")"
  assert_contains "backend down reported" "Desktop backend unit hermes-serve.service is inactive" "$SBX/stdout.txt"
}

test_check_receipt_followup() {
  new_sandbox check_followup
  rm -f "$SBX/home/.hermes/logs/update_receipts/"*.json
  write_receipt "$SBX/home/.hermes/logs/update_receipts/update_20260102_000000_followup.json" 1
  run_script "$SBX" check
  assert_eq "receipt followup exit" "1" "$(status_of "$SBX")"
  assert_contains "receipt followup verdict" "STATUS: DEGRADED" "$SBX/stdout.txt"
  assert_contains "receipt followup reported" "unresolved follow-up" "$SBX/stdout.txt"
}

test_check_wrong_checkout_binding() {
  new_sandbox check_wrong_binding
  : >"$SBX/fixtures/gateway_wrong_checkout"
  run_script "$SBX" check
  assert_eq "wrong checkout exit" "2" "$(status_of "$SBX")"
  assert_contains "wrong checkout reason" "does not resolve to the discovered checkout" "$SBX/stdout.txt"
}

test_update_blocked_dirty() {
  new_sandbox update_dirty
  echo "local edit" >>"$SBX/checkout/README"
  run_script "$SBX" update
  assert_eq "update dirty exit" "2" "$(status_of "$SBX")"
  assert_contains "update dirty verdict" "STATUS: BLOCKED" "$SBX/stdout.txt"
  assert_eq "update dirty made no update call" "0" "$(count_matches 'update --set-channel' "$SBX/calls.log")"
}

test_update_blocked_migration() {
  new_sandbox update_migration
  cp "$SBX/fixtures/migrate_risk.txt" "$SBX/fixtures/migrate.txt"
  run_script "$SBX" update
  assert_eq "update migration exit" "2" "$(status_of "$SBX")"
  assert_contains "update migration reason" "topology change" "$SBX/stdout.txt"
  assert_eq "update migration made no update call" "0" "$(count_matches 'update --set-channel' "$SBX/calls.log")"
}

test_update_blocked_sudo() {
  new_sandbox update_sudo
  : >"$SBX/fixtures/no_sudo"
  run_script "$SBX" update
  assert_eq "update no sudo exit" "2" "$(status_of "$SBX")"
  assert_contains "update no sudo reason" "passwordless sudo" "$SBX/stdout.txt"
  assert_eq "update no sudo made no update call" "0" "$(count_matches 'update --set-channel' "$SBX/calls.log")"
}

test_update_success() {
  new_sandbox update_success
  run_script "$SBX" update
  assert_eq "update success exit" "0" "$(status_of "$SBX")"
  assert_contains "update success verdict" "STATUS: UPDATED" "$SBX/stdout.txt"
  assert_eq "exactly one native update" "1" "$(count_matches 'update --set-channel' "$SBX/calls.log")"
  assert_eq "backend restarted exactly once" "1" "$(count_matches 'restart hermes-serve.service' "$SBX/calls.log")"
  local report
  report=$(report_of "$SBX")
  assert_contains "update report reflects new version" "v0.23.3" "$report"
  assert_contains "update report shows refreshed pid" "->" "$report"
  assert_not_contains "update did not use --no-backup" "--no-backup" "$SBX/calls.log"
}

test_update_respects_upstream_restart() {
  new_sandbox update_upstream_restart
  : >"$SBX/fixtures/upstream_restarts_serve"
  run_script "$SBX" update
  assert_eq "upstream restart exit" "0" "$(status_of "$SBX")"
  assert_eq "no duplicate backend restart" "0" "$(count_matches 'restart hermes-serve.service' "$SBX/calls.log")"
}

test_update_gateway_not_refreshed() {
  new_sandbox update_gateway_stale
  : >"$SBX/fixtures/no_upstream_gateway_restart"
  run_script "$SBX" update
  assert_eq "gateway stale exit" "0" "$(status_of "$SBX")"
  assert_contains "gateway manual restart issued once" "gateway restart" "$SBX/calls.log"
  assert_eq "one gateway restart" "1" "$(count_matches 'gateway restart' "$SBX/calls.log")"
}

test_update_partial_receipt() {
  new_sandbox update_partial
  : >"$SBX/fixtures/receipt_followup_after"
  run_script "$SBX" update
  assert_eq "update partial exit" "1" "$(status_of "$SBX")"
  assert_contains "update partial verdict" "STATUS: PARTIAL" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "update partial reason" "unresolved follow-up" "$report"
  assert_eq "partial still one update call" "1" "$(count_matches 'update --set-channel' "$SBX/calls.log")"
}

test_update_failed_no_retry() {
  new_sandbox update_failed
  : >"$SBX/fixtures/update_fail"
  run_script "$SBX" update
  assert_eq "update failed exit" "1" "$(status_of "$SBX")"
  assert_contains "update failed verdict" "STATUS: FAILED" "$SBX/stdout.txt"
  assert_eq "failed updater run exactly once" "1" "$(count_matches 'update --set-channel' "$SBX/calls.log")"
}

test_update_already_current() {
  new_sandbox update_current
  cp "$SBX/fixtures/version_after.txt" "$SBX/fixtures/version.txt"
  run_script "$SBX" update
  assert_eq "already current exit" "0" "$(status_of "$SBX")"
  assert_contains "already current verdict" "STATUS: ALREADY_CURRENT" "$SBX/stdout.txt"
  assert_eq "already current no updater call" "0" "$(count_matches 'update --set-channel' "$SBX/calls.log")"
}

test_check_no_backup_rejected() {
  new_sandbox check_no_backup
  run_script "$SBX" check --no-backup
  assert_eq "check --no-backup exit" "2" "$(status_of "$SBX")"
}

test_check_latest_plugin_check_ignored() {
  new_sandbox check_latest_plugin
  cat >"$SBX/home/.hermes/logs/update_receipts/latest.json" <<'EOF'
{"schema":1,"kind":"plugin-check","outcome":"error","followups":[{"step":"plugin","reason":"not an update receipt"}]}
EOF
  run_script "$SBX" check
  assert_eq "latest plugin-check exit" "0" "$(status_of "$SBX")"
  assert_contains "latest plugin-check ignored" "STATUS: HEALTHY" "$SBX/stdout.txt"
}

test_check_latest_update_receipt_used() {
  new_sandbox check_latest_update
  rm -f "$SBX/home/.hermes/logs/update_receipts/"update_*.json
  cat >"$SBX/home/.hermes/logs/update_receipts/latest.json" <<'EOF'
{"schema":1,"kind":null,"outcome":"success","followups":[{"step":"gateway_restart","reason":"deferred backend restart"}],"gateway_restart":{"incomplete":true}}
EOF
  run_script "$SBX" check
  assert_eq "latest update receipt exit" "1" "$(status_of "$SBX")"
  assert_contains "latest update receipt followup" "STATUS: DEGRADED" "$SBX/stdout.txt"
}

test_check_user_scope_units() {
  new_sandbox check_user_scope
  : >"$SBX/fixtures/sys_units.txt"
  cat >"$SBX/fixtures/user_units.txt" <<'EOF'
hermes-gateway.service enabled enabled
hermes-serve.service enabled enabled
EOF
  run_script "$SBX" check
  assert_eq "user scope exit" "0" "$(status_of "$SBX")"
  assert_contains "user scope healthy" "STATUS: HEALTHY" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "user scope recorded" "gateway=user backend=user" "$report"
}

test_check_redaction() {
  new_sandbox check_redaction
  cat >"$SBX/fixtures/gateway_status.txt" <<'EOF'
✓ System gateway service is running
System gateway error: Authorization: Bearer super-secret-token-value token=another-secret-value
EOF
  run_script "$SBX" check
  local report
  report=$(report_of "$SBX")
  assert_not_contains "report has no raw bearer token" "super-secret-token-value" "$report"
  assert_not_contains "report has no raw query token" "another-secret-value" "$report"
  assert_contains "report marks redaction" "[REDACTED]" "$report"
}

# ---------------------------------------------------------------------------
printf '== Linux hermes.sh tests ==\n'
test_check_healthy
test_check_dirty_checkout
test_check_root_blocked
test_check_missing_hermes
test_check_conflicting_units
test_check_http_wrong_payload
test_check_http_401
test_check_backend_down
test_check_receipt_followup
test_check_wrong_checkout_binding
test_update_blocked_dirty
test_update_blocked_migration
test_update_blocked_sudo
test_update_success
test_update_respects_upstream_restart
test_update_gateway_not_refreshed
test_update_partial_receipt
test_update_failed_no_retry
test_update_already_current
test_check_no_backup_rejected
test_check_latest_plugin_check_ignored
test_check_latest_update_receipt_used
test_check_user_scope_units
test_check_redaction

printf '\n== Result: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf 'Failed:%s\n' "$FAILED_NAMES"
  exit 1
fi
exit 0
