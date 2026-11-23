# Hermes Operations — End-to-End Repository Specification

**Status:** implementation-ready specification; **scripts are not yet deployed or verified on the user's machines**  
**Version:** 1.0 · **Research checked:** 2026-11-23  
**Intended execution:** T3 Code, OpenCode, Codex, or another terminal-capable agent running on the target machine.  
**Platforms:** Ubuntu Linux VM and Windows 11 Desktop.  
**One-sentence goal:** Tell an agent **“Check Hermes”** or **“Update Hermes”** and receive an evidence-backed result, without the agent inventing commands or silently making unrelated changes.

---

## 1. Decision and design principles

**Build one small repository with two independent agent skills and one shell script per operating system.** Hermes already owns installation and update logic. Our repository is an **orchestrator and verifier**, not a new updater.

1. **`check`**: inspect versions, provenance, services, configuration, profiles, remote connectivity, and relevant logs. **Do not update, restart, migrate, install, or modify Hermes configuration.** A local redacted report may be written to an ignored `reports/` directory. `hermes update --check` may fetch Git metadata; it does not apply the update.
2. **`update`**: run the correct upstream update mechanism after a preflight; refresh any *separately managed* backend; verify all required components; record exact partial/failed steps.
3. **Fail closed:** ambiguous installation, permissions, profile topology, unrecognized service ownership, untrusted download, or unknown package source → **BLOCKED with a specific explanation**, never “try some other installer.”
4. **Minimum moving parts:** no new database, daemon, monitoring stack, cloud service, Docker image, GUI automation, custom backup/restore framework, or broad machine cleanup.
5. **Never announce success from exit code alone.** Hermes can exit 0 after code is updated while leaving explicit follow-ups, and a reachable port does not prove a usable Desktop session.

### What "terminal-only" means

All supported check and update actions are initiated from Bash or PowerShell. They never launch the Hermes Desktop window intentionally. Windows package operations still depend on Windows and its installation owner; Microsoft Store / App Installer can require OS-managed consent, a package release, or closing a locked application. Such a blocker is a truthful **BLOCKED** result, not a reason to switch installer technologies.

### What "latest" means

- **Linux managed source / Windows source-built Desktop:** Hermes official **stable** channel, selecting the latest published `vX.Y.Z` release, *not* `main` and not a canary.
- **Windows Store / signed sideload MSIX:** latest package *actually published in that distributor's channel*. It need not match the GitHub CLI release numerically.
- At research time, the GitHub latest stable release was **v0.23.3** (published November 20, 2026). **Never hardcode this number in an updater**; obtain the actual release at run time.

---

## 2. Deployment model: don't confuse the processes

```text
Ubuntu VM (current deployment to VERIFY, not assume)
┌─────────────────────────────────────────────────────────┐
│ Hermes source-managed install, executed as its owner    │
│                                                         │
│  hermes-gateway.service   ← messaging / profiles / bots  │
│     └─ Hermes-managed lifecycle during `hermes update`   │
│                                                         │
│  hermes-serve.service     ← Desktop remote API/WS backend│
│     └─ custom systemd lifecycle; requires separate check │
│                                                         │
│  Optional API server on :8642 is NOT the Desktop API     │
└───────────────────────────┬─────────────────────────────┘
                            │ reachable only via approved
                            │ Tailscale / private URL
                            ▼
Windows 11 Desktop
┌─────────────────────────────────────────────────────────┐
│ Hermes Desktop (source build OR Store OR sideload MSIX)  │
│       → remote `hermes serve` HTTP + authenticated WS     │
│       → tools and agent work run on the Linux VM         │
└─────────────────────────────────────────────────────────┘
```

The unit names above come from the intended deployment and **must be discovered**; a VM might instead have a user unit, a system unit, a templated profile unit, or another service name. The VM may run several profiles on one multiplexed gateway. The Windows Desktop may have a saved different URL, or an environment override.

### Current deployment hypotheses requiring preflight

| Property | Candidate / expectation | Verification required |
|---|---|---|
| Linux host | Ubuntu VM `openclaw` | `hostnamectl`, `uname -a`, `id` |
| Service account | `ubuntu` | effective user, unit `User=`, unit scope |
| Source tree | `~/.hermes/hermes-agent` | `hermes update --install-id`; Git remote and status |
| Messaging gateway | `hermes-gateway.service` | `hermes update --plan`; `hermes gateway status`; systemd |
| Remote Desktop API | `hermes-serve.service` | systemd unit, PID, `ExecStart`, listening address |
| Remote URL | port 9119, Tailscale IP or hostname | actual unit/config and Desktop connection setting |
| Optional local model API | port 8642 | separate surface; do not treat as Desktop health |
| Multiple profiles | more than one | `hermes profile list`, served-profile inventory |
| Windows source/package owner | **unknown** | `Get-Command hermes -All`, Hermes Appx identities (`NousResearchInc.HermesAgent` Store, `NousResearch.HermesBundled` sideload), WinGet, `hermes doctor` where valid |

**Never embed a real IP, API key, password, access token, or profile credentials in this repository.** Runtime URLs come from explicit arguments/environment or an existing verified configuration.

---

## 3. Repository contract

