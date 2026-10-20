# ============================================================
# FortiClient EMS - DETECTION de la boucle "essai expire" (lecture seule)
#
# Constat du 2026-10-12 sur PC-TEST-02 : un FortiClient qui a perdu son enregistrement EMS
# lance toutes les 60 s un 'License Expire Check' qui finit par
#   "FortiClient VPN trial period has expired" -> "Disconnect sslvpn or ipsec vpn"
#   -> "remove cloud client token and invitation code"
# Le VPN est coupe et toute invitation reinjectee est effacee dans la minute.
#
# Usage :
#   - sur un poste : .\Detect-FortiTrialExpired.ps1   (PowerShell admin)
#   - flotte : remediation Intune en DETECTION SEULE, contexte SYSTEM, 64 bits. La ligne de
#     sortie apparait dans "Pre-remediation detection output" (limite 2048 caracteres).
# Exit 1 = poste dans la boucle (remonte "with issues"), exit 0 = sain ou non concerne.
# Ne modifie RIEN.
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'
$Trace = 'C:\Program Files\Fortinet\FortiClient\logs\trace'

function Get-HKLM64 ($sub) { try { [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64').OpenSubKey($sub) } catch { $null } }
function Stamp ($m) { if ($m) { ($m.Line -split '\]')[0].TrimStart('[').Substring(0,16) } else { '-' } }

# Renvoie le code de sortie ; la ligne de constat part sur la sortie standard via Write-Host
# pour ne pas se melanger au code retourne.
function Main {
    $ver = $null
    foreach ($root in 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        $u = Get-HKLM64 $root
        foreach ($s in $u.GetSubKeyNames()) { $sk = $u.OpenSubKey($s); if ($sk.GetValue('DisplayName') -eq 'FortiClient') { $ver = $sk.GetValue('DisplayVersion') } }
    }
    if (-not $ver) { Write-Host "$env:COMPUTERNAME | FortiClient (EMS) absent - non concerne"; return 0 }

    $k   = Get-HKLM64 'SOFTWARE\Fortinet\FortiClient\FA_ESNAC'
    $inv = (Get-HKLM64 'SOFTWARE\Fortinet\FortiClient\FA_ESNAC\cloud_client').GetValue('invitation_code')
    $st  = '0x{0:X}' -f [int]$k.GetValue('status')
    $sn  = [bool]$k.GetValue('fgt_sn')
    $invShort = if ($inv) { $inv.Substring(0, [Math]::Min(6, $inv.Length)) + '...' } else { 'aucune' }

    # Les traces ESNAC tournent : on parcourt tous les fichiers presents (hors *_error).
    $expired = @(); $wipes = @()
    Get-ChildItem $Trace -Filter 'FortiESNAC*.log' -File | Where-Object Name -notmatch '_error' | Sort-Object LastWriteTime | ForEach-Object {
        $expired += Select-String -Path $_.FullName -Pattern 'trial period has expired' -SimpleMatch
        $wipes   += Select-String -Path $_.FullName -Pattern 'remove cloud client token and invitation code' -SimpleMatch
    }

    # Boucle ACTIVE = les deux traces datent de moins d'une heure (meme regle que detection.ps1).
    # Un journal peut garder l'historique d'une boucle deja reparee par reinstallation.
    $since  = (Get-Date).AddMinutes(-60)
    $isRecent = { param($m) try { [datetime]::ParseExact($m.Line.Substring(1, 19), 'yyyy-MM-dd HH:mm:ss', $null) -gt $since } catch { $false } }
    $loop = $expired.Count -gt 0 -and $wipes.Count -gt 0 -and (& $isRecent $expired[-1]) -and (& $isRecent $wipes[-1])
    Write-Host ("{0} | FCT {1} | status {2} | fgt_sn={3} | invitation={4} | essai expire: {5} occ. (1re {6}, der. {7}) | effacement invitation: {8} occ. (1re {9}) | {10}" -f `
        $env:COMPUTERNAME, $ver, $st, $sn, $invShort, $expired.Count, (Stamp $expired[0]), (Stamp $expired[-1]), $wipes.Count, (Stamp $wipes[0]),
        $(if ($loop) { 'BOUCLE ESSAI EXPIRE' } elseif ($sn) { $(if ($expired.Count) { 'enregistre (boucle passee, reparee)' } else { 'enregistre' }) } else { 'non enregistre, pas de boucle active' }))
    if ($loop) { return 1 } else { return 0 }
}

$code = Main
# Lance comme fichier (Intune, .\script.ps1) : 'exit' transmet le code a l'appelant.
# Colle dans une console : $PSCommandPath est vide et 'exit' fermerait la fenetre -> on s'abstient.
if ($PSCommandPath) { exit $code } else { "Code de sortie : $code" }
