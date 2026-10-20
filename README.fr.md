# Enrollment FortiClient EMS via Intune — sans casser l'authentification Entra

[English](README.md) · **Français**

📘 **Mise en place pas à pas, vérification, mise à niveau et dépannage : [guide détaillé](docs/GUIDE.fr.md).**

Déployer **FortiClient EMS** avec Intune paraît trivial, et ne l'est pas. Ce dépôt contient une
méthode qui fonctionne et, plus utile encore, la liste des impasses qui ont l'air correctes et
ne le sont pas.

Tout est anonymisé : aucun code d'invitation, aucun numéro de série EMS, aucun identifiant de
tenant, aucun nom de poste. L'installeur FortiClient n'est **pas** fourni ; générez le vôtre
depuis votre console EMS.

---

## Le problème

L'enrollment FortiClient EMS exige un **jeton Entra**, et ce jeton n'existe que dans la
**session interactive d'un utilisateur connecté** (WAM / TokenBroker / PRT).

Une app Win32 installée par Intune en contexte **SYSTEM** tourne en **session 0** : ni
WebAccount, ni PRT. Le client s'installe sans erreur, puis boucle indéfiniment sur
`Endpoint state: Azure Token Required` et reste à `status 0x1D` (authentification en attente)
dans

```
HKLM\SOFTWARE\Fortinet\FortiClient\FA_ESNAC
```

Tout *semble* sain : le MSI a réussi, le service tourne, le code d'invitation est dans le
registre. Rien ne s'enrôle.

## Ce qui ne marche pas

| Tentative | Pourquoi ça échoue |
|---|---|
| Installer en SYSTEM | session 0, pas de jeton Entra — le cœur du problème |
| `FortiESNAC.exe -r <code>` depuis un script de logon | manifeste `requireAdministrator` → **invite UAC à chaque ouverture de session**, erreur 1223 pour un utilisateur standard |
| Élever `FortiESNAC.exe` avec Intune EPM | EPM substitue un **compte virtuel** `MEM\<NETBIOS>_<user>_$` (autorité SID `S-1-5-110`) sans cache TokenBroker → ni WebAccount ni PRT → `0xCAA100D8` → `azuretoken is invalid` |
| Tâche planifiée au logon | s'exécute hors du bureau interactif ; l'élévation EPM n'y est pas fiable |
| Réinstaller un client bloqué | `0x1D` est une transaction *en attente*. Seul un **redémarrage** la finalise. Réinstaller relance la même attente |

> **Ne ciblez jamais `FortiESNAC.exe` ni `FortiTray.exe` avec une règle EPM.** Cette seule
> erreur coûte des semaines : l'enrollment échoue avec une erreur qui a l'air de venir du
> serveur, alors que tous les contrôles locaux passent.

## Ce qui marche

Séparer la partie privilégiée de la partie identité.

```
App Win32 Intune  (SYSTEM)     install.ps1
                               ├── copie l'installeur EMS + logon-install.ps1
                               │   dans C:\ProgramData\IntuneStaging\FortiEMS
                               ├── écrit target-version.txt (version de l'EXE embarqué)
                               ├── Utilisateurs : lecture/exécution + création seule sur ce dossier
                               └── écrit HKLM\...\Run  'FortiEMS-Install'

Ouverture de session (USER)    logon-install.ps1
                               ├── enrôlé ET à la version cible ?     -> arrêt définitif
                               ├── déjà tenté, client présent        -> constat seulement, jamais de relance
                               ├── déjà tenté, client ABSENT         -> nouvelle tentative (3 max)
                               ├── attente de AzureAdPrt = YES (30 min max)
                               └── lance l'installeur                (élevé par Intune EPM)
```

Les marqueurs portent la version cible (`exe-launched-<ver>.flag`, `enrolled-<ver>.flag`).
Repackager avec un installeur EMS plus récent réarme donc la mise à niveau tout seul : aucun
nettoyage sur les postes, aucune constante à modifier. `Publish-Win32App.ps1` injecte la même
version dans `detection.ps1` au moment de l'upload (jeton `__TARGET_VERSION__`), car un script
de détection n'a pas accès au contenu du package.

Une **clé Run HKLM s'exécute dans la session de l'utilisateur connecté**. Le dépôt est donc
privilégié et le lancement de l'installeur ne l'est pas — exactement la séparation voulue. Et
comme un lancement par clé Run est un processus utilisateur ordinaire, **EPM l'intercepte de
façon fiable** (vérifié).

Mesuré sur un poste neuf : logon à `13:52:14`, installeur à `13:52:15`, `status 0x2` avec
`fgt_sn` renseigné à `13:54:17`. Aucune invite UAC, aucune tâche planifiée.

Sur d'autres postes, le MSI se termine en **3010** (`FortiClient requested a reboot`).
L'installeur tourne en `/norestart`, la transaction reste donc en attente : le code
d'invitation est dans le registre, `FA_ESNAC` est encore vide, et **rien ne s'enrôle avant le
redémarrage du poste**. Après le redémarrage et l'ouverture de session suivante, l'enrollment
aboutit sans autre action. Dans cet état, ne réinstallez pas et ne lancez pas de remédiation :
c'est le chemin direct vers `0x1D`.

