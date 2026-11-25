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
           "$SBX/fixtures" "$SBX/pids" "$SBX/state" "$SBX/checkout/.hermes/bin"
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
  git -C "$SBX/checkout" commit --allow-empty -q -m "updated"
  git -C "$SBX/checkout" rev-parse --short=8 HEAD >"$SBX/target-sha"
  git -C "$SBX/checkout" commit --allow-empty -q -m "wrong"
  git -C "$SBX/checkout" rev-parse --short=8 HEAD >"$SBX/wrong-sha"
  git -C "$SBX/checkout" checkout -q --detach HEAD~2

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
  printf '→ Update channel: stable\n→ Selected release available: stable v0.23.3 (%s)\n  Run hermes update to install it.\n' "$(cat "$SBX/target-sha")" >"$SBX/fixtures/update_check.txt"
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
        if [ -f "$fixtures/stale_gateway_plan" ] && grep -q 'v0.23.3' "$fixtures/version.txt"; then rev=$(git -C "$FAKE_CHECKOUT" rev-parse --short=8 HEAD~1); fi
        {
          echo "Update plan:"
          printf '  Install: git (v%s @ %s)\n' "$(current_version)" "$rev"
          [ ! -f "$fixtures/no_plan_profiles" ] && echo "  Profiles: default, alpha, beta"
          echo "  Running services to restart (2):"
          printf '    • gateway [default] pid %s — systemd @ %s\n' "$(cat "$FAKE_SBX/pids/gateway")" "$rev"
          echo "      restart: systemctl restart (drain-first SIGUSR1 when supported)"
          printf '    • dashboard [default] pid %s — systemd\n' "$(cat "$FAKE_SBX/pids/serve")"
          echo "      restart: systemctl restart (drain-first SIGUSR1 when supported)"
        } ;;
      --yes)
        if [ -f "$fixtures/update_fail" ]; then echo "simulated updater failure"; exit 1; fi
        if [ -f "$fixtures/update_no_install" ]; then echo "no code installed"; exit 0; fi
        if [ -f "$fixtures/advance_wrong_revision" ]; then
          git -C "$FAKE_CHECKOUT" checkout -q --detach "$(cat "$FAKE_SBX/wrong-sha")"
        elif [ ! -f "$fixtures/wrong_revision" ]; then
          git -C "$FAKE_CHECKOUT" checkout -q --detach "$(cat "$FAKE_SBX/target-sha")"
        fi
        cp "$fixtures/version_after.txt" "$fixtures/version.txt"
        if [ ! -f "$fixtures/stale_backend_after" ]; then
          sed -i 's/"version":"0.23.2"/"version":"0.23.3"/' "$fixtures/http_body.json"
        fi
        if [ -f "$fixtures/profile_disappear_after" ]; then
          grep -v 'alpha' "$fixtures/profile_list.txt" >"$fixtures/profile_list.tmp" && mv "$fixtures/profile_list.tmp" "$fixtures/profile_list.txt"
        fi
        if [ ! -f "$fixtures/no_upstream_gateway_restart" ]; then
          echo $(( $(cat "$FAKE_SBX/pids/gateway") + 100 )) >"$FAKE_SBX/pids/gateway"
        fi
        if [ -f "$fixtures/upstream_restarts_serve" ]; then
          echo $(( $(cat "$FAKE_SBX/pids/serve") + 100 )) >"$FAKE_SBX/pids/serve"
        fi
        if [ -f "$fixtures/post_update_conflict" ]; then
          echo "hermes-gateway.service enabled enabled" >"$fixtures/user_units.txt"
        fi
        if [ -f "$fixtures/receipt_missing_after" ]; then
          echo "simulated missing receipt"; exit 0
        fi
        cid="${HERMES_UPDATE_CORRELATION_ID:-}"
        if [ -f "$fixtures/receipt_bad_correlation" ]; then cid="wrong-correlation"; fi
        if [ -f "$fixtures/receipt_followup_after" ]; then
          write_followup="$fixtures/../home/.hermes/logs/update_receipts/update_$(date +%s%N).json"
          printf '{"correlation_id":"%s","outcome":"success","followups":[{"step":"gateway_restart","reason":"deferred backend restart"}],"gateway_restart":{"incomplete":true}}\n' "$cid" >"$write_followup"
        else
          printf '{"correlation_id":"%s","outcome":"success","followups":[],"gateway_restart":{"incomplete":false},"desktop":{"status":"ok"}}\n' "$cid" >"$FAKE_SBX/home/.hermes/logs/update_receipts/update_$(date +%s%N).json"
        fi
        if [ -f "$fixtures/unrelated_latest" ]; then
          printf '{"correlation_id":"unrelated","outcome":"failed","followups":[],"gateway_restart":{"incomplete":false}}\n' >"$FAKE_SBX/home/.hermes/logs/update_receipts/latest.json"
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
  profile)
    if [ "${2:-}" != list ]; then exit 9; fi
    if [ -f "$fixtures/profile_list_fail" ]; then echo "profile listing unavailable" >&2; exit 1; fi
    cat "$fixtures/profile_list.txt" ;;
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
    if [ "$scope" = user ]; then
      cat "$fixtures/user_units.txt"
      if [ -f "$fixtures/safety_scope_change" ] && [ "$(cat "$FAKE_SBX/state/sys_list_count" 2>/dev/null || echo 0)" -ge 5 ]; then
        grep -Fxq 'hermes-gateway.service' "$fixtures/user_units.txt" || echo 'hermes-gateway.service enabled enabled'
      fi
    else
      count=$(( $(cat "$FAKE_SBX/state/sys_list_count" 2>/dev/null || echo 0) + 1 ))
      echo "$count" >"$FAKE_SBX/state/sys_list_count"
      if [ -f "$fixtures/safety_discovery_fail" ] && [ "$count" -ge 5 ]; then
        echo "simulated systemd discovery failure" >&2
        exit 1
      fi
      if [ -f "$fixtures/safety_scope_change" ] && [ "$count" -ge 5 ]; then
        grep -v '^hermes-gateway.service ' "$fixtures/sys_units.txt"
      else
        cat "$fixtures/sys_units.txt"
      fi
    fi ;;
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
        if [ -f "$fixtures/serve_no_bind" ]; then
          exec="{ path=$FAKE_CHECKOUT/.hermes/bin/hermes ; argv[]=$FAKE_CHECKOUT/.hermes/bin/hermes dashboard --host 127.0.0.1 --no-open ; }"
        fi
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
      User)
        if [ "$unit" = "hermes-gateway.service" ]; then
          count=$(( $(cat "$FAKE_SBX/state/gateway_user_count" 2>/dev/null || echo 0) + 1 ))
          echo "$count" >"$FAKE_SBX/state/gateway_user_count"
          if [ -f "$fixtures/safety_owner_change" ] && [ "$count" -ge 3 ]; then
            echo "evil-user"
          elif [ "$scope" = user ]; then
            echo ""
          else
            echo "ubuntu"
          fi
        elif [ "$scope" = user ]; then
          echo ""
        else
          echo "ubuntu"
        fi ;;
      Description) echo "$desc" ;;
      ExecStart)
        if [ "$unit" = "hermes-gateway.service" ]; then
          count=$(( $(cat "$FAKE_SBX/state/gateway_exec_count" 2>/dev/null || echo 0) + 1 ))
          echo "$count" >"$FAKE_SBX/state/gateway_exec_count"
          if [ -f "$fixtures/safety_checkout_rebind" ]; then
            exec="{ path=$FAKE_SBX/exec/hermes ; argv[]=$FAKE_SBX/exec/hermes gateway run ; }"
            if [ "$count" -ge 3 ]; then
              ln -sfn "$FAKE_SBX/other/hermes" "$FAKE_SBX/exec/hermes"
            fi
          fi
          if [ -f "$fixtures/safety_checkout_change" ] && [ "$count" -ge 3 ]; then
            exec="{ path=/opt/other/hermes ; argv[]=/opt/other/hermes gateway run ; }"
          fi
          if [ -f "$fixtures/safety_incomplete_evidence" ] && [ "$count" -ge 3 ]; then
            exec=""
          fi
        elif [ "$unit" = "hermes-serve.service" ]; then
          count=$(( $(cat "$FAKE_SBX/state/serve_exec_count" 2>/dev/null || echo 0) + 1 ))
          echo "$count" >"$FAKE_SBX/state/serve_exec_count"
          if [ -f "$fixtures/safety_backend_change" ] && [ "$count" -ge 3 ]; then
            exec="{ path=/opt/other/hermes ; argv[]=/opt/other/hermes dashboard --host 127.0.0.1 --port 9119 --no-open ; }"
          fi
        fi
        echo "$exec" ;;
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
if [ -f "$FAKE_SBX/fixtures/delayed_backend_recovery" ]; then
  count=$(( $(cat "$FAKE_SBX/state/curl_count" 2>/dev/null || echo 0) + 1 ))
  echo "$count" >"$FAKE_SBX/state/curl_count"
  limit=$(cat "$FAKE_SBX/fixtures/delayed_backend_fail_count" 2>/dev/null || echo 2)
  if [ "$count" -le "$limit" ]; then exit 7; fi
