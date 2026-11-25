# Hermes Operations — Linux and Windows skills

Two terminal-only agent skills that answer exactly two requests safely:

- **“Check Hermes”** → read-only evidence, no deployment mutation.
- **“Update Hermes”** → one owner-specific official update after a passing
  preflight, then independent verification.

This repository is an orchestrator and verifier. It is **not** a new updater,
package manager, dashboard, scheduler, or backup framework. Hermes owns its
source updates; the Microsoft Store/WinGet and the signed App Installer own
Windows packages.

The source of truth is [`docs/OPERATIONS_SPEC.md`](docs/OPERATIONS_SPEC.md).
Agent routing is in [`AGENTS.md`](AGENTS.md). Failure output follows
[`docs/FAILURE_REPORT_TEMPLATE.md`](docs/FAILURE_REPORT_TEMPLATE.md).

## Repository layout

```text
AGENTS.md
README.md
docs/
  OPERATIONS_SPEC.md
  FAILURE_REPORT_TEMPLATE.md
skills/
  hermes-linux/
    SKILL.md
    scripts/hermes.sh          # bash: check / update
  hermes-windows/
    SKILL.md
    scripts/hermes.ps1         # PowerShell 5.1+: check / update
tests/
  linux/test_hermes.sh         # mock-driven bash tests
  windows/test_hermes.ps1      # mock-driven PowerShell tests
  run-tests.sh
```

Runtime reports are written under `reports/<host>/` and are ignored by Git.
Never commit reports, `.env`, tokens, auth stores, or raw logs.

## Linux (Ubuntu VM)

Read [`skills/hermes-linux/SKILL.md`](skills/hermes-linux/SKILL.md) first.

```bash
bash skills/hermes-linux/scripts/hermes.sh check
bash skills/hermes-linux/scripts/hermes.sh update
```

Optional:

```bash
--backend-url http://HOST:9119   # existing private Desktop backend
--no-backup                      # update only, explicit opt-out
```

The script discovers the install owner, executable, checkout, channel, systemd
scope/units, profiles, backend bind URL, and receipt at runtime. It never
assumes port 9119 or unit names.

`check` is read-only: it may fetch Git metadata through `hermes update --check`,
but it does not update, restart, migrate, or write Hermes configuration.

`update` refuses dirty/forked checkouts, a non-stable channel, a downgrade,
insufficient disk, ambiguous/conflicting units, an inactive gateway/backend, an
unapproved multiplex fold, an existing update lock, or unavailable passwordless
sudo for a system-scope backend refresh. It then runs **one**:

```bash
hermes update --yes
```

Hermes owns service lifecycle after the update. The wrapper does not restart
services; it verifies the installed release, Git revision, expected/served
profiles, native receipt, and backend readiness by bounded polling of
`/api/status`. It treats receipt `followups[]` or
`gateway_restart.incomplete=true` as `PARTIAL`, never as success.

## Windows 11

Read [`skills/hermes-windows/SKILL.md`](skills/hermes-windows/SKILL.md) first.
Run these **on Windows**, not on the Linux VM:

```powershell
powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 check  -BackendUrl 'http://HOST:9119'
powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 update -BackendUrl 'http://HOST:9119'
```

Optional `-NoBackup` (source builds only) and `-AppInstallerFile <verified
descriptor>` (signed sideload only).

Owner detection is mandatory and read-only:

| Detected owner | Allowed update path |
|---|---|
| Source build | `hermes update --yes` |
| Microsoft Store (`NousResearchInc.HermesAgent`, product `9PMXK8CZC7KR`) | `winget upgrade --id 9PMXK8CZC7KR --exact --source msstore ...` |
| Signed sideload MSIX (`NousResearch.HermesBundled`) + verified descriptor | `Add-AppxPackage -AppInstallerFile ...` |
| Source + MSIX both present | `BLOCKED` |
| Store vs sideload unclear or unrecognized identity | `BLOCKED` |
| Not installed | `BLOCKED`, no bootstrap |

Store and sideload are different official identities. A Store identity that is
not Store-signed, a sideload identity with a non-Nous publisher, an unrecognized
Hermes package, or both official MSIX variants at once is blocked rather than
guessed. A recognized sideload owner without a descriptor is `UNKNOWN` in check
mode and cannot update.

No GUI launch, no blanket process kill, no distribution conversion, no
unrestricted `winget upgrade --all`, no token scraping. Source updates also
require the resolved CLI install directory to match the discovered checkout,
the official NousResearch Git remote, a clean tree, and the stable channel.

