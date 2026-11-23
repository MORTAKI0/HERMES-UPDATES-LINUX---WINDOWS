# Focused mock-driven tests for skills/hermes-windows/scripts/hermes.ps1.
#
# On Windows 11 this runs owner-detection and safety branches against mocked
# Appx/WinGet/Hermes commands. It never touches the real Hermes installation,
# package store, network, or GUI.
#
# On non-Windows hosts it performs a parser/static check and skips runtime
# branches; real Windows 11 execution remains required for acceptance.

[CmdletBinding()]
param(
    [switch]$KeepSandbox
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ScriptPath = Join-Path $RepoRoot 'skills\hermes-windows\scripts\hermes.ps1'
$Base = Join-Path ([System.IO.Path]::GetTempPath()) ('hermes-ops-win-tests-' + [guid]::NewGuid().ToString('N'))

$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Add-Pass([string]$Name) {
    $script:Pass++
    Write-Output "PASS  $Name"
}

function Add-Fail([string]$Name, [string]$Detail) {
    $script:Fail++
    $script:Failures.Add($Name)
    Write-Output "FAIL  $Name : $Detail"
}

function Assert-Equal([string]$Name, [string]$Expected, [string]$Actual) {
    if ($Expected -eq $Actual) { Add-Pass $Name } else { Add-Fail $Name "expected '$Expected', got '$Actual'" }
}

function Assert-Contains([string]$Name, [string]$Needle, [string]$Text) {
    if ($Text -like "*$Needle*") { Add-Pass $Name } else { Add-Fail $Name "missing '$Needle'" }
}

function Assert-NotContains([string]$Name, [string]$Needle, [string]$Text) {
    if ($Text -like "*$Needle*") { Add-Fail $Name "unexpected '$Needle'" } else { Add-Pass $Name }
}

function Test-Parser {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -eq 0) {
        Add-Pass 'PowerShell parser accepts hermes.ps1'
    } else {
        $detail = ($errors | ForEach-Object { $_.Message }) -join '; '
        Add-Fail 'PowerShell parser accepts hermes.ps1' $detail
    }
}

function New-Sandbox {
    param([string]$Name)
    $dir = Join-Path $Base $Name
    $repo = Join-Path $dir 'repo'
    $scriptDir = Join-Path $repo 'skills\hermes-windows\scripts'
    $bin = Join-Path $dir 'bin'
    $home = Join-Path $dir 'home'
    $localAppData = Join-Path $dir 'localappdata'
    $receipts = Join-Path $home '.hermes\logs\update_receipts'
    New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    New-Item -ItemType Directory -Path $receipts -Force | Out-Null
    New-Item -ItemType Directory -Path $localAppData -Force | Out-Null
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $scriptDir 'hermes.ps1') -Force
    $callLog = Join-Path $dir 'calls.log'
    Set-Content -LiteralPath $callLog -Value '' -Encoding ASCII

    # WinGet shim.
    @'
@echo off
echo winget %*>>"%MOCK_CALL_LOG%"
if "%~1"=="list" (
  if "%MOCK_WINGET_NO_UPGRADE%"=="1" (
    echo No applicable upgrade found.
  ) else (
    echo NousResearch.HermesBundled   9PMXK8CZC7KR   0.23.2   0.23.3   msstore
  )
  exit /b 0
)
if "%~1"=="upgrade" (
  echo Simulated Store upgrade.
  exit /b 0
)
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $bin 'winget.cmd') -Encoding ASCII

    return [pscustomobject]@{
        Dir = $dir
        Repo = $repo
        Script = (Join-Path $scriptDir 'hermes.ps1')
        Bin = $bin
        Home = $home
        LocalAppData = $localAppData
        Receipts = $receipts
        CallLog = $callLog
    }
}

function Add-SourceInstall {
    param($Sandbox)
    New-Item -ItemType Directory -Path (Join-Path $Sandbox.LocalAppData 'hermes\hermes-agent\.git') -Force | Out-Null
    $hermesCmd = @'
@echo off
echo hermes %*>>"%MOCK_CALL_LOG%"
if "%~1"=="--version" (
  echo Hermes Agent v0.23.2 ^(2026.9.24^) . stable . local abc123
  echo Install directory: %LOCALAPPDATA%\hermes\hermes-agent
  echo Install method: git
  exit /b 0
)
if "%~1"=="update" (
  if "%~2"=="--check" (
    echo Update channel: stable
    echo Selected release available: stable v0.23.3 ^(caafe5389ae5^)
    exit /b 0
  )
  if "%~2"=="--plan" (
    echo Update plan:
    echo   Install: git ^(v0.23.2 @ abc123^)
    echo   Profiles: default
    exit /b 0
  )
  if "%~2"=="--set-channel" (
    echo Simulated source update.
    exit /b 0
  )
)
exit /b 0
'@
    Set-Content -LiteralPath (Join-Path $Sandbox.Bin 'hermes.cmd') -Value $hermesCmd -Encoding ASCII
}