```text
hermes-ops/
├── README.md                          # two commands, setup, status semantics
├── AGENTS.md                          # mandatory routing and safety rules
├── docs/
│   ├── OPERATIONS_SPEC.md             # this source-of-truth specification
│   └── FAILURE_REPORT_TEMPLATE.md     # exact evidence report format
├── skills/
│   ├── hermes-linux/
│   │   ├── SKILL.md
│   │   └── scripts/hermes.sh           # one Bash CLI: check / update
│   └── hermes-windows/
│       ├── SKILL.md
│       └── scripts/hermes.ps1          # one PowerShell CLI: check / update
└── .gitignore                         # reports/, secrets, temp output
```

**No root `package.json`, Python package, shared execution framework, CI deployment pipeline, or application UI.** Add lightweight local tests only where they are needed to prove failure safety. Do not duplicate the two scripts in another folder.

### Agent-skill format

Each `SKILL.md` contains YAML frontmatter with `name` and `description`, exact OS requirements, which script to execute, accepted arguments, report interpretation, and links to this spec. It is **not** itself a shell script.

`AGENTS.md` tells T3 to read the relevant skill and run the existing script. Merely storing a `SKILL.md` in a repo does not guarantee every agent automatically discovers it; **root routing instructions are mandatory**.

### One-time configuration, no committed credentials

Do not require global installation of these skills on every agent. Checking out/opening the repo is enough if the agent reads `AGENTS.md`.

Accepted parameters:

- Linux: optional `--backend-url <URL>` for the already-known private Desktop backend; default is *discovered*, with a fallback to `http://127.0.0.1:9119` **only if the real service configuration confirms it**.
- Windows: `-BackendUrl <URL>` or explicit pre-existing `HERMES_DESKTOP_REMOTE_URL`; never invent a URL. No URL means the **remote-connectivity criterion is UNKNOWN**, not healthy.
- Optional `--no-backup` / `-NoBackup` for skipping Hermes' own quick snapshot **only when the user explicitly wants that**.
- Optional `--check` vs `update` action; never use a CLI spelling that is not in the supported installed version.

Example invocation names (the implementer must honor these exactly):

```bash
# On Ubuntu, within repository root
bash skills/hermes-linux/scripts/hermes.sh check
bash skills/hermes-linux/scripts/hermes.sh update
```

```powershell
# On Windows, within repository root
powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 check -BackendUrl 'http://YOUR_TAILSCALE_HOST:9119'
powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 update -BackendUrl 'http://YOUR_TAILSCALE_HOST:9119'
```

These are the **required CLI contract for future scripts**, not a claim that these files already exist. If local execution policy blocks scripts, the agent must report the blocker rather than silently alter machine policy.

---

## 4. Commands and expected outcomes

| User asks | Agent runs | Mutation allowed | Required output |
|---|---|---|---|
| “Check Hermes” | Target OS script `check` | Read diagnostics; write *only local report*; Git metadata fetch allowed | `HEALTHY`, `DEGRADED`, `BLOCKED`, or `UNKNOWN` |
| “Is Hermes up to date?” | `check` | Same | Installed vs available update; distinguish package channel |
| “Update Hermes” | `update` | Authorized official updater + authorized existing service refresh | `UPDATED`, `ALREADY_CURRENT`, `PARTIAL`, `FAILED`, or `BLOCKED` |
| “Fix Hermes” | First run `check` | **No speculative fixes** | Root-cause evidence + specific safe proposed repair |
| “Update Hermes on both machines” | One run on each actual OS (sequential is simplest) | Per host | Separate reports + consolidated verdict |

### Exit codes

Keep OS scripts aligned:

- `0` — requested operation passed **all the checks it can genuinely prove**; evidence and any explicitly untested dimensions still listed.
- `1` — check found degraded state or update failed/partial.
- `2` — refused/blocked because the action is unsafe, ambiguous, unsupported, or requires explicit operator intervention.

A successful CLI call without remote WebSocket validation must not be labeled “Desktop fully working.” State the narrower verified status.

---

## 5. Linux: `check` end to end (NO changes)

### Phase L0 — execution sanity

1. Confirm Linux + `systemd` and that the script runs as the **Hermes install owner**, not root.
2. Resolve the exact `hermes` executable (`command -v hermes`, `readlink -f`) and source checkout, but do not install anything if absent.
3. Identify Linux OS, user, hostname, Hermes version, Git remote, channel, and whether the checkout has uncommitted changes.
4. Discover systemd user vs system units; if both scopes claim the same service or `ExecStart` points to a different checkout/account, **BLOCK** any subsequent update. **Never create or overwrite a unit**.

### Phase L1 — inspect Hermes

Use supported read-style commands:

```bash
hermes --version
hermes update --install-id
hermes update --plan
hermes update --check
hermes gateway status
hermes doctor
hermes pm status
hermes profile list
hermes gateway migrate --multiplex --dry-run
```

`hermes update --check` may fetch Git metadata, but does not install or restart. Treat nonzero exits explicitly; avoid `|| true` except when recording a failure code. `hermes doctor` may report optional providers as warnings; classify the impact rather than automatically failing an unrelated subsystem.

### Phase L2 — check *all* relevant runtime processes

