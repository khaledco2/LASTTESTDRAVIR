#Requires -Version 5.1
<#
.SYNOPSIS
    Online bootstrapper for the recoil-killer setup.
    Downloads Install-Toolkit.ps1 (and on demand the package files) from a URL
    you host, then runs the setup on the current machine.

.DESCRIPTION
    The machine only needs Windows + PowerShell + internet access.
    Nothing has to be copied by hand.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Online.ps1 -BaseUrl "https://your-host/DRIVER/"

.EXAMPLE
    # one-liner for any machine (no file to copy beforehand)
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$u='https://your-host/DRIVER/'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; $p=\"$env:TEMP\Run-Online.ps1\"; iwr ($u+'Run-Online.ps1') -OutFile $p -UseBasicParsing; & $p -BaseUrl $u"

.EXAMPLE
    # pin the setup script with its SHA256 so a changed file on the server is refused
    .\Run-Online.ps1 -BaseUrl "https://your-host/DRIVER/" -ScriptSha256 "A1B2C3..."
#>
[CmdletBinding()]
param(
    # Base URL that hosts Install-Toolkit.ps1 and the package folders
    # Example: https://your-host/DRIVER/
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    # Where the downloaded package is stored on the target machine
    [string]$WorkDir = (Join-Path $env:ProgramData 'RecoilKillerSetup\bootstrap'),

    # Optional: expected SHA256 of Install-Toolkit.ps1 on the server
    [string]$ScriptSha256 = '',

    # ---- options forwarded to Install-Toolkit.ps1 ----
    [bool]$InstallVCRuntimes = $true,
    [bool]$InstallDrivers    = $true,
    [switch]$RunVTXCheck,
    [switch]$FixVTX,
    [switch]$SkipVTXFix,
    [switch]$SkipProtectionGate,
    [switch]$SkipVerify,
    [switch]$VCFromMicrosoft,
    [switch]$AllowLocalVCRuntimes,
    [switch]$Detailed,
    [switch]$RebootWhenDone,
    [switch]$OpenVendorGuide,
    [int]$MinWindowsBuild = 19041,
    [int]$MaxWindowsBuild = 26200
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

function Say  { param([string]$m, [string]$c = 'White') Write-Host $m -ForegroundColor $c }

$BaseUrl  = $BaseUrl.TrimEnd('/')
$ScriptUrl = "$BaseUrl/Install-Toolkit.ps1"

Say ('=' * 46) 'Cyan'
Say '  recoil-killer - online setup' 'Cyan'
Say ('=' * 46) 'Cyan'
Say ("Server : {0}" -f $BaseUrl)
Say ("Work   : {0}" -f $WorkDir)
Say ''

if (-not (Test-Path -LiteralPath $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Download the setup script
# ---------------------------------------------------------------------------
$localScript = Join-Path $WorkDir 'Install-Toolkit.ps1'
Say 'Downloading the setup script...' 'Yellow'
try {
    Invoke-WebRequest -Uri $ScriptUrl -OutFile $localScript -UseBasicParsing
} catch {
    Say ("FAILED to download {0}" -f $ScriptUrl) 'Red'
    Say $_.Exception.Message 'Red'
    exit 1
}

if ($ScriptSha256) {
    $actual = (Get-FileHash -LiteralPath $localScript -Algorithm SHA256).Hash
    if ($actual -ne $ScriptSha256.Trim().ToUpper()) {
        Say 'The downloaded setup script does NOT match the expected SHA256.' 'Red'
        Say ("expected : {0}" -f $ScriptSha256.Trim().ToUpper()) 'Red'
        Say ("actual   : {0}" -f $actual) 'Red'
        Remove-Item -LiteralPath $localScript -Force -ErrorAction SilentlyContinue
        exit 2
    }
    Say 'Setup script verified against the pinned SHA256.' 'Green'
}
Say ''

# ---------------------------------------------------------------------------
# Run it (Install-Toolkit.ps1 elevates itself with UAC if needed)
# ---------------------------------------------------------------------------
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$localScript`"",
             '-Source', "`"$WorkDir`"",
             '-OnlineBaseUri', "`"$BaseUrl`"")
if (-not $InstallVCRuntimes) { $argList += @('-InstallVCRuntimes', '0') }
if (-not $InstallDrivers)    { $argList += @('-InstallDrivers', '0') }
if ($RunVTXCheck)            { $argList += '-RunVTXCheck' }
if ($FixVTX)                 { $argList += '-FixVTX' }
if ($SkipVTXFix)             { $argList += '-SkipVTXFix' }
if ($SkipProtectionGate)     { $argList += '-SkipProtectionGate' }
if ($SkipVerify)             { $argList += '-SkipVerify' }
if ($VCFromMicrosoft)        { $argList += '-VCFromMicrosoft' }
if ($AllowLocalVCRuntimes)   { $argList += '-AllowLocalVCRuntimes' }
if ($Detailed)               { $argList += '-Detailed' }
if ($RebootWhenDone)         { $argList += '-RebootWhenDone' }
if ($OpenVendorGuide)        { $argList += '-OpenVendorGuide' }
if ($MinWindowsBuild -ne 19041) { $argList += @('-MinWindowsBuild', $MinWindowsBuild) }
if ($MaxWindowsBuild -ne 26200) { $argList += @('-MaxWindowsBuild', $MaxWindowsBuild) }

Say 'Starting the setup...' 'Yellow'
Say ''
& powershell.exe @argList
exit $LASTEXITCODE
