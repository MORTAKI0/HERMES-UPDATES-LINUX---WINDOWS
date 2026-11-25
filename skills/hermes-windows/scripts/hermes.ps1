# ---------------------------------------------------------------------------
# Hermes Operations — Windows check/update CLI
#
# Terminal-only orchestrator/verifier for the Windows 11 Hermes Desktop. It
# detects the actual distribution owner (source build, Microsoft Store, or
# signed sideload MSIX), uses only that owner's official updater, and verifies
# the remote Linux `hermes` backend independently. It never launches the
# Desktop GUI and never kills unrelated processes.
#
# Usage:
#   powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 check  -BackendUrl 'http://HOST:9119'
#   powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 update -BackendUrl 'http://HOST:9119'
#
# Optional:
#   -NoBackup           skip Hermes' own quick snapshot (source builds only,
#                       only when explicitly requested)
#   -AppInstallerFile   operator-supplied, publisher-verified .appinstaller
#                       descriptor for a signed sideload MSIX; never guessed
#
# Exit codes: 0 = operation passed all provable checks; 1 = degraded/partial/
# unknown/failed; 2 = blocked/ambiguous/unsafe.
# PowerShell 5.1+ only. No third-party modules required.
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'update')]
    [string]$Action = 'check',

    [string]$BackendUrl = '',

    [switch]$NoBackup,

    [string]$AppInstallerFile = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:ScriptVersion = '1.0.0'
$script:Operation = $Action
$script:BackendUrlInput = [string]$BackendUrl
$script:BackendUrlExplicit = [bool]$PSBoundParameters.ContainsKey('BackendUrl')
$script:StartedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$script:StartedAt = Get-Date

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:ReportRoot = Join-Path $script:RepoRoot 'reports'
$script:ReportPath = ''

$script:Status = 'UNKNOWN'
$script:ExitCode = 1
$script:FailurePhase = 'NONE'
$script:Summary = ''
$script:Mutations = 'none'

$script:HostName = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($script:HostName)) { $script:HostName = 'unknown' }
$script:OsName = 'unknown'
$script:OsBuild = 0
$script:PsVersion = $PSVersionTable.PSVersion.ToString()
try {
    $script:Account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
} catch {
    $script:Account = "$env:USERNAME (Windows identity unavailable: $($_.Exception.Message))"
}

$script:Owner = 'Unknown'
$script:OwnerEvidence = ''
$script:HeremesCommand = $null
$script:HeremesPath = ''
$script:HeremesCliPresent = $false
$script:SourceCheckout = ''
$script:SourcePresent = $false
$script:SourceInstallDirectory = ''
$script:SourceInstallMethod = 'unknown'
$script:SourceChannel = 'unknown'
$script:SourceVersionOk = 'unknown'
$script:UpdateCheckChannel = 'unknown'
$script:SourceProvenanceOk = 'unknown'
$script:InstallId = 'unknown'
$script:InstallIdBefore = 'unknown'
$script:CanonicalCheckout = 'unknown'
$script:CheckoutBefore = 'unknown'
$script:CliPathBefore = ''
$script:GitHead = 'unknown'
$script:GitHeadBefore = 'unknown'
$script:GitIntegrityOk = 'unknown'
$script:StableTargetVersion = 'unknown'
$script:StableTargetVersionBefore = 'unknown'
$script:StableTargetShort = 'unknown'
$script:StableTargetShortBefore = 'unknown'
$script:StableTargetFull = 'unknown'
$script:StableTargetFullBefore = 'unknown'
$script:SourceVerification = 'not applicable'
$script:DesktopBuildExpected = 'unknown'
$script:DesktopBuildVerified = 'unverified'
$script:DesktopArtifactPath = 'not found'
$script:DesktopRepairRun = 'no'
$script:DesktopRepairResult = 'not applicable'
$script:UpdateCorrelationId = ''
$script:GitRemote = 'unknown'
$script:GitBranch = 'unknown'
$script:GitDirty = 'unknown'
$script:AppxPackage = $null
$script:AppxCount = 0
$script:AppxOwnerCandidate = 'None'
$script:AppxIssue = ''
$script:AppxIdentities = ''
$script:InstalledVersion = 'unknown'
$script:InstalledVersionAfter = 'not applicable'
$script:PackageIdentity = 'not applicable'
$script:PackagePublisher = 'not applicable'
$script:SignatureKind = 'not applicable'
$script:SideloadDescriptorValid = $false
$script:SideloadDescriptorPath = ''
$script:SideloadDescriptorReason = ''
$script:SideloadDescriptorVersion = 'unknown'
$script:UpdateAvailable = 'unknown'
$script:AvailableVersion = 'unknown'
$script:DistributorState = 'unknown'

$script:BackendUrlRaw = ''
$script:BackendUrl = ''
$script:BackendUrlSource = 'not supplied'
$script:BackendUrlDisplay = 'not supplied'
$script:DnsState = 'NOT_TESTED'
$script:TcpState = 'NOT_TESTED'
$script:TailscaleState = 'NOT_TESTED'
$script:HttpState = 'NOT_TESTED'
$script:HttpCode = 'not tested'
$script:HttpContentType = 'unknown'
$script:HttpProtocol = 'unknown'
$script:HttpAuthRequired = 'unknown'
$script:HttpVersion = 'unknown'
$script:HttpOverall = 'unknown'
$script:BackendHealthState = 'unknown'
$script:AuthState = 'NOT_TESTED'
$script:WebSocketState = 'NOT_TESTED'

$script:ReceiptPath = 'none'
$script:ReceiptOutcome = 'unknown'
$script:ReceiptFollowupCount = 0
$script:ReceiptFollowupText = ''
$script:ReceiptGatewayIncomplete = 'unknown'
$script:ReceiptFresh = 'unknown'
$script:ReceiptCheck = 'NOT_TESTED'
$script:ReceiptCorrelation = 'unknown'
$script:ReceiptContractValid = 'no'
$script:ReceiptBuildFailure = 'unknown'
$script:DesktopBuildState = 'unknown'

$script:UpdateOutput = ''
$script:UpdateExit = 'not run'
$script:UpdateNeeded = $false
$script:UpdateAttempted = $false
$script:PostPackageVerified = 'not applicable'

$script:CheckRows = New-Object System.Collections.Generic.List[string]
$script:TimelineRows = New-Object System.Collections.Generic.List[string]
$script:Blocks = New-Object System.Collections.Generic.List[string]
$script:Degraded = New-Object System.Collections.Generic.List[string]
$script:Confirmed = New-Object System.Collections.Generic.List[string]
$script:Likely = New-Object System.Collections.Generic.List[string]
$script:Unknowns = New-Object System.Collections.Generic.List[string]
$script:Works = New-Object System.Collections.Generic.List[string]
$script:Affected = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Evidence = New-Object System.Collections.Generic.List[string]
$script:Journal = 'not collected'

$script:StoreProductId = '9PMXK8CZC7KR'
# Official Store submission identity (apps/desktop/product-identity.cjs, storeMsix).
$script:StoreAppxName = 'NousResearchInc.HermesAgent'
$script:StorePublisher = 'CN=EE6D86E4-606F-4E38-B940-AD7248C9D519'
# Official out-of-store/sideload identity (msixAppIdWithOrg / channel .appinstaller).
$script:BundledAppxName = 'NousResearch.HermesBundled'
$script:SideloadPublisherPattern = '^CN=Nous Research Inc\.'
$script:MinFreeMb = 2048

# ---------------------------------------------------------------------------
# Output, sanitizing, rows
# ---------------------------------------------------------------------------
function Write-Say([string]$Message) {
    Write-Output (Sanitize-Text $Message)
}

function Write-WarnLine([string]$Message) {
    [Console]::Error.WriteLine("WARN: $(Sanitize-Text $Message)")
}

function Sanitize-Text {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $s = $Text
    $s = [regex]::Replace($s, '((https?|ssh|git)://)[^/@\s]+@', '$1[REDACTED]@', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $s = [regex]::Replace($s, '([?&][^=\s]+=)[^&\s]+', '$1[REDACTED]')
    $s = [regex]::Replace($s, '(Authorization:\s*).*', '$1[REDACTED]', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $s = [regex]::Replace($s, '(Bearer\s+)[A-Za-z0-9._~+/-]+=*', '$1[REDACTED]', 'IgnoreCase')
    $s = [regex]::Replace($s, '((password|passwd|token|secret|api[_-]?key|auth[_-]?token|client[_-]?secret|session[_-]?token)\s*[=:]\s*)[^\s"'']+', '$1[REDACTED]', 'IgnoreCase')
    $s = [regex]::Replace($s, '(-----BEGIN [A-Z ]*PRIVATE KEY-----).*', '$1[REDACTED]', 'IgnoreCase')
    $s = [regex]::Replace($s, '\b(sk-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})\b', '[REDACTED]')
    return $s
}

function Limit-Text {
    param([string]$Text, [int]$MaxLines = 40, [int]$MaxChars = 500)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $lines = @($Text -split "`r?`n" | Select-Object -First $MaxLines)
    $joined = ($lines -join "`n")
    $joined = Sanitize-Text $joined
    if ($joined.Length -gt $MaxChars * $MaxLines) {
        $joined = $joined.Substring(0, $MaxChars * $MaxLines)
    }
    return $joined
}

function ConvertTo-MdCell {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $s = Sanitize-Text $Text
    $s = ($s -replace "`r?`n", ' ')
    $s = $s -replace '\|', '\|'
    if ($s.Length -gt 500) { $s = $s.Substring(0, 500) + '…' }
    return $s
}

function Add-Timeline {
    param([string]$Phase, [string]$Command, [string]$Status, [string]$Detail)
    $line = '| ' + (ConvertTo-MdCell $Phase) + ' | `' + (ConvertTo-MdCell $Command) + '` | ' +
            (ConvertTo-MdCell $Status) + ' | ' + (ConvertTo-MdCell (Limit-Text $Detail 8 300)) + ' |'
    $script:TimelineRows.Add($line)
}

function Add-CheckRow {
    param([string]$Check, [string]$Expected, [string]$Actual, [string]$Verdict)
    $line = '| ' + (ConvertTo-MdCell $Check) + ' | ' + (ConvertTo-MdCell $Expected) + ' | ' +
            (ConvertTo-MdCell $Actual) + ' | ' + $Verdict + ' |'
    $script:CheckRows.Add($line)
}

function Add-Block {
    param([string]$Phase, [string]$Reason)
    if ($script:FailurePhase -eq 'NONE') { $script:FailurePhase = $Phase }
    $clean = Limit-Text $Reason 6 500
    $script:Blocks.Add("$Phase|$clean")
    [Console]::Error.WriteLine("ERROR: $clean")
}

function Add-Degraded {
    param([string]$Phase, [string]$Reason)
    if ($script:FailurePhase -eq 'NONE') { $script:FailurePhase = $Phase }
    $clean = Limit-Text $Reason 6 500
    $script:Degraded.Add("$Phase|$clean")
    Write-WarnLine $clean
}

function Add-Confirmed([string]$Text) { $script:Confirmed.Add('- ' + (Limit-Text $Text 3 500)) }
function Add-Likely([string]$Text)    { $script:Likely.Add('- ' + (Limit-Text $Text 3 500)) }
function Add-Unknown([string]$Text)   { $script:Unknowns.Add('- ' + (Limit-Text $Text 3 500)) }
function Add-Works([string]$Text)     { $script:Works.Add('- ' + (Limit-Text $Text 3 500)) }
function Add-Affected([string]$Text)  { $script:Affected.Add('- ' + (Limit-Text $Text 3 500)) }
function Add-Warning([string]$Text)   { $script:Warnings.Add('- ' + (Limit-Text $Text 3 500)) }
function Add-Evidence([string]$Text)  { $script:Evidence.Add('- ' + (Limit-Text $Text 3 500)) }

# ---------------------------------------------------------------------------
# Native command helper. Returns exit code, stores merged output globally.
# ---------------------------------------------------------------------------
$script:NativeExit = 0
$script:NativeOutput = ''

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Native {
    param(
        [string]$Command,
        [string[]]$Arguments = @()
    )
    $script:NativeExit = 127
    $script:NativeOutput = ''
    if (-not (Test-CommandExists $Command)) {
        $script:NativeOutput = "command not found: $Command"
        return 127
    }
    $global:LASTEXITCODE = 0
    $previousOutputEncoding = $null
    try {
        # Windows PowerShell 5.1 decodes native stdout/stderr with the console
        # encoding. Hermes emits UTF-8; decode it as such without leaving a
        # permanent console/code-page change behind.
        $previousOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $script:NativeOutput = (& $Command @Arguments 2>&1 | Out-String)
        if ($null -eq $LASTEXITCODE) {
            $script:NativeExit = 0
        } else {
            $script:NativeExit = [int]$LASTEXITCODE
        }
    } catch {
        $script:NativeOutput = $_.Exception.Message
        $script:NativeExit = 1
    } finally {
        if ($null -ne $previousOutputEncoding) {
            try { [Console]::OutputEncoding = $previousOutputEncoding } catch { }
        }
    }
    return $script:NativeExit
}

# ---------------------------------------------------------------------------
# Input and environment validation
# ---------------------------------------------------------------------------
function Normalize-BackendUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        Add-Block 'PRECHECK' "Backend URL is not an absolute URI."
        return ''
    }
    if (($uri.Scheme -ne 'http') -and ($uri.Scheme -ne 'https')) {
        Add-Block 'PRECHECK' "Backend URL must use http or https."
        return ''
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        Add-Block 'PRECHECK' "Backend URL must not embed credentials (userinfo)."
        return ''
    }
    if ((-not [string]::IsNullOrEmpty($uri.Query)) -or (-not [string]::IsNullOrEmpty($uri.Fragment))) {
        Add-Block 'PRECHECK' "Backend URL must not contain a query string or fragment."
        return ''
    }
    return $uri.GetLeftPart([UriPartial]::Path).TrimEnd('/')
}

function Get-HermesHomePath {
    if (-not [string]::IsNullOrWhiteSpace($env:HERMES_HOME)) {
        return $env:HERMES_HOME
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA 'hermes')
    }
    return (Join-Path $env:USERPROFILE '.hermes')
}

function Initialize-Environment {
    $isWindowsOs = ($env:OS -eq 'Windows_NT')
    if (-not $isWindowsOs) {
        Add-Block 'PRECHECK' "This script must run on Windows; detected OS '$($env:OS)'."
        return $false
    }
    $script:OsName = 'Windows'
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $script:OsName = $os.Caption
        $script:OsBuild = [int]$os.BuildNumber
        Add-CheckRow 'Windows version' 'Windows 11 (build >= 22000)' `
            "$($os.Caption) build $($os.BuildNumber)" `
            $(if ([int]$os.BuildNumber -ge 22000) { 'PASS' } else { 'FAIL' })
        if ([int]$os.BuildNumber -lt 22000) {
            Add-Degraded 'PRECHECK' "Windows build $($os.BuildNumber) is older than Windows 11 (22000)."
        }
    } catch {
        Add-Degraded 'PRECHECK' "Could not read Windows version: $($_.Exception.Message)"
        Add-CheckRow 'Windows version' 'Windows 11' 'unreadable' 'NOT_TESTED'
    }
    $psv = $PSVersionTable.PSVersion
    $psOk = ($psv.Major -gt 5) -or (($psv.Major -eq 5) -and ($psv.Minor -ge 1))
    Add-CheckRow 'PowerShell version' '5.1 or newer' $script:PsVersion $(if ($psOk) { 'PASS' } else { 'FAIL' })
    if (-not $psOk) {
        Add-Block 'PRECHECK' "PowerShell 5.1 or newer is required; found $script:PsVersion."
        return $false
    }
    Add-CheckRow 'Execution account' 'non-elevated interactive account' $script:Account 'PASS'

    if ($script:BackendUrlExplicit) {
        $script:BackendUrlRaw = $script:BackendUrlInput
        $script:BackendUrlSource = 'explicit -BackendUrl'
        if ([string]::IsNullOrWhiteSpace($script:BackendUrlRaw)) {
            Add-Block 'PRECHECK' 'Backend URL is not an absolute URI.'
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($env:HERMES_DESKTOP_REMOTE_URL)) {
        $script:BackendUrlRaw = $env:HERMES_DESKTOP_REMOTE_URL
        $script:BackendUrlSource = 'pre-existing HERMES_DESKTOP_REMOTE_URL'
    } else {
        $script:BackendUrlRaw = ''
        $script:BackendUrlSource = 'not supplied'
    }
    if (-not [string]::IsNullOrWhiteSpace($script:BackendUrlRaw)) {
        $script:BackendUrl = Normalize-BackendUrl $script:BackendUrlRaw
        if (-not [string]::IsNullOrWhiteSpace($script:BackendUrl)) {
            $script:BackendUrlDisplay = Sanitize-Text $script:BackendUrl
        }
    }
    return $true
}

