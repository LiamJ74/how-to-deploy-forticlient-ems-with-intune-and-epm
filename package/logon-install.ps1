# ============================================================
# FortiClient EMS - INSTALLATION AU LOGON (ultra simple)
# ------------------------------------------------------------
# Lance par la cle Run HKLM 'FortiEMS-Install' posee par install.ps1. Une cle Run HKLM
# s'execute DANS LA SESSION INTERACTIVE de l'utilisateur, sous son identite Entra reelle et
# SANS elevation - exactement ce qu'il faut ici.
#
# Lance l'EXE d'installation UNE SEULE FOIS des que FortiClient est pose (marqueur disque),
# puis se contente de constater l'etat aux ouvertures de session suivantes.
#
# L'elevation de l'EXE vient de la regle Intune EPM ciblant forticlientsetup_*.exe.
# Ce script lui-meme n'est pas eleve et n'en a pas besoin : install.ps1 (SYSTEM) a ouvert
# l'ecriture du dossier de depot aux utilisateurs.
#
# POURQUOI UNE SEULE TENTATIVE (une fois FortiClient pose) :
#   Relancer l'installeur sur un client deja pose ne relance pas l'enrollment et peut laisser
#   une transaction a moitie engagee (status 0x1D), l'etat dont on a mis un mois a sortir.
#   Si l'enrollment n'aboutit pas, c'est le REDEMARRAGE qui le debloque, pas une reinstallation.
#
# EXCEPTION : FortiClient TOTALEMENT ABSENT apres une tentative -> nouvelle tentative au logon
# suivant, jusqu'a $MaxTries au total. Cas PC-TEST-03 du 2026-10-15 : EPM n'a pas eleve
# l'installeur, qui a rendu ExitCode=0 sans rien installer ; le marqueur unique bloquait
# ensuite toute reprise. Sans client pose, aucune transaction ne peut etre a moitie engagee.
# Une tentative = un fichier (exe-launched-<ver>.flag, puis .2.flag, .3.flag) : creer suffit,
# aucun droit de modification ni de suppression n'est requis (poste partage compris).
#
# AUTO-DESARMEMENT : par marqueur 'enrolled.flag', pas par suppression de la cle Run - celle-ci
# est en HKLM et ce script n'a pas les droits pour l'effacer. C'est uninstall.ps1, qui tourne
# en SYSTEM, qui la retire. Un passage sur poste enrole coute une lecture de registre.
# ============================================================

# Masque la console de ce process -> aucune fenetre au logon, meme si -WindowStyle Hidden
# n'a pas ete honore par le shell appelant.
try {
    $h = Add-Type -Name Cw -Namespace Hide -PassThru -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);'
    $null = $h::ShowWindow($h::GetConsoleWindow(), 0)   # 0 = SW_HIDE
} catch { }

$ErrorActionPreference = 'Continue'

# AUCUNE CONSTANTE DE CHEMIN ICI, VOLONTAIREMENT : le dossier de depot est deduit de la
# position de ce script sur le disque. Si vous changez $BaseDir / $StageName dans
# install.ps1, detection.ps1 et uninstall.ps1, ce script suit sans modification.
$Stage   = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir  = Split-Path -Parent $Stage
$LogFile = Join-Path $LogDir 'FortiClientEMS-ultrasimple-logon.log'
$ExeLog  = Join-Path $LogDir 'FortiClientEMS-ultrasimple-exe.log'
$Esnac   = 'HKLM:\SOFTWARE\Fortinet\FortiClient\FA_ESNAC'

function Log ($m) {
    try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - [$env:USERNAME] $m" |
            Out-File $LogFile -Append -Encoding UTF8 } catch { }
}

# --- Version cible et version installee -----------------------------------
# La cible est celle de l'EXE depose par install.ps1, jamais une constante : repackager avec
# une version plus recente fait tout suivre automatiquement.
$TargetVersion = $null
$tv = Join-Path $Stage 'target-version.txt'
if (Test-Path $tv) { try { $TargetVersion = [version](Get-Content $tv -Raw).Trim() } catch { } }
if (-not $TargetVersion) {
    $se = Get-ChildItem $Stage -Filter 'forticlientsetup_*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($se) { try { $TargetVersion = [version]$se.VersionInfo.FileVersion } catch { } }
}

