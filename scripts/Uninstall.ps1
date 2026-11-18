<#
.SYNOPSIS
    Removes the desktop shortcuts created by Setup.ps1. Optionally deletes the
    profile data (logins/history) too.

.PARAMETER Profile
    Profile names to remove. Default: Work, Personal.

.PARAMETER InstallDir
    Where the launcher scripts (bin\) were installed. Default:
    %USERPROFILE%\ClaudeProfiles. (Profile *data* lives under %APPDATA%\<name>.)

.PARAMETER RemoveData
    Also delete the isolated profile data directories (this signs you out and
    erases that profile's local history). The "Work" profile that reuses
    %APPDATA%\Claude is never deleted.
#>
[CmdletBinding()]
param(
    [string[]]$Profile = @('Work', 'Personal'),
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'ClaudeProfiles'),
    [switch]$RemoveData
)

$desktop = [Environment]::GetFolderPath('Desktop')

foreach ($name in $Profile) {
    $lnk = Join-Path $desktop "Claude ($name).lnk"
    if (Test-Path $lnk) {
        Remove-Item $lnk -Force
        Write-Host "Removed shortcut: $lnk" -ForegroundColor Yellow
    }

    if ($RemoveData) {
        # Profile data lives under %APPDATA%\<name> (see Setup.ps1), not -InstallDir.
        $dataDir = Join-Path $env:APPDATA $name
        if ($name -ieq 'Work' -or $dataDir -ieq (Join-Path $env:APPDATA 'Claude')) {
            # %APPDATA%\Claude is the main login shared with the Start-menu app.
            Write-Host "Skipping data removal for '$name' (shared main login)." -ForegroundColor DarkYellow
        } elseif (Test-Path $dataDir) {
            Remove-Item $dataDir -Recurse -Force
            Write-Host "Removed profile data: $dataDir" -ForegroundColor Yellow
        }
    }
}

# Drop removed profiles from the update watcher's manifest; once none are left,
# remove the watcher's scheduled task too.
$binDir = Join-Path $InstallDir 'bin'
$manifestPath = Join-Path $binDir 'profiles.json'
$remaining = @()
if (Test-Path $manifestPath) {
    try {
        $remaining = @((Get-Content $manifestPath -Raw | ConvertFrom-Json).profiles |
            Where-Object { $Profile -notcontains $_.name })
    } catch { $remaining = @() }
    if ($remaining.Count) {
        @{ profiles = $remaining } | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
    } else {
        Remove-Item $manifestPath, (Join-Path $binDir 'update-state.json'), (Join-Path $binDir 'install.json') -Force -ErrorAction SilentlyContinue
    }
}
if (-not $remaining.Count) {
    $taskName = 'claude-desktop-clone update watcher'
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed scheduled task: $taskName" -ForegroundColor Yellow
    }
}

Write-Host "Done."
