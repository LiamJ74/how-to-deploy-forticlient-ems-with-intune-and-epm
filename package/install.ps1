# ============================================================
# FortiClient EMS - INSTALL (ultra simple) - PHASE DE DEPOT
# Contexte Intune : Win32 app, "Install behavior = SYSTEM", 64 bits.
#
# Ce script N'INSTALLE PAS FortiClient. Il depose la charge utile et arme le lancement au
# logon :
#   1. Copie l'EXE de l'architecture du poste + logon-install.ps1 dans
#      $BaseDir\$StageName (voir les constantes plus bas)
#   2. Ouvre ce dossier en ecriture aux utilisateurs (le script de logon, non eleve, doit
#      pouvoir y ecrire ses logs et ses marqueurs)
#   3. Pose la cle Run HKLM 'FortiEMS-Install' -> logon-install.ps1
#
# POURQUOI LE DEPOT EN SYSTEM :
#   Par defaut, un utilisateur peut creer un fichier dans ProgramData mais PAS modifier ceux
#   crees par SYSTEM. Deposer en contexte utilisateur marcherait sur un poste a l'ACL
#   permissive et echouerait ailleurs. SYSTEM depose, puis accorde explicitement l'ecriture.
#
# POURQUOI L'INSTALLATION SE FAIT QUAND MEME EN USER :
#   L'enrollment EMS exige un jeton Entra, qui n'existe que dans la session interactive de
#   l'utilisateur (WebAccount / PRT). Une installation en session 0 laisse le client boucler
#   sur "Azure Token Required", bloque a status 0x1D.
#   HKLM\...\Run s'execute DANS LA SESSION DE L'UTILISATEUR a l'ouverture de session : le
#   depot est privilegie, le lancement de l'EXE ne l'est pas. C'est exactement le partage
#   voulu.
#   Valide le 2026-09-21 : install manuelle elevee en session interactive -> status 0x2,
#   fgt_sn renseigne, sans tache planifiee ni wrapper d'enrollment.
#
# POURQUOI UNE CLE RUN ET PAS UNE TACHE PLANIFIEE :
#   Une tache s'executerait hors du bureau interactif, ou l'elevation EPM n'est pas fiable.
#   Un processus lance par la cle Run au logon est un lancement utilisateur ordinaire -
#   exactement le cas qu'EPM est concu pour intercepter.
#
# /!\ Ne JAMAIS cibler FortiESNAC.exe ni FortiTray.exe dans une regle EPM : EPM substitue un
#     compte virtuel MEM\<NETBIOS>_<user>_$ sans WebAccount ni PRT Entra -> "azuretoken is
#     invalid" (incident du 2026-08-27). La regle ne couvre QUE forticlientsetup_*.exe.
# ============================================================

$ErrorActionPreference = 'Stop'

# --- CONSTANTES A ADAPTER ---------------------------------------------------
# Emplacement du depot et des journaux. Nom volontairement neutre : remplacez-le par la
# convention de votre organisation si vous en avez une.
#
# /!\ Ces deux valeurs doivent etre IDENTIQUES dans install.ps1, detection.ps1 et
#     uninstall.ps1. logon-install.ps1 n'en a pas besoin : il deduit le chemin de sa propre
#     position sur le disque, donc il suit automatiquement. Une divergence rendrait la
#     detection toujours non conforme et la desinstallation incomplete.
$BaseDir   = 'C:\ProgramData\IntuneStaging'
$StageName = 'FortiEMS'

# --- Relance en 64 bits -----------------------------------------------------
# Intune execute la ligne de commande d'installation dans l'hote PowerShell 32 BITS. Toute
# ecriture dans HKLM:\SOFTWARE\...\Run y est silencieusement redirigee vers WOW6432Node :
# New-ItemProperty reussit, le log affiche "cle posee", et la detection (vue 64 bits) ne voit
# rien. Constate le 2026-09-22 sur PC-TEST-01.
# SysNative est l'alias qui donne acces au System32 reel depuis un process 32 bits ; il
# n'existe PAS dans un process deja 64 bits, d'ou le test prealable.
if (-not [Environment]::Is64BitProcess) {
    $p = Start-Process "$env:WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
            -NoNewWindow -Wait -PassThru
    exit $p.ExitCode
}

