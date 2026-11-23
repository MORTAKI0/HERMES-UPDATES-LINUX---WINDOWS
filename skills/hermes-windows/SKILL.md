---
name: hermes-windows
description: Check or update Hermes Desktop on Windows 11 by proving the actual distribution owner (source build, Microsoft Store, or signed sideload MSIX) and verifying the private Linux backend separately. Use for "check Hermes" or "update Hermes" only when execution is actually on Windows.
---

# Hermes Windows operations

This skill is a **terminal-only orchestrator and verifier** for Hermes Desktop on
Windows 11. It never launches the Desktop GUI intentionally and never converts
one distribution into another. Follow `docs/OPERATIONS_SPEC.md` (especially
Sections 7–11) and `docs/FAILURE_REPORT_TEMPLATE.md`.

## When to use

Use only when the **actual execution host is Windows 11** with Windows
PowerShell 5.1+. A T3 session on the Ubuntu VM cannot update Windows without an
explicitly authorized Windows terminal; in that case return the exact command
for the Windows agent instead of claiming a result.

- **“Check Hermes” / “Is Hermes up to date?”** → `check`
- **“Update Hermes”** → `update`, only after owner detection and an explicit
  user instruction.

## Requirements

- Windows 11 (build 22000+), Windows PowerShell 5.1 or newer. PowerShell 7 and
  third-party modules are not required.
- An existing Hermes Desktop installation. This skill never bootstraps,
  reinstalls, or uninstalls a competing copy.
- An explicit `-BackendUrl` or a pre-existing `HERMES_DESKTOP_REMOTE_URL` for
  the private Linux backend. The script never invents or silently edits a URL.
- Microsoft Store updates require `winget`. Sideload updates require an
  operator-supplied, publisher-verified `.appinstaller` descriptor.

## Commands

From the repository root, on Windows:

```powershell
powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 check -BackendUrl 'http://HOST:9119'
powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 update -BackendUrl 'http://HOST:9119'
```

Optional:

```powershell
-NoBackup                          # source update only; explicit user opt-out
-AppInstallerFile <path>           # signed sideload descriptor, never guessed
```

If local execution policy blocks scripts, report the blocker. Do not silently
change machine execution policy.

## Owner detection (mandatory, read-only)

The script inspects, at runtime:

- `Get-Command hermes -All` and a source checkout at
  `%LOCALAPPDATA%\hermes\hermes-agent\.git`.
- `Get-AppxPackage -Name 'NousResearch.HermesBundled'`, including
  `SignatureKind`, `Publisher`, `Version`, and package identity.
- `winget list --id 9PMXK8CZC7KR --exact --source msstore --upgrade-available`
  for Store-channel availability.

It then selects exactly one owner:

| Detection | Owner | Allowed update |
|---|---|---|
| Only a verified source checkout/CLI | Source build | `hermes update --set-channel stable --yes` |
| Only a Store-signed MSIX | Microsoft Store | `winget upgrade --id 9PMXK8CZC7KR --exact --source msstore ...` |
| Only a signed sideload MSIX with a verified descriptor | Sideload MSIX | `Add-AppxPackage -AppInstallerFile <verified descriptor>` |
| Source + MSIX both present | Unknown | `BLOCKED` |
| Store vs sideload cannot be proven | Unknown | `BLOCKED` |
| Nothing supported installed | Not installed | `BLOCKED`, no bootstrap |

The script never uses `hermes update` for package-owned MSIX files, never uses a
GitHub CLI release as proof of Store availability, and never deletes the other
copy.

## What `check` does

1. Confirms Windows 11 and PowerShell 5.1+.
2. Detects the installed owner, package identity, signature kind, and installed
   version; records ambiguity as `BLOCKED`.
3. Determines update availability using the **owner's** channel only. WinGet
   “no applicable upgrade” is reported as a Store-channel outcome, not as proof
   of GitHub stable parity.
4. Validates the explicit/pre-existing backend URL without logging credentials.
5. Reports DNS, TCP, Tailscale, HTTP, JSON/protocol, authentication, and
   WebSocket as **separate layers**.
6. Reads the native source update receipt when applicable. Store/MSIX receipts
   are distributor-owned.
7. Writes a redacted report under `reports\<host>\<UTC>-check.md`.

No package mutation, process kill, GUI launch, or saved-URL edit occurs.

## What `update` does

- **Source:** preflight (`hermes update --plan`, clean checkout, stable channel,
  no downgrade), one `hermes update --set-channel stable --yes`, independent
  version/receipt checks, and a headless `hermes desktop --build-only
  --force-build` **only** if output or receipt proves a missing/failed Desktop
  build.
- **Store:** exact product ID `9PMXK8CZC7KR` with `--source msstore`, then
  re-reads `Get-AppxPackage`. `NO_APPLICABLE_UPGRADE` is its own outcome.
  Locked packages are reported with process evidence, never killed.
- **Sideload:** only a publisher-verified `.appinstaller` whose identity,
  publisher, HTTPS URI, and non-downgrade version all match the installed
  package. An unreachable feed is `BLOCKED`; there is no fallback installer.
- After any update, re-checks package/CLI version, source receipt follow-ups,
  DNS/TCP/HTTP, and marks WebSocket `NOT_TESTED` unless truly exercised.

## Arguments and exit codes

| Exit | Verdict | Meaning |
|---|---|---|
| `0` | `HEALTHY`, `UPDATED`, `ALREADY_CURRENT` | All checks the script can genuinely prove passed |
| `1` | `DEGRADED`, `PARTIAL`, `FAILED`, `UNKNOWN` | Degraded, unverified, partial, or failed |
| `2` | `BLOCKED` | Ambiguous owner, unsafe, unsupported, or needs operator action |

No backend URL means remote connectivity is `UNKNOWN`, never healthy. Store
“no upgrade” is not GitHub-stable parity. HTTP 200 is not authentication, and
HTTP 401/403 is not a usable Desktop session. WebSocket is never inferred.

## Report interpretation

Reports follow `docs/FAILURE_REPORT_TEMPLATE.md`. Look first at the owner row and
the per-layer network rows. A clean local package update with an unreachable VM
is `PARTIAL`, not `UPDATED`. Never commit reports, `.env`, auth stores, tokens,
or raw logs.

## Safety boundaries

- No broad `Get-Process Hermes* | Stop-Process -Force`, no Python kill sweep,
  no `--force-venv` outside Hermes' own documented flow.
- No GUI launch; `hermes desktop` without `--build-only` is prohibited.
- No distribution conversion, package uninstall, or owner switching.
- No unrestricted `winget upgrade --all`.
- No firewall, Tailscale, auth, or saved-URL changes to make a check pass.
- No retry loop after an updater failure.

## Known limitations

- The script does not scrape or decrypt saved Desktop tokens, so an
  authenticated WebSocket/session is `NOT_TESTED` unless a documented terminal
  credential path is supplied.
- Sideload descriptor discovery is not standardized; without
  `-AppInstallerFile` the script returns `BLOCKED` rather than guessing a feed.
- WinGet output formats and exit codes are distributor/version dependent; the
  script records the raw bounded output for diagnosis.
- The script cannot prove the Linux host state; run the Linux skill separately
  and merge the two evidence reports.
- Windows-host execution and PS 5.1 parsing must be accepted on a real Windows
  machine; Linux-only inspection is insufficient.
