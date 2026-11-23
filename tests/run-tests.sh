#!/usr/bin/env bash
# Run the focused tests available on the current host.
#
# Linux: always runs the mocked bash suite.
# Windows: if PowerShell is available, runs the parser check plus (on an actual
# Windows host) the mocked owner-detection suite.
set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
FAILED=0

printf '== Linux tests ==\n'
if bash "$REPO_ROOT/tests/linux/test_hermes.sh"; then
  printf 'Linux: PASS\n'
else
  printf 'Linux: FAIL\n'
  FAILED=1
fi

printf '\n== Windows tests ==\n'
if command -v pwsh >/dev/null 2>&1; then
  PWSH=pwsh
elif command -v powershell >/dev/null 2>&1; then
  PWSH=powershell
else
  PWSH=""
fi

if [ -z "$PWSH" ]; then
  printf 'SKIP: PowerShell is not available on this host; run tests/windows/test_hermes.ps1 on Windows 11.\n'
else
  if "$PWSH" -NoProfile -File "$REPO_ROOT/tests/windows/test_hermes.ps1"; then
    printf 'Windows: PASS\n'
  else
    printf 'Windows: FAIL\n'
    FAILED=1
  fi
fi

printf '\n'
if [ "$FAILED" -ne 0 ]; then
  printf 'Overall: FAIL\n'
  exit 1
fi
printf 'Overall: PASS (with any skipped host-specific checks listed above)\n'
exit 0
