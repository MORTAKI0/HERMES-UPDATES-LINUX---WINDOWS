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
$WindowsPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
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

function Assert-MatchCount([string]$Name, [string]$Pattern, [int]$Expected, [string]$Text) {
    $actual = [regex]::Matches($Text, $Pattern).Count
    if ($Expected -eq $actual) { Add-Pass $Name } else { Add-Fail $Name "expected $Expected matches, got $actual" }
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
    $userHome = Join-Path $dir 'home'
    $localAppData = Join-Path $dir 'localappdata'
    $state = Join-Path $dir 'state'
    $receipts = Join-Path $userHome '.hermes\logs\update_receipts'
    New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    New-Item -ItemType Directory -Path $receipts -Force | Out-Null
    New-Item -ItemType Directory -Path $state -Force | Out-Null
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
        Home = $userHome
        LocalAppData = $localAppData
        Receipts = $receipts
        State = $state
        CallLog = $callLog
    }
}

function Add-SourceInstall {
    param($Sandbox)
    $checkout = Join-Path $Sandbox.LocalAppData 'hermes\hermes-agent'
    New-Item -ItemType Directory -Path (Join-Path $checkout '.git') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Sandbox.LocalAppData 'hermes\bin') -Force | Out-Null
    $oldSha = '1111111111111111111111111111111111111111'
    $targetSha = '2222222222222222222222222222222222222222'
    Set-Content -LiteralPath (Join-Path $Sandbox.State 'version.txt') -Value '0.23.2' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Sandbox.State 'http_version.txt') -Value '0.23.2' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Sandbox.State 'http_overall.txt') -Value 'ok' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Sandbox.State 'head.txt') -Value $oldSha -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Sandbox.State 'target_version.txt') -Value '0.23.3' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Sandbox.State 'target_short.txt') -Value $targetSha.Substring(0, 12) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Sandbox.State 'target_full.txt') -Value $targetSha -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Sandbox.State 'install_id.txt') -Value 'test-install-id-0001' -Encoding ASCII
    $unpackedDir = Join-Path $checkout 'apps\desktop\release\win-unpacked'
    $stampDir = Join-Path $unpackedDir 'resources'
    New-Item -ItemType Directory -Path $stampDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $unpackedDir 'Hermes.exe') -Value 'fake' -Encoding ASCII
    @{ commit = $oldSha; baseVersion = '0.23.2'; displayVersion = '0.23.2'; source = 'git' } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $stampDir 'install-stamp.json') -Encoding UTF8

    $hermesCmd = @'
@echo off
echo hermes %*>>"%MOCK_CALL_LOG%"
"%MOCK_WINDOWS_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%MOCK_HERMES_MOCK%" %*
exit /b %ERRORLEVEL%
'@
    Set-Content -LiteralPath (Join-Path $Sandbox.LocalAppData 'hermes\bin\hermes.cmd') -Value $hermesCmd -Encoding ASCII
    $mock = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$state = $env:MOCK_SOURCE_STATE