function Get-InstalledVersion {
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $a = Get-ItemProperty $root -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -eq 'FortiClient' } | Select-Object -First 1
        if ($a.DisplayVersion) { try { return [version]$a.DisplayVersion } catch { } }
    }
    return $null
}

# Les marqueurs sont NOMMES PAR VERSION. Un nouveau package invalide donc de lui-meme la
# tentative et l'enrollment de la version precedente, et la mise a niveau peut repartir
# sans qu'on ait a nettoyer quoi que ce soit sur le poste.
$verTag   = if ($TargetVersion) { $TargetVersion.ToString() } else { 'unknown' }
$Done     = Join-Path $Stage "enrolled-$verTag.flag"
$FesExe   = 'C:\Program Files\Fortinet\FortiClient\FortiESNAC.exe'
$MaxTries = 3

# Tentatives deja faites pour cette version : exe-launched-<ver>.flag, exe-launched-<ver>.2.flag...
function Get-Attempts {
    @(Get-ChildItem $Stage -Filter "exe-launched-$verTag*.flag" -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime)
}

# Installeur encore actif (auto-extracteur relance eleve par EPM, ou son orchestrateur) :
# conclure "absent" pendant qu'il travaille ferait relancer une installation en cours.
function Test-InstallerRunning {
    [bool](Get-Process -Name 'forticlientsetup*', 'FortiClientInstaller' -ErrorAction SilentlyContinue)
}

# Seule la presence de fgt_sn fait foi. Un test sur 'status -eq 2' considere comme non enroles
# des postes sains portant 0x1E / 0x12 - l'erreur qui avait casse un poste le 2026-09-14.
function Get-Enroll {
    $e = Get-ItemProperty $Esnac -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Enrolled = [bool]$e.fgt_sn
        Status   = [int]$e.status
        Invite   = (Get-ItemProperty "$Esnac\cloud_client" -ErrorAction SilentlyContinue).invitation_code
    }
}

# --- 0. Deja conclu -> sortie immediate, sans rien journaliser ------------
if (Test-Path $Done) { exit 0 }

# Desinstallation de reprise pas encore nettoyee (FortiShield charge jusqu'au redemarrage) :
# installer maintenant heriterait de l'ancien etat FA_ESNAC. install.ps1 (SYSTEM) nettoie
# apres le redemarrage ; l'installation se fera a l'ouverture de session suivante.
if (Test-Path (Join-Path $Stage 'cleanup-pending.flag')) {
    Log 'Nettoyage FA_ESNAC en attente (apres desinstallation de reprise) -> installation reportee au prochain logon'
    exit 0
}

Log "=== Ouverture de session sur $env:COMPUTERNAME ==="

# --- 1. Enrole ET a jour -> ecrire le marqueur et s'arreter ---------------
# /!\ Le test ne peut PAS se limiter a l'enrollment : un poste enrole sur une version ancienne
# doit quand meme etre mis a niveau. C'est le cas des postes restes en arriere, enroles jadis
# puis tombes en 'Not Registered' faute d'une version recente.
$st  = Get-Enroll
$cur = Get-InstalledVersion
Log ("Version installee : {0}  |  cible : {1}" -f
     $(if ($cur) { $cur } else { 'aucune' }), $(if ($TargetVersion) { $TargetVersion } else { 'inconnue' }))

if ($st.Enrolled -and $cur -and $TargetVersion -and $cur -ge $TargetVersion) {
    Log ("ENROLE et a jour (status 0x{0:X}, version {1}, invitation={2}) -> termine" -f $st.Status, $cur, $st.Invite)
    "$(Get-Date -Format 'o') - enrole status 0x$('{0:X}' -f $st.Status) version $cur" |
        Out-File $Done -Encoding UTF8 -Force
    exit 0
}
if ($st.Enrolled) {
    Log ("Enrole mais version {0} < cible {1} -> mise a niveau" -f
         $(if ($cur) { $cur } else { 'inconnue' }), $TargetVersion)
}