function Set-Receipt {
    param($Sandbox, [int]$Followups)
    if ($Followups -gt 0) {
        $json = '{"schema":1,"outcome":"success","followups":[{"step":"gateway_restart","reason":"deferred backend restart"}],"gateway_restart":{"incomplete":true}}'
    } else {
        $json = '{"schema":1,"outcome":"success","followups":[],"gateway_restart":{"incomplete":false},"desktop":{"status":"ok"}}'
    }
    $path = Join-Path $Sandbox.Receipts ('update_' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff') + '.json')
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-Preamble {
    return @'
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter)
    [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '22631' }
}
function Get-AppxPackage {
    [CmdletBinding()]
    param([string]$Name, [switch]$AllUsers)
    $mode = $env:MOCK_APPX_MODE
    if ($mode -eq 'none') { return }
    $sig = 'Store'
    if ($mode -eq 'sideload') { $sig = 'Developer' }
    [pscustomobject]@{
        Name = 'NousResearch.HermesBundled'
        Version = [version]'0.23.2'
        Publisher = 'CN=Nous Research'
        SignatureKind = $sig
        PackageFullName = 'NousResearch.HermesBundled_0.23.2.0_neutral__test'
        PackageFamilyName = 'NousResearch.HermesBundled_test'
        InstallLocation = 'C:\Program Files\WindowsApps\fake'
    }
}
'@
}

