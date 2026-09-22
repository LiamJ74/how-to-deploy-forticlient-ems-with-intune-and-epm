# ============================================================
# FortiClient EMS - INSTALLATION AU LOGON (ultra simple)
# ------------------------------------------------------------
# Lance par la cle Run HKLM 'FortiEMS-Install' posee par install.ps1. Une cle Run HKLM
# s'execute DANS LA SESSION INTERACTIVE de l'utilisateur, sous son identite Entra reelle et
# SANS elevation - exactement ce qu'il faut ici.
#
# Lance l'EXE d'installation UNE SEULE FOIS (marqueur disque), puis se contente de constater
# l'etat aux ouvertures de session suivantes.
#
# L'elevation de l'EXE vient de la regle Intune EPM ciblant forticlientsetup_*.exe.
# Ce script lui-meme n'est pas eleve et n'en a pas besoin : install.ps1 (SYSTEM) a ouvert
# l'ecriture du dossier de depot aux utilisateurs.
#
# POURQUOI UNE SEULE TENTATIVE :
#   Relancer l'installeur sur un client deja pose ne relance pas l'enrollment et peut laisser
#   une transaction a moitie engagee (status 0x1D), l'etat dont on a mis un mois a sortir.
#   Si l'enrollment n'aboutit pas, c'est le REDEMARRAGE qui le debloque, pas une reinstallation.
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

$Stage   = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir  = Split-Path -Parent $Stage
$LogFile = Join-Path $LogDir 'FortiClientEMS-ultrasimple-logon.log'
$ExeLog  = Join-Path $LogDir 'FortiClientEMS-ultrasimple-exe.log'
$Tried   = Join-Path $Stage 'exe-launched.flag'
$Done    = Join-Path $Stage 'enrolled.flag'
$Esnac   = 'HKLM:\SOFTWARE\Fortinet\FortiClient\FA_ESNAC'

function Log ($m) {
    try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - [$env:USERNAME] $m" |
            Out-File $LogFile -Append -Encoding UTF8 } catch { }
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

Log "=== Ouverture de session sur $env:COMPUTERNAME ==="

# --- 1. Enrole -> ecrire le marqueur et s'arreter definitivement ----------
$st = Get-Enroll
if ($st.Enrolled) {
    Log ("ENROLE (status 0x{0:X}, invitation={1}) -> terminé" -f $st.Status, $st.Invite)
    "$(Get-Date -Format 'o') - enrole status 0x$('{0:X}' -f $st.Status)" |
        Out-File $Done -Encoding UTF8 -Force
    exit 0
}

# --- 2. L'EXE a deja ete lance -> constater, ne pas relancer --------------
if (Test-Path $Tried) {
    $fc = Test-Path 'C:\Program Files\Fortinet\FortiClient\FortiESNAC.exe'
    Log ("Deja tente le {0}. FortiClient installe={1}, status 0x{2:X}, invitation={3}" -f
         (Get-Item $Tried).LastWriteTime, $fc, $st.Status,
         $(if ($st.Invite) { $st.Invite } else { 'aucune' }))
    if (-not $fc) {
        Log 'AVERTISSEMENT : marqueur present mais FortiClient absent -> installation echouee. Verifier la regle EPM et le log EXE.'
    } elseif (-not $st.Invite) {
        # Distinction essentielle : sans code d'invitation le client ignore a quel EMS
        # s'adresser. Aucun redemarrage n'y changera rien, c'est le package qui est en cause.
        Log 'ECHEC : FortiClient installe SANS code d''invitation -> l''EXE n''est pas un package de deploiement EMS. Regenerer le package depuis la console EMS.'
    } else {
        Log 'Client pose avec son code d''invitation, enrollment non finalise -> un REDEMARRAGE est requis (surtout pas une reinstallation).'
    }
    exit 0
}

# --- 3. Premier et unique lancement de l'EXE ------------------------------
$exe = Get-ChildItem $Stage -Filter 'forticlientsetup_*.exe' -File -ErrorAction SilentlyContinue |
       Select-Object -First 1
if (-not $exe) { Log "ERREUR : aucun forticlientsetup_*.exe dans $Stage"; exit 1 }

$sha = (Get-FileHash $exe.FullName -Algorithm SHA256).Hash
Log "Lancement de $($exe.Name)  SHA256=$sha"

$p = Start-Process $exe.FullName -ArgumentList "/quiet /norestart /log `"$ExeLog`"" -Wait -PassThru
Log "ExitCode=$($p.ExitCode)"

# Marqueur pose MEME en cas d'echec : sinon chaque ouverture de session relancerait un
# installeur qui echoue, et le poste afficherait une invite a chaque logon.
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
$FesExe = 'C:\Program Files\Fortinet\FortiClient\FortiESNAC.exe'
$instDeadline = (Get-Date).AddMinutes(20)
while (-not (Test-Path $FesExe) -and (Get-Date) -lt $instDeadline) { Start-Sleep -Seconds 15 }

if (Test-Path $FesExe) {
    Log 'FortiClient pose (FortiESNAC.exe present) - attente de la configuration EMS'
    # La cle cloud_client est ecrite un peu apres les fichiers : laisser le MSI finir.
    $cfgDeadline = (Get-Date).AddMinutes(5)
    while (-not (Get-Enroll).Invite -and (Get-Date) -lt $cfgDeadline) { Start-Sleep -Seconds 15 }
} else {
    Log 'AVERTISSEMENT : FortiESNAC.exe toujours absent apres 20 min - installation en echec ou tres lente'
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