$dotChar = [char]0x00B7
$arrowChar = [char]0x2192
function Read-State([string]$Name, [string]$Default = '') {
    $path = Join-Path $state $Name
    if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw).Trim() }
    return $Default
}
function Write-State([string]$Name, [string]$Value) {
    Set-Content -LiteralPath (Join-Path $state $Name) -Value $Value -Encoding ASCII
}
function Set-DesktopStamp([string]$Version, [string]$Sha) {
    $unpacked = Join-Path $state 'desktop\win-unpacked'
    $dir = Join-Path $unpacked 'resources'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $unpacked 'Hermes.exe') -Value 'fake' -Encoding ASCII
    @{ commit = $Sha; baseVersion = $Version; displayVersion = $Version; source = 'git' } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dir 'install-stamp.json') -Encoding UTF8
}
function Copy-DesktopStamp {
    $source = Join-Path $state 'desktop\win-unpacked'
    $checkout = Read-State 'checkout.txt' $env:MOCK_INSTALL_DIR
    $destination = Join-Path $checkout 'apps\desktop\release\win-unpacked'
    if (Test-Path -LiteralPath $source) {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
    }
}
$version = Read-State 'version.txt' '0.23.2'
$head = Read-State 'head.txt' '1111111111111111111111111111111111111111'
$targetVersion = Read-State 'target_version.txt' '0.23.3'
$targetShort = Read-State 'target_short.txt' '222222222222'
$targetFull = Read-State 'target_full.txt' '2222222222222222222222222222222222222222'
$installDir = $env:MOCK_INSTALL_DIR
if (Test-Path -LiteralPath (Join-Path $state 'install_dir_after.txt')) { $installDir = Read-State 'install_dir_after.txt' }
$channel = $env:MOCK_SOURCE_CHANNEL
if (Test-Path -LiteralPath (Join-Path $state 'channel_after.txt')) { $channel = Read-State 'channel_after.txt' }
$method = $env:MOCK_SOURCE_METHOD
if ($Args.Count -eq 0) { exit 9 }
if ($Args[0] -eq '--version') {
    $cid = if ($env:HERMES_UPDATE_CORRELATION_ID) { $env:HERMES_UPDATE_CORRELATION_ID } else { '<unset>' }
    Set-Content -LiteralPath (Join-Path $state 'observed_correlation.txt') -Value $cid -Encoding ASCII
    Write-Output ("Hermes Agent v$version (2026.9.24) $dotChar $channel $dotChar local $($head.Substring(0, 12))")
    Write-Output "Install directory: $installDir"
    Write-Output "Install method: $method"
    exit 0
}
if ($Args[0] -eq 'desktop') {
    if (($Args -contains '--build-only') -and ($Args -contains '--force-build')) {
        if ($env:MOCK_DESKTOP_REPAIR_FAIL -eq '1') { Write-Output 'simulated Desktop repair failure'; exit 1 }
        Set-DesktopStamp $targetVersion $targetFull
        Copy-DesktopStamp
        Write-Output 'Desktop build complete.'
        exit 0
    }
    exit 9
}
if ($Args[0] -ne 'update') { exit 9 }
if ($Args -contains '--install-id') { Write-Output (Read-State 'install_id.txt'); exit 0 }
if ($Args -contains '--check') {
    Write-Output "$arrowChar Update channel: $($env:MOCK_UPDATE_CHANNEL)"
    if (($env:MOCK_UPDATE_CURRENT -eq '1') -or (($version -eq $targetVersion) -and ($head -eq $targetFull))) {
        Write-Output "$arrowChar Already up to date: stable v$targetVersion"
    } else {
        Write-Output "$arrowChar Selected release available: stable v$targetVersion ($targetShort)"
    }
    exit 0
}
if ($Args -contains '--plan') {
    Write-Output 'Update plan:'
    Write-Output "  Install: git (v$version @ $($head.Substring(0, 12)))"
    Write-Output '  Profiles: default'
    exit 0
}
if (-not ($Args -contains '--yes')) { Write-Output 'channel-only operation does not update'; exit 0 }
Remove-Item -LiteralPath (Join-Path $state 'observed_correlation.txt') -ErrorAction SilentlyContinue
$mode = if ($env:MOCK_UPDATE_MODE) { $env:MOCK_UPDATE_MODE } else { 'success' }
$oldVersion = $version
$oldHead = $head
$correlation = if ($env:HERMES_UPDATE_CORRELATION_ID) { $env:HERMES_UPDATE_CORRELATION_ID } else { '' }
$updateId = [guid]::NewGuid().ToString('N')
$outcome = 'success'
$exitCode = 0
$followups = @()
$gatewayIncomplete = $false
$buildOutcome = 'success'
if ($mode -eq 'fail' -or $mode -eq 'fail_with_desktop_owed') {
    $outcome = 'failed'
    $exitCode = 1
    if ($mode -eq 'fail_with_desktop_owed') { Write-Output '⚠ Desktop app build owed: build failed' }
}
elseif ($mode -ne 'no_install') {
    $version = $targetVersion
    $head = $targetFull
    if ($mode -eq 'wrong_revision') { $head = '3333333333333333333333333333333333333333' }
    if ($mode -eq 'wrong_version') { $version = '0.23.2' }
    Write-State 'version.txt' $version
    Write-State 'head.txt' $head
    Write-State 'updated.txt' '1'
    Set-Content -LiteralPath (Join-Path $state 'http_version.txt') -Value $version -Encoding ASCII
    if ($mode -ne 'desktop_failed') { Set-DesktopStamp $version $head; Copy-DesktopStamp }
    if ($mode -eq 'target_drift') {
        Write-State 'target_version.txt' '0.23.4'
        Write-State 'target_short.txt' '444444444444'
        Write-State 'target_full.txt' '4444444444444444444444444444444444444444'
    }
    if ($mode -eq 'identity_change') { Write-State 'install_id.txt' 'changed-install-id' }
    if ($mode -eq 'checkout_change') { Write-State 'install_dir_after.txt' (Join-Path $env:MOCK_SOURCE_STATE 'other-checkout') }
    if ($mode -eq 'channel_change') { Write-State 'channel_after.txt' 'canary' }
    if ($mode -eq 'dirty_after') { Write-State 'dirty_after.txt' 'M tracked.txt' }
    if ($mode -eq 'desktop_failed') {
        $buildOutcome = 'failed'
        $followups = @(@{ step = 'build'; reason = 'Desktop app build failed' })
        Write-Output '⚠ Desktop app build owed: build failed'
    }
}
$receiptMode = $mode
if ($receiptMode -eq 'receipt_missing' -or $receiptMode -eq 'receipt_historical' -or $receiptMode -eq 'no_install') {
    Write-Output 'simulated update without a current receipt'
    exit $exitCode
}
$receiptCorrelation = $correlation
if ($receiptMode -eq 'receipt_mismatch') { $receiptCorrelation = 'wrong-correlation' }
if ($receiptMode -eq 'receipt_no_correlation') { $receiptCorrelation = '' }
if ($receiptMode -eq 'receipt_failed' -or $receiptMode -eq 'receipt_failed_unrelated_success') { $outcome = 'failed'; $exitCode = 1 }
if ($receiptMode -eq 'receipt_followup') { $followups = @(@{ step = 'gateway_restart'; reason = 'deferred backend restart' }) }
if ($receiptMode -eq 'receipt_gateway_incomplete') { $gatewayIncomplete = $true }
$started = (Get-Date).ToUniversalTime().ToString('o')
$finished = (Get-Date).ToUniversalTime().ToString('o')
$receipt = @{
    schema = 1
    started_at = $started
    finished_at = $finished
    argv = @('hermes', 'update', '--yes')
    pid = $PID
    exit_code = $exitCode
    outcome = $outcome
    pre_update = @{ sha = $oldHead; short_sha = $oldHead.Substring(0, 8); version = $oldVersion; source = 'git' }
    post_update = @{ sha = $head; short_sha = $head.Substring(0, 8); version = $version; source = 'git' }
    steps = @()
    followups = $followups
    gateway_restart = @{ incomplete = $gatewayIncomplete; failed_units = @() }
    stages = @(@{ name = 'build'; outcome = $buildOutcome })
    update_id = $updateId
    correlation_id = $receiptCorrelation
}
if ($receiptMode -eq 'receipt_incomplete') {
    $receipt.Remove('finished_at')
    $receipt.Remove('post_update')
}
$receiptDir = Join-Path $env:HERMES_HOME 'logs\update_receipts'
New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
if ($receiptMode -eq 'receipt_malformed') {
    Set-Content -LiteralPath (Join-Path $receiptDir 'update_malformed.json') -Value '{"schema":1,' -Encoding UTF8
} else {
    $path = Join-Path $receiptDir ("update_$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff'))_${PID}_$updateId.json")
    $receipt | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $path -Encoding UTF8
    if ($receiptMode -eq 'receipt_plugin') {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        @{ schema = 1; kind = 'plugin-check'; outcome = 'updates-available'; update_id = $null; correlation_id = $null } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $receiptDir 'latest.json') -Encoding UTF8
    } elseif ($receiptMode -eq 'receipt_unrelated_latest') {
        @{ schema = 1; outcome = 'failed'; followups = @(); gateway_restart = @{ incomplete = $false }; correlation_id = 'unrelated'; update_id = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'; finished_at = $finished } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $receiptDir 'latest.json') -Encoding UTF8
    } elseif ($receiptMode -eq 'receipt_failed_unrelated_success') {
        @{ schema = 1; outcome = 'success'; followups = @(); gateway_restart = @{ incomplete = $false }; correlation_id = 'unrelated-success'; update_id = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'; finished_at = $finished } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $receiptDir 'latest.json') -Encoding UTF8
    } else {
        $receipt | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath (Join-Path $receiptDir 'latest.json') -Encoding UTF8
    }
}
Write-Output 'simulated source update'
exit $exitCode
'@
    Set-Content -LiteralPath (Join-Path $Sandbox.Bin 'hermes_mock.ps1') -Value $mock -Encoding UTF8
    Add-GitShim $Sandbox
}