fi
[ -n "$out" ] && cp "$FAKE_SBX/fixtures/http_body.json" "$out"
[ -n "$hdr" ] && printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\n' "$(cat "$FAKE_SBX/fixtures/http_code.txt")" >"$hdr"
printf '%s|application/json|0.01\n' "$(cat "$FAKE_SBX/fixtures/http_code.txt")"
MOCK

  # ss mock -----------------------------------------------------------------
  cat >"$SBX/bin/ss" <<'MOCK'
#!/usr/bin/env bash
if [ -f "$FAKE_SBX/fixtures/serve_no_bind" ]; then exit 0; fi
pid=$(cat "$FAKE_SBX/pids/serve")
addr="127.0.0.1:9119"
if [ -f "$FAKE_SBX/fixtures/backend_wildcard_after" ] && grep -q 'v0.23.3' "$FAKE_SBX/fixtures/version.txt"; then addr="0.0.0.0:9119"; fi
printf 'LISTEN 0 2048 %s 0.0.0.0:* users:(("hermes",pid=%s,fd=9))\n' "$addr" "$pid"
MOCK

  # git mock: delegates to real git, with a controllable status failure.
  REAL_GIT=$(command -v git)
  cat >"$SBX/bin/git" <<MOCK
#!/usr/bin/env bash
if [ "\${1:-}" = "-C" ] && [ "\${3:-}" = "status" ] && [ -f "\$FAKE_SBX/fixtures/git_status_fail" ]; then
  echo "fatal: unable to read repository" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
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

  # sleep mock: fast tests, optional deterministic uptime advance.
  cat >"$SBX/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
