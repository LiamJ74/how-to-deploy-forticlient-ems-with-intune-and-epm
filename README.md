# FortiClient EMS enrollment via Intune — without breaking Entra authentication

**English** · [Français](README.fr.md)

> The comments inside the scripts are in French.

📘 **Step-by-step setup, verification, upgrade and troubleshooting: [detailed guide](docs/GUIDE.md).**

Deploying **FortiClient EMS** through Intune looks trivial and is not. This repository holds a
working pattern, and — more useful — the list of dead ends that look right and are not.

Everything here is anonymised: no invitation code, no EMS serial, no tenant id, no device name.
The FortiClient installer itself is **not** included; you generate your own from your EMS console.

---

## The problem

FortiClient EMS enrollment needs an **Entra token**, and that token only exists inside the
**interactive session of a signed-in user** (WAM / TokenBroker / PRT).

A Win32 app installed by Intune in **SYSTEM** context runs in **session 0**. No WebAccount, no
PRT. The client installs fine, then loops forever on `Endpoint state: Azure Token Required` and
sits at `status 0x1D` (pending authentication) in

```
HKLM\SOFTWARE\Fortinet\FortiClient\FA_ESNAC
```

Everything *looks* healthy: the MSI succeeded, the service runs, the invitation code is in the
registry. Nothing enrolls.

## What does not work

| Attempt | Why it fails |
|---|---|
| Install as SYSTEM | session 0, no Entra token — the core problem |
| `FortiESNAC.exe -r <code>` from a logon script | manifest is `requireAdministrator` → **UAC prompt at every logon**, error 1223 for standard users |
| Elevate `FortiESNAC.exe` with Intune EPM | EPM substitutes a **virtual account** `MEM\<NETBIOS>_<user>_$` (SID authority `S-1-5-110`) with no TokenBroker cache → no WebAccount, no PRT → `0xCAA100D8` → `azuretoken is invalid` |
| Scheduled task at logon | runs outside the interactive desktop; EPM elevation is not reliable there |
| Reinstalling a stuck client | `0x1D` is a *pending* transaction. Only a **reboot** finalises it. Reinstalling restarts the same wait |

> **Never target `FortiESNAC.exe` or `FortiTray.exe` with an EPM rule.** That single mistake
> costs weeks: enrollment fails with a server-side–looking error while every local check passes.

## What works

Split the privileged part from the identity part.

```
Intune Win32 app  (SYSTEM)     install.ps1
                               ├── copies the EMS installer + logon-install.ps1
                               │   to C:\ProgramData\IntuneStaging\FortiEMS
                               ├── writes target-version.txt (version of the embedded EXE)
                               ├── Users: read/execute + create-only on that folder
                               └── writes HKLM\...\Run  'FortiEMS-Install'

User logon        (USER)       logon-install.ps1
                               ├── enrolled AND at target version? -> stop for good
                               ├── already attempted, client present -> report only, never retry
                               ├── already attempted, client ABSENT  -> retry (max 3)
                               ├── wait for AzureAdPrt = YES (30 min cap)
                               └── run the installer               (Intune EPM elevates it)
```

Markers are named after the target version (`exe-launched-<ver>.flag`,
`enrolled-<ver>.flag`). Repackaging with a newer EMS installer therefore re-arms the upgrade on
its own: no cleanup on the devices, no constant to edit. `Publish-Win32App.ps1` injects the
same version into `detection.ps1` at upload time (`__TARGET_VERSION__` token), because a
detection script has no access to the package content.

An **HKLM Run key executes inside the signed-in user's session**. So the staging is privileged
and the installer launch is not — which is exactly the split you need. And because a Run key
launch is an ordinary user-initiated process, **EPM intercepts it reliably** (verified).

Measured on a clean device: logon at `13:52:14`, installer at `13:52:15`, `status 0x2` with
`fgt_sn` populated at `13:54:17`. No UAC prompt, no scheduled task.