$LogDir  = $BaseDir
$Stage   = Join-Path $LogDir $StageName
$LogFile = Join-Path $LogDir 'FortiClientEMS-ultrasimple-install.log'
$RunKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'FortiEMS-Install'
$Esnac   = 'HKLM:\SOFTWARE\Fortinet\FortiClient\FA_ESNAC'

New-Item -ItemType Directory -Path $Stage -Force | Out-Null
function Log ($m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $m" | Out-File $LogFile -Append -Encoding UTF8
    Write-Host $m
}

Log "=== Depot FortiClient EMS (ultra simple) sur $env:COMPUTERNAME ==="

# Elevation attendue = True. Un False signifie que l'app est configuree en User : le depot
# echouerait sur tout poste dont l'ACL de ProgramData n'est pas permissive.
$id       = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
Log ("Identite={0}  Eleve={1}  64bits={2}  (attendus : True / True)" -f
     $id.Name, $elevated, [Environment]::Is64BitProcess)

# --- 1. Identifier l'EXE du poste et la version cible ---------------------
# La version CIBLE est celle de l'EXE embarque dans ce package, jamais une constante ecrite
# a la main : repackager avec un 7.4.9 suffit a faire suivre le depot, le script de logon et
# la detection, sans toucher une ligne de code.
$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$arch = if ((Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture -eq 12) { 'arm64' } else { 'x64' }

$exe = Get-ChildItem (Join-Path $dir $arch) -Filter *.exe -File -ErrorAction SilentlyContinue |
       Select-Object -First 1
if (-not $exe) { Log "ERREUR : aucun .exe dans $dir\$arch"; exit 1 }

$TargetVersion = [version]$exe.VersionInfo.FileVersion
Log "Version cible (EXE du package) : $TargetVersion"

# Version de FortiClient actuellement installee, si presente.
function Get-InstalledVersion {
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $a = Get-ItemProperty $root -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -eq 'FortiClient' } | Select-Object -First 1
        if ($a.DisplayVersion) { try { return [version]$a.DisplayVersion } catch { } }
    }
    return $null
}
$installed = Get-InstalledVersion

# --- 0. Client bloque dans la boucle "essai expire" -> UNE desinstallation ------------
# Constat du 2026-10-12 (PC-TEST-02) : un FortiClient qui a perdu son enregistrement EMS
# lance toutes les 60 s un 'License Expire Check' :
#   "FortiClient VPN trial period has expired" -> "Disconnect sslvpn or ipsec vpn"
#   -> "remove cloud client token and invitation code"
# Le VPN est coupe et toute invitation reinjectee (FCConfig, registre) est effacee dans la
# minute ; FortiShield interdit d'ecrire FA_ESNAC. Une reinstallation PAR-DESSUS ne fait qu'un
# 'reconfigure' MSI et ne remet pas l'essai a zero. Seule une installation FRAICHE en sort.
#
# On desinstalle donc ici (SYSTEM), puis le depot normal plus bas arme l'installation fraiche
# au prochain logon. Rien n'est perdu pour l'utilisateur : son VPN est deja coupe.
#
# Garde-fous contre les redemarrages a repetition :
#   - declenchement uniquement sur une boucle ACTIVE (traces de moins d'une heure), jamais sur
#     un simple etat du registre ni sur des traces anciennes restees apres une reinstallation ;
#   - UNE seule desinstallation par poste et par version cible (marqueur hors du depot, qui
#     survit donc a la desinstallation). Au-dela : rien, intervention manuelle ;
#   - 3010 rendu SEULEMENT si Windows l'exige (msiexec 3010/1641 ou FortiShield encore charge).
$ReinstallFlag = Join-Path $LogDir "FortiEMS-reinstall-$TargetVersion.flag"
$CleanupFlag   = Join-Path $Stage 'cleanup-pending.flag'
$needReboot    = $false