if [ -n "${FAKE_UPTIME:-}" ]; then
  cur=$(cat "$FAKE_UPTIME" 2>/dev/null || echo 0)
  echo $(( cur + ${1:-0} )) >"$FAKE_UPTIME"
fi
exit 0
MOCK

  chmod +x "$SBX/bin/"*
}

run_script() {
  local dir="$1"; shift
  local ready_budget="90"
  [ -f "$dir/fixtures/short_ready_budget" ] && ready_budget="1"
  local uptime_file=""
  if [ -f "$dir/fixtures/fake_clock" ]; then
    uptime_file="$dir/state/uptime"
    echo "1000" >"$uptime_file"
  fi
  env PATH="$dir/bin:/usr/bin:/bin" HOME="$dir/home" \
      HERMES_HOME="$dir/home/.hermes" HERMES_OPS_REPORT_DIR="$dir/reports" \
      HERMES_OPS_READY_BUDGET="$ready_budget" \
      HERMES_OPS_UPTIME_FILE="${uptime_file:-/proc/uptime}" FAKE_UPTIME="$uptime_file" \
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
  assert_eq "update dirty made no update call" "0" "$(count_matches 'update --yes' "$SBX/calls.log")"
}

test_update_blocked_migration() {
  new_sandbox update_migration
  cp "$SBX/fixtures/migrate_risk.txt" "$SBX/fixtures/migrate.txt"
  run_script "$SBX" update
  assert_eq "update migration exit" "2" "$(status_of "$SBX")"
  assert_contains "update migration reason" "topology change" "$SBX/stdout.txt"
  assert_eq "update migration made no update call" "0" "$(count_matches 'update --yes' "$SBX/calls.log")"
}