function Add-GitShim {
    param($Sandbox)
    $gitCmd = @'
@echo off
echo git %*>>"%MOCK_CALL_LOG%"
"%MOCK_WINDOWS_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%MOCK_GIT_MOCK%" %*
exit /b %ERRORLEVEL%
'@
    Set-Content -LiteralPath (Join-Path $Sandbox.Bin 'git.cmd') -Value $gitCmd -Encoding ASCII
    $mock = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
$ErrorActionPreference = 'Continue'
$state = $env:MOCK_SOURCE_STATE
function Read-State([string]$Name, [string]$Default = '') {
    $path = Join-Path $state $Name
    if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw).Trim() }
    return $Default
}
if ($Args.Count -lt 3 -or $Args[0] -ne '-C') { exit 1 }
$command = $Args[2]
if ($command -eq 'remote') {
    $remote = $env:MOCK_GIT_REMOTE
    if ((Test-Path -LiteralPath (Join-Path $state 'updated.txt')) -and (Test-Path -LiteralPath (Join-Path $state 'remote_after.txt'))) {
        $remote = Read-State 'remote_after.txt'
    }
    Write-Output $remote
    exit 0
}
if ($command -eq 'ls-remote') {
    if ($env:MOCK_TARGET_UNRESOLVED -eq '1') { [Console]::Error.WriteLine('remote target unavailable'); exit 128 }
    $targetVersion = Read-State 'target_version.txt'
    $full = Read-State 'target_full.txt'
    Write-Output ($full + "`trefs/tags/v$targetVersion^{}")
    exit 0
}
if ($command -eq 'rev-parse') {
    $argument = $Args[3]
    if ($argument -eq '--is-inside-work-tree') { Write-Output $env:MOCK_GIT_INSIDE; exit 0 }
    if ($argument -eq 'HEAD') { Write-Output (Read-State 'head.txt'); exit 0 }
    if (($argument -eq '--verify') -and ($Args.Count -ge 5)) { $argument = $Args[4] }
    if (($argument -like '*^{commit}') -or ($argument -like '*{commit}')) {
        if (($env:MOCK_TARGET_UNRESOLVED -eq '1') -or ($env:MOCK_LOCAL_TARGET_MISSING -eq '1')) { [Console]::Error.WriteLine('Needed a single revision'); exit 128 }
        Write-Output (Read-State 'target_full.txt')
        exit 0
    }
    exit 1
}
if ($command -eq 'symbolic-ref') {
    if ($env:MOCK_GIT_BRANCH -eq 'DETACHED') { exit 1 }
    Write-Output $env:MOCK_GIT_BRANCH
    exit 0
}
if ($command -eq 'status') {
    if ($env:MOCK_GIT_STATUS_EXIT -ne '0') { [Console]::Error.WriteLine('fatal: unable to read repository'); exit [int]$env:MOCK_GIT_STATUS_EXIT }
    $status = $env:MOCK_GIT_STATUS
    if ((Test-Path -LiteralPath (Join-Path $state 'updated.txt')) -and (Test-Path -LiteralPath (Join-Path $state 'dirty_after.txt'))) { $status = Read-State 'dirty_after.txt' }
    if ($status) { Write-Output $status }
    exit 0
}
exit 1
'@
    Set-Content -LiteralPath (Join-Path $Sandbox.Bin 'git_mock.ps1') -Value $mock -Encoding UTF8
}

function Enable-UnicodeMock {
    param($Sandbox)
    $asciiPath = Join-Path $Sandbox.LocalAppData 'hermes\bin\hermes_ascii.cmd'
    Copy-Item -LiteralPath (Join-Path $Sandbox.LocalAppData 'hermes\bin\hermes.cmd') -Destination $asciiPath -Force
    $emitter = Join-Path $Sandbox.Bin 'unicode_output.ps1'
    @'
param([string]$Kind, [string]$Channel, [string]$InstallDir, [string]$Method)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
if ($Kind -eq 'version') {
    Write-Output ("Hermes Agent v0.23.2 (2026.9.24) · " + $Channel + " · local abc123")
    Write-Output "Install directory: $InstallDir"
    Write-Output "Install method: $Method"
} else {
    Write-Output "→ Update channel: $Channel"
    Write-Output "→ Selected release available: stable v0.23.3 (caafe5389ae5)"
}
'@ | Set-Content -LiteralPath $emitter -Encoding UTF8
    $launcher = @'
@echo off
echo hermes %*>>"%MOCK_CALL_LOG%"
if "%~1"=="--version" (
  "%MOCK_WINDOWS_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%MOCK_UNICODE_SCRIPT%" version "%MOCK_SOURCE_CHANNEL%" "%MOCK_INSTALL_DIR%" "%MOCK_SOURCE_METHOD%"
  exit /b %ERRORLEVEL%
)
if "%~1"=="update" if "%~2"=="--check" (
  "%MOCK_WINDOWS_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%MOCK_UNICODE_SCRIPT%" check "%MOCK_UPDATE_CHANNEL%" "%MOCK_INSTALL_DIR%" "%MOCK_SOURCE_METHOD%"
  exit /b %ERRORLEVEL%
)
call "%MOCK_HERMES_ASCII%" %*
exit /b %ERRORLEVEL%
'@
    Set-Content -LiteralPath (Join-Path $Sandbox.LocalAppData 'hermes\bin\hermes.cmd') -Value $launcher -Encoding ASCII
}