function Test-TrialLoop {
    $trace = 'C:\Program Files\Fortinet\FortiClient\logs\trace'
    $log = Get-ChildItem $trace -Filter 'FortiESNAC*.log' -File -ErrorAction SilentlyContinue |
           Where-Object Name -notmatch '_error' | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $log) { return $false }
    # La boucle ecrit toutes les minutes : la fin du fichier suffit.
    $tail = Get-Content $log.FullName -Tail 5000 -ErrorAction SilentlyContinue
    $since = (Get-Date).AddMinutes(-60)
    $recent = {
        param($pattern)
        $hit = $tail | Where-Object { $_ -like "*$pattern*" } | Select-Object -Last 1
        if (-not $hit) { return $false }
        # Horodatage local en tete : [2026-10-12 09:52:00.9105135 UTC+01:00]
        try { return ([datetime]::ParseExact($hit.Substring(1, 19), 'yyyy-MM-dd HH:mm:ss', $null) -gt $since) }
        catch { return $false }
    }
    return ((& $recent 'trial period has expired') -and (& $recent 'remove cloud client token and invitation code'))
}

# Supprime l'etat FortiClient residuel (FA_ESNAC compris) dans les deux vues du registre.
# /!\ Sous Windows PowerShell 5.1 (celui d'Intune), un exe natif qui ecrit sur stderr avec
#     '2>&1' et $ErrorActionPreference='Stop' LEVE UNE EXCEPTION : 'reg delete' sur une cle
#     absente (WOW6432Node) a ainsi interrompu une version anterieure sur PC-TEST-02 le 2026-10-12.
#     PowerShell 7 ne le fait pas, d'ou un test local trompeur. On ne vise donc que les cles
#     presentes, en 'Continue' local.
function Remove-FortiState {
    $ErrorActionPreference = 'Continue'
    foreach ($v in @(@{ Ps = 'HKLM:\SOFTWARE\Fortinet\FortiClient';             Reg = 'HKLM\SOFTWARE\Fortinet\FortiClient' },
                     @{ Ps = 'HKLM:\SOFTWARE\WOW6432Node\Fortinet\FortiClient'; Reg = 'HKLM\SOFTWARE\WOW6432Node\Fortinet\FortiClient' })) {
        if (Test-Path $v.Ps) { $null = cmd.exe /c "$env:WINDIR\System32\reg.exe delete $($v.Reg) /f /reg:64 2>nul" }   # chemins sans espace : pas de guillemets (cmd /c les mangerait)
    }
}

# Nettoyage reporte par un passage precedent (FortiShield etait encore charge).
if ((Test-Path $CleanupFlag) -and -not $installed) {
    $shield = Get-CimInstance Win32_SystemDriver -Filter "Name='FortiShield'" -ErrorAction SilentlyContinue
    if ($shield -and $shield.State -eq 'Running') {
        Log 'Nettoyage FA_ESNAC toujours en attente : FortiShield encore charge -> redemarrage requis'
        exit 3010
    }
    Remove-FortiState
    if (Test-Path 'HKLM:\SOFTWARE\Fortinet\FortiClient') { Log 'AVERTISSEMENT : HKLM\SOFTWARE\Fortinet\FortiClient toujours present' }
    else { Log 'Nettoyage reporte effectue : etat FortiClient residuel supprime' }
    Remove-Item $CleanupFlag -Force -ErrorAction SilentlyContinue
}

