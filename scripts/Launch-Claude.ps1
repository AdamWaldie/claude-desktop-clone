<#
.SYNOPSIS
    Launches the Claude Desktop (Windows MSIX) app with an isolated profile.

.DESCRIPTION
    The Claude Desktop app is built on Electron/Chromium, which accepts the
    standard `--user-data-dir` flag. Each distinct data directory gets its own
    Chromium "singleton" lock, so multiple instances — each signed into a
    different account — can run side by side.

    This script resolves the MSIX executable dynamically via Get-AppxPackage so
    it keeps working after the app updates (the WindowsApps path contains a
    version number that changes on every update).

.PARAMETER ProfileDir
    Absolute path to the data directory for this instance. A fresh directory =
    a fresh, isolated login. Point it at "$env:APPDATA\Claude" to reuse the
    account that the normally-installed app is already signed into.

.PARAMETER Force
    Skip the "another profile is already running" warning below and launch
    unconditionally. Use this for scripted/unattended launches.

.EXAMPLE
    .\Launch-Claude.ps1 -ProfileDir "$env:USERPROFILE\ClaudeProfiles\personal"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileDir,

    # Optional: give this instance its own Claude Code / Cowork config + memory
    # store by pointing CLAUDE_CONFIG_DIR at a dedicated directory. Useful to
    # keep a personal profile's memory separate from a work one.
    [string]$ConfigDir,

    [switch]$Force
)

function Show-Error {
    param([string]$Message)
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show($Message, 'claude-desktop-clone', 'OK', 'Error') | Out-Null
    } catch {
        Write-Error $Message
    }
}

# 1) Preferred: resolve via the Appx package (robust against version changes).
$exe = $null
try {
    $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction Stop |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) {
        $candidate = Join-Path $pkg.InstallLocation 'app\Claude.exe'
        if (Test-Path $candidate) { $exe = $candidate }
    }
} catch { }

# 2) Fallback: scan WindowsApps directly (newest version first).
if (-not $exe) {
    $exe = Get-ChildItem 'C:\Program Files\WindowsApps\Claude_*__*\app\Claude.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}

if (-not $exe -or -not (Test-Path $exe)) {
    Show-Error "Claude Desktop app was not found.`n`nInstall it from the Microsoft Store / claude.ai/download first, then run again."
    exit 1
}

# Warn if a DIFFERENT profile is already running. --user-data-dir isolates
# login and (with -ConfigDir) Claude Code/Cowork memory, but not necessarily
# every org-level network/capability restriction -- see README "Cross-profile
# org restriction bleed" for a case where one org's outbound allow-list
# appeared to affect a second, unrestricted profile while both were signed in
# under the same Windows user. Until that's confirmed/fixed, the safest known
# workaround is to never have two profiles running at once, so nudge for it
# here instead of relying on remembering to check the system tray.
if (-not $Force) {
    try {
        $others = Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction Stop |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -like '*--user-data-dir=*' -and
                $_.CommandLine -notlike "*--user-data-dir=$ProfileDir*"
            }
    } catch {
        $others = $null
    }
    if ($others) {
        $otherDirs = ($others | ForEach-Object {
            if ($_.CommandLine -match '--user-data-dir=("?)(.*?)\1(\s|$)') { $Matches[2] } else { '(unknown profile)' }
        } | Select-Object -Unique) -join ', '
        Add-Type -AssemblyName PresentationFramework
        $choice = [System.Windows.MessageBox]::Show(
            "Another Claude Desktop profile is already running:`n$otherDirs`n`n" +
            "Running two profiles at the same time has been observed to leak one " +
            "org's network/capability restrictions into the other, even though " +
            "login stays isolated (see README: Cross-profile org restriction " +
            "bleed). Recommended: fully quit the other profile first (check the " +
            "system tray, not just the window), then launch this one.`n`n" +
            "Launch anyway?",
            'claude-desktop-clone', 'YesNo', 'Warning')
        if ($choice -eq 'No') { exit 0 }
    }
}

# Ensure the isolated data directory exists.
New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null

# Optionally isolate Claude Code / Cowork config + memory for this instance.
# Start-Process inherits this process's environment, so the launched app (and
# any claude-code it spawns) picks up CLAUDE_CONFIG_DIR.
if ($ConfigDir) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $env:CLAUDE_CONFIG_DIR = $ConfigDir
}

# Launch. Different --user-data-dir => separate singleton lock => parallel instance.
Start-Process -FilePath $exe -ArgumentList "--user-data-dir=$ProfileDir"