# --- 2. L'EXE a deja ete lance -> constater ; relancer seulement si rien n'est pose ---
$attempts = Get-Attempts
if ($attempts.Count) {
    $fc = (Test-Path $FesExe) -or [bool]$cur
    Log ("Deja tente {0} fois (dernier le {1}). FortiClient installe={2}, status 0x{3:X}, invitation={4}" -f
         $attempts.Count, $attempts[-1].LastWriteTime, $fc, $st.Status,
         $(if ($st.Invite) { $st.Invite } else { 'aucune' }))
    if (-not $fc) {
        if (Test-InstallerRunning) { Log 'Installeur encore actif -> on le laisse finir'; exit 0 }
        if ($attempts.Count -ge $MaxTries) {
            Log ("ECHEC : FortiClient toujours absent apres {0} tentatives. Verifier l'elevation EPM " -f $MaxTries +
                 "(C:\Program Files\Microsoft EPM Agent\Logs) et $ExeLog. Pour relancer : supprimer " +
                 "$Stage\exe-launched-$verTag*.flag")
            exit 0
        }
        Log ("FortiClient ABSENT malgre la tentative precedente (installeur probablement non eleve par EPM) " +
             "-> nouvelle tentative {0}/{1}" -f ($attempts.Count + 1), $MaxTries)
        # pas de exit : on enchaine sur l'attente du PRT puis le lancement
    } else {
        if (-not $st.Invite) {
            # Distinction essentielle : sans code d'invitation le client ignore a quel EMS
            # s'adresser. Aucun redemarrage n'y changera rien, c'est le package qui est en cause.
            Log 'ECHEC : FortiClient installe SANS code d''invitation -> l''EXE n''est pas un package de deploiement EMS. Regenerer le package depuis la console EMS.'
        } else {
            Log 'Client pose avec son code d''invitation, enrollment non finalise -> un REDEMARRAGE est requis (surtout pas une reinstallation).'
        }
        exit 0
    }
}

# --- 2b. ATTENDRE LE PRT ENTRA AVANT DE LANCER QUOI QUE CE SOIT -----------
# /!\ Course critique. Le moment ou WAM / le PRT devient disponible dans une session fraiche
# est VARIABLE : de quelques secondes a ~30 minutes. Si FortiClient demande son token avant
# que WAM soit pret, Fortinet rend "azuretoken is invalid" et - c'est la le piege - l'invitation
# EMS est PERDUE cote serveur ("invitation lost if the initial user verification fails").
# L'etat devient empoisonne : status 0x1D permanent, non recuperable sans wipe complet.
#
# La cle Run se declenche tres tot a l'ouverture de session, donc precisement dans la fenetre
# a risque. On attend donc explicitement AzureAdPrt=YES avant de lancer l'installeur, en
# rafraichissant le PRT entre deux verifications.
#
# dsregcmd /RefreshPrt et /status ne demandent AUCUNE elevation : ils tournent sous l'identite
# de l'utilisateur, ce qui est exactement ce qu'il faut ici.
function Test-Prt {
    try { return [bool](& dsregcmd.exe /status 2>$null | Select-String -Pattern 'AzureAdPrt\s*:\s*YES') }
    catch { return $false }
}

$prtDeadline = (Get-Date).AddMinutes(30)
$pn = 0
while (-not (Test-Prt) -and (Get-Date) -lt $prtDeadline) {
    $pn++
    Start-Process dsregcmd.exe -ArgumentList '/RefreshPrt' -WindowStyle Hidden -ErrorAction SilentlyContinue
    if ($pn -eq 1 -or $pn % 5 -eq 0) { Log "Attente du PRT Entra (AzureAdPrt=YES) - verification $pn" }
    Start-Sleep -Seconds 20
}

if (Test-Prt) {
    Log ("PRT Entra disponible apres {0} verification(s) -> lancement de l'installeur" -f $pn)
} else {
    # On renonce plutot que de tenter : un lancement sans PRT ne rate pas seulement, il
    # DETRUIT l'invitation cote EMS. Mieux vaut reessayer a la prochaine ouverture de session,
    # et c'est pour cela qu'aucun marqueur n'est pose dans cette branche.
    Log 'ABANDON : pas de PRT Entra apres 30 min. Lancer l''installeur maintenant perdrait l''invitation cote EMS. Nouvelle tentative au prochain logon.'
    exit 0
}

# --- 3. Lancement de l'EXE ------------------------------------------------
$exe = Get-ChildItem $Stage -Filter 'forticlientsetup_*.exe' -File -ErrorAction SilentlyContinue |
       Select-Object -First 1
if (-not $exe) { Log "ERREUR : aucun forticlientsetup_*.exe dans $Stage"; exit 1 }

$sha = (Get-FileHash $exe.FullName -Algorithm SHA256).Hash
$n   = (Get-Attempts).Count + 1
$Tried = if ($n -eq 1) { Join-Path $Stage "exe-launched-$verTag.flag" } else { Join-Path $Stage "exe-launched-$verTag.$n.flag" }
Log "Lancement de $($exe.Name)  SHA256=$sha  (tentative $n/$MaxTries)"