## Verdicts and exit codes

| Exit | Verdicts | Meaning |
|---|---|---|
| `0` | `HEALTHY`, `UPDATED`, `ALREADY_CURRENT` | All checks the script can genuinely prove passed |
| `1` | `DEGRADED`, `PARTIAL`, `FAILED`, `UNKNOWN` | Unhealthy, unverified, partial, or failed |
| `2` | `BLOCKED` | Unsafe, ambiguous, unsupported, or needs operator action |

Important distinctions enforced by both scripts:

- HTTP 401/403 proves a listener, not an authenticated Hermes session.
- HTTP 200 alone is not health; the payload must look like Hermes status JSON.
- A reachable VM does not prove a Windows Desktop login or WebSocket.
- Updater exit code 0 plus receipt follow-ups is `PARTIAL`.
- A healthy gateway with a stale/dead separately supervised backend is
  `PARTIAL`.
- Store “no applicable upgrade” is channel-specific, not GitHub-stable parity.

## Tests

Linux, no live Hermes access required:

```bash
bash tests/linux/test_hermes.sh
```

The suite uses mocked `hermes`, `systemctl`, `curl`, `ss`, `loginctl`, `sudo`
and a temporary Git checkout. It covers healthy check, dirty checkout, root
execution, missing CLI, conflicting units, wrong JSON, HTTP 401, backend down,
receipt follow-ups, `latest.json` selection, user-scope units, wrong checkout
binding, blocked update (dirty/migration/sudo), successful update (one updater
call, backend PID refresh), upstream restart respect, stale gateway refresh,
partial receipt, updater failure with no retry, already-current, argument
rejection, provenance failures, unverified health states, post-update restart
safety, and redaction. Current result: **144 assertions passed**.

Windows (must run on a Windows host):

```powershell
powershell.exe -NoProfile -File .\tests\windows\test_hermes.ps1
```

On non-Windows hosts the Windows test performs a parser/static check and skips
runtime branches. Real Windows acceptance is still required.

Run whichever tests the current host supports:

```bash
bash tests/run-tests.sh
```

## Verified status of this checkout

- Linux `check` was executed read-only on the target VM. It found the actual
  gateway/backend units, source provenance, v0.23.2 → available v0.23.3, HTTP
  `/api/status` JSON, and reported real degradations: configured profile
  `ega-house-chief1` is not served, and the newest native receipt has an
  unresolved backend-restart follow-up. The run took roughly 3.5–5 minutes on
  this busy arm64 host; `hermes doctor` can exceed its 60 s diagnostic budget
  and is then reported as `NOT_TESTED`, not as a service failure.
- Linux `update` was **not** run against the live deployment during
  implementation. It remains gated on the operator's explicit update request
  and a passing preflight. A topology dry-run timeout is treated as an unknown
  migration risk and blocks update rather than guessing.
- Windows `check`/`update` have **not** been executed on Windows in this
  environment. The script parses successfully under PowerShell 7.7 on Linux,
  and PSScriptAnalyzer reports no PowerShell 5.1 syntax-compatibility findings,
  but real Windows 11 runtime acceptance is still **NOT_TESTED**.
- Neither script has proven Windows authentication or an authenticated
  WebSocket. Those remain `NOT_TESTED` until exercised on Windows with approved
  credentials.

## Limitations

- The scripts depend on Hermes CLI output/receipt formats. Unknown outcomes are
  treated as not clean; docs and installed `--help` should be re-checked when
  Hermes changes.
- A configured-but-unserved profile is reported, not repaired. The operator
  decides whether it is intentionally parked.
- Sideload descriptor discovery is not standardized; without a verified
  descriptor check reports `UNKNOWN` and update is `BLOCKED`.
- WinGet output/exit codes vary by distributor and version; the script records
  bounded raw evidence and does not force a fallback.
- Linux diagnostics are run sequentially and are bounded per command. On a slow
  or busy host, optional diagnostics such as `hermes doctor` may be
  `NOT_TESTED` rather than blocking the whole check. Missing essential evidence
  (active backend without HTTP verification, no receipt, or incomplete profile
  inventory) yields `UNKNOWN`, not `HEALTHY`.
- No cross-host orchestration. Run each skill on its actual host and merge the
  two reports.

## Safety

No reinstall, `git reset --hard`, forced updater, automatic multi-profile
migration, new unit, firewall/auth change, credential rotation, reboot, blanket
process kill, GUI launch, or retry loop. Keep Hermes' default quick snapshot
unless the user explicitly opts out. Reports are redacted and local only.
