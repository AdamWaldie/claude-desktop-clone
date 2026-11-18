<#
.SYNOPSIS
    Installs "clones" of the Claude Desktop app: one isolated profile + one
    desktop shortcut per account.

.DESCRIPTION
    For each profile name you pass, this script:
      * creates an isolated Chromium data directory under %APPDATA% (required so
        the Cowork VM works -- see the note in the loop below),
      * copies the launcher scripts into -InstallDir\bin (so the shortcuts keep
        working even if you delete this repo),
      * creates a "Claude (<Name>)" shortcut on your Desktop that opens the app
        with that profile, using the real Claude icon,
      * gives each profile its own Claude Code/Cowork memory + settings store
        (CLAUDE_CONFIG_DIR) by default, isolated the same way the Chromium
        login already is -- see -ConfigDir / -SharedConfig below.

    Whichever profile name you pass to -ReuseDefaultFor can reuse the account the
    normally-installed app is already signed into, so you don't have to log in
    again for that account.

.PARAMETER Profile
    One or more profile names. Default: Work, Personal.

.PARAMETER InstallDir
    Where the launcher scripts (bin\) live. Default: %USERPROFILE%\ClaudeProfiles.
    NOTE: profile *data* always lives under %APPDATA%\<name>, not here -- this is
    required for the Cowork VM to start (the native VM service resolves rootfs.vhdx
    under %APPDATA% regardless of --user-data-dir).

.PARAMETER ReuseDefaultFor
    Name of the profile whose shortcut opens the normal, default Claude instance
    (the Start-menu app, with its login and ~/.claude memory) instead of a
    fresh, separate profile. Matched case-insensitively against -Profile
    entries.

.PARAMETER ReuseDefaultForWork
    Legacy alias for -ReuseDefaultFor Work. Deprecated: prefer -ReuseDefaultFor
    <name>, which works for any profile name, not just "Work". If -ReuseDefaultFor
    is also passed explicitly, it takes precedence.

.PARAMETER ConfigDir
    Optional hashtable overriding the Claude Code / Cowork config directory
    (CLAUDE_CONFIG_DIR) for specific profiles. Every profile gets one by
    default (see -SharedConfig to opt out entirely) -- pass this only to
    point a particular profile's store somewhere other than the default
    "$env:USERPROFILE\.claude-<profile name, lowercased>".

.PARAMETER SharedConfig
    Skip per-profile CLAUDE_CONFIG_DIR isolation and fall back to the old
    default: every profile shares the same ~/.claude Claude Code/Cowork
    memory and settings store. Use this if you specifically want that
    shared behaviour; most setups don't.

.PARAMETER NoUpdateWatcher
    Don't install (and remove, if present) the per-user scheduled task that
    offers to restart profiles still running an old Claude build after an
    update. Re-clicking a stale profile's shortcut still offers the restart.

.PARAMETER WatchIntervalMinutes
    How often the update watcher checks, in minutes. Default: 10.

.PARAMETER NoAutoRestart
    Make the watcher always ask before restarting a stale profile. By default
    an idle profile (no Claude Code / Cowork sessions open) is restarted
    silently and only a busy one prompts.

.PARAMETER NoAutoSync
    Don't let the watcher keep bin\ in sync with this repo. By default, when
    the repo is on -TrackBranch and its scripts change, the watcher re-runs
    this Setup with the same options (saved in bin\install.json).

.PARAMETER TrackBranch
    Branch the auto-sync follows. Default: master. While the repo has another
    branch checked out, nothing is synced.

.EXAMPLE
    .\Setup.ps1
    # Creates "Claude (Work)" and "Claude (Personal)" on the Desktop, each
    # with its own isolated login AND its own Claude Code/Cowork memory.

.EXAMPLE
    .\Setup.ps1 -Profile Work,Personal -ReuseDefaultFor Personal

.EXAMPLE
    # Works the same from cmd.exe too -- no arrays or hashtables needed on
    # the command line, since -Profile and -ConfigDir both default sensibly:
    # powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -ReuseDefaultFor Personal

.EXAMPLE
    # Deprecated alias, still supported:
    .\Setup.ps1 -Profile Personal,Side,Client -ReuseDefaultForWork

.EXAMPLE
    # Override just one profile's config store (others still get the default):
    .\Setup.ps1 -ConfigDir @{ Personal = "$env:USERPROFILE\.claude-personal-old" }

.EXAMPLE
    # Opt back into the old shared ~/.claude behaviour for every profile:
    .\Setup.ps1 -SharedConfig