- Determine every Hermes-managed gateway and whether its **live code revision** matches the checked-out revision; consult `hermes update --plan`, `gateway status` and any current receipt obligations.
- Determine whether the configured Desktop API service was expected to be running. Check supervisor, running PID, bind address/port and `systemctl is-active`; verify not merely `loaded`.
- Verify all **expected** profiles are served. If a profile is missing, surface the exact name and reason; don't fabricate a healthy count. A multiplexed gateway can serve many profiles with one PID.
- For an active user service, verify linger if required for boot/logout survival (`loginctl show-user ... -p Linger`). Do **not** enable it in check mode.
- Optional API listener such as `:8642` is a *separate* test; it cannot substitute for the remote Desktop backend.

Useful supervisor read commands (choose `--user` only for actual user units):

```bash
systemctl --user status hermes-gateway.service --no-pager
systemctl --user status hermes-serve.service --no-pager
systemctl status hermes-gateway.service hermes-serve.service --no-pager
ss -ltnp
```

Not every command above applies to every host. Detect first and **only query the discovered, relevant supervisor**. Do not echo environment secrets or raw `systemctl show Environment` values.

### Phase L3 — verify local Desktop backend

- Discover the actual private HTTP(S) base URL and probe `GET /api/status` with a short timeout.
- Require a valid Hermes status JSON payload (for example `auth_required` and provider information), not just any HTTP 200 page.
- A 401/403 proves a listener or gate answered, **not** successful Hermes health or Desktop authentication; label as `AUTH_REQUIRED`/`UNVERIFIED` pending an authorized test.
- An absent endpoint, wrong port, wrong host, invalid JSON or no actual backend unit is **DEGRADED** if the Desktop backend is expected to work.

### Phase L4 — report

Output `HEALTHY` only for **the services and checks actually verified**. Include exact versions, expected/served profile count, supervisor scope and status, HTTP evidence, any unresolved updater follow-ups, and what remains unverified (especially login + WebSocket from Windows).

---

## 6. Linux: `update` end to end (CONTROLLED changes)

### Preflight: reuse `check` and enforce stop conditions

Stop **before any mutation** when:

- Hermes provenance is not an official managed source checkout, or update channel is unknown/forked.
- Wrong user, ambiguous supervisor/checkout, necessary elevated privileges unavailable, or insufficient disk space for the upstream updater.
- Checkout is dirty, has a custom branch/commits that would be switched or discarded, or the stable target would **downgrade** code/schema. Present exact findings; do not auto-stash or reset source edits for the user.
- A `hermes gateway migrate --multiplex --dry-run` indicates Hermes would fold an older per-profile fleet and that topology change is not previously authorized. **Updating may implicitly change multiple systemd units.** Report the planned migration and stop. Operator can *separately choose* to keep old topology via `gateway.auto_multiplex_migration: false` (where supported) or approve migration. Do not silently set this configuration.
- A Hermes run is actively using the backend and shutdown would interrupt it, when such activity can be reliably detected; otherwise warn that a restart causes a brief disconnect. Never use `--force` to bypass active work.
- Required host/service isn't actually found. Never guess one from the name.

### Apply exactly one official update

For a validated official source install, the primary command is:

```bash
hermes update --set-channel stable --yes
```

This **both sets the channel and performs the update**. Do **not** run a second `hermes update`. Add `--no-backup` only if explicitly requested; otherwise keep Hermes' built-in quick snapshot. The upstream updater handles its own dependency preparation, gateway pause/restart, startup syntax guard, receipts, and internal rollback logic. Do not run `git pull`, `pip install`, `npm install`, or an external installer as a parallel or fallback update.

### Refresh the separately managed Desktop backend

The updater automatically manages gateway services it recognizes, but **does not own an independently launched `hermes serve`**. After the code update, restart **only** the **preflight-verified existing** backend service using its actual supervisor and permissions (e.g. `systemctl --user restart hermes-serve.service`, or `sudo systemctl restart ...` only with separately approved privileges).

- Preserve pre-update expected state: do **not** start a backend that was intentionally stopped, unless the operator explicitly requests it.
- Restart the gateway manually **only if** verification shows it did not restart correctly; use Hermes' documented `hermes gateway restart` or the verified supervisor. Do not blindly restart an already healthy gateway a second time.
- Do not run migrations, reconfigure authentication, change `ExecStart`, expose a new bind address, restart unrelated services, or reboot the VM.
- If upstream updater fails, **do not immediately run another updater**. Diagnose code state and existing service condition first. If the backend is stale but reachable, report partial state rather than claiming recovery.

### Verify independently

1. `hermes --version`; compare to the **live official stable release** if network retrieval succeeds.
2. `hermes update --check`, `hermes gateway status`, `hermes doctor`, `hermes pm status`.
3. Inspect `~/.hermes/logs/update_receipts/latest.json` under the **actual default Hermes root**: `outcome`, `followups[]`, `gateway_restart.incomplete`, and the version/fleet matrix. `outcome=success` **is insufficient** if follow-ups remain.
4. Gateway live PID/commit/supervisor valid for each expected profile; verify no unintended profile disappeared.
5. `hermes-serve` service active, using the updated checkout, and PID **changed from its pre-update PID** if a restart was required. Inspect journals if not.
6. Local backend `GET /api/status` returns recognizable Hermes JSON and the expected auth-advertisement behavior.
7. When verifiable from the VM, ensure private bind / Tailscale reachability has not changed. Do not make public the backend to pass a test.
8. Report remaining **remote Windows** authentication/WebSocket validation separately.

