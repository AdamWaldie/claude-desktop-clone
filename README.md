# claude-desktop-clone

Run **multiple isolated instances of the Claude Desktop app on Windows** — one
per account (e.g. *Work* and *Personal*) — side by side, each with its own
login, history, and settings.

The official Claude Desktop app (installed from the Microsoft Store / claude.ai)
only supports **one account at a time** and refuses to open a second window.
This repo works around that with a tiny, dependency-free launcher.

> 🇻🇳 Bản tóm tắt tiếng Việt ở [cuối README](#tiếng-việt--quickstart).

---

## How it works

The Claude Desktop app is an **Electron / Chromium** application. Chromium
accepts the standard `--user-data-dir` flag, and it keys its *single-instance
lock* on that directory. So:

> **Different `--user-data-dir` → different lock → a second instance runs,
> signed into a different account.**

The only Windows-specific wrinkle is that the app is shipped as an **MSIX
package**, so its executable lives under a versioned, permission-restricted
path:

```
C:\Program Files\WindowsApps\Claude_<version>_x64__<hash>\app\Claude.exe
```

The launcher resolves that path at runtime via `Get-AppxPackage` (so it survives
app updates) and starts it with a chosen data directory:

```powershell
Claude.exe --user-data-dir="C:\Users\<you>\ClaudeProfiles\personal"
```

That's the whole trick. No patching, no copying the app, no admin rights.

> **Credit:** the `--user-data-dir` technique for Claude is from
> [Zoltak-Dev/ai-multi-instance](https://github.com/Zoltak-Dev/ai-multi-instance).
> This repo is a small, native (PowerShell + VBScript) reimplementation focused
> on Claude only, with desktop shortcuts and a one-command setup.

---

## Requirements

- Windows 10/11
- The official **Claude Desktop app** installed
  ([claude.ai/download](https://claude.ai/download) or Microsoft Store)
- No admin rights, no Python, no extra dependencies

---

## Quick start

```powershell
git clone https://github.com/vodongha/claude-desktop-clone.git
cd claude-desktop-clone

# Create "Claude (Work)" + "Claude (Personal)" shortcuts on your Desktop.
# -ReuseDefaultFor <name> keeps your already-signed-in account for that profile.
powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -ReuseDefaultFor Personal
```

That's the whole command — `-Profile` isn't needed since `Work,Personal` is
already the default, and every profile gets its own isolated Claude
Code/Cowork memory store automatically too (see below). It works exactly the
same from **cmd.exe** as from PowerShell, since nothing on the command line
needs PowerShell-only syntax (arrays, hashtables) — see
[Isolate Claude Code / Cowork memory per profile](#isolate-claude-code--cowork-memory-per-profile).

Then:

1. Double-click **Claude (Personal)** → your existing account (no re-login).
2. Double-click **Claude (Work)** → a fresh window; sign in to the other
   account.

Both windows now run at the same time, fully isolated — separate login *and*
separate Claude Code/Cowork memory.

### Custom profiles

```powershell
# Any names you like; each gets its own isolated login + shortcut.
powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -Profile Personal,ClientA,ClientB
```

Note: `-Profile` with more than one name needs a real PowerShell array, so
call this one from an actual PowerShell prompt (`.\scripts\Setup.ps1 -Profile
Personal,ClientA,ClientB`), not `powershell -File` from cmd.exe or a nested
process — that form doesn't split the comma-separated value and will
silently create one mis-named profile shared by all three instead of three
separate ones. If you only need the `Work,Personal` default, the Quick start
command above sidesteps this entirely since it doesn't pass `-Profile` at all.

### Different install location

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -InstallDir "D:\ClaudeProfiles"
```

### Isolate Claude Code / Cowork memory per profile

**This is on by default.** Login (Chromium `--user-data-dir`) and the
embedded **Claude Code / Cowork** memory/settings store (`CLAUDE_CONFIG_DIR`)
are both isolated per profile without passing anything extra — `Setup.ps1`
auto-derives `~/.claude-<profile name, lowercased>` for each one (e.g.
`~/.claude-personal`, `~/.claude-work`).

To point a specific profile's store somewhere else, override just that entry
with `-ConfigDir` (a real hashtable, so call the script directly rather than
via `powershell -File`):

```powershell
& .\scripts\Setup.ps1 -ConfigDir @{ Personal = "$env:USERPROFILE\.claude-personal-old" }
```

To go back to the old shared behaviour instead — every profile using the same
`~/.claude` store — pass `-SharedConfig`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -SharedConfig
```

Manual equivalent for any launcher:

```text
wscript.exe launch.vbs "<profile-data-dir>" "<claude-config-dir>"
```

---

## What gets created

```
%USERPROFILE%\ClaudeProfiles\
└── bin\
    ├── Launch-Claude.ps1     # resolves the MSIX exe, launches with --user-data-dir
    ├── launch.vbs            # runs the .ps1 hidden (no console flash)
    └── claude.ico            # icon extracted to a STABLE path (survives updates)

%APPDATA%\                     # profile DATA lives here (required for Cowork VM)
├── Personal\                 # isolated Chromium profile (login, history, cache, VM)
└── Work\                     # (only if not reusing the default login)

Desktop\
├── Claude (Work).lnk
└── Claude (Personal).lnk
```

The shortcuts point at the copied `bin\` scripts, so you can delete the cloned
repo afterwards and everything keeps working. Profile *data* lives under
`%APPDATA%\<name>` (not under `ClaudeProfiles\`) — this is required so Claude's
**Cowork** VM can start; see [Cowork limitations](#cowork-vm-limitations) below.

---

## Usage notes

- **Re-clicking a shortcut** focuses that profile's existing window instead of
  opening a duplicate — exactly the normal single-instance behaviour, but scoped
  per profile.
- **App updates** are handled automatically: the launcher re-resolves the exe
  path each time via `Get-AppxPackage`.
- **Shortcut icons survive updates.** `Setup.ps1` extracts the Claude icon once
  to `bin\claude.ico` (a stable path) and points every shortcut there. Pointing a
  shortcut straight at the versioned `WindowsApps\Claude_<version>\...\Claude.exe`
  would go blank after the next update deletes that folder — which is why the
  icon is copied out to a fixed location instead.
- **Switching the "main" app:** the regular Start-menu Claude icon still uses
  `%APPDATA%\Claude`, i.e. the same login as whichever profile was created with
  `-ReuseDefaultFor` (or the deprecated `-ReuseDefaultForWork` alias, which
  reuses it for a profile named "Work").

---

## Optional: build a real `.exe`

If you'd rather have a single executable than a `.vbs`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Build-Exe.ps1
# -> dist\ClaudeLauncher.exe  (takes -ProfileDir "<path>")
```

This uses [`ps2exe`](https://github.com/MScholtes/PS2EXE). Note that unsigned
ps2exe binaries can trip SmartScreen / antivirus heuristics — the `.vbs`
launcher created by `Setup.ps1` is the recommended, friction-free option.

---

## Uninstall

```powershell
# Remove the shortcuts only:
powershell -ExecutionPolicy Bypass -File scripts\Uninstall.ps1

# Remove shortcuts AND the isolated profile data (signs you out, clears history):
powershell -ExecutionPolicy Bypass -File scripts\Uninstall.ps1 -RemoveData
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Claude Desktop app not found" | Install it from [claude.ai/download](https://claude.ai/download) and run `Setup.ps1` again. |
| Shortcut does nothing | Run `scripts\Launch-Claude.ps1 -ProfileDir <dir>` directly in PowerShell to see the error. |
| Second window won't open | Make sure the two shortcuts use **different** `--user-data-dir` paths (check shortcut *Target*). |
| Icon is blank or grey | Re-run `Setup.ps1` (current versions extract the icon to a stable `bin\claude.ico`, so it survives updates). If a stale thumbnail lingers, clear the icon cache: `ie4uinit.exe -show`, or `Stop-Process -Name explorer -Force; Start-Process explorer`. |
| **"Failed to start Claude's workspace" / `VHDX file not found`** in a cloned profile | The profile's data dir is **outside `%APPDATA%`**, so the Cowork VM service can't find `rootfs.vhdx`. Re-run `Setup.ps1` (current version puts profiles under `%APPDATA%`). To migrate an existing profile without re-login, move `ClaudeProfiles\<name>` → `%APPDATA%\<name>` and update the shortcut's first argument to `%APPDATA%\<name>`. Do **not** use a junction/symlink for `vm_bundles` — the VM service refuses to open reparse points. |
| **Cowork won't start in one profile while another is open** (`HYPERVISOR_SERVICE_ERROR`, *"a virtual machine … with the specified identifier already exists"*) | Expected — see [Cowork VM limitations](#cowork-vm-limitations). Only one profile can run the Cowork VM at a time; quit the other profile (or reboot to clear a stale VM) before launching. |
| **One profile's org network/domain restrictions apply to the other profile too** (e.g. a work org's outbound allow-list also blocks a personal account, even though sign-in is correctly separated) | Unconfirmed root cause, still open — see [Cross-profile org restriction bleed](#cross-profile-org-restriction-bleed) and run `scripts\Diagnose-ProfileBleed.ps1` to help pin down what's actually shared. |

---

## Cowork VM limitations

Claude Desktop's **Cowork** feature (the agentic workspace, scheduled tasks, and
artifact storage) runs inside a per-machine **Hyper-V VM**, not just an Electron
window. Two consequences for multi-profile use:

1. **Profile data must live under `%APPDATA%`.** The native VM service resolves
   the VM image (`rootfs.vhdx`) at `%APPDATA%\<profile-name>\vm_bundles`,
   *ignoring* `--user-data-dir`. `Setup.ps1` therefore places isolated profiles
   under `%APPDATA%\<name>` (the `-ReuseDefaultFor` profile already uses
   `%APPDATA%\Claude`, which is why it works out of the box). A data dir
   anywhere else makes Cowork fail with `VHDX file not found`.

2. **Only one Cowork VM can run at a time.** The Hyper-V compute system is *not*
   scoped per profile, so launching Cowork in a second profile while another's
   VM is running fails with `HYPERVISOR_SERVICE_ERROR` /
   *"identifier already exists"*. You can keep both **windows** open for chat, but
   the VM-backed workspace only runs in one profile at a time — quit (or stop the
   workspace of) the other profile first. The plain chat / login isolation that
   this tool provides is unaffected.

---

## Cross-profile org restriction bleed

**Status: investigated, not yet confirmed.** Reported once, on one machine, with a
work org that enforces outbound network/domain allow-listing (client-data
policy). Documented here so the investigation isn't lost and can be picked up
or repeated.

**Symptom:** with two profiles isolated via `--user-data-dir` (per
[How it works](#how-it-works)) and each correctly signed into a different
account — confirmed by the account shown in each window — *both* windows hit
the same "blocked by allow list" network error that should only apply to the
org-restricted account. Login/account isolation worked; some org-level
network or capability restriction did not stay scoped to the profile that
should have had it.

**Ruled out:**
- No VPN or network security agent (Zscaler/Netskope/Umbrella-style) running
  on the machine — it's a personal, unmanaged machine, not the org's.
- Not simply "both profiles share `%APPDATA%\Claude`" — the profiles were
  genuinely separate data directories and showed separate accounts.

**Leading theory (unconfirmed):** something scoped to the Windows user
account rather than to the Chromium `--user-data-dir` — most plausibly
Windows Credential Manager, a DPAPI-backed secret, or a device-trust/
last-authenticated-identity marker that Electron's `safeStorage` (or a
device-trust mechanism in Claude Desktop) keys off the OS user. If the
org-restricted account's policy caches such a marker per-Windows-user, having
that account signed in *anywhere* on the machine could apply its restriction
to every profile under that same Windows user, regardless of data-dir
isolation. This would explain why removing the org-restricted profile
entirely (not just quitting it) resolved the other profile's error.

**Not yet ruled out:** a network-path cause (e.g. Anthropic's
[Tenant Restrictions](https://support.claude.com/en/articles/13198485-enforce-network-level-access-control-with-tenant-restrictions),
a proxy-level org allow-list keyed by a header) — a test off the home network
(e.g. a mobile hotspot) with both profiles rebuilt and signed in
simultaneously was never actually completed, so this can't be told apart
cleanly from the credential-store theory yet.

**Constraint: both profiles need to run side by side, at the same time, on
one Windows account.** That rules out two workarounds that would otherwise be
the obvious answer:

- *"Never have both signed in at once"* isn't acceptable — simultaneous use is
  the actual use case, not an edge case to avoid.
- *A separate Windows user account per org* would isolate Credential
  Manager/DPAPI/device-trust state cleanly, but Windows only shows one user's
  desktop at a time (Fast User Switching swaps the whole session, it doesn't
  let two users' windows sit on screen together), so it can't give you side-by-
  side either. Off the table for this use case regardless of setup cost.

So the only real fix is finding **where** the leaking state actually lives and
scoping *that* per profile too — the same trick `-ConfigDir` already applies
to Claude Code/Cowork memory, extended to whatever else isn't following
`--user-data-dir`. `scripts/Diagnose-ProfileBleed.ps1` exists to find that:
it lists every location a Windows app can plausibly cache state outside a
Chromium `--user-data-dir` (`%LOCALAPPDATA%\Claude`, the MSIX package's
protected `LocalState` folder, Windows Credential Manager entries, and
relevant registry keys) and snapshots each one's contents.

To use it: run once with only one profile signed in and working normally,
run it again right after the *other* profile hits the cross-profile error,
and diff the two reports. Whatever changed between the runs — a new
Credential Manager entry, a new file under `LocalState`, a registry value —
is the leak candidate. From there:

- If it's a file or registry value inside something process-launchable (e.g.
  `LocalState`), it may be possible to redirect it per profile the same way
  `-ConfigDir` redirects `CLAUDE_CONFIG_DIR` — worth trying once the exact
  path is known.
- If it's genuinely Windows Credential Manager/DPAPI with no override, that's
  an OS-level, per-user store with no per-process scoping mechanism — the
  finding itself would need reporting as a product gap (Claude Desktop would
  need to key that storage off `--user-data-dir`, e.g. via a scoped
  credential target name, the way its own Chromium profile isolation already
  does for cookies/local storage).

```powershell
.\scripts\Diagnose-ProfileBleed.ps1 -OutFile "$env:TEMP\claude-state-before.json"
# ... reproduce the cross-profile block, then:
.\scripts\Diagnose-ProfileBleed.ps1 -OutFile "$env:TEMP\claude-state-after.json"
Compare-Object (Get-Content "$env:TEMP\claude-state-before.json") (Get-Content "$env:TEMP\claude-state-after.json")
```

---

## How is this different from running the app twice?

The app enforces a single instance via the Chromium singleton lock, which is
tied to the data directory. Clicking the normal icon twice hits the same lock
and just focuses the open window. Giving each instance its own data directory
gives each its own lock — and its own account.

---

## Disclaimer

This is an unofficial community tool. It does not modify, repackage, or
redistribute the Claude app — it only launches the official, installed app with
a standard Chromium command-line flag. Use in accordance with Anthropic's terms.

---

## Tiếng Việt — Quickstart

Chạy **nhiều cửa sổ Claude Desktop cùng lúc trên Windows**, mỗi cái một tài
khoản (ví dụ *Công việc* và *Cá nhân*), đăng nhập/lịch sử/cài đặt tách biệt.

App chính thức chỉ cho 1 tài khoản và không mở cửa sổ thứ hai. Repo này lách
bằng cờ `--user-data-dir` của Chromium: mỗi thư mục dữ liệu khác nhau = một khoá
instance riêng = một cửa sổ + một tài khoản chạy song song.

```powershell
git clone https://github.com/vodongha/claude-desktop-clone.git
cd claude-desktop-clone
powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -ReuseDefaultForWork
```

- Tạo 2 icon trên Desktop: **Claude (Work)** và **Claude (Personal)**.
- `-ReuseDefaultForWork`: icon Work dùng lại tài khoản đang đăng nhập (khỏi
  login lại). Icon Personal mở cửa sổ mới để đăng nhập tài khoản còn lại.
- Bấm lại icon → focus đúng cửa sổ của tài khoản đó (không mở trùng).

Muốn tách riêng cả **bộ nhớ Claude Code / Cowork** cho từng profile (mặc định
chỉ tách login, còn `~/.claude` thì dùng chung), trỏ `CLAUDE_CONFIG_DIR` qua
`-ConfigDir`:

```powershell
& .\scripts\Setup.ps1 -ConfigDir @{ Personal = "$env:USERPROFILE\.claude-personal" }
```

Gỡ: `scripts\Uninstall.ps1` (thêm `-RemoveData` để xoá luôn dữ liệu/đăng nhập).

Yêu cầu: Windows 10/11 + đã cài app Claude Desktop. Không cần quyền admin,
không cần Python.

---

## Contributing

`develop` is the integration branch; `master` is the stable, published state. Branch `feature/*`
or `bug/*` off `develop` and PR into `develop`; branch `hotfix/*` off `master` for urgent fixes.
Merging `develop → master` releases, and `sync-develop.yml` merges `master` back into `develop`.
CI runs PSScriptAnalyzer on every PR. See [CLAUDE.md](CLAUDE.md#git-workflow) for details.

## License

[MIT](LICENSE)

---

## Built with

[Claude Code](https://claude.ai/code) by Anthropic. 🤖
