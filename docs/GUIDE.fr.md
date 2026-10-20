# Guide détaillé — déployer FortiClient EMS avec Intune et EPM

[English](GUIDE.md) · **Français** · [← README](../README.fr.md)

Le [README](../README.fr.md) explique *pourquoi* cette architecture. Ce guide explique *comment*
la mettre en place, la vérifier, la faire évoluer et la dépanner.

## Sommaire

1. [Vue d'ensemble](#1-vue-densemble)
2. [Prérequis](#2-prérequis)
3. [Étape 1 — Générer les installeurs EMS](#3-étape-1--générer-les-installeurs-ems)
4. [Étape 2 — Préparer le package](#4-étape-2--préparer-le-package)
5. [Étape 3 — Créer la règle EPM](#5-étape-3--créer-la-règle-epm)
6. [Étape 4 — Publier l'app Win32](#6-étape-4--publier-lapp-win32)
7. [Étape 5 — Affecter et piloter](#7-étape-5--affecter-et-piloter)
8. [Étape 6 — Vérifier sur un poste](#8-étape-6--vérifier-sur-un-poste)
9. [Mettre à niveau FortiClient](#9-mettre-à-niveau-forticlient)
10. [Désinstaller](#10-désinstaller)
11. [Dépannage](#11-dépannage)
12. [Référence](#12-référence)

---

## 1. Vue d'ensemble

```
 Intune (SYSTEM)                     Ouverture de session (UTILISATEUR)
 ─────────────────                   ──────────────────────────────────
 install.ps1                         logon-install.ps1  (lancé par la clé Run)
  ├ dépose l'EXE + logon-install      ├ déjà enrôlé à la bonne version ? → fin
  ├ écrit target-version.txt          ├ déjà tenté ? → constate, ne relance pas
  ├ pose les droits (création seule)  ├ attend AzureAdPrt = YES
  └ pose HKLM\...\Run                 ├ lance forticlientsetup_*.exe  ← élevé par EPM
                                      ├ attend FortiESNAC.exe + code d'invitation
 detection.ps1                        └ attend fgt_sn 10 min, sinon : REDÉMARRAGE requis
  └ conforme = dépôt en place
```

Chronologie typique d'un poste neuf :

| Moment | Ce qui se passe |
|---|---|
| Cycle Intune | `install.ps1` dépose la charge utile. Intune affiche l'app **installée** (la détection valide le dépôt). |
| Ouverture de session suivante | `logon-install.ps1` attend le PRT, lance l'installeur, EPM l'élève. |
| +2 à 5 min | FortiClient installé, code d'invitation présent dans le registre. |
| Soit immédiatement | `fgt_sn` renseigné → enrôlé. |
| Soit après redémarrage | le MSI a rendu **3010** : l'enrollment se fait après le reboot et la reconnexion. |

> La détection Intune valide **le dépôt**, pas l'enrollment. C'est voulu : exiger l'enrollment
> ferait redéployer le package à chaque cycle tant que l'utilisateur ne s'est pas reconnecté.
> Le suivi de l'enrollment se fait dans les journaux du poste (§ 8) ou dans la console EMS.

## 2. Prérequis

**Côté postes**
- Windows 10/11 x64 ou ARM64, **joints à Entra** (ou en jonction hybride) — le PRT Entra est
  indispensable à l'authentification EMS.
- Licence **Intune Endpoint Privilege Management** (EPM) pour les utilisateurs ciblés.
- Utilisateurs **non administrateurs** : c'est EPM qui fournit l'élévation.

**Côté administration**
- Une console FortiClient EMS (sur site ou cloud) avec l'authentification utilisateur Entra.
- PowerShell 7 et le module `Microsoft.Graph.Authentication` :
  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  ```
- [`IntuneWinAppUtil.exe`](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
  posé dans `tools\` (ou passé via `-IntuneWinAppUtil`).
- Droits Intune : création d'apps Win32 et de stratégies EPM
  (`DeviceManagementApps.ReadWrite.All`, `DeviceManagementConfiguration.ReadWrite.All`).

## 3. Étape 1 — Générer les installeurs EMS

1. Dans la console EMS, créez un **installeur de déploiement** FortiClient avec les modules
   voulus et l'**invitation** de votre tenant/site.
2. Générez une version **x64** et une version **ARM64** si vous avez les deux types de postes.
3. Téléchargez les `.exe`. Le nom doit commencer par `forticlientsetup_` (la règle EPM et les
   scripts s'appuient sur ce préfixe), par ex. `forticlientsetup_7.4.8_x64.exe`.

> **Chaque package embarque son propre code d'invitation**, et n'est **pas signé** (l'injection
> de l'invitation casse la signature). Conséquence : chaque nouveau package a un nouveau
> SHA256 → la règle EPM doit être mise à jour en même temps (§ 5 et § 9).

## 4. Étape 2 — Préparer le package

```
package\
├── install.ps1
├── logon-install.ps1
├── detection.ps1
├── uninstall.ps1
├── x64\forticlientsetup_<ver>_x64.exe
└── arm64\forticlientsetup_<ver>_arm64.exe
```

1. Copiez les `.exe` dans `package\x64\` et `package\arm64\` (un seul `.exe` par dossier ;
   supprimez les `PLACEHOLDER.md`).
2. **Optionnel** — changez le dossier de dépôt. En tête de `install.ps1`, `detection.ps1` **et**
   `uninstall.ps1` :
   ```powershell
   $BaseDir   = 'C:\ProgramData\IntuneStaging'
   $StageName = 'FortiEMS'
   ```
   Les trois fichiers doivent porter **exactement** les mêmes valeurs. `logon-install.ps1`
   n'en a pas besoin.
3. Ne touchez pas à `__TARGET_VERSION__` dans `detection.ps1` : `Publish-Win32App.ps1` le
   remplace à la publication par la version de l'EXE embarqué.

## 5. Étape 3 — Créer la règle EPM

L'installeur est lancé **sans élévation** dans la session utilisateur. EPM doit l'élever.

**Avec le script** (recommandé) :
```powershell
cd tools
.\New-EpmElevationRule.ps1                # affiche nom, version, SHA256 de chaque EXE (hors ligne)
.\New-EpmElevationRule.ps1 -CreatePolicy  # crée la stratégie via Graph
```

**Ou à la main** (Intune > Sécurité du point de terminaison > Endpoint Privilege Management >
Règles d'élévation), une règle par architecture :

| Champ | Valeur |
|---|---|
| Nom du fichier | `forticlientsetup_<ver>_x64.exe` (exact) |
| Hash du fichier | SHA256 affiché par le script |
| Type d'élévation | **Automatique** |
| Comportement des processus enfants | **Autoriser tous les processus enfants à s'exécuter avec élévation** (l'auto-extracteur lance `msiexec`) |
| Certificat | aucun (binaire non signé) |

> ⚠️ **Ne créez jamais de règle pour `FortiESNAC.exe` ou `FortiTray.exe`.** EPM les exécuterait
> sous un compte virtuel sans PRT Entra → `azuretoken is invalid` → enrollment impossible.

Affectez la stratégie EPM **au même groupe** que l'app (étape 5).

## 6. Étape 4 — Publier l'app Win32

```powershell
cd tools
.\Publish-Win32App.ps1 -SourceFolder '..\package' -DisplayName 'FortiClient EMS' `
                       -Publisher 'Votre organisation' -Build -FailOnElevationDenied
```

- `-Build` construit le `.intunewin` ; sans `-SourceFolder`, une fenêtre le demande.
- Le script affiche `Version cible injectee dans la detection : 7.4.8.xxxx` — vérifiez-le.
- Pour une nouvelle version d'une app existante : ajoutez `-Update` (les affectations sont
  conservées).

Paramètres obtenus (à reproduire si vous publiez à la main) :

| Paramètre | Valeur |
|---|---|
| Comportement d'installation | **Système** |
| Commande d'installation | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` |
| Commande de désinstallation | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1` |
| Détection | script `detection.ps1`, 64 bits, sans contrôle de signature |
| Codes de retour | `0` succès · `3010` redémarrage souple · `1641` redémarrage forcé · `1618` réessayer · `1223` **échec** |

> Publication à la main : remplacez vous-même `__TARGET_VERSION__` par la version de l'EXE
> (ex. `7.4.8.2066`). Laissé tel quel, la détection vérifie le dépôt sans exiger de version —
> une mise à niveau ultérieure ne serait alors pas redistribuée.

## 7. Étape 5 — Affecter et piloter

1. Créez un groupe pilote (2–5 postes, utilisateurs volontaires, x64 et ARM64 si possible).
2. Affectez **l'app (Requise)** et **la stratégie EPM** à ce groupe.
3. Déclenchez une synchronisation Intune sur un poste pilote, puis demandez à l'utilisateur de
   **fermer et rouvrir sa session**.
4. Vérifiez le poste (§ 8) et la console EMS. Puis élargissez par vagues.

## 8. Étape 6 — Vérifier sur un poste

### Journaux

Tous dans `$BaseDir` (par défaut `C:\ProgramData\IntuneStaging`) :

| Fichier | Écrit par | Contenu |
|---|---|---|
| `FortiClientEMS-ultrasimple-install.log` | `install.ps1` (SYSTEM) | dépôt, SHA256 de l'EXE, droits, clé Run |
| `FortiClientEMS-ultrasimple-logon.log` | `logon-install.ps1` (utilisateur) | attente PRT, lancement, enrollment |
| `FortiClientEMS-ultrasimple-exe.log` | l'installeur | journal MSI verbeux + `[SETUPEXE]` |
| `FortiClientEMS-ultrasimple-uninstall.log` | `uninstall.ps1` | désinstallation |
| `FortiClientEMS-ultrasimple-msi-<code>.log` | `msiexec /x` | journal MSI de la désinstallation |
| `FortiClientEMS-ultrasimple-reinstall-msi-<code>.log` | `install.ps1` | désinstallation de reprise « essai expiré » |

### Séquence normale du journal de logon

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

ou, si le MSI a demandé un redémarrage :

```
[user] Pas encore enrole apres 10 min (status 0x0). Un REDEMARRAGE est requis ...
```
→ redémarrer, se reconnecter. À la session suivante : `ENROLE et a jour ... -> termine`.

### Contrôles rapides (PowerShell)

```powershell
# Enrollment : seul fgt_sn fait foi
Get-ItemProperty 'HKLM:\SOFTWARE\Fortinet\FortiClient\FA_ESNAC' |
    Select-Object status, fgt_sn, ems_sn, registration_status
# Code d'invitation embarqué
(Get-ItemProperty 'HKLM:\SOFTWARE\Fortinet\FortiClient\FA_ESNAC\cloud_client').invitation_code
# PRT (dans la session de l'UTILISATEUR, pas en admin/SYSTEM)
dsregcmd /status | Select-String AzureAdPrt
# Redémarrage en attente ?
Select-String -Path 'C:\ProgramData\IntuneStaging\FortiClientEMS-ultrasimple-exe.log' -Pattern 'returning 3010|requested a reboot'
```

## 9. Mettre à niveau FortiClient

1. Générez les nouveaux installeurs dans EMS (§ 3) et remplacez les `.exe` du package.
2. **Mettez à jour la règle EPM** avec les nouveaux noms et SHA256 (`New-EpmElevationRule.ps1`).
   Faites-le **avant** ou **en même temps** que la publication.
3. Republiez : `Publish-Win32App.ps1 ... -Build -Update`.

Ce qui se passe ensuite, sans rien nettoyer sur les postes :
- la détection (nouvelle version injectée) voit le dépôt périmé → Intune relance `install.ps1` ;
- `target-version.txt` change → les marqueurs `exe-launched-<ancienne>` / `enrolled-<ancienne>`
  ne comptent plus ;
- à l'ouverture de session suivante, un poste enrôlé mais en version inférieure est mis à niveau.

## 10. Désinstaller

Affectez l'app en **Désinstaller**. `uninstall.ps1` (SYSTEM) :
1. retire la clé Run `FortiEMS-Install` (vues 64 et 32 bits) ;
2. supprime le dossier de dépôt ;
3. désinstalle FortiClient par son code produit MSI (`REBOOT=ReallySuppress`) ;
4. supprime l'état d'enrollment résiduel (`HKLM\SOFTWARE\Fortinet\FortiClient`, dont
   `FA_ESNAC`), pour qu'une réinstallation reparte de zéro.

Exécuté sans élévation, `msiexec` rend `1223` et le script le signale (d'où le code 1223 = échec).

> **Limite connue :** si le pilote `FortiShield` est encore chargé après la désinstallation,
> la clé `FA_ESNAC` est protégée et ne peut pas être supprimée. Le script rend alors `3010` mais
> **ne programme pas** de nettoyage après le redémarrage. Avant de réinstaller sur ce poste,
> vérifiez après le reboot que `HKLM\SOFTWARE\Fortinet\FortiClient` a disparu, et supprimez-la
> sinon (en admin : `reg delete HKLM\SOFTWARE\Fortinet\FortiClient /f /reg:64`).

## 11. Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| Intune « installé », rien dans le journal de logon | l'utilisateur ne s'est pas reconnecté depuis le dépôt | fermer/rouvrir la session |
| `Pas encore enrole apres 10 min`, `FA_ESNAC` vide, invitation présente | **redémarrage en attente** (MSI 3010) | redémarrer. **Ne pas réinstaller.** |
| `ECHEC : elevation refusee (1223)` | règle EPM absente, mal ciblée ou SHA256 périmé | vérifier nom + SHA256 de la règle vs journal d'install ; affectation au même groupe |
| `FortiClient ABSENT malgre la tentative precedente` | EPM n'a pas élevé (ExitCode 0 sans rien installer) | ligne `bUserIsElevated=` du journal EXE ; journaux EPM `C:\Program Files\Microsoft EPM Agent\Logs` ; nouvelle tentative auto (3 max) |
| `ECHEC : FortiClient toujours absent apres 3 tentatives` | idem, persistant | corriger EPM, puis supprimer `$BaseDir\FortiEMS\exe-launched-<ver>*.flag` |
| `ABANDON : pas de PRT Entra apres 30 min` | pas de PRT dans la session (poste non joint, mot de passe expiré, hors réseau) | `dsregcmd /status` dans la session ; nouvelle tentative au logon suivant (aucun marqueur posé) |
| `ECHEC : FortiClient installe SANS code d'invitation` | l'EXE n'est pas un package de déploiement EMS | regénérer depuis EMS ; la détection redéclenche le dépôt |
| `status 0x1D` permanent, `azuretoken is invalid` | installeur lancé avant le PRT, ou EPM sur FortiESNAC/FortiTray → invitation perdue côté EMS | désinstallation complète + nettoyage `FA_ESNAC`, puis réinstallation ; vérifier qu'aucune règle EPM ne cible FortiESNAC/FortiTray |
| VPN coupé chaque minute, invitation effacée | boucle « essai expiré » | automatique : `install.ps1` désinstalle une fois par version. Inventaire : `remediation\Detect-FortiTrialExpired.ps1` |
| Détection toujours non conforme | constantes `$BaseDir`/`$StageName` différentes entre scripts, ou clé Run dans `WOW6432Node` | aligner les constantes ; vérifier la clé en vue 64 bits |

> **Règle d'or :** un poste installé avec son code d'invitation mais pas encore enrôlé a besoin
> d'un **redémarrage**, pas d'une réinstallation ni d'une remédiation.

## 12. Référence

### Fichiers sur le poste (`$BaseDir\$StageName`, par défaut `C:\ProgramData\IntuneStaging\FortiEMS`)

| Fichier | Rôle |
|---|---|
| `forticlientsetup_*.exe` | installeur déposé |
| `logon-install.ps1` | script lancé par la clé Run |
| `target-version.txt` | version cible (celle de l'EXE déposé) |
| `exe-launched-<ver>.flag`, `.2.flag`, `.3.flag` | une tentative de lancement chacun |
| `enrolled-<ver>.flag` | poste enrôlé à cette version → le script de logon sort immédiatement |
| `cleanup-pending.flag` | nettoyage `FA_ESNAC` reporté après une désinstallation de reprise |
| `$BaseDir\FortiEMS-reinstall-<ver>.flag` | réinstallation « essai expiré » déjà faite pour cette version (hors dépôt, survit à la désinstallation) |

### Registre

| Clé / valeur | Signification |
|---|---|
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` › `FortiEMS-Install` | lance `logon-install.ps1` à chaque ouverture de session |
| `HKLM\SOFTWARE\Fortinet\FortiClient\FA_ESNAC` › `fgt_sn` | **présent = enrôlé** (seul critère fiable) |
| `...\FA_ESNAC` › `status` | `0x2` enrôlé ; `0x1E`/`0x12` aussi vus sur des postes sains ; `0x1D` authentification en attente |
| `...\FA_ESNAC\cloud_client` › `invitation_code` | invitation embarquée par le package |

### Codes de sortie

| Script | Code | Sens |
|---|---|---|
| `install.ps1` | `0` | dépôt fait (ou rien à faire) |
| | `3010` | uniquement après une désinstallation « essai expiré » que Windows veut terminer par un redémarrage |
| | `1618` | une installation est en cours, Intune réessaiera |
| | `1` | erreur (EXE absent, clé Run non écrite en 64 bits…) |
| `detection.ps1` | `0` / `1` | conforme / à (re)déposer |
| `uninstall.ps1` | `1223` | `msiexec /x` non élevé |
| installeur | `3010` / `0x80070BC2` | installé, **redémarrage requis** avant enrollment |