**Result rule:** `UPDATED` requires source update + runtime/service verification + no unresolved required native follow-ups. A healthy gateway but stale or dead `hermes-serve` is `PARTIAL`.

---

## 7. Windows: installation detection (MUST happen before actions)

Do **not** infer the Desktop distributor only from `Get-Command hermes` or whether a Git checkout exists. The machine can have a source CLI **and** an installed MSIX Desktop simultaneously. Identify **which installed app the user actually uses**.

Read-only PowerShell evidence:

```powershell
Get-Command hermes -All -ErrorAction SilentlyContinue
Get-AppxPackage | Where-Object { $_.Name -match 'Hermes' }
winget list --id 9PMXK8CZC7KR --exact --source msstore
```

The official Store identity is `NousResearchInc.HermesAgent` (Store-signed,
publisher `CN=EE6D86E4-606F-4E38-B940-AD7248C9D519`). The official out-of-store
sideload identity is `NousResearch.HermesBundled` (Developer/Enterprise-signed,
publisher `CN=Nous Research Inc.`). Any other Hermes identity, a signature or
publisher mismatch, or both official variants at once is ambiguous and must be
blocked.

For source installs, also verify `%LOCALAPPDATA%\hermes\hermes-agent\.git`, that
the resolved CLI reports that same install directory with `Install method: git`,
the official NousResearch Git remote, a clean tree, the stable channel, and
`hermes doctor` where available. A source/bootstrap installer (`Hermes-Setup.exe`
/ official `install.ps1`) is **not** an MSIX just because it runs a Desktop
executable.

| Detection | Correct owner | Allowed update |
|---|---|---|
| Verified source-built Desktop, no competing package ambiguity | Hermes CLI | `hermes update --set-channel stable --yes` |
| Verified Microsoft Store app | Microsoft Store | `winget upgrade --id 9PMXK8CZC7KR --exact --source msstore ...` |
| Verified signed sideload MSIX/App Installer | Registered Windows App Installer feed | `Add-AppxPackage -AppInstallerFile <verified official descriptor>` |
| Both Store/MSIX and source build exist, active Desktop owner unclear | Unknown | **BLOCKED** |
| Store vs sideload cannot be proven | Unknown | **BLOCKED** |
| No supported existing Hermes installation | Not installed | **BLOCKED** — no automatic bootstrap |

**Never convert one distribution into another during `update`**, delete the other copy, overwrite signed packages with source-built files, or use a GitHub CLI release as proof the Store has published a package.

---

## 8. Windows: `check` end to end

1. Verify Windows 11 and PowerShell 5.1+ (do not require PowerShell 7 or third-party modules).
2. Identify installed Desktop owner, package identity and **installed version**; for source, also identify Hermes CLI version and checkout/channel. Record ambiguity as `BLOCKED`.
3. Determine update availability using the **right owner**, without changing package state:
   - source → `hermes update --check`;
   - Store → `winget list/upgrade --available` with exact product/source filtering; WinGet may return “no applicable upgrade,” which can mean *already current in the Store channel* or *not offered here* — do not equate with GitHub stable;
   - sideload → only read and validate the registered/publisher-verified official descriptor; missing descriptor is `UNKNOWN`, rejected descriptor or unavailable feed is `BLOCKED`, never current-by-assumption.
4. Validate explicit/verified Linux backend URL (`HERMES_DESKTOP_REMOTE_URL` can override saved Desktop selection). Avoid logging the Desktop's saved authentication credentials.
5. Check network/Tailscale if available, then `GET /api/status`. Classify **TCP reachable / Hermes JSON / auth advertised** separately.
6. If existing approved credentials and a documented terminal-capable WebSocket test path are available, test the authenticated `/api/ws` handshake and record success; **never scrape/decrypt saved Desktop tokens just to claim full health**. Without this proof mark WebSocket/session `NOT_TESTED`.
7. Report any connection mismatch (Desktop configured for A but test queried B) as **configuration inconsistency** and do not silently edit the saved URL.

---

## 9. Windows: `update` end to end

### Common preflight

- Identify owner unambiguously and confirm official stable channel, Windows update capability, permissions, and package/source files.
- Do not run broad `Get-Process Hermes* | Stop-Process -Force`, generic Python process killing, `--force-venv`, unrestricted `winget upgrade --all`, or download/run code from an unverified mirror.
- If the installed app has locks or Windows requests closing it, either use only a **targeted, verified, graceful** close operation with explicit operator authorization or return `BLOCKED` with the relevant PID/process image/path. **Never terminate unrelated Hermes services.**

### A. Source/bootstrap Desktop

```powershell
hermes update --plan
hermes update --set-channel stable --yes
```

Add `--no-backup` only if explicitly selected. Check `$LASTEXITCODE` after **every** external command. The source updater can rebuild Desktop as part of its own pipeline. Use the terminal-only repair:

```powershell
hermes desktop --build-only --force-build
```