if ($installed -and (Test-TrialLoop)) {
    if (Test-Path $ReinstallFlag) {
        Log ("Boucle 'essai expire' ACTIVE, mais reinstallation deja faite pour {0} ({1}) -> AUCUNE action, aucun redemarrage. Intervention manuelle requise." -f
             $TargetVersion, (Get-Content $ReinstallFlag -Raw -ErrorAction SilentlyContinue).Trim())
        exit 0
    }
    Log "Boucle 'essai expire' ACTIVE (FortiClient $installed, VPN coupe, invitation effacee chaque minute) -> desinstallation pour reinstallation fraiche"

    # Jamais pendant une installation en cours : Intune reessaiera (1618 = retry).
    $busy = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like 'forticlientsetup*' -or ($_.Name -eq 'msiexec.exe' -and $_.CommandLine -notmatch '/V\s*$') -or
        ($_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'logon-install\.ps1')
    }
    if ($busy) { Log ("Installation en cours ({0}) -> 1618, nouvel essai Intune plus tard" -f (($busy.Name | Sort-Object -Unique) -join ', ')); exit 1618 }

    $app = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -eq 'FortiClient' -and $_.PSChildName -match '^\{.+\}$' } | Select-Object -First 1
    if (-not $app) { Log 'ERREUR : code produit FortiClient introuvable -> aucune action'; exit 1 }

    $msiLog = Join-Path $LogDir "FortiClientEMS-ultrasimple-reinstall-msi-$($app.PSChildName).log"
    $p = Start-Process "$env:WINDIR\System32\msiexec.exe" -Wait -PassThru `
            -ArgumentList @('/x', $app.PSChildName, '/qn', 'REBOOT=ReallySuppress', 'MSIRESTARTMANAGERCONTROL=Disable', '/l*v', "`"$msiLog`"")
    Log "msiexec /x $($app.PSChildName) -> ExitCode=$($p.ExitCode) (log : $msiLog)"
    # Echec = aucun redemarrage demande ; Intune reessaiera, le marqueur n'est pas pose.
    if ($p.ExitCode -notin 0, 3010, 1641, 1605) { Log "ECHEC de la desinstallation ($($p.ExitCode)) -> aucune autre action"; exit 1 }
    if ($p.ExitCode -in 3010, 1641) { $needReboot = $true }

    "$(Get-Date -Format 'o') - desinstalle FortiClient $installed (msiexec $($p.ExitCode))" |
        Out-File $ReinstallFlag -Encoding UTF8 -Force

    # L'etat d'enregistrement residuel (FA_ESNAC...) doit disparaitre pour que l'installation
    # reparte de zero. FortiShield se decharge normalement avec la desinstallation (constate le
    # 2026-09-21) ; s'il reste charge, le nettoyage est reporte apres redemarrage.
    $shield = Get-CimInstance Win32_SystemDriver -Filter "Name='FortiShield'" -ErrorAction SilentlyContinue
    if ($shield -and $shield.State -eq 'Running') {
        Log 'FortiShield encore charge -> nettoyage FA_ESNAC reporte apres redemarrage'
        'pending' | Out-File $CleanupFlag -Encoding UTF8 -Force
        $needReboot = $true
    } else {
        Remove-FortiState
        if (Test-Path 'HKLM:\SOFTWARE\Fortinet\FortiClient') { Log 'AVERTISSEMENT : HKLM\SOFTWARE\Fortinet\FortiClient toujours present' }
        else { Log 'Etat FortiClient residuel supprime (FA_ESNAC compris)' }
    }

    # Le script de logon doit refaire une vraie installation : on leve ses marqueurs.
    Get-ChildItem $Stage -Filter '*.flag' -File -ErrorAction SilentlyContinue |
        Where-Object Name -match '^(exe-launched|enrolled)' | Remove-Item -Force -ErrorAction SilentlyContinue
    $installed = $null
    Log ("Desinstallation terminee -> depot et installation fraiche au prochain logon{0}" -f
         $(if ($needReboot) { ' (redemarrage requis par Windows : 3010)' } else { ' (aucun redemarrage demande)' }))
}

