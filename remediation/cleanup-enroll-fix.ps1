# ============================================================
# PROACTIVE REMEDIATION - FIX : retire le mecanisme d'auto-enrollment FortiClient
# ------------------------------------------------------------
# /!\ SCRIPT DE MIGRATION - N'A DE SENS QUE SI VOUS AVEZ DEJA DEPLOYE L'ANCIEN DISPOSITIF.
#     Il ne vise QUE l'architecture precedente. Les artefacts de l'architecture decrite dans
#     ce depot (cle Run HKLM 'FortiEMS-Install', script logon-install.ps1, dossier de depot
#     $BaseDir\$StageName) sont intacts : les noms sont differents et compares a l'identique.
#     Si vous partez de zero avec ce depot, ne deployez pas ces deux scripts.
#
# Supprime, sur tout poste "infecte" :
#   1. la/les tache(s) planifiee(s) 'FortiTray-EMS-Enrollment' (et variantes Forti*Enroll*)
#   2. la cle Run HKLM 'FortiEMS-Enroll'  <- c'est ELLE qui ouvre la console PowerShell au logon
#   3. le wrapper $LegacyBaseDir\FortiTray-Enroll.ps1 (RENOMME en .bak, pas efface)
#   4. tout process wrapper en cours d'execution
#
# NE TOUCHE PAS :
#   - la cle Run 'FortiEMS-Install' ni logon-install.ps1 (architecture courante)
#   - FortiClient lui-meme (service FA_Scheduler, MSI, registre FA_ESNAC)
#   - la cle Run 'FortiTray' (GUI legitime, n'exige aucune elevation, aucun UAC)
#   - l'etat d'enrollment des postes deja enroles
#
# Pourquoi : FortiESNAC.exe porte 'requestedExecutionLevel = requireAdministrator'. Lance en
# contexte utilisateur (clef Run / tache Limited), il declenche un consentement UAC a CHAQUE
# logon, et ne finalise jamais un status 0x1D. Le retirer supprime la nuisance sans rien casser.
#
# Idempotent. Contexte : SYSTEM. Intune : "Run script in 64-bit PowerShell Host = Yes".
#
# /!\ PREREQUIS INTUNE : desassigner d'abord la Proactive Remediation 'enroll-task-*'
#     (detect/fix) et retirer le bloc correspondant de l'install.ps1 de votre ANCIENNE app
#     Win32, sinon la cle Run et le wrapper seront reposes au cycle suivant. (L'install.ps1
#     de ce depot ne pose rien de tout cela.)
# ============================================================

# --- Relance en 64 bits (sinon Get-ScheduledTask et /reg:64 voient une vue tronquee) ---
if (-not [Environment]::Is64BitProcess) {
    Start-Process "$env:WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -NoNewWindow -Wait
    exit $LASTEXITCODE
}

# --- CONSTANTE A ADAPTER ----------------------------------------------------
# Dossier ou l'ANCIEN dispositif deposait son wrapper, et ou ce script ecrit son journal.
# Doit etre la meme valeur que dans cleanup-enroll-detect.ps1.
$LegacyBaseDir = 'C:\ProgramData\IntuneStaging'

$LogFolder = $LegacyBaseDir
if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }
$LogFile = Join-Path $LogFolder 'cleanup-enroll.log'
function Write-Log { param([string]$m)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts - $m" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    Write-Output "$ts - $m"
}

$TaskNames = @('FortiTray-EMS-Enrollment', 'FortiEMS-Enrollment', 'FortiClient-EMS-Enrollment')
$RunKey    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
# Valeur EXACTE de l'ancienne cle. Surtout pas de comparaison par motif : 'FortiEMS-Install',
# la cle de l'architecture courante, serait emportee avec.
$RunValue  = 'FortiEMS-Enroll'
$Wrapper   = Join-Path $LegacyBaseDir 'FortiTray-Enroll.ps1'

Write-Log "=== CLEANUP lanceurs d'enrollment FortiClient sur $env:COMPUTERNAME ==="

# Etat d'enrollment, pour tracabilite uniquement (le nettoyage a lieu dans tous les cas :
# enrole -> le lanceur ne sert plus a rien ; non enrole -> il n'a jamais fonctionne).
$e = Get-ItemProperty 'HKLM:\SOFTWARE\Fortinet\FortiClient\FA_ESNAC' -ErrorAction SilentlyContinue
if ($e) {
    Write-Log ("Etat FortiClient : status 0x{0:X}, fgt_sn={1}" -f [int]$e.status,
               $(if ($e.fgt_sn) { $e.fgt_sn } else { 'VIDE (non enrole)' }))
} else {
    Write-Log "FortiClient non installe (cle FA_ESNAC absente) - nettoyage des residus quand meme"
}

