# ============================================================
# FortiClient EMS - DETECTION Intune (ultra simple)
# Exit 0 = conforme (Intune ne fait rien) | Exit 1 = a (re)deposer
#
# Contexte : SYSTEM (l'app est en "Install behavior = System").
#
# CE QUE DETECTE CE SCRIPT : le DEPOT, pas l'installation.
#   install.ps1 ne fait que deposer l'EXE + logon-install.ps1 et armer la cle Run ;
#   l'installation reelle a lieu a l'ouverture de session suivante. Exiger ici FortiClient
#   installe, ou pire l'enrollment, ferait redeployer le package a chaque cycle Intune tant
#   que l'utilisateur ne s'est pas reconnecte - un faux "echec" permanent.
#
#   Un poste deja enrole est conforme d'office : rien a deposer.
#
# Suivi de l'enrollment : $BaseDir\FortiClientEMS-ultrasimple-logon.log et le marqueur
# $BaseDir\$StageName\enrolled.flag, pas cette detection.
# ============================================================

$ErrorActionPreference = 'SilentlyContinue'

# --- CONSTANTES A ADAPTER ---------------------------------------------------
# /!\ Doivent etre IDENTIQUES a celles d'install.ps1 et d'uninstall.ps1 : cette detection
#     cherche exactement ce chemin. Une divergence rend le poste eternellement non conforme
#     et fait redeployer le package a chaque cycle Intune.
$BaseDir   = 'C:\ProgramData\IntuneStaging'
$StageName = 'FortiEMS'

# Vue 64 bits explicite : l'hote PowerShell d'Intune peut etre 32 bits et ne verrait alors
# que WOW6432Node, ou la cle Fortinet est absente.
function Get-HKLM64 ($sub) {
    try { [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64').OpenSubKey($sub) } catch { $null }
}

# 1. Deja enrole -> conforme. Seule la presence de fgt_sn fait foi : des postes sains portent
# 0x1E / 0x12, et un test strict sur 'status -eq 2' avait casse des enrollments valides.
$k = Get-HKLM64 'SOFTWARE\Fortinet\FortiClient\FA_ESNAC'
if ($k -and $k.GetValue('fgt_sn')) {
    Write-Output ("Enrole (status 0x{0:X}) - conforme" -f [int]$k.GetValue('status'))
    exit 0
}

# 2. FortiClient installe MAIS sans code d'invitation = installation inexploitable.
# Le client ne s'enrolera jamais : il ne sait pas a quel EMS s'adresser. Ce cas se produit si
# l'EXE deploye n'est pas un package genere par la console EMS, ou si l'install a ete tronquee.
# On renvoie non conforme pour que install.ps1 redepose ET reamorce une tentative de logon.
$installed = $false
foreach ($root in @('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                    'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
    $u = Get-HKLM64 $root
    if ($u) {
        foreach ($s in $u.GetSubKeyNames()) {
            $sk = $u.OpenSubKey($s)
            if ($sk -and $sk.GetValue('DisplayName') -eq 'FortiClient') { $installed = $true; break }
        }
    }
    if ($installed) { break }
}

$inv = (Get-HKLM64 'SOFTWARE\Fortinet\FortiClient\FA_ESNAC\cloud_client').GetValue('invitation_code')

if ($installed -and -not $inv) {
    Write-Output 'NON CONFORME : FortiClient installe SANS code d''invitation - le client ne peut pas s''enroler'
    exit 1
}

# 3. Depot complet ? EXE + script de logon + cle Run HKLM.
$stage = Join-Path $BaseDir $StageName
$exe   = Get-ChildItem $stage -Filter 'forticlientsetup_*.exe' -File -ErrorAction SilentlyContinue |
         Select-Object -First 1
$logon = Test-Path (Join-Path $stage 'logon-install.ps1')
$run   = (Get-HKLM64 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run').GetValue('FortiEMS-Install')

if ($exe -and $logon -and $run) {
    $etat = if ($installed) { "FortiClient installe, invitation=$inv" } else { 'FortiClient pas encore installe' }
    Write-Output "Depot en place ($($exe.Name)) + cle Run HKLM - $etat - conforme"
    exit 0
}

$why = @()
if (-not $exe)   { $why += 'EXE absent' }
if (-not $logon) { $why += 'logon-install.ps1 absent' }
if (-not $run)   { $why += 'cle Run absente' }
Write-Output ("Depot incomplet : " + ($why -join ' ; '))
exit 1