**only if** upstream output/receipt indicates a missing or failed Desktop build, and the source app is no longer holding the build output files. This option builds without launching Desktop. Do not run `hermes desktop` alone, which can open the GUI. Inspect native receipt `followups` and `desktop` build result.

### B. Microsoft Store Desktop

Use **exact** Store product ID `9PMXK8CZC7KR`, not a name search that might match another application:

```powershell
winget upgrade --id 9PMXK8CZC7KR --exact --source msstore --silent --accept-source-agreements --accept-package-agreements
```

Re-read `Get-AppxPackage` and the Store upgrade listing. Handle WinGet's `NO_APPLICABLE_UPGRADE` return as its own outcome (not proof of GitHub stable parity and not necessarily a broken installation). Never fall back to sideloading or to `hermes update` for package-owned files.

### C. Sideload MSIX Desktop

1. Discover the actual registered App Installer source / official publisher feed. Verify **HTTPS host**, official sideload identity `NousResearch.HermesBundled`, publisher matching the installed Nous Research package, package version, non-downgrade, and Microsoft-trusted signature through Windows package validation. A missing descriptor is `UNKNOWN` in check mode and blocks update; a rejected descriptor is `BLOCKED`.
2. Only if the official signed `.appinstaller` descriptor is reachable and proposes a non-downgrade, use Windows `Add-AppxPackage -AppInstallerFile` through PowerShell.
3. Validate installed package version afterward; if the publisher feed is unavailable, **BLOCKED**, with the failed URL/HTTP or transport error and no fallback source build.

**Known distribution caveat:** a publicly referenced stable `.appinstaller` feed was unreachable during research on 2026-11-23. Its status must be re-checked at runtime; do not hardcode a successful assumption or recommend a different installer to hide the problem.

### Post-update Windows checks

- Package/CLI version before/after and distributor-specific “current” status.
- When source-built, native Hermes diagnostics + latest receipt with no required follow-ups.
- No unwanted Desktop GUI launch.
- Remote URL host resolves and the VM HTTP endpoint responds with Hermes JSON.
- Authenticated WebSocket **only if truly tested**; HTTP-only success is not “Desktop connected.”

---

## 10. Cross-host validation: the real end-to-end test

To claim the **whole architecture** is healthy, these are **separate** checks:

| Layer | Checked on | Evidence | Failure class |
|---|---|---|---|
| Linux source installed/current | VM | checkout provenance + version/channel | `VERSION_OR_PROVENANCE` |
| Gateway alive/current | VM | supervisor + live PID/revision + served profiles | `GATEWAY` |
| Desktop API backend alive/current | VM | actual `hermes-serve` unit/PID + `/api/status` | `SERVE_BACKEND` |
| Tailscale/private route works | Windows | route/port test to actual VM URL | `NETWORK` |
| Endpoint is really Hermes | Windows | `/api/status` expected JSON | `PROTOCOL` |
| Authentication works | Windows | existing approved session sign-in result | `AUTH` |
| Chat WebSocket works | Windows | authenticated `/api/ws` handshake/heartbeat | `WEBSOCKET` |
| Desktop package current | Windows | package owner/version/updater result | `WINDOWS_PACKAGE` |

**Never infer `AUTH` or `WEBSOCKET` from HTTP 200/401/403.** Never infer a Windows check passed from a Linux agent without an actual Windows execution result.

### Agent location / execution boundary

- T3 running on the **Ubuntu VM** may run the Linux skill locally. It **cannot update Windows from Linux** unless the user has explicitly configured and authorized a supported Windows remote terminal. Otherwise, return the precise PowerShell commands for the user/T3 Windows agent to run.
- T3 running on **Windows** may run the Windows skill locally. Linux operations require an authorized SSH shell running as the Hermes service owner; do not assume SSH access just because Tailscale can reach port 9119.
- One repo can be checked out on both hosts. **No cross-host orchestration service is needed.** A combined report can merge evidence from two independently executed local runs.

---

## 11. Failure response contract (NON-NEGOTIABLE)

When any check fails or remains unverified, the agent MUST create a **redacted, structured Markdown report** and print the local path. Do not end with “it failed; try reinstalling.”

### Required sections

1. **Verdict:** `HEALTHY`, `DEGRADED`, `PARTIAL`, `FAILED`, `BLOCKED`, or `UNKNOWN`, with the exact operation and failing phase.
2. **Scope:** target host/OS/account, attempted command, timestamp, selected installation and package owner, backend URL **without embedded credentials**, run mode, whether mutation occurred.
3. **Expected vs actual:** release/channel, selected executable, service supervisor, expected/served profiles, service states/PIDs, package version, local and remote health checks.
4. **Timeline:** command/phase order, exit codes, and the **last successfully completed phase**. If the CLI exited 0 but receipt has unresolved `followups`, state that explicitly.
5. **Precise error:** one short exact error excerpt (redacted), upstream receipt `outcome` and `followups`, affected service/URL, and timeout/HTTP codes where relevant.
6. **Supporting evidence:** redacted `hermes update --plan`, `hermes gateway status`, relevant `doctor`/`pm` findings, service status and scoped `journalctl` tail, update receipt path and selected fields, Windows installed package/WinGet output and Windows-specific error text. Link local paths; **do not paste entire raw secret-bearing logs**.
7. **Root cause:** one or more hypotheses **labeled confirmed / likely / unknown**; include the evidence for each. Never present a guess as a fact.
8. **Blast radius:** what still works; whether gateway, bots, Desktop backend, or Windows app is affected; any services intentionally left running or stopped.
9. **Next action:** the **single lowest-risk concrete fix** and exact command *only when its safety is grounded*. If fixing requires permission, secrets, auth, unit edits, or topology migration, clearly request a separate authorization.
10. **Re-verification:** commands to run to close the incident and conditions for success; do not claim the incident is closed until they pass.

