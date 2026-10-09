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

# Deja enrole -> ne rien deposer. Seule la presence de fgt_sn fait foi : des postes sains
# portent 0x1E / 0x12, et un test strict sur 'status -eq 2' avait casse des enrollments valides.
$e = Get-ItemProperty $Esnac -ErrorAction SilentlyContinue
if ($e.fgt_sn) { Log ("Deja enrole (status 0x{0:X}) -> rien a deposer" -f [int]$e.status); exit 0 }

# --- 1. Copier l'EXE de l'architecture du poste + le script de logon -------
$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$arch = if ((Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture -eq 12) { 'arm64' } else { 'x64' }

$exe = Get-ChildItem (Join-Path $dir $arch) -Filter *.exe -File -ErrorAction SilentlyContinue |
       Select-Object -First 1
if (-not $exe) { Log "ERREUR : aucun .exe dans $dir\$arch"; exit 1 }

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

# --- 1b. Installation existante sans code d'invitation -> reamorcer --------
# Un FortiClient installe mais depourvu d'invitation_code ne s'enrolera jamais : il ne sait pas
# a quel EMS s'adresser. Le marqueur 'une seule tentative' doit alors etre leve, sinon le script
# de logon se contenterait de constater l'echec a chaque session sans jamais reessayer.
$inv = (Get-ItemProperty "$Esnac\cloud_client" -ErrorAction SilentlyContinue).invitation_code
$fcInstalled = Test-Path 'C:\Program Files\Fortinet\FortiClient\FortiESNAC.exe'
$tried = Join-Path $Stage 'exe-launched.flag'
if ($fcInstalled -and -not $inv) {
    Remove-Item $tried -Force -ErrorAction SilentlyContinue
    Log 'FortiClient installe SANS code d''invitation -> marqueur de tentative leve, nouvel essai au prochain logon'
} elseif ($inv) {
    Log "Code d'invitation deja present sur le poste : $inv"
}

# --- 2. Droits d'ecriture pour les utilisateurs ---------------------------
# SID *S-1-5-32-545 et non "Utilisateurs"/"Users" : le nom litteral depend de la langue du
# poste. (OI)(CI)M = heritage fichiers + dossiers, droit Modifier.
$null = & "$env:WINDIR\System32\icacls.exe" $Stage /grant '*S-1-5-32-545:(OI)(CI)M' /T 2>&1
Log "Ecriture accordee aux utilisateurs sur $Stage"

# Le script de logon ajoute aussi ses lignes au journal commun, un cran au-dessus.
$null = & "$env:WINDIR\System32\icacls.exe" $LogDir /grant '*S-1-5-32-545:(OI)(CI)M' 2>&1

# --- 3. Armer le lancement au logon ---------------------------------------
# -WindowStyle Hidden ici, plus masquage de la console dans le script lui-meme : aucune
# fenetre a l'ouverture de session (l'ancienne cle Run 'FortiEMS-Enroll', remplacee par
# celle-ci, en affichait une - voir remediation\ pour son retrait).
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
exit 0
