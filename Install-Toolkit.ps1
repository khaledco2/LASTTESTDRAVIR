#Requires -Version 5.1
<#
.SYNOPSIS
    recoil-killer setup script for the DRIVER package.

.DESCRIPTION
    Flow:
      1. Verifies every package file against a built-in SHA256 manifest.
         Optionally downloads missing files from an online location you host.
      2. Opens dControl.exe so YOU can turn Windows protection off manually.
         The script only waits and detects the change - it never disables
         anything by itself.
      3. Scans the machine for every requirement recoil-killer needs:
         a supported Windows build, Visual C++ runtimes, drivers,
         virtualization / VTX, and it fingerprints the motherboard + BIOS.
      4. Auto-installs what is missing (Visual C++ runtimes, .inf drivers).
      5. VTX is the LAST working step, on purpose. If VTX is not active the
         script prints motherboard-specific BIOS guidance, runs GiaiPhongVTX
         then BatVTX, schedules a resume entry and restarts. Everything else
         is already finished by then, so nothing is repeated after the reboot.
      6. After the reboot the script continues by itself (RunOnce), verifies
         that VTX is now active and prints the final PASS / FAIL report.

    Console output is intentionally short: one line per item with OK / FAIL.
    Full details always go to the log file (path is printed at the end).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Toolkit.ps1
.EXAMPLE
    .\Install-Toolkit.ps1 -OnlineBaseUri "https://your-host/DRIVER/" -RunVTXCheck
.EXAMPLE
    .\Install-Toolkit.ps1 -Detailed          # show the full verbose output in the console
#>
[CmdletBinding()]
param(
    # Folder that holds the toolkit (defaults to the script's own folder)
    [string]$Source = $PSScriptRoot,

    # Optional: base URL used to pull files that are missing locally.
    # Example: https://your-host/DRIVER/  (must mirror the same folder layout)
    [string]$OnlineBaseUri = '',

    # How long the script waits for you to turn protection off (minutes)
    [int]$ProtectionTimeoutMinutes = 5,

    [switch]$SkipProtectionGate,        # never open dControl
    [switch]$ProceedWithoutProtectionOff,

    # Master switches
    [bool]$InstallVCRuntimes = $true,
    [bool]$InstallDrivers    = $true,
    [switch]$RunVTXCheck,               # run 1. CheckVTX.exe and wait for you
    [switch]$FixVTX,                    # force the VTX enable tools even if VTX looks active
    [switch]$SkipVTXFix,                # never touch VTX (default = enable it automatically)
    [switch]$SkipVerify,                # continue despite a SHA256 mismatch (NOT recommended)
    [switch]$VCFromMicrosoft,           # download the VC++ runtimes from Microsoft instead of the package
    [switch]$AllowLocalVCRuntimes,      # allow package copies that are NOT signed by Microsoft
    [switch]$Detailed,                  # full verbose console output
    [switch]$RebootWhenDone,            # reboot at the end when a restart is required

    # Seconds to wait before the automatic restart after a VTX fix
    [int]$RebootDelaySeconds = 60,

    # Supported Windows range (build numbers).
    # 19041 = Windows 10 2004 (20H1) ... 26200 = Windows 11 25H2
    [int]$MinWindowsBuild = 19041,
    [int]$MaxWindowsBuild = 26200,

    # Open the detected motherboard manufacturer's support page in the browser
    # when VTX is not active.
    [switch]$OpenVendorGuide,

    # Internal: set by the RunOnce entry so the script continues after a reboot
    [switch]$Resume
)

# ---------------------------------------------------------------------------
# Global setup
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

$StateDir  = Join-Path $env:ProgramData 'RecoilKillerSetup'
$StateFile = Join-Path $StateDir 'state.json'
$RunOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$RunOnceName = 'RecoilKillerSetupResume'

# Resolve the package folder reliably.
# ($PSScriptRoot in a parameter default can come back empty, so resolve it here.)
if (-not $Source) {
    if ($PSScriptRoot) { $Source = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $Source = Split-Path -Parent $MyInvocation.MyCommand.Path }
    elseif ($PSCommandPath) { $Source = Split-Path -Parent $PSCommandPath }
}
if (-not $Source) { throw 'Could not detect the package folder. Run with: -Source "C:\path\to\DRIVER"' }
if (-not (Test-Path -LiteralPath $Source)) { throw "Package folder not found: $Source" }
$Source = (Resolve-Path -LiteralPath $Source).Path

# ---------------------------------------------------------------------------
# Resume support - after a reboot the RunOnce entry calls us back with -Resume
# ---------------------------------------------------------------------------
$ResumeMode = $false
$SavedLogFile = $null
if ($Resume -and (Test-Path -LiteralPath $StateFile)) {
    try {
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        $ResumeMode = $true
        if ($state.LogFile) { $SavedLogFile = $state.LogFile }
        if ($state.Source -and (Test-Path -LiteralPath $state.Source)) { $Source = $state.Source }
        if ($state.OnlineBaseUri) { $OnlineBaseUri = $state.OnlineBaseUri }
        if ($state.RunVTXCheck)   { $RunVTXCheck = $true }
        if ($state.SkipVerify)    { $SkipVerify = $true }
        if ($state.VCFromMicrosoft) { $VCFromMicrosoft = $true }
        if ($state.AllowLocalVCRuntimes) { $AllowLocalVCRuntimes = $true }
        if ($state.Detailed)      { $Detailed = $true }
        if ($state.OpenVendorGuide) { $OpenVendorGuide = $true }
        if ($state.MinWindowsBuild) { $MinWindowsBuild = [int]$state.MinWindowsBuild }
        if ($state.MaxWindowsBuild) { $MaxWindowsBuild = [int]$state.MaxWindowsBuild }
        if ($state.Stage) { Write-Host ("Resuming after reboot (stage: {0})..." -f $state.Stage) -ForegroundColor Cyan }
    } catch {
        Write-Host "Could not read the resume state, starting normally." -ForegroundColor Yellow
    }
}
# Never run the protection gate again on a resumed run
if ($ResumeMode) { $SkipProtectionGate = $true }