### Reporting rules

- Save sanitized reports under `reports/<host>/<UTC_TIMESTAMP>-check.md` or `...-update.md` (ignored by Git).
- Include external update artifacts / logs **as paths**, not automatic uploads. Never commit personal machine reports by default.
- Redact: passwords, API tokens, session tokens, SSH keys, OAuth material, auth headers, `.env` contents, personally identifying data unrelated to diagnosis.
- Use `journalctl --user -u <verified-unit> -n 100 --no-pager` or its system-unit equivalent; sanitize before embedding lines in report. Avoid commands that indiscriminately dump environments or config secrets.
- Mask URL credentials/query secrets, but retain hostname/port/path so connectivity is diagnosable.
- **Do not retry blindly**. One repair or retry only after a specific cause is established, authorized, and recorded.

### Example failure diagnosis (illustrative, not observed)

```text
VERDICT: PARTIAL — Linux update installed new code, Desktop backend stale
Host: openclaw (Ubuntu); operation: update; official channel: stable
CLI: v0.23.3; gateway: active/current; Hermes served profiles: 6/6
Desktop backend: hermes-serve.service failed after restart (exit-code 1)
HTTP GET /api/status: connection refused at 127.0.0.1:9119
Updater receipt: outcome=success; followups=[backend restart reminder]
Confirmed: source files advanced, but independently supervised backend did not restart.
Likely cause: backend startup error; inspect sanitized journal excerpt before changing unit.
Safe next step: `systemctl --user status hermes-serve.service --no-pager`
Status: NOT RESOLVED. No authentication/WS tests completed.
```

All values in this example are **hypothetical**. Reports must always use actual runtime evidence.

---

## 12. Error classification and exact playbooks

| Symptom | What to capture first | Do NOT do | Safe next step |
|---|---|---|---|
| `hermes` not found | `$PATH`, intended user, known install path, `hermes update --install-id` if possible | Reinstall automatically | Locate existing launcher; return `BLOCKED` if missing |
| Checkout dirty / fork / wrong channel | current branch, remote, `git status --short`, update plan | `git reset --hard`, forced stash discard | Stop; ask user to preserve/resolve local changes |
| Stable target older than checkout | source SHA, target tag/SHA | Force downgrade | Stop; explain code/schema mismatch risk |
| Native update exits 0 but `followups[]` nonempty | latest receipt path, stage, reason, service state | Claim success | Diagnose exact recorded deferred step |
| Multi-profile migration planned | migration dry-run and unit inventory | Auto-fold gateways | Stop; obtain owner decision on topology |
| Gateway inactive / stale revision | Hermes gateway status, systemd scope/unit/PID, journal tail | `killall`, restart all bots | Restart only the verified affected gateway if authorized |
| Desktop `hermes-serve` fails | unit definition/provenance, service state, journal tail, `/api/status` | Change firewall/credentials to mask it | Fix evidenced startup issue; restart verified backend |
| HTTP listener up, wrong JSON | URL, HTTP status, response content type/redacted body | Label healthy | Verify URL/service binding and proxy route |
| HTTP 401/403 | endpoint status, auth providers | Change/disable auth | Label reachable but auth not proven; test approved credentials |
| HTTP passes, WS fails | `/api/ws` handshake error, TLS/proxy, auth/origin reason | Open port publicly | Check reverse proxy, authenticated session and WebSocket routing |
| Windows Store says “no upgrade” | product ID, installed version, WinGet output/exit | Install sideload bundle | Mark channel-specific availability; explain not equal to CLI stable |
| Sideload feed unavailable | verified official feed URL, HTTP/TLS error | Download from mirror | Block; require publisher release/feed restoration |
| Windows source build locked | PID/path/owner of lock, updater diagnostic | Kill all Hermes/Python | Request targeted graceful close or defer update |
| Backend URL differs from Desktop selection | actual saved connection identity (no tokens), env override, requested URL | Overwrite saved profile | Report mismatch; request corrected URL explicitly |

---

## 13. Safety boundaries (must remain true)

**Allowed during `check`:** process/service inspection, CLI diagnostics, package/version reads, network test, an ignored local report. No restart or configuration changes.

**Allowed during `update`:** official source/package-owner update, *only* restart an already confirmed existing service according to the expected pre-update state, diagnostics/reporting.

**Explicitly prohibited without a new request:**

