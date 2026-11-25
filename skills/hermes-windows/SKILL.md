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

Backend URL precedence is: explicit `-BackendUrl`, then a pre-existing
`HERMES_DESKTOP_REMOTE_URL`, then no URL (`UNKNOWN`). An explicitly supplied
invalid URI, non-HTTP(S) URL, embedded userinfo, query or fragment is rejected;
it is never replaced by the environment fallback. The report records which
source was used and never prints credential userinfo.

If local execution policy blocks scripts, report the blocker. Do not silently
change machine execution policy.

Native Hermes output is decoded as UTF-8 for each invocation, with the prior
console output encoding restored afterward. Reports are written as UTF-8 so
arrows, bullets and other valid Unicode are preserved in Windows PowerShell 5.1
and PowerShell 7.

## Owner detection (mandatory, read-only)

The script inspects, at runtime:

- `Get-Command hermes -All` and a source checkout at
  `%LOCALAPPDATA%\hermes\hermes-agent\.git`.
- Registered Hermes Appx packages, including `SignatureKind`, `Publisher`,
  `Version`, and identity. The official identities are:
  - Microsoft Store: `NousResearchInc.HermesAgent`, Store-signed, publisher
    `CN=EE6D86E4-606F-4E38-B940-AD7248C9D519`.
  - Sideload/bundled: `NousResearch.HermesBundled`, Developer/Enterprise-signed,
    publisher `CN=Nous Research Inc.` (prefix).
- `winget list --id 9PMXK8CZC7KR --exact --source msstore --upgrade-available`
  for Store-channel availability.

Any other Hermes package identity, a signature/identity mismatch, or both
official MSIX identities at once is blocked. The exact Store product ID remains
`9PMXK8CZC7KR`.

It then selects exactly one owner:

| Detection | Owner | Allowed update |
|---|---|---|
| Only a verified source checkout/CLI | Source build | `hermes update --yes` |
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

- **Source:** preflight (`hermes update --plan`, resolved CLI install directory
  matching the discovered checkout, official NousResearch Git remote, clean
  tree, stable channel, no downgrade), exact installed and stable-target
  identities (native install id plus full Git SHA, resolved locally or from the
  verified official origin's release tag), one
  `hermes update --yes`, independent exact version/revision/identity/receipt
  checks, and a headless `hermes desktop --build-only --force-build` **only**
  when the current operation's receipt/output proves a build is owed, the
  native update completed successfully, and no Desktop process is holding the
  build output.
- **Store:** exact product ID `9PMXK8CZC7KR` with `--source msstore`, then
  re-reads `Get-AppxPackage`. `NO_APPLICABLE_UPGRADE` is its own outcome.
  Locked packages are reported with process evidence, never killed.
- **Sideload:** only a publisher-verified `.appinstaller` whose `MainPackage`
  or `MainBundle` identity, publisher, HTTPS URI, non-downgrade version, and
  signed-sideload ownership all match. A missing descriptor is `UNKNOWN` in
  check mode and blocks update; a rejected, ambiguous, or unreachable
  descriptor is `BLOCKED`. There is no fallback installer.
- After any package update, independently verifies the expected package is
  still installed, its owner/identity/publisher are unchanged, and its version
  is valid, non-downgraded, and satisfies the descriptor target where
  applicable. Missing, ambiguous, invalid, or non-advancing packages are never
  reported as success. It also re-checks source receipts, DNS/TCP/HTTP, and
  marks WebSocket `NOT_TESTED` unless truly exercised.

For source updates, the wrapper generates one operation correlation id and
scopes it to the updater through `HERMES_UPDATE_CORRELATION_ID`, restoring any
previous value afterward. Only the terminal `update_*.json` receipt whose
`correlation_id` matches that operation is evidence for the update. A newer
unrelated `latest.json`, a plugin-check artifact, a historical receipt, a
malformed/incomplete schema, a failed outcome, unresolved `followups[]`, or
`gateway_restart.incomplete=true` cannot produce `UPDATED`. Receipts are read
only and never rewritten or deleted.

`UPDATED` also requires the CLI version and full Git HEAD to equal the
pre-update stable target, the install id and canonical checkout to be unchanged,
official provenance and stable channel to remain valid, the checkout to remain
clean, the Desktop artifact to be stamped at that exact commit, and the remote
backend JSON health check to pass. HTTP 200 alone still does not prove
authentication or WebSocket.

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
  `-AppInstallerFile` check reports `UNKNOWN` and update is `BLOCKED` rather
  than guessing a feed.
- WinGet output formats and exit codes are distributor/version dependent; the
  script records the raw bounded output for diagnosis.
- The script cannot prove the Linux host state; run the Linux skill separately
  and merge the two evidence reports.
- Windows-host execution and PS 5.1 parsing must be accepted on a real Windows
  machine; Linux-only inspection is insufficient.
