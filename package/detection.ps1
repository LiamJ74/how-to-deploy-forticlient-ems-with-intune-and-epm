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
# Suivi de l'enrollment : $BaseDir\FortiClientEMS-ultrasimple-logon.log et les marqueurs
# $BaseDir\$StageName\enrolled-<version>.flag, pas cette detection.
# ============================================================

$ErrorActionPreference = 'SilentlyContinue'

# --- CONSTANTES A ADAPTER ---------------------------------------------------
# /!\ Doivent etre IDENTIQUES a celles d'install.ps1 et d'uninstall.ps1 : cette detection
#     cherche exactement ce chemin. Une divergence rend le poste eternellement non conforme
#     et fait redeployer le package a chaque cycle Intune.
$BaseDir   = 'C:\ProgramData\IntuneStaging'
$StageName = 'FortiEMS'
$stage     = Join-Path $BaseDir $StageName

# --- Version cible --------------------------------------------------------
# /!\ Un script de detection Intune s'execute SANS acces au contenu du package : il ne peut
# donc pas lire la version de l'EXE embarque. La valeur ci-dessous est INJECTEE AUTOMATIQUEMENT
# par Publish-Win32App.ps1 au moment de l'upload, a partir de l'EXE reellement present dans le
# package. Elle n'est donc jamais a maintenir a la main : repackager avec un 7.4.9 suffit.
#
# Ne pas interroger Internet ici : une detection doit etre rapide, deterministe et fonctionner
# hors ligne, et un poste ne doit jamais courir apres une version qui n'a pas ete packagee.
#
# Si le jeton n'a pas ete remplace (publication manuelle depuis le portail), on retombe sur le
# comportement d'origine : on verifie le depot sans rien exiger de la version.
$TargetVersion = $null
$raw = '__TARGET_VERSION__'
if ($raw -notmatch '^_{2}') { try { $TargetVersion = [version]$raw } catch { } }

