<#
.SYNOPSIS
    Checks whether any cloned Claude profile is still running an older build
    than the installed Claude Desktop package, and offers to restart it.

.DESCRIPTION
    When Claude Desktop updates itself, the updater relaunches only the default
    (Start-menu) instance. Profiles started by this tool with --user-data-dir
    keep running the previous build until they are fully closed, and re-clicking
    their shortcut only focuses the old process.

    This script reads profiles.json (written by Setup.ps1, next to this file),
    finds each profile's running Claude.exe, and compares the package folder it
    was started from with the currently installed one. A stale profile is
    relaunched through Launch-Claude.ps1 with the same data dir and
    CLAUDE_CONFIG_DIR:
      * idle (no Claude Code / Cowork child processes) -> restarted silently;
      * busy -> you're asked first, once per new version. Declining is
        remembered (update-state.json) until the next Claude version;
        re-clicking the profile's shortcut will still offer the restart.

    Self-sync: if install.json (written by Setup.ps1) names a source repo, and
    that repo is on the tracked branch (default master) and its scripts differ
    from the installed copies in bin\, Setup.ps1 is re-run from the repo with
    the originally used options -- so merging/pulling a change is enough, no
    manual Setup re-run.

    Setup.ps1 registers this as a per-user scheduled task (no admin) that runs
    hidden via watch.vbs at logon and every few minutes.

.PARAMETER Restart
    Restart stale profiles without asking, even when busy.

.PARAMETER NoAutoRestart
    Always ask before restarting, even when the profile is idle. (Setup.ps1
    -NoAutoRestart persists this in install.json.)

.PARAMETER Quiet
    Never show a dialog or change anything; only report stale profiles.
    Useful to check the state by hand.

.EXAMPLE
    .\Watch-ClaudeUpdates.ps1 -Quiet
    # Lists profiles running an outdated Claude build, changes nothing.
