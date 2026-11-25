---
name: hermes-linux
description: Check or update an official source-managed Hermes Agent installation on Ubuntu Linux, including its gateway, profiles, separately supervised Desktop backend, HTTP health, and native update receipt. Use for "check Hermes" or "update Hermes" when execution is actually on the Linux host.
---

# Hermes Linux operations

This skill is a **terminal-only orchestrator and verifier**. It does not replace
Hermes' updater. Follow `docs/OPERATIONS_SPEC.md` (especially Sections 3–6 and
11) and `docs/FAILURE_REPORT_TEMPLATE.md`.

## When to use

Use only when the **actual execution host is Ubuntu Linux** and the request is
to check or update Hermes there. A Windows request or a T3 session on another
machine must not be reported as a Linux result.

- **“Check Hermes” / “Is Hermes healthy or current?”** → `check`
- **“Update Hermes”** → `update`, only after a passing preflight and an explicit
  user instruction to update.

On ambiguity, missing provenance, or unsafe state, the script returns
`BLOCKED`; do not invent an installer or workaround.

## Requirements

- Ubuntu/Debian-style Linux with a running `systemd`.
- Run as the **Hermes install owner** (for this deployment: `ubuntu`), never as
  root.
- The existing official source checkout and `hermes` launcher must already be
  installed. This skill never bootstraps or reinstalls Hermes.
- `bash`, `systemctl`, `journalctl`, `git`, `curl`, `ss`, `df`, `python3`.
  `jq` is optional.
- Read access to the Hermes home (`HERMES_HOME`, default `~/.hermes`).
- For an **active system-scope** Desktop backend restart during `update`,
  passwordless `sudo -n` must already work. The script never prompts for a
  password and never enables elevation.

## Commands

From the repository root, on the Ubuntu host:

```bash
bash skills/hermes-linux/scripts/hermes.sh check
bash skills/hermes-linux/scripts/hermes.sh update
```

Optional arguments:

```bash
--backend-url http://HOST:PORT   # existing private Desktop backend; no credentials
--no-backup                      # update only; explicit user opt-out of Hermes' snapshot
```

`--no-backup` must never be added implicitly. Keep Hermes' default quick
snapshot unless the user explicitly asks to skip it.

Do not call `hermes update` directly in parallel with this skill. The script
issues **exactly one** native stable update, or none at all.

## What `check` does

Read-only discovery and inspection:

1. Confirms Linux, running `systemd`, non-root install owner, `hermes` path,
   resolved checkout, install id, version, channel, Git remote and dirty state.
2. Reads the native update target (`hermes update --check`), update plan,
   profiles and multiplex dry run. `--check` may fetch Git metadata; it does not
   apply an update.
3. Discovers system vs user units for the messaging gateway and the separately
   supervised Desktop backend, their `ExecStart`, `User`, `MainPID` and active
   state. Conflicting scopes, unit/account mismatch, or a unit pointing at a
   different checkout is `BLOCKED`.
4. Verifies expected vs served profiles by name, including missing profiles.
5. Discovers the backend URL from the verified unit `ExecStart` (or an explicit
   `--backend-url`), probes `GET /api/status`, validates Hermes JSON, and
   reports HTTP, protocol and auth separately.
6. Reads the newest native `update_*.json` receipt and treats unresolved
   `followups[]` or `gateway_restart.incomplete=true` as **not success**.
7. Distinguishes `PASS`, `FAIL`, `NOT_TESTED`, and `UNKNOWN`. Missing essential
   evidence (active backend without HTTP verification, no receipt evidence, or
   incomplete profile inventory) yields `UNKNOWN`, never `HEALTHY`. An absent
   optional backend unit remains optional and does not fail the host.
8. Writes a redacted Markdown report under `reports/<host>/<UTC>-check.md`.
   Every report field and console message is sanitized before output.

No restart, migration, config write, package install, or credential change is
allowed in `check`.

## What `update` does

Preflight (all read-only), then at most one controlled mutation sequence:

1. Refuses dirty checkout, non-official remote, non-`stable` channel, custom
   branch, downgrade target, insufficient disk, missing/conflicting units,
   inactive gateway/backend, unapproved multiplex topology change, an existing
   update lock, or unavailable passwordless sudo for a system-scope backend.
2. Runs the official updater exactly once:
   `hermes update --yes` (plus `--no-backup` only when
   explicitly requested), after preflight verifies the channel is `stable`.
3. Re-reads version, Git revision, plan, gateway, profiles, backend service and receipt
   independently. It does not trust the updater's exit code.
4. Performs no wrapper-managed service restarts; Hermes owns its lifecycle.
5. Polls backend `/api/status` with a bounded number of attempts and records readiness.
6. Verifies the installed release, Git revision, expected/served profiles, backend service state, HTTP JSON, and fresh correlated receipt. A healthy gateway with a stale or dead backend is `PARTIAL`.
7. Writes `reports/<host>/<UTC>-update.md`.

## Arguments and exit codes

| Exit | Verdict | Meaning |
|---|---|---|
| `0` | `HEALTHY`, `UPDATED`, `ALREADY_CURRENT` | All checks the script can genuinely prove passed |
| `1` | `DEGRADED`, `PARTIAL`, `FAILED`, `UNKNOWN` | Unhealthy, unverified, partial, or failed state |
| `2` | `BLOCKED` | Unsafe, ambiguous, unsupported, or requires operator action |

An exit code of `0` from Hermes itself is insufficient: unresolved receipt
follow-ups produce `PARTIAL`. An HTTP 401/403 is a listener, **not** an
authenticated session. `HERMES_DESKTOP` login and authenticated WebSocket from
Windows remain unverified unless tested on Windows.

## Report interpretation

Reports follow `docs/FAILURE_REPORT_TEMPLATE.md`: verdict, environment, expected
vs actual, timeline with exit codes, exact redacted error, receipt fields, root
cause confidence, blast radius, one lowest-risk next action, and re-verification
criteria. Never commit reports or raw logs.

## Safety boundaries

- No reinstall, `git reset --hard`, `git clean`, forced updater, `--force`,
  `--force-venv`, stash discard, automatic multi-profile migration, new unit,
  firewall/auth change, credential rotation, reboot, or blanket process kill.
- No second updater run after a failure. Diagnose the code/service state first.
- No configuration changes to make a health check pass.
- No public exposure of the backend.

## Known limitations

- The script cannot prove a Windows Desktop login, chat WebSocket, or end-to-end
  Desktop session from Linux.
- `hermes doctor` is slow on large fleets; a timeout is reported as
  `NOT_TESTED`, not as a service failure.
- A profile directory may exist without being served (for example a parked
  duplicate). The script surfaces the exact missing name as `DEGRADED` and does
  not delete or re-enable it.
- The native receipt schema is upstream-owned; unknown outcome strings are
  treated as not clean.
- Real-host acceptance remains required on the target VM; mocked tests alone do
  not prove machine health.