$LogFile = if ($SavedLogFile) { $SavedLogFile } else {
    Join-Path $env:TEMP ("RecoilKillerSetup_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
}
$Results = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------------------
# Output helpers
#   - everything goes to the log file
#   - the console shows only short OK / FAIL lines unless -Detailed is used
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0:HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
    if ($Detailed) {
        $color = switch ($Level) {
            'OK'    { 'Green' }
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            'STEP'  { 'Cyan' }
            'DATA'  { 'Gray' }
            default { 'White' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Write-Con {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

function Set-StepProgress {
    param([int]$Percent, [string]$Status)
    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    Write-Progress -Activity 'recoil-killer setup' -Status $Status -PercentComplete $Percent
}

function Cleanup-ResumeEntry {
    try { Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item -LiteralPath $StateFile -ErrorAction SilentlyContinue } catch {}
}

function Add-Result {
    param([string]$Requirement, [string]$Status, [string]$Action)
    $Results.Add([PSCustomObject]@{ Requirement = $Requirement; Status = $Status; Action = $Action })

    $verdict = switch ($Status) {
        'OK'      { 'OK' }
        'WARN'    { 'WARN' }
        default   { 'FAIL' }
    }
    $color = switch ($verdict) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        default { 'Red' }
    }
    Write-Log ("  [{0}] {1} - {2}" -f $verdict, $Requirement, $Action) $Status
    if ($Detailed) {
        Write-Con ("  [{0,-4}] {1}  -->  {2}" -f $verdict, $Requirement, $Action) $color
    } else {
        Write-Con ("{0,-30} : {1}" -f $Requirement, $verdict) $color
    }
}

# ---------------------------------------------------------------------------
# Integrity manifest  (relative path | SHA256)
# ---------------------------------------------------------------------------
$Manifest = @{}
foreach ($line in @'
13_1.exe|67F3DC584071AEB37D569C1EC12761D626B094C0AE5EA2181D3333B12CB3FDC3
CMD.exe|778CF5AF6F192F0EADE2705ADEB8B75EEC043ACAE27FA5A1690DA17F23CD48CE
dControl.exe|0A647A56916290075B0C0462A75C930879119F5F4836983B3366112B7D536FBC
1. VTX\VTX\1. CheckVTX.exe|67F3DC584071AEB37D569C1EC12761D626B094C0AE5EA2181D3333B12CB3FDC3
1. VTX\VTX\2. GiaiPhongVTX.exe|34CB3106AB7DBEF379E80E35086DE92883AEFAF3D2F56D1B1FC84FC13F413C85
1. VTX\VTX\3. BatVTX.exe|801626FD566388FEC8768B67DE55438AD97856ECB30DFB6CFD5B14BEBD94D707
Visual-C-Runtimes-All-in-One-Oct-2024\install_all.bat|492EE4C16AC45A5483088583C9CAA08252D3A1BB3922DBBEC834D61673538F17
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2005_x86.exe|4EE4DA0FE62D5FA1B5E80C6E6D88A4A2F8B3B140C35DA51053D0D7B72A381D29
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2005_x64.exe|0551A61C85B718E1FA015B0C3E3F4C4EEA0637055536C00E7969286B4FA663E0
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2008_x86.exe|6B3E4C51C6C0E5F68C8A72B497445AF3DBF976394CBB62AA23569065C28DEEB6
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2008_x64.exe|B811F2C047A3E828517C234BD4AA4883E1EC591D88FAD21289AE68A6915A6665
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2010_x86.exe|67313B3D1BC86E83091E8DE22981F14968F1A7FB12EB7AD467754C40CD94CC3D
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2010_x64.exe|CC7EC044218C72A9A15FCA2363BAED8FC51095EE3B2A7593476771F9EBA3D223
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2012_x86.exe|B924AD8062EAF4E70437C8BE50FA612162795FF0839479546CE907FFA8D6E386
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2012_x64.exe|681BE3E5BA9FD3DA02C09D7E565ADFA078640ED66A0D58583EFAD2C1E3CC4064
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2013_x86.exe|53B605D1100AB0A88B867447BBF9274B5938125024BA01F5105A9E178A3DCDBD
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2013_x64.exe|A4BBA7701E355AE29C403431F871A537897C363E215CAFE706615E270984F17C
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2015_2017_2019_2022_x86.exe|ED1967C2AC27D806806D121601B526F84E497AE1B99ED139C0C4C6B50147DF4A
Visual-C-Runtimes-All-in-One-Oct-2024\vcredist2015_2017_2019_2022_x64.exe|814E9DA5EC5E5D6A8FA701999D1FC3BADDF7F3ADC528E202590E9B1CB73E4A11
'@ -split "`r?`n") {
    if ($line -match '^\s*(.+?)\s*\|\s*([0-9A-Fa-f]{64})\s*$') { $Manifest[$Matches[1]] = $Matches[2].ToUpper() }
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Warning 'Administrator privileges are required. Relaunching elevated...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-Source', "`"$Source`"", '-ProtectionTimeoutMinutes', $ProtectionTimeoutMinutes,
                 '-RebootDelaySeconds', $RebootDelaySeconds,
                 '-MinWindowsBuild', $MinWindowsBuild, '-MaxWindowsBuild', $MaxWindowsBuild)
    if ($OnlineBaseUri)               { $argList += @('-OnlineBaseUri', "`"$OnlineBaseUri`"") }
    if ($SkipProtectionGate)          { $argList += '-SkipProtectionGate' }
    if ($ProceedWithoutProtectionOff) { $argList += '-ProceedWithoutProtectionOff' }
    if (-not $InstallVCRuntimes)      { $argList += @('-InstallVCRuntimes', '0') }
    if (-not $InstallDrivers)         { $argList += @('-InstallDrivers', '0') }
    if ($RunVTXCheck)                 { $argList += '-RunVTXCheck' }
    if ($FixVTX)                      { $argList += '-FixVTX' }
    if ($SkipVTXFix)                  { $argList += '-SkipVTXFix' }
    if ($SkipVerify)                  { $argList += '-SkipVerify' }
    if ($VCFromMicrosoft)             { $argList += '-VCFromMicrosoft' }
    if ($AllowLocalVCRuntimes)        { $argList += '-AllowLocalVCRuntimes' }
    if ($Detailed)                    { $argList += '-Detailed' }
    if ($RebootWhenDone)              { $argList += '-RebootWhenDone' }
    if ($OpenVendorGuide)             { $argList += '-OpenVendorGuide' }
    if ($Resume)                      { $argList += '-Resume' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit 0
}

# ---------------------------------------------------------------------------
# Helpers - protection state and VC++ detection
# ---------------------------------------------------------------------------
function Test-RealTimeProtectionActive {
    # $true = protection is ON. Checks Defender status and the registry keys
    # tools like dControl modify, so detection is reliable.
    try {
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' `
                   -Name DisableAntiSpyware -ErrorAction SilentlyContinue
        if ($reg -and $reg.DisableAntiSpyware -eq 1) { return $false }

        $rt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection' `
                   -Name DisableRealtimeMonitoring -ErrorAction SilentlyContinue
        if ($rt -and $rt.DisableRealtimeMonitoring -eq 1) { return $false }

        $mp = Get-MpComputerStatus
        return [bool]$mp.RealTimeProtectionEnabled
    } catch {
        return $false
    }
}

# Official Microsoft download locations (verified reachable, files signed by Microsoft)
$script:OfficialVC = [ordered]@{
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
    # $true only when the file carries a VALID signature from Microsoft Corporation.
    param([string]$Path)
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        if ($sig.Status -ne 'Valid') { return $false }
        return ($sig.SignerCertificate.Subject -match 'O=Microsoft Corporation')
    } catch {
        return $false
    }
}

$script:VCList = @()
function Get-InstalledVCRedist {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    return @(Get-ItemProperty $keys -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -like 'Microsoft Visual C++ *' } |
             ForEach-Object { $_.DisplayName })
}

function Test-VCRuntimeInstalled {
    param([string]$Year)
    $list = $script:VCList
    switch ($Year) {
        '2015_2017_2019_2022' { return [bool]($list -match 'Microsoft Visual C\+\+ (2015|2017|2019|2022)') }
        default                { return [bool]($list -match ("Microsoft Visual C\+\+ {0} " -f $Year)) }
    }
}

# ---------------------------------------------------------------------------
# Windows build detection
# ---------------------------------------------------------------------------
function Get-WindowsReleaseName {
    param([int]$Build, [string]$Label, [string]$ProductName)
    $map = @{
        19041 = 'Windows 10 2004 (20H1)'
        19042 = 'Windows 10 20H2'
        19043 = 'Windows 10 21H1'
        19044 = 'Windows 10 21H2'
        19045 = 'Windows 10 22H2'
        22000 = 'Windows 11 21H2'
        22621 = 'Windows 11 22H2'
        22631 = 'Windows 11 23H2'
        26100 = 'Windows 11 24H2'
        26200 = 'Windows 11 25H2'
    }
    if ($map.ContainsKey($Build)) { return $map[$Build] }
    $nm = if ($ProductName) { $ProductName } else { 'Windows' }
    if ($Label) { return ("{0} {1} (build {2})" -f $nm, $Label, $Build) }
    return ("{0} (build {1})" -f $nm, $Build)
}

function Get-WindowsInfo {
    $build = 0; $productName = ''; $displayVersion = ''; $releaseId = ''; $caption = ''
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) { $build = [int]$os.BuildNumber; $caption = [string]$os.Caption }
    } catch {}
    try {
        $p = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        if ($p) {
            if (-not $build) { $build = [int]$p.CurrentBuildNumber }
            $productName    = [string]$p.ProductName
            $displayVersion = [string]$p.DisplayVersion
            $releaseId      = [string]$p.ReleaseId
        }
    } catch {}
    $label = if ($displayVersion) { $displayVersion } elseif ($releaseId) { $releaseId } else { '' }
    return [PSCustomObject]@{
        Build   = $build
        Caption = $caption
        Name    = (Get-WindowsReleaseName -Build $build -Label $label -ProductName $productName)
    }
}

# ---------------------------------------------------------------------------
# Motherboard / BIOS fingerprint (+ BIOS vendor support links)
# ---------------------------------------------------------------------------
function Get-BoardInfo {
    $board = $null; $bios = $null; $cs = $null; $cpu = $null
    try { $board = Get-CimInstance Win32_BaseBoard      -ErrorAction SilentlyContinue } catch {}
    try { $bios  = Get-CimInstance Win32_BIOS           -ErrorAction SilentlyContinue } catch {}
    try { $cs    = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue } catch {}
    try { $cpu   = Get-CimInstance Win32_Processor      -ErrorAction SilentlyContinue } catch {}

    $mfg   = @($board.Manufacturer, $cs.Manufacturer, $bios.Manufacturer) | Where-Object { $_ } | Select-Object -Unique
    $mfgTx = ($mfg -join ' / ')

    $cpuVendor = 'Intel'
    if ($cpu -and $cpu.Manufacturer -match 'AMD')   { $cpuVendor = 'AMD' }
    if ($cpu -and $cpu.Manufacturer -match 'Intel') { $cpuVendor = 'Intel' }

    $modelText = ("{0} {1} {2} {3}" -f $cs.Manufacturer, $cs.Model, $board.Manufacturer, $board.Product)
    $isVm = ($modelText -match 'Virtual|VMware|VirtualBox|KVM|QEMU|Xen|Hyper-V|Bochs|Parallels|Microsoft Corporation Virtual')

    return [PSCustomObject]@{
        Manufacturer    = if ($cs.Manufacturer) { [string]$cs.Manufacturer } else { [string]$board.Manufacturer }
        Model           = [string]$cs.Model
        BoardManufacturer = [string]$board.Manufacturer
        BoardProduct    = [string]$board.Product
        BiosVendor      = [string]$bios.Manufacturer
        BiosVersion     = [string]$bios.SMBIOSBIOSVersion
        CpuVendor       = $cpuVendor
        CpuName         = if ($cpu) { ([string]$cpu.Name).Trim() } else { 'unknown CPU' }
        Makers          = $mfgTx
        IsVm            = [bool]$isVm
        Text            = ("{0} {1}" -f $board.Manufacturer, $board.Product).Trim()
    }
}

function Get-VtxGuidance {
    # Vendor-specific BIOS instructions, taken from the detected board maker.
    param([object]$Board)
    $cpuWord = if ($Board.CpuVendor -eq 'AMD') { 'SVM Mode (AMD-V)' } else { 'Intel Virtualization Technology (VT-x)' }

    $boot = 'Del or F2'
    $path = 'Advanced > CPU Configuration > Intel Virtualization Technology / SVM Mode'
    $url  = ''
    $m = ("{0} {1} {2}" -f $Board.Manufacturer, $Board.BoardManufacturer, $Board.BiosVendor).ToUpper()

    switch -Regex ($m) {
        'ASUS'        { $boot = 'Del (F2 on laptops)';    $path = 'Advanced (F7) > CPU Configuration > Intel Virtualization Technology / SVM Mode'; $url = 'https://www.asus.com/support/'; break }
        'GIGABYTE'    { $boot = 'Del';                    $path = 'Tweaker / Advanced > CPU Configuration > SVM Mode or Intel Virtualization Technology'; $url = 'https://www.gigabyte.com/Support'; break }
        'MICRO-STAR|MSI' { $boot = 'Del';                 $path = 'OC or Advanced > CPU Features > SVM Mode / Intel Virtualization Technology'; $url = 'https://www.msi.com/support'; break }
        'ASROCK'      { $boot = 'F2 or Del';              $path = 'Advanced > CPU Configuration > SVM Mode / Intel Virtualization Technology'; $url = 'https://www.asrock.com/support/'; break }
        'DELL'        { $boot = 'F2';                     $path = 'Virtualization Support > Virtualization > Enable Intel Virtualization Technology'; $url = 'https://www.dell.com/support'; break }
        'HEWLETT|HP'  { $boot = 'Esc then F10';           $path = 'Security > System Security > Virtualization Technology (VTx)'; $url = 'https://support.hp.com'; break }
        'LENOVO'      { $boot = 'F1 or F2';               $path = 'Security > Virtualization > Intel Virtualization Technology / AMD SVM'; $url = 'https://support.lenovo.com'; break }
        'ACER'        { $boot = 'F2';                     $path = 'Advanced > CPU Configuration > Intel Virtualization Technology / SVM Mode'; $url = 'https://www.acer.com/support'; break }
        'SAMSUNG'     { $boot = 'F2';                     $path = 'Advanced > CPU Configuration > Intel Virtualization Technology'; $url = 'https://www.samsung.com/support/'; break }
        'TOSHIBA|DYNABOOK' { $boot = 'F2';                $path = 'Advanced > System Configuration > Virtualization Technology'; $url = 'https://support.dynabook.com'; break }
        'INTEL'       { $boot = 'F2';                     $path = 'Advanced > CPU Configuration > Intel Virtualization Technology'; $url = 'https://www.intel.com/content/www/us/en/support.html'; break }
        'AMERICAN MEGATRENDS|PHOENIX|INSYDE' { $boot = 'Del or F2'; $path = 'Advanced > CPU Configuration > Intel Virtualization Technology / SVM Mode'; $url = ''; break }
        default       { }
    }

    $search = 'https://www.bing.com/search?q=' + [uri]::EscapeDataString(("{0} {1} enable {2} in BIOS" -f $Board.Manufacturer, $Board.BoardProduct, $cpuWord))

    $lines = New-Object System.Collections.Generic.List[string]
    if ($Board.IsVm) {
        $lines.Add(("!! Virtual machine detected ({0} {1}). You cannot enable this inside the guest -" -f $Board.Manufacturer, $Board.Model))
        $lines.Add(("   enable nested virtualization on the HOST (Hyper-V: Set-VMProcessor -ExposeVirtualizationExtensions $true)."))
    }
    $lines.Add(("Machine    : {0} {1}" -f $Board.Manufacturer, $Board.Model))
    $lines.Add(("Board      : {0} {1}  |  BIOS: {2} {3}" -f $Board.BoardManufacturer, $Board.BoardProduct, $Board.BiosVendor, $Board.BiosVersion))
    $lines.Add(("CPU        : {0}" -f $Board.CpuName))
    $lines.Add(("Enable     : '{0}' in BIOS/UEFI" -f $cpuWord))
    $lines.Add(("Enter BIOS : press {0} while the machine powers on" -f $boot))
    $lines.Add(("Menu path  : {0}" -f $path))
    $lines.Add(("Save       : press F10 (or the shown key) to save and restart"))
    if ($url) { $lines.Add(("Vendor     : {0}" -f $url)) }
    $lines.Add(("Search     : {0}" -f $search))

    return [PSCustomObject]@{
        BootKey   = $boot
        Path      = $path
        VendorUrl = $url
        SearchUrl = $search
        Lines     = $lines
    }
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
$TotalSteps = 6
$scheduledResume = $false
$rebootNeeded = $false

Write-Con ('=' * 46) 'Cyan'
Write-Con ('  recoil-killer setup  |  ' + $env:COMPUTERNAME) 'Cyan'
Write-Con ('=' * 46) 'Cyan'
Write-Log ('=' * 70) 'STEP'
Write-Log ("START (resume={0}) | Machine: {1} | Source: {2} | Log: {3}" -f $ResumeMode, $env:COMPUTERNAME, $Source, $LogFile) 'STEP'

# ---------------------------------------------------------------------------
# Step 1 - Windows protection gate (FIRST, so the rest runs without being
#          blocked). dControl.exe is only opened for YOU; the script never
#          turns protection off by itself, it just waits and detects.
# ---------------------------------------------------------------------------
Set-StepProgress 3 'Windows protection gate...'
Write-Log "STEP 1/$TotalSteps : Windows protection gate" 'STEP'

if ($SkipProtectionGate) {
    Write-Log '  Gate skipped.' 'WARN'
} else {
    $dControl = Join-Path $Source 'dControl.exe'
    if (Test-Path -LiteralPath $dControl) {
        Write-Con 'Opening dControl - turn protection OFF there if you accept the risk.' 'Yellow'
        Start-Process -FilePath $dControl
        Write-Con ("Waiting up to {0} minute(s) for protection to be turned off..." -f $ProtectionTimeoutMinutes) 'Yellow'

        $deadline   = (Get-Date).AddMinutes($ProtectionTimeoutMinutes)
        $timeoutMin = [Math]::Max(1, $ProtectionTimeoutMinutes)
        $detectedOn = Test-RealTimeProtectionActive
        $waited     = 0

        while ($detectedOn -and (Get-Date) -lt $deadline) {
            Set-StepProgress (3 + [int](10 * [Math]::Min(1, $waited / ($timeoutMin * 60)))) 'Waiting for protection to be turned off manually...'
            Start-Sleep -Seconds 3
            $waited += 3
            $detectedOn = Test-RealTimeProtectionActive
        }

        if ($detectedOn) {
            if ($ProceedWithoutProtectionOff) {
                Write-Log '  Protection still ON, continuing because of -ProceedWithoutProtectionOff.' 'WARN'
                Add-Result -Requirement 'Protection off' -Status 'MISSING' -Action 'Still ON - files may be blocked'
            } else {
                Add-Result -Requirement 'Protection off' -Status 'FAILED' -Action 'Timed out waiting'
                if ($ResumeMode) { Cleanup-ResumeEntry }
                exit 3
            }
        } else {
            Add-Result -Requirement 'Protection off' -Status 'OK' -Action 'Detected OFF'
        }
    } else {
        Add-Result -Requirement 'Protection off' -Status 'MISSING' -Action 'dControl.exe not found'
    }
}

# ---------------------------------------------------------------------------
# Step 2 - Verify package + optional online download
# ---------------------------------------------------------------------------
Set-StepProgress 18 'Verifying package files...'
Write-Log "STEP 2/$TotalSteps : Verifying package files" 'STEP'

$failed = 0
$ignoredMismatch = 0
$files = @($Manifest.Keys | Sort-Object)
$i = 0
foreach ($rel in $files) {
    $i++
    Set-StepProgress (3 + [int](12 * $i / $files.Count)) ("Verifying {0}/{1}" -f $i, $files.Count)
    $full     = Join-Path $Source $rel
    $expected = $Manifest[$rel]

    if (-not (Test-Path -LiteralPath $full)) {
        if ($OnlineBaseUri) {
            $destDir = Split-Path $full -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            $url = $OnlineBaseUri.TrimEnd('/') + '/' + ($rel -replace '\\', '/')
            try {
                Write-Log "  Downloading missing file : $rel"
                Invoke-WebRequest -Uri $url -OutFile $full -UseBasicParsing
            } catch {
                Write-Log "  Download FAILED ($rel) : $($_.Exception.Message)" 'ERROR'
                $failed++
                continue
            }
        } else {
            Write-Log "  Missing file : $rel" 'ERROR'
            $failed++
            continue
        }
    }

    $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpper()
    if ($actual -ne $expected) {
        if ($SkipVerify) {
            Write-Log "  Hash mismatch IGNORED (-SkipVerify) : $rel" 'WARN'
            Write-Log ("    expected : {0}" -f $expected) 'WARN'
            Write-Log ("    actual   : {0}" -f $actual)   'WARN'
            $ignoredMismatch++
        } else {
            Write-Log "  Hash MISMATCH, this file is not the expected one : $rel" 'ERROR'
            $failed++
        }
    }
}

if ($failed -gt 0) {
    Add-Result -Requirement 'Package files' -Status 'FAILED' -Action "$failed file(s) missing or modified"
    Write-Log 'Aborting. Restore the missing/modified files from a copy you trust.' 'ERROR'
    if ($ResumeMode) { Cleanup-ResumeEntry }
    exit 2
}
if ($ignoredMismatch -gt 0) {
    Add-Result -Requirement 'Package files' -Status 'WARN' -Action ("{0} file(s) failed the SHA256 check, accepted only because -SkipVerify was used" -f $ignoredMismatch)
} else {
    Add-Result -Requirement 'Package files' -Status 'OK' -Action 'All files match the SHA256 manifest'
}

# ---------------------------------------------------------------------------
# Step 3 - Requirements scan
# ---------------------------------------------------------------------------
Set-StepProgress 32 'Scanning requirements...'
Write-Log "STEP 3/$TotalSteps : Requirement scan" 'STEP'

if ([Environment]::Is64BitOperatingSystem) {
    Add-Result -Requirement '64-bit Windows' -Status 'OK' -Action (Get-CimInstance Win32_OperatingSystem).Caption
} else {
    Add-Result -Requirement '64-bit Windows' -Status 'FAILED' -Action '32-bit OS detected - x64 is required'
}

# Windows build must be inside the supported range (default: 20H1/2004 ... 25H2)
$winInfo = Get-WindowsInfo
Write-Log ("  Windows  : {0} (build {1})" -f $winInfo.Name, $winInfo.Build)
if ($winInfo.Build -ge $MinWindowsBuild -and $winInfo.Build -le $MaxWindowsBuild) {
    Add-Result -Requirement 'Windows version' -Status 'OK' `
               -Action ("{0} - build {1} is supported ({2}-{3})" -f $winInfo.Name, $winInfo.Build, $MinWindowsBuild, $MaxWindowsBuild)
} elseif ($winInfo.Build -lt $MinWindowsBuild) {
    Add-Result -Requirement 'Windows version' -Status 'FAILED' `
               -Action ("{0} - too old, build {1} is below the minimum {2}" -f $winInfo.Name, $winInfo.Build, $MinWindowsBuild)
} else {
    Add-Result -Requirement 'Windows version' -Status 'FAILED' `
               -Action ("{0} - too new, build {1} is above the maximum {2}" -f $winInfo.Name, $winInfo.Build, $MaxWindowsBuild)
}

$script:VCList = Get-InstalledVCRedist
$vcYears = @('2005', '2008', '2010', '2012', '2013', '2015_2017_2019_2022')
$missingVC = @($vcYears | Where-Object { -not (Test-VCRuntimeInstalled -Year $_) })
if ($missingVC.Count -eq 0) {
    Add-Result -Requirement 'Visual C++ runtimes' -Status 'OK' -Action '2005-2022 installed'
} else {
    Add-Result -Requirement 'Visual C++ runtimes' -Status 'MISSING' -Action ("Missing: {0}" -f ($missingVC -join ', '))
}

# Are the VC++ copies inside the package genuine Microsoft binaries?
$vcLocalDir = Join-Path $Source 'Visual-C-Runtimes-All-in-One-Oct-2024'
$vcLocal = @(Get-ChildItem -Path $vcLocalDir -Filter 'vcredist*.exe' -ErrorAction SilentlyContinue)
if ($vcLocal.Count -gt 0) {
    $unsignedVC = @($vcLocal | Where-Object { -not (Test-MicrosoftSigned -Path $_.FullName) })
    if ($unsignedVC.Count -eq 0) {
        Add-Result -Requirement 'VC++ files genuine' -Status 'OK' -Action 'All package copies are signed by Microsoft'
    } else {
        Add-Result -Requirement 'VC++ files genuine' -Status 'WARN' `
                   -Action ("{0} of {1} package copies are NOT signed by Microsoft - official copies from Microsoft will be used instead" -f $unsignedVC.Count, $vcLocal.Count)
    }
}

$vtOk = $false
$vtDetail = ''
try {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $proc = Get-CimInstance Win32_Processor
    if ($cs.HypervisorPresent) {
        $vtOk = $true; $vtDetail = 'Hypervisor present'
    } elseif ($proc.VirtualizationFirmwareEnabled -eq $true) {
        $vtOk = $true; $vtDetail = 'Enabled in firmware'
    } else {
        $vtDetail = 'Disabled or unknown in BIOS/UEFI'
    }
} catch {
    $vtDetail = "Could not read state: $($_.Exception.Message)"
}

# Fingerprint the motherboard / BIOS and prepare the guidance in case VTX is off
$script:BoardInfo  = Get-BoardInfo
$script:VtxGuide   = Get-VtxGuidance -Board $script:BoardInfo
$script:GuideFile  = $null
Write-Log ("  Motherboard : {0} {1} | BIOS: {2} {3} | CPU: {4} ({5})" -f `
    $script:BoardInfo.BoardManufacturer, $script:BoardInfo.BoardProduct, `
    $script:BoardInfo.BiosVendor, $script:BoardInfo.BiosVersion, `
    $script:BoardInfo.CpuName, $script:BoardInfo.CpuVendor)
Add-Result -Requirement 'Motherboard' -Status 'OK' `
           -Action ("{0} {1} | BIOS {2} {3}" -f $script:BoardInfo.BoardManufacturer, $script:BoardInfo.BoardProduct, $script:BoardInfo.BiosVendor, $script:BoardInfo.BiosVersion)

if ($vtOk) {
    Add-Result -Requirement 'VTX (virtualization)' -Status 'OK' -Action $vtDetail
} else {
    Add-Result -Requirement 'VTX (virtualization)' -Status 'MISSING' -Action $vtDetail
    # Persist the BIOS guide so it survives the reboot and can be read anytime
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        $script:GuideFile = Join-Path $StateDir 'VTX-BIOS-Guide.txt'
        $head = @(
            'How to enable virtualization (VTX) on this machine',
            ("Generated : {0}" -f (Get-Date)),
            ("Machine   : {0}" -f $env:COMPUTERNAME),
            ''
        )
        ($head + $script:VtxGuide.Lines) | Set-Content -LiteralPath $script:GuideFile -Encoding UTF8
        Write-Log ("  BIOS guide written to {0}" -f $script:GuideFile) 'WARN'
    } catch {
        Write-Log ("  Could not write the BIOS guide: {0}" -f $_.Exception.Message) 'WARN'
    }
}

$infFiles = @(Get-ChildItem -Path $Source -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue)
if ($infFiles.Count -eq 0) {
    Add-Result -Requirement 'Driver package' -Status 'MISSING' -Action 'No .inf files found in the package'
} else {
    Add-Result -Requirement 'Driver package' -Status 'OK' -Action ("{0} .inf file(s)" -f $infFiles.Count)
}

$vtxDir   = Join-Path $Source '1. VTX\VTX'
$checkVtx = Join-Path $vtxDir '1. CheckVTX.exe'
$fixVtx1  = Join-Path $vtxDir '2. GiaiPhongVTX.exe'
$fixVtx2  = Join-Path $vtxDir '3. BatVTX.exe'
if ((Test-Path -LiteralPath $checkVtx) -and (Test-Path -LiteralPath $fixVtx1) -and (Test-Path -LiteralPath $fixVtx2)) {
    Add-Result -Requirement 'VTX tools' -Status 'OK' -Action 'CheckVTX / GiaiPhongVTX / BatVTX present'
} else {
    Add-Result -Requirement 'VTX tools' -Status 'FAILED' -Action 'VTX tools missing from the package'
}

# ---------------------------------------------------------------------------
# Step 4 - Install what is missing
# ---------------------------------------------------------------------------
Set-StepProgress 45 'Installing missing components...'
Write-Log "STEP 4/$TotalSteps : Installing missing components" 'STEP'

# --- 4a. Visual C++ runtimes
if ($InstallVCRuntimes -and $missingVC.Count -gt 0) {
    $vcDir = Join-Path $Source 'Visual-C-Runtimes-All-in-One-Oct-2024'
    $isX64 = [Environment]::Is64BitOperatingSystem
    $argByYear = @{
        '2005' = '/q'; '2008' = '/qb'
        '2010' = '/passive /norestart'; '2012' = '/passive /norestart'
        '2013' = '/passive /norestart'; '2015_2017_2019_2022' = '/passive /norestart'
    }
    $todo = @()
    foreach ($y in $missingVC) {
        $todo += @{ Year = $y; Arch = 'x86' }
        if ($isX64) { $todo += @{ Year = $y; Arch = 'x64' } }
    }
    $vcCache = Join-Path $env:ProgramData 'RecoilKillerSetup\vc'
    if (-not (Test-Path -LiteralPath $vcCache)) { New-Item -ItemType Directory -Path $vcCache -Force | Out-Null }

    $n = 0
    foreach ($p in $todo) {
        $n++
        Set-StepProgress (45 + [int](20 * $n / $todo.Count)) ("Preparing VC++ {0} {1} ({2}/{3})" -f $p.Year, $p.Arch, $n, $todo.Count)

        $key      = "{0}_{1}" -f $p.Year, $p.Arch
        $local    = Join-Path $vcDir ("vcredist{0}_{1}.exe" -f $p.Year, $p.Arch)
        $exe      = $null
        $trusted  = $false

        # 1) a local copy is only used when Microsoft really signed it
        if ((Test-Path -LiteralPath $local) -and (Test-MicrosoftSigned -Path $local)) {
            $exe = $local
            $trusted = $true
            Write-Log "  Local copy is Microsoft-signed, using it : $key" 'OK'
        } elseif (Test-Path -LiteralPath $local) {
            Write-Log "  Local copy is NOT signed by Microsoft - refused : $key" 'ERROR'
        }

        # 2) otherwise pull it from Microsoft (default source for untrusted copies)
        if (-not $exe -and ($VCFromMicrosoft -or -not (Test-Path -LiteralPath $local))) {
            if ($script:OfficialVC.Contains($key)) {
                $cached = Join-Path $vcCache ("vcredist{0}.exe" -f $key)
                if (-not (Test-Path -LiteralPath $cached) -or -not (Test-MicrosoftSigned -Path $cached)) {
                    try {
                        Write-Log "  Downloading official Microsoft runtime : $key"
                        Invoke-WebRequest -Uri $script:OfficialVC[$key] -OutFile $cached -UseBasicParsing
                    } catch {
                        Write-Log "  Download FAILED for $key : $($_.Exception.Message)" 'ERROR'
                    }
                }
                if ((Test-Path -LiteralPath $cached) -and (Test-MicrosoftSigned -Path $cached)) {
                    $exe = $cached
                    $trusted = $true
                } elseif (Test-Path -LiteralPath $cached) {
                    Write-Log "  Downloaded file failed the Microsoft signature check : $key" 'ERROR'
                    Remove-Item -LiteralPath $cached -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # 3) explicit opt-in to run a copy that is not Microsoft-signed
        if (-not $exe -and $AllowLocalVCRuntimes -and (Test-Path -LiteralPath $local)) {
            Write-Log "  Using the UNSIGNED local copy because -AllowLocalVCRuntimes was used : $key" 'WARN'
            $exe = $local
        }

        if (-not $exe) {
            Write-Log "  Skipped $key - no Microsoft-signed installer available." 'ERROR'
            continue
        }
        if (-not $trusted) { Write-Log "  WARNING: running a file that is not Microsoft-signed : $exe" 'WARN' }
        Write-Log "  Installing $key from: $exe" 'DATA'
        try {
            $proc = Start-Process -FilePath $exe -ArgumentList $argByYear[$p.Year] -PassThru -Wait
            switch ($proc.ExitCode) {
                0     { Write-Log ("  VC++ {0} {1} installed" -f $p.Year, $p.Arch) 'OK' }
                3010  { Write-Log ("  VC++ {0} {1} installed (reboot pending)" -f $p.Year, $p.Arch) 'OK'; $rebootNeeded = $true }
                1638  { Write-Log ("  VC++ {0} {1}: newer version present" -f $p.Year, $p.Arch) 'WARN' }
                default { Write-Log ("  VC++ {0} {1}: exit code {2}" -f $p.Year, $p.Arch, $proc.ExitCode) 'WARN' }
            }
        } catch {
            Write-Log ("  VC++ {0} {1} FAILED : {2}" -f $p.Year, $p.Arch, $_.Exception.Message) 'ERROR'
        }
    }
    $script:VCList = Get-InstalledVCRedist
    $stillMissing = @($vcYears | Where-Object { -not (Test-VCRuntimeInstalled -Year $_) })
    if ($stillMissing.Count -eq 0) {
        Add-Result -Requirement 'VC++ install' -Status 'OK' -Action 'All required runtimes installed'
    } else {
        Add-Result -Requirement 'VC++ install' -Status 'FAILED' -Action ("Still missing: {0}" -f ($stillMissing -join ', '))
    }
} elseif ($missingVC.Count -eq 0) {
    Write-Log '  Nothing to do - runtimes already installed.' 'OK'
} else {
    Write-Log '  Runtime installation skipped (-InstallVCRuntimes $false).' 'WARN'
}

# --- 4b. Drivers
if ($InstallDrivers) {
    if ($infFiles.Count -gt 0) {
        $n = 0
        foreach ($inf in $infFiles) {
            $n++
            Set-StepProgress (65 + [int](10 * $n / $infFiles.Count)) ("Installing driver {0}/{1}" -f $n, $infFiles.Count)
            Write-Log ("  Adding driver : {0}" -f $inf.FullName)
            $out = & pnputil.exe /add-driver $inf.FullName /install 2>&1
            $out | ForEach-Object { Write-Log "    $_" 'DATA' }
            if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) {
                Write-Log '    Driver staged successfully.' 'OK'
                if ($LASTEXITCODE -eq 3010) { $rebootNeeded = $true }
            } else {
                Write-Log ("    pnputil returned {0}" -f $LASTEXITCODE) 'WARN'
            }
        }
        Add-Result -Requirement 'Drivers' -Status 'OK' -Action 'pnputil finished for all .inf files'
    } else {
        Write-Log '  No .inf files to install - put your drivers in the DRIVER folder and re-run.' 'WARN'
    }
} else {
    Write-Log '  Driver installation skipped (-InstallDrivers $false).' 'WARN'
}

# ---------------------------------------------------------------------------
# Step 5 - VTX (virtualization).  Deliberately the LAST working step:
#   everything else is already done by now, so when VTX needs a restart
#   nothing has to be repeated after the reboot.
# ---------------------------------------------------------------------------
Set-StepProgress 78 'VTX (virtualization)...'
Write-Log "STEP 5/$TotalSteps : VTX (virtualization)" 'STEP'

$needVtxFix = ((-not $vtOk) -or [bool]$FixVTX) -and -not $ResumeMode

if (-not $vtOk) {
    Write-Con ''
    Write-Con 'VTX is not active - enable it in BIOS/UEFI using this guide:' 'Yellow'
    foreach ($l in $script:VtxGuide.Lines) {
        Write-Con ('  ' + $l) 'Yellow'
        Write-Log ('  GUIDE: ' + $l) 'WARN'
    }
    if ($script:GuideFile) { Write-Con ('  (this guide is saved to {0})' -f $script:GuideFile) 'Gray' }
    if ($OpenVendorGuide -and $script:VtxGuide.VendorUrl) {
        try {
            Start-Process $script:VtxGuide.VendorUrl
            Write-Log ("  Opened the vendor page: {0}" -f $script:VtxGuide.VendorUrl) 'OK'
        } catch {
            Write-Log ("  Could not open the vendor page: {0}" -f $_.Exception.Message) 'WARN'
        }
    }
    Write-Con ''
}

if ($ResumeMode -and $vtOk) {
    Add-Result -Requirement 'VTX after reboot' -Status 'OK' -Action 'VTX is now active'
} elseif ($ResumeMode -and -not $vtOk) {
    Write-Log '  Resumed after reboot but VTX is still not active. Not running the tools twice (reboot loop guard).' 'WARN'
    Add-Result -Requirement 'VTX after reboot' -Status 'FAILED' -Action 'Still not active - enable it in BIOS/UEFI with the guide above'
} elseif ($needVtxFix -and -not $SkipVTXFix) {
    if (-not $vtOk) { Write-Log '  VTX is NOT active - enabling it now.' 'WARN' }
    else            { Write-Log '  VTX enable forced with -FixVTX.' 'WARN' }

    $didFix = $false
    if (Test-Path -LiteralPath $fixVtx1) {
        Write-Con 'Enabling VTX - step 1/2 (GiaiPhongVTX), wait for 100%...' 'Yellow'
        Write-Log '  [1/2] Running GiaiPhongVTX...' 'DATA'
        Start-Process -FilePath $fixVtx1 -Wait
        $didFix = $true
    } else {
        Write-Log '  GiaiPhongVTX.exe not found - skipping preparation step.' 'WARN'
    }
    if (Test-Path -LiteralPath $fixVtx2) {
        Write-Con 'Enabling VTX - step 2/2 (BatVTX)...' 'Yellow'
        Write-Log '  [2/2] Running BatVTX (the VTX enabler)...' 'DATA'
        Start-Process -FilePath $fixVtx2 -Wait
        $didFix = $true
    } else {
        Write-Log '  BatVTX.exe not found - cannot enable VTX automatically.' 'ERROR'
    }

    if ($didFix) {
        Add-Result -Requirement 'VTX enable (BatVTX)' -Status 'OK' -Action 'Enable tools executed - restart required'
        # Schedule automatic continuation after the reboot
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        @{
            LogFile       = $LogFile
            Source        = $Source
            OnlineBaseUri = $OnlineBaseUri
            RunVTXCheck   = [bool]$RunVTXCheck
            SkipVerify    = [bool]$SkipVerify
            VCFromMicrosoft = [bool]$VCFromMicrosoft
            AllowLocalVCRuntimes = [bool]$AllowLocalVCRuntimes
            Detailed      = [bool]$Detailed
            OpenVendorGuide = [bool]$OpenVendorGuide
            MinWindowsBuild = $MinWindowsBuild
            MaxWindowsBuild = $MaxWindowsBuild
            Stage         = 'AfterVTXEnable'
            When          = (Get-Date).ToString('s')
        } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8

        $resumeArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"",
                        '-Resume', '-Source', "`"$Source`"", '-RebootDelaySeconds', $RebootDelaySeconds,
                        '-MinWindowsBuild', $MinWindowsBuild, '-MaxWindowsBuild', $MaxWindowsBuild)
        if ($OnlineBaseUri)          { $resumeArgs += @('-OnlineBaseUri', "`"$OnlineBaseUri`"") }
        if ($RunVTXCheck)            { $resumeArgs += '-RunVTXCheck' }
        if ($SkipVerify)             { $resumeArgs += '-SkipVerify' }
        if ($VCFromMicrosoft)        { $resumeArgs += '-VCFromMicrosoft' }
        if ($AllowLocalVCRuntimes)   { $resumeArgs += '-AllowLocalVCRuntimes' }
        if ($Detailed)               { $resumeArgs += '-Detailed' }
        if ($OpenVendorGuide)        { $resumeArgs += '-OpenVendorGuide' }
        if (-not $InstallVCRuntimes) { $resumeArgs += @('-InstallVCRuntimes', '0') }
        if (-not $InstallDrivers)    { $resumeArgs += @('-InstallDrivers', '0') }

        $resumeCmd = 'powershell.exe ' + ($resumeArgs -join ' ')
        New-ItemProperty -Path $RunOnceKey -Name $RunOnceName -Value $resumeCmd -PropertyType String -Force | Out-Null
        Write-Log '  Resume entry registered (RunOnce) - the script continues after the restart.' 'OK'
        $scheduledResume = $true
    } else {
        Add-Result -Requirement 'VTX enable (BatVTX)' -Status 'FAILED' -Action 'VTX tools missing from the package'
    }
} elseif ($needVtxFix -and $SkipVTXFix) {
    Write-Log '  VTX is not active but -SkipVTXFix was used - nothing done.' 'WARN'
    Add-Result -Requirement 'VTX enable (BatVTX)' -Status 'MISSING' -Action 'Skipped by -SkipVTXFix'
} else {
    Write-Log '  VTX is already active - nothing to do.' 'OK'
}

# The pack's own VTX checker is only useful once VTX is actually active
if ($RunVTXCheck -and -not $scheduledResume -and (Test-Path -LiteralPath $checkVtx)) {
    Write-Con 'Launching CheckVTX - all green means VTX is OK.' 'Cyan'
    Start-Process -FilePath $checkVtx -Wait
}

# ---------------------------------------------------------------------------
# Step 6 - Final report
# ---------------------------------------------------------------------------
Set-StepProgress 96 'Writing report...'
Write-Log "STEP 6/$TotalSteps : Final report" 'STEP'

if ($scheduledResume) {
    Write-Con ''
    Write-Con 'VTX enable tools finished. A restart is required to apply the change.' 'Yellow'
    Write-Con 'The final report is shown automatically after the restart.' 'Yellow'
    Write-Log 'VTX enable done - the final verdict is printed after the restart.' 'WARN'
} else {
    $blocking = @($Results | Where-Object { $_.Status -in @('MISSING', 'FAILED') -and $_.Requirement -notlike '*Protection off*' })

    Write-Con ''
    Write-Con ('-' * 46) 'Cyan'
    if ($blocking.Count -eq 0) {
        Write-Con '  recoil-killer  :  READY  (OK)' 'Green'
    } else {
        Write-Con '  recoil-killer  :  NOT READY  (FAIL)' 'Red'
        foreach ($b in $blocking) { Write-Con ("     - {0}" -f $b.Requirement) 'Red' }
    }
    Write-Con ('-' * 46) 'Cyan'
    Write-Con ("Log: {0}" -f $LogFile) 'Gray'

    Write-Log 'FINAL REPORT' 'STEP'
    foreach ($r in $Results) { Write-Log ("  [{0}] {1} - {2}" -f $r.Status, $r.Requirement, $r.Action) 'DATA' }
    if ($blocking.Count -eq 0) {
        Write-Log 'RESULT: all requirements satisfied.' 'OK'
    } else {
        Write-Log ("RESULT: NOT ready - missing/failed: {0}" -f (($blocking | ForEach-Object { $_.Requirement }) -join ', ')) 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Resume cleanup / reboot handling
# ---------------------------------------------------------------------------
if ($ResumeMode) {
    # Job done - remove the continuation so it never runs again
    Cleanup-ResumeEntry
    Write-Log 'Resume entry cleaned up.' 'OK'
}

if ($scheduledResume) {
    Write-Con '' 
    Write-Con ("Restarting in {0} seconds to apply the VTX change." -f $RebootDelaySeconds) 'Yellow'
    Write-Con 'The setup continues automatically after Windows restarts.' 'Yellow'
    Write-Con 'To cancel the restart:  shutdown /a' 'Gray'
    Write-Log ("Automatic restart in {0} seconds (RunOnce resume registered)." -f $RebootDelaySeconds) 'WARN'
    Set-StepProgress 100 'Restarting...'
    shutdown.exe /r /t $RebootDelaySeconds /c "recoil-killer setup: restart required to finish"
} elseif ($rebootNeeded) {
    if ($RebootWhenDone) {
        Write-Con ("Restarting in {0} seconds..." -f $RebootDelaySeconds) 'Yellow'
        shutdown.exe /r /t $RebootDelaySeconds /c "recoil-killer setup: restart required"
    } else {
        Write-Con 'A restart is required to finish. Restart when convenient.' 'Yellow'
    }
} else {
    Set-StepProgress 100 'Finished'
}
