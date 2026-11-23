# Agent contract — Hermes Operations

## Mandatory routing

On every request, read `docs/OPERATIONS_SPEC.md`, then read the matching OS-specific `skills/<OS>/SKILL.md` when it exists. Do not invent replacement commands or bypass the scripts. If scripts do not exist yet, implement/test them against the spec; **do not pretend the requested operation ran**.

- **“Check Hermes”**, “is Hermes healthy/current?” → `check` mode, no Hermes deployment mutation.
- **“Update Hermes”** → `update` mode only after preflight and explicit user instruction.
- Route based on **actual execution OS**, not the user's OS mentioned in the prompt. T3 on Linux cannot update Windows without authorized Windows terminal access.
- For both hosts, perform separate checks; a VM health check is not a Windows Desktop test.

## Never guess

Discover executable path, install type, updater channel, supervisor scope, unit name, user, expected profiles, bind URL and Windows package owner at runtime. On ambiguity, exit `BLOCKED` with the evidence required to unblock. Never assume port 9119, package identity, existing credentials, or successful sign-in simply from a HTTP status code.

## Do not mutate unrelated state

No general reinstall, `git reset --hard`, forced CLI update, backend migration, new unit or firewall setting, unapproved elevation, destructive cleanup, GUI launch, blanket process kill, credential rotation, or package-owner switching. Keep upstream Hermes' default quick snapshot unless the user explicitly opts out. Do not introduce a custom backup framework.

## Verification and reporting

1. Record exact versions, command exit codes, service/PID/profiles, package owner, backend connectivity and upstream native receipt.
2. Distinguish what was proven (source/package, gateway, backend API, network, auth, WebSocket) from what was not tested.
3. On any unhealthy, partial, blocked or unknown result, write a **redacted** Markdown report matching `docs/FAILURE_REPORT_TEMPLATE.md`; include the last good step, exact sanitized error, root cause confidence, blast radius, and one lowest-risk next action.
4. Treat exit code 0 plus unresolved Hermes receipt `followups` as **partial**, not a success.
5. Before changes, inspect `hermes gateway migrate --multiplex --dry-run` and STOP if `hermes update` would unapprovedly change the older multi-profile topology.
6. Verify that the existing independently supervised `hermes serve` was refreshed following Linux source update; gateway status alone is insufficient.

## Repo policy

Only implementation of these two skills and supporting docs/tests is in scope. No dashboards, external agents/orchestrators, CI deployments, periodic updates, hidden credentials, or unrelated features. Never commit `reports/`, `.env`, tokens or raw logs.