function Set-Receipt {
    param($Sandbox, [int]$Followups)
    $followupList = @()
    $gatewayIncomplete = $false
    if ($Followups -gt 0) {
        $followupList = @(@{ step = 'gateway_restart'; reason = 'deferred backend restart' })
        $gatewayIncomplete = $true
    }
    $receipt = @{
        schema = 1
        started_at = (Get-Date).ToUniversalTime().AddMinutes(-2).ToString('o')
        finished_at = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
        argv = @('hermes', 'update', '--yes')
        outcome = 'success'
        pre_update = @{ sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; version = '0.23.1'; source = 'git' }
        post_update = @{ sha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; version = '0.23.2'; source = 'git' }
        followups = $followupList
        gateway_restart = @{ incomplete = $gatewayIncomplete }
        stages = @(@{ name = 'build'; outcome = 'success' })
        update_id = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        correlation_id = 'historical-check-receipt'
    }
    $path = Join-Path $Sandbox.Receipts ('update_' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff') + '.json')
    $receipt | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-Preamble {
    return @'
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter)
    [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '22631' }
}
function Get-PSDrive {
    [CmdletBinding()]
    param([string]$Name)
    [pscustomobject]@{ Name = $Name; Free = 10GB; Used = 1GB }
}
function Get-Process {
    [CmdletBinding()]
    param([string]$Name)
    if ($env:MOCK_DESKTOP_LOCKED -eq '1') {
        [pscustomobject]@{ Id = 4242; ProcessName = 'Hermes'; Path = (Join-Path $env:MOCK_DESKTOP_RELEASE_DIR 'win-unpacked\Hermes.exe') }
    }
}
function Get-MockHermesPackage {
    param([string]$Name, [string]$Version, [string]$Publisher, [string]$SignatureKind)
    $versionValue = $Version
    try { $versionValue = [version]$Version } catch { $versionValue = $Version }
    [pscustomobject]@{
        Name = $Name
        Version = $versionValue
        Publisher = $Publisher
        SignatureKind = $SignatureKind
        PackageFullName = ($Name + '_' + $Version + '_neutral__test')
        PackageFamilyName = ($Name + '_test')
        InstallLocation = 'C:\Program Files\WindowsApps\fake'
    }
}
function Get-AppxPackage {
    [CmdletBinding()]
    param([string]$Name, [switch]$AllUsers)
    $mode = $env:MOCK_APPX_MODE
    if (($mode -eq 'none') -or (($env:MOCK_APPX_DISAPPEAR -eq '1') -and ($env:MOCK_APPX_UPDATED -eq '1'))) { return }
    $version = '0.23.2'
    if ($env:MOCK_APPX_UPDATED -eq '1') {
        $version = '0.23.3'
        if (-not [string]::IsNullOrWhiteSpace($env:MOCK_APPX_UPDATED_VERSION)) {
            $version = $env:MOCK_APPX_UPDATED_VERSION
        }
    }
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
    if (($mode -eq 'sideload') -and ($env:MOCK_APPX_OWNER_CHANGE -eq '1') -and ($env:MOCK_APPX_UPDATED -eq '1')) { $packages = @($store) }
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        return @($packages | Where-Object { $_.Name -eq $Name })
    }
    return $packages
}
function Add-AppxPackage {
    [CmdletBinding()]
    param([string]$AppInstallerFile)
    Add-Content -LiteralPath $env:MOCK_CALL_LOG -Value "Add-AppxPackage $AppInstallerFile"
    switch ($env:MOCK_APPX_FAIL_MODE) {
        'network' { throw '0x80072EE7: The server name or address could not be resolved' }
        'signature' { throw '0x800B0109: A certificate chain processed but terminated in a root certificate which is not trusted' }
        'lock' { throw '0x80073D02: The package could not be installed because resources it modifies are currently in use' }
        'generic' { throw 'Generic simulated package installation failure' }
    }
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
        [string]$UpdateCurrent = '0',
        [string]$BackendEnvironmentUrl = '',
        [string]$UpdateMode = 'success',
        [string]$TargetUnresolved = '0',
        [string]$LocalTargetMissing = '0',
        [string]$DesktopRepairFail = '0',
        [string]$DesktopLocked = '0',
        [string]$ExistingCorrelation = '',
        [string]$AppxFailMode = '',
        [string]$AppxDisappear = '0',
        [string]$AppxOwnerChange = '0',
        [string]$AppxUpdatedVersion = ''
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
    $runner = Join-Path $Sandbox.Dir 'invoke.ps1'
    $runnerBody = (Get-Preamble) + "`n& '$($Sandbox.Script)' $argText" + "`nexit `$LASTEXITCODE`n"
    Set-Content -LiteralPath $runner -Value $runnerBody -Encoding UTF8

    $oldPath = $env:PATH
    $oldHome = $env:USERPROFILE
    $oldLocal = $env:LOCALAPPDATA
    $oldHermesHome = $env:HERMES_HOME
    $oldAppx = $env:MOCK_APPX_MODE
    $oldWinget = $env:MOCK_WINGET_NO_UPGRADE
    $oldLog = $env:MOCK_CALL_LOG
    $oldScript = $env:MOCK_SCRIPT_PATH
    $oldWindowsPowerShell = $env:MOCK_WINDOWS_POWERSHELL
    $oldUnicodeScript = $env:MOCK_UNICODE_SCRIPT
    $oldHermesAscii = $env:MOCK_HERMES_ASCII
    $oldSourceState = $env:MOCK_SOURCE_STATE
    $oldHermesMock = $env:MOCK_HERMES_MOCK
    $oldGitMock = $env:MOCK_GIT_MOCK
    $oldUpdateMode = $env:MOCK_UPDATE_MODE
    $oldTargetUnresolved = $env:MOCK_TARGET_UNRESOLVED
    $oldLocalTargetMissing = $env:MOCK_LOCAL_TARGET_MISSING
    $oldDesktopRepairFail = $env:MOCK_DESKTOP_REPAIR_FAIL
    $oldDesktopLocked = $env:MOCK_DESKTOP_LOCKED
    $oldDesktopReleaseDir = $env:MOCK_DESKTOP_RELEASE_DIR
    $oldCorrelation = $env:HERMES_UPDATE_CORRELATION_ID
    $oldModuleCache = $env:PSModuleAnalysisCachePath
    $oldRemoteUrl = $env:HERMES_DESKTOP_REMOTE_URL
    $oldAppInstaller = $env:HERMES_APPINSTALLER_FILE
    $oldErrorActionPreference = $ErrorActionPreference
    $oldGitRemote = $env:MOCK_GIT_REMOTE
    $oldGitBranch = $env:MOCK_GIT_BRANCH
    $oldGitStatus = $env:MOCK_GIT_STATUS
    $oldGitStatusExit = $env:MOCK_GIT_STATUS_EXIT
    $oldGitInside = $env:MOCK_GIT_INSIDE
    $oldInstallDir = $env:MOCK_INSTALL_DIR
    $oldSourceChannel = $env:MOCK_SOURCE_CHANNEL
    $oldSourceMethod = $env:MOCK_SOURCE_METHOD
    $oldUpdateChannel = $env:MOCK_UPDATE_CHANNEL
    $oldUpdateCurrent = $env:MOCK_UPDATE_CURRENT
    $oldAppxFailMode = $env:MOCK_APPX_FAIL_MODE
    $oldAppxDisappear = $env:MOCK_APPX_DISAPPEAR
    $oldAppxOwnerChange = $env:MOCK_APPX_OWNER_CHANGE
    $oldAppxUpdatedVersion = $env:MOCK_APPX_UPDATED_VERSION
    $oldAppxUpdated = $env:MOCK_APPX_UPDATED
    try {
        $env:PATH = "$($Sandbox.LocalAppData)\hermes\bin;$($Sandbox.Bin);$env:SystemRoot\System32;$env:SystemRoot"
        $env:USERPROFILE = $Sandbox.Home
        $env:LOCALAPPDATA = $Sandbox.LocalAppData
        $env:HERMES_HOME = (Join-Path $Sandbox.Home '.hermes')
        $env:HERMES_DESKTOP_REMOTE_URL = $BackendEnvironmentUrl
        $env:HERMES_APPINSTALLER_FILE = ''
        $env:MOCK_APPX_MODE = $AppxMode
        $env:MOCK_WINGET_NO_UPGRADE = $WingetNoUpgrade
        $env:MOCK_CALL_LOG = $Sandbox.CallLog
        $env:MOCK_SCRIPT_PATH = $Sandbox.Script
        $env:MOCK_WINDOWS_POWERSHELL = $WindowsPowerShell
        $env:MOCK_UNICODE_SCRIPT = Join-Path $Sandbox.Bin 'unicode_output.ps1'
        $env:MOCK_HERMES_ASCII = Join-Path $Sandbox.LocalAppData 'hermes\bin\hermes_ascii.cmd'
        $env:MOCK_SOURCE_STATE = $Sandbox.State
        $env:MOCK_HERMES_MOCK = Join-Path $Sandbox.Bin 'hermes_mock.ps1'
        $env:MOCK_GIT_MOCK = Join-Path $Sandbox.Bin 'git_mock.ps1'
        $env:MOCK_UPDATE_MODE = $UpdateMode
        $env:MOCK_TARGET_UNRESOLVED = $TargetUnresolved
        $env:MOCK_LOCAL_TARGET_MISSING = $LocalTargetMissing
        $env:MOCK_DESKTOP_REPAIR_FAIL = $DesktopRepairFail
        $env:MOCK_DESKTOP_LOCKED = $DesktopLocked
        $env:MOCK_DESKTOP_RELEASE_DIR = Join-Path $InstallDir 'apps\desktop\release'
        $env:HERMES_UPDATE_CORRELATION_ID = $ExistingCorrelation
        $env:PSModuleAnalysisCachePath = Join-Path $Base 'ModuleAnalysisCache'
        $env:MOCK_GIT_REMOTE = $GitRemote
        $env:MOCK_GIT_BRANCH = $GitBranch
        $env:MOCK_GIT_STATUS = $GitStatus
        $env:MOCK_GIT_STATUS_EXIT = $GitStatusExit
        $env:MOCK_GIT_INSIDE = $GitInside
        $env:MOCK_INSTALL_DIR = $InstallDir
        $env:MOCK_SOURCE_CHANNEL = $SourceChannel
        $env:MOCK_SOURCE_METHOD = $SourceMethod
        $env:MOCK_UPDATE_CHANNEL = $UpdateChannel
        $env:MOCK_UPDATE_CURRENT = $UpdateCurrent
        $env:MOCK_APPX_FAIL_MODE = $AppxFailMode
        $env:MOCK_APPX_DISAPPEAR = $AppxDisappear
        $env:MOCK_APPX_OWNER_CHANGE = $AppxOwnerChange
        $env:MOCK_APPX_UPDATED_VERSION = $AppxUpdatedVersion
        $env:MOCK_APPX_UPDATED = ''
        $ErrorActionPreference = 'Continue'
        $output = & $WindowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
        $env:PATH = $oldPath
        $env:USERPROFILE = $oldHome
        $env:LOCALAPPDATA = $oldLocal
        $env:HERMES_HOME = $oldHermesHome
        $env:MOCK_APPX_MODE = $oldAppx
        $env:MOCK_WINGET_NO_UPGRADE = $oldWinget
        $env:MOCK_CALL_LOG = $oldLog
        $env:MOCK_SCRIPT_PATH = $oldScript
        $env:MOCK_WINDOWS_POWERSHELL = $oldWindowsPowerShell
        $env:MOCK_UNICODE_SCRIPT = $oldUnicodeScript
        $env:MOCK_HERMES_ASCII = $oldHermesAscii
        $env:MOCK_SOURCE_STATE = $oldSourceState
        $env:MOCK_HERMES_MOCK = $oldHermesMock
        $env:MOCK_GIT_MOCK = $oldGitMock
        $env:MOCK_UPDATE_MODE = $oldUpdateMode
        $env:MOCK_TARGET_UNRESOLVED = $oldTargetUnresolved
        $env:MOCK_LOCAL_TARGET_MISSING = $oldLocalTargetMissing
        $env:MOCK_DESKTOP_REPAIR_FAIL = $oldDesktopRepairFail
        $env:MOCK_DESKTOP_LOCKED = $oldDesktopLocked
        $env:MOCK_DESKTOP_RELEASE_DIR = $oldDesktopReleaseDir
        $env:HERMES_UPDATE_CORRELATION_ID = $oldCorrelation
        $env:PSModuleAnalysisCachePath = $oldModuleCache
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
        $env:MOCK_UPDATE_CURRENT = $oldUpdateCurrent
        $env:MOCK_APPX_FAIL_MODE = $oldAppxFailMode
        $env:MOCK_APPX_DISAPPEAR = $oldAppxDisappear
        $env:MOCK_APPX_OWNER_CHANGE = $oldAppxOwnerChange
        $env:MOCK_APPX_UPDATED_VERSION = $oldAppxUpdatedVersion
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
        [string]$FileName = 'valid.appinstaller',
        [ValidateSet('MainPackage', 'MainBundle', 'Both', 'None')]
        [string]$Kind = 'MainPackage'
    )
    $path = Join-Path $Sandbox.Dir $FileName
    $package = "  <MainPackage Name=`"$Name`" Version=`"$Version`" Publisher=`"$Publisher`" Uri=`"$Uri`" />"
    $bundle = "  <MainBundle Name=`"$Name`" Version=`"$Version`" Publisher=`"$Publisher`" Uri=`"$Uri`" />"
    $body = ''
    if (($Kind -eq 'MainPackage') -or ($Kind -eq 'Both')) { $body += $package + "`n" }
    if (($Kind -eq 'MainBundle') -or ($Kind -eq 'Both')) { $body += $bundle + "`n" }
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller xmlns="http://schemas.microsoft.com/appx/appinstaller/2017/2" Version="1.0.0.0">
$body</AppInstaller>
"@
    Set-Content -LiteralPath $path -Value $xml -Encoding UTF8
    return $path
}