#>
[CmdletBinding()]
param(
    [string[]]$Profile = @('Work', 'Personal'),
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'ClaudeProfiles'),
    [string]$ReuseDefaultFor = $null,
    [switch]$ReuseDefaultForWork,
    [hashtable]$ConfigDir = @{},
    [switch]$SharedConfig,
    [switch]$NoUpdateWatcher,
    [ValidateRange(1, 1440)]
    [int]$WatchIntervalMinutes = 10,
    [switch]$NoAutoRestart,
    [switch]$NoAutoSync,
    [string]$TrackBranch = 'master'
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# `powershell -File Setup.ps1 -Profile Work,Personal` (cmd.exe, shortcuts, the
# watcher's unattended re-run) passes ONE string "Work,Personal", not an array.
# Split it, or that becomes a single bogus profile named "Work,Personal".
$Profile = @($Profile | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Deprecated alias: -ReuseDefaultForWork means -ReuseDefaultFor Work, unless
# -ReuseDefaultFor was already given explicitly (which wins).
if ($ReuseDefaultForWork -and -not $ReuseDefaultFor) {
    $ReuseDefaultFor = 'Work'
}

# Extracts the highest-resolution icon out of an .exe into a standalone .ico.
# This is what makes shortcut icons survive app updates: the Claude .exe lives
# under C:\Program Files\WindowsApps\Claude_<version>__...\app\Claude.exe, and
# that <version> folder is DELETED whenever Claude auto-updates. A shortcut whose
# IconLocation points straight at that versioned path goes blank after the next
# update + icon-cache rebuild (typically noticed after a reboot). Copying the
# icon once to a stable file under bin\ and pointing every shortcut there avoids
# the dangling path entirely.
function Export-AppIcon {
    param([string]$ExePath, [string]$IcoPath, [int]$Size = 256)
    Add-Type -AssemblyName System.Drawing
    $sig = @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern int PrivateExtractIcons(string lpszFile, int nIconIndex, int cxIcon, int cyIcon, IntPtr[] phicon, int[] piconid, int nIcons, int flags);
[DllImport("user32.dll")]
public static extern bool DestroyIcon(IntPtr hIcon);
'@
    $api = Add-Type -MemberDefinition $sig -Name 'IconExtract' -Namespace 'Win32Native' -PassThru

    # Writes a 32-bit, full-colour, PNG-compressed .ico (Vista+ format) from a
    # Bitmap. We deliberately do NOT use Icon.Save(): saving an Icon created from
    # an HICON drops the colour plane and writes only the 1-bit AND mask, which is
    # why the icon came out grey. Rendering to a Bitmap and packing the PNG
    # ourselves preserves colour and alpha.
    function Write-IcoFromBitmap {
        param([System.Drawing.Bitmap]$Bmp, [string]$Path)
        $ms = New-Object System.IO.MemoryStream
        $Bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $png = $ms.ToArray(); $ms.Dispose()
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
        $bw = New-Object System.IO.BinaryWriter($fs)
        $bw.Write([uint16]0)            # reserved
        $bw.Write([uint16]1)            # type = icon
        $bw.Write([uint16]1)            # image count
        $dim = if ($Bmp.Width -ge 256) { 0 } else { [byte]$Bmp.Width }   # 0 means 256
        $bw.Write([byte]$dim)           # width
        $bw.Write([byte]$dim)           # height
        $bw.Write([byte]0)              # palette count
        $bw.Write([byte]0)              # reserved
        $bw.Write([uint16]1)            # colour planes
        $bw.Write([uint16]32)           # bits per pixel
        $bw.Write([uint32]$png.Length)  # image size
        $bw.Write([uint32]22)           # offset = 6 (dir) + 16 (entry)
        $bw.Write($png)
        $bw.Flush(); $bw.Close()
    }

    $h = New-Object IntPtr[] 1
    $id = New-Object int[] 1
    try {
        $n = $api::PrivateExtractIcons($ExePath, 0, $Size, $Size, $h, $id, 1, 0)
        if ($n -gt 0 -and $h[0] -ne [IntPtr]::Zero) {
            $ico = [System.Drawing.Icon]::FromHandle($h[0])
            $bmp = $ico.ToBitmap()       # full 32bpp colour + alpha
            Write-IcoFromBitmap -Bmp $bmp -Path $IcoPath
            $bmp.Dispose(); $ico.Dispose()
            return $true
        }
    } catch {
    } finally {
        if ($h[0] -ne [IntPtr]::Zero) { $api::DestroyIcon($h[0]) | Out-Null }
    }
    # Fallback: managed helper (lower-res, but still full colour and a stable file).
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        $bmp = $ico.ToBitmap()
        Write-IcoFromBitmap -Bmp $bmp -Path $IcoPath
        $bmp.Dispose(); $ico.Dispose()
        return $true
    } catch { return $false }
}