$p = Start-Process $exe.FullName -ArgumentList "/quiet /norestart /log `"$ExeLog`"" -Wait -PassThru
Log "ExitCode=$($p.ExitCode)"

# Marqueur pose MEME en cas d'echec : sinon chaque ouverture de session relancerait un
# installeur qui echoue, et le poste afficherait une invite a chaque logon. Le nombre de
# marqueurs borne les reprises a $MaxTries (voir etape 2).
"$(Get-Date -Format 'o') - exit $($p.ExitCode) - sha $sha" | Out-File $Tried -Encoding UTF8 -Force

# 1223 = elevation refusee : regle EPM absente, mal ciblee, ou perimee par un nouveau hash.
if ($p.ExitCode -eq 1223) {
    Log "ECHEC : elevation refusee (1223). Verifier la regle EPM - nom du fichier et SHA256 $sha"
    exit 0
}
if ($p.ExitCode -notin 0, 3010, 1641) { Log "Installation ECHEC ($($p.ExitCode)) - voir $ExeLog"; exit 0 }

# --- 4. Attendre la fin reelle de l'installation --------------------------
# /!\ forticlientsetup_*.exe est un AUTO-EXTRACTEUR : il rend la main en ~1 seconde et laisse
# msiexec poser le produit en arriere-plan. -Wait n'attend donc que l'extraction. Juger l'etat
# a ce moment-la conclut a tort "aucun code d'invitation", alors que rien n'est encore installe.
# Constate le 2026-09-22 : ExitCode=0 a 13:52:16, msiexec toujours actif ensuite.
$instDeadline = (Get-Date).AddMinutes(20)
while (-not (Test-Path $FesExe) -and (Get-Date) -lt $instDeadline) { Start-Sleep -Seconds 15 }

if (Test-Path $FesExe) {
    Log 'FortiClient pose (FortiESNAC.exe present) - attente de la configuration EMS'
    # La cle cloud_client est ecrite un peu apres les fichiers : laisser le MSI finir.
    $cfgDeadline = (Get-Date).AddMinutes(5)
    while (-not (Get-Enroll).Invite -and (Get-Date) -lt $cfgDeadline) { Start-Sleep -Seconds 15 }
} else {
    # Rien de pose : inutile d'attendre un enrollment. La ligne 'bUserIsElevated' du log EXE dit
    # si l'installeur a tourne eleve (1) ou non (0 = EPM n'a pas pris la main).
    $elev = Select-String -Path $ExeLog -Pattern 'bUserIsElevated=\d' -ErrorAction SilentlyContinue |
            Select-Object -Last 1 | ForEach-Object { $_.Matches[0].Value }
    $suite = if ($n -lt $MaxTries) { "nouvelle tentative au prochain logon ($($n + 1)/$MaxTries)" }
             else { 'plus de tentative automatique' }
    Log ("ECHEC : FortiESNAC.exe toujours absent apres 20 min ({0}) -> {1}" -f
         $(if ($elev) { $elev } else { 'elevation inconnue' }), $suite)
    exit 0
}

# Chaque package genere par la console EMS embarque SON PROPRE code d'invitation ; le tracer
# permet de savoir quel package a reellement servi sur le poste.
$st = Get-Enroll
Log ("Apres installation : status 0x{0:X}, invitation={1}" -f $st.Status,
     $(if ($st.Invite) { $st.Invite } else { "AUCUNE - verifier que l'EXE est bien un package de deploiement EMS" }))

# Courte fenetre laissee a l'enrollment automatique avant de conclure.
$deadline = (Get-Date).AddMinutes(10)
while (-not $st.Enrolled -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 30
    $st = Get-Enroll
}

if ($st.Enrolled) {
    Log ("=== ENROLE (status 0x{0:X}) ===" -f $st.Status)
    "$(Get-Date -Format 'o') - enrole status 0x$('{0:X}' -f $st.Status)" | Out-File $Done -Encoding UTF8 -Force
} else {
    Log ("Pas encore enrole apres 10 min (status 0x{0:X}). Un REDEMARRAGE est requis : " -f $st.Status +
         "l'installation en /norestart laisse la transaction en attente jusqu'au redemarrage. " +
         'La prochaine ouverture de session constatera l''etat.')
}
exit 0
