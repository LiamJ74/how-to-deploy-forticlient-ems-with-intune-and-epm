# ============================================================
# FortiClient EMS - UNINSTALL (ultra simple)
# Contexte Intune : Win32 app, "Install behavior = USER", 64 bits.
#
# Desinstalle FortiClient via son code produit MSI, puis supprime l'etat d'enrollment
# residuel pour qu'une reinstallation reparte de zero.
#
# /!\ CE SCRIPT TOURNE SANS ELEVATION. msiexec /x exige l'elevation : elle doit venir d'une
#     regle EPM couvrant msiexec.exe, OU la desinstallation doit etre lancee en contexte
#     SYSTEM. Sans elevation, msiexec rend 1223 et le script le signale explicitement.
#
# POURQUOI NETTOYER LE REGISTRE APRES COUP :
#     Le MSI ne supprime pas HKLM\SOFTWARE\Fortinet\FortiClient\FA_ESNAC. Sans ce nettoyage,
#     un poste peut rester sur une transaction d'enrollment en cours (status 0x1D) d'une
#     installation a la suivante. Le pilote anti-tamper FortiShield interdit l'ecriture sur
#     cette cle tant qu'il est charge ; il se decharge avec la desinstallation (verifie le
#     2026-09-21 : plus aucun pilote FortiShield charge apres msiexec /x, sans redemarrage).
#     Si malgre tout il reste resident, le nettoyage est simplement reporte -> 3010.
# ============================================================

$ErrorActionPreference = 'Continue'

# --- Relance en 64 bits -----------------------------------------------------
# Intune execute la ligne de commande dans l'hote PowerShell 32 BITS : les acces a
# HKLM:\SOFTWARE\... y sont rediriges vers WOW6432Node, et la cle Run 64 bits resterait en
# place. SysNative n'existe que depuis un process 32 bits, d'ou le test prealable.
if (-not [Environment]::Is64BitProcess) {
    $p = Start-Process "$env:WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
            -NoNewWindow -Wait -PassThru
    exit $p.ExitCode
}

$LogDir = 'C:\ProgramData\Autopilot-Setup'
try {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    [IO.File]::AppendAllText((Join-Path $LogDir '.wtest'), '')
    Remove-Item (Join-Path $LogDir '.wtest') -Force -ErrorAction SilentlyContinue
} catch {
    $LogDir = Join-Path $env:LOCALAPPDATA 'Autopilot-Setup'
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$LogFile = Join-Path $LogDir 'FortiClientEMS-ultrasimple-uninstall.log'
function Log ($m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $m" | Out-File $LogFile -Append -Encoding UTF8
    Write-Host $m
}

Log "=== Desinstallation FortiClient EMS (ultra simple) - $env:USERNAME sur $env:COMPUTERNAME ==="

$id       = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
Log "Identite=$($id.Name)  Eleve=$elevated"

# --- 0. Desarmer le lancement au logon et retirer le depot ----------------
# Fait en premier, et c'est ici seulement que la cle Run peut disparaitre : elle est en HKLM,
# donc hors de portee du script de logon qui tourne sans elevation.
# Les deux vues : la 64 bits (posee par la version courante) et WOW6432Node (residu des
# versions qui tournaient en 32 bits). Windows execute les entrees Run des deux ruches.
foreach ($rk in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
    if ((Get-ItemProperty $rk -ErrorAction SilentlyContinue).'FortiEMS-Install') {
        Remove-ItemProperty -Path $rk -Name 'FortiEMS-Install' -Force -ErrorAction SilentlyContinue
        if ((Get-ItemProperty $rk -ErrorAction SilentlyContinue).'FortiEMS-Install') {
            Log "ERREUR : cle Run non retiree de $rk"
        } else {
            Log "Cle Run 'FortiEMS-Install' retiree de $rk"
        }
    }
}
$stage = 'C:\ProgramData\Autopilot-Setup\FortiEMS'
if (Test-Path $stage) {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $stage) { Log "AVERTISSEMENT : $stage non supprime" } else { Log "Depot supprime : $stage" }
}

# --- 1. Code produit ------------------------------------------------------
# Nom EXACT 'FortiClient' : ne jamais attraper 'FortiClient VPN', produit distinct.
$app = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                        -ErrorAction SilentlyContinue |
       Where-Object { $_.DisplayName -eq 'FortiClient' -and $_.PSChildName -match '^\{.+\}$' } |
       Select-Object -First 1

$rebootNeeded = $false

if ($app) {
    $code   = $app.PSChildName
    $msiLog = Join-Path $LogDir "FortiClientEMS-ultrasimple-msi-$code.log"
    Log "Desinstallation de '$($app.DisplayName)' v$($app.DisplayVersion) ($code)"
    $p = Start-Process "$env:WINDIR\System32\msiexec.exe" `
            -ArgumentList @('/x', $code, '/qn', 'REBOOT=ReallySuppress', '/l*v', "`"$msiLog`"") `
            -Wait -PassThru
    Log "msiexec ExitCode=$($p.ExitCode) (log : $msiLog)"

    if ($p.ExitCode -eq 1223) {
        Log 'ECHEC : elevation refusee (1223). msiexec doit etre couvert par une regle EPM, ou lance en SYSTEM.'
        exit 1223
    }
    # 0 = OK, 3010/1641 = OK redemarrage requis, 1605 = produit deja absent
    if ($p.ExitCode -notin 0, 3010, 1641, 1605) { Log "ECHEC desinstallation ($($p.ExitCode))"; exit $p.ExitCode }
    if ($p.ExitCode -in 3010, 1641) { $rebootNeeded = $true }
} else {
    Log 'FortiClient absent du registre - rien a desinstaller'
}

# --- 2. Etat d'enrollment residuel ---------------------------------------
$shield = Get-CimInstance Win32_SystemDriver -Filter "Name='FortiShield'" -ErrorAction SilentlyContinue
if ($shield -and $shield.State -eq 'Running') {
    Log 'FortiShield encore charge -> nettoyage de FA_ESNAC impossible maintenant, reporte au redemarrage'
    $rebootNeeded = $true
} else {
    foreach ($k in @('HKLM\SOFTWARE\Fortinet\FortiClient',
                     'HKLM\SOFTWARE\WOW6432Node\Fortinet\FortiClient')) {
        $ps = 'Registry::HKEY_LOCAL_MACHINE\' + $k.Substring(5)
        if (Test-Path $ps) {
            $out = & "$env:WINDIR\System32\reg.exe" delete $k /f /reg:64 2>&1 | Out-String
            # On reverifie l'absence : reg.exe peut rendre 0 alors que l'ecriture a ete refusee.
            if (-not (Test-Path $ps)) { Log "Supprime : $k" }
            else { Log "AVERTISSEMENT : $k toujours present ($($out.Trim()))" }
        }
    }
}

if ($rebootNeeded) { Log '=== FIN - 3010 rendu a Intune (redemarrage) ==='; exit 3010 }
Log '=== FIN ==='
exit 0
