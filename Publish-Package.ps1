#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a clean, portable copy of the package - no server needed.

.DESCRIPTION
    - Copies the toolkit to an output folder
    - Optionally replaces the VC++ files with the genuine ones downloaded
      from Microsoft (each one is verified to be signed by Microsoft Corp.)
    - Zips everything into a single file and prints its SHA256
    - Also copies the launcher and the online bootstrap

    The result can be carried on a USB stick, put on a shared folder, or
    uploaded to any free file host / GitHub release.

.EXAMPLE
    .\Publish-Package.ps1                      # full clean package
.EXAMPLE
    .\Publish-Package.ps1 -SkipVCRuntimes      # just copy + zip, no downloads
#>
[CmdletBinding()]
param(
    [string]$Source = '',
    [string]$OutDir = '',
    [switch]$SkipVCRuntimes,      # do not download the genuine runtimes (just copy what is there)
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

function Say { param([string]$m, [string]$c = 'White') Write-Host $m -ForegroundColor $c }

$OfficialVC = [ordered]@{
    '2005_x86'             = 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.exe'
    '2005_x64'             = 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.exe'
    '2008_x86'             = 'https://download.microsoft.com/download/9/7/7/977B481A-7BA6-4E30-AC40-ED51EB2028F2/vcredist_x86.exe'
    '2008_x64'             = 'https://download.microsoft.com/download/9/7/7/977B481A-7BA6-4E30-AC40-ED51EB2028F2/vcredist_x64.exe'
    '2010_x86'             = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe'
    '2010_x64'             = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'
    '2012_x86'             = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe'
    '2012_x64'             = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe'
    '2013_x86'             = 'https://aka.ms/highdpimfc2013x86enu'
    '2013_x64'             = 'https://aka.ms/highdpimfc2013x64enu'
    '2015_2017_2019_2022_x86' = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
    '2015_2017_2019_2022_x64' = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
}

function Test-MicrosoftSigned {
    param([string]$Path)
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        if ($sig.Status -ne 'Valid') { return $false }
        return ($sig.SignerCertificate.Subject -match 'O=Microsoft Corporation')
    } catch { return $false }
}

# Resolve paths inside the body: $PSScriptRoot is not reliable in param defaults
if (-not $Source) {
    if ($PSScriptRoot) { $Source = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $Source = Split-Path -Parent $MyInvocation.MyCommand.Path }
    elseif ($PSCommandPath) { $Source = Split-Path -Parent $PSCommandPath }
}
if (-not $Source) { throw 'Could not detect the package folder. Use -Source "C:\path\to\DRIVER"' }
$Source = (Resolve-Path -LiteralPath $Source).Path
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $Source -Parent) 'recoil-killer-package' }

Say ('=' * 60) 'Cyan'
Say '  building a clean, portable package' 'Cyan'
Say ('=' * 60) 'Cyan'
Say ("Source : {0}" -f $Source)
Say ("Output : {0}" -f $OutDir)
Say ''

