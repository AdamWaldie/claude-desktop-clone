<#
.SYNOPSIS
    Snapshots every location where Claude Desktop could plausibly cache state
    OUTSIDE a Chromium --user-data-dir, to help find what's leaking across
    isolated profiles.

.DESCRIPTION
    --user-data-dir (see Launch-Claude.ps1) isolates the Chromium profile:
    cookies, Local Storage, IndexedDB, the per-profile "Local State" file.
    That part of isolation is confirmed working (separate accounts show up
    correctly in each window). But at least one report exists of an org's
    network/capability restriction applying to a *different*, unrestricted
    profile while both were signed in under the same Windows user -- which
    means something outside the Chromium profile dir is shared per Windows
    user (or per machine) instead of per profile.

    This script doesn't diagnose the cause by itself. It snapshots the
    candidate shared-state locations so you can diff two runs and see what
    actually changed:

      1. Run this once while only the unaffected profile is open and things
         are working normally.
      2. Reproduce the cross-profile issue (open the other profile, hit the
         error).
      3. Run this again.
      4. Diff the two JSON reports. Whatever appears/changes between them is
         the leak candidate -- report it back with the file/entry name so a
         fix (redirecting it per-profile, or reporting it as a product gap)
         can be scoped precisely instead of guessed at.

    Also captured: each renderer process's --desktop-managed-config argument.
    This is a JSON blob Claude Desktop itself builds fresh per launch
    (forceLoginOrgUUIDs, loginSsoOrgDomain, deploymentMode, configOrgDelivered,
    etc.) describing whether that instance is org-managed. Comparing this
    field between two profiles WHILE BOTH ARE RUNNING AND THE ISSUE IS
    ACTIVE is a more direct test than the file diff above:
      - If the unrestricted profile's config correctly still shows
        deploymentMode "1p" / null org fields even while it's hitting the
        org's block, the leak isn't in this local launch config at all --
        it's being applied server-side (e.g. per-request, keyed by a device
        identifier rather than by which profile's session token is used).
      - If the unrestricted profile's config has picked up the other org's
        fields, that's the bleed, caught directly, and it's a bug in how the
        app decides this value per launch rather than per Windows user.

    Locations checked:
      - %LOCALAPPDATA%\Claude (a machine/user-wide folder some Electron apps
        use in addition to --user-data-dir; distinct from any profile dir)
      - The MSIX package's protected per-user storage
        (%LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalState and \Settings),
        resolved dynamically via Get-AppxPackage so it survives version bumps
      - Windows Credential Manager entries whose target name mentions Claude
        or Anthropic (via cmdkey /list -- DPAPI-backed, scoped per Windows
        user, not per process)
      - HKCU registry keys under Software\Claude and Software\Anthropic

    Read-only. Makes no changes to the system.

.PARAMETER OutFile
    Where to write the JSON report. Default: a timestamped file under
    $env:TEMP.

.EXAMPLE
    .\Diagnose-ProfileBleed.ps1 -OutFile "$env:TEMP\claude-state-before.json"
    # ... reproduce the issue ...
    .\Diagnose-ProfileBleed.ps1 -OutFile "$env:TEMP\claude-state-after.json"
    Compare-Object (Get-Content "$env:TEMP\claude-state-before.json") (Get-Content "$env:TEMP\claude-state-after.json")