#>
[CmdletBinding()]
param(
    [switch]$Restart,
    [switch]$NoAutoRestart,
    [switch]$Quiet
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $here 'profiles.json'
$statePath = Join-Path $here 'update-state.json'
$installPath = Join-Path $here 'install.json'
$launch = Join-Path $here 'Launch-Claude.ps1'

# --- Self-sync bin\ from the source repo -------------------------------------
$install = $null
if (Test-Path $installPath) {
    try { $install = Get-Content $installPath -Raw | ConvertFrom-Json } catch { }
}
if ($install -and $install.autoSync -and $install.sourceDir -and (Test-Path $install.sourceDir)) {
    $src = $install.sourceDir
    # Only follow the tracked branch, so checking out a feature branch to work
    # on the tool never installs unmerged scripts. Reads .git\HEAD directly (no
    # git.exe dependency). A source without .git (e.g. a zip) syncs on change.
    $branchOk = $true
    $headFile = Join-Path (Split-Path -Parent $src) '.git\HEAD'
    if (Test-Path $headFile -PathType Leaf) {
        $head = (Get-Content $headFile -Raw).Trim()
        $branchOk = ($head -eq "ref: refs/heads/$($install.trackBranch)")
    } elseif (Test-Path (Join-Path (Split-Path -Parent $src) '.git')) {
        $branchOk = $false   # worktree/.git file: not the main checkout, don't follow it
    }
    if ($branchOk) {
        $synced = 'Launch-Claude.ps1', 'launch.vbs', 'Watch-ClaudeUpdates.ps1', 'watch.vbs'
        $differs = $false
        foreach ($f in $synced + 'Setup.ps1') {
            $s = Join-Path $src $f
            if (-not (Test-Path $s)) { continue }
            $srcHash = (Get-FileHash $s -Algorithm SHA256).Hash
            if ($f -eq 'Setup.ps1') {
                $srcSetupHash = $srcHash
                $differs = $differs -or ($srcHash -ne $install.setupHash)
            } else {
                $d = Join-Path $here $f
                $differs = $differs -or -not (Test-Path $d) -or ($srcHash -ne (Get-FileHash $d -Algorithm SHA256).Hash)
            }
        }
        if ($differs -and -not $Quiet) {
            $setupArgs = @{}
            foreach ($p in $install.setupArgs.PSObject.Properties) {
                if ($p.Name -eq 'ConfigDir') {
                    $h = @{}; foreach ($c in $p.Value.PSObject.Properties) { $h[$c.Name] = "$($c.Value)" }
                    $setupArgs.ConfigDir = $h
                } elseif ($p.Value -is [bool]) {
                    if ($p.Value) { $setupArgs[$p.Name] = $true }
                } elseif ($p.Value -is [System.Array]) {
                    $setupArgs[$p.Name] = [string[]]$p.Value
                } elseif ($null -ne $p.Value -and "$($p.Value)" -ne '') {
                    $setupArgs[$p.Name] = $p.Value
                }
            }
            $log = Join-Path $here 'sync.log'
            "[$(Get-Date -Format s)] repo scripts changed; re-running Setup.ps1 from $src" | Add-Content $log
            try {
                & (Join-Path $src 'Setup.ps1') @setupArgs *>> $log
            } catch {
                "[$(Get-Date -Format s)] Setup failed: $($_.Exception.Message)" | Add-Content $log
            }
            # Record which Setup we ran even if that (possibly older) Setup does
            # not write install.json itself, so the same change isn't re-applied
            # on every run.
            try {
                $i2 = Get-Content $installPath -Raw | ConvertFrom-Json
                if ($srcSetupHash -and $i2.setupHash -ne $srcSetupHash) {
                    $i2.setupHash = $srcSetupHash
                    $i2 | ConvertTo-Json -Depth 5 | Set-Content -Path $installPath -Encoding UTF8
                }
            } catch { }
            # The next scheduled run uses the freshly installed scripts.
            exit 0
        } elseif ($differs) {
            Write-Output "bin\ is out of date with $src (would re-run Setup.ps1)."
        }
    }
}
if ($install -and $install.noAutoRestart) { $NoAutoRestart = $true }

if (-not (Test-Path $manifestPath)) {
    Write-Verbose "No profiles.json next to this script; run Setup.ps1 first."
    exit 0
}

function Get-PackageVersionFromPath {
    param([string]$Path)
    if ($Path -match 'Claude_([0-9.]+)_') { return $Matches[1] }
    return '0.0'
}

function Get-UserDataDir {
    param([string]$CommandLine)
    if ($CommandLine -match '--user-data-dir=(?:"([^"]+)"|(\S+))') {
        $v = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        return $v.TrimEnd('\')
    }
    return $null
}

$pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pkg) { exit 0 }
$installRoot = $pkg.InstallLocation.TrimEnd('\')
$current = "$($pkg.Version)"

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$declined = @{}
if (Test-Path $statePath) {
    try {
        $s = Get-Content $statePath -Raw | ConvertFrom-Json
        foreach ($p in $s.declined.PSObject.Properties) { $declined[$p.Name] = "$($p.Value)" }
    } catch { }
}

# All Claude Desktop browser processes started with an explicit data dir. The
# default Start-menu instance has no --user-data-dir and is never touched (its
# own updater restarts it).
$allProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$procs = @($allProcs | Where-Object { $_.Name -eq 'Claude.exe' } |
    Where-Object { $_.ExecutablePath -match '\\WindowsApps\\' -and $_.CommandLine -notmatch '--type=' } |
    ForEach-Object {
        [pscustomobject]@{ Proc = $_; DataDir = (Get-UserDataDir $_.CommandLine) }
    } | Where-Object DataDir)

$stateChanged = $false
foreach ($prof in $manifest.profiles) {
    $dataFull = [System.IO.Path]::GetFullPath($prof.dataDir).TrimEnd('\')
    $hit = $procs | Where-Object { $_.DataDir -ieq $dataFull } | Select-Object -First 1
    if (-not $hit) { continue }

    $exePath = $hit.Proc.ExecutablePath
    if ($exePath.StartsWith($installRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) { continue }

    $old = Get-PackageVersionFromPath $exePath
    $msg = "[$($prof.name)] running Claude $old; installed is $current."

    # Busy = any Claude Code / Cowork process under this profile's main process.
    # Those live as claude-code\<ver>\...\claude.exe (or claude-code-vm) and stay
    # alive while a session is open, so an open session counts as busy.
    $mainId = $hit.Proc.ProcessId
    $ids = @{ $mainId = $true }
    $busy = $false
    do {
        $added = $false
        foreach ($p in $allProcs) {
            if ($ids.ContainsKey([int]$p.ParentProcessId) -and -not $ids.ContainsKey([int]$p.ProcessId)) {
                $ids[[int]$p.ProcessId] = $true; $added = $true
                if ($p.ExecutablePath -match '\\claude-code(-vm)?\\') { $busy = $true }
            }
        }
    } while ($added -and -not $busy)

    if ($Quiet) { Write-Output "$msg (stale, $(if ($busy) { 'busy' } else { 'idle' }))"; continue }

    $doIt = [bool]$Restart -or (-not $busy -and -not $NoAutoRestart)
    if (-not $doIt) {
        if ($declined[$prof.name] -eq $current) { continue }
        Add-Type -AssemblyName PresentationFramework
        $answer = [System.Windows.MessageBox]::Show(
            "Claude was updated to $current, but your '$($prof.name)' profile is still running $old.`n`n" +
            "Restart '$($prof.name)' now on the new version?`n" +
            "Any Claude Code / Cowork sessions running in that window will be stopped.`n`n" +
            "No = don't ask again for this version (re-clicking the shortcut will still offer it).",
            'claude-desktop-clone', 'YesNo', 'Question', 'Yes',
            [System.Windows.MessageBoxOptions]::DefaultDesktopOnly)
        $doIt = ("$answer" -eq 'Yes')
        if (-not $doIt) { $declined[$prof.name] = $current; $stateChanged = $true }
    }

    if ($doIt) {
        Write-Output "$msg Restarting."
        # Launch-Claude.ps1 sets CLAUDE_CONFIG_DIR in *this* process before
        # Start-Process; isolate it per profile so one profile's store never
        # leaks into the next relaunch.
        $saved = $env:CLAUDE_CONFIG_DIR
        Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        try {
            $launchArgs = @{ ProfileDir = $prof.dataDir; Restart = $true }
            if ($prof.configDir) { $launchArgs.ConfigDir = $prof.configDir }
            & $launch @launchArgs
        } finally {
            if ($null -ne $saved) { $env:CLAUDE_CONFIG_DIR = $saved } else { Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        }
        if ($declined.ContainsKey($prof.name)) { $declined.Remove($prof.name); $stateChanged = $true }
    }
}

if ($stateChanged) {
    @{ declined = $declined } | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
}