if (Test-Path -LiteralPath $OutDir) {
    Say 'Output folder exists - refreshing it...' 'Yellow'
    Remove-Item -LiteralPath $OutDir -Recurse -Force
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# ---------------------------------------------------------------------------
# 1) Copy the tree
# ---------------------------------------------------------------------------
Say '[1/4] Copying the toolkit...' 'Yellow'
$copyArgs = @($Source, $OutDir, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
$null = & robocopy.exe @copyArgs
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
Say '      copied.' 'Green'

# ---------------------------------------------------------------------------
# 2) Replace the VC++ files with genuine Microsoft ones
# ---------------------------------------------------------------------------
$vcOutDir = Join-Path $OutDir 'Visual-C-Runtimes-All-in-One-Oct-2024'
if (-not $SkipVCRuntimes) {
    Say '[2/4] Fetching genuine Microsoft runtimes (this replaces the package copies)...' 'Yellow'
    $bad = @(Get-ChildItem -Path $vcOutDir -Filter 'vcredist*.exe' -ErrorAction SilentlyContinue |
             Where-Object { -not (Test-MicrosoftSigned -Path $_.FullName) })
    foreach ($f in $bad) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }

    $i = 0
    foreach ($key in $OfficialVC.Keys) {
        $i++
        $dest = Join-Path $vcOutDir ("vcredist{0}.exe" -f $key)
        Write-Progress -Activity 'Downloading official runtimes' -Status $key -PercentComplete ([int](100 * $i / $OfficialVC.Count))
        try {
            Invoke-WebRequest -Uri $OfficialVC[$key] -OutFile $dest -UseBasicParsing
            if (Test-MicrosoftSigned -Path $dest) {
                Say ("      OK   {0}" -f $key) 'Green'
            } else {
                Say ("      UNSIGNED - removed: {0}" -f $key) 'Red'
                Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Say ("      FAILED {0} : {1}" -f $key, $_.Exception.Message) 'Red'
        }
    }
    Write-Progress -Activity 'Downloading official runtimes' -Completed
} else {
    Say '[2/4] Runtime replacement skipped (-SkipVCRuntimes).' 'Yellow'
}

# ---------------------------------------------------------------------------
# 3) Verify what is inside the package now
# ---------------------------------------------------------------------------
Say '[3/4] Verifying the packaged VC++ files...' 'Yellow'
$vcFiles = @(Get-ChildItem -Path $vcOutDir -Filter 'vcredist*.exe' -ErrorAction SilentlyContinue)
$unsigned = @($vcFiles | Where-Object { -not (Test-MicrosoftSigned -Path $_.FullName) })
Say ("      {0} runtime file(s), {1} not signed by Microsoft." -f $vcFiles.Count, $unsigned.Count) $(if ($unsigned.Count) { 'Yellow' } else { 'Green' })

$otherExe = @(
    (Join-Path $OutDir 'dControl.exe'),
    (Join-Path $OutDir 'CMD.exe'),
    (Join-Path $OutDir '13_1.exe'),
    (Join-Path $OutDir '1. VTX\VTX\1. CheckVTX.exe'),
    (Join-Path $OutDir '1. VTX\VTX\2. GiaiPhongVTX.exe'),
    (Join-Path $OutDir '1. VTX\VTX\3. BatVTX.exe')
) | Where-Object { Test-Path -LiteralPath $_ }
$unsignedOther = @($otherExe | Where-Object { -not (Test-MicrosoftSigned -Path $_) })
Say ("      {0} toolkit executable(s), {1} unsigned (dControl / VTX / CMD are expected here)." -f $otherExe.Count, $unsignedOther.Count) 'Yellow'

# ---------------------------------------------------------------------------
# 4) Zip + hash
# ---------------------------------------------------------------------------
if (-not $NoZip) {
    Say '[4/4] Creating the single archive...' 'Yellow'
    $zip = "$OutDir.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zip -CompressionLevel Optimal -Force
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    $size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
    Say ''
    Say ('-' * 60) 'Cyan'
    Say ("  Archive : {0}" -f $zip) 'Green'
    Say ("  Size    : {0} MB" -f $size) 'Green'
    Say ("  SHA256  : {0}" -f $hash) 'Green'
    Say ('-' * 60) 'Cyan'
} else {
    Say '[4/4] Zipping skipped (-NoZip).' 'Yellow'
}

Say ''
Say 'How to use this package without a server:' 'Cyan'
Say '  1) USB / shared folder : copy the folder (or extract the zip) and run Run-Setup.cmd'
Say '  2) Free hosting        : upload the zip anywhere, put Install-Toolkit.ps1 +'
Say '                           Run-Online.ps1 on a raw link (GitHub raw, etc.)'
Say '  3) No hosting at all   : run with -VCFromMicrosoft - the runtimes come from Microsoft'