function Start-MockBackend {
    param($Sandbox)
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()
    $ready = Join-Path $Sandbox.State 'backend-ready.txt'
    $stop = Join-Path $Sandbox.State 'backend-stop.txt'
    Remove-Item -LiteralPath $stop -Force -ErrorAction SilentlyContinue
    $versionFile = Join-Path $Sandbox.State 'http_version.txt'
    $overallFile = Join-Path $Sandbox.State 'http_overall.txt'
    $job = Start-Job -ScriptBlock {
        param([int]$Port, [string]$Ready, [string]$VersionFile, [string]$OverallFile, [string]$StopFile)
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        Set-Content -LiteralPath $Ready -Value 'ready' -Encoding ASCII
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $StopFile) -and $listener.Pending() -eq $false) {
            Start-Sleep -Milliseconds 25
        }
        while (-not (Test-Path -LiteralPath $StopFile) -and (Get-Date) -lt $deadline) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 25; continue }
            $client = $null
            try {
                $client = $listener.AcceptTcpClient()
                $stream = $client.GetStream()
                $stream.ReadTimeout = 2000
                $buffer = New-Object byte[] 4096
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -eq 0) { $client.Close(); continue }
                $version = (Get-Content -LiteralPath $VersionFile -Raw).Trim()
                $overall = (Get-Content -LiteralPath $OverallFile -Raw).Trim()
                $body = '{"version":"' + $version + '","auth_required":true,"auth_providers":["basic"],"gateway_running":true,"overall":"' + $overall + '","profiles":["default"]}'
                $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
                $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                $client.Close()
            } catch {
                try { if ($null -ne $client) { $client.Close() } } catch { }
            }
        }
        $listener.Stop()
    } -ArgumentList $port, $ready, $versionFile, $overallFile, $stop
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $ready); $i++) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path -LiteralPath $ready)) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw 'Mock backend did not start.'
    }
    return [pscustomobject]@{ Url = "http://127.0.0.1:$port"; Job = $job; StopFile = $stop }
}

function Stop-MockBackend {
    param($Backend)
    if ($null -ne $Backend) {
        Set-Content -LiteralPath $Backend.StopFile -Value 'stop' -Encoding ASCII
        Wait-Job -Job $Backend.Job -Timeout 3 -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $Backend.Job -Force -ErrorAction SilentlyContinue
    }
}

function New-HistoricalReceipt {
    param($Sandbox, [string]$Correlation = 'historical-correlation', [string]$BuildOutcome = 'failed')
    $receipt = @{
        schema = 1
        started_at = (Get-Date).ToUniversalTime().AddDays(-1).ToString('o')
        finished_at = (Get-Date).ToUniversalTime().AddDays(-1).AddMinutes(1).ToString('o')
        argv = @('hermes', 'update', '--yes')
        outcome = 'success'
        pre_update = @{ sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; version = '0.23.1'; source = 'git' }
        post_update = @{ sha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; version = '0.23.2'; source = 'git' }
        followups = @(@{ step = 'build'; reason = 'historical Desktop build failure' })
        gateway_restart = @{ incomplete = $false }
        stages = @(@{ name = 'build'; outcome = $BuildOutcome })
        update_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        correlation_id = $Correlation
    }
    $path = Join-Path $Sandbox.Receipts 'update_historical.json'
    $receipt | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $path -Encoding UTF8
    $receipt | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath (Join-Path $Sandbox.Receipts 'latest.json') -Encoding UTF8
}

