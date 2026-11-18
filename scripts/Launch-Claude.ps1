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

    Stale-instance check: when Claude updates, its own updater relaunches only
    the default (Start-menu) instance. A cloned profile that was already open
    keeps running the OLD build, and clicking its shortcut again only focuses
    that old process (single-instance lock). So before launching, this script
    looks for a running instance of THIS profile that was started from an
    older package folder and offers to restart it on the installed version.

.PARAMETER ProfileDir
    Absolute path to the data directory for this instance. A fresh directory =
    a fresh, isolated login. Point it at "$env:APPDATA\Claude" to reuse the
    account that the normally-installed app is already signed into.

.PARAMETER Default
    Open the default Claude instance the same way the Start menu does, instead
    of an isolated profile. Ignores the other parameters. Claude now keeps the
    default instance's data under %LOCALAPPDATA%\Claude-Data, not
    %APPDATA%\Claude, so pointing --user-data-dir at %APPDATA%\Claude no longer
    reuses the normal login. Activation always opens the right one.

.PARAMETER ConfigDir
    Optional: give this instance its own Claude Code / Cowork config + memory
    store by pointing CLAUDE_CONFIG_DIR at a dedicated directory.

.PARAMETER Restart
    If this profile is already running, close it and start it again without
    asking (used by Watch-ClaudeUpdates.ps1 after you confirm there).

.PARAMETER NoUpdateCheck
    Skip the stale-instance check and just launch (old behaviour).

.EXAMPLE
    .\Launch-Claude.ps1 -ProfileDir "$env:APPDATA\Work" -ConfigDir "$env:USERPROFILE\.claude-work"
#>
param(
    [string]$ProfileDir,

    # Open the normal, default Claude instance exactly as the Start menu does
    # (MSIX activation, no --user-data-dir). Used for the -ReuseDefaultFor
    # profile: same login, data folder and ~/.claude memory as the Start-menu
    # app, and Claude's own updater restarts it.
    [switch]$Default,

    [string]$ConfigDir,

    [switch]$Restart,

    [switch]$NoUpdateCheck
)

function Show-Message {
    param([string]$Message, [string]$Buttons = 'OK', [string]$Image = 'Error')
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        # DefaultDesktopOnly keeps the box in front: this script runs hidden, so
        # there is no owner window and a plain MessageBox can open behind others.
        return [System.Windows.MessageBox]::Show($Message, 'claude-desktop-clone', $Buttons, $Image,
            'None', [System.Windows.MessageBoxOptions]::DefaultDesktopOnly)
    } catch {
        Write-Warning $Message
        return 'None'
    }
}

# Pulls the "6.6395.0.0" out of a ...\WindowsApps\Claude_6.6395.0.0_x64__...\ path.
function Get-PackageVersionFromPath {
    param([string]$Path)
    if ($Path -match 'Claude_([0-9.]+)_') { return $Matches[1] }
    return '0.0'
}

# Extracts the --user-data-dir value from a command line (quoted or bare).
function Get-UserDataDir {
    param([string]$CommandLine)
    if ($CommandLine -match '--user-data-dir=(?:"([^"]+)"|(\S+))') {
        $v = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        return $v.TrimEnd('\')
    }
    return $null
}

if ($Default) {
    # Activation takes no arguments, which is exactly what we want here. The
    # app id is read from the manifest, never hard-coded.
    try {
        $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction Stop |
            Sort-Object Version -Descending | Select-Object -First 1
        $app = @(($pkg | Get-AppxPackageManifest).Package.Applications.Application |
            Where-Object { $_.Executable -ieq 'app\Claude.exe' })[0]
        Start-Process "shell:AppsFolder\$($pkg.PackageFamilyName)!$($app.Id)"
        exit 0
    } catch {
        Show-Message "Could not open the default Claude app.`n`n$($_.Exception.Message)" | Out-Null
        exit 1
    }
}

if (-not $ProfileDir) {
    Show-Message "Launch-Claude.ps1 needs -ProfileDir <dir> (or -Default)." | Out-Null
    exit 1
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

# 2) Fallback: scan WindowsApps directly (newest version first, compared as a
#    version, not as text, so 10.x sorts above 9.x).
if (-not $exe) {
    $exe = Get-ChildItem 'C:\Program Files\WindowsApps\Claude_*__*\app\Claude.exe' -ErrorAction SilentlyContinue |
        Sort-Object { [version](Get-PackageVersionFromPath $_.FullName) } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

if (-not $exe -or -not (Test-Path $exe)) {
    Show-Message "Claude Desktop app was not found.`n`nInstall it from the Microsoft Store / claude.ai/download first, then run again." | Out-Null
    exit 1
}

# Package root, e.g. C:\Program Files\WindowsApps\Claude_<version>_x64__<hash>
$installRoot = Split-Path -Parent (Split-Path -Parent $exe)
$profileFull = [System.IO.Path]::GetFullPath($ProfileDir).TrimEnd('\')

# --- Stale-instance check --------------------------------------------------
# Find this profile's Electron *browser* process: a Claude.exe from a
# WindowsApps\Claude_* package (not the embedded claude-code CLI, which is also
# called claude.exe), without --type= (those are renderer/GPU children), whose
# --user-data-dir matches ours.
$running = $null
if ($Restart -or -not $NoUpdateCheck) {
    $running = Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -match '\\WindowsApps\\' -and
            $_.CommandLine -notmatch '--type=' -and
            (Get-UserDataDir $_.CommandLine) -ieq $profileFull
        } | Select-Object -First 1
}

if ($running) {
    $isStale = -not $running.ExecutablePath.StartsWith($installRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
    $doRestart = [bool]$Restart
    if ($isStale -and -not $Restart) {
        $old = Get-PackageVersionFromPath $running.ExecutablePath
        $new = Get-PackageVersionFromPath $installRoot
        $answer = Show-Message ("This profile is still running Claude $old, but Claude $new is installed.`n`n" +
            "Profile: $profileFull`n`n" +
            "Restart it now on the new version? Any Claude Code / Cowork sessions running in this window will be stopped.") 'YesNo' 'Question'
        $doRestart = ("$answer" -eq 'Yes')
    }

    if ($doRestart) {
        # Ask nicely first (Claude may only hide to the tray on WM_CLOSE), then
        # kill the whole tree so no old-version child (claude-code, MCP servers)
        # keeps the profile's singleton lock or the old package files alive.
        try { (Get-Process -Id $running.ProcessId -ErrorAction Stop).CloseMainWindow() | Out-Null } catch { }
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Process -Id $running.ProcessId -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
        if (Get-Process -Id $running.ProcessId -ErrorAction SilentlyContinue) {
            & taskkill.exe /PID $running.ProcessId /T /F | Out-Null
        }
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Process -Id $running.ProcessId -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
        # Give Chromium a moment to release the profile's singleton lock.
        Start-Sleep -Milliseconds 750
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
# Quoted so a data dir containing spaces stays one argument.
Start-Process -FilePath $exe -ArgumentList "--user-data-dir=`"$ProfileDir`""