#>
param(
    [string]$OutFile = (Join-Path $env:TEMP "claude-state-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)

$report = [ordered]@{
    Timestamp         = (Get-Date).ToString('o')
    RunningInstances  = @()
    ManagedConfigByProfile = @()
    LocalAppDataDir   = $null
    AppxLocalState    = $null
    AppxSettings      = $null
    CredentialManager = @()
    RegistryKeys      = @()
}

# --- Which profiles are currently running -----------------------------------
try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction Stop
    $report.RunningInstances = $procs | ForEach-Object {
        $dir = if ($_.CommandLine -match '--user-data-dir=("?)(.*?)\1(\s|$)') { $Matches[2] } else { '(none / default)' }
        [ordered]@{ ProcessId = $_.ProcessId; UserDataDir = $dir; CommandLine = $_.CommandLine }
    }

    # Each renderer's --desktop-managed-config is built fresh per launch and
    # describes whether that instance is org-managed (forceLoginOrgUUIDs,
    # loginSsoOrgDomain, deploymentMode, configOrgDelivered, ...). Pulling it
    # out per profile lets you compare it directly across profiles instead of
    # only diffing files on disk -- see the note in .DESCRIPTION above.
    $report.ManagedConfigByProfile = $procs |
        Where-Object { $_.CommandLine -match '--type=renderer' -and $_.CommandLine -match '--desktop-managed-config=' } |
        ForEach-Object {
            $dir = if ($_.CommandLine -match '--user-data-dir=("?)(.*?)\1(\s|$)') { $Matches[2] } else { '(none / default)' }
            $cfg = if ($_.CommandLine -match '--desktop-managed-config="(.*?)"\s+--\S') { $Matches[1] -replace '\\"', '"' } else { $null }
            [ordered]@{ ProcessId = $_.ProcessId; UserDataDir = $dir; ManagedConfig = $cfg }
        }
} catch { }

# --- %LOCALAPPDATA%\Claude ----------------------------------------------------
$localAppData = Join-Path $env:LOCALAPPDATA 'Claude'
if (Test-Path $localAppData) {
    $report.LocalAppDataDir = Get-ChildItem $localAppData -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object @{n='Path'; e={$_.FullName.Substring($localAppData.Length + 1)}}, Length, LastWriteTimeUtc
}

# --- MSIX package's protected per-user storage --------------------------------
# This is a completely separate storage area from --user-data-dir: Windows
# App Model gives every installed package one such folder per Windows user,
# addressed by PackageFamilyName (not by anything the app's command line
# controls), so it's the single most likely place for cross-profile bleed.
try {
    $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction Stop |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) {
        $pkgRoot = Join-Path $env:LOCALAPPDATA "Packages\$($pkg.PackageFamilyName)"
        $localState = Join-Path $pkgRoot 'LocalState'
        $settings = Join-Path $pkgRoot 'Settings'
        if (Test-Path $localState) {
            $report.AppxLocalState = Get-ChildItem $localState -Recurse -File -ErrorAction SilentlyContinue |
                Select-Object @{n='Path'; e={$_.FullName.Substring($localState.Length + 1)}}, Length, LastWriteTimeUtc
        }
        if (Test-Path $settings) {
            $report.AppxSettings = Get-ChildItem $settings -Recurse -File -ErrorAction SilentlyContinue |
                Select-Object @{n='Path'; e={$_.FullName.Substring($settings.Length + 1)}}, Length, LastWriteTimeUtc
        }
    }
} catch { }

# --- Windows Credential Manager ------------------------------------------------
# DPAPI-backed, scoped to the Windows user account -- if Claude Desktop (or
# Electron's safeStorage) stores an auth/device-trust token here, it would be
# visible to every profile run by this Windows user regardless of
# --user-data-dir. cmdkey only lists target names, not secret values.
try {
    $cmdkeyOutput = cmdkey /list 2>$null
    $current = $null
    foreach ($line in $cmdkeyOutput) {
        if ($line -match '^\s*Target:\s*(.+)$') {
            if ($current -and $current -match 'claude|anthropic') {
                $report.CredentialManager += $current
            }
            $current = $Matches[1].Trim()
        }
    }
    if ($current -and $current -match 'claude|anthropic') {
        $report.CredentialManager += $current
    }
} catch { }

# --- Registry --------------------------------------------------------------
foreach ($keyPath in @('HKCU:\Software\Claude', 'HKCU:\Software\Anthropic')) {
    if (Test-Path $keyPath) {
        $report.RegistryKeys += Get-ChildItem $keyPath -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $_.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' }
    }
}

$report | ConvertTo-Json -Depth 6 | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "Report written to $OutFile" -ForegroundColor Green
Write-Host "Run again after reproducing the issue, then diff the two files." -ForegroundColor Cyan
if ($report.ManagedConfigByProfile.Count -ge 2) {
    Write-Host ""
    Write-Host "Multiple profiles running -- compare ManagedConfigByProfile in the report directly:" -ForegroundColor Yellow
    $report.ManagedConfigByProfile | Format-List | Out-String | Write-Host
}