function Invoke-Sandbox {
    param(
        $Sandbox,
        [string[]]$Arguments,
        [string]$AppxMode = 'none',
        [string]$WingetNoUpgrade = '0'
    )
    $quotedArgs = @()
    foreach ($a in $Arguments) {
        if ($a.StartsWith('-')) { $quotedArgs += $a }
        else { $quotedArgs += ("'" + ($a -replace "'", "''") + "'") }
    }
    $argText = ($quotedArgs -join ' ')
    $cmd = (Get-Preamble) + "`n& '$($Sandbox.Script)' $argText; exit `$LASTEXITCODE"

    $oldPath = $env:PATH
    $oldHome = $env:USERPROFILE
    $oldLocal = $env:LOCALAPPDATA
    $oldHermesHome = $env:HERMES_HOME
    $oldAppx = $env:MOCK_APPX_MODE
    $oldWinget = $env:MOCK_WINGET_NO_UPGRADE
    $oldLog = $env:MOCK_CALL_LOG
    $oldScript = $env:MOCK_SCRIPT_PATH
    $oldRemoteUrl = $env:HERMES_DESKTOP_REMOTE_URL
    $oldAppInstaller = $env:HERMES_APPINSTALLER_FILE
    try {
        $env:PATH = "$($Sandbox.Bin);$env:SystemRoot\System32;$env:SystemRoot"
        $env:USERPROFILE = $Sandbox.Home
        $env:LOCALAPPDATA = $Sandbox.LocalAppData
        $env:HERMES_HOME = (Join-Path $Sandbox.Home '.hermes')
        $env:HERMES_DESKTOP_REMOTE_URL = ''
        $env:HERMES_APPINSTALLER_FILE = ''
        $env:MOCK_APPX_MODE = $AppxMode
        $env:MOCK_WINGET_NO_UPGRADE = $WingetNoUpgrade
        $env:MOCK_CALL_LOG = $Sandbox.CallLog
        $env:MOCK_SCRIPT_PATH = $Sandbox.Script
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $env:PATH = $oldPath
        $env:USERPROFILE = $oldHome
        $env:LOCALAPPDATA = $oldLocal
        $env:HERMES_HOME = $oldHermesHome
        $env:MOCK_APPX_MODE = $oldAppx
        $env:MOCK_WINGET_NO_UPGRADE = $oldWinget
        $env:MOCK_CALL_LOG = $oldLog
        $env:MOCK_SCRIPT_PATH = $oldScript
        $env:HERMES_DESKTOP_REMOTE_URL = $oldRemoteUrl
        $env:HERMES_APPINSTALLER_FILE = $oldAppInstaller
    }
    $reportDir = Join-Path $Sandbox.Repo 'reports'
    $report = $null
    if (Test-Path $reportDir) {
        $report = Get-ChildItem -Path $reportDir -Filter '*.md' -File -Recurse |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    return [pscustomobject]@{
        ExitCode = [int]$code
        Output = $output
        ReportPath = $(if ($null -ne $report) { $report.FullName } else { '' })
        Report = $(if ($null -ne $report) { Get-Content -LiteralPath $report.FullName -Raw } else { '' })
        Calls = (Get-Content -LiteralPath $Sandbox.CallLog -Raw)
    }
}

function New-ReceiptJson {
    param($Sandbox, [int]$Followups)
    Set-Receipt -Sandbox $Sandbox -Followups $Followups
}

# ---------------------------------------------------------------------------
Write-Output '== Windows hermes.ps1 tests =='
Test-Parser

if ($env:OS -ne 'Windows_NT') {
    Write-Output 'SKIP  runtime branches require Windows 11 (parser check completed)'
    Write-Output ''
    Write-Output "== Result: $($script:Pass) passed, $script:Fail failed =="
    if ($script:Fail -ne 0) { exit 1 }
    exit 0
}

New-Item -ItemType Directory -Path $Base -Force | Out-Null
try {
    # 1. Source-only check without a backend URL: owner proven, remote UNKNOWN.
    $s = New-Sandbox 'source_check'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('check') -AppxMode 'none'
    Assert-Equal 'source check exit' '1' "$($r.ExitCode)"
    Assert-Contains 'source owner detected' 'OWNER: Source build' $r.Output
    Assert-Contains 'source check UNKNOWN without URL' 'STATUS: UNKNOWN' $r.Output
    Assert-Contains 'source version detected' 'INSTALLED: v0.23.2' $r.Output
    Assert-Contains 'source report exists' '## 1. Verdict' $r.Report

    # 2. Source check with unreachable backend: DEGRADED, network layer separate.
    $s = New-Sandbox 'source_network'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('check', '-BackendUrl', 'http://127.0.0.1:1') -AppxMode 'none'
    Assert-Equal 'source network exit' '1' "$($r.ExitCode)"
    Assert-Contains 'source network degraded' 'STATUS: DEGRADED' $r.Output
    Assert-Contains 'network failure classified' 'TCP connection' $r.Output

    # 3. Source receipt follow-up: not success.
    $s = New-Sandbox 'source_receipt'
    Add-SourceInstall $s
    New-ReceiptJson $s 1
    $r = Invoke-Sandbox $s @('check') -AppxMode 'none'
    Assert-Equal 'source receipt exit' '1' "$($r.ExitCode)"
    Assert-Contains 'receipt follow-up reported' 'unresolved follow-up' $r.Report

    # 4. Store-only check: correct owner, Store availability, no source CLI.
    $s = New-Sandbox 'store_check'
    $r = Invoke-Sandbox $s @('check') -AppxMode 'store'
    Assert-Equal 'store check exit' '1' "$($r.ExitCode)"
    Assert-Contains 'store owner detected' 'OWNER: Microsoft Store' $r.Output
    Assert-Contains 'store availability row' 'Store published a newer package' $r.Report

    # 5. Store no applicable upgrade: truthful channel outcome.
    $s = New-Sandbox 'store_current'
    $r = Invoke-Sandbox $s @('check') -AppxMode 'store' -WingetNoUpgrade '1'
    Assert-Equal 'store current exit' '1' "$($r.ExitCode)"
    Assert-Contains 'store no-upgrade state' 'no applicable upgrade' $r.Report

    # 6. Ambiguous source + MSIX: BLOCKED and no update.
    $s = New-Sandbox 'ambiguous'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('check') -AppxMode 'store'
    Assert-Equal 'ambiguous check exit' '2' "$($r.ExitCode)"
    Assert-Contains 'ambiguous blocked' 'STATUS: BLOCKED' $r.Output
    Assert-Contains 'ambiguous owner reason' 'active Desktop owner is unclear' $r.Output

    # 7. Sideload without a verified descriptor: BLOCKED, no fallback.
    $s = New-Sandbox 'sideload'
    $r = Invoke-Sandbox $s @('check') -AppxMode 'sideload'
    Assert-Equal 'sideload check exit' '2' "$($r.ExitCode)"
    Assert-Contains 'sideload blocked' 'STATUS: BLOCKED' $r.Output
    Assert-Contains 'sideload descriptor reason' 'no registered official App Installer descriptor' $r.Output

    # 8. Not installed: BLOCKED, no bootstrap.
    $s = New-Sandbox 'not_installed'
    $r = Invoke-Sandbox $s @('check') -AppxMode 'none'
    Assert-Equal 'not installed exit' '2' "$($r.ExitCode)"
    Assert-Contains 'not installed blocked' 'STATUS: BLOCKED' $r.Output
    Assert-Contains 'not installed no bootstrap' 'Automatic bootstrap is not allowed' $r.Output

    # 9. Credential-bearing URL is rejected and never written to the report.
    $s = New-Sandbox 'credential_url'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('check', '-BackendUrl', 'http://user:topsecret@127.0.0.1:9119') -AppxMode 'none'
    Assert-Equal 'credential URL exit' '2' "$($r.ExitCode)"
    Assert-NotContains 'credential URL not in report' 'topsecret' $r.Report
    Assert-NotContains 'credential URL not in stdout' 'topsecret' $r.Output

    # 10. Update with ambiguous owner: BLOCKED, no updater invocation.
    $s = New-Sandbox 'update_ambiguous'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('update') -AppxMode 'store'
    Assert-Equal 'ambiguous update exit' '2' "$($r.ExitCode)"
    Assert-NotContains 'ambiguous update did not run source updater' '--set-channel' $r.Calls
    Assert-NotContains 'ambiguous update did not run winget upgrade' 'winget upgrade' $r.Calls
}
finally {
    if (-not $KeepSandbox) {
        Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Output "Sandbox kept: $Base"
    }
}

Write-Output ''
Write-Output "== Result: $($script:Pass) passed, $($script:Fail) failed =="
if ($script:Fail -ne 0) {
    Write-Output ("Failed: " + ($script:Failures -join ', '))
    exit 1
}
exit 0
