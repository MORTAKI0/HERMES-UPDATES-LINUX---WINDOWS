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
    echo NousResearchInc.HermesAgent   9PMXK8CZC7KR   0.23.2   0.23.3   msstore
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
    New-Item -ItemType Directory -Path (Join-Path $Sandbox.LocalAppData 'hermes\bin') -Force | Out-Null
    $hermesCmd = @'
@echo off
echo hermes %*>>"%MOCK_CALL_LOG%"
if "%~1"=="--version" (
  echo Hermes Agent v0.23.2 ^(2026.9.24^) . %MOCK_SOURCE_CHANNEL% . local abc123
  echo Install directory: %MOCK_INSTALL_DIR%
  echo Install method: %MOCK_SOURCE_METHOD%
  exit /b 0
)
if "%~1"=="update" (
  if "%~2"=="--check" (
    echo Update channel: %MOCK_UPDATE_CHANNEL%
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
    Set-Content -LiteralPath (Join-Path $Sandbox.LocalAppData 'hermes\bin\hermes.cmd') -Value $hermesCmd -Encoding ASCII
    Add-GitShim $Sandbox
}

function Add-GitShim {
    param($Sandbox)
    $gitCmd = @'
@echo off
echo git %*>>"%MOCK_CALL_LOG%"
if "%~1"=="-C" (
  if "%~3"=="remote" (
    echo %MOCK_GIT_REMOTE%
    exit /b 0
  )
  if "%~3"=="rev-parse" (
    if "%~4"=="--is-inside-work-tree" (
      echo %MOCK_GIT_INSIDE%
      exit /b 0
    )
    if "%~4"=="--short=12" (
      echo abc123def456
      exit /b 0
    )
  )
  if "%~3"=="symbolic-ref" (
    if "%MOCK_GIT_BRANCH%"=="DETACHED" ( exit /b 1 )
    echo %MOCK_GIT_BRANCH%
    exit /b 0
  )
  if "%~3"=="status" (
    if not "%MOCK_GIT_STATUS_EXIT%"=="0" (
      echo fatal: unable to read repository 1>&2
      exit /b %MOCK_GIT_STATUS_EXIT%
    )
    if not "%MOCK_GIT_STATUS%"=="" echo %MOCK_GIT_STATUS%
    exit /b 0
  )
)
exit /b 1
'@
    Set-Content -LiteralPath (Join-Path $Sandbox.Bin 'git.cmd') -Value $gitCmd -Encoding ASCII
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
function Get-MockHermesPackage {
    param([string]$Name, [string]$Version, [string]$Publisher, [string]$SignatureKind)
    [pscustomobject]@{
        Name = $Name
        Version = [version]$Version
        Publisher = $Publisher
        SignatureKind = $SignatureKind
        PackageFullName = "$Name`_$Version`_neutral__test"
        PackageFamilyName = "$Name`_test"
        InstallLocation = 'C:\Program Files\WindowsApps\fake'
    }
}
function Get-AppxPackage {
    [CmdletBinding()]
    param([string]$Name, [switch]$AllUsers)
    $mode = $env:MOCK_APPX_MODE
    if ($mode -eq 'none') { return }
    $version = '0.23.2'
    if ($env:MOCK_APPX_UPDATED -eq '1') { $version = '0.23.3' }
    $store = Get-MockHermesPackage -Name 'NousResearchInc.HermesAgent' -Version $version -Publisher 'CN=EE6D86E4-606F-4E38-B940-AD7248C9D519' -SignatureKind 'Store'
    $sideload = Get-MockHermesPackage -Name 'NousResearch.HermesBundled' -Version $version -Publisher 'CN=Nous Research Inc., O=Nous Research Inc., L=Austin, S=Texas, C=US' -SignatureKind 'Developer'
    $unknown = Get-MockHermesPackage -Name 'Contoso.HermesClone' -Version $version -Publisher 'CN=Contoso' -SignatureKind 'Developer'
    switch ($mode) {
        'store' { $packages = @($store) }
        'sideload' { $packages = @($sideload) }
        'unknown' { $packages = @($unknown) }
        'dual' { $packages = @($store, $sideload) }
        'store_bad_sig' { $store.SignatureKind = 'Developer'; $packages = @($store) }
        'sideload_bad_pub' { $sideload.Publisher = 'CN=Evil Corp'; $packages = @($sideload) }
        'sideload_bad_sig' { $sideload.SignatureKind = 'Store'; $packages = @($sideload) }
        default { $packages = @() }
    }
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        return @($packages | Where-Object { $_.Name -eq $Name })
    }
    return $packages
}
function Add-AppxPackage {
    [CmdletBinding()]
    param([string]$AppInstallerFile)
    Add-Content -LiteralPath $env:MOCK_CALL_LOG -Value "Add-AppxPackage $AppInstallerFile"
    if ($env:MOCK_APPX_FAIL -eq '1') { throw '0x80072EE7: The server name or address could not be resolved' }
    $env:MOCK_APPX_UPDATED = '1'
}
'@
}