$errors = 0

# --- 1. Tuer le wrapper s'il tourne (sinon le .ps1 est verrouille / il repose des -r) ---
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'FortiTray-Enroll\.ps1' } |
    ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
              Write-Log "Process wrapper PID $($_.ProcessId) arrete" }
        catch { Write-Log "WARN: impossible d'arreter le PID $($_.ProcessId) : $($_.Exception.Message)" }
    }

# --- 2. Taches planifiees ---
$tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
         Where-Object { $TaskNames -contains $_.TaskName -or
                        ($_.TaskName -match 'Forti' -and $_.TaskName -match 'Enroll') } |
         Sort-Object TaskName -Unique

if ($tasks) {
    foreach ($t in $tasks) {
        $full = "$($t.TaskPath)$($t.TaskName)"
        try {
            Stop-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Log "Tache supprimee : $full"
        } catch {
            $errors++
            Write-Log "ERREUR suppression tache $full : $($_.Exception.Message)"
        }
    }
} else {
    Write-Log "Aucune tache planifiee d'enrollment (deja propre)"
}

# --- 3. Cle Run HKLM 'FortiEMS-Enroll' ---
# Pas de SilentlyContinue : un acces refuse doit apparaitre dans le log, pas passer pour un succes.
if ((Get-ItemProperty -Path $RunKey -ErrorAction SilentlyContinue).$RunValue) {
    try {
        Remove-ItemProperty -Path $RunKey -Name $RunValue -Force -ErrorAction Stop
        Write-Log "Cle Run HKLM '$RunValue' supprimee (fin de la console PowerShell + UAC au logon)"
    } catch {
        $errors++
        Write-Log "ERREUR suppression cle Run '$RunValue' : $($_.Exception.Message)"
    }
} else {
    Write-Log "Cle Run '$RunValue' absente (deja propre)"
}

# Meme valeur eventuellement posee en HKCU sur des postes bricoles manuellement.
$hkcuRun = 'Registry::HKEY_USERS'
Get-ChildItem $hkcuRun -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$' } |
    ForEach-Object {
        $p = "Registry::$($_.Name)\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        if ((Get-ItemProperty -Path $p -ErrorAction SilentlyContinue).$RunValue) {
            try { Remove-ItemProperty -Path $p -Name $RunValue -Force -ErrorAction Stop
                  Write-Log "Cle Run '$RunValue' supprimee dans $($_.PSChildName)" }
            catch { $errors++; Write-Log "ERREUR cle Run HKU $($_.PSChildName) : $($_.Exception.Message)" }
        }
    }

# --- 4. Wrapper : renomme, pas efface (garde la trace pour un eventuel retour arriere) ---
if (Test-Path $Wrapper) {
    $bak = "$Wrapper.removed-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    try {
        Move-Item -LiteralPath $Wrapper -Destination $bak -Force -ErrorAction Stop
        Write-Log "Wrapper deplace vers $bak"
    } catch {
        $errors++
        Write-Log "ERREUR deplacement wrapper : $($_.Exception.Message)"
    }
} else {
    Write-Log "Wrapper absent (deja propre)"
}

# --- 5. FortiTray reste autostart : GUI legitime, aucun manifeste requireAdministrator ---
$FortiTray = 'C:\Program Files\Fortinet\FortiClient\FortiTray.exe'
if (Test-Path $FortiTray) {
    if (-not (Get-ItemProperty -Path $RunKey -ErrorAction SilentlyContinue).FortiTray) {
        try { New-ItemProperty -Path $RunKey -Name 'FortiTray' -PropertyType String `
                -Value "`"$FortiTray`"" -Force -ErrorAction Stop | Out-Null
              Write-Log "Cle Run 'FortiTray' (re)posee - GUI seulement, pas d'elevation" }
        catch { Write-Log "WARN: cle Run FortiTray non posee : $($_.Exception.Message)" }
    } else {
        Write-Log "Cle Run 'FortiTray' deja presente - conservee"
    }
}

if ($errors -gt 0) {
    Write-Log "=== FIN avec $errors erreur(s) ==="
    exit 1
}
Write-Log "=== FIN CLEANUP OK ==="
exit 0
