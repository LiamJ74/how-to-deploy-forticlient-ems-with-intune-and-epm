# ============================================================
# PROACTIVE REMEDIATION - DETECTION : reste-t-il un lanceur d'enrollment FortiClient ?
# ------------------------------------------------------------
# /!\ SCRIPT DE MIGRATION - N'A DE SENS QUE SI VOUS AVEZ DEJA DEPLOYE L'ANCIEN DISPOSITIF.
#     Il ne concerne QUE l'architecture precedente (tache planifiee + cle Run
#     'FortiEMS-Enroll' + wrapper FortiTray-Enroll.ps1), qui tentait d'enroler en appelant
#     FortiESNAC.exe. Il ne touche PAS a l'architecture decrite dans ce depot (cle Run
#     'FortiEMS-Install' + logon-install.ps1) : les noms sont distincts et compares a
#     l'identique, pas par motif. Si vous partez de zero avec ce depot, ces deux scripts
#     ne vous servent a rien - ne les deployez pas.
#
# Contexte : le mecanisme d'auto-enrollment (tache planifiee 'FortiTray-EMS-Enrollment' ET/OU
# cle Run HKLM 'FortiEMS-Enroll' + wrapper FortiTray-Enroll.ps1) est a retirer de la flotte :
#   - FortiESNAC.exe a 'requestedExecutionLevel = requireAdministrator' dans son manifeste :
#     lance en contexte utilisateur il declenche SYSTEMATIQUEMENT un consentement UAC au logon.
#   - La cle Run lance powershell.exe SANS -WindowStyle Hidden -> console visible au logon.
#   - Le wrapper ne finalise jamais un status 0x1D ; il ne fait que reposer le probleme.
#
# Exit 1 = au moins un artefact present -> lancer le fix.
# Exit 0 = poste propre.
# Contexte : SYSTEM. Intune : "Run script in 64-bit PowerShell Host = Yes".
#
# /!\ PREREQUIS INTUNE : desassigner d'abord la Proactive Remediation 'enroll-task-*'
#     (detect/fix), sinon elle reposera la cle Run et le wrapper au cycle suivant.
# ============================================================

# --- CONSTANTE A ADAPTER ----------------------------------------------------
# Dossier ou l'ANCIEN dispositif deposait son wrapper. Ce n'est pas forcement le meme que le
# $BaseDir de l'architecture courante (package\) : mettez ici le chemin que vous utilisiez
# avant, sinon ce script ne trouvera jamais rien a nettoyer.
$LegacyBaseDir = 'C:\ProgramData\CHANGEME-OldStagingFolder'   # <-- A REMPLACER

$TaskNames = @('FortiTray-EMS-Enrollment', 'FortiEMS-Enrollment', 'FortiClient-EMS-Enrollment')
$RunKey    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
# Valeur EXACTE de l'ancienne cle. Surtout pas de comparaison par motif : 'FortiEMS-Install',
# la cle de l'architecture courante, serait emportee avec.
$RunValue  = 'FortiEMS-Enroll'
$Wrapper   = Join-Path $LegacyBaseDir 'FortiTray-Enroll.ps1'

$found = @()

# 1. Taches planifiees (nom exact connu + tout Forti*Enroll* par securite)
$tasks = @()
$tasks += Get-ScheduledTask -ErrorAction SilentlyContinue |
          Where-Object { $TaskNames -contains $_.TaskName -or
                         ($_.TaskName -match 'Forti' -and $_.TaskName -match 'Enroll') }
foreach ($t in ($tasks | Sort-Object TaskName -Unique)) {
    $found += "tache planifiee '$($t.TaskPath)$($t.TaskName)'"
}

# 2. Cle Run HKLM (lanceur reel sur les postes migres en septembre)
# NB: pas de -ErrorAction SilentlyContinue sur Get-Item : un acces refuse doit remonter,
# pas se transformer en faux negatif.
$rv = (Get-ItemProperty -Path $RunKey).$RunValue
if ($rv) { $found += "cle Run HKLM '$RunValue'" }

# 3. Wrapper sur disque
if (Test-Path $Wrapper) { $found += "wrapper '$Wrapper'" }

if ($found.Count -gt 0) {
    Write-Output ("NON CONFORME : " + ($found -join ' ; ') + " -> nettoyage requis (UAC + console au logon)")
    exit 1
}

Write-Output "Aucun lanceur d'enrollment FortiClient present - conforme"
exit 0