test_update_blocked_sudo() {
  new_sandbox update_sudo
  : >"$SBX/fixtures/no_sudo"
  run_script "$SBX" update
  assert_eq "update no sudo exit" "2" "$(status_of "$SBX")"
  assert_contains "update no sudo reason" "passwordless sudo" "$SBX/stdout.txt"
  assert_eq "update no sudo made no update call" "0" "$(count_matches 'update --yes' "$SBX/calls.log")"
}

test_update_success() {
  new_sandbox update_success
  run_script "$SBX" update
  assert_eq "update success exit" "0" "$(status_of "$SBX")"
  assert_contains "update success verdict" "STATUS: UPDATED" "$SBX/stdout.txt"
  assert_eq "exactly one native update" "1" "$(count_matches 'update --yes' "$SBX/calls.log")"
  assert_eq "wrapper performed no service restarts" "0" "$(count_matches 'restart hermes-serve.service' "$SBX/calls.log")"
  assert_eq "wrapper performed no gateway restarts" "0" "$(count_matches 'gateway restart' "$SBX/calls.log")"
  local report
  report=$(report_of "$SBX")
  assert_contains "update report reflects new version" "v0.23.3" "$report"
  assert_not_contains "update did not use --no-backup" "--no-backup" "$SBX/calls.log"
}


test_check_seven_registered_profiles_with_deleted_remnant() {
  new_sandbox check_seven_profiles
  cat >"$SBX/fixtures/profile_list.txt" <<'EOF'
 Profile     Model       Gateway   Alias   Distribution
 ─────────   ─────────   ───────   ─────   ────────────
 ◆default    model        running   —       —
  ega-house-chief model  running   —       —
  egahouse-pm model      running   —       —
  mailling-radar model   running   —       —
  me          model       running   —       —
  t3-code-nighty-updates model running —       —
  t3-work-status model   running   —       —
  ega-house-chief1 model stopped —       deleted
  WARN: profile listing degraded
EOF
  cat >"$SBX/fixtures/http_body.json" <<'EOF'
{"version":"0.23.2","auth_required":true,"auth_providers":["basic"],"gateway_running":true,"overall":"ok","profiles":["default","ega-house-chief","egahouse-pm","mailling-radar","me","t3-code-nighty-updates","t3-work-status"],"components":{"dashboard":{"status":"ok"}}}
EOF
  run_script "$SBX" check
  assert_eq "seven profiles exit" "0" "$(status_of "$SBX")"
  assert_contains "seven profiles healthy" "STATUS: HEALTHY" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "seven profiles count" "Expected profiles: 7" "$report"
  assert_not_contains "deleted remnant excluded" "ega-house-chief1" "$report"
}

test_update_wrong_revision_fails() {
  new_sandbox update_wrong_revision
  : >"$SBX/fixtures/wrong_revision"
  run_script "$SBX" update
  assert_eq "wrong revision exit" "1" "$(status_of "$SBX")"
  assert_not_contains "wrong revision not updated" "STATUS: UPDATED" "$SBX/stdout.txt"
  assert_eq "wrong revision one update" "1" "$(count_matches 'update --yes' "$SBX/calls.log")"
  assert_eq "wrong revision no restart" "0" "$(count_matches 'restart hermes-serve.service' "$SBX/calls.log")"
}

test_update_stale_backend_fails() {
  new_sandbox update_stale_backend
  : >"$SBX/fixtures/stale_backend_after"
  : >"$SBX/fixtures/short_ready_budget"
  run_script "$SBX" update
  assert_eq "stale backend exit" "1" "$(status_of "$SBX")"
  assert_not_contains "stale backend not updated" "STATUS: UPDATED" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "stale backend reported" "backend version could not be verified" "$report"
}

test_update_profile_disappear_fails() {
  new_sandbox update_profile_disappear
  : >"$SBX/fixtures/profile_disappear_after"
  run_script "$SBX" update
  assert_eq "profile disappear exit" "1" "$(status_of "$SBX")"
  assert_not_contains "profile disappear not updated" "STATUS: UPDATED" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "profile disappear reported" "registered profile disappeared" "$report"
}