# --- Verify the Claude Desktop app is installed and find its icon ---------
$pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pkg) {
    throw "Claude Desktop app not found. Install it from https://claude.ai/download (or the Microsoft Store) first."
}
$iconExe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
Write-Host "Found Claude $($pkg.Version) at $($pkg.InstallLocation)" -ForegroundColor Green

# --- Copy launcher scripts to a stable location ---------------------------
$binDir = Join-Path $InstallDir 'bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Copy-Item (Join-Path $scriptRoot 'Launch-Claude.ps1') $binDir -Force
Copy-Item (Join-Path $scriptRoot 'launch.vbs') $binDir -Force
Copy-Item (Join-Path $scriptRoot 'Watch-ClaudeUpdates.ps1') $binDir -Force
Copy-Item (Join-Path $scriptRoot 'watch.vbs') $binDir -Force
$vbs = Join-Path $binDir 'launch.vbs'

# profiles.json records each profile's data dir + config dir so the update
# watcher can relaunch a stale profile exactly as its shortcut would. Merge with
# any existing entries so running Setup for a subset of profiles keeps the rest.
$manifestPath = Join-Path $binDir 'profiles.json'
$manifest = [ordered]@{}
if (Test-Path $manifestPath) {
    try {
        foreach ($p in (Get-Content $manifestPath -Raw | ConvertFrom-Json).profiles) { $manifest[$p.name] = $p }
    } catch { Write-Warning "Ignoring unreadable $manifestPath; it will be rewritten." }
}

# --- Extract the Claude icon to a STABLE path (survives app updates) -------
# See Export-AppIcon above for why pointing IconLocation at the versioned
# WindowsApps .exe makes icons disappear after updates/reboots.
$icoPath = Join-Path $binDir 'claude.ico'
if (Export-AppIcon -ExePath $iconExe -IcoPath $icoPath) {
    $iconLocation = "$icoPath,0"
    Write-Host "Extracted stable icon to $icoPath" -ForegroundColor Green
} else {
    # Last resort: fall back to the versioned exe (may go blank after an update).
    $iconLocation = "$iconExe,0"
    Write-Warning "Could not extract a standalone icon; falling back to the app exe (icon may break after updates)."
}

# --- Create a profile + desktop shortcut for each name --------------------
$desktop = [Environment]::GetFolderPath('Desktop')
$wsh = New-Object -ComObject WScript.Shell