function Get-CurrentReceipt {
    param($Sandbox)
    $path = Get-ChildItem -LiteralPath $Sandbox.Receipts -Filter 'update_*.json' -File |
        Where-Object { $_.Name -ne 'update_historical.json' -and $_.Name -ne 'update_malformed.json' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $path) { return $null }
    try { return Get-Content -LiteralPath $path.FullName -Raw | ConvertFrom-Json } catch { return $null }
}

function Invoke-SourceUpdateScenario {
    param(
        $Sandbox,
        [string]$Mode = 'success',
        [string]$TargetUnresolved = '0',
        [string]$LocalTargetMissing = '0',
        [string]$ExistingCorrelation = '',
        [string]$DesktopRepairFail = '0',
        [switch]$NoBackup,
        [switch]$DesktopLocked
    )
    $backend = Start-MockBackend $Sandbox
    try {
        $arguments = @('update', '-BackendUrl', $backend.Url)
        if ($NoBackup) { $arguments += '-NoBackup' }
        return Invoke-Sandbox $Sandbox $arguments -AppxMode 'none' -UpdateMode $Mode -TargetUnresolved $TargetUnresolved -LocalTargetMissing $LocalTargetMissing -ExistingCorrelation $ExistingCorrelation -DesktopRepairFail $DesktopRepairFail -DesktopLocked $(if ($DesktopLocked) { '1' } else { '0' })
    } finally {
        Stop-MockBackend $backend
    }
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

    # 2c. Native UTF-8 output and UTF-8 report bytes preserve Unicode.
    $s = New-Sandbox 'source_unicode'
    Add-SourceInstall $s
    Enable-UnicodeMock $s
    $r = Invoke-Sandbox $s @('check', '-BackendUrl', 'http://127.0.0.1:1') -AppxMode 'none'
    Assert-Contains 'native arrow decoded' '→ Update channel: stable' $r.Report
    Assert-Contains 'native bullets decoded' '· stable · local' $r.Report
    Assert-NotContains 'native arrow is not mojibake' 'ΓåÆ' $r.Report
    Assert-NotContains 'native bullet is not mojibake' '┬╖' $r.Report
    $reportUtf8 = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($r.ReportPath))
    Assert-Contains 'report UTF-8 bytes preserve arrow' '→ Update channel: stable' $reportUtf8
    Assert-Contains 'report UTF-8 bytes preserve bullet' '· stable · local' $reportUtf8
    Assert-Contains 'Unicode version still parses' 'INSTALLED: v0.23.2' $r.Output
    Assert-Contains 'Unicode channel still parses' 'channel=stable' $r.Report

    # 2b. Backend URL precedence and source reporting.
    $s = New-Sandbox 'backend_explicit'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('check', '-BackendUrl', 'http://127.0.0.1:1') -AppxMode 'none' -BackendEnvironmentUrl 'http://127.0.0.1:2'
    Assert-Contains 'explicit backend URL source reported' 'explicit -BackendUrl' $r.Report
    Assert-Contains 'explicit backend URL reaches TCP check' '127.0.0.1:1' $r.Report
    Assert-NotContains 'environment backend does not override explicit URL' '127.0.0.1:2' $r.Report

    $s = New-Sandbox 'backend_environment'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('check') -AppxMode 'none' -BackendEnvironmentUrl 'http://127.0.0.1:1'
    Assert-Contains 'environment backend URL source reported' 'pre-existing HERMES_DESKTOP_REMOTE_URL' $r.Report
    Assert-Contains 'environment backend URL reaches TCP check' '127.0.0.1:1' $r.Report

    $s = New-Sandbox 'backend_invalid_explicit'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('check', '-BackendUrl', 'not-a-url') -AppxMode 'none' -BackendEnvironmentUrl 'http://127.0.0.1:1'
    Assert-Equal 'invalid explicit backend URL blocks' '2' "$($r.ExitCode)"
    Assert-Contains 'invalid explicit backend URL is rejected' 'not an absolute URI' $r.Output
    Assert-NotContains 'invalid explicit URL does not use environment fallback' 'pre-existing HERMES_DESKTOP_REMOTE_URL' $r.Report

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
    $r = Invoke-Sandbox $s @('check', '-BackendUrl', 'http://user:topsecret@127.0.0.1:9119') -AppxMode 'none' -BackendEnvironmentUrl 'http://127.0.0.1:1'
    Assert-Equal 'credential URL exit' '2' "$($r.ExitCode)"
    Assert-Contains 'credential URL source remains explicit' 'explicit -BackendUrl' $r.Report
    Assert-NotContains 'credential URL not in report' 'topsecret' $r.Report
    Assert-NotContains 'credential URL not in stdout' 'topsecret' $r.Output

    # 10. Update with ambiguous owner: BLOCKED, no updater invocation.
    $s = New-Sandbox 'update_ambiguous'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('update') -AppxMode 'store'
    Assert-Equal 'ambiguous update exit' '2' "$($r.ExitCode)"
    Assert-NotContains 'ambiguous update did not run source updater' '--set-channel' $r.Calls
    Assert-NotContains 'ambiguous update did not run native updater' 'hermes update --yes' $r.Calls
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

    # 15b. MainBundle descriptors are valid; ambiguous/unsupported descriptors block.
    $s = New-Sandbox 'sideload_mainbundle'
    $descriptor = New-AppInstallerDescriptor $s -Kind MainBundle
    $r = Invoke-Sandbox $s @('check', '-AppInstallerFile', $descriptor) -AppxMode 'sideload'
    Assert-Equal 'sideload mainbundle exit' '1' "$($r.ExitCode)"
    Assert-Contains 'sideload mainbundle accepted' 'kind=MainBundle' $r.Report
    Assert-NotContains 'sideload mainbundle no rejection' 'descriptor rejected' $r.Output

    $s = New-Sandbox 'sideload_both_kinds'
    $descriptor = New-AppInstallerDescriptor $s -Kind Both
    $r = Invoke-Sandbox $s @('check', '-AppInstallerFile', $descriptor) -AppxMode 'sideload'
    Assert-Equal 'sideload both kinds exit' '2' "$($r.ExitCode)"
    Assert-Contains 'sideload both kinds reason' 'both MainPackage and MainBundle' $r.Report

    $s = New-Sandbox 'sideload_no_kind'
    $descriptor = New-AppInstallerDescriptor $s -Kind None
    $r = Invoke-Sandbox $s @('check', '-AppInstallerFile', $descriptor) -AppxMode 'sideload'
    Assert-Equal 'sideload no kind exit' '2' "$($r.ExitCode)"
    Assert-Contains 'sideload no kind reason' 'no supported MainPackage or MainBundle' $r.Report

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
    Assert-Contains 'sideload update package verification passed' 'Post-update package verification' $r.Report
    Assert-Contains 'sideload update verified version' 'version=0.23.3' $r.Report

    $s = New-Sandbox 'sideload_update_generic_fail'
    $descriptor = New-AppInstallerDescriptor $s
    $r = Invoke-Sandbox $s @('update', '-AppInstallerFile', $descriptor) -AppxMode 'sideload' -AppxFailMode 'generic'
    Assert-Equal 'sideload generic failure exit' '1' "$($r.ExitCode)"
    Assert-Contains 'sideload generic failure status' 'STATUS: FAILED' $r.Output
    Assert-NotContains 'sideload generic failure not current' 'ALREADY_CURRENT' $r.Output
    Assert-NotContains 'sideload generic failure not updated' 'STATUS: UPDATED' $r.Output

    $s = New-Sandbox 'sideload_update_disappear'
    $descriptor = New-AppInstallerDescriptor $s
    $r = Invoke-Sandbox $s @('update', '-AppInstallerFile', $descriptor) -AppxMode 'sideload' -AppxDisappear '1'
    Assert-Equal 'sideload disappearance exit' '1' "$($r.ExitCode)"
    Assert-NotContains 'sideload disappearance not success' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'sideload disappearance reported' 'expected package version is missing' $r.Report

    $s = New-Sandbox 'sideload_update_owner_change'
    $descriptor = New-AppInstallerDescriptor $s
    $r = Invoke-Sandbox $s @('update', '-AppInstallerFile', $descriptor) -AppxMode 'sideload' -AppxOwnerChange '1'
    Assert-Equal 'sideload owner change exit' '1' "$($r.ExitCode)"
    Assert-NotContains 'sideload owner change not success' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'sideload owner change reported' 'package ownership changed' $r.Report

    $s = New-Sandbox 'sideload_update_downgrade'
    $descriptor = New-AppInstallerDescriptor $s
    $r = Invoke-Sandbox $s @('update', '-AppInstallerFile', $descriptor) -AppxMode 'sideload' -AppxUpdatedVersion '0.23.1'
    Assert-Equal 'sideload downgrade observed exit' '1' "$($r.ExitCode)"
    Assert-NotContains 'sideload downgrade observed not success' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'sideload downgrade observed reported' 'downgraded' $r.Report

    $s = New-Sandbox 'sideload_update_insufficient'
    $descriptor = New-AppInstallerDescriptor $s
    $r = Invoke-Sandbox $s @('update', '-AppInstallerFile', $descriptor) -AppxMode 'sideload' -AppxUpdatedVersion '0.23.2'
    Assert-Equal 'sideload insufficient exit' '1' "$($r.ExitCode)"
    Assert-NotContains 'sideload insufficient not success' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'sideload insufficient reported' 'below validated descriptor target' $r.Report

    $s = New-Sandbox 'sideload_update_invalid'
    $descriptor = New-AppInstallerDescriptor $s
    $r = Invoke-Sandbox $s @('update', '-AppInstallerFile', $descriptor) -AppxMode 'sideload' -AppxUpdatedVersion 'bad-version'
    Assert-Equal 'sideload invalid version exit' '1' "$($r.ExitCode)"
    Assert-NotContains 'sideload invalid version not success' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'sideload invalid version reported' 'not valid' $r.Report

    $s = New-Sandbox 'sideload_update_feed_fail'
    $descriptor = New-AppInstallerDescriptor $s
    $r = Invoke-Sandbox $s @('update', '-AppInstallerFile', $descriptor) -AppxMode 'sideload' -AppxFailMode 'network'
    Assert-Equal 'sideload feed failure exit' '2' "$($r.ExitCode)"
    Assert-Contains 'sideload feed failure blocked' 'Official descriptor feed was unavailable' $r.Output

    # 18. Source update command is the native updater, never a channel-only operation.
    $s = New-Sandbox 'source_update_command'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('update') -AppxMode 'none'
    Assert-NotContains 'source update never selects a channel' '--set-channel' $r.Calls
    Assert-MatchCount 'source update invokes native updater exactly once' '(?m)^hermes update --yes\r?$' 1 $r.Calls
    Assert-NotContains 'source update keeps default backup' '--no-backup' $r.Calls

    $s = New-Sandbox 'source_update_no_backup'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('update', '-NoBackup') -AppxMode 'none'
    Assert-MatchCount 'explicit no-backup reaches the one native updater' '(?m)^hermes update --yes --no-backup\r?$' 1 $r.Calls

    $s = New-Sandbox 'source_already_current'
    Add-SourceInstall $s
    $r = Invoke-Sandbox $s @('update') -AppxMode 'none' -UpdateCurrent '1'
    Assert-NotContains 'already-current source runs no updater' 'hermes update --yes' $r.Calls
    Assert-NotContains 'already-current source never selects a channel' '--set-channel' $r.Calls

    # 20. Exact source release, correlated receipt, and final-verdict regressions.
    $s = New-Sandbox 'source_update_exact'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s
    Assert-Equal 'exact source update exit' '0' "$($r.ExitCode)"
    Assert-Contains 'exact source update verdict' 'STATUS: UPDATED' $r.Output
    Assert-MatchCount 'exact source update runs one native updater' '(?m)^hermes update --yes\r?$' 1 $r.Calls
    Assert-Contains 'exact target version reported' 'v0.23.3' $r.Report
    Assert-Contains 'exact target full revision reported' '2222222222222222222222222222222222222222' $r.Report
    Assert-Contains 'Desktop build independently verified' 'Desktop build' $r.Report
    Assert-Contains 'Desktop build verified state' 'verified' $r.Report
    Assert-Contains 'backend health separately verified' 'Backend health' $r.Report
    Assert-Contains 'authentication only advertised' 'AUTH=ADVERTISED (session not tested)' $r.Output
    Assert-Contains 'WebSocket remains untested' 'WS=NOT_TESTED' $r.Output
    $receipt = Get-CurrentReceipt $s
    Assert-Contains 'current receipt has operation correlation' 'hermes-ops-win-' "$($receipt.correlation_id)"

    $s = New-Sandbox 'source_update_remote_target'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -LocalTargetMissing 1
    Assert-Equal 'remote tag resolves missing local target exit' '0' "$($r.ExitCode)"
    Assert-Contains 'remote tag resolves missing local target verdict' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'remote tag resolution uses full commit' '2222222222222222222222222222222222222222' $r.Report

    $s = New-Sandbox 'source_update_http_unhealthy'
    Add-SourceInstall $s
    Set-Content -LiteralPath (Join-Path $s.State 'http_overall.txt') -Value 'degraded' -Encoding ASCII
    $r = Invoke-SourceUpdateScenario $s
    Assert-NotContains 'HTTP 200 with unhealthy payload is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'HTTP reachability itself passed' 'HTTP=PASS' $r.Output
    Assert-Contains 'backend health failure is recorded' 'overall=degraded' $r.Report

    $s = New-Sandbox 'source_update_unchanged'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode no_install
    Assert-NotContains 'unchanged source is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'unchanged source is non-success' 'STATUS: PARTIAL' $r.Output
    Assert-MatchCount 'unchanged source still runs updater once' '(?m)^hermes update --yes\r?$' 1 $r.Calls
    Assert-NotContains 'unchanged source does not repair Desktop' 'hermes desktop --build-only --force-build' $r.Calls

    $s = New-Sandbox 'source_update_wrong_revision'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode wrong_revision
    Assert-NotContains 'advanced wrong revision is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'wrong revision is reported' '3333333333333333333333333333333333333333' $r.Report

    $s = New-Sandbox 'source_update_wrong_version'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode wrong_version
    Assert-NotContains 'correct revision wrong version is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'wrong reported version is reported' 'does not equal selected stable release' $r.Report

    $s = New-Sandbox 'source_update_unresolved_target'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -TargetUnresolved 1
    Assert-Equal 'unresolved target blocks before mutation' '2' "$($r.ExitCode)"
    Assert-Contains 'unresolved target verdict' 'STATUS: BLOCKED' $r.Output
    Assert-NotContains 'unresolved target runs no updater' 'hermes update --yes' $r.Calls

    $s = New-Sandbox 'source_update_target_drift'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode target_drift
    Assert-NotContains 'target drift is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'target drift is reported' 'target changed during execution' $r.Report

    $s = New-Sandbox 'source_update_identity_change'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode identity_change
    Assert-NotContains 'installation identity change is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'installation identity change is reported' 'installation identity changed' $r.Report

    $s = New-Sandbox 'source_update_checkout_change'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode checkout_change
    Assert-NotContains 'checkout change is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'checkout change is reported' 'checkout changed' $r.Report

    $s = New-Sandbox 'source_update_dirty_after'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode dirty_after
    Assert-NotContains 'post-update dirty checkout is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'post-update dirty checkout is reported' 'dirty after update' $r.Report

    $s = New-Sandbox 'source_update_unrelated_latest'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode receipt_unrelated_latest
    Assert-Equal 'correlated receipt survives unrelated latest exit' '0' "$($r.ExitCode)"
    Assert-Contains 'correlated receipt survives unrelated latest verdict' 'STATUS: UPDATED' $r.Output

    $s = New-Sandbox 'source_update_receipt_missing'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode receipt_missing
    Assert-NotContains 'missing current receipt is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'missing current receipt is reported' 'correlation' $r.Report

    $s = New-Sandbox 'source_update_receipt_no_correlation'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode receipt_no_correlation
    Assert-NotContains 'receipt without correlation is not UPDATED' 'STATUS: UPDATED' $r.Output

    $s = New-Sandbox 'source_update_receipt_mismatch'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode receipt_mismatch
    Assert-NotContains 'receipt correlation mismatch is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'receipt correlation mismatch is reported' 'correlation' $r.Report

    $s = New-Sandbox 'source_update_receipt_failed'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode receipt_failed_unrelated_success
    Assert-NotContains 'failed correlated receipt is not replaced by unrelated success' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'failed correlated receipt is reported' 'outcome=failed' $r.Report

    $s = New-Sandbox 'source_update_receipt_malformed'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode receipt_malformed
    Assert-NotContains 'malformed receipt is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'malformed receipt is reported' 'unreadable' $r.Report

    $s = New-Sandbox 'source_update_receipt_incomplete'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode receipt_incomplete
    Assert-NotContains 'incomplete receipt is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'incomplete receipt is reported' 'finished_at' $r.Report

    $s = New-Sandbox 'source_update_receipt_historical'
    Add-SourceInstall $s
    New-HistoricalReceipt $s
    $r = Invoke-SourceUpdateScenario $s -Mode receipt_historical
    Assert-NotContains 'historical receipt is not current update evidence' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'historical receipt is reported as uncorrelated' 'correlation' $r.Report
    Assert-NotContains 'historical receipt does not authorize Desktop repair' 'hermes desktop --build-only --force-build' $r.Calls

    $s = New-Sandbox 'source_update_receipt_plugin'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode receipt_plugin
    Assert-NotContains 'plugin-check artifact is not update evidence' 'STATUS: UPDATED' $r.Output

    $s = New-Sandbox 'source_update_receipt_followup'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode receipt_followup
    Assert-NotContains 'unresolved receipt follow-up is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'unresolved receipt follow-up is PARTIAL' 'STATUS: PARTIAL' $r.Output

    $s = New-Sandbox 'source_update_gateway_incomplete'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode receipt_gateway_incomplete
    Assert-NotContains 'incomplete gateway restart is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'incomplete gateway restart is PARTIAL' 'STATUS: PARTIAL' $r.Output

    $s = New-Sandbox 'source_update_correlation_scope'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -ExistingCorrelation 'pre-existing-correlation'
    Assert-Equal 'scoped correlation update exit' '0' "$($r.ExitCode)"
    $receipt = Get-CurrentReceipt $s
    Assert-NotContains 'operation correlation is unique' 'pre-existing-correlation' "$($receipt.correlation_id)"
    Assert-Equal 'prior correlation restored after updater' 'pre-existing-correlation' (Get-Content -LiteralPath (Join-Path $s.State 'observed_correlation.txt') -Raw).Trim()

    $s = New-Sandbox 'source_update_failed_no_repair'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode fail -ExistingCorrelation 'prior-on-failure'
    Assert-Contains 'failed native updater verdict' 'STATUS: FAILED' $r.Output
    Assert-NotContains 'failed native updater does not repair Desktop' 'hermes desktop --build-only --force-build' $r.Calls
    Assert-Equal 'prior correlation restored after failed updater' 'prior-on-failure' (Get-Content -LiteralPath (Join-Path $s.State 'observed_correlation.txt') -Raw).Trim()

    $s = New-Sandbox 'source_update_failed_desktop_owed'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode fail_with_desktop_owed
    Assert-NotContains 'failed updater Desktop-owed output does not authorize repair' 'hermes desktop --build-only --force-build' $r.Calls
    Assert-Contains 'failed updater with Desktop-owed output stays non-success' 'STATUS: FAILED' $r.Output

    $s = New-Sandbox 'source_update_desktop_repair'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode desktop_failed
    Assert-MatchCount 'current Desktop failure authorizes one headless repair' '(?m)^hermes desktop --build-only --force-build\r?$' 1 $r.Calls
    Assert-Contains 'native Desktop follow-up remains PARTIAL' 'STATUS: PARTIAL' $r.Output

    $s = New-Sandbox 'source_update_desktop_locked'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode desktop_failed -DesktopLocked
    Assert-NotContains 'locked Desktop is not repaired or killed' 'hermes desktop --build-only --force-build' $r.Calls
    Assert-Contains 'locked Desktop is reported' 'holding Desktop build output' $r.Report

    $s = New-Sandbox 'source_update_desktop_repair_failed'
    Add-SourceInstall $s
    $r = Invoke-SourceUpdateScenario $s -Mode desktop_failed -DesktopRepairFail 1
    Assert-MatchCount 'failed Desktop repair is attempted once' '(?m)^hermes desktop --build-only --force-build\r?$' 1 $r.Calls
    Assert-NotContains 'failed Desktop repair is not UPDATED' 'STATUS: UPDATED' $r.Output
    Assert-Contains 'failed Desktop repair affects final status' 'Headless Desktop build repair failed' $r.Report

    # 21. Source provenance failures block before any source update.
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