test_update_backend_delayed_recovery_succeeds() {
  new_sandbox update_delayed_recovery
  : >"$SBX/fixtures/delayed_backend_recovery"
  echo "2" >"$SBX/fixtures/delayed_backend_fail_count"
  run_script "$SBX" update
  assert_eq "delayed recovery exit" "0" "$(status_of "$SBX")"
  assert_contains "delayed recovery updated" "STATUS: UPDATED" "$SBX/stdout.txt"
  assert_eq "delayed recovery one update" "1" "$(count_matches 'update --yes' "$SBX/calls.log")"
  assert_eq "delayed recovery no restart" "0" "$(count_matches 'restart hermes-serve.service' "$SBX/calls.log")"
}

test_update_backend_readiness_timeout_fails() {
  new_sandbox update_readiness_timeout
  : >"$SBX/fixtures/delayed_backend_recovery"
  echo "999" >"$SBX/fixtures/delayed_backend_fail_count"
  : >"$SBX/fixtures/short_ready_budget"
  : >"$SBX/fixtures/fake_clock"
  run_script "$SBX" update
  assert_eq "readiness timeout exit" "1" "$(status_of "$SBX")"
  assert_not_contains "readiness timeout not updated" "STATUS: UPDATED" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "readiness timeout reported" "readiness budget" "$report"
}

test_update_advanced_wrong_revision_fails() {
  new_sandbox update_advanced_wrong
  : >"$SBX/fixtures/advance_wrong_revision"
  run_script "$SBX" update
  assert_eq "advanced wrong revision exit" "1" "$(status_of "$SBX")"
  assert_not_contains "advanced wrong revision not updated" "STATUS: UPDATED" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "advanced wrong revision reported" "does not match selected stable revision" "$report"
}

test_update_correlated_receipt_survives_unrelated_latest() {
  new_sandbox update_unrelated_latest
  : >"$SBX/fixtures/unrelated_latest"
  run_script "$SBX" update
  assert_eq "unrelated latest exit" "0" "$(status_of "$SBX")"
  assert_contains "unrelated latest updated" "STATUS: UPDATED" "$SBX/stdout.txt"
}

test_update_backend_address_changed_fails() {
  new_sandbox update_address_changed
  : >"$SBX/fixtures/backend_wildcard_after"
  : >"$SBX/fixtures/short_ready_budget"
  : >"$SBX/fixtures/fake_clock"
  run_script "$SBX" update
  assert_eq "address changed exit" "1" "$(status_of "$SBX")"
  assert_not_contains "address changed not updated" "STATUS: UPDATED" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "address changed reported" "listener ownership" "$report"
}

test_update_receipt_correlation_mismatch_fails() {
  new_sandbox update_receipt_mismatch
  : >"$SBX/fixtures/receipt_bad_correlation"
  run_script "$SBX" update
  assert_eq "receipt mismatch exit" "1" "$(status_of "$SBX")"
  assert_not_contains "receipt mismatch not updated" "STATUS: UPDATED" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "receipt mismatch reported" "correlation_id" "$report"
}

test_update_gateway_stale_revision_fails() {
  new_sandbox update_gateway_stale
  : >"$SBX/fixtures/stale_gateway_plan"
  run_script "$SBX" update
  assert_eq "gateway stale revision exit" "1" "$(status_of "$SBX")"
  assert_not_contains "gateway stale revision not updated" "STATUS: UPDATED" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "gateway stale revision reported" "live gateway revision" "$report"
}