function Invoke-Sandbox {
    param(
        $Sandbox,
        [string[]]$Arguments,
        [string]$AppxMode = 'none',
        [string]$WingetNoUpgrade = '0',
        [string]$GitRemote = 'https://github.com/NousResearch/hermes-agent.git',
        [string]$GitBranch = 'main',
        [string]$GitStatus = '',
        [string]$GitStatusExit = '0',
        [string]$GitInside = 'true',
        [string]$InstallDir = '',
        [string]$SourceChannel = 'stable',
        [string]$SourceMethod = 'git',
        [string]$UpdateChannel = 'stable',
        [string]$AppxFail = '0'
    )
    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $InstallDir = Join-Path $Sandbox.LocalAppData 'hermes\hermes-agent'
    }
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
    $oldGitRemote = $env:MOCK_GIT_REMOTE
    $oldGitBranch = $env:MOCK_GIT_BRANCH
    $oldGitStatus = $env:MOCK_GIT_STATUS
    $oldGitStatusExit = $env:MOCK_GIT_STATUS_EXIT
    $oldGitInside = $env:MOCK_GIT_INSIDE
    $oldInstallDir = $env:MOCK_INSTALL_DIR
    $oldSourceChannel = $env:MOCK_SOURCE_CHANNEL
    $oldSourceMethod = $env:MOCK_SOURCE_METHOD
    $oldUpdateChannel = $env:MOCK_UPDATE_CHANNEL
    $oldAppxFail = $env:MOCK_APPX_FAIL
    $oldAppxUpdated = $env:MOCK_APPX_UPDATED
    try {
        $env:PATH = "$($Sandbox.LocalAppData)\hermes\bin;$($Sandbox.Bin);$env:SystemRoot\System32;$env:SystemRoot"
        $env:USERPROFILE = $Sandbox.Home
        $env:LOCALAPPDATA = $Sandbox.LocalAppData
        $env:HERMES_HOME = (Join-Path $Sandbox.Home '.hermes')
        $env:HERMES_DESKTOP_REMOTE_URL = ''
        $env:HERMES_APPINSTALLER_FILE = ''
        $env:MOCK_APPX_MODE = $AppxMode
        $env:MOCK_WINGET_NO_UPGRADE = $WingetNoUpgrade
        $env:MOCK_CALL_LOG = $Sandbox.CallLog
        $env:MOCK_SCRIPT_PATH = $Sandbox.Script
        $env:MOCK_GIT_REMOTE = $GitRemote
        $env:MOCK_GIT_BRANCH = $GitBranch
        $env:MOCK_GIT_STATUS = $GitStatus
        $env:MOCK_GIT_STATUS_EXIT = $GitStatusExit
        $env:MOCK_GIT_INSIDE = $GitInside
        $env:MOCK_INSTALL_DIR = $InstallDir
        $env:MOCK_SOURCE_CHANNEL = $SourceChannel
        $env:MOCK_SOURCE_METHOD = $SourceMethod
        $env:MOCK_UPDATE_CHANNEL = $UpdateChannel
        $env:MOCK_APPX_FAIL = $AppxFail
        $env:MOCK_APPX_UPDATED = ''
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
        $env:MOCK_GIT_REMOTE = $oldGitRemote
        $env:MOCK_GIT_BRANCH = $oldGitBranch
        $env:MOCK_GIT_STATUS = $oldGitStatus
        $env:MOCK_GIT_STATUS_EXIT = $oldGitStatusExit
        $env:MOCK_GIT_INSIDE = $oldGitInside
        $env:MOCK_INSTALL_DIR = $oldInstallDir
        $env:MOCK_SOURCE_CHANNEL = $oldSourceChannel
        $env:MOCK_SOURCE_METHOD = $oldSourceMethod
        $env:MOCK_UPDATE_CHANNEL = $oldUpdateChannel
        $env:MOCK_APPX_FAIL = $oldAppxFail
        $env:MOCK_APPX_UPDATED = $oldAppxUpdated
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

function New-AppInstallerDescriptor {
    param(
        $Sandbox,
        [string]$Name = 'NousResearch.HermesBundled',
        [string]$Version = '0.23.3',
        [string]$Publisher = 'CN=Nous Research Inc., O=Nous Research Inc., L=Austin, S=Texas, C=US',
        [string]$Uri = 'https://example.invalid/HermesBundled-0.23.3.msixbundle',
        [string]$FileName = 'valid.appinstaller'
    )
    $path = Join-Path $Sandbox.Dir $FileName
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller xmlns="http://schemas.microsoft.com/appx/appinstaller/2017/2" Version="1.0.0.0">
  <MainPackage Name="$Name" Version="$Version" Publisher="$Publisher" Uri="$Uri" />
</AppInstaller>
"@
    Set-Content -LiteralPath $path -Value $xml -Encoding UTF8
    return $path
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

    # 7. Sideload owner without a descriptor: UNKNOWN availability, not BLOCKED.
    $s = New-Sandbox 'sideload'
    $r = Invoke-Sandbox $s @('check') -AppxMode 'sideload'
    Assert-Equal 'sideload check exit' '1' "$($r.ExitCode)"
    Assert-Contains 'sideload owner recognized' 'OWNER: Sideload MSIX' $r.Output
    Assert-Contains 'sideload availability unknown' 'STATUS: UNKNOWN' $r.Output
    Assert-Contains 'sideload descriptor not supplied' 'not supplied' $r.Report

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

    # 11. Store detection keeps the exact product ID and official identity.
    $s = New-Sandbox 'store_identity'
    $r = Invoke-Sandbox $s @('check') -AppxMode 'store'
    Assert-Contains 'store identity recorded' 'NousResearchInc.HermesAgent' $r.Report
    Assert-Contains 'store product ID preserved' '9PMXK8CZC7KR' $r.Calls

    # 12. Unrecognized Hermes package identity is blocked.
    $s = New-Sandbox 'unknown_identity'
    $r = Invoke-Sandbox $s @('check') -AppxMode 'unknown'
    Assert-Equal 'unknown identity exit' '2' "$($r.ExitCode)"
    Assert-Contains 'unknown identity reason' 'Unrecognized Hermes package identity' $r.Report

    # 13. Two known official MSIX variants are ambiguous.
    $s = New-Sandbox 'dual_identity'
    $r = Invoke-Sandbox $s @('check') -AppxMode 'dual'
    Assert-Equal 'dual identity exit' '2' "$($r.ExitCode)"
    Assert-Contains 'dual identity reason' 'Multiple or ambiguous Hermes MSIX packages' $r.Report

    # 14. Identity/signature mismatches are blocked, not guessed.
    $s = New-Sandbox 'store_bad_sig'
    $r = Invoke-Sandbox $s @('check') -AppxMode 'store_bad_sig'
    Assert-Equal 'store bad signature exit' '2' "$($r.ExitCode)"
    Assert-Contains 'store bad signature reason' 'not Store-signed' $r.Report

    $s = New-Sandbox 'sideload_bad_pub'
    $r = Invoke-Sandbox $s @('check') -AppxMode 'sideload_bad_pub'
    Assert-Equal 'sideload bad publisher exit' '2' "$($r.ExitCode)"
    Assert-Contains 'sideload bad publisher reason' 'not the official Nous Research' $r.Report

    $s = New-Sandbox 'sideload_bad_sig'
    $r = Invoke-Sandbox $s @('check') -AppxMode 'sideload_bad_sig'
    Assert-Equal 'sideload bad signature exit' '2' "$($r.ExitCode)"
    Assert-Contains 'sideload bad signature reason' 'not a signed sideload' $r.Report

    # 15. Valid sideload descriptor authorizes availability.
    $s = New-Sandbox 'sideload_valid'
    $descriptor = New-AppInstallerDescriptor $s
    $r = Invoke-Sandbox $s @('check', '-AppInstallerFile', $descriptor) -AppxMode 'sideload'
    Assert-Equal 'sideload valid exit' '1' "$($r.ExitCode)"
    Assert-Contains 'sideload valid not blocked' 'STATUS: UNKNOWN' $r.Output
    Assert-Contains 'sideload valid row' 'verified official descriptor' $r.Report
    Assert-NotContains 'sideload valid no rejection' 'descriptor rejected' $r.Output

    # 16. Descriptor validation failures are blocked.
    $s = New-Sandbox 'sideload_malformed'
    $bad = New-AppInstallerDescriptor $s -FileName 'bad.appinstaller'
    Set-Content -LiteralPath $bad -Value '<not-an-appinstaller>' -Encoding UTF8
    $r = Invoke-Sandbox $s @('check', '-AppInstallerFile', $bad) -AppxMode 'sideload'
    Assert-Equal 'sideload malformed exit' '2' "$($r.ExitCode)"
    Assert-Contains 'sideload malformed reason' 'Sideload descriptor rejected' $r.Report

    $s = New-Sandbox 'sideload_identity_mismatch'
    $bad = New-AppInstallerDescriptor $s -Name 'Contoso.HermesClone'
    $r = Invoke-Sandbox $s @('check', '-AppInstallerFile', $bad) -AppxMode 'sideload'
    Assert-Equal 'sideload identity mismatch exit' '2' "$($r.ExitCode)"
    Assert-Contains 'sideload identity mismatch reason' 'does not match installed package' $r.Report

    $s = New-Sandbox 'sideload_downgrade'
    $bad = New-AppInstallerDescriptor $s -Version '0.23.1'
    $r = Invoke-Sandbox $s @('check', '-AppInstallerFile', $bad) -AppxMode 'sideload'
    Assert-Equal 'sideload downgrade exit' '2' "$($r.ExitCode)"
    Assert-Contains 'sideload downgrade reason' 'would downgrade' $r.Report

    $s = New-Sandbox 'sideload_http_uri'
    $bad = New-AppInstallerDescriptor $s -Uri 'http://example.invalid/HermesBundled-0.23.3.msixbundle'
    $r = Invoke-Sandbox $s @('check', '-AppInstallerFile', $bad) -AppxMode 'sideload'
    Assert-Equal 'sideload http URI exit' '2' "$($r.ExitCode)"
    Assert-Contains 'sideload http URI reason' 'not HTTPS' $r.Report

    # 17. Sideload update requires a validated descriptor, then uses Add-AppxPackage.
    $s = New-Sandbox 'sideload_update_missing'
    $r = Invoke-Sandbox $s @('update') -AppxMode 'sideload'
    Assert-Equal 'sideload update missing exit' '2' "$($r.ExitCode)"
    Assert-NotContains 'sideload update missing no install' 'Add-AppxPackage' $r.Calls

    $s = New-Sandbox 'sideload_update_valid'
    $descriptor = New-AppInstallerDescriptor $s
    $r = Invoke-Sandbox $s @('update', '-AppInstallerFile', $descriptor) -AppxMode 'sideload'
    Assert-Equal 'sideload update valid exit' '1' "$($r.ExitCode)"
    Assert-Contains 'sideload update used Add-AppxPackage' 'Add-AppxPackage' $r.Calls
    Assert-Contains 'sideload update not blocked' 'STATUS: PARTIAL' $r.Output

    $s = New-Sandbox 'sideload_update_feed_fail'
    $descriptor = New-AppInstallerDescriptor $s
    $r = Invoke-Sandbox $s @('update', '-AppInstallerFile', $descriptor) -AppxMode 'sideload' -AppxFail '1'
    Assert-Equal 'sideload feed failure exit' '2' "$($r.ExitCode)"
    Assert-Contains 'sideload feed failure blocked' 'Official descriptor feed was unavailable' $r.Output

    # 18. Source provenance failures block before any source update.
    $s = New-Sandbox 'source_provenance_ok'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('check') -AppxMode 'none'
    Assert-Contains 'source provenance pass' 'source provenance' $r.Report
    Assert-NotContains 'source provenance not blocked' 'STATUS: BLOCKED' $r.Output

    $s = New-Sandbox 'source_cli_mismatch'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('update') -AppxMode 'none' -InstallDir 'C:\Other\hermes-agent'
    Assert-Equal 'source CLI mismatch exit' '2' "$($r.ExitCode)"
    Assert-Contains 'source CLI mismatch reason' 'does not belong to the discovered checkout' $r.Output
    Assert-NotContains 'source CLI mismatch no updater' '--set-channel' $r.Calls

    $s = New-Sandbox 'source_cli_outside_root'
    Add-SourceInstall $s
    Move-Item -LiteralPath (Join-Path $s.LocalAppData 'hermes\bin\hermes.cmd') -Destination (Join-Path $s.Bin 'hermes.cmd') -Force
    $r = Invoke-Sandbox $s @('update') -AppxMode 'none'
    Assert-Equal 'source CLI outside root exit' '2' "$($r.ExitCode)"
    Assert-Contains 'source CLI outside root reason' 'outside the verified source install root' $r.Output
    Assert-NotContains 'source CLI outside root no updater' '--set-channel' $r.Calls

    $s = New-Sandbox 'source_missing_git'
    Add-SourceInstall $s
    Remove-Item -LiteralPath (Join-Path $s.LocalAppData 'hermes\hermes-agent\.git') -Recurse -Force
    $r = Invoke-Sandbox $s @('update') -AppxMode 'none'
    Assert-Equal 'source missing git exit' '2' "$($r.ExitCode)"
    Assert-Contains 'source missing git reason' 'no .git metadata' $r.Output
    Assert-NotContains 'source missing git no updater' '--set-channel' $r.Calls

    $s = New-Sandbox 'source_missing_checkout'
    Add-SourceInstall $s
    Remove-Item -LiteralPath (Join-Path $s.LocalAppData 'hermes\hermes-agent') -Recurse -Force
    $r = Invoke-Sandbox $s @('update') -AppxMode 'none'
    Assert-Equal 'source missing checkout exit' '2' "$($r.ExitCode)"
    Assert-Contains 'source missing checkout reason' 'source checkout path is missing' $r.Output
    Assert-NotContains 'source missing checkout no updater' '--set-channel' $r.Calls

    $s = New-Sandbox 'source_remote_bad'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('update') -AppxMode 'none' -GitRemote 'https://github.com/Evil/hermes-agent.git'
    Assert-Equal 'source remote bad exit' '2' "$($r.ExitCode)"
    Assert-Contains 'source remote bad reason' 'not the official' $r.Output
    Assert-NotContains 'source remote bad no updater' '--set-channel' $r.Calls

    $s = New-Sandbox 'source_dirty'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('update') -AppxMode 'none' -GitStatus 'M README.md'
    Assert-Equal 'source dirty exit' '2' "$($r.ExitCode)"
    Assert-Contains 'source dirty reason' 'uncommitted changes' $r.Output

    $s = New-Sandbox 'source_git_fail'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('update') -AppxMode 'none' -GitStatusExit '128'
    Assert-Equal 'source git status failure exit' '2' "$($r.ExitCode)"
    Assert-Contains 'source git status failure reason' 'git status failed' $r.Output

    $s = New-Sandbox 'source_canary'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('update') -AppxMode 'none' -SourceChannel 'canary' -UpdateChannel 'canary'
    Assert-Equal 'source canary exit' '2' "$($r.ExitCode)"
    Assert-Contains 'source canary reason' 'not stable' $r.Output

    $s = New-Sandbox 'source_custom_branch'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('update') -AppxMode 'none' -GitBranch 'feature/x'
    Assert-Equal 'source custom branch exit' '2' "$($r.ExitCode)"
    Assert-Contains 'source custom branch reason' 'custom branch' $r.Output

    # 19. Git remote credentials never reach console or report.
    $s = New-Sandbox 'source_redaction'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('check') -AppxMode 'none' -GitRemote 'https://user:supersecret-git-credential@github.com/Evil/hermes-agent.git'
    Assert-NotContains 'source git credential not in report' 'supersecret-git-credential' $r.Report
    Assert-NotContains 'source git credential not in output' 'supersecret-git-credential' $r.Output
    Assert-Contains 'source git credential redacted' '[REDACTED]' $r.Report
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