- Installing/reinstalling Hermes from scratch; uninstalling a competing Windows package.
- `git reset --hard`, `git clean -fd`, forced branch switching, pip/uv dependency repair outside Hermes' own updater.
- `hermes update --force`, `--force-venv`, broad process-kill scripts.
- Automatic multi-profile gateway migration not already approved, changes to `gateway.auto_multiplex_migration`, profile creation/deletion, credential reauthorization.
- Disabling auth, exposing ports to `0.0.0.0`, editing firewall/Tailscale/SSH access, changing OAuth/session-token configurations to make a health check pass.
- Installing packages or elevated system units with unapproved `sudo`, auto-merging PRs, rebooting machines.
- Unrelated refactors or changing Hermes upstream source code.
- Printing secrets or committing runtime reports/logs/`.env` files.

**Backup policy:** keep upstream Hermes' default lightweight quick snapshot; do not implement a second backup system. The `--no-backup` opt-out requires a clear user instruction and is recorded in the report. Hermes' source-code startup rollback is *not* a universal rollback for data schema, packages, or live sessions.

---

## 14. Tests and acceptance criteria before calling this repository ready

### Linux script tests

- [ ] `bash -n` passes; behavior tested with mocked `hermes`, `systemctl`, `curl` and a temporary fake receipt.
- [ ] `check` does not call update/apply, service restart, migration apply or config setter.
- [ ] Fails closed on wrong UNIX user, missing source, conflicting user/system units, dirty checkout, older stable target, migration plan requiring consent.
- [ ] Uses `hermes update --set-channel stable --yes` only once, no unrequested `--no-backup`.
- [ ] Native gateway restart respected; separately supervised `hermes-serve` refreshed and PID verified when applicable.
- [ ] Receipt with `outcome=success` **and a followup** produces `PARTIAL`, not `UPDATED`.
- [ ] HTTP 200 wrong content is not a success; HTTP 401 is not an authenticated session success.
- [ ] Relevant service failure includes redacted journal evidence and exact remediation guidance.

### Windows script tests

- [ ] Parses in Windows PowerShell 5.1; real execution tested on Windows 11, not Linux-only static inspection.
- [ ] Source, Store, sideload, ambiguous dual install, and unknown owner branches each tested.
- [ ] Verifies Store identity `NousResearchInc.HermesAgent` and sideload identity `NousResearch.HermesBundled`; blocks unknown/dual identities; never uses source CLI to update MSIX; never silently migrates owner.
- [ ] Checks `$LASTEXITCODE` on native commands; handles WinGet “no applicable upgrade” truthfully.
- [ ] Official sideload source unreachable produces `BLOCKED` without fallback.
- [ ] Running GUI lock results in targeted diagnosis, not blanket process termination.
- [ ] No GUI opened; source Desktop rebuild is headless and conditional.
- [ ] Tailscale/network/HTTP/WS status each reported separately.

### E2E checks on the user's real deployment (required)

- [ ] Capture **read-only** Linux baseline and confirm actual `hermes-gateway` / `hermes-serve` units and service account.
- [ ] Capture **read-only** Windows baseline, package owner and correct Desktop remote URL.
- [ ] Exercise a controlled Linux stable update; verify all originally expected profiles and backend status.
- [ ] Exercise a controlled Windows owner-specific update; verify package state and VM HTTP response.
- [ ] Run permitted authenticated WS test, or explicitly mark not tested.
- [ ] Run `check` after the update on both hosts and ensure repeat runs are idempotent.
- [ ] Simulate at least one failure per platform and inspect the detailed Markdown report for completeness and redaction.

**Definition of done:** the user can open this repo in T3 and ask either operation. The agent selects exactly one relevant skill, calls its script, reports what is verified vs unknown, and on failure provides a reproducible detailed report. No manual command invention is necessary. The scripts must first pass the real-host tests; documentation alone does not meet the runtime acceptance criteria.

---

## 15. Implementation order (small, controlled delivery)

**Milestone 1 — Documentation and baseline (now):** ship `README.md`, `AGENTS.md`, this spec and failure template; read-only command inventory on Ubuntu/Windows. Do not update anything yet.

**Milestone 2 — Linux skill first:** implement `check`, test, then `update`, and run a controlled VM test. This is the most important dependency for the Windows Desktop.

**Milestone 3 — Windows skill:** implement safe owner detection + `check`, then owner-specific `update`, and verify network/remote backend from the Windows host.

**Milestone 4 — Final E2E acceptance:** compare both reports, test failure scenarios and credentials redaction, and mark the repository ready. Do not add automation or scheduled updating in V1.

No PR/branch management, UI, dashboard, multi-host remote execution, extra dependencies, or automatic periodic updates are required for V1.

---

## 16. Copy/paste agent requests

**Check Linux**

> Read `AGENTS.md`, `docs/OPERATIONS_SPEC.md`, and `skills/hermes-linux/SKILL.md`. Run the Linux `check` script on this Ubuntu host. Do not modify Hermes, services, or configuration. Report exact current version vs stable, service owners/status, gateway profiles, `hermes-serve` API health, topology migration risk, and any unknowns. If anything fails, produce the required redacted failure report and the least-risk next action.

**Update Linux**

> Read repository instructions and run Linux preflight. Only if safe, update the installed official Hermes source checkout to stable using its native updater (one update), refresh the existing separately supervised Desktop backend, and verify all expected profiles/services, the receipt, and HTTP health. No destructive commands, implicit gateway topology migration, new services or auth changes. Report `UPDATED`, `ALREADY_CURRENT`, `PARTIAL`, `FAILED`, or `BLOCKED` with evidence.