test_update_blocked_in_hermes_cgroup() {
  new_sandbox update_unsafe_context
  local fake="$SBX/fakeproc"
  mkdir -p "$fake"
  env PATH="$SBX/bin:/usr/bin:/bin" HOME="$SBX/home" \
      HERMES_HOME="$SBX/home/.hermes" HERMES_OPS_REPORT_DIR="$SBX/reports" \
      FAKE_SBX="$SBX" FAKE_CHECKOUT="$SBX/checkout" FAKE_PROC="$fake" \
      SCRIPT_PATH="$SCRIPT" \
      bash -c '
        pid=$$
        mkdir -p "$FAKE_PROC/$pid"
        printf "Name:\tbash\nPPid:\t%s\n" "$PPID" >"$FAKE_PROC/$pid/status"
        printf "0::/system.slice/hermes-gateway.service\n" >"$FAKE_PROC/$pid/cgroup"
        exec env HERMES_OPS_PROC_ROOT="$FAKE_PROC" PATH="$PATH" HOME="$HOME" \
          HERMES_HOME="$HERMES_HOME" HERMES_OPS_REPORT_DIR="$HERMES_OPS_REPORT_DIR" \
          FAKE_SBX="$FAKE_SBX" FAKE_CHECKOUT="$FAKE_CHECKOUT" \
          bash "$SCRIPT_PATH" update
      ' >"$SBX/stdout.txt" 2>"$SBX/stderr.txt"
  echo $? >"$SBX/status.txt"
  assert_eq "unsafe context exit" "2" "$(status_of "$SBX")"
  assert_contains "unsafe context blocked" "STATUS: BLOCKED" "$SBX/stdout.txt"
  assert_contains "unsafe context reason" "cgroup" "$SBX/stdout.txt"
  assert_eq "unsafe context no update" "0" "$(count_matches 'update --yes' "$SBX/calls.log")"
  assert_eq "unsafe context no restart" "0" "$(count_matches 'restart hermes-serve.service' "$SBX/calls.log")"
}

test_update_post_update_conflict_prevents_restarts() {
  new_sandbox update_post_conflict
  : >"$SBX/fixtures/post_update_conflict"
  run_script "$SBX" update
  assert_eq "post-update conflict exit" "1" "$(status_of "$SBX")"
  assert_contains "post-update conflict partial" "STATUS: PARTIAL" "$SBX/stdout.txt"
  assert_not_contains "post-update conflict not updated" "STATUS: UPDATED" "$SBX/stdout.txt"
  assert_eq "post-update conflict no gateway restart" "0" "$(count_matches 'gateway restart' "$SBX/calls.log")"
  assert_eq "post-update conflict no backend restart" "0" "$(count_matches 'restart hermes-serve.service' "$SBX/calls.log")"
  assert_eq "post-update conflict still one update" "1" "$(count_matches 'update --yes' "$SBX/calls.log")"
}








test_update_respects_upstream_restart() {
  new_sandbox update_upstream_restart
  : >"$SBX/fixtures/upstream_restarts_serve"
  run_script "$SBX" update
  assert_eq "upstream restart exit" "0" "$(status_of "$SBX")"
  assert_eq "no duplicate backend restart" "0" "$(count_matches 'restart hermes-serve.service' "$SBX/calls.log")"
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
  assert_eq "partial still one update call" "1" "$(count_matches 'update --yes' "$SBX/calls.log")"
}

test_update_failed_no_retry() {
  new_sandbox update_failed
  : >"$SBX/fixtures/update_fail"
  run_script "$SBX" update
  assert_eq "update failed exit" "1" "$(status_of "$SBX")"
  assert_contains "update failed verdict" "STATUS: FAILED" "$SBX/stdout.txt"
  assert_eq "failed updater run exactly once" "1" "$(count_matches 'update --yes' "$SBX/calls.log")"
}