foreach ($name in $Profile) {
    if ($ReuseDefaultFor -and $name -ieq $ReuseDefaultFor) {
        # Open the normal Start-menu instance via MSIX activation (launch.vbs
        # "--default"). Claude moved the default instance's data from
        # %APPDATA%\Claude to %LOCALAPPDATA%\Claude-Data\claude_<hash>, so a
        # --user-data-dir of %APPDATA%\Claude now opens an EMPTY, signed-out
        # profile. Activation always opens the real default: same login, same
        # ~/.claude memory (no CLAUDE_CONFIG_DIR, so -ConfigDir/-SharedConfig
        # don't apply), and Claude's own updater restarts it -- so it is not
        # added to the watcher's profiles.json.
        $lnkPath = Join-Path $desktop "Claude ($name).lnk"
        $sc = $wsh.CreateShortcut($lnkPath)
        $sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $sc.Arguments = '"{0}" "--default"' -f $vbs
        $sc.IconLocation = $iconLocation
        $sc.Description = "Claude Desktop - $name profile (default instance)"
        $sc.WorkingDirectory = $binDir
        $sc.Save()
        if ($manifest.Contains($name)) { $manifest.Remove($name) }
        Write-Host "  [$name] opens the normal Start-menu Claude (same login + ~/.claude memory)"
        Write-Host "  -> created shortcut: $lnkPath" -ForegroundColor Cyan
        continue
    } else {
        # IMPORTANT: isolated profiles must live under %APPDATA% (NOT an arbitrary
        # folder such as -InstallDir). Claude Desktop's "Cowork" feature runs its
        # agent inside a Hyper-V VM, and the native VM service resolves the VM image
        # (rootfs.vhdx) at  %APPDATA%\<profile-name>\vm_bundles  -- it ignores the
        # --user-data-dir flag. If the data dir lives elsewhere, Electron provisions
        # the VM under the data dir but the VM service looks under %APPDATA% and dies
        # with "VHDX file not found", so the Cowork workspace never starts. Putting
        # the data dir under %APPDATA% makes both components agree (exactly how the
        # -ReuseDefaultFor profile already behaves).
        $dataDir = Join-Path $env:APPDATA $name
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        Write-Host "  [$name] isolated profile at $dataDir"
    }

    $lnkPath = Join-Path $desktop "Claude ($name).lnk"
    $sc = $wsh.CreateShortcut($lnkPath)
    $sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $cfg = $null
    if ($SharedConfig) {
        # Opt-out path: every profile shares the default ~/.claude store.
        $sc.Arguments = '"{0}" "{1}"' -f $vbs, $dataDir
    } else {
        # Default: give this profile its own Claude Code/Cowork memory +
        # settings store, same as the Chromium login above. -ConfigDir can
        # override the auto-derived path for a specific profile; every other
        # profile still gets one, it's just computed rather than typed out --
        # this also means the common case needs no hashtable literal on the
        # command line, so it works the same from cmd.exe as from PowerShell.
        $cfg = if ($ConfigDir.ContainsKey($name)) {
            $ConfigDir[$name]
        } else {
            Join-Path $env:USERPROFILE ".claude-$($name.ToLowerInvariant())"
        }
        New-Item -ItemType Directory -Force -Path $cfg | Out-Null
        $sc.Arguments = '"{0}" "{1}" "{2}"' -f $vbs, $dataDir, $cfg
        Write-Host "      memory/config dir: $cfg"
    }
    $sc.IconLocation = $iconLocation
    $sc.Description = "Claude Desktop - $name profile"
    $sc.WorkingDirectory = $binDir
    $sc.Save()
    Write-Host "  -> created shortcut: $lnkPath" -ForegroundColor Cyan

    $manifest[$name] = [ordered]@{ name = $name; dataDir = $dataDir; configDir = $cfg }
}

@{ profiles = @($manifest.Values) } | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8

# install.json: where these scripts came from + the options used, so the
# watcher can re-run this Setup unattended when the repo's scripts change.
# Only explicitly passed options are saved, so defaults stay computed.
$saved = [ordered]@{}
foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [switch]) { $v = [bool]$v }
    $saved[$k] = $v
}
[ordered]@{
    sourceDir     = $scriptRoot
    trackBranch   = $TrackBranch
    autoSync      = -not $NoAutoSync
    noAutoRestart = [bool]$NoAutoRestart
    setupHash     = (Get-FileHash $MyInvocation.MyCommand.Path -Algorithm SHA256).Hash
    setupArgs     = $saved
} | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $binDir 'install.json') -Encoding UTF8

# --- Update watcher ---------------------------------------------------------
# Claude's updater only relaunches the default instance; a cloned profile that
# is open during an update keeps running the old build. A per-user scheduled
# task (no admin needed) runs Watch-ClaudeUpdates.ps1 hidden at logon and every
# -WatchIntervalMinutes, and offers to restart any profile left on an old build.
$taskName = 'claude-desktop-clone update watcher'
if ($NoUpdateWatcher) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Update watcher not installed (-NoUpdateWatcher)." -ForegroundColor DarkYellow
} else {
    try {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\wscript.exe') `
            -Argument ('"{0}"' -f (Join-Path $binDir 'watch.vbs')) -WorkingDirectory $binDir
        $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes $WatchIntervalMinutes)
        $logon = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        $task = New-ScheduledTask -Action $action -Trigger @($repeat, $logon) -Principal $principal -Settings $settings `
            -Description 'Offers to restart claude-desktop-clone profiles left running an outdated Claude build after an update.'
        try {
            Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
        } catch {
            # Some machines refuse a logon trigger for non-admins; the repeating
            # trigger alone still catches every update within the interval.
            $task.Triggers = @($repeat)
            Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
        }
        Write-Host "Update watcher scheduled: '$taskName' (every $WatchIntervalMinutes min)." -ForegroundColor Green
    } catch {
        Write-Warning "Could not register the update watcher task: $($_.Exception.Message)"
        Write-Warning "Profiles still update when fully restarted; re-clicking a stale profile's shortcut also offers a restart."
    }
}

Write-Host ""
Write-Host "Done. Open each shortcut and sign in to the matching account." -ForegroundColor Green
Write-Host "Tip: clicking a shortcut again just focuses that profile's window (single instance per profile)."
