# Detailed guide — deploying FortiClient EMS with Intune and EPM

**English** · [Français](GUIDE.fr.md) · [← README](../README.md)

The [README](../README.md) explains *why* this design. This guide explains *how* to set it up,
verify it, upgrade it and troubleshoot it.

> Log lines quoted below are in French, as the scripts write them.

## Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Build the EMS installers](#3-step-1--build-the-ems-installers)
4. [Step 2 — Prepare the package](#4-step-2--prepare-the-package)
5. [Step 3 — Create the EPM rule](#5-step-3--create-the-epm-rule)
6. [Step 4 — Publish the Win32 app](#6-step-4--publish-the-win32-app)
7. [Step 5 — Assign and pilot](#7-step-5--assign-and-pilot)
8. [Step 6 — Verify on a device](#8-step-6--verify-on-a-device)
9. [Upgrading FortiClient](#9-upgrading-forticlient)
10. [Uninstalling](#10-uninstalling)
11. [Troubleshooting](#11-troubleshooting)
12. [Reference](#12-reference)

---

## 1. Overview

```
 Intune (SYSTEM)                     User logon (USER)
 ─────────────────                   ─────────────────
 install.ps1                         logon-install.ps1  (started by the Run key)
  ├ stages the EXE + logon-install    ├ enrolled at target version? → done
  ├ writes target-version.txt         ├ already attempted? → report, never relaunch
  ├ sets ACLs (create-only)           ├ waits for AzureAdPrt = YES
  └ writes HKLM\...\Run               ├ runs forticlientsetup_*.exe  ← elevated by EPM
                                      ├ waits for FortiESNAC.exe + invitation code
 detection.ps1                        └ waits 10 min for fgt_sn, else: REBOOT required
  └ compliant = staging in place
```

Typical timeline on a new device:

| When | What happens |
|---|---|
| Intune cycle | `install.ps1` stages the payload. Intune reports the app **installed** (detection checks the staging). |
| Next user logon | `logon-install.ps1` waits for the PRT, runs the installer, EPM elevates it. |
| +2 to 5 min | FortiClient installed, invitation code in the registry. |
| Either right away | `fgt_sn` populated → enrolled. |
| Or after a reboot | the MSI returned **3010**: enrollment completes after the reboot and the next logon. |

> Intune detection validates **the staging**, not the enrollment. That is deliberate: requiring
> enrollment would redeploy the package every cycle until the user logs on again. Track
> enrollment in the device logs (§ 8) or in the EMS console.

## 2. Prerequisites

**Devices**
- Windows 10/11 x64 or ARM64, **Entra-joined** (or hybrid-joined) — the Entra PRT is required
  for EMS user verification.
- **Intune Endpoint Privilege Management** (EPM) licence for the targeted users.
- **Standard** (non-admin) users: EPM provides the elevation.

**Administration**
- A FortiClient EMS console (on-prem or cloud) with Entra user verification.
- PowerShell 7 and the `Microsoft.Graph.Authentication` module:
  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  ```
- [`IntuneWinAppUtil.exe`](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
  placed in `tools\` (or passed with `-IntuneWinAppUtil`).
- Intune permissions to create Win32 apps and EPM policies (the scripts request
  `DeviceManagementApps.ReadWrite.All` and `DeviceManagementConfiguration.ReadWrite.All`).

## 3. Step 1 — Build the EMS installers

1. In the EMS console, create a FortiClient **deployment installer** with the modules you need
   and your tenant/site **invitation**.
2. Build an **x64** and an **ARM64** flavour if you have both kinds of devices.
3. Download the `.exe` files. The name must start with `forticlientsetup_` (the EPM rule and the
   scripts rely on that prefix), e.g. `forticlientsetup_7.4.8_x64.exe`.

> **Each package embeds its own invitation code** and is **unsigned** (injecting the invitation
> breaks the signature). Every new package therefore has a new SHA256 → update the EPM rule at
> the same time (§ 5 and § 9).

## 4. Step 2 — Prepare the package

```
package\
├── install.ps1
├── logon-install.ps1
├── detection.ps1
├── uninstall.ps1
├── x64\forticlientsetup_<ver>_x64.exe
└── arm64\forticlientsetup_<ver>_arm64.exe
```

1. Copy the `.exe` files into `package\x64\` and `package\arm64\` (one `.exe` per folder;
   delete the `PLACEHOLDER.md` files).
2. **Optional** — change the staging folder. At the top of `install.ps1`, `detection.ps1`
   **and** `uninstall.ps1`:
   ```powershell
   $BaseDir   = 'C:\ProgramData\IntuneStaging'
   $StageName = 'FortiEMS'
   ```
   All three files must carry **exactly** the same values. `logon-install.ps1` needs none.
3. Leave `__TARGET_VERSION__` in `detection.ps1` alone: `Publish-Win32App.ps1` replaces it at
   upload time with the version of the embedded EXE.

## 5. Step 3 — Create the EPM rule

The installer is started **unelevated** in the user session. EPM has to elevate it.

**With the script** (recommended):
```powershell
cd tools
.\New-EpmElevationRule.ps1                # prints name, version, SHA256 of each EXE (offline)
.\New-EpmElevationRule.ps1 -CreatePolicy  # creates the policy through Graph
```

**Or by hand** (Intune > Endpoint security > Endpoint Privilege Management > Elevation rules),
one rule per architecture:

| Field | Value |
|---|---|
| File name | `forticlientsetup_<ver>_x64.exe` (exact) |
| File hash | SHA256 printed by the script |
| Elevation type | **Automatic** |
| Child process behavior | **Allow all child processes to run elevated** (the self-extractor starts `msiexec`) |
| Certificate | none (unsigned binary) |

> ⚠️ **Never create a rule for `FortiESNAC.exe` or `FortiTray.exe`.** EPM would run them under a
> virtual account with no Entra PRT → `azuretoken is invalid` → enrollment impossible.

Assign the EPM policy to **the same group** as the app (step 5).

## 6. Step 4 — Publish the Win32 app

```powershell
cd tools
.\Publish-Win32App.ps1 -SourceFolder '..\package' -DisplayName 'FortiClient EMS' `
                       -Publisher 'Your Organization' -Build -FailOnElevationDenied
```

- `-Build` builds the `.intunewin`; without `-SourceFolder`, a dialog asks for it.
- The script prints `Version cible injectee dans la detection : 7.4.8.xxxx` — check it.
- For a new version of an existing app, add `-Update` (assignments are kept).

Resulting settings (reproduce them if you publish by hand):

| Setting | Value |
|---|---|
| Install behavior | **System** |
| Install command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` |
| Uninstall command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1` |
| Detection | script `detection.ps1`, 64-bit, no signature check |
| Return codes | `0` success · `3010` soft reboot · `1641` hard reboot · `1618` retry · `1223` **failed** |

> Publishing by hand: replace `__TARGET_VERSION__` yourself with the EXE version (e.g.
> `7.4.8.2066`). Left as is, detection checks the staging without requiring a version — and a
> later upgrade would never be redistributed.

## 7. Step 5 — Assign and pilot

1. Create a pilot group (2–5 devices, willing users, x64 and ARM64 if possible).
2. Assign **the app (Required)** and **the EPM policy** to that group.
3. Trigger an Intune sync on a pilot device, then ask the user to **sign out and back in**.
4. Check the device (§ 8) and the EMS console. Then widen in waves.

## 8. Step 6 — Verify on a device

### Logs

All in `$BaseDir` (default `C:\ProgramData\IntuneStaging`):

| File | Written by | Content |
|---|---|---|
| `FortiClientEMS-ultrasimple-install.log` | `install.ps1` (SYSTEM) | staging, EXE SHA256, ACLs, Run key |
| `FortiClientEMS-ultrasimple-logon.log` | `logon-install.ps1` (user) | PRT wait, launch, enrollment |
| `FortiClientEMS-ultrasimple-exe.log` | the installer | verbose MSI log + `[SETUPEXE]` lines |
| `FortiClientEMS-ultrasimple-uninstall.log` | `uninstall.ps1` | uninstall |
| `FortiClientEMS-ultrasimple-msi-<code>.log` | `msiexec /x` | MSI log of the uninstall |
| `FortiClientEMS-ultrasimple-reinstall-msi-<code>.log` | `install.ps1` | "trial expired" recovery uninstall |

### Normal logon log sequence

```
[user] === Ouverture de session sur PC-01 ===
[user] Version installee : aucune  |  cible : 7.4.8.2066
[user] PRT Entra disponible apres 0 verification(s) -> lancement de l'installeur
[user] Lancement de forticlientsetup_7.4.8_x64.exe  SHA256=...  (tentative 1/3)
[user] ExitCode=0
[user] FortiClient pose (FortiESNAC.exe present) - attente de la configuration EMS
[user] Apres installation : status 0x0, invitation=XXXXXXXX
[user] === ENROLE (status 0x2) ===
```

or, if the MSI asked for a reboot:

```
[user] Pas encore enrole apres 10 min (status 0x0). Un REDEMARRAGE est requis ...
```
→ reboot, sign in. At the next logon: `ENROLE et a jour ... -> termine`.

### Quick checks (PowerShell)

```powershell
# Enrollment: only fgt_sn counts
Get-ItemProperty 'HKLM:\SOFTWARE\Fortinet\FortiClient\FA_ESNAC' |
    Select-Object status, fgt_sn, ems_sn, registration_status
# Embedded invitation code
(Get-ItemProperty 'HKLM:\SOFTWARE\Fortinet\FortiClient\FA_ESNAC\cloud_client').invitation_code
# PRT (in the USER's session, not as admin/SYSTEM)
dsregcmd /status | Select-String AzureAdPrt
# Pending reboot?
Select-String -Path 'C:\ProgramData\IntuneStaging\FortiClientEMS-ultrasimple-exe.log' -Pattern 'returning 3010|requested a reboot'
```

## 9. Upgrading FortiClient

1. Build the new installers in EMS (§ 3) and replace the `.exe` files in the package.
2. **Update the EPM rule** with the new names and SHA256 (`New-EpmElevationRule.ps1`). Do it
   **before** or **together with** the publish.
3. Republish: `Publish-Win32App.ps1 ... -Build -Update`.

What happens next, with no cleanup on the devices:
- detection (new version injected) sees an outdated staging → Intune reruns `install.ps1`;
- `target-version.txt` changes → the `exe-launched-<old>` / `enrolled-<old>` markers no longer
  count;
- at the next logon, a device enrolled on an older version is upgraded.

## 10. Uninstalling

Assign the app as **Uninstall**. `uninstall.ps1` (SYSTEM):
1. removes the `FortiEMS-Install` Run key (64- and 32-bit views);
2. deletes the staging folder;
3. uninstalls FortiClient by its MSI product code (`REBOOT=ReallySuppress`);
4. deletes the leftover enrollment state (`HKLM\SOFTWARE\Fortinet\FortiClient`, including
   `FA_ESNAC`) so a reinstall starts from scratch.

Run unelevated, `msiexec` returns `1223` and the script reports it (hence 1223 = failed).

> **Known limitation:** if the `FortiShield` driver is still loaded after the uninstall, the
> `FA_ESNAC` key is protected and cannot be deleted. The script then returns `3010` but **does
> not schedule** a cleanup after the reboot. Before reinstalling on that device, check after the
> reboot that `HKLM\SOFTWARE\Fortinet\FortiClient` is gone, and delete it otherwise (as admin:
> `reg delete HKLM\SOFTWARE\Fortinet\FortiClient /f /reg:64`).

## 11. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Intune "installed", nothing in the logon log | the user has not logged on again since staging | sign out / sign in |
| `Pas encore enrole apres 10 min`, `FA_ESNAC` empty, invitation present | **pending reboot** (MSI 3010) | reboot. **Do not reinstall.** |
| `ECHEC : elevation refusee (1223)` | EPM rule missing, mis-targeted or stale SHA256 | compare rule name + SHA256 with the install log; same group assignment |
| `FortiClient ABSENT malgre la tentative precedente` | EPM did not elevate (ExitCode 0, nothing installed) | `bUserIsElevated=` line in the EXE log; EPM logs in `C:\Program Files\Microsoft EPM Agent\Logs`; automatic retry (3 max) |
| `ECHEC : FortiClient toujours absent apres 3 tentatives` | same, persistent | fix EPM, then delete `$BaseDir\FortiEMS\exe-launched-<ver>*.flag` |
| `ABANDON : pas de PRT Entra apres 30 min` | no PRT in the session (device not joined, expired password, offline) | `dsregcmd /status` in the session; retried at next logon (no marker written) |
| `ECHEC : FortiClient installe SANS code d'invitation` | the EXE is not an EMS deployment package | rebuild it in EMS; detection re-triggers the staging |
| Permanent `status 0x1D`, `azuretoken is invalid` | installer started before the PRT, or EPM on FortiESNAC/FortiTray → invitation lost server-side | full uninstall + `FA_ESNAC` cleanup, then reinstall; make sure no EPM rule targets FortiESNAC/FortiTray |
| VPN dropped every minute, invitation wiped | "trial expired" loop | automatic: `install.ps1` uninstalls once per version. Inventory: `remediation\Detect-FortiTrialExpired.ps1` |
| Detection never compliant | `$BaseDir`/`$StageName` differ between scripts, or Run key in `WOW6432Node` | align the constants; check the key in the 64-bit view |

> **Golden rule:** a device installed with its invitation code but not yet enrolled needs a
> **reboot** — not a reinstall, not a remediation.

## 12. Reference

### Files on the device (`$BaseDir\$StageName`, default `C:\ProgramData\IntuneStaging\FortiEMS`)

| File | Purpose |
|---|---|
| `forticlientsetup_*.exe` | staged installer |
| `logon-install.ps1` | script started by the Run key |
| `target-version.txt` | target version (the staged EXE's) |
| `exe-launched-<ver>.flag`, `.2.flag`, `.3.flag` | one per launch attempt |
| `enrolled-<ver>.flag` | enrolled at that version → the logon script exits immediately |
| `cleanup-pending.flag` | `FA_ESNAC` cleanup deferred after a recovery uninstall |
| `$BaseDir\FortiEMS-reinstall-<ver>.flag` | "trial expired" reinstall already done for that version (outside staging, survives uninstall) |

### Registry

| Key / value | Meaning |
|---|---|
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` › `FortiEMS-Install` | starts `logon-install.ps1` at every logon |
| `HKLM\SOFTWARE\Fortinet\FortiClient\FA_ESNAC` › `fgt_sn` | **present = enrolled** (the only reliable test) |
| `...\FA_ESNAC` › `status` | `0x2` enrolled; `0x1E`/`0x12` also seen on healthy devices; `0x1D` authentication pending |
| `...\FA_ESNAC\cloud_client` › `invitation_code` | invitation embedded by the package |

### Exit codes

| Script | Code | Meaning |
|---|---|---|
| `install.ps1` | `0` | staged (or nothing to do) |
| | `3010` | only after a "trial expired" uninstall that Windows wants to finish with a reboot |
| | `1618` | an installation is running, Intune will retry |
| | `1` | error (EXE missing, Run key not written in the 64-bit view…) |
| `detection.ps1` | `0` / `1` | compliant / (re)stage needed |
| `uninstall.ps1` | `1223` | `msiexec /x` not elevated |
| installer | `3010` / `0x80070BC2` | installed, **reboot required** before enrollment |
