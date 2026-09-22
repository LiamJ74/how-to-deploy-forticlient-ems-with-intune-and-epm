# FortiClient EMS enrollment via Intune — without breaking Entra authentication

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
                               │   to C:\ProgramData\<YourFolder>\FortiEMS
                               ├── grants Users write access on that folder
                               └── writes HKLM\...\Run  'FortiEMS-Install'

User logon        (USER)       logon-install.ps1
                               ├── already enrolled?  -> stop for good
                               ├── already attempted?  -> report only, never retry
                               └── otherwise           -> run the installer once
                                                          (Intune EPM elevates it)
```

An **HKLM Run key executes inside the signed-in user's session**. So the staging is privileged
and the installer launch is not — which is exactly the split you need. And because a Run key
launch is an ordinary user-initiated process, **EPM intercepts it reliably** (verified).

Measured on a clean device: logon at `13:52:14`, installer at `13:52:15`, `status 0x2` with
`fgt_sn` populated at `13:54:17`. No UAC prompt, no scheduled task, no reboot.

## Contents

```
package/     install.ps1          stages payload + Run key          (Win32 app, SYSTEM)
             logon-install.ps1    runs the installer once           (user session)
             detection.ps1        Intune detection rule
             uninstall.ps1        removes payload, Run key, product

tools/       New-EpmElevationRule.ps1   creates the EPM rule via Graph
             Publish-Win32App.ps1       builds + uploads any Win32 app (with a GUI)
             Get-IntuneRemediations.ps1 exports what your remediations REALLY contain

remediation/ cleanup-enroll-*.ps1  removes legacy scheduled tasks / Run keys / wrappers
```

Drop your EMS-generated installers into `package\x64\` and `package\arm64\`.

## Traps worth knowing

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

Map `1223` to **failed**: it is the code for refused elevation. Left as success, it hides an
install that never happened.

EPM rule — file name + SHA256, **Automatic**, **Allow all child processes to run elevated**
(the self-extractor calls `msiexec` as a child). Assign the app and the EPM policy to the
**same** group, or installs fail 1223 for lack of elevation.

## Requirements

PowerShell 7, `Microsoft.Graph.Authentication`, and Microsoft's
[Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
(place `IntuneWinAppUtil.exe` next to `Publish-Win32App.ps1`, or pass `-IntuneWinAppUtil`).

Tested against FortiClient 7.4.7 and 7.4.8 on Windows 11, Entra-joined devices.

## Disclaimer

Shared as-is, from a production rollout. Read the scripts before running them: some of them
uninstall software. Test on one device first.
