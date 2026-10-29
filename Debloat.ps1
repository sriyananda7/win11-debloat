<#
.SYNOPSIS
    Safe, config-driven Windows 11 debloater. Dry-run by default.

.DESCRIPTION
    Removes preinstalled apps, disables startup items, turns off ads/suggestions
    and some tracking toggles, and clears temp files. Everything it touches is
    listed in config.json so you can fork and edit it.

    Nothing changes unless you pass -Apply.

.EXAMPLE
    .\Debloat.ps1                       # preview only
    .\Debloat.ps1 -Apply                # apply the "safe" lists
    .\Debloat.ps1 -Apply -IncludeOptional
    .\Debloat.ps1 -Apply -SkipCleanup -SkipStartup
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Apply,             # actually make changes (default is preview)
    [switch]$IncludeOptional,   # also process the "optional" app and startup lists
    [switch]$Deprovision,       # also remove apps from the Windows image so new users don't get them
    [switch]$SkipApps,
    [switch]$SkipStartup,
    [switch]$SkipPrivacy,
    [switch]$SkipCleanup,
    [switch]$SkipRestorePoint,
    [switch]$Yes,               # skip the confirmation prompt
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'

# ---------- helpers ----------
function Write-Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Info($t)    { Write-Host "  $t" }
function Write-Preview($t) { Write-Host "  [preview] $t" -ForegroundColor Yellow }
function Write-Done($t)    { Write-Host "  [done] $t" -ForegroundColor Green }
function Write-Skip($t)    { Write-Host "  [skip] $t" -ForegroundColor DarkGray }
function Write-Warn($t)    { Write-Host "  [warn] $t" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Apps matching these patterns are NEVER removed, even if listed in config.json.
$Protected = @(
    'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller',
    'Microsoft.SecHealthUI', 'Microsoft.Windows.*', 'MicrosoftWindows.*', 'Windows.*', 'windows.*',
    'Microsoft.NET.*', 'Microsoft.VCLibs.*', 'Microsoft.UI.Xaml.*', 'Microsoft.WindowsAppRuntime.*',
    'Microsoft.WinAppRuntime.*', 'MicrosoftCorporationII.WinAppRuntime.*',
    'Microsoft.AAD.*', 'Microsoft.AccountsControl', 'Microsoft.LockApp', 'Microsoft.BioEnrollment',
    'Microsoft.MicrosoftEdge*', 'Microsoft.DirectXRuntime',
    'Microsoft.WindowsCalculator', 'Microsoft.WindowsNotepad', 'Microsoft.WindowsTerminal',
    'Microsoft.Paint', 'Microsoft.ScreenSketch',
    'Microsoft.*VideoExtension*', 'Microsoft.*ImageExtension*', 'Microsoft.WebMediaExtensions',
    'Microsoft.GamingServices', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxGameCallableUI',
    '*NVIDIA*', 'AdvancedMicroDevices*', '*Realtek*', '*Intel*', '*DTS*', '*Dolby*'
)
# Narrow exceptions to the patterns above (explicitly safe to remove).
$ProtectedExceptions = @('Microsoft.Windows.DevHome')

function Test-Protected($name) {
    if ($ProtectedExceptions -contains $name) { return $false }
    foreach ($p in $Protected) { if ($name -like $p) { return $true } }
    return $false
}

function Set-Reg($path, $name, $value, $type = 'DWord') {
    if (-not $Apply) { Write-Preview "$path -> $name = $value"; return }
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
    Write-Done "$name = $value"
}

function Set-StartupApproved($approvedKey, $itemName) {
    if (-not $Apply) { Write-Preview "disable startup item '$itemName'"; return }
    if (-not (Test-Path $approvedKey)) { New-Item -Path $approvedKey -Force | Out-Null }
    # First byte 03 = disabled (02 = enabled). This is what Task Manager writes.
    $bytes = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)
    New-ItemProperty -Path $approvedKey -Name $itemName -Value $bytes -PropertyType Binary -Force | Out-Null
    Write-Done "disabled startup item '$itemName'"
}

