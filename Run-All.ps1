#Requires -Version 5.1
<#
.SYNOPSIS
    One-line bootstrap: downloads Install-All.ps1 from the project URL and runs it.

.DESCRIPTION
    The machine only needs Windows + PowerShell + internet.
    Update $BaseUrl below to match where you host the package.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-All.ps1
#>
[CmdletBinding()]
param(
    # Base URL that hosts Install-All.ps1 (keep the trailing slash).
    [string]$BaseUrl = 'https://raw.githubusercontent.com/khaledco2/TEST20262/main/',

    # Optional: folder holding the package (drivers / VTX / Install-Toolkit.ps1).
    [string]$PackageDir = '',

    # Extra arguments forwarded to Install-All.ps1 (e.g. -InstallDrivers -RunVendorToolkit)
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$InstallerArgs
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

$BaseUrl = $BaseUrl.TrimEnd('/')
$url     = "$BaseUrl/Install-All.ps1"
$local   = Join-Path $env:TEMP 'Install-All.ps1'

Write-Host ('=' * 52) -ForegroundColor Cyan
Write-Host '  Complete installer - online bootstrap' -ForegroundColor Cyan
Write-Host ('=' * 52) -ForegroundColor Cyan
Write-Host ("Source : {0}" -f $url)

if (Test-Path -LiteralPath $local) { Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue }

Write-Host 'Downloading the installer...' -ForegroundColor Yellow
try {
    Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing
} catch {
    Write-Host ("Download FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

Write-Host 'Starting the installer...' -ForegroundColor Yellow
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $local)
if (-not [string]::IsNullOrWhiteSpace($PackageDir)) { $argList += @('-PackageDir', $PackageDir) }
if ($InstallerArgs) { $argList += $InstallerArgs }
& powershell.exe @argList
exit $LASTEXITCODE