On other devices the MSI ends with **3010** (`FortiClient requested a reboot`). The installer
runs with `/norestart`, so the transaction stays pending: the invitation code is in the
registry, `FA_ESNAC` is still empty, and **nothing enrolls until the device restarts**. After
the reboot and the next logon, enrollment completes without any further action. Do not
reinstall and do not run a remediation in that state — that is the road to `0x1D`.

## Contents

```
package/     install.ps1          stages payload + Run key          (Win32 app, SYSTEM)
             logon-install.ps1    waits for the PRT, runs the installer (user session)
             detection.ps1        Intune detection: checks the staging, not the install
             uninstall.ps1        removes payload, Run key, product

tools/       New-EpmElevationRule.ps1   creates the EPM rule via Graph
             Publish-Win32App.ps1       builds + uploads any Win32 app (with a GUI)
             Get-IntuneRemediations.ps1 exports what your remediations REALLY contain

remediation/ Detect-FortiTrialExpired.ps1 read-only fleet report of the "trial expired" loop
             cleanup-enroll-detect.ps1  MIGRATION ONLY — see below
             cleanup-enroll-fix.ps1     MIGRATION ONLY — see below
```

Drop your EMS-generated installers into `package\x64\` and `package\arm64\`.

### Staging folder

Everything lands under `C:\ProgramData\IntuneStaging\FortiEMS`. The name is deliberately
generic — change it if you have your own convention. It is declared as two constants at the
top of **install.ps1**, **detection.ps1** and **uninstall.ps1**:

```powershell
$BaseDir   = 'C:\ProgramData\IntuneStaging'
$StageName = 'FortiEMS'
```

These three must match, or detection never passes and uninstall leaves the payload behind.
`logon-install.ps1` needs no constant: it derives the folder from its own location on disk.

### The `remediation/cleanup-*` scripts are for migration only

They belong to an **older design** of this deployment (a scheduled task
`FortiTray-EMS-Enrollment` and/or a Run key `FortiEMS-Enroll` launching a
`FortiTray-Enroll.ps1` wrapper, which called `FortiESNAC.exe` directly — a UAC prompt at
every logon). They match those names **exactly**, so they leave the current artefacts
(`FortiEMS-Install`, `logon-install.ps1`, the staging folder) untouched.

If you are starting from this repository, **you do not need them — do not deploy them.**
If you do use them, set `$LegacyBaseDir` at the top of both files to the folder your old
wrapper lived in. Note that the fix script also *re-creates* the `FortiTray` Run key when
`FortiTray.exe` is present (the legitimate GUI autostart the old cleanup used to drop).

## Security fix — update if you deployed an earlier version

Earlier versions of `install.ps1` granted **Modify** (`(OI)(CI)M`) to Users on the staging
folder and on its parent. That folder holds `logon-install.ps1`, which the HKLM Run key executes
at the logon of **every** user, administrators included. A standard user could replace the
script and wait for an admin to sign in: **local privilege escalation**.

The current version removes inheritance on the staging folder and grants Users only
read/execute, plus *create files* on the folder itself (no inheritance flag) — enough to drop
new markers, not to overwrite an existing file. It also removes the explicit Modify grant on the
parent folder. Republishing the package fixes deployed devices on the next Intune cycle.

## Traps worth knowing

**The "trial expired" loop.** A client that lost its EMS registration runs a
`License Expire Check` every minute: `trial period has expired` → VPN disconnected →
`remove cloud client token and invitation code`. Any invitation you re-inject is wiped within
the minute, and an install over the top is only an MSI *reconfigure* that does not reset the
trial. Only a **fresh** install recovers it. `detection.ps1` spots an *active* loop (traces less
than an hour old) and `install.ps1` then uninstalls **once per target version** so the next
logon reinstalls cleanly. A second occurrence is left for manual handling — never a reboot loop.

**Windows PowerShell 5.1 is not PowerShell 7.** Under 5.1 (the host Intune uses), a native exe
writing to stderr with `2>&1` and `$ErrorActionPreference = 'Stop'` *throws*. A `reg delete` on
a missing key aborted an install that way, while the same code passed every local test in 7.

**The PRT race is the expensive one.** In a fresh session, WAM / the Entra PRT becomes
available anywhere between a few seconds and about half an hour. If FortiClient asks for its
token before WAM is ready you get `azuretoken is invalid` — and the EMS invitation is **lost
server-side** ("invitation lost if the initial user verification fails"). The endpoint then
sits at `0x1D` for good: neither a reboot nor an install over the top recovers it, only a full
uninstall does.

A Run key fires early in session startup, right inside that window. `logon-install.ps1`
therefore waits for `AzureAdPrt : YES` — refreshing the PRT every 20 seconds, 30 minute cap —
before launching anything. If the PRT never shows up it **deliberately writes no attempt
marker**: everywhere else the marker is written even on failure, to avoid a retry loop, but
here doing nothing and retrying at the next logon beats burning the invitation.
`dsregcmd /status` and `/RefreshPrt` need no elevation.

**Intune runs Win32 install commands in the 32-bit PowerShell host.** Writing to
`HKLM:\SOFTWARE\...\Run` is silently redirected to `WOW6432Node`. `New-ItemProperty` succeeds,
your log says "key written", and a 64-bit detection sees nothing. Relaunch via `SysNative` and
**re-read the value through an explicit 64-bit view** — a successful write does not prove the
right hive.

**`forticlientsetup_*.exe` is a self-extractor.** It returns in about one second and lets
`msiexec` do the work. `Start-Process -Wait` waits for the extraction only. Judging the result
there wrongly concludes "no invitation code" while nothing is installed yet.

**EMS-generated packages are unsigned.** Injecting the invitation code breaks the Authenticode
signature, so an EPM rule can only match on **file name + SHA256** — and every repackage changes
the hash. Update the rule at the same time, or elevation silently stops and installs fail 1223.

**Each EMS package embeds its own invitation code.** Two packages built on different days carry
different codes. Never hardcode one in a script.

**Only `fgt_sn` proves enrollment.** Testing `status -eq 2` marks healthy devices (`0x1E`,
`0x12`) as broken. We wiped a working install that way.

**Check what your tenant actually runs.** A remediation of ours tested `Get-Service FortiESNAC`
— a service that does not exist on 7.4.x, where the real one is `FA_Scheduler`. The condition
therefore reduced to *"installed and not yet enrolled → uninstall"*, hourly, fleet-wide, for a
month. The fix existed on disk and had never been republished. `Get-IntuneRemediations.ps1`
exports the real script content, which the portal does not show.

## Intune settings

| Setting | Value |
|---|---|
| Install behavior | **System** |
| Install command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` |
| Uninstall command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1` |
| Detection | script, `detection.ps1` |
| Return codes | `0` success · `3010`/`1641` reboot · `1618` retry · **`1223` failed** |

Map `1223` to **failed**: it is the code for refused elevation. The staging install never
returns it (it runs as SYSTEM), but `uninstall.ps1` does when `msiexec /x` is not elevated,
and left as success it would report a product removal that never happened.
`Publish-Win32App.ps1` adds that mapping with `-FailOnElevationDenied`.

EPM rule — file name + SHA256, **Automatic**, **Allow all child processes to run elevated**
(the self-extractor calls `msiexec` as a child). Assign the app and the EPM policy to the
**same** group, or installs fail 1223 for lack of elevation.

## Requirements

PowerShell 7, `Microsoft.Graph.Authentication`, and Microsoft's
[Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
(place `IntuneWinAppUtil.exe` next to `Publish-Win32App.ps1`, or pass `-IntuneWinAppUtil`).

Tested against FortiClient 7.4.7 and 7.4.8 on Windows 11, Entra-joined and hybrid-joined
devices.

## Disclaimer

Shared as-is, from a production rollout. Read the scripts before running them: some of them
uninstall software. Test on one device first.