# ---------- preflight ----------
if (-not (Test-Admin)) {
    Write-Error "Run this from an elevated PowerShell (Right-click -> Run as administrator)."
}
if ([Environment]::OSVersion.Version.Build -lt 22000) {
    Write-Warn "This was written for Windows 11 (build 22000+). Continue at your own risk."
}
if ($PSVersionTable.PSEdition -eq 'Core') {
    Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue
}
if (-not (Test-Path $ConfigPath)) { Write-Error "Config not found: $ConfigPath" }
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path (Join-Path $logDir ("debloat-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null

try {
    if ($Apply) {
        Write-Host "`nAPPLY MODE: changes will be made to this PC." -ForegroundColor Red
        if (-not $Yes) {
            $ans = Read-Host "Type YES to continue"
            if ($ans -ne 'YES') { Write-Host "Cancelled."; return }
        }
    } else {
        Write-Host "`nPREVIEW MODE: nothing will be changed. Re-run with -Apply to make changes." -ForegroundColor Yellow
    }

    # ---------- restore point ----------
    if ($Apply -and -not $SkipRestorePoint) {
        Write-Section 'Restore point'
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description 'Before Win11-Debloat' -RestorePointType MODIFY_SETTINGS
            Write-Done 'restore point created'
        } catch {
            Write-Warn "Could not create restore point ($($_.Exception.Message))."
            Write-Warn "Windows allows one per 24h by default. Continuing."
        }
    }

    # ---------- apps ----------
    if (-not $SkipApps) {
        Write-Section 'Apps'
        $targets = @($Config.apps.safe) + @($Config.apps.oem)
        if ($IncludeOptional) { $targets += @($Config.apps.optional) }
        foreach ($name in ($targets | Where-Object { $_ } | Select-Object -Unique)) {
            if (Test-Protected $name) { Write-Skip "$name (protected)"; continue }
            $pkgs = Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue
            if (-not $pkgs) { Write-Skip "$name (not installed)"; continue }
            if (-not $Apply) { Write-Preview "remove $name"; continue }
            foreach ($p in $pkgs) {
                try {
                    Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
                    Write-Done "removed $($p.Name)"
                } catch { Write-Warn "failed: $($p.Name): $($_.Exception.Message)" }
            }
            if ($Deprovision) {
                Get-AppxProvisionedPackage -Online |
                    Where-Object { $_.DisplayName -like $name } |
                    ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null }
            }
        }
    }

    # ---------- startup ----------
    if (-not $SkipStartup) {
        Write-Section 'Startup items'
        $patterns = @($Config.startup.disable)
        if ($IncludeOptional) { $patterns += @($Config.startup.optional) }

        $runKeys = @(
            @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
               Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
            @{ Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
               Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        )
        $folders = @(
            @{ Dir = [Environment]::GetFolderPath('Startup')
               Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
            @{ Dir = [Environment]::GetFolderPath('CommonStartup')
               Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
        )

        foreach ($pattern in ($patterns | Where-Object { $_ })) {
            $found = $false
            foreach ($k in $runKeys) {
                if (-not (Test-Path $k.Run)) { continue }
                foreach ($n in ((Get-Item $k.Run).Property | Where-Object { $_ -like $pattern })) {
                    $found = $true; Set-StartupApproved $k.Approved $n
                }
            }
            foreach ($f in $folders) {
                if (-not (Test-Path $f.Dir)) { continue }
                foreach ($file in (Get-ChildItem $f.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $pattern })) {
                    $found = $true; Set-StartupApproved $f.Approved $file.Name
                }
            }
            if (-not $found) { Write-Skip "$pattern (not in startup)" }
        }
    }

    # ---------- privacy / ads ----------
    if (-not $SkipPrivacy) {
        Write-Section 'Ads, suggestions and privacy toggles'
        foreach ($s in $Config.registry) {
            Set-Reg $s.path $s.name $s.value $(if ($s.type) { $s.type } else { 'DWord' })
        }
    }

    # ---------- disk cleanup ----------
    if (-not $SkipCleanup) {
        Write-Section 'Disk cleanup (never touches Downloads)'
        foreach ($dir in @($env:TEMP, "$env:WINDIR\Temp")) {
            if (-not (Test-Path $dir)) { continue }
            $bytes = (Get-ChildItem $dir -Recurse -Force -File -ErrorAction SilentlyContinue |
                      Measure-Object Length -Sum).Sum
            $mb = [math]::Round(($bytes / 1MB), 1)
            if (-not $Apply) { Write-Preview "clear $dir (~$mb MB)"; continue }
            Get-ChildItem $dir -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Done "cleared $dir (~$mb MB, files in use were skipped)"
        }

        if (-not $Apply) {
            Write-Preview 'empty Recycle Bin'
            Write-Preview 'run Windows Disk Cleanup (update leftovers, thumbnails, shader cache, delivery optimization)'
        } else {
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            Write-Done 'Recycle Bin emptied'
            $cats = @('Temporary Files', 'Thumbnail Cache', 'Windows Update Cleanup',
                      'Delivery Optimization Files', 'D3D Shader Cache')
            $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
            foreach ($c in $cats) {
                $key = Join-Path $base $c
                if (Test-Path $key) {
                    New-ItemProperty -Path $key -Name 'StateFlags1337' -Value 2 -PropertyType DWord -Force | Out-Null
                }
            }
            Write-Info 'Running Disk Cleanup (this can take a few minutes)...'
            Start-Process cleanmgr.exe -ArgumentList '/sagerun:1337' -Wait
            Write-Done 'Disk Cleanup finished'
        }
    }

    Write-Section 'Finished'
    if ($Apply) { Write-Host '  Restart your PC to finish applying changes.' -ForegroundColor Green }
    else        { Write-Host '  Preview complete. Re-run with -Apply to make these changes.' -ForegroundColor Yellow }
}
finally {
    Stop-Transcript | Out-Null
}