## Contenu

```
package/     install.ps1          dépose la charge utile + clé Run      (app Win32, SYSTEM)
             logon-install.ps1    attend le PRT, lance l'installeur     (session utilisateur)
             detection.ps1        détection Intune : vérifie le dépôt, pas l'installation
             uninstall.ps1        retire la charge utile, la clé Run, le produit

tools/       New-EpmElevationRule.ps1   crée la règle EPM via Graph
             Publish-Win32App.ps1       construit + publie n'importe quelle app Win32 (avec GUI)
             Get-IntuneRemediations.ps1 exporte ce que vos remédiations contiennent VRAIMENT

remediation/ Detect-FortiTrialExpired.ps1 rapport flotte (lecture seule) de la boucle « essai expiré »
             cleanup-enroll-detect.ps1  MIGRATION UNIQUEMENT — voir plus bas
             cleanup-enroll-fix.ps1     MIGRATION UNIQUEMENT — voir plus bas
```

Déposez vos installeurs générés par EMS dans `package\x64\` et `package\arm64\`.

### Dossier de dépôt

Tout est déposé sous `C:\ProgramData\IntuneStaging\FortiEMS`. Le nom est volontairement
générique — changez-le si vous avez votre propre convention. Il est déclaré par deux constantes
en tête de **install.ps1**, **detection.ps1** et **uninstall.ps1** :

```powershell
$BaseDir   = 'C:\ProgramData\IntuneStaging'
$StageName = 'FortiEMS'
```

Les trois doivent être identiques, sinon la détection ne passe jamais et la désinstallation
laisse la charge utile sur place. `logon-install.ps1` n'a besoin d'aucune constante : il déduit
le dossier de sa propre position sur le disque.

### Les scripts de `remediation/cleanup-*` servent uniquement à la migration

Ils appartiennent à une **ancienne conception** de ce déploiement (une tâche planifiée
`FortiTray-EMS-Enrollment` et/ou une clé Run `FortiEMS-Enroll` lançant un wrapper
`FortiTray-Enroll.ps1`, qui appelait `FortiESNAC.exe` directement — une invite UAC à chaque
logon). Ils ciblent ces noms **exactement**, et ne touchent donc pas aux éléments actuels
(`FortiEMS-Install`, `logon-install.ps1`, le dossier de dépôt).

Si vous partez de ce dépôt, **vous n'en avez pas besoin — ne les déployez pas.**
Si vous les utilisez, renseignez `$LegacyBaseDir` en tête des deux fichiers avec le dossier où
vivait votre ancien wrapper. Notez que le script de correction *recrée* aussi la clé Run
`FortiTray` quand `FortiTray.exe` est présent (le démarrage automatique légitime de l'interface,
que l'ancien nettoyage supprimait).

## Correctif de sécurité — à appliquer si vous avez déployé une version antérieure

Les versions précédentes d'`install.ps1` accordaient **Modifier** (`(OI)(CI)M`) aux
Utilisateurs sur le dossier de dépôt et sur son parent. Ce dossier contient
`logon-install.ps1`, que la clé Run HKLM exécute à l'ouverture de session de **tous** les
utilisateurs, administrateurs compris. Un utilisateur standard pouvait remplacer le script et
attendre qu'un administrateur se connecte : **élévation de privilèges locale**.

La version actuelle coupe l'héritage sur le dossier de dépôt et n'accorde aux Utilisateurs que
lecture/exécution, plus *création de fichiers* sur le dossier lui-même (sans héritage) — de quoi
déposer de nouveaux marqueurs, pas d'écraser un fichier existant. Elle retire aussi le droit
Modifier explicite du dossier parent. Republier le package corrige les postes déjà déployés au
cycle Intune suivant.

## Pièges à connaître

**La boucle « essai expiré ».** Un client qui a perdu son enregistrement EMS lance chaque
minute un `License Expire Check` : `trial period has expired` → VPN coupé →
`remove cloud client token and invitation code`. Toute invitation réinjectée est effacée dans la
minute, et une installation par-dessus n'est qu'un *reconfigure* MSI qui ne remet pas l'essai à
zéro. Seule une installation **fraîche** en sort. `detection.ps1` repère une boucle *active*
(traces de moins d'une heure) et `install.ps1` désinstalle alors **une fois par version cible**
pour que l'ouverture de session suivante réinstalle proprement. Une seconde occurrence est
laissée à une intervention manuelle — jamais de boucle de redémarrages.

**Windows PowerShell 5.1 n'est pas PowerShell 7.** Sous 5.1 (l'hôte qu'utilise Intune), un exe
natif qui écrit sur stderr avec `2>&1` et `$ErrorActionPreference = 'Stop'` *lève une
exception*. Un `reg delete` sur une clé absente a interrompu une installation de cette façon,
alors que le même code passait tous les tests locaux sous 7.

**La course au PRT est le piège le plus coûteux.** Dans une session fraîche, WAM / le PRT Entra
devient disponible entre quelques secondes et une trentaine de minutes. Si FortiClient demande
son jeton avant que WAM soit prêt, vous obtenez `azuretoken is invalid` — et l'invitation EMS
est **perdue côté serveur** (« invitation lost if the initial user verification fails »). Le
poste reste alors à `0x1D` pour de bon : ni un redémarrage ni une installation par-dessus ne le
rattrapent, seule une désinstallation complète.

Une clé Run se déclenche tôt à l'ouverture de session, en plein dans cette fenêtre.
`logon-install.ps1` attend donc `AzureAdPrt : YES` — en rafraîchissant le PRT toutes les 20
secondes, 30 minutes maximum — avant de lancer quoi que ce soit. Si le PRT n'apparaît jamais, il
**ne pose délibérément aucun marqueur** : partout ailleurs le marqueur est posé même en cas
d'échec, pour éviter une boucle de relances, mais ici mieux vaut ne rien faire et réessayer au
logon suivant que de griller l'invitation. `dsregcmd /status` et `/RefreshPrt` ne demandent
aucune élévation.

**Intune exécute les commandes d'installation Win32 dans l'hôte PowerShell 32 bits.** Une
écriture dans `HKLM:\SOFTWARE\...\Run` est redirigée silencieusement vers `WOW6432Node`.
`New-ItemProperty` réussit, votre journal dit « clé posée », et une détection 64 bits ne voit
rien. Relancez via `SysNative` et **relisez la valeur par une vue 64 bits explicite** — une
écriture réussie ne prouve pas que c'est la bonne ruche.

**`forticlientsetup_*.exe` est un auto-extracteur.** Il rend la main en une seconde environ et
laisse `msiexec` travailler. `Start-Process -Wait` n'attend que l'extraction. Juger le résultat
à ce moment conclut à tort « aucun code d'invitation » alors que rien n'est encore installé.

**Les packages générés par EMS ne sont pas signés.** L'injection du code d'invitation casse la
signature Authenticode : une règle EPM ne peut donc cibler que **nom de fichier + SHA256** — et
chaque repackaging change le hash. Mettez la règle à jour en même temps, sinon l'élévation cesse
silencieusement et les installations échouent en 1223.

**Chaque package EMS embarque son propre code d'invitation.** Deux packages générés à des dates
différentes portent des codes différents. N'en codez jamais un en dur dans un script.

**Seul `fgt_sn` prouve l'enrollment.** Tester `status -eq 2` déclare cassés des postes sains
(`0x1E`, `0x12`). Nous avons effacé une installation fonctionnelle de cette façon.

**Vérifiez ce que votre tenant exécute réellement.** Une de nos remédiations testait
`Get-Service FortiESNAC` — un service qui n'existe pas en 7.4.x, où le vrai s'appelle
`FA_Scheduler`. La condition se réduisait donc à *« installé et pas encore enrôlé →
désinstaller »*, toutes les heures, sur toute la flotte, pendant un mois. Le correctif existait
sur disque et n'avait jamais été republié. `Get-IntuneRemediations.ps1` exporte le contenu réel
des scripts, que le portail n'affiche pas.

## Paramètres Intune

| Paramètre | Valeur |
|---|---|
| Comportement d'installation | **Système** |
| Commande d'installation | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` |
| Commande de désinstallation | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1` |
| Détection | script, `detection.ps1` |
| Codes de retour | `0` succès · `3010`/`1641` redémarrage · `1618` réessayer · **`1223` échec** |

Associez `1223` à **échec** : c'est le code d'une élévation refusée. L'installation du dépôt ne
le renvoie jamais (elle tourne en SYSTEM), mais `uninstall.ps1` le renvoie quand `msiexec /x`
n'est pas élevé ; laissé en succès, il signalerait une désinstallation qui n'a jamais eu lieu.
`Publish-Win32App.ps1` ajoute cette correspondance avec `-FailOnElevationDenied`.

Règle EPM — nom de fichier + SHA256, **Automatique**, **Autoriser tous les processus enfants à
s'exécuter avec élévation** (l'auto-extracteur appelle `msiexec` en processus enfant). Affectez
l'app et la stratégie EPM au **même** groupe, sinon les installations échouent en 1223 faute
d'élévation.

## Prérequis

PowerShell 7, `Microsoft.Graph.Authentication`, et le
[Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) de
Microsoft (placez `IntuneWinAppUtil.exe` à côté de `Publish-Win32App.ps1`, ou passez
`-IntuneWinAppUtil`).

Testé avec FortiClient 7.4.7 et 7.4.8 sous Windows 11, postes joints à Entra et en jonction
hybride.

## Avertissement

Partagé tel quel, issu d'un déploiement en production. Lisez les scripts avant de les exécuter :
certains désinstallent des logiciels. Testez d'abord sur un seul poste.