# Deja enrole ET deja a la bonne version -> rien a faire.
# /!\ Le test ne peut PAS se limiter a fgt_sn : un poste enrole sur une version ancienne doit
# quand meme recevoir le depot pour etre mis a niveau. C'est precisement le cas des postes
# restes en arriere, enroles jadis puis tombes en 'Not Registered'.
# Seule la presence de fgt_sn fait foi pour l'enrollment : des postes sains portent 0x1E / 0x12,
# et un test strict sur 'status -eq 2' avait casse des enrollments valides.
$e = Get-ItemProperty $Esnac -ErrorAction SilentlyContinue
if ($e.fgt_sn -and $installed -and $installed -ge $TargetVersion) {
    Log ("Deja enrole (status 0x{0:X}) en version {1} >= cible {2} -> rien a deposer" -f [int]$e.status, $installed, $TargetVersion)
    exit 0
}
if ($e.fgt_sn) {
    Log ("Enrole mais en version {0} < cible {1} -> depot pour mise a niveau" -f
         $(if ($installed) { $installed } else { 'inconnue' }), $TargetVersion)
}

# --- 1a. Copier l'EXE + le script de logon --------------------------------

Copy-Item $exe.FullName -Destination $Stage -Force
$stagedExe = Join-Path $Stage $exe.Name
# Le SHA256 conditionne le declenchement de la regle EPM (packages EMS non signes -> aucune
# regle par certificat possible). Le tracer rend un echec d'elevation diagnosticable.
Log "Arch=$arch  EXE depose : $($exe.Name)  SHA256=$((Get-FileHash $stagedExe -Algorithm SHA256).Hash)"

$logonSrc = Join-Path $dir 'logon-install.ps1'
if (-not (Test-Path $logonSrc)) { Log "ERREUR : logon-install.ps1 absent du package"; exit 1 }
Copy-Item $logonSrc -Destination $Stage -Force
$stagedLogon = Join-Path $Stage 'logon-install.ps1'
Log "Script de logon depose : $stagedLogon"

# --- 1b. Marqueur de version cible ----------------------------------------
# Le script de logon lit ce fichier pour savoir vers quoi il doit amener le poste, et pour
# nommer son marqueur de tentative. Un changement de version cible invalide donc
# automatiquement la tentative precedente.
Set-Content -Path (Join-Path $Stage 'target-version.txt') -Value $TargetVersion.ToString() -Encoding UTF8 -Force
Log "Version cible ecrite dans target-version.txt"

# --- 1c. Installation existante sans code d'invitation -> reamorcer --------
# Un FortiClient installe mais depourvu d'invitation_code ne s'enrolera jamais : il ne sait pas
# a quel EMS s'adresser. Le marqueur 'une seule tentative' doit alors etre leve, sinon le script
# de logon se contenterait de constater l'echec a chaque session sans jamais reessayer.
$inv = (Get-ItemProperty "$Esnac\cloud_client" -ErrorAction SilentlyContinue).invitation_code
$fcInstalled = Test-Path 'C:\Program Files\Fortinet\FortiClient\FortiESNAC.exe'
if ($fcInstalled -and -not $inv) {
    # Toutes les tentatives de cette version (exe-launched-<ver>.flag, .2.flag, .3.flag)
    Get-ChildItem $Stage -Filter "exe-launched-$TargetVersion*.flag" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Log 'FortiClient installe SANS code d''invitation -> marqueur de tentative leve, nouvel essai au prochain logon'
} elseif ($inv) {
    Log "Code d'invitation deja present sur le poste : $inv"
}

# --- 2. Droits sur le dossier de depot ------------------------------------
# Le script de logon, non eleve, doit pouvoir CREER ses marqueurs (exe-launched.flag,
# enrolled.flag). Il ne les ecrit que s'ils sont ABSENTS : le droit de CREATION suffit,
# celui de MODIFICATION est inutile.
#
# /!\ Ne JAMAIS accorder (OI)(CI)M ici. Ce dossier contient logon-install.ps1, que la cle
#     Run HKLM execute a l'ouverture de session de TOUS les utilisateurs du poste, comptes
#     d'administration compris. Avec un droit Modifier, un utilisateur standard y depose son
#     code et attend qu'un administrateur ouvre une session : elevation de privileges immediate.
#     Faille constatee et corrigee le 2026-09-29.
#
# SID litteraux (*S-1-...) et non les noms, qui dependent de la langue du poste :
#   S-1-5-18 SYSTEM   S-1-5-32-544 Administrateurs
#   S-1-5-32-545 Utilisateurs      S-1-3-0 CREATEUR PROPRIETAIRE
$icacls = "$env:WINDIR\System32\icacls.exe"