# Vue 64 bits explicite : l'hote PowerShell d'Intune peut etre 32 bits et ne verrait alors
# que WOW6432Node, ou la cle Fortinet est absente.
function Get-HKLM64 ($sub) {
    try { [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64').OpenSubKey($sub) } catch { $null }
}

# Version de FortiClient installee, ou $null.
function Get-InstalledVersion {
    foreach ($root in @('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        $u = Get-HKLM64 $root
        if ($u) {
            foreach ($s in $u.GetSubKeyNames()) {
                $sk = $u.OpenSubKey($s)
                if ($sk -and $sk.GetValue('DisplayName') -eq 'FortiClient') {
                    try { return [version]$sk.GetValue('DisplayVersion') } catch { return $null }
                }
            }
        }
    }
    return $null
}
$curVersion = Get-InstalledVersion

# 0. Boucle "essai expire" (constat du 2026-10-12) : le client a perdu son enregistrement,
# coupe le VPN et efface toute invitation chaque minute. Seule une reinstallation fraiche en
# sort : install.ps1 s'en charge, UNE fois par version. Teste AVANT l'etape 1, car un poste
# peut garder fgt_sn tout en etant dans la boucle.
# Meme logique que Test-TrialLoop d'install.ps1 : traces de moins d'une heure uniquement, pour
# ne jamais reagir aux lignes anciennes restees dans le journal apres une reinstallation.
function Test-TrialLoop {
    $log = Get-ChildItem 'C:\Program Files\Fortinet\FortiClient\logs\trace' -Filter 'FortiESNAC*.log' -File |
           Where-Object Name -notmatch '_error' | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $log) { return $false }
    $tail  = Get-Content $log.FullName -Tail 5000
    $since = (Get-Date).AddMinutes(-60)
    foreach ($pattern in 'trial period has expired', 'remove cloud client token and invitation code') {
        $hit = $tail | Where-Object { $_ -like "*$pattern*" } | Select-Object -Last 1
        if (-not $hit) { return $false }
        try { if ([datetime]::ParseExact($hit.Substring(1, 19), 'yyyy-MM-dd HH:mm:ss', $null) -le $since) { return $false } }
        catch { return $false }
    }
    return $true
}

# Nettoyage reporte apres une desinstallation de reprise : install.ps1 doit repasser.
if (Test-Path (Join-Path $stage 'cleanup-pending.flag')) {
    Write-Output 'NON CONFORME : nettoyage FA_ESNAC en attente apres desinstallation de reprise'
    exit 1
}
if ($curVersion -and (Test-TrialLoop)) {
    if (Test-Path (Join-Path $BaseDir "FortiEMS-reinstall-$TargetVersion.flag")) {
        # Reinstallation deja tentee pour cette version : conforme cote Intune pour ne pas relancer
        # install.ps1 (ni notifier l'utilisateur) a chaque cycle. Le poste releve d'une
        # intervention manuelle ; Detect-FortiTrialExpired.ps1 le retrouve.
        Write-Output "Boucle 'essai expire' active, reinstallation deja tentee pour $TargetVersion - intervention manuelle"
        exit 0
    }
    Write-Output "NON CONFORME : boucle 'essai expire' active (FortiClient $curVersion) - reinstallation requise"
    exit 1
}

# 1. Enrole ET a la version cible -> conforme, etat final atteint.
# /!\ L'enrollment seul ne suffit PAS : un poste enrole sur une version ancienne doit etre mis
# a niveau, sinon il reste sur le client qui decroche (passage en 'Not Registered' cote EMS).
# Seule la presence de fgt_sn fait foi pour l'enrollment : des postes sains portent 0x1E / 0x12,
# et un test strict sur 'status -eq 2' avait casse des enrollments valides.
$k = Get-HKLM64 'SOFTWARE\Fortinet\FortiClient\FA_ESNAC'
if ($k -and $k.GetValue('fgt_sn')) {
    if (-not $TargetVersion -or ($curVersion -and $curVersion -ge $TargetVersion)) {
        Write-Output ("Enrole (status 0x{0:X}, version {1}) - conforme" -f
                      [int]$k.GetValue('status'), $(if ($curVersion) { $curVersion } else { 'inconnue' }))
        exit 0
    }
    # /!\ SURTOUT PAS de 'exit 1' ici. Conclure a la non-conformite sur le seul critere de
    # version court-circuite le controle du depot plus bas : le poste resterait "not detected"
    # meme une fois install.ps1 passe et le depot en place, puisque la mise a niveau elle-meme
    # n'a lieu qu'a la PROCHAINE ouverture de session. Intune relancerait alors l'installation
    # a chaque cycle en signalant un echec permanent.
    # On se contente donc de tracer, et on laisse la suite decider : depot correct = conforme,
    # la mise a niveau suivra au logon.
    Write-Output ("Enrole mais version {0} < cible {1} - mise a niveau attendue au prochain logon ; " -f
                  $(if ($curVersion) { $curVersion } else { 'inconnue' }), $TargetVersion)
}

# 2. FortiClient installe MAIS sans code d'invitation = installation inexploitable.
# Le client ne s'enrolera jamais : il ne sait pas a quel EMS s'adresser. Ce cas se produit si
# l'EXE deploye n'est pas un package genere par la console EMS, ou si l'install a ete tronquee.
# On renvoie non conforme pour que install.ps1 redepose ET reamorce une tentative de logon.
$installed = [bool]$curVersion
$inv = (Get-HKLM64 'SOFTWARE\Fortinet\FortiClient\FA_ESNAC\cloud_client').GetValue('invitation_code')

if ($installed -and -not $inv) {
    Write-Output 'NON CONFORME : FortiClient installe SANS code d''invitation - le client ne peut pas s''enroler'
    exit 1
}

# 3. Depot complet ET a la bonne version ? EXE + script de logon + cle Run HKLM.
# La mise a niveau elle-meme se fera a la prochaine ouverture de session ; exiger ici que
# FortiClient soit deja a la cible ferait echouer la detection a chaque cycle tant que
# l'utilisateur ne s'est pas reconnecte. On valide donc le DEPOT - mais un depot d'une version
# perimee ne compte pas, sinon un nouveau package ne serait jamais redistribue.
$exe   = Get-ChildItem $stage -Filter 'forticlientsetup_*.exe' -File -ErrorAction SilentlyContinue |
         Select-Object -First 1
$logon = Test-Path (Join-Path $stage 'logon-install.ps1')
$run   = (Get-HKLM64 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run').GetValue('FortiEMS-Install')

$stagedVersion = $null
if ($exe) { try { $stagedVersion = [version]$exe.VersionInfo.FileVersion } catch { } }
$stageUpToDate = (-not $TargetVersion) -or ($stagedVersion -and $stagedVersion -ge $TargetVersion)

if ($exe -and $logon -and $run -and $stageUpToDate) {
    $etat = if ($installed) { "FortiClient $curVersion, invitation=$inv" } else { 'FortiClient pas encore installe' }
    Write-Output "Depot en place ($($exe.Name)) + cle Run HKLM - $etat - conforme"
    exit 0
}

$why = @()
if (-not $exe)            { $why += 'EXE absent' }
if (-not $logon)          { $why += 'logon-install.ps1 absent' }
if (-not $run)            { $why += 'cle Run absente' }
if ($exe -and -not $stageUpToDate) { $why += "EXE depose en $stagedVersion < cible $TargetVersion" }
Write-Output ("Depot incomplet : " + ($why -join ' ; '))
exit 1