# ---------------------------------------------------------------------------
# Owner detection (must happen before any action)
# ---------------------------------------------------------------------------
function Get-HermesCommandInfo {
    $commands = @(Get-Command hermes -All -ErrorAction SilentlyContinue)
    $script:HeremesCommand = $commands | Select-Object -First 1
    $script:HeremesCliPresent = ($commands.Count -gt 0)
    if ($null -ne $script:HeremesCommand) {
        if (-not [string]::IsNullOrEmpty($script:HeremesCommand.Source)) {
            $script:HeremesPath = $script:HeremesCommand.Source
        } elseif (-not [string]::IsNullOrEmpty($script:HeremesCommand.Path)) {
            $script:HeremesPath = $script:HeremesCommand.Path
        } elseif (-not [string]::IsNullOrEmpty($script:HeremesCommand.Definition)) {
            $script:HeremesPath = $script:HeremesCommand.Definition
        }
    }
    $candidate = Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent'
    if ((Test-Path -LiteralPath $candidate -PathType Container) -or (Test-Path -LiteralPath (Join-Path $candidate '.git'))) {
        $script:SourceCheckout = $candidate
    }
    $localHermesRoot = Join-Path $env:LOCALAPPDATA 'hermes'
    $cliLooksSource = $false
    if (-not [string]::IsNullOrEmpty($script:HeremesPath)) {
        if (($script:HeremesPath -like "$localHermesRoot\*") -and ($script:HeremesPath -notmatch '\\WindowsApps\\')) {
            $cliLooksSource = $true
        }
    }
    $script:SourcePresent = [bool]($script:SourceCheckout -or $cliLooksSource)
}

function Get-AppxInfo {
    param([switch]$AfterUpdate)
    if (-not (Test-CommandExists 'Get-AppxPackage')) {
        Add-Block 'WINDOWS_PACKAGE' 'Get-AppxPackage is unavailable in this PowerShell session; package ownership cannot be proven.'
        return
    }
    try {
        $allPackages = @(Get-AppxPackage -ErrorAction Stop)
    } catch {
        Add-Block 'WINDOWS_PACKAGE' "Get-AppxPackage failed; package ownership cannot be proven: $($_.Exception.Message)"
        return
    }
    $hermesPackages = @($allPackages | Where-Object {
        ($_.Name -match '(?i)hermes') -or ($_.PackageFamilyName -match '(?i)hermes')
    })
    $script:AppxCount = $hermesPackages.Count
    $script:AppxOwnerCandidate = 'None'
    $script:AppxIssue = ''
    $script:AppxIdentities = ''
    if ($hermesPackages.Count -eq 0) {
        if ($AfterUpdate) { $script:InstalledVersionAfter = 'absent' }
        return
    }
    $script:AppxIdentities = (($hermesPackages | ForEach-Object {
        "$($_.Name)@$($_.Version)[$($_.SignatureKind)] publisher=$($_.Publisher)"
    }) -join '; ')

    $storePackages = @($hermesPackages | Where-Object { $_.Name -eq $script:StoreAppxName })
    $bundledPackages = @($hermesPackages | Where-Object { $_.Name -eq $script:BundledAppxName })
    $unknownPackages = @($hermesPackages | Where-Object {
        ($_.Name -ne $script:StoreAppxName) -and ($_.Name -ne $script:BundledAppxName)
    })

    if ($unknownPackages.Count -gt 0) {
        $script:AppxOwnerCandidate = 'Unknown'
        $script:AppxIssue = "Unrecognized Hermes package identity: $($script:AppxIdentities)"
    } elseif (($storePackages.Count + $bundledPackages.Count) -ne 1) {
        $script:AppxOwnerCandidate = 'Unknown'
        $script:AppxIssue = "Multiple or ambiguous Hermes MSIX packages are registered: $($script:AppxIdentities)"
    }

    $observed = $hermesPackages[0]
    if ($storePackages.Count -eq 1) { $observed = $storePackages[0] }
    elseif ($bundledPackages.Count -eq 1) { $observed = $bundledPackages[0] }
    $script:AppxPackage = $observed
    $observedVersion = $observed.Version.ToString()
    if ($AfterUpdate) {
        $script:InstalledVersionAfter = $observedVersion
    } else {
        $script:InstalledVersion = $observedVersion
        if ($script:InstalledVersionAfter -eq 'not applicable') {
            $script:InstalledVersionAfter = $observedVersion
        }
    }
    $script:PackageIdentity = $observed.PackageFullName
    $script:PackagePublisher = $observed.Publisher
    $script:SignatureKind = [string]$observed.SignatureKind

    if ($script:AppxIssue -eq '') {
        if ($storePackages.Count -eq 1) {
            $pkg = $storePackages[0]
            if ([string]$pkg.SignatureKind -ne 'Store') {
                $script:AppxOwnerCandidate = 'Unknown'
                $script:AppxIssue = "Store package identity '$($pkg.Name)' is not Store-signed (SignatureKind=$($pkg.SignatureKind))."
            } elseif ([string]$pkg.Publisher -ne $script:StorePublisher) {
                $script:AppxOwnerCandidate = 'Unknown'
                $script:AppxIssue = "Store package publisher '$($pkg.Publisher)' does not match the official Store publisher."
            } else {
                $script:AppxOwnerCandidate = 'Microsoft Store'
            }
        } elseif ($bundledPackages.Count -eq 1) {
            $pkg = $bundledPackages[0]
            $sig = [string]$pkg.SignatureKind
            if (($sig -ne 'Developer') -and ($sig -ne 'Enterprise')) {
                $script:AppxOwnerCandidate = 'Unknown'
                $script:AppxIssue = "Bundled package identity '$($pkg.Name)' is not a signed sideload (SignatureKind=$sig)."
            } elseif ([string]$pkg.Publisher -notmatch $script:SideloadPublisherPattern) {
                $script:AppxOwnerCandidate = 'Unknown'
                $script:AppxIssue = "Bundled package publisher '$($pkg.Publisher)' is not the official Nous Research sideload publisher."
            } else {
                $script:AppxOwnerCandidate = 'Sideload MSIX'
            }
        }
    }

    if ($AfterUpdate -and ($script:AppxIssue -ne '')) {
        Add-Block 'WINDOWS_PACKAGE' $script:AppxIssue
    }
}