**Check Windows**

> Read repository instructions and run the Windows `check` script **on Windows**. Detect the actual Desktop owner (source vs Store vs sideload), installed version and owner-specific update availability. Test the configured private Linux backend endpoint; distinguish network, JSON, authentication and WebSocket evidence. Do not open Desktop, modify state or invent an endpoint. Produce the required report.

**Update Windows**

> Read repository instructions and run the Windows `update` script **on Windows** after owner detection. Use only that distribution's official terminal updater; do not kill unrelated processes or switch distributions. Do not open Desktop. Re-verify installed version, VM backend URL and available authenticated transport checks. On any blocker, stop and produce the full detailed failure report instead of guessing a workaround.

**Check both hosts**

> Run the Linux check locally on the VM and the Windows check on Windows using only authorized terminal access. Do not claim a host was inspected if it was not executed there. Summarize the two evidence reports and whether the whole Desktop→VM path is actually proven.

---

## 17. Upstream primary sources (re-check when implementing)

1. Nous Research — Updating: https://hermes-agent.nousresearch.com/docs/getting-started/updating
2. Nous Research — Installation and package ownership: https://hermes-agent.nousresearch.com/docs/getting-started/installation
3. Nous Research — Hermes Desktop / remote backend: https://hermes-agent.nousresearch.com/docs/user-guide/desktop
4. Nous Research — Multi-profile gateways / automatic multiplexing: https://hermes-agent.nousresearch.com/docs/user-guide/multi-profile-gateways
5. Nous Research — Multiple desktop gateway connections: https://hermes-agent.nousresearch.com/docs/user-guide/multi-connection-desktop
6. Nous Research — CLI reference: https://hermes-agent.nousresearch.com/docs/reference/cli-commands
7. Hermes official latest stable release: https://github.com/NousResearch/hermes-agent/releases/latest
8. Microsoft — WinGet upgrade: https://learn.microsoft.com/en-us/windows/package-manager/winget/upgrade
9. Microsoft — Add-AppxPackage: https://learn.microsoft.com/en-us/powershell/module/appx/add-appxpackage
10. Hermes Desktop product identity (Store vs sideload MSIX): https://github.com/NousResearch/hermes-agent/blob/main/apps/desktop/product-identity.cjs

**Freshness rule:** inspect the current official docs and `hermes update --help` on the installed version before relying on an argument that may have changed. Do not silently use `main` or canary because a public doc becomes inconsistent. If docs and installed commands disagree, record both, stop before potentially destructive actions, and propose a safe compatibility path.

---

## 18. T3 coding-agent implementation brief (execute after creating the repository)

**Goal:** Turn this specification into two reliable terminal-only Hermes skills, one for Ubuntu and one for Windows, supporting `check` and `update` with meaningful exit codes and redacted incident reports.

**Context:** This repository is a documentation-first blueprint. The user's Linux VM has an existing Hermes install with a gateway and a separately managed remote Desktop backend. The Windows Hermes Desktop connects to the VM over a private network. Installation details **must be discovered**, not inferred from these notes. The official Hermes updater owns source changes; Windows distribution owners own their app packages.

**Scope:**

1. Implement `skills/hermes-linux/SKILL.md` and `scripts/hermes.sh` with exact `check`/`update` contract in Sections 3–6.
2. Implement `skills/hermes-windows/SKILL.md` and `scripts/hermes.ps1` with owner detection, safe check/update modes, and backend probe in Sections 7–9.
3. Implement Markdown failure report output conforming to Section 11 and the template, with default `reports/` destination ignored by Git.
4. Add focused mock-driven CLI tests for preflight, successful state, and failure/blocked state on each OS; no mandatory additional runtime dependencies.
5. Update root README only as needed to replace "not yet implemented" with **actual** verified usage once scripts have been validated.

**Acceptance criteria:**

- Linux `check` is non-destructive, shows actual stable status, discovers correct user/system unit(s), and detects when Desktop backend isn't healthy. No bogus success from optional/no HTTP tests.
- Linux `update` uses **one** native stable update, follows the existing gateway supervisor, refreshes only the independently supervised backend, validates every expected profile, and inspects native receipt follow-ups.
- Windows `check/update` detects competing install types, refuses ambiguity, and chooses only the actual owner; it never opens Desktop intentionally. PowerShell 5.1 exit codes are checked.
- An HTTP reachability pass is never represented as authenticated WebSocket success.
- Both scripts exit nonzero for blocked/partial/failed states and generate actionable **sanitized** reports with exact evidence, cause confidence, and next command.
- Minimal scripts and necessary tests pass in supported environments. Real VM/Windows acceptance remains pending until explicitly run on those hosts.

**Do NOT touch:** upstream Hermes code, gateway topology, production profiles/credentials, auth/Tailscale/firewall, unrelated systemd units, other repos, OS package sources, or machine startup settings. No automatic reinstall, new scheduler, dashboard, or unnecessary abstractions.

**Execution rule:** implement and test from a new branch or worktree if appropriate; do not commit runtime reports or secrets and **never claim machine health or update success without target-host execution evidence**. Deliver a concise implementation summary, test results, remaining gaps and the exact next manual acceptance command.