# Couper l'heritage, sinon le droit Modifier du dossier parent revient.
$null = & $icacls $Stage /inheritance:r 2>&1

# (OI)(CI) = herite par les fichiers et les sous-dossiers.
# (IO) sur CREATEUR PROPRIETAIRE = ne s'applique qu'aux objets crees ensuite, pas au dossier.
$null = & $icacls $Stage /grant `
            '*S-1-5-18:(OI)(CI)F' `
            '*S-1-5-32-544:(OI)(CI)F' `
            '*S-1-5-32-545:(OI)(CI)RX' `
            '*S-1-3-0:(OI)(CI)(IO)M' 2>&1

# SANS flag d'heritage : la regle ne vaut que pour LE DOSSIER. WD/AD y signifient
# "creer un fichier / un sous-dossier" et non "ecraser un fichier existant" - c'est
# exactement la distinction qui ferme la faille tout en laissant le script fonctionner.
$null = & $icacls $Stage /grant '*S-1-5-32-545:(WD,AD)' 2>&1
Log "Droits poses sur $Stage : utilisateurs en lecture/execution + creation de marqueurs"

# Journal commun, un cran au-dessus : AUCUN droit supplementaire n'est necessaire.
# C:\ProgramData accorde deja par heritage tout ce qu'il faut :
#   Utilisateurs  ReadAndExecute            (lire)
#   Utilisateurs  Write (ContainerInherit)  (creer un fichier, sans ecraser l'existant)
#   CREATEUR PROPRIETAIRE  Modify           (reecrire les fichiers qu'on a soi-meme crees)
# Le script de logon cree son journal, en devient proprietaire, et peut donc y ajouter ses
# lignes aux sessions suivantes.
#
# On retire au contraire le 'Modify' explicite que les versions precedentes posaient ici :
# ce dossier peut contenir d'autres scripts de l'organisation, qu'un utilisateur standard
# pourrait alors remplacer. /remove:g ne touche que les ACE explicites, les heritees sont conservees.
$null = & $icacls $LogDir /remove:g '*S-1-5-32-545' 2>&1
Log "Droit 'Modify' explicite retire de $LogDir (les droits herites de ProgramData suffisent)"

# --- 3. Armer le lancement au logon ---------------------------------------
# -WindowStyle Hidden ici, plus masquage de la console dans le script lui-meme : aucune
# fenetre a l'ouverture de session (la cle Run precedente, 'FortiEMS-Enroll', en affichait une).
$cmd = '"' + "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" + '"' +
       " -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$stagedLogon`""
New-ItemProperty -Path $RunKey -Name $RunName -PropertyType String -Value $cmd -Force | Out-Null

# Relecture en vue 64 bits EXPLICITE : c'est le seul controle qui prouve que la valeur n'a pas
# atterri dans WOW6432Node. Un New-ItemProperty qui "reussit" ne garantit pas la bonne ruche.
$check = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64').
             OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Run').GetValue($RunName)
if (-not $check) { Log "ERREUR : cle Run absente de la vue 64 bits apres ecriture"; exit 1 }
Log "Cle Run HKLM '$RunName' posee et verifiee en vue 64 bits"

# Nettoyage du residu 32 bits laisse par les versions anterieures du script : Windows execute
# aussi les entrees de WOW6432Node\...\Run, ce qui lancerait le wrapper deux fois par session.
$wow = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
if ((Get-ItemProperty $wow -ErrorAction SilentlyContinue).$RunName) {
    Remove-ItemProperty -Path $wow -Name $RunName -Force -ErrorAction SilentlyContinue
    Log 'Residu 32 bits (WOW6432Node) de la cle Run supprime'
}

Log '=== Depot termine - installation a la prochaine ouverture de session ==='
# 3010 uniquement apres une desinstallation que Windows veut terminer par un redemarrage.
if ($needReboot) { exit 3010 }
exit 0