function Get-SourceVersion {
    param([switch]$AfterUpdate)
    if ([string]::IsNullOrEmpty($script:HeremesPath)) { return }
    $exit = Invoke-Native $script:HeremesPath @('--version')
    $out = $script:NativeOutput
    Add-Timeline 'WINDOWS_PACKAGE' 'hermes --version' "exit $exit" (($out -split "`r?`n" | Select-Object -First 1) -join ' ')
    if ($exit -eq 0) {
        $script:SourceVersionOk = 'yes'
        $m = [regex]::Match($out, 'v?(\d+\.\d+\.\d+)')
        if ($m.Success) {
            if ($AfterUpdate) {
                $script:InstalledVersionAfter = $m.Groups[1].Value
            } else {
                $script:InstalledVersion = $m.Groups[1].Value
                if ($script:InstalledVersionAfter -eq 'not applicable') {
                    $script:InstalledVersionAfter = $script:InstalledVersion
                }
            }
        } else {
            $script:SourceVersionOk = 'no'
            Add-Degraded 'WINDOWS_PACKAGE' 'hermes --version did not contain a parseable vX.Y.Z version.'
        }
        $dirMatch = [regex]::Match($out, '(?im)^Install directory:\s*(.+?)\s*$')
        if ($dirMatch.Success) {
            $script:SourceInstallDirectory = $dirMatch.Groups[1].Value
            $script:CanonicalCheckout = Get-NormalizedPath $script:SourceInstallDirectory
        }
        $methodMatch = [regex]::Match($out, '(?im)^Install method:\s*(\S+)')
        if ($methodMatch.Success) { $script:SourceInstallMethod = $methodMatch.Groups[1].Value }
        $channelMatch = [regex]::Match($out, '(?i)\b(stable|canary|main)\b')
        if ($channelMatch.Success) { $script:SourceChannel = $channelMatch.Groups[1].Value.ToLowerInvariant() }
        $versionVerdict = $(if ($script:SourceVersionOk -eq 'yes') { 'PASS' } else { 'FAIL' })
        Add-CheckRow 'Hermes CLI version' 'discoverable' `
            "v$($script:InstalledVersion) (after=$($script:InstalledVersionAfter)); method=$($script:SourceInstallMethod); channel=$($script:SourceChannel)" $versionVerdict
    } else {
        $script:SourceVersionOk = 'no'
        Add-Degraded 'WINDOWS_PACKAGE' "hermes --version failed (exit $exit)."
        Add-CheckRow 'Hermes CLI version' 'discoverable' "exit $exit" 'FAIL'
    }
}

function Get-NormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        return [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    } catch {
        return $Path.TrimEnd([char[]]@('\', '/'))
    }
}

function Test-SourceProvenance {
    param([switch]$AfterUpdate)
    if ($script:Owner -ne 'Source build') { return }
    $issues = @()
    if ($script:SourceVersionOk -ne 'yes') { $issues += 'hermes --version did not complete successfully; CLI provenance is unavailable.' }
    if ([string]::IsNullOrEmpty($script:HeremesPath)) { $issues += 'hermes CLI path is missing.' }
    if ([string]::IsNullOrEmpty($script:SourceCheckout)) { $issues += 'source checkout path is missing.' }
    if (-not [string]::IsNullOrEmpty($script:HeremesPath)) {
        $localRoot = Join-Path $env:LOCALAPPDATA 'hermes'
        $cliInRoot = ($script:HeremesPath -like "$localRoot\*")
        $wrapperReferencesCheckout = $false
        if (-not $cliInRoot -and (Test-Path -LiteralPath $script:HeremesPath -PathType Leaf)) {
            try {
                $wrapperText = Get-Content -LiteralPath $script:HeremesPath -Raw -ErrorAction Stop
                if ($wrapperText -match [regex]::Escape($script:SourceCheckout)) { $wrapperReferencesCheckout = $true }
            } catch { $wrapperReferencesCheckout = $false }
        }
        if ((-not $cliInRoot) -and (-not $wrapperReferencesCheckout)) {
            $issues += "resolved CLI '$($script:HeremesPath)' is outside the verified source install root and does not reference the checkout."
        }
    }
    if ([string]::IsNullOrEmpty($script:SourceInstallDirectory)) {
        $issues += 'hermes --version did not report an install directory.'
    } else {
        $cliDir = Get-NormalizedPath $script:SourceInstallDirectory
        $expectedDir = Get-NormalizedPath $script:SourceCheckout
        if ($cliDir -ine $expectedDir) {
            $issues += "resolved CLI reports install directory '$script:SourceInstallDirectory', which does not belong to the discovered checkout '$script:SourceCheckout'."
        }
    }
    if ($script:SourceInstallMethod -ne 'git') {
        $issues += "install method '$($script:SourceInstallMethod)' is not a managed Git checkout."
    }
    if ($script:SourceChannel -ne 'stable') {
        $issues += "installed update channel '$($script:SourceChannel)' is not stable."
    }
    if ($script:UpdateCheckChannel -ne 'stable') {
        $issues += "update-check channel '$($script:UpdateCheckChannel)' is not verified stable."
    }
    if (($script:SourceChannel -ne 'unknown') -and ($script:UpdateCheckChannel -ne 'unknown') -and
        ($script:SourceChannel -ne $script:UpdateCheckChannel)) {
        $issues += "installed channel '$($script:SourceChannel)' disagrees with update-check channel '$($script:UpdateCheckChannel)'."
    }
    if (-not [string]::IsNullOrEmpty($script:SourceCheckout)) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:SourceCheckout '.git'))) {
            $issues += "source checkout '$($script:SourceCheckout)' has no .git metadata."
        }
        $insideExit = Invoke-Native 'git' @('-C', $script:SourceCheckout, 'rev-parse', '--is-inside-work-tree')
        if (($insideExit -ne 0) -or ($script:NativeOutput.Trim() -ne 'true')) {
            $issues += "git rev-parse --is-inside-work-tree failed (exit $insideExit)."
            $script:GitIntegrityOk = 'no'
        }
        $headExit = Invoke-Native 'git' @('-C', $script:SourceCheckout, 'rev-parse', 'HEAD')
        $headOut = $script:NativeOutput.Trim()
        if (($headExit -eq 0) -and ($headOut -match '^[0-9a-fA-F]{40}$')) {
            $script:GitHead = $headOut.ToLowerInvariant()
        } else {
            $script:GitHead = 'unknown'
            $script:GitIntegrityOk = 'no'
            $issues += "git rev-parse HEAD did not return one full commit (exit $headExit)."
        }
        $remoteExit = Invoke-Native 'git' @('-C', $script:SourceCheckout, 'remote', 'get-url', 'origin')
        $remotes = @($script:NativeOutput -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $script:GitRemote = $(if ($remotes.Count -gt 0) { $remotes[0].Trim() } else { 'unknown' })
        $officialRemote = '^(https://github\.com/NousResearch/hermes-agent(\.git)?|git@github\.com:NousResearch/hermes-agent(\.git)?|ssh://git@github\.com/NousResearch/hermes-agent(\.git)?)$'
        if (($remoteExit -ne 0) -or ($script:GitRemote -notmatch $officialRemote)) {
            $issues += "origin remote '$script:GitRemote' is not the official NousResearch/hermes-agent repository (exit $remoteExit)."
        }
        $branchExit = Invoke-Native 'git' @('-C', $script:SourceCheckout, 'symbolic-ref', '--short', '-q', 'HEAD')
        $branchOut = $script:NativeOutput.Trim()
        if ($branchExit -eq 0) {
            $script:GitBranch = $branchOut
            if ($branchOut -notin @('main', 'master')) {
                $issues += "checkout is on custom branch '$branchOut'."
            }
        } elseif (($branchExit -eq 1) -and [string]::IsNullOrEmpty($branchOut)) {
            $script:GitBranch = 'detached'
        } else {
            $issues += "checkout branch could not be read (exit $branchExit)."
        }
        $statusExit = Invoke-Native 'git' @('-C', $script:SourceCheckout, 'status', '--porcelain', '--untracked-files=normal')
        if ($statusExit -ne 0) {
            $script:GitDirty = 'unknown'
            $issues += "git status failed (exit $statusExit); repository cleanliness cannot be proven."
        } elseif (-not [string]::IsNullOrWhiteSpace($script:NativeOutput)) {
            $script:GitDirty = 'yes'
            $issues += "source checkout has uncommitted changes; refusing to reset/stash/assume clean."
            Add-Evidence "git status: $(Limit-Text $script:NativeOutput 8 600)"
        } else {
            $script:GitDirty = 'no'
        }
    }

    if ($issues.Count -eq 0) {
        $script:SourceProvenanceOk = 'yes'
        $script:GitIntegrityOk = 'yes'
        Add-CheckRow 'Source provenance' 'official checkout, stable channel, clean tree' `
            "checkout=$($script:CanonicalCheckout); head=$($script:GitHead); remote=$($script:GitRemote); branch=$($script:GitBranch); dirty=$($script:GitDirty)" 'PASS'
    } else {
        $script:SourceProvenanceOk = 'no'
        if ($script:GitIntegrityOk -ne 'no') { $script:GitIntegrityOk = 'no' }
        foreach ($issue in $issues) {
            if ($AfterUpdate) { Add-Degraded 'SOURCE_UPDATE' $issue } else { Add-Block 'PRECHECK' $issue }
        }
        Add-CheckRow 'Source provenance' 'official checkout, stable channel, clean tree' `
            "remote=$($script:GitRemote); branch=$($script:GitBranch); dirty=$($script:GitDirty); issues=$($issues.Count)" 'FAIL'
    }
    Add-Timeline 'PRECHECK' 'source provenance' $script:SourceProvenanceOk `
        "remote=$($script:GitRemote); branch=$($script:GitBranch); head=$($script:GitHead); dirty=$($script:GitDirty)"
}

function Resolve-Owner {
    Get-HermesCommandInfo
    Get-AppxInfo

    $appxPresent = ($script:AppxCount -ge 1)
    if ($appxPresent -and $script:SourcePresent) {
        Add-Block 'WINDOWS_PACKAGE' "A source/CLI Hermes install and a registered MSIX package both exist. The active Desktop owner is unclear; refusing to choose or convert distributions."
        $script:Owner = 'Unknown (source + MSIX)'
        $script:OwnerEvidence = "appx=$($script:AppxIdentities) sourceCli=$($script:HeremesPath) checkout=$($script:SourceCheckout)"
        Add-CheckRow 'Desktop package owner' 'exactly one unambiguous owner' 'source + MSIX both present' 'FAIL'
        return
    }

    if ($appxPresent) {
        if ($script:AppxIssue -ne '') {
            Add-Block 'WINDOWS_PACKAGE' $script:AppxIssue
            $script:Owner = 'Unknown (unrecognized MSIX ownership)'
            $script:OwnerEvidence = $script:AppxIdentities
            Add-CheckRow 'Desktop package owner' 'recognized official Store or sideload identity' $script:AppxIdentities 'FAIL'
            return
        }
        if ($script:AppxOwnerCandidate -eq 'Microsoft Store') {
            $script:Owner = 'Microsoft Store'
        } elseif ($script:AppxOwnerCandidate -eq 'Sideload MSIX') {
            $script:Owner = 'Sideload MSIX'
        } else {
            Add-Block 'WINDOWS_PACKAGE' "Registered Hermes package ownership could not be classified: $($script:AppxIdentities)"
            $script:Owner = 'Unknown (unclassified MSIX ownership)'
            $script:OwnerEvidence = $script:AppxIdentities
            Add-CheckRow 'Desktop package owner' 'recognized official Store or sideload identity' $script:AppxIdentities 'FAIL'
            return
        }
        $script:OwnerEvidence = "Name=$($script:AppxPackage.Name); Version=$($script:InstalledVersion); Publisher=$($script:PackagePublisher); SignatureKind=$($script:SignatureKind); Family=$($script:AppxPackage.PackageFamilyName)"
        Add-CheckRow 'Desktop package owner' 'one verified distributor' `
            "$($script:Owner); $($script:AppxPackage.Name); $($script:SignatureKind); v$($script:InstalledVersion)" 'PASS'
        return
    }

    if ($script:SourcePresent -and -not [string]::IsNullOrEmpty($script:HeremesPath)) {
        $script:Owner = 'Source build'
        $script:OwnerEvidence = "cli=$($script:HeremesPath); checkout=$($script:SourceCheckout)"
        if ([string]::IsNullOrEmpty($script:SourceCheckout)) {
            Add-Block 'WINDOWS_PACKAGE' "A source/CLI hermes was found at '$($script:HeremesPath)' but no verified Git checkout exists at '$env:LOCALAPPDATA\hermes\hermes-agent\.git'."
            Add-CheckRow 'Desktop package owner' 'verified source checkout' "CLI present; checkout not verified" 'FAIL'
        } else {
            Add-CheckRow 'Desktop package owner' 'one verified distributor' "source build; $($script:HeremesPath); checkout=$($script:SourceCheckout)" 'PASS'
        }
        Get-SourceVersion
        return
    }

    if ($script:SourcePresent -and [string]::IsNullOrEmpty($script:HeremesPath)) {
        $script:Owner = 'Unknown (source checkout without CLI)'
        Add-Block 'WINDOWS_PACKAGE' "A source checkout exists at '$($script:SourceCheckout)' but no hermes CLI was resolved."
        Add-CheckRow 'Desktop package owner' 'verified source checkout and CLI' 'checkout present; CLI missing' 'FAIL'
        return
    }
    if ($script:HeremesCliPresent) {
        $script:Owner = 'Unknown (unverified CLI)'
        Add-Block 'WINDOWS_PACKAGE' "A hermes CLI was found at '$($script:HeremesPath)' but it is not tied to a verified source checkout or a recognized Store/sideload package."
        Add-CheckRow 'Desktop package owner' 'verified installation owner' "unverified CLI: $($script:HeremesPath)" 'FAIL'
        return
    }
    $script:Owner = 'Not installed'
    Add-Block 'WINDOWS_PACKAGE' "No supported existing Hermes installation was found. Automatic bootstrap is not allowed."
    Add-CheckRow 'Desktop package owner' 'supported existing install' 'none' 'FAIL'
}

function Get-SourceUpdateAvailability {
    param([switch]$AfterUpdate)
    if ([string]::IsNullOrEmpty($script:HeremesPath)) { return }
    $exit = Invoke-Native $script:HeremesPath @('update', '--check')
    $out = $script:NativeOutput
    Add-Timeline 'WINDOWS_PACKAGE' 'hermes update --check' "exit $exit" (($out -split "`r?`n" | Select-Object -First 4) -join ' ')
    if ($exit -ne 0) {
        Add-Degraded 'WINDOWS_PACKAGE' "hermes update --check failed (exit $exit)."
        $script:UpdateAvailable = 'unknown'
        return
    }

    $channelMatch = [regex]::Match($out, '(?im)^\s*(?:[→>]\s*)?Update channel:\s*(?<channel>[A-Za-z0-9_-]+)\s*$')
    if ($channelMatch.Success) {
        $script:UpdateCheckChannel = $channelMatch.Groups['channel'].Value.ToLowerInvariant()
    }

    $selected = [regex]::Match($out, '(?im)^\s*(?:[→>]\s*)?Selected release available:\s*(?<channel>[A-Za-z0-9_-]+)\s+v(?<version>\d+\.\d+\.\d+)\s*(?:\((?<sha>[0-9a-fA-F]{7,40})\))?\s*$')
    $current = [regex]::Match($out, '(?im)^\s*(?:[→>✓]\s*)?(?:Already up to date|Up to date with the latest release|No newer release)[^v\r\n]*v(?<version>\d+\.\d+\.\d+)?')
    if ($selected.Success) {
        $selectedChannel = $selected.Groups['channel'].Value.ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($script:UpdateCheckChannel) -or ($script:UpdateCheckChannel -eq 'unknown')) {
            $script:UpdateCheckChannel = $selectedChannel
        }
        $script:StableTargetVersion = $selected.Groups['version'].Value
        $script:AvailableVersion = $script:StableTargetVersion
        if ($selected.Groups['sha'].Success) {
            $script:StableTargetShort = $selected.Groups['sha'].Value.ToLowerInvariant()
        } else {
            $script:StableTargetShort = 'unknown'
        }
        if ($selectedChannel -ne 'stable') {
            $script:UpdateAvailable = 'unknown'
            $script:DistributorState = "source channel $selectedChannel (not stable)"
            Add-Degraded 'WINDOWS_PACKAGE' "Source update target is on channel '$selectedChannel', not stable."
        } elseif (($script:InstalledVersion -ne 'unknown') -and ($script:InstalledVersion -match '^\d+\.\d+\.\d+$')) {
            $cmp = Compare-VersionStrings $script:InstalledVersion $script:StableTargetVersion
            if ($cmp -gt 0) {
                $script:UpdateAvailable = 'downgrade'
            } elseif ($cmp -eq 0) {
                $script:UpdateAvailable = 'no'
            } else {
                $script:UpdateAvailable = 'yes'
            }
            $script:DistributorState = 'source stable channel'
        } else {
            $script:UpdateAvailable = 'unknown'
            Add-Degraded 'WINDOWS_PACKAGE' 'Installed source version is not a parseable release.'
        }
        if (($script:UpdateAvailable -eq 'yes') -and ($script:StableTargetShort -eq 'unknown')) {
            Add-Degraded 'WINDOWS_PACKAGE' 'The stable target revision is missing from native update-check output.'
        }
    } elseif ($current.Success) {
        if ($current.Groups['version'].Success) {
            $script:StableTargetVersion = $current.Groups['version'].Value
            $script:AvailableVersion = $script:StableTargetVersion
        }
        $script:StableTargetShort = 'unknown'
        $script:UpdateAvailable = 'no'
        $script:DistributorState = 'source stable channel current'
    } elseif ($out -match '(?i)no update|up[ -]?to[ -]?date|already current') {
        $script:UpdateAvailable = 'no'
        $script:StableTargetShort = 'unknown'
        $script:DistributorState = 'source stable channel current'
    } else {
        $script:UpdateAvailable = 'unknown'
        $script:StableTargetShort = 'unknown'
        $script:DistributorState = 'source stable channel unresolved'
        Add-Degraded 'WINDOWS_PACKAGE' 'Source update availability could not be parsed from the owner channel output.'
    }

    Add-CheckRow 'Source update availability' 'stable channel checked' `
        "installed v$($script:InstalledVersion); available v$($script:StableTargetVersion) ($($script:StableTargetShort)); update=$($script:UpdateAvailable); channel=$($script:UpdateCheckChannel)" 'INFO'
}

function Get-SourceInstallIdentity {
    param([switch]$AfterUpdate)
    if ([string]::IsNullOrEmpty($script:HeremesPath)) { return }
    $exit = Invoke-Native $script:HeremesPath @('update', '--install-id')
    $out = $script:NativeOutput
    Add-Timeline 'WINDOWS_PACKAGE' 'hermes update --install-id' "exit $exit" (($out -split "`r?`n" | Select-Object -First 1) -join ' ')
    $identity = ''
    if ($exit -eq 0) {
        $identity = (($out -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) -as [string])
        if (-not [string]::IsNullOrWhiteSpace($identity)) { $identity = $identity.Trim() }
    }
    if (($exit -ne 0) -or [string]::IsNullOrWhiteSpace($identity) -or ($identity -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$')) {
        if ($AfterUpdate) {
            Add-Degraded 'SOURCE_UPDATE' "Installation identity could not be re-read after update (exit $exit)."
        } else {
            Add-Block 'PRECHECK' "Installation identity could not be established (exit $exit); refusing to assume it."
        }
        $script:InstallId = 'unknown'
        return
    }
    $script:InstallId = $identity
    Add-CheckRow 'Installation identity' 'native install id' $identity 'PASS'
}

function Resolve-SourceTargetRevision {
    param([switch]$AfterUpdate)
    if ([string]::IsNullOrWhiteSpace($script:SourceCheckout)) {
        if ($AfterUpdate) { Add-Degraded 'SOURCE_UPDATE' 'Source checkout is unavailable for target revision resolution.' } else { Add-Block 'PRECHECK' 'Source checkout is unavailable for target revision resolution.' }
        return $false
    }
    if (($script:StableTargetShort -eq 'unknown') -or ($script:StableTargetShort -notmatch '^[0-9a-fA-F]{7,40}$')) {
        if ($AfterUpdate) { Add-Degraded 'SOURCE_UPDATE' 'Stable target revision is unresolved.' } else { Add-Block 'PRECHECK' 'Stable target revision could not be established; refusing a blind update.' }
        return $false
    }
    $rev = $script:StableTargetShort + '^{commit}'
    $exit = Invoke-Native 'git' @('-C', $script:SourceCheckout, 'rev-parse', '--verify', $rev)
    $lines = @($script:NativeOutput -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $full = ''
    if (($exit -eq 0) -and ($lines.Count -eq 1) -and ($lines[0].Trim() -match '^[0-9a-fA-F]{40}$')) {
        $full = $lines[0].Trim().ToLowerInvariant()
    } elseif (($script:StableTargetVersion -match '^\d+\.\d+\.\d+$') -and ($script:GitRemote -match 'NousResearch/hermes-agent')) {
        # The pre-update checkout often does not have the selected release object yet.
        # Resolve the immutable release tag against the already-verified official origin.
        $tag = "v$($script:StableTargetVersion)"
        $remoteExit = Invoke-Native 'git' @('-C', $script:SourceCheckout, 'ls-remote', 'origin', "refs/tags/$tag^{}", "refs/tags/$tag")
        if ($remoteExit -eq 0) {
            $remoteLines = @($script:NativeOutput -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $peeled = @()
            $direct = @()
            foreach ($line in $remoteLines) {
                $parts = $line.Trim() -split "`t", 2
                if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[0-9a-fA-F]{40}$') { continue }
                if ($parts[1] -eq "refs/tags/$tag^{}") { $peeled += $parts[0].ToLowerInvariant() }
                elseif ($parts[1] -eq "refs/tags/$tag") { $direct += $parts[0].ToLowerInvariant() }
            }
            if ($peeled.Count -gt 0) {
                $candidate = @($peeled | Select-Object -Unique)
            } else {
                $candidate = @($direct | Select-Object -Unique)
            }
            if ($candidate.Count -eq 1) { $full = [string]$candidate[0] }
        }
    }
    if ([string]::IsNullOrWhiteSpace($full) -or -not $full.StartsWith($script:StableTargetShort.ToLowerInvariant())) {
        if ($AfterUpdate) { Add-Degraded 'SOURCE_UPDATE' 'Stable target revision could not be resolved to one full commit.' } else { Add-Block 'PRECHECK' 'Stable target revision could not be resolved to one full commit.' }
        $script:StableTargetFull = 'unknown'
        return $false
    }
    if (($script:StableTargetFull -ne 'unknown') -and ($script:StableTargetFull -ne $full)) {
        if ($AfterUpdate) { Add-Degraded 'SOURCE_UPDATE' 'Stable target revision changed during resolution.' } else { Add-Block 'PRECHECK' 'Stable target revision changed during resolution.' }
        return $false
    }
    $script:StableTargetFull = $full
    Add-CheckRow 'Stable target revision' 'one authoritative full commit' $full 'PASS'
    return $true
}

function Capture-SourceBaseline {
    $script:StableTargetVersionBefore = $script:StableTargetVersion
    $script:StableTargetShortBefore = $script:StableTargetShort
    $script:StableTargetFullBefore = $script:StableTargetFull
    $script:InstallIdBefore = $script:InstallId
    $script:GitHeadBefore = $script:GitHead
    $script:CheckoutBefore = $script:CanonicalCheckout
    $script:CliPathBefore = $script:HeremesPath
    Add-Evidence "Pre-update source identity: install=$($script:InstallIdBefore); version=v$($script:InstalledVersion); head=$($script:GitHeadBefore); checkout=$($script:CheckoutBefore); target=v$($script:StableTargetVersionBefore) ($($script:StableTargetFullBefore)); cli=$($script:CliPathBefore)"
}

function Compare-VersionStrings {
    param([string]$Left, [string]$Right)
    try {
        $l = [version]$Left
        $r = [version]$Right
        return $l.CompareTo($r)
    } catch {
        return 0
    }
}

function Get-StoreUpdateAvailability {
    if ($script:Owner -ne 'Microsoft Store') { return }
    if (-not (Test-CommandExists 'winget')) {
        Add-Block 'WINDOWS_PACKAGE' "WinGet is not available; the Microsoft Store package cannot be checked or updated from this terminal."
        $script:UpdateAvailable = 'unknown'
        $script:DistributorState = 'winget unavailable'
        Add-CheckRow 'Store update availability' 'WinGet exact product ID' 'winget not found' 'FAIL'
        return
    }
    $exit = Invoke-Native 'winget' @('list', '--id', $script:StoreProductId, '--exact', '--source', 'msstore', '--upgrade-available', '--accept-source-agreements')
    $out = $script:NativeOutput
    Add-Timeline 'WINDOWS_PACKAGE' "winget list --id $script:StoreProductId --upgrade-available" "exit $exit" (($out -split "`r?`n" | Select-Object -First 6) -join ' ')
    Add-Evidence "WinGet list output: $(Limit-Text $out 10 900)"
    if ($exit -ne 0) {
        Add-Degraded 'WINDOWS_PACKAGE' "winget list failed (exit $exit); Store-channel availability is unknown."
        $script:UpdateAvailable = 'unknown'
        $script:DistributorState = 'winget list failed'
        return
    }
    if ($out -match [regex]::Escape($script:StoreProductId)) {
        $script:UpdateAvailable = 'yes'
        $script:DistributorState = 'Store published a newer package'
    } elseif ($out -match '(?i)no installed package|no applicable upgrade|no available upgrade|no newer') {
        $script:UpdateAvailable = 'no'
        $script:DistributorState = 'Store channel reports no applicable upgrade'
    } else {
        $script:UpdateAvailable = 'unknown'
        $script:DistributorState = 'WinGet returned neither the product nor a no-upgrade marker'
        Add-Degraded 'WINDOWS_PACKAGE' "WinGet output did not clearly establish Store-channel availability."
    }
    Add-CheckRow 'Store update availability' 'distributor-specific availability' `
        "$($script:DistributorState); update=$($script:UpdateAvailable)" 'INFO'
}

function Read-AppInstallerDescriptor {
    param([string]$Path)
    $result = [pscustomobject]@{
        Valid = $false
        Reason = ''
        Path = $Path
        Kind = ''
        Name = ''
        Version = ''
        Publisher = ''
        Uri = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.Reason = "App Installer descriptor not found: $Path"
        return $result
    }
    try {
        $descriptorItem = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($descriptorItem.Length -gt 1MB) {
            $result.Reason = 'App Installer descriptor exceeds the 1 MiB safety limit.'
            return $result
        }
        $rawXml = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $readerSettings = New-Object System.Xml.XmlReaderSettings
        $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $readerSettings.XmlResolver = $null
        $stringReader = New-Object System.IO.StringReader($rawXml)
        $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $readerSettings)
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($xmlReader)
        $xmlReader.Close()
        $stringReader.Close()
        $mainPackage = $doc.SelectSingleNode('/*[local-name()="AppInstaller"]/*[local-name()="MainPackage"]')
        $mainBundle = $doc.SelectSingleNode('/*[local-name()="AppInstaller"]/*[local-name()="MainBundle"]')
        if (($null -ne $mainPackage) -and ($null -ne $mainBundle)) {
            $result.Reason = 'The .appinstaller file declares both MainPackage and MainBundle; ambiguous descriptor.'
            return $result
        }
        if (($null -eq $mainPackage) -and ($null -eq $mainBundle)) {
            $result.Reason = 'The .appinstaller file has no supported MainPackage or MainBundle element.'
            return $result
        }
        if ($null -ne $mainBundle) {
            $main = $mainBundle
            $result.Kind = 'MainBundle'
        } else {
            $main = $mainPackage
            $result.Kind = 'MainPackage'
        }
        $result.Name = [string]$main.GetAttribute('Name')
        $result.Version = [string]$main.GetAttribute('Version')
        $result.Publisher = [string]$main.GetAttribute('Publisher')
        $result.Uri = [string]$main.GetAttribute('Uri')
    } catch {
        $result.Reason = "Could not parse the App Installer descriptor: $($_.Exception.Message)"
        return $result
    }
    if ([string]::IsNullOrEmpty($script:AppxPackage.Name)) {
        $result.Reason = 'Installed package identity is unavailable; descriptor cannot be matched.'
        return $result
    }
    if ($result.Name -ne $script:AppxPackage.Name) {
        $result.Reason = "Descriptor identity '$($result.Name)' does not match installed package '$($script:AppxPackage.Name)'."
        return $result
    }
    if ($result.Name -ne $script:BundledAppxName) {
        $result.Reason = "Descriptor identity '$($result.Name)' is not the recognized official sideload identity."
        return $result
    }
    if ($result.Publisher -ne $script:AppxPackage.Publisher) {
        $result.Reason = "Descriptor publisher '$($result.Publisher)' does not match installed publisher '$($script:AppxPackage.Publisher)'."
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($result.Publisher) -or ($result.Publisher -notmatch $script:SideloadPublisherPattern)) {
        $result.Reason = "Descriptor publisher '$($result.Publisher)' is not the official Nous Research sideload publisher."
        return $result
    }
    $uri = $null
    if (-not [Uri]::TryCreate($result.Uri, [UriKind]::Absolute, [ref]$uri) -or ($uri.Scheme -ne 'https') -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        $result.Reason = "Descriptor package URI is missing, not absolute, or not HTTPS."
        return $result
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        $result.Reason = "Descriptor package URI embeds credentials (userinfo)."
        return $result
    }
    $proposed = $null
    if (-not [version]::TryParse($result.Version, [ref]$proposed)) {
        $result.Reason = "Descriptor version '$($result.Version)' is not a valid version."
        return $result
    }
    if (($script:InstalledVersion -ne 'unknown') -and ((Compare-VersionStrings $result.Version $script:InstalledVersion) -lt 0)) {
        $result.Reason = "Descriptor version $($result.Version) would downgrade installed v$($script:InstalledVersion)."
        return $result
    }
    $result.Valid = $true
    $result.Reason = 'identity, publisher, signed sideload ownership, HTTPS URI, and non-downgrade version verified'
    return $result
}

function Get-SideloadDescriptorInfo {
    if ($script:Owner -ne 'Sideload MSIX') { return }
    $file = $AppInstallerFile
    if ([string]::IsNullOrWhiteSpace($file)) { $file = $env:HERMES_APPINSTALLER_FILE }
    $script:SideloadDescriptorPath = $file
    if ([string]::IsNullOrWhiteSpace($file)) {
        $script:SideloadDescriptorValid = $false
        $script:SideloadDescriptorReason = 'No verified App Installer descriptor was supplied.'
        $script:UpdateAvailable = 'unknown'
        $script:DistributorState = 'no verified descriptor supplied'
        Add-CheckRow 'Sideload update availability' 'publisher-verified official descriptor' 'not supplied' 'NOT_TESTED'
        Add-Unknown 'Sideload availability is UNKNOWN: no verified descriptor was supplied, so no update is authorized.'
        return
    }
    $descriptor = Read-AppInstallerDescriptor -Path $file
    if (-not $descriptor.Valid) {
        $script:SideloadDescriptorValid = $false
        $script:SideloadDescriptorReason = $descriptor.Reason
        $script:UpdateAvailable = 'unknown'
        $script:DistributorState = 'descriptor rejected'
        Add-Block 'WINDOWS_PACKAGE' "Sideload descriptor rejected: $($descriptor.Reason)"
        Add-CheckRow 'Sideload update availability' 'publisher-verified official descriptor' $descriptor.Reason 'FAIL'
        return
    }
    $script:SideloadDescriptorValid = $true
    $script:SideloadDescriptorReason = $descriptor.Reason
    $script:SideloadDescriptorVersion = $descriptor.Version
    $script:AvailableVersion = $descriptor.Version
    $cmp = Compare-VersionStrings $descriptor.Version $script:InstalledVersion
    if ($cmp -eq 0) {
        $script:UpdateAvailable = 'no'
        $script:DistributorState = 'verified descriptor already current'
    } else {
        $script:UpdateAvailable = 'yes'
        $script:DistributorState = 'verified descriptor supplied'
    }
    Add-Evidence "App Installer descriptor: path=$file kind=$($descriptor.Kind) identity=$($descriptor.Name) version=$($descriptor.Version) publisher=$($descriptor.Publisher) uri=$($descriptor.Uri)"
    Add-CheckRow 'Sideload update availability' 'verified official descriptor, non-downgrade' `
        "kind=$($descriptor.Kind) identity=$($descriptor.Name) version=$($descriptor.Version); $($descriptor.Reason)" 'PASS'
}

# ---------------------------------------------------------------------------
# Backend network / HTTP (each layer reported separately)
# ---------------------------------------------------------------------------
function Test-BackendNetwork {
    if ([string]::IsNullOrWhiteSpace($script:BackendUrl)) {
        Add-CheckRow 'Backend URL' 'verified explicit URL' 'not supplied' 'NOT_TESTED'
        Add-Unknown 'No backend URL was supplied; remote connectivity, authentication and WebSocket are UNKNOWN, not healthy.'
        return
    }
    $uri = [Uri]$script:BackendUrl
    $hostName = $uri.Host
    $port = $uri.Port
    Add-CheckRow 'Backend URL' 'explicit or pre-existing verified URL' "$($script:BackendUrlDisplay) ($($script:BackendUrlSource))" 'PASS'

    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($hostName)
        $script:DnsState = "PASS ($($addresses.Count) address(es))"
    } catch {
        $script:DnsState = 'FAIL'
        Add-Degraded 'NETWORK' "Backend host '$hostName' does not resolve: $($_.Exception.Message)"
    }
    Add-CheckRow 'DNS resolution' 'host resolves' "$($script:DnsState)" $(if ($script:DnsState -like 'PASS*') { 'PASS' } else { 'FAIL' })

    if ($script:DnsState -like 'PASS*') {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $client.BeginConnect($hostName, $port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(4000, $false)
            if ($ok) {
                $client.EndConnect($iar)
                $script:TcpState = 'PASS'
            } else {
                $script:TcpState = 'TIMEOUT'
            }
        } catch {
            $script:TcpState = "FAIL ($($_.Exception.Message))"
        } finally {
            $client.Close()
        }
        Add-CheckRow 'TCP reachability' 'connect to actual host:port' "$hostName`:$port $($script:TcpState)" $(if ($script:TcpState -eq 'PASS') { 'PASS' } else { 'FAIL' })
        if ($script:TcpState -ne 'PASS') {
            Add-Degraded 'NETWORK' "TCP connection to $hostName`:$port failed or timed out."
        }
    } else {
        $script:TcpState = 'NOT_TESTED (DNS failed)'
    }

    if (Test-CommandExists 'tailscale') {
        $exit = Invoke-Native 'tailscale' @('status', '--json')
        if ($exit -eq 0) {
            try {
                $ts = $script:NativeOutput | ConvertFrom-Json
                $script:TailscaleState = "PASS (BackendState=$($ts.BackendState))"
            } catch {
                $script:TailscaleState = 'UNKNOWN (unparseable status)'
            }
        } else {
            $script:TailscaleState = "NOT_TESTED (tailscale exit $exit)"
        }
    } else {
        $script:TailscaleState = 'NOT_TESTED (tailscale CLI not found)'
    }
    Add-CheckRow 'Tailscale/private route' 'route available (separate from HTTP)' "$($script:TailscaleState)" $(if ($script:TailscaleState -like 'PASS*') { 'PASS' } else { 'NOT_TESTED' })
}

function Invoke-StatusProbe {
    if ([string]::IsNullOrWhiteSpace($script:BackendUrl)) { return }
    if ($script:TcpState -ne 'PASS') {
        $script:HttpState = 'NOT_TESTED (TCP failed)'
        Add-CheckRow 'Backend HTTP + JSON' 'Hermes JSON from /api/status' "$($script:HttpState)" 'NOT_TESTED'
        return
    }
    $url = $script:BackendUrl + '/api/status'
    $request = $null
    $response = $null
    $reader = $null
    $body = ''
    try {
        $request = [System.Net.HttpWebRequest]::Create($url)
        $request.Method = 'GET'
        $request.Timeout = 8000
        $request.ReadWriteTimeout = 8000
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'hermes-ops-windows/1.0'
        $response = $request.GetResponse()
        $script:HttpCode = [int]$response.StatusCode
        $script:HttpContentType = [string]$response.ContentType
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $body = $reader.ReadToEnd()
    } catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            $response = $_.Exception.Response
            $script:HttpCode = [int]$response.StatusCode
            $script:HttpContentType = [string]$response.ContentType
            try {
                $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
                $body = $reader.ReadToEnd()
            } catch { $body = '' }
        } else {
            $script:HttpState = 'UNREACHABLE'
            Add-Degraded 'NETWORK' "HTTP GET /api/status failed before a response: $($_.Exception.Message)"
            Add-CheckRow 'Backend HTTP + JSON' 'Hermes JSON from /api/status' 'no HTTP response' 'FAIL'
            Add-Timeline 'NETWORK' 'GET /api/status' 'transport error' $_.Exception.Message
            return
        }
    } catch {
        $script:HttpState = 'ERROR'
        Add-Degraded 'PROTOCOL' "HTTP probe failed: $($_.Exception.Message)"
        Add-CheckRow 'Backend HTTP + JSON' 'Hermes JSON from /api/status' $_.Exception.Message 'FAIL'
        return
    } finally {
        if ($null -ne $reader) { $reader.Close() }
        if ($null -ne $response) { $response.Close() }
    }

    Add-Timeline 'NETWORK' 'GET /api/status' "HTTP $($script:HttpCode)" "content-type=$($script:HttpContentType); bytes=$($body.Length)"
    if (($script:HttpCode -eq 401) -or ($script:HttpCode -eq 403)) {
        $script:HttpState = "AUTH_REQUIRED"
        $script:AuthState = 'AUTH_REQUIRED (not proven)'
        Add-Degraded 'AUTH' "Backend answered HTTP $($script:HttpCode); that proves a listener or gate, not a healthy authenticated Hermes session."
        Add-CheckRow 'Backend HTTP + JSON' 'HTTP 2xx with Hermes JSON' "HTTP $($script:HttpCode); auth not proven" 'FAIL'
        return
    }
    if (($script:HttpCode -lt 200) -or ($script:HttpCode -ge 300)) {
        $script:HttpState = "HTTP_$($script:HttpCode)"
        Add-Degraded 'PROTOCOL' "Backend returned HTTP $($script:HttpCode) from /api/status."
        Add-CheckRow 'Backend HTTP + JSON' 'HTTP 2xx with Hermes JSON' "HTTP $($script:HttpCode)" 'FAIL'
        return
    }

    $markers = 0
    try {
        $data = $body | ConvertFrom-Json -ErrorAction Stop
        $props = @($data.PSObject.Properties.Name)
        foreach ($key in @('auth_required', 'auth_providers', 'gateway_running', 'version', 'components', 'install_id')) {
            if ($props -contains $key) { $markers++ }
        }
        if (($markers -ge 2) -and ($props -contains 'version')) {
            $script:HttpState = 'PASS'
            $script:HttpProtocol = 'hermes-json'
            $script:HttpVersion = [string]$data.version
            $script:HttpAuthRequired = [string]$data.auth_required
            $script:HttpOverall = [string]$data.overall
            if ($script:HttpOverall -match '^(?i)ok$') {
                $script:BackendHealthState = 'PASS'
                Add-CheckRow 'Backend health' 'recognizable Hermes JSON with overall=ok' "overall=$($script:HttpOverall); version=$($script:HttpVersion)" 'PASS'
            } else {
                $script:BackendHealthState = 'FAIL'
                Add-Degraded 'PROTOCOL' "Backend JSON is recognizable but overall status is '$($script:HttpOverall)', not ok."
                Add-CheckRow 'Backend health' 'recognizable Hermes JSON with overall=ok' "overall=$($script:HttpOverall); version=$($script:HttpVersion)" 'FAIL'
            }
            if ($props -contains 'profiles') {
                $profileList = @($data.profiles) | ForEach-Object { [string]$_ }
                Add-Evidence "Backend advertised profiles: $($profileList -join ', ')"
            }
            Add-CheckRow 'Backend HTTP + JSON' 'HTTP 2xx with Hermes JSON' `
                "HTTP 200; version=$($script:HttpVersion); auth_required=$($script:HttpAuthRequired); overall=$($script:HttpOverall)" 'PASS'
            if (($script:HttpAuthRequired -eq 'True') -or ($script:HttpAuthRequired -eq 'true')) {
                $script:AuthState = 'ADVERTISED (session not tested)'
                Add-Unknown 'Backend advertises auth_required=true; no approved Desktop credential was used and no token was scraped.'
            } else {
                $script:AuthState = 'NOT_TESTED'
            }
        } else {
            $script:HttpState = 'WRONG_PAYLOAD'
            $script:HttpProtocol = 'invalid-json-or-shape'
            Add-Degraded 'PROTOCOL' "HTTP 200 from /api/status is not recognizable Hermes status JSON (markers=$markers)."
            Add-CheckRow 'Backend HTTP + JSON' 'HTTP 2xx with Hermes JSON' 'HTTP 200, wrong payload shape' 'FAIL'
        }
    } catch {
        $script:HttpState = 'INVALID_JSON'
        $script:HttpProtocol = 'invalid-json'
        Add-Degraded 'PROTOCOL' "HTTP 200 from /api/status is not valid JSON."
        Add-CheckRow 'Backend HTTP + JSON' 'HTTP 2xx with Hermes JSON' 'HTTP 200, invalid JSON' 'FAIL'
    }
    $script:WebSocketState = 'NOT_TESTED'
    Add-CheckRow 'Authenticated WebSocket' 'authenticated /api/ws handshake' 'not tested (no approved credential path)' 'NOT_TESTED'
    Add-Unknown 'WebSocket/session health is not inferred from HTTP status; it remains NOT_TESTED.'
}

# ---------------------------------------------------------------------------
# Receipt
# ---------------------------------------------------------------------------
function Test-SourceReleaseVerification {
    if (($script:Owner -ne 'Source build') -or (-not $script:UpdateAttempted)) {
        $script:SourceVerification = 'not attempted'
        return
    }
    $issues = @()
    if (($script:UpdateExit -ne 0) -and ($script:UpdateExit -ne 'not run')) {
        $issues += "native updater exited $($script:UpdateExit)"
    }
    if ($script:InstalledVersionAfter -ne $script:StableTargetVersionBefore) {
        $issues += "installed version v$($script:InstalledVersionAfter) does not equal selected stable release v$($script:StableTargetVersionBefore)"
    }
    if (($script:InstalledVersionAfter -eq 'unknown') -or ($script:InstalledVersionAfter -eq $script:InstalledVersion)) {
        $issues += "installed version did not advance from v$($script:InstalledVersion) (after=$($script:InstalledVersionAfter))"
    }
    if ($script:GitHead -ne $script:StableTargetFullBefore) {
        $issues += "installed Git revision $($script:GitHead) does not match selected stable revision $($script:StableTargetFullBefore)"
    }
    if (($script:GitHead -eq 'unknown') -or ($script:GitHead -eq $script:GitHeadBefore)) {
        $issues += "Git revision did not advance from $($script:GitHeadBefore) (after=$($script:GitHead))"
    }
    if ($script:InstallId -ne $script:InstallIdBefore) {
        $issues += "installation identity changed: $($script:InstallIdBefore) -> $($script:InstallId)"
    }
    if ($script:CanonicalCheckout -ne $script:CheckoutBefore) {
        $issues += "checkout changed during update: $($script:CheckoutBefore) -> $($script:CanonicalCheckout)"
    }
    if ($script:HeremesPath -ne $script:CliPathBefore) {
        $issues += "Hermes CLI path changed during update: $($script:CliPathBefore) -> $($script:HeremesPath)"
    }
    if ($script:StableTargetVersion -ne 'unknown' -and $script:StableTargetVersion -ne $script:StableTargetVersionBefore) {
        $issues += "stable target changed during execution: v$($script:StableTargetVersionBefore) -> v$($script:StableTargetVersion)"
    }
    if (($script:StableTargetShort -ne 'unknown') -and ($script:StableTargetShort -ne $script:StableTargetShortBefore)) {
        $issues += "stable target revision changed during execution: $($script:StableTargetShortBefore) -> $($script:StableTargetShort)"
    }
    if ($script:StableTargetFull -ne 'unknown' -and $script:StableTargetFull -ne $script:StableTargetFullBefore) {
        $issues += "stable target full revision changed during execution"
    }
    if ($script:SourceProvenanceOk -ne 'yes') { $issues += 'official provenance/stable channel is no longer proven after update' }
    if ($script:GitDirty -ne 'no') { $issues += "checkout dirty after update (state=$($script:GitDirty))" }
    if ($script:GitIntegrityOk -ne 'yes') { $issues += 'checkout integrity is not proven after update' }

    if ($issues.Count -eq 0) {
        $script:SourceVerification = 'yes'
        Add-CheckRow 'Source release verification' 'exact target version and full Git revision, same identity/checkout' `
            "v$($script:InstalledVersionAfter) @ $($script:GitHead); install=$($script:InstallId); checkout=$($script:CanonicalCheckout)" 'PASS'
    } else {
        $script:SourceVerification = 'no'
        foreach ($issue in $issues) { Add-Degraded 'SOURCE_UPDATE' $issue }
        Add-CheckRow 'Source release verification' 'exact target version and full Git revision, same identity/checkout' ($issues -join '; ') 'FAIL'
    }
}

function Get-UpdateReceipt {
    param([string]$CorrelationId = '')
    $hermesHome = Get-HermesHomePath
    $receiptDir = Join-Path $hermesHome 'logs\update_receipts'
    if (-not (Test-Path -LiteralPath $receiptDir -PathType Container)) {
        $script:ReceiptPath = 'none'
        $script:ReceiptCheck = if ($CorrelationId) { 'FAIL' } else { 'NOT_TESTED' }
        if ($CorrelationId) {
            Add-Degraded 'RECEIPT' "No update receipt directory exists for correlation '$CorrelationId'."
        }
        Add-CheckRow 'Update receipt / follow-ups' 'update_*.json present' 'no receipt directory' $script:ReceiptCheck
        return
    }

    $receiptFiles = @(Get-ChildItem -LiteralPath $receiptDir -Filter 'update_*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)
    $latestAnyPath = Join-Path $receiptDir 'latest.json'
    $selected = $null
    $selectedData = $null
    $parseError = ''

    if (-not [string]::IsNullOrWhiteSpace($CorrelationId)) {
        foreach ($file in $receiptFiles) {
            try {
                $data = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($null -ne $data -and ([string]$data.correlation_id) -eq $CorrelationId) {
                    $selected = $file
                    $selectedData = $data
                    break
                }
            } catch {
                $parseError = $_.Exception.Message
            }
        }
        if ($null -eq $selected) {
            $script:ReceiptPath = 'none'
            $script:ReceiptCheck = 'FAIL'
            $script:ReceiptContractValid = 'no'
            if ($parseError) {
                Add-Degraded 'RECEIPT' "Update receipt files include an unreadable receipt and none matched correlation '$CorrelationId': $parseError"
            } else {
                Add-Degraded 'RECEIPT' "No native update receipt matched operation correlation '$CorrelationId'; historical or unrelated receipts are not current evidence."
            }
            Add-CheckRow 'Update receipt / follow-ups' 'exactly one receipt for this operation' "correlation=$CorrelationId; matched=none" 'FAIL'
            return
        }
    } else {
        $selected = $receiptFiles | Select-Object -First 1
        if (Test-Path -LiteralPath $latestAnyPath -PathType Leaf) {
            $latestKind = ''
            try {
                $latestAny = Get-Content -LiteralPath $latestAnyPath -Raw -ErrorAction Stop | ConvertFrom-Json
                $latestKind = [string]$latestAny.kind
            } catch {
                $latestKind = 'unreadable'
            }
            if (($null -eq $selected) -and ($latestKind -ne 'plugin-check') -and ($latestKind -ne 'unreadable')) {
                $selected = Get-Item -LiteralPath $latestAnyPath
            } elseif (($null -ne $selected) -and ($latestKind -ne 'plugin-check') -and ($latestKind -ne 'unreadable') -and
                      (Get-Item -LiteralPath $latestAnyPath).LastWriteTime -gt $selected.LastWriteTime) {
                $selected = Get-Item -LiteralPath $latestAnyPath
            }
        }
        if ($null -eq $selected) {
            $script:ReceiptPath = 'none'
            $script:ReceiptCheck = 'NOT_TESTED'
            Add-CheckRow 'Update receipt / follow-ups' 'update_*.json or latest.json present' 'none' 'NOT_TESTED'
            return
        }
    }

    $script:ReceiptPath = $selected.FullName
    if ($null -eq $selectedData) {
        try {
            $selectedData = Get-Content -LiteralPath $selected.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {
            $script:ReceiptCheck = 'FAIL'
            $script:ReceiptContractValid = 'no'
            Add-Degraded 'RECEIPT' "Selected update receipt is unreadable: $($_.Exception.Message)"
            Add-CheckRow 'Update receipt / follow-ups' 'readable upstream receipt schema' 'unreadable JSON' 'FAIL'
            return
        }
    }

    $issues = @()
    if ($selectedData -is [System.Array]) {
        $issues += 'receipt root is an array, not an upstream receipt object'
    } elseif ($null -eq $selectedData) {
        $issues += 'receipt is empty'
    } else {
        $schema = 0
        if (-not [int]::TryParse([string]$selectedData.schema, [ref]$schema) -or ($schema -ne 1)) {
            $issues += "unsupported schema '$($selectedData.schema)'"
        }
        $kind = [string]$selectedData.kind
        if ($kind -eq 'plugin-check') { $issues += 'kind=plugin-check is not an update receipt' }
        $updateId = [string]$selectedData.update_id
        if ($updateId -notmatch '^[0-9a-fA-F]{32}$') { $issues += "update_id '$updateId' is not a native update id" }
        $script:ReceiptCorrelation = [string]$selectedData.correlation_id
        if ([string]::IsNullOrWhiteSpace($script:ReceiptCorrelation)) { $script:ReceiptCorrelation = 'missing' }
        if ($CorrelationId -and ($script:ReceiptCorrelation -ne $CorrelationId)) {
            $issues += "correlation_id '$($script:ReceiptCorrelation)' does not match '$CorrelationId'"
        }
        $script:ReceiptOutcome = [string]$selectedData.outcome
        $finished = [string]$selectedData.finished_at
        $finishedParsed = [DateTimeOffset]::MinValue
        if ([string]::IsNullOrWhiteSpace($finished) -or -not [DateTimeOffset]::TryParse($finished, [ref]$finishedParsed)) {
            $issues += 'finished_at is missing or invalid'
        }
        $started = [string]$selectedData.started_at
        $startedParsed = [DateTimeOffset]::MinValue
        if ([string]::IsNullOrWhiteSpace($started) -or -not [DateTimeOffset]::TryParse($started, [ref]$startedParsed)) {
            $issues += 'started_at is missing or invalid'
        } elseif ($finishedParsed -ne [DateTimeOffset]::MinValue -and $finishedParsed -lt $startedParsed) {
            $issues += 'finished_at precedes started_at'
        }
        $exitCodeProp = $selectedData.PSObject.Properties['exit_code']
        if (($null -ne $exitCodeProp) -and ([string]$exitCodeProp.Value -ne '0')) {
            $issues += "exit_code '$($exitCodeProp.Value)' is not zero"
        }

        $followupProp = $selectedData.PSObject.Properties['followups']
        if ($null -ne $followupProp) {
            if ($followupProp.Value -isnot [System.Array]) {
                $issues += 'followups is not an upstream array'
                $script:ReceiptFollowupCount = 0
                $script:ReceiptFollowupText = ''
            } else {
                $followups = @($followupProp.Value)
                $script:ReceiptFollowupCount = $followups.Count
                $reasons = @()
                foreach ($f in $followups) {
                    if ($null -ne $f.reason) { $reasons += [string]$f.reason } else { $reasons += [string]$f }
                    if (([string]$f.step) -in @('launchers', 'build', 'completion')) { $script:ReceiptBuildFailure = 'yes' }
                }
                $script:ReceiptFollowupText = ($reasons -join '; ')
            }
        } else {
            $script:ReceiptFollowupCount = 0
            $script:ReceiptFollowupText = ''
        }

        if ($null -ne $selectedData.gateway_restart) {
            $gateway = $selectedData.gateway_restart
            if ($gateway -isnot [System.Management.Automation.PSCustomObject]) {
                $issues += 'gateway_restart is not an object'
            } else {
                $incompleteProp = $gateway.PSObject.Properties['incomplete']
                if (($null -eq $incompleteProp) -or ($incompleteProp.Value -isnot [bool])) {
                    $issues += 'gateway_restart.incomplete is missing or not boolean'
                } else {
                    $script:ReceiptGatewayIncomplete = [string]$incompleteProp.Value
                }
            }
        } else {
            $issues += 'gateway_restart is missing'
            $script:ReceiptGatewayIncomplete = 'missing'
        }

        if ($null -ne $selectedData.desktop) {
            if ($null -ne $selectedData.desktop.status) { $script:DesktopBuildState = [string]$selectedData.desktop.status }
            elseif ($null -ne $selectedData.desktop.result) { $script:DesktopBuildState = [string]$selectedData.desktop.result }
        }
        $stagesProp = $selectedData.PSObject.Properties['stages']
        if ($null -ne $stagesProp -and $stagesProp.Value -is [System.Array]) {
            foreach ($stage in @($stagesProp.Value)) {
                if ([string]$stage.name -eq 'build') {
                    if ([string]$stage.outcome -eq 'failed') { $script:ReceiptBuildFailure = 'yes' }
                }
            }
        }
        $argvProp = $selectedData.PSObject.Properties['argv']
        if ($null -ne $argvProp) {
            if ($argvProp.Value -isnot [System.Array]) {
                $issues += 'argv is not an array'
            } else {
                $argv = @($argvProp.Value | ForEach-Object { [string]$_ })
                if (($argv -notcontains 'update') -or (($argv -notcontains '--yes') -and ($argv -notcontains '-y'))) {
                    $issues += 'argv does not prove the native update --yes command'
                }
            }
        }

        if ($CorrelationId) {
            if (($null -eq $selectedData.post_update) -or ($selectedData.post_update -isnot [System.Management.Automation.PSCustomObject])) {
                $issues += 'post_update completion evidence is missing'
            } else {
                $postSha = [string]$selectedData.post_update.sha
                $postVersion = [string]$selectedData.post_update.version
                $postSource = [string]$selectedData.post_update.source
                if (($postSha -notmatch '^[0-9a-fA-F]{40}$') -or ($postSha.ToLowerInvariant() -ne $script:StableTargetFullBefore)) {
                    $issues += "post_update.sha '$postSha' does not equal target '$($script:StableTargetFullBefore)'"
                }
                if ($postVersion -ne $script:StableTargetVersionBefore) {
                    $issues += "post_update.version '$postVersion' does not equal target '$($script:StableTargetVersionBefore)'"
                }
                if ($postSource -ne 'git') {
                    $issues += "post_update.source '$postSource' is not a managed Git source"
                }
            }
            if (($null -ne $selectedData.pre_update) -and ($selectedData.pre_update -is [System.Management.Automation.PSCustomObject])) {
                $preSha = [string]$selectedData.pre_update.sha
                if ($preSha -ne $script:GitHeadBefore) {
                    $issues += "pre_update.sha '$preSha' does not match pre-update HEAD '$($script:GitHeadBefore)'"
                }
            } else {
                $issues += 'pre_update identity is missing'
            }
        }
    }

    $script:ReceiptContractValid = if ($issues.Count -eq 0) { 'yes' } else { 'no' }
    if ($script:ReceiptOutcome -notmatch '^(?i)(ok|success)$') {
        $issues += "outcome '$($script:ReceiptOutcome)' is not success"
    }
    if (($script:ReceiptFollowupCount -gt 0) -or ($script:ReceiptGatewayIncomplete -eq 'True') -or ($script:ReceiptGatewayIncomplete -eq 'true')) {
        $issues += "receipt has $($script:ReceiptFollowupCount) unresolved follow-up(s)$(if ($script:ReceiptFollowupText) { ': ' + $script:ReceiptFollowupText }) and gateway_restart.incomplete=$($script:ReceiptGatewayIncomplete)"
    }
    if ($CorrelationId -and ($script:ReceiptCorrelation -ne $CorrelationId)) {
        $issues += "receipt correlation '$($script:ReceiptCorrelation)' does not match operation '$CorrelationId'"
    }

    if ($CorrelationId) { $script:ReceiptFresh = 'yes' }
    else { $script:ReceiptFresh = $(if ($selected.LastWriteTime -ge $script:StartedAt.AddSeconds(-5)) { 'yes' } else { 'no' }) }

    if ($issues.Count -eq 0) {
        $script:ReceiptCheck = 'PASS'
    } else {
        $script:ReceiptCheck = 'FAIL'
        foreach ($issue in $issues) {
            if ($issue -match '(?i)follow-up|gateway_restart\.incomplete') {
                Add-Degraded 'RECEIPT' "Native update receipt: $issue"
            } elseif ($issue -match '(?i)correlation') {
                Add-Degraded 'RECEIPT' "Native receipt correlation mismatch: $issue"
            } else {
                Add-Degraded 'RECEIPT' "Native update receipt contract failed: $issue"
            }
        }
    }
    Add-CheckRow 'Update receipt / follow-ups' 'current correlated terminal success, zero follow-ups, gateway complete' `
        "correlation=$($script:ReceiptCorrelation); outcome=$($script:ReceiptOutcome) followups=$($script:ReceiptFollowupCount) gateway_incomplete=$($script:ReceiptGatewayIncomplete) fresh=$($script:ReceiptFresh) build_failure=$($script:ReceiptBuildFailure)" $script:ReceiptCheck
    Add-Timeline 'RECEIPT' "read $($selected.FullName)" $script:ReceiptOutcome (Limit-Text $script:ReceiptFollowupText 4 400)
}

# ---------------------------------------------------------------------------
# Updates (owner-specific)
# ---------------------------------------------------------------------------
function Invoke-SourceUpdate {
    if ($script:Owner -ne 'Source build') { return }
    if ([string]::IsNullOrEmpty($script:HeremesPath)) {
        Add-Block 'WINDOWS_PACKAGE' 'Source owner detected but no usable hermes CLI was found.'
        return
    }
    Get-SourceVersion
    Get-SourceUpdateAvailability
    Get-SourceInstallIdentity
    Test-SourceProvenance
    if (($script:SourceProvenanceOk -ne 'yes') -or ($script:SourceChannel -ne 'stable') -or ($script:UpdateCheckChannel -ne 'stable')) {
        Add-Block 'PRECHECK' 'Source provenance or stable channel is not proven immediately before update; refusing to run the source updater.'
        return
    }
    if ($script:UpdateAvailable -ne 'yes') {
        Add-Block 'PRECHECK' "No verified stable update is available (state=$($script:UpdateAvailable)); refusing to invoke the updater."
        return
    }
    if (-not (Resolve-SourceTargetRevision)) {
        return
    }

    $planExit = Invoke-Native $script:HeremesPath @('update', '--plan')
    Add-Timeline 'WINDOWS_PACKAGE' 'hermes update --plan' "exit $planExit" (($script:NativeOutput -split "`r?`n" | Select-Object -First 8) -join ' ')
    Add-Evidence "Update plan: $(Limit-Text $script:NativeOutput 10 900)"
    if ($planExit -ne 0) {
        Add-Block 'PRECHECK' "hermes update --plan failed (exit $planExit); refusing to update blindly."
        return
    }
    $planInstall = [regex]::Match($script:NativeOutput, '(?im)^\s*Install:\s*git\s+\(v(?<version>\d+\.\d+\.\d+)\s+@\s+(?<sha>[0-9a-fA-F]{7,40})\)')
    if ($planInstall.Success) {
        $planSha = $planInstall.Groups['sha'].Value.ToLowerInvariant()
        if (-not $script:GitHead.StartsWith($planSha)) {
            Add-Block 'PRECHECK' "Update plan revision $planSha does not match the installed Git HEAD $($script:GitHead)."
            return
        }
    }

    Capture-SourceBaseline
    $script:UpdateCorrelationId = 'hermes-ops-win-' + [guid]::NewGuid().ToString('N')
    $updateArgs = @('update', '--yes')
    if ($NoBackup) { $updateArgs += '--no-backup' }
    $script:UpdateAttempted = $true
    $script:UpdateNeeded = $true
    Add-Timeline 'WINDOWS_PACKAGE' ("hermes " + ($updateArgs -join ' ')) 'started' "single official updater invocation; correlation=$($script:UpdateCorrelationId)"
    $hadCorrelation = Test-Path Env:HERMES_UPDATE_CORRELATION_ID
    $previousCorrelation = $env:HERMES_UPDATE_CORRELATION_ID
    try {
        $env:HERMES_UPDATE_CORRELATION_ID = $script:UpdateCorrelationId
        $exit = Invoke-Native $script:HeremesPath $updateArgs
    } finally {
        if ($hadCorrelation) {
            $env:HERMES_UPDATE_CORRELATION_ID = $previousCorrelation
        } else {
            Remove-Item Env:HERMES_UPDATE_CORRELATION_ID -ErrorAction SilentlyContinue
        }
    }
    $script:UpdateExit = $exit
    $script:UpdateOutput = $script:NativeOutput
    $script:Mutations = 'hermes ' + ($updateArgs -join ' ')
    Add-Timeline 'WINDOWS_PACKAGE' ("hermes " + ($updateArgs -join ' ')) "exit $exit" (Limit-Text $script:UpdateOutput 8 600)
    Add-Evidence "Updater output (bounded): $(Limit-Text $script:UpdateOutput 20 1200)"
}

function Get-DesktopReleaseRoot {
    if ([string]::IsNullOrWhiteSpace($script:SourceCheckout)) { return '' }
    return (Join-Path $script:SourceCheckout 'apps\desktop\release')
}

function Test-DesktopBuildArtifact {
    if ($script:Owner -ne 'Source build') { return }
    $desktopDir = Join-Path $script:SourceCheckout 'apps\desktop'
    if (-not (Test-Path -LiteralPath $desktopDir -PathType Container)) {
        $script:DesktopBuildExpected = 'no'
        $script:DesktopBuildVerified = 'not applicable'
        $script:DesktopBuildState = 'not applicable'
        Add-CheckRow 'Desktop build' 'source Desktop present' 'no Desktop workspace in checkout' 'NOT_TESTED'
        return
    }
    $script:DesktopBuildExpected = 'yes'
    $releaseRoot = Get-DesktopReleaseRoot
    $candidates = @('win-unpacked', 'win-arm64-unpacked', 'win-ia32-unpacked')
    $matching = @()
    $observed = @()
    foreach ($name in $candidates) {
        $root = Join-Path $releaseRoot $name
        $exe = Join-Path $root 'Hermes.exe'
        $stampPath = Join-Path $root 'resources\install-stamp.json'
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        $observed += "$name (no current stamp)"
        if (-not (Test-Path -LiteralPath $stampPath -PathType Leaf)) { continue }
        try {
            $stamp = Get-Content -LiteralPath $stampPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $commit = [string]$stamp.commit
            if (($commit -match '^[0-9a-fA-F]{40}$') -and ($commit.ToLowerInvariant() -eq $script:StableTargetFullBefore)) {
                $matching += $root
                $observed += "$name (commit=$commit)"
            } else {
                $observed += "$name (stale commit=$commit)"
            }
        } catch {
            $observed += "$name (unreadable stamp)"
        }
    }
    if ($matching.Count -ge 1) {
        $script:DesktopBuildVerified = 'verified'
        $script:DesktopBuildState = 'verified'
        $script:DesktopArtifactPath = $matching[0]
        Add-CheckRow 'Desktop build' 'packaged app stamped at exact target commit' "verified; $($matching[0])" 'PASS'
    } else {
        $script:DesktopBuildVerified = 'unverified'
        $script:DesktopBuildState = 'unverified'
        Add-CheckRow 'Desktop build' 'packaged app stamped at exact target commit' (($observed -join '; ') -replace '^$', 'no packaged app artifact') 'FAIL'
    }
}

function Test-DesktopBuildUnlocked {
    $releaseRoot = Get-DesktopReleaseRoot
    if ([string]::IsNullOrWhiteSpace($releaseRoot)) { return $false }
    try {
        $holders = @()
        foreach ($process in @(Get-Process -ErrorAction Stop)) {
            try { $processPath = $process.Path } catch { continue }
            if ($processPath -and ($processPath.StartsWith($releaseRoot, [StringComparison]::OrdinalIgnoreCase))) {
                $holders += $process
            }
        }
    } catch {
        Add-Degraded 'WINDOWS_PACKAGE' "Desktop build output locks could not be checked: $($_.Exception.Message)"
        return $false
    }
    if ($holders.Count -gt 0) {
        $details = (($holders | Select-Object -First 5 | ForEach-Object { "pid=$($_.Id) path=$($_.Path)" }) -join '; ')
        Add-Degraded 'WINDOWS_PACKAGE' "A running Desktop process is holding Desktop build output ($details); no repair or process kill was performed."
        return $false
    }
    return $true
}

function Invoke-DesktopRepairIfNeeded {
    if (($script:Owner -ne 'Source build') -or (-not $script:UpdateAttempted)) { return }
    if (($script:UpdateExit -ne 0) -or ($script:SourceVerification -ne 'yes')) { return }
    if (($script:ReceiptContractValid -ne 'yes') -or ($script:ReceiptOutcome -notmatch '^(?i)(ok|success)$')) { return }
    $evidence = $false
    if ($script:ReceiptBuildFailure -eq 'yes') { $evidence = $true }
    if ($script:UpdateOutput -match '(?i)Desktop app build owed|desktop[^\r\n]*(fail|missing|not built|build error)') { $evidence = $true }
    if (-not $evidence) { return }
    if (-not (Test-DesktopBuildUnlocked)) { return }
    Add-Warning 'Current-operation receipt/output proves the native update completed but the Desktop build is owed; running the documented headless repair once.'
    $repairExit = Invoke-Native $script:HeremesPath @('desktop', '--build-only', '--force-build')
    $script:DesktopRepairRun = 'yes'
    $script:DesktopRepairResult = "exit $repairExit"
    $script:Mutations = $script:Mutations + '; hermes desktop --build-only --force-build'
    Add-Timeline 'WINDOWS_PACKAGE' 'hermes desktop --build-only --force-build' "exit $repairExit" (Limit-Text $script:NativeOutput 8 500)
}

function Invoke-StoreUpdate {
    if ($script:Owner -ne 'Microsoft Store') { return }
    if (-not (Test-CommandExists 'winget')) {
        Add-Block 'WINDOWS_PACKAGE' 'WinGet is unavailable; no Store update can be attempted.'
        return
    }
    $updateArgs = @('upgrade', '--id', $script:StoreProductId, '--exact', '--source', 'msstore',
              '--silent', '--accept-source-agreements', '--accept-package-agreements')
    $script:UpdateAttempted = $true
    $script:UpdateNeeded = $true
    Add-Timeline 'WINDOWS_PACKAGE' ("winget " + ($updateArgs -join ' ')) 'started' 'exact Store product ID'
    $exit = Invoke-Native 'winget' $updateArgs
    $script:UpdateExit = $exit
    $script:UpdateOutput = $script:NativeOutput
    $script:Mutations = 'winget upgrade --id ' + $script:StoreProductId + ' --exact --source msstore'
    Add-Timeline 'WINDOWS_PACKAGE' ("winget " + ($updateArgs -join ' ')) "exit $exit" (Limit-Text $script:UpdateOutput 8 600)
    Add-Evidence "WinGet output (bounded): $(Limit-Text $script:UpdateOutput 20 1200)"

    if ($script:UpdateOutput -match '(?i)no applicable upgrade|no newer package|already installed|no available upgrade') {
        $script:DistributorState = 'NO_APPLICABLE_UPGRADE'
        $script:UpdateNeeded = $false
        $script:UpdateAttempted = $false
    }
    $newPackages = @(Get-AppxPackage -Name $script:StoreAppxName -ErrorAction SilentlyContinue)
    if ($newPackages.Count -eq 1) {
        $script:InstalledVersionAfter = $newPackages[0].Version.ToString()
        $script:AppxPackage = $newPackages[0]
    }
    if (($exit -ne 0) -and ($script:UpdateOutput -notmatch '(?i)no applicable upgrade|no newer package|already installed')) {
        if ($script:UpdateOutput -match '0x80073D02|0x80073D0A|being used|in use|close the app') {
            Add-Block 'WINDOWS_PACKAGE' "The Store package appears to be in use. No process was killed. Close Hermes gracefully with operator authorization, then rerun."
            $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(Hermes|hermes)' } |
                Select-Object -First 10 Id, ProcessName, Path)
            foreach ($p in $procs) { Add-Evidence "Possibly relevant process: pid=$($p.Id) name=$($p.ProcessName) path=$($p.Path)" }
        }
    }
}

function Invoke-SideloadUpdate {
    if ($script:Owner -ne 'Sideload MSIX') { return }
    if (-not $script:SideloadDescriptorValid) {
        Add-Block 'PRECHECK' "Sideload update is not authorized: $($script:SideloadDescriptorReason)"
        return
    }
    Get-AppxInfo
    if (($script:AppxIssue -ne '') -or ($script:AppxOwnerCandidate -ne 'Sideload MSIX')) {
        Add-Block 'PRECHECK' "Installed package ownership changed or became ambiguous before update: $($script:AppxIssue)"
        return
    }
    $file = $script:SideloadDescriptorPath
    $descriptor = Read-AppInstallerDescriptor -Path $file
    if (-not $descriptor.Valid) {
        Add-Block 'PRECHECK' "Sideload descriptor changed or became invalid: $($descriptor.Reason)"
        return
    }
    $script:UpdateAttempted = $true
    $script:UpdateNeeded = $true
    try {
        Add-Timeline 'WINDOWS_PACKAGE' 'Add-AppxPackage -AppInstallerFile' 'started' $file
        Add-AppxPackage -AppInstallerFile $file -ErrorAction Stop
        $script:UpdateExit = 0
        $script:Mutations = 'Add-AppxPackage -AppInstallerFile ' + $file
        Add-Timeline 'WINDOWS_PACKAGE' 'Add-AppxPackage -AppInstallerFile' 'exit 0' "descriptor version $($descriptor.Version)"
    } catch {
        $msg = $_.Exception.Message
        $script:UpdateExit = 1
        $script:UpdateOutput = $msg
        Add-Timeline 'WINDOWS_PACKAGE' 'Add-AppxPackage -AppInstallerFile' 'failed' (Limit-Text $msg 6 500)
        if ($msg -match '0x80073D02|being used|in use|close') {
            Add-Block 'WINDOWS_PACKAGE' 'The signed package is in use. No process was killed; close Hermes gracefully and rerun.'
        } elseif ($msg -match '(?i)0x80072|0x800c|network|name resolution|unreachable|connection|timed out|ssl|tls') {
            Add-Block 'WINDOWS_PACKAGE' "Official descriptor feed was unavailable: $msg. No fallback source or installer is permitted."
        } elseif ($msg -match '(?i)0x800b|signature|certificate|trust|publisher') {
            Add-Block 'WINDOWS_PACKAGE' "Signed package validation failed: $msg. No fallback source or installer is permitted."
        } else {
            Add-Degraded 'WINDOWS_PACKAGE' "Sideload package installation failed: $msg"
        }
    }
}

# ---------------------------------------------------------------------------
# Post-update package verification
# ---------------------------------------------------------------------------
function Test-PostUpdatePackage {
    if (-not $script:UpdateAttempted) {
        $script:PostPackageVerified = 'not applicable'
        return
    }
    if (($script:Owner -ne 'Microsoft Store') -and ($script:Owner -ne 'Sideload MSIX')) { return }
    $problems = @()
    if ($script:AppxIssue -ne '') {
        Add-Block 'WINDOWS_PACKAGE' "Post-update package ownership is ambiguous or mismatched: $($script:AppxIssue)"
        $script:PostPackageVerified = 'no'
        Add-CheckRow 'Post-update package verification' 'exactly one supported package with expected ownership' $script:AppxIssue 'FAIL'
        return
    }
    if ($script:AppxCount -ne 1) {
        $problems += "expected exactly one supported package, observed $($script:AppxCount)."
    } elseif ($script:AppxOwnerCandidate -ne $script:Owner) {
        $problems += "package ownership changed to '$($script:AppxOwnerCandidate)' (expected '$($script:Owner)')."
    }
    $expectedName = $(if ($script:Owner -eq 'Microsoft Store') { $script:StoreAppxName } else { $script:BundledAppxName })
    if (($null -ne $script:AppxPackage) -and ($script:AppxPackage.Name -ne $expectedName)) {
        $problems += "installed package identity '$($script:AppxPackage.Name)' does not match expected '$expectedName'."
    }

    $afterText = [string]$script:InstalledVersionAfter
    $after = $null
    $before = $null
    if ([string]::IsNullOrWhiteSpace($afterText) -or ($afterText -in @('absent', 'unknown', 'not applicable'))) {
        $problems += "expected package version is missing or invalid ('$afterText')."
    } elseif (-not [version]::TryParse($afterText, [ref]$after)) {
        $problems += "installed version '$afterText' is not valid."
    } else {
        if ([version]::TryParse([string]$script:InstalledVersion, [ref]$before)) {
            if ($after.CompareTo($before) -lt 0) {
                $problems += "installed version $afterText downgraded from v$($script:InstalledVersion)."
            } elseif ($after.CompareTo($before) -eq 0) {
                $problems += "installed version did not advance from v$($script:InstalledVersion)."
            }
        }
        if ($script:Owner -eq 'Sideload MSIX') {
            $target = $null
            if ([version]::TryParse([string]$script:SideloadDescriptorVersion, [ref]$target)) {
                if ($after.CompareTo($target) -lt 0) {
                    $problems += "installed version $afterText is below validated descriptor target $($script:SideloadDescriptorVersion)."
                }
            } else {
                $problems += 'validated descriptor target version is unavailable.'
            }
        } elseif ($script:Owner -eq 'Microsoft Store') {
            if ($script:DistributorState -eq 'NO_APPLICABLE_UPGRADE') {
                $problems += 'Store distributor reported no applicable upgrade during an attempted update.'
            }
        }
    }

    if ($problems.Count -gt 0) {
        $script:PostPackageVerified = 'no'
        foreach ($problem in $problems) { Add-Degraded 'WINDOWS_PACKAGE' $problem }
        Add-CheckRow 'Post-update package verification' 'expected package present, one owner, valid non-downgrade version' ($problems -join ' ') 'FAIL'
    } else {
        $script:PostPackageVerified = 'yes'
        Add-CheckRow 'Post-update package verification' 'expected package present, one owner, valid non-downgrade version' `
            "owner=$($script:AppxOwnerCandidate); version=$afterText" 'PASS'
    }
}

# ---------------------------------------------------------------------------
# Decision
# ---------------------------------------------------------------------------
function Set-CheckVerdict {
    if ($script:Blocks.Count -gt 0) {
        $script:Status = 'BLOCKED'
        $script:ExitCode = 2
        $script:Summary = ($script:Blocks[0] -split '\|', 2)[1]
    } elseif ($script:Degraded.Count -gt 0) {
        $script:Status = 'DEGRADED'
        $script:ExitCode = 1
        $script:Summary = ($script:Degraded[0] -split '\|', 2)[1]
    } elseif (($script:Owner -eq 'Sideload MSIX') -and (-not $script:SideloadDescriptorValid)) {
        $script:Status = 'UNKNOWN'
        $script:ExitCode = 1
        $script:Summary = 'Sideload owner recognized, but package availability is unknown without a verified descriptor.'
    } elseif ([string]::IsNullOrWhiteSpace($script:BackendUrl)) {
        $script:Status = 'UNKNOWN'
        $script:ExitCode = 1
        $script:Summary = 'Local package checks passed, but remote connectivity is unknown because no backend URL was supplied.'
    } else {
        $script:Status = 'HEALTHY'
        $script:ExitCode = 0
        if ($script:UpdateAvailable -eq 'yes') {
            $script:Summary = "Local package/backend checks passed; an owner-specific update is available."
        } else {
            $script:Summary = 'All locally verifiable Windows checks passed.'
        }
    }
    Add-Unknown 'Authenticated Desktop session and WebSocket were not exercised; they are not inferred from HTTP status.'
    Add-Works 'Windows version, PowerShell, owner detection, package/CLI evidence and backend transport layers were inspected read-only.'
    Add-Affected 'No package, process, service or configuration was changed during check.'
}

function Set-UpdateVerdict {
    $problems = 0
    $updaterFailed = $false
    if ($script:Blocks.Count -gt 0) {
        if ($script:UpdateAttempted -and ($script:Owner -eq 'Source build')) {
            if (($script:UpdateExit -ne 0) -and ($script:UpdateExit -ne 'not run')) {
                $script:Status = 'FAILED'
                $script:Summary = "Native updater exited $($script:UpdateExit); post-update verification also found: $(($script:Blocks[0] -split '\|', 2)[1])"
            } else {
                $script:Status = 'PARTIAL'
                $script:Summary = "Update ran, but post-update verification found: $(($script:Blocks[0] -split '\|', 2)[1])"
            }
            $script:ExitCode = 1
        } else {
            $script:Status = 'BLOCKED'
            $script:ExitCode = 2
            $script:Summary = ($script:Blocks[0] -split '\|', 2)[1]
            if (-not $script:UpdateAttempted) {
                Add-Unknown 'No update was attempted after the blocker; the pre-existing package state remains.'
            }
        }
        return
    }

    if ($script:UpdateAttempted) {
        if (($script:UpdateExit -ne 0) -and ($script:UpdateExit -ne 'not run') -and ($script:DistributorState -ne 'NO_APPLICABLE_UPGRADE')) {
            $problems++
            $updaterFailed = $true
            Add-Degraded 'WINDOWS_PACKAGE' "Owner-specific updater exited $($script:UpdateExit); no retry was attempted."
        }
        if (($script:InstalledVersionAfter -eq 'unknown') -or ($script:InstalledVersionAfter -eq $script:InstalledVersion)) {
            if ($script:DistributorState -ne 'NO_APPLICABLE_UPGRADE') {
                $problems++
                Add-Degraded 'WINDOWS_PACKAGE' "Installed version did not advance from v$($script:InstalledVersion) (after=$($script:InstalledVersionAfter))."
            }
        }
        if ((($script:Owner -eq 'Microsoft Store') -or ($script:Owner -eq 'Sideload MSIX')) -and ($script:PostPackageVerified -ne 'yes')) {
            $problems++
            Add-Degraded 'WINDOWS_PACKAGE' "Post-update package verification is '$($script:PostPackageVerified)', not verified success."
        }
        if ($script:Owner -eq 'Source build') {
            if ($script:SourceVerification -ne 'yes') {
                $problems++
                Add-Degraded 'SOURCE_UPDATE' "Exact source release verification is '$($script:SourceVerification)', not verified success."
            }
            if (($script:ReceiptContractValid -ne 'yes') -or ($script:ReceiptCheck -ne 'PASS')) {
                $problems++
                Add-Degraded 'RECEIPT' 'Native source update receipt is not a clean, complete, correlated success.'
            }
            if (([string]::IsNullOrWhiteSpace($script:UpdateCorrelationId)) -or ($script:ReceiptCorrelation -ne $script:UpdateCorrelationId)) {
                $problems++
                Add-Degraded 'RECEIPT' "Receipt correlation '$($script:ReceiptCorrelation)' does not match current operation '$($script:UpdateCorrelationId)'."
            }
            if ($script:DesktopBuildVerified -ne 'verified') {
                $problems++
                Add-Degraded 'WINDOWS_PACKAGE' "Desktop build verification is '$($script:DesktopBuildVerified)', not verified."
            }
            if ($script:DesktopRepairRun -eq 'yes' -and $script:DesktopRepairResult -ne 'exit 0') {
                $problems++
                Add-Degraded 'WINDOWS_PACKAGE' "Headless Desktop build repair failed ($($script:DesktopRepairResult))."
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($script:BackendUrl)) {
        $problems++
        Add-Degraded 'NETWORK' 'No backend URL was supplied; VM connectivity remains UNKNOWN after update.'
    } elseif ($script:HttpState -ne 'PASS') {
        $problems++
        Add-Degraded 'PROTOCOL' "Post-update backend HTTP check is '$($script:HttpState)' (HTTP $($script:HttpCode))."
    } elseif ($script:BackendHealthState -ne 'PASS') {
        $problems++
        Add-Degraded 'PROTOCOL' "Post-update backend health is '$($script:BackendHealthState)' (overall=$($script:HttpOverall))."
    }
    if ($script:WebSocketState -ne 'PASS') {
        Add-Unknown 'Authenticated WebSocket/session remains NOT_TESTED; HTTP success is not Desktop connection proof.'
    }
    if ($script:Degraded.Count -gt 0) { $problems++ }

    if ($updaterFailed) {
        $script:Status = 'FAILED'
        $script:ExitCode = 1
        $script:Summary = "Owner-specific updater exited $($script:UpdateExit); no retry was attempted and verification is incomplete."
    } elseif ($script:UpdateAttempted -and ($script:UpdateExit -eq 0) -and ($problems -eq 0)) {
        $script:Status = 'UPDATED'
        $script:ExitCode = 0
        $script:Summary = 'Native stable source update and all independently verifiable checks passed.'
    } elseif ($script:UpdateAttempted) {
        $script:Status = 'PARTIAL'
        $script:ExitCode = 1
        $script:Summary = 'The owner-specific update ran, but one or more exact-release/receipt/Desktop/remote checks remain unresolved.'
    } elseif ($problems -eq 0) {
        $script:Status = 'ALREADY_CURRENT'
        $script:ExitCode = 0
        $script:Summary = 'No update was available; all verified checks passed.'
    } else {
        $script:Status = 'PARTIAL'
        $script:ExitCode = 1
        $script:Summary = 'No update was available, but pre-existing degradation remains (no mutation).'
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
function Get-NextAction {
    param([string]$Phase)
    if (($script:Owner -eq 'Sideload MSIX') -and (-not $script:SideloadDescriptorValid)) {
        return @{
            Action = 'Supply a publisher-verified official .appinstaller descriptor before checking availability or updating.'
            Command = 'powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 check -AppInstallerFile ''<verified.appinstaller>'''
            Permission = 'No; the descriptor must come from the official signed publisher feed.'
        }
    }
    if ([string]::IsNullOrWhiteSpace($script:BackendUrl) -and ($script:Blocks.Count -eq 0)) {
        return @{
            Action = 'Supply the existing private backend URL so network/HTTP/authentication layers can be tested separately.'
            Command = 'powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 check -BackendUrl ''<verified-url>'''
            Permission = 'No; the URL must already exist and must not include credentials.'
        }
    }
    switch ($Phase) {
        'PRECHECK' {
            return @{
                Action = 'Resolve the source provenance or preflight blocker before attempting any update.'
                Command = 'powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 check'
                Permission = 'No; do not reset, stash, or clean the checkout to bypass the check.'
            }
        }
        'WINDOWS_PACKAGE' {
            return @{
                Action = 'Resolve the first Windows package-owner/updater blocker, then rerun the owner-specific check.'
                Command = 'powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 check -BackendUrl ''<verified-url>'''
                Permission = 'Installing a Store/MSIX package may require Windows-managed consent; no elevation is assumed.'
            }
        }
        'NETWORK' {
            return @{
                Action = 'Verify the private route to the VM and re-test the same URL; do not open the backend publicly.'
                Command = 'Test-NetConnection <host> -Port <port>'
                Permission = 'No.'
            }
        }
        'AUTH' {
            return @{
                Action = 'Sign in through an approved Desktop session; do not scrape or decrypt saved tokens.'
                Command = 'powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 check -BackendUrl ''<verified-url>'''
                Permission = 'Desktop sign-in is an operator action.'
            }
        }
        'PROTOCOL' {
            return @{
                Action = 'Confirm the URL points at the Hermes backend and inspect the response type; do not label HTTP 200 as healthy.'
                Command = 'Invoke-WebRequest ''<verified-url>/api/status'' -UseBasicParsing'
                Permission = 'No.'
            }
        }
        'RECEIPT' {
            $receiptCommand = if (($script:ReceiptPath -ne 'none') -and (Test-Path -LiteralPath $script:ReceiptPath)) {
                'Get-Content ''' + $script:ReceiptPath + ''' -Raw | ConvertFrom-Json'
            } else {
                'Get-ChildItem "$env:HERMES_HOME\logs\update_receipts\update_*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1'
            }
            return @{
                Action = 'Read the correlated native receipt and complete the exact deferred step; exit code 0 alone is not success.'
                Command = $receiptCommand
                Permission = 'No; reading evidence only.'
            }
        }
        default {
            return @{
                Action = 'Rerun the read-only check and inspect the first failed row.'
                Command = 'powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 check'
                Permission = 'No.'
            }
        }
    }
}

function Write-Report {
    $utc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $safeHost = $script:HostName -replace '[^A-Za-z0-9._-]', '_'
    $dir = Join-Path $script:ReportRoot $safeHost
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $script:ReportPath = Join-Path $dir "$utc-$($script:Operation).md"
    $next = Get-NextAction $script:FailurePhase
    $versionAfter = $script:InstalledVersionAfter
    if ($script:Operation -eq 'check') { $versionAfter = 'not applicable (check is read-only)' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Hermes Operations — Incident Report ($($script:Operation))")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("> Generated by ``skills/hermes-windows/scripts/hermes.ps1`` v$($script:ScriptVersion). Redacted. Do not commit.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 1. Verdict')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- **Status:** ``$($script:Status)``")
    [void]$sb.AppendLine("- **Operation:** ``$($script:Operation)``")
    [void]$sb.AppendLine("- **Failure phase and classification:** ``$($script:FailurePhase)``")
    [void]$sb.AppendLine("- **One-line summary:** $(ConvertTo-MdCell $script:Summary)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 2. Exact environment')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Field | Observed value |')
    [void]$sb.AppendLine('|---|---|')
    [void]$sb.AppendLine("| Timestamp (UTC) | $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) (started $($script:StartedUtc)) |")
    [void]$sb.AppendLine("| Host / operating system | $(ConvertTo-MdCell $script:HostName) / $(ConvertTo-MdCell $script:OsName) build $($script:OsBuild) |")
    [void]$sb.AppendLine("| Effective account and supervisor scope | $(ConvertTo-MdCell $script:Account); PowerShell $($script:PsVersion) |")
    [void]$sb.AppendLine("| Hermes executable path | $(ConvertTo-MdCell $script:HeremesPath) |")
    [void]$sb.AppendLine("| Installation type / Windows package owner | $(ConvertTo-MdCell $script:Owner) / $(ConvertTo-MdCell $script:SignatureKind) |")
    [void]$sb.AppendLine("| Installed version before/after | v$(ConvertTo-MdCell $script:InstalledVersion) / $(ConvertTo-MdCell $versionAfter) |")
    [void]$sb.AppendLine("| Upstream stable target / full revision | v$(ConvertTo-MdCell $script:StableTargetVersion) ($(ConvertTo-MdCell $script:StableTargetFull)) / $(ConvertTo-MdCell $script:DistributorState) |")
    [void]$sb.AppendLine("| Installation identity / canonical checkout | $(ConvertTo-MdCell $script:InstallId) / $(ConvertTo-MdCell $script:CanonicalCheckout) |")
    [void]$sb.AppendLine("| Desktop build verification | $(ConvertTo-MdCell $script:DesktopBuildVerified); artifact=$(ConvertTo-MdCell $script:DesktopArtifactPath); repair=$(ConvertTo-MdCell $script:DesktopRepairRun)/$(ConvertTo-MdCell $script:DesktopRepairResult) |")
    [void]$sb.AppendLine("| Backend URL (no userinfo or tokens) | $(ConvertTo-MdCell $script:BackendUrlDisplay) ($(ConvertTo-MdCell $script:BackendUrlSource)) |")
    [void]$sb.AppendLine("| Mutations actually made | $(ConvertTo-MdCell $script:Mutations) |")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 3. Expected vs actual')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Check | Expected | Actual | PASS/FAIL/NOT_TESTED |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($row in $script:CheckRows) { [void]$sb.AppendLine($row) }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**Outcome separation (never collapsed into one success claim):**')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("| Dimension | Result | Evidence |")
    [void]$sb.AppendLine("|---|---|---|")
    [void]$sb.AppendLine("| Windows source installation updated | $(ConvertTo-MdCell $script:SourceVerification) | v$($script:InstalledVersionAfter) @ $($script:GitHead) vs target v$($script:StableTargetVersionBefore) @ $($script:StableTargetFullBefore) |")
    [void]$sb.AppendLine("| Desktop build | $(ConvertTo-MdCell $script:DesktopBuildVerified) | $(ConvertTo-MdCell $script:DesktopBuildState); $(ConvertTo-MdCell $script:DesktopArtifactPath) |")
    [void]$sb.AppendLine("| Remote backend reachable | $(ConvertTo-MdCell $script:HttpState) | HTTP $(ConvertTo-MdCell $script:HttpCode); protocol=$(ConvertTo-MdCell $script:HttpProtocol) |")
    [void]$sb.AppendLine("| Remote backend healthy | $(ConvertTo-MdCell $script:BackendHealthState) | overall=$(ConvertTo-MdCell $script:HttpOverall); version=$(ConvertTo-MdCell $script:HttpVersion) |")
    [void]$sb.AppendLine("| Authentication advertised | $(ConvertTo-MdCell $script:AuthState) | auth_required=$(ConvertTo-MdCell $script:HttpAuthRequired) |")
    [void]$sb.AppendLine("| Authenticated Desktop session actually tested | NO / NOT_TESTED | No approved credential path was used. |")
    [void]$sb.AppendLine("| WebSocket actually tested | $(ConvertTo-MdCell $script:WebSocketState) | Never inferred from HTTP status. |")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 4. Timeline and last successful step')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Step | Command or verification | Exit/status | Sanitized evidence |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($row in $script:TimelineRows) { [void]$sb.AppendLine($row) }
    [void]$sb.AppendLine('')
    $lastGood = ($script:TimelineRows | Where-Object { $_ -match '\| exit 0 \||\| HTTP 2\d\d \|' } | Select-Object -Last 1)
    $firstBad = ($script:TimelineRows | Where-Object { $_ -match '\| exit [1-9]\d* \||\| FAIL \|' } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($lastGood)) { $lastGood = 'none recorded' }
    if ([string]::IsNullOrWhiteSpace($firstBad)) { $firstBad = 'none observed' }
    [void]$sb.AppendLine("**Last confirmed successful step:** $(ConvertTo-MdCell $lastGood)")
    [void]$sb.AppendLine("**First confirmed failed step:** $(ConvertTo-MdCell $firstBad)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 5. Exact errors and references')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- **Error text (redacted, concise):** $(ConvertTo-MdCell $script:Summary)")
    [void]$sb.AppendLine("- **Hermes receipt:** ``$(ConvertTo-MdCell $script:ReceiptPath)``; correlation=``$(ConvertTo-MdCell $script:ReceiptCorrelation)``; operation=``$(ConvertTo-MdCell $script:UpdateCorrelationId)``; outcome=``$(ConvertTo-MdCell $script:ReceiptOutcome)``; followups=$($script:ReceiptFollowupCount); gateway_restart.incomplete=$(ConvertTo-MdCell $script:ReceiptGatewayIncomplete); contract=$(ConvertTo-MdCell $script:ReceiptContractValid); build_failure=$(ConvertTo-MdCell $script:ReceiptBuildFailure); fresh=$(ConvertTo-MdCell $script:ReceiptFresh)")
    if ($script:ReceiptFollowupText) {
        [void]$sb.AppendLine("- **Receipt follow-up detail:** $(ConvertTo-MdCell $script:ReceiptFollowupText)")
    }
    [void]$sb.AppendLine("- **Windows package identity:** $(ConvertTo-MdCell $script:PackageIdentity); publisher=$(ConvertTo-MdCell $script:PackagePublisher); SignatureKind=$(ConvertTo-MdCell $script:SignatureKind)")
    [void]$sb.AppendLine("- **Relevant Windows installer/WinGet error and exit code:** exit=$($script:UpdateExit); $(ConvertTo-MdCell (Limit-Text $script:UpdateOutput 5 600))")
    [void]$sb.AppendLine("- **HTTP status / response type / WebSocket close code, if tested:** HTTP $($script:HttpCode); type=$(ConvertTo-MdCell $script:HttpContentType); protocol=$($script:HttpProtocol); WS=$($script:WebSocketState)")
    [void]$sb.AppendLine("- **Evidence files kept locally (do not upload automatically):** ``$(ConvertTo-MdCell $script:ReportPath)``")
    foreach ($e in $script:Evidence) { [void]$sb.AppendLine($e) }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 6. Diagnosis and impact')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**Recorded blockers and degradations (exact reasons):**')
    [void]$sb.AppendLine('')
    if (($script:Blocks.Count + $script:Degraded.Count) -gt 0) {
        foreach ($b in $script:Blocks) { [void]$sb.AppendLine('- [BLOCKED] ' + (($b -split '\|', 2)[1])) }
        foreach ($d in $script:Degraded) { [void]$sb.AppendLine('- [DEGRADED] ' + (($d -split '\|', 2)[1])) }
    } else {
        [void]$sb.AppendLine('- None.')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**Confirmed cause(s) with evidence:**')
    [void]$sb.AppendLine('')
    if ($script:Confirmed.Count -gt 0) { foreach ($c in $script:Confirmed) { [void]$sb.AppendLine($c) } } else { [void]$sb.AppendLine('- No single confirmed failure cause; see failed rows above.') }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**Likely cause(s), explicitly labeled hypotheses:**')
    [void]$sb.AppendLine('')
    if ($script:Likely.Count -gt 0) { foreach ($l in $script:Likely) { [void]$sb.AppendLine($l) } } else { [void]$sb.AppendLine('- None asserted without evidence.') }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**Unknowns / tests not performed:**')
    [void]$sb.AppendLine('')
    foreach ($u in $script:Unknowns) { [void]$sb.AppendLine($u) }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**What still works:**')
    [void]$sb.AppendLine('')
    if ($script:Works.Count -gt 0) { foreach ($w in $script:Works) { [void]$sb.AppendLine($w) } } else { [void]$sb.AppendLine('- Not established.') }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**What is degraded / number of affected profiles:**')
    [void]$sb.AppendLine('')
    foreach ($a in $script:Affected) { [void]$sb.AppendLine($a) }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**Any service stopped or left running:**')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- No service or Desktop process was intentionally started, stopped, or killed by this script.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 7. Lowest-risk next action')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- **Recommended action (exactly one first action):** $($next.Action)")
    [void]$sb.AppendLine("- **Exact command, only if confirmed safe:** ``$($next.Command)``")
    [void]$sb.AppendLine("- **Requires new permission or credentials?** $($next.Permission)")
    [void]$sb.AppendLine('- **Actions deliberately NOT taken and why:** No reinstall, no distribution conversion, no blanket process kill, no GUI launch, no owner switch, no auth/firewall change, no retry loop. Check mode is read-only; update mode issued at most one owner-specific updater command.')
    if ($script:Warnings.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('**Warnings recorded (non-fatal):**')
        [void]$sb.AppendLine('')
        foreach ($w in $script:Warnings) { [void]$sb.AppendLine($w) }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 8. Re-verification / closure')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- **Commands to rerun:** `powershell.exe -NoProfile -File .\skills\hermes-windows\scripts\hermes.ps1 check -BackendUrl ''<verified-url>''`; for source updates also inspect the native receipt.')
    [void]$sb.AppendLine('- **Criteria for `HEALTHY`/`UPDATED`:** owner remains unambiguous; owner-specific version/receipt clean; VM host resolves; TCP reachable; `/api/status` returns Hermes JSON; authenticated WebSocket tested separately or explicitly not tested.')
    [void]$sb.AppendLine("- **Current incident state:** ``$(if ($script:ExitCode -eq 0) { 'VERIFIED_RESOLVED' } else { 'OPEN' })``")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**Security:** generated locally and redacted. Never include raw `.env`, auth stores, cookies, bearer headers, API tokens, SSH keys, or unsanitized logs. This report is ignored by Git.')

    try {
        Set-Content -LiteralPath $script:ReportPath -Value $sb.ToString() -Encoding UTF8 -Force -ErrorAction Stop
    } catch {
        $script:ReportPath = '(write failed)'
        Write-WarnLine "Could not write report: $($_.Exception.Message)"
    }
}

function Show-Summary {
    Write-Output ''
    Write-Output "STATUS: $($script:Status)"
    Write-Output "SUMMARY: $(Sanitize-Text $script:Summary)"
    if ($script:Status -in @('BLOCKED', 'FAILED', 'PARTIAL', 'DEGRADED', 'UNKNOWN')) {
        Write-Output "FAILURE PHASE: $($script:FailurePhase)"
    }
    Write-Output "REPORT: $(Sanitize-Text $script:ReportPath)"
    Write-Output "OWNER: $(Sanitize-Text $script:Owner); INSTALLED: v$(Sanitize-Text $script:InstalledVersion)"
    Write-Output "REMOTE: HTTP=$($script:HttpState); AUTH=$($script:AuthState); WS=$($script:WebSocketState)"
    if ($script:Operation -eq 'update' -and $script:Mutations -ne 'none') {
        Write-Output "MUTATIONS: $(Sanitize-Text $script:Mutations)"
    }
    Write-Output "EXIT: $($script:ExitCode)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Main {
    Write-Output "Hermes Operations (Windows) v$($script:ScriptVersion) — mode=$($script:Operation)"
    Write-Output "PowerShell $($script:PsVersion) — read-only owner detection first"

    $envOk = Initialize-Environment
    if (-not $envOk) {
        Add-Unknown 'Windows execution was not established; no owner or package command was run.'
        Set-CheckVerdict
        Write-Report
        Show-Summary
        exit $script:ExitCode
    }

    Resolve-Owner

    if ($script:Owner -eq 'Source build') {
        Get-SourceUpdateAvailability
        Get-SourceInstallIdentity
        Test-SourceProvenance
        if ($script:UpdateAvailable -eq 'yes') { [void](Resolve-SourceTargetRevision) }
        Capture-SourceBaseline
    } elseif ($script:Owner -eq 'Microsoft Store') {
        Get-StoreUpdateAvailability
    } elseif ($script:Owner -eq 'Sideload MSIX') {
        Get-SideloadDescriptorInfo
    }

    Test-BackendNetwork
    Invoke-StatusProbe
    if ($script:Owner -eq 'Source build') {
        if ($script:Operation -eq 'check') {
            Get-UpdateReceipt
        }
    } else {
        $script:ReceiptPath = 'not applicable (package owner)'
        Add-CheckRow 'Update receipt / follow-ups' 'source receipt applies only to source builds' 'distributor-owned package' 'NOT_TESTED'
    }

    if ($script:Operation -eq 'check') {
        Set-CheckVerdict
        Write-Report
        Show-Summary
        exit $script:ExitCode
    }

    # Update preflight: refuse ambiguity before any package mutation.
    if ($script:Blocks.Count -gt 0) {
        Set-UpdateVerdict
        Write-Report
        Show-Summary
        exit $script:ExitCode
    }
    if ($NoBackup -and ($script:Owner -ne 'Source build')) {
        Add-Block 'PRECHECK' '-NoBackup applies only to source updates; it is not a Store/MSIX option.'
    }
    $systemDrive = $env:SystemDrive
    if (-not [string]::IsNullOrWhiteSpace($systemDrive)) {
        try {
            $free = (Get-PSDrive -Name $systemDrive.Substring(0, 1) -ErrorAction Stop).Free
            $freeMb = [math]::Round($free / 1MB)
            Add-CheckRow 'Free disk for update' '>= 2048 MiB' "$freeMb MiB free" $(if ($freeMb -ge 2048) { 'PASS' } else { 'FAIL' })
            if ($freeMb -lt 2048) { Add-Block 'PRECHECK' "Only $freeMb MiB free on $systemDrive; update needs at least 2048 MiB." }
        } catch {
            Add-Warning "Could not determine free disk space: $($_.Exception.Message)"
        }
    }
    if ($script:Owner -eq 'Source build') {
        if ($script:UpdateAvailable -eq 'downgrade') {
            Add-Block 'PRECHECK' "Stable target v$($script:AvailableVersion) is older than installed v$($script:InstalledVersion)."
        }
        if ($script:UpdateAvailable -eq 'unknown') {
            Add-Block 'PRECHECK' 'Source update availability/target could not be established; refusing a blind update.'
        }
        if ($script:SourceProvenanceOk -ne 'yes') {
            Add-Block 'PRECHECK' 'Source provenance was not fully proven; refusing to run the source updater.'
        }
    }
    if (($script:Owner -eq 'Sideload MSIX') -and (-not $script:SideloadDescriptorValid)) {
        Add-Block 'PRECHECK' "Sideload update is not authorized: $($script:SideloadDescriptorReason)"
    }
    if ($script:Blocks.Count -gt 0) {
        Set-UpdateVerdict
        Write-Report
        Show-Summary
        exit $script:ExitCode
    }

    if (($script:Owner -eq 'Source build') -or ($script:Owner -eq 'Microsoft Store') -or ($script:Owner -eq 'Sideload MSIX')) {
        if ($script:UpdateAvailable -eq 'no') {
            $script:UpdateNeeded = $false
            $script:UpdateExit = 'not run'
            $script:DistributorState = 'owner channel already current'
            Add-Timeline 'WINDOWS_PACKAGE' 'owner-specific update' 'not run' 'no update available in the owner channel'
        } elseif ($script:Owner -eq 'Source build') {
            Invoke-SourceUpdate
        } elseif ($script:Owner -eq 'Microsoft Store') {
            Invoke-StoreUpdate
        } else {
            Invoke-SideloadUpdate
        }
    }

    # Re-read package state and the remote endpoint after mutation.
    Get-AppxInfo -AfterUpdate
    if ($script:Owner -eq 'Source build') {
        Get-HermesCommandInfo
        Get-SourceVersion -AfterUpdate
        Get-SourceInstallIdentity -AfterUpdate
        Get-SourceUpdateAvailability -AfterUpdate
        Test-SourceProvenance -AfterUpdate
        Test-SourceReleaseVerification
        if ($script:UpdateAttempted) {
            Get-UpdateReceipt -CorrelationId $script:UpdateCorrelationId
            Test-DesktopBuildArtifact
            Invoke-DesktopRepairIfNeeded
            if ($script:DesktopRepairRun -eq 'yes') { Test-DesktopBuildArtifact }
        } else {
            Get-UpdateReceipt
        }
    }
    Test-PostUpdatePackage
    Test-BackendNetwork
    Invoke-StatusProbe

    Set-UpdateVerdict
    Write-Report
    Show-Summary
    exit $script:ExitCode
}

try {
    Main
} catch {
    Add-Block 'OTHER' "Unhandled Windows operations error: $($_.Exception.Message)"
    Add-Unknown 'The script could not complete discovery/verification; no conclusion about Hermes health is warranted.'
    Add-Evidence "Exception type: $($_.Exception.GetType().FullName)"
    if ($script:Operation -eq 'update') {
        Set-UpdateVerdict
    } else {
        Set-CheckVerdict
    }
    Write-Report
    Show-Summary
    exit 2
}