test_update_already_current() {
  new_sandbox update_current
  cp "$SBX/fixtures/version_after.txt" "$SBX/fixtures/version.txt"
  run_script "$SBX" update
  assert_eq "already current exit" "0" "$(status_of "$SBX")"
  assert_contains "already current verdict" "STATUS: ALREADY_CURRENT" "$SBX/stdout.txt"
  assert_eq "already current no updater call" "0" "$(count_matches 'update --yes' "$SBX/calls.log")"
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

test_check_git_status_failure() {
  new_sandbox check_git_status_fail
  : >"$SBX/fixtures/git_status_fail"
  run_script "$SBX" check
  assert_eq "git status failure check exit" "1" "$(status_of "$SBX")"
  assert_contains "git status failure not healthy" "STATUS: DEGRADED" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "git status failure recorded" "git status" "$report"
}

test_update_git_status_failure() {
  new_sandbox update_git_status_fail
  : >"$SBX/fixtures/git_status_fail"
  run_script "$SBX" update
  assert_eq "git status failure update exit" "2" "$(status_of "$SBX")"
  assert_contains "git status failure blocks update" "STATUS: BLOCKED" "$SBX/stdout.txt"
  assert_eq "git status failure made no update call" "0" "$(count_matches 'update --yes' "$SBX/calls.log")"
}

test_check_missing_receipt() {
  new_sandbox check_missing_receipt
  rm -rf "$SBX/home/.hermes/logs/update_receipts"
  run_script "$SBX" check
  assert_eq "missing receipt exit" "1" "$(status_of "$SBX")"
  assert_contains "missing receipt not healthy" "STATUS: UNKNOWN" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "missing receipt recorded" "receipt" "$report"
}

test_check_backend_unverified() {
  new_sandbox check_backend_unverified
  : >"$SBX/fixtures/serve_no_bind"
  run_script "$SBX" check
  assert_eq "unverified backend exit" "1" "$(status_of "$SBX")"
  assert_contains "unverified backend not healthy" "STATUS: UNKNOWN" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "unverified backend recorded" "HTTP health was not verified" "$report"
}

test_check_optional_backend_absent() {
  new_sandbox check_backend_absent
  cat >"$SBX/fixtures/sys_units.txt" <<'EOF'
hermes-gateway.service enabled enabled
hermes-tunnel.service enabled enabled
EOF
  run_script "$SBX" check
  assert_eq "optional backend absent exit" "0" "$(status_of "$SBX")"
  assert_contains "optional backend absent healthy" "STATUS: HEALTHY" "$SBX/stdout.txt"
}

test_check_incomplete_profiles() {
  new_sandbox check_incomplete_profiles
  : >"$SBX/fixtures/no_plan_profiles"
  : >"$SBX/fixtures/profile_list_fail"
  rm -rf "$SBX/home/.hermes/profiles"
  run_script "$SBX" check
  assert_eq "incomplete profiles exit" "1" "$(status_of "$SBX")"
  assert_contains "incomplete profiles not healthy" "STATUS: UNKNOWN" "$SBX/stdout.txt"
  local report
  report=$(report_of "$SBX")
  assert_contains "incomplete profiles recorded" "profile inventory" "$report"
}

test_check_redaction_git_remote() {
  new_sandbox check_redaction_remote
  git -C "$SBX/checkout" remote set-url origin 'https://user:supersecret-git-credential@github.com/NousResearch/hermes-agent.git'
  run_script "$SBX" check
  local report
  report=$(report_of "$SBX")
  assert_not_contains "git credential not in report" "supersecret-git-credential" "$report"
  assert_not_contains "git credential not in stdout" "supersecret-git-credential" "$SBX/stdout.txt"
  assert_not_contains "git credential not in stderr" "supersecret-git-credential" "$SBX/stderr.txt"
  assert_contains "git credential redacted in report" "[REDACTED]" "$report"
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
test_check_seven_registered_profiles_with_deleted_remnant
test_update_wrong_revision_fails
test_update_stale_backend_fails
test_update_profile_disappear_fails
test_update_receipt_correlation_mismatch_fails
test_update_gateway_stale_revision_fails
test_update_backend_delayed_recovery_succeeds
test_update_backend_readiness_timeout_fails
test_update_advanced_wrong_revision_fails
test_update_correlated_receipt_survives_unrelated_latest
test_update_backend_address_changed_fails
test_update_blocked_in_hermes_cgroup
test_update_post_update_conflict_prevents_restarts
test_update_respects_upstream_restart
test_update_partial_receipt
test_update_failed_no_retry
test_update_already_current
test_check_no_backup_rejected
test_check_latest_plugin_check_ignored
test_check_latest_update_receipt_used
test_check_user_scope_units
test_check_git_status_failure
test_update_git_status_failure
test_check_missing_receipt
test_check_backend_unverified
test_check_optional_backend_absent
test_check_incomplete_profiles
test_check_redaction_git_remote
test_check_redaction

printf '\n== Result: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf 'Failed:%s\n' "$FAILED_NAMES"
  exit 1
fi
exit 0
