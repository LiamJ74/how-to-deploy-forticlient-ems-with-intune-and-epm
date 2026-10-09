<#
.SYNOPSIS
    Prepare (et cree, en option) la regle Intune EPM qui eleve l'installeur FortiClient EMS.

.DESCRIPTION
    Le package (dossier package\) se deploie en Win32 app avec
    "Install behavior = System" : install.ps1 se contente de DEPOSER l'installeur et
    logon-install.ps1, puis de poser la cle Run HKLM 'FortiEMS-Install'. C'est cette cle Run
    qui lance l'installeur dans la session interactive de l'utilisateur, ce qui est
    indispensable a l'enrollment EMS (le jeton Entra / PRT n'existe que la ; un installeur
    execute en SYSTEM tourne en session 0 et reste bloque en status 0x1D).

    L'installeur ainsi lance n'est pas eleve et exige pourtant l'elevation. Elle est fournie
    par une regle EPM ciblant UNIQUEMENT forticlientsetup_*.exe.

    /!\ Ne JAMAIS creer de regle EPM ciblant FortiESNAC.exe ni FortiTray.exe : EPM n'eleve pas
        "en tant qu'utilisateur courant", il substitue un compte virtuel
        MEM\<NETBIOS>_<user>_$ (autorite de SID S-1-5-110) depourvu de cache TokenBroker, donc
        sans WebAccount ni PRT Entra -> 0xCAA100D8 -> "azuretoken is invalid" -> enrollment
        impossible. C'est l'incident du 2026-08-27 (dernier enrollment reussi a 11:02:36 ;
        premiere interception de FortiESNAC.exe par EPM a 13:52 ; plus rien ensuite).

    Les packages generes par la console EMS sont NON SIGNES : l'injection du code d'invitation
    casse la signature Authenticode. La regle ne peut donc PAS reposer sur le certificat
    editeur - uniquement sur nom de fichier + SHA256. Consequence : chaque package regenere
    depuis EMS produit un nouveau hash et impose une mise a jour de la regle, faute de quoi
    l'elevation cesse et l'installation echoue en 1223.

.PARAMETER PackagePath
    Dossier du package contenant les sous-dossiers x64\ et arm64\.

.PARAMETER CreatePolicy
    Cree reellement la strategie EPM dans Intune via Microsoft Graph. Sans ce commutateur, le
    script se contente de calculer les valeurs et de les afficher (mode hors-ligne, sans
    aucune connexion ni modification).

.PARAMETER PolicyName
    Nom de la strategie EPM creee.

.EXAMPLE
    .\New-EpmElevationRule.ps1
    Calcule les hashes et affiche les valeurs exactes a saisir dans le portail Intune.

.EXAMPLE
    .\New-EpmElevationRule.ps1 -CreatePolicy
    Se connecte a Graph, decouvre les identifiants de parametres EPM du tenant, puis cree
    la strategie.

.NOTES
    Le mode -CreatePolicy DECOUVRE les settingDefinitionId depuis Graph plutot que de les
    coder en dur : le catalogue de parametres EPM evolue et des identifiants figes se
    perimeraient silencieusement.
#>

[CmdletBinding()]
param(
    [string] $PackagePath = (Join-Path $PSScriptRoot '..\package'),
    [switch] $CreatePolicy,
    [string] $PolicyName  = 'EPM - FortiClient EMS installer elevation'
)

$ErrorActionPreference = 'Stop'

# Le templateId du modele "Elevation rules policy" n'est PAS code en dur : il varie selon le
# tenant et la version du service. Un identifiant fige provoque un POST 400 ResourceNotFound.
# Il est decouvert depuis Graph, comme les definitions de parametres.
$EpmRulesTemplateId = $null

function Write-Section ($t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# 1. Inventaire des binaires et calcul des empreintes
# ---------------------------------------------------------------------------
Write-Section 'Binaires du package'

if (-not (Test-Path $PackagePath)) { throw "Dossier de package introuvable : $PackagePath" }

$targets = @()
foreach ($arch in 'x64', 'arm64') {
    $dir = Join-Path $PackagePath $arch
    if (-not (Test-Path $dir)) { Write-Warning "Sous-dossier absent : $dir"; continue }

    $exe = Get-ChildItem $dir -Filter *.exe -File | Select-Object -First 1
    if (-not $exe) { Write-Warning "Aucun .exe dans $dir"; continue }

    $sig = Get-AuthenticodeSignature $exe.FullName
    $targets += [pscustomobject]@{
        Arch      = $arch
        Name      = $exe.Name
        Version   = $exe.VersionInfo.FileVersion
        Sha256    = (Get-FileHash $exe.FullName -Algorithm SHA256).Hash
        Signature = $sig.Status
        SizeMB    = [math]::Round($exe.Length / 1MB, 1)
    }
}

if (-not $targets) { throw "Aucun installeur trouve sous $PackagePath" }
$targets | Format-Table Arch, Name, Version, SizeMB, Signature, Sha256 -AutoSize | Out-String -Width 200 | Write-Host

if ($targets.Signature -contains 'Valid') {
    Write-Host "Note : un binaire est signe - une regle par certificat editeur serait possible." -ForegroundColor Yellow
} else {
    Write-Host "Binaires NON SIGNES (attendu pour un package EMS) -> regle par SHA256 obligatoire." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 2. Valeurs a saisir dans le portail (toujours affichees)
# ---------------------------------------------------------------------------
Write-Section 'Valeurs de la regle EPM'

foreach ($t in $targets) {
    Write-Host ""
    Write-Host "  Regle : FortiClient EMS installer ($($t.Arch))" -ForegroundColor Green
    Write-Host "    Rule type              : File"
    Write-Host "    File name              : $($t.Name)"
    Write-Host "    File hash (SHA256)     : $($t.Sha256)"
    Write-Host "    Elevation type         : Automatic"
    Write-Host "    Child process behavior : Allow all child processes to run elevated"
    Write-Host "    Signature source       : (aucune - binaire non signe)"
}
Write-Host ""
Write-Host "  'Allow all child processes' est requis : l'EXE extrait puis appelle msiexec ;" -ForegroundColor DarkGray
Write-Host "  sans heritage, le MSI s'executerait non eleve et l'installation echouerait." -ForegroundColor DarkGray

if (-not $CreatePolicy) {
    Write-Section 'Mode hors-ligne'
    Write-Host "Aucune connexion, aucune modification. Relancer avec -CreatePolicy pour creer la strategie."
    Write-Host "Portail : Intune > Endpoint security > Endpoint Privilege Management > Policies"
    return
}

# ---------------------------------------------------------------------------
# 3. Connexion Graph
# ---------------------------------------------------------------------------
Write-Section 'Connexion a Microsoft Graph'

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw "Module manquant. Installer avec : Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Connect-MgGraph -Scopes 'DeviceManagementConfiguration.ReadWrite.All' -NoWelcome
Write-Host "Connecte : $((Get-MgContext).Account)"

# ---------------------------------------------------------------------------
# 4. Decouverte des identifiants de parametres EPM DANS LE TENANT
#    (plutot que de les coder en dur : le catalogue evolue et des ids figes
#     se perimeraient sans que rien ne le signale)
# ---------------------------------------------------------------------------
Write-Section 'Decouverte du modele EPM'

# Modeles disponibles pour la technologie EPM. On retient le modele de REGLES d'elevation
# (et non le modele de PARAMETRES d'elevation, qui active EPM sur le poste), dans sa version
# active la plus recente.
$tplUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicyTemplates" +
          "?`$filter=technologies has 'endpointPrivilegeManagement'"
$tpls = @()
do {
    $page = Invoke-MgGraphRequest -Method GET -Uri $tplUri
    $tpls += $page.value
    $tplUri = $page.'@odata.nextLink'
} while ($tplUri)

$tpls | ForEach-Object {
    Write-Host ("  [{0}] {1}  (v{2}, {3})" -f $_.id, $_.displayName, $_.version, $_.lifecycleState)
}

$tpl = $tpls |
       Where-Object { $_.displayName -match 'elevation\s*rules' -and $_.lifecycleState -eq 'active' } |
       Sort-Object version -Descending | Select-Object -First 1
if (-not $tpl) {
    $tpl = $tpls | Where-Object { $_.displayName -match 'elevation\s*rules' } |
           Sort-Object version -Descending | Select-Object -First 1
}
if (-not $tpl) { throw "Modele 'Elevation rules policy' introuvable dans le tenant (voir la liste ci-dessus)." }

$EpmRulesTemplateId = $tpl.id
Write-Host ""
Write-Host "Modele retenu : $($tpl.displayName) -> $EpmRulesTemplateId" -ForegroundColor Green

Write-Section 'Decouverte des parametres EPM'

$uri  = "https://graph.microsoft.com/beta/deviceManagement/configurationSettings" +
        "?`$filter=applicability/technologies has 'endpointPrivilegeManagement'"
$defs = @()
do {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri
    $defs += $page.value
    $uri   = $page.'@odata.nextLink'
} while ($uri)

Write-Host "$($defs.Count) definitions de parametres EPM recuperees."

# La racine est le groupe de regles lui-meme, dont l'id se termine par le jeton de nom de
# regle : ..._privilegemanagement_elevationrules_{elevationrulename}
$ruleRoot = $defs | Where-Object { $_.id -match '_elevationrules_\{elevationrulename\}$' } | Select-Object -First 1
if (-not $ruleRoot) {
    Write-Warning "Racine des regles d'elevation introuvable dans le catalogue du tenant."
    Write-Host "Identifiants disponibles contenant 'elevation' :" -ForegroundColor Yellow
    $defs | Where-Object { $_.id -match 'elevation' } | Select-Object -ExpandProperty id -Unique |
        Sort-Object | ForEach-Object { "   $_" }
    throw "Impossible de construire la regle automatiquement. Utiliser le mode hors-ligne et le portail."
}

Write-Host "Racine des regles : $($ruleRoot.id)"

# Les enfants portent des suffixes stables. On les resout depuis le catalogue pour ne rien
# supposer de leur nommage exact. $Optional : certains parametres peuvent etre absents selon
# la version du catalogue ; on les omet alors du payload plutot que d'echouer.
function Resolve-Child ($suffix, [switch]$Optional) {
    $hit = $defs | Where-Object { $_.id -eq "$($ruleRoot.id)_$suffix" } | Select-Object -First 1
    if (-not $hit) {
        if ($Optional) { return $null }
        throw "Parametre '$suffix' introuvable dans le catalogue EPM du tenant."
    }
    return $hit.id
}

$idRuleName  = Resolve-Child 'name'
$idRuleDesc  = Resolve-Child 'description' -Optional
$idFileName  = Resolve-Child 'filename'
$idHash      = Resolve-Child 'filehash'
$idRuleType  = Resolve-Child 'ruletype'
$idChildProc = Resolve-Child 'childprocessbehavior'
$idSigSource = Resolve-Child 'signaturesource' -Optional
$idAppliesTo = Resolve-Child 'appliesto'       -Optional

foreach ($p in @(@{n='name';v=$idRuleName}, @{n='description';v=$idRuleDesc},
                 @{n='filename';v=$idFileName}, @{n='filehash';v=$idHash},
                 @{n='ruletype';v=$idRuleType}, @{n='childprocessbehavior';v=$idChildProc},
                 @{n='signaturesource';v=$idSigSource}, @{n='appliesto';v=$idAppliesTo})) {
    Write-Host ("  {0,-22}: {1}" -f $p.n, $(if ($p.v) { $p.v } else { '(absent du catalogue)' }))
}

# ---------------------------------------------------------------------------
# 4b. Options des parametres de choix : AFFICHEES puis resolues.
#     Les valeurs ne sont pas devinees - on lit ce que le tenant expose, et si la
#     correspondance echoue le script montre les options reelles avant de s'arreter.
# ---------------------------------------------------------------------------
function Show-Options ($settingId) {
    if (-not $settingId) { return }
    $s = $defs | Where-Object { $_.id -eq $settingId } | Select-Object -First 1
    Write-Host ""
    Write-Host "  Options de $($settingId.Split('_')[-1]) :" -ForegroundColor DarkGray
    foreach ($o in $s.options) {
        Write-Host ("     [{0}] {1}" -f $o.itemId, $o.displayName) -ForegroundColor DarkGray
    }
}
function Resolve-Option ($settingId, $pattern) {
    $s = $defs | Where-Object { $_.id -eq $settingId } | Select-Object -First 1
    $o = $s.options | Where-Object {
            $_.displayName -match $pattern -or $_.name -match $pattern -or $_.itemId -match $pattern
         } | Select-Object -First 1
    if (-not $o) {
        throw ("Option '$pattern' introuvable pour $settingId. Options reelles : " +
               (($s.options | ForEach-Object { "$($_.displayName) [$($_.itemId)]" }) -join ' | '))
    }
    return $o.itemId
}

Show-Options $idRuleType
Show-Options $idChildProc
Show-Options $idSigSource
Show-Options $idAppliesTo

# Variante tolerante : avertit et rend $null au lieu d'interrompre, pour les parametres dont
# l'absence est acceptable.
function Try-ResolveOption ($settingId, $pattern) {
    if (-not $settingId) { return $null }
    try { return Resolve-Option $settingId $pattern }
    catch { Write-Warning $_.Exception.Message; return $null }
}

$optAutomatic = Resolve-Option $idRuleType  'automatic'
$optChildAll  = Resolve-Option $idChildProc 'all|allow'

# signaturesource ne propose QUE des options exigeant un certificat ("Use a certificate file
# in reusable settings" / "Upload a certificate file") : il n'existe aucune valeur "non
# requis". Ce parametre ne s'applique donc qu'a une validation par certificat. Les packages
# EMS etant NON SIGNES, on l'omet entierement et la regle repose sur le SHA256 seul.
$signedTargets = @($targets | Where-Object { $_.Signature -eq 'Valid' })
$optSigSource  = $null
if ($idSigSource -and $signedTargets.Count -eq $targets.Count -and $targets.Count -gt 0) {
    $optSigSource = Try-ResolveOption $idSigSource 'reusable|upload'
} else {
    Write-Host "  signaturesource omis : binaires non signes, validation par SHA256 uniquement." -ForegroundColor DarkGray
}

$optAppliesTo = Try-ResolveOption $idAppliesTo 'all\s*users|tous'

Write-Host ""
Write-Host "  -> Elevation type 'Automatic'  = $optAutomatic"
Write-Host "  -> Child process 'Allow all'   = $optChildAll"
if ($optSigSource) { Write-Host "  -> Signature source            = $optSigSource" }
if ($optAppliesTo) { Write-Host "  -> Applies to                  = $optAppliesTo" }

# ---------------------------------------------------------------------------
# 4c. References de modele (settingTemplates)
#     Une strategie creee depuis un modele exige que CHAQUE instance de parametre porte son
#     settingInstanceTemplateId, et chaque valeur son settingValueTemplateId. Sans eux :
#     400 "TemplateReference not found for SettingInstance ...".
#     Ces GUID sont propres au modele : on les lit, on ne les invente pas.
# ---------------------------------------------------------------------------
Write-Section 'References de modele'

$stUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicyTemplates('$EpmRulesTemplateId')/settingTemplates"
$sts = @()
do {
    $page = Invoke-MgGraphRequest -Method GET -Uri $stUri
    $sts += $page.value
    $stUri = $page.'@odata.nextLink'
} while ($stUri)

$instTpl = @{}   # settingDefinitionId -> settingInstanceTemplateId
$valTpl  = @{}   # settingDefinitionId -> settingValueTemplateId

function Read-InstanceTemplate ($t) {
    if (-not $t) { return }
    $def = $t.settingDefinitionId
    if ($def -and $t.settingInstanceTemplateId) { $instTpl[$def] = $t.settingInstanceTemplateId }

    foreach ($k in 'simpleSettingValueTemplate', 'choiceSettingValueTemplate') {
        if ($t.$k -and $t.$k.settingValueTemplateId) { $valTpl[$def] = $t.$k.settingValueTemplateId }
    }
    if ($t.choiceSettingValueTemplate -and $t.choiceSettingValueTemplate.children) {
        foreach ($c in $t.choiceSettingValueTemplate.children) { Read-InstanceTemplate $c }
    }
    if ($t.groupSettingCollectionValueTemplate) {
        foreach ($g in $t.groupSettingCollectionValueTemplate) {
            if ($g.settingValueTemplateId) { $valTpl[$def] = $g.settingValueTemplateId }
            foreach ($c in $g.children) { Read-InstanceTemplate $c }
        }
    }
}
foreach ($s in $sts) { Read-InstanceTemplate $s.settingInstanceTemplate }

Write-Host "$($sts.Count) modeles de parametres lus - $($instTpl.Count) references d'instance, $($valTpl.Count) de valeur."
if ($instTpl.Count -eq 0) {
    throw "Aucune reference de modele recuperee : la creation echouerait en 'TemplateReference not found'."
}
foreach ($d in @($ruleRoot.id, $idRuleName, $idFileName, $idHash, $idRuleType, $idChildProc)) {
    Write-Host ("  {0,-24} inst={1} val={2}" -f $d.Split('_')[-1],
                $(if ($instTpl.ContainsKey($d)) { 'oui' } else { 'NON' }),
                $(if ($valTpl.ContainsKey($d))  { 'oui' } else { 'non' }))
}

# ---------------------------------------------------------------------------
# 5. Construction et creation de la strategie
# ---------------------------------------------------------------------------
Write-Section 'Creation de la strategie'

# Les references de modele sont ajoutees seulement si le modele en expose une pour ce
# parametre : en envoyer une inexistante est aussi refuse que de l'omettre.
function New-ValueRef ($defId) {
    if ($valTpl.ContainsKey($defId)) {
        return @{ settingValueTemplateId = $valTpl[$defId]; useTemplateDefault = $false }
    }
    return $null
}
# $WithRefs : les references de modele ne valent que pour le PREMIER element de la collection
# de regles. Les repeter sur les suivants donne 400 "Duplicate References found" - une meme
# reference de modele ne peut apparaitre qu'une fois par strategie.
function New-StringSetting ($defId, $value, [bool]$WithRefs = $true) {
    $val = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'
              value         = $value }
    if ($WithRefs) { $vr = New-ValueRef $defId; if ($vr) { $val['settingValueTemplateReference'] = $vr } }

    $h = @{ '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
            settingDefinitionId = $defId
            simpleSettingValue  = $val }
    if ($WithRefs -and $instTpl.ContainsKey($defId)) {
        $h['settingInstanceTemplateReference'] = @{ settingInstanceTemplateId = $instTpl[$defId] }
    }
    return $h
}
function New-ChoiceSetting ($defId, $value, [bool]$WithRefs = $true) {
    $val = @{ value = $value; children = @() }
    if ($WithRefs) { $vr = New-ValueRef $defId; if ($vr) { $val['settingValueTemplateReference'] = $vr } }

    $h = @{ '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
            settingDefinitionId = $defId
            choiceSettingValue  = $val }
    if ($WithRefs -and $instTpl.ContainsKey($defId)) {
        $h['settingInstanceTemplateReference'] = @{ settingInstanceTemplateId = $instTpl[$defId] }
    }
    return $h
}

$isFirst    = $true
$ruleGroups = foreach ($t in $targets) {
    $r = $isFirst   # seul le premier element porte les references de modele
    $children = @(
        New-StringSetting $idRuleName "FortiClient EMS installer ($($t.Arch))" $r
        New-StringSetting $idFileName $t.Name    $r
        New-StringSetting $idHash     $t.Sha256  $r
        New-ChoiceSetting $idRuleType  $optAutomatic $r
        New-ChoiceSetting $idChildProc $optChildAll  $r
    )
    # Parametres presents seulement dans certaines versions du catalogue : ajoutes s'ils existent.
    if ($idRuleDesc)  { $children += New-StringSetting $idRuleDesc 'Installeur FortiClient EMS - elevation automatique. Ne couvre PAS FortiESNAC.exe ni FortiTray.exe.' $r }
    if ($optSigSource){ $children += New-ChoiceSetting $idSigSource $optSigSource $r }
    if ($optAppliesTo){ $children += New-ChoiceSetting $idAppliesTo $optAppliesTo $r }

    $grp = @{ children = $children }
    if ($r) {
        $gvr = New-ValueRef $ruleRoot.id
        if ($gvr) { $grp['settingValueTemplateReference'] = $gvr }
    }
    $isFirst = $false
    $grp
}

$rootInstance = @{
    '@odata.type'               = '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'
    settingDefinitionId         = $ruleRoot.id
    groupSettingCollectionValue = @($ruleGroups)
}
if ($instTpl.ContainsKey($ruleRoot.id)) {
    $rootInstance['settingInstanceTemplateReference'] = @{ settingInstanceTemplateId = $instTpl[$ruleRoot.id] }
}

$body = @{
    name              = $PolicyName
    description       = 'Eleve uniquement forticlientsetup_*.exe. Ne jamais ajouter FortiESNAC.exe ni FortiTray.exe.'
    platforms         = 'windows10'
    technologies      = 'endpointPrivilegeManagement'
    templateReference = @{ templateId = $EpmRulesTemplateId }
    settings          = @(
        @{ settingInstance = $rootInstance }
    )
}

$json = $body | ConvertTo-Json -Depth 20
Write-Host "Corps de la requete :" -ForegroundColor DarkGray
Write-Host $json -ForegroundColor DarkGray

$created = Invoke-MgGraphRequest -Method POST `
    -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' `
    -Body $json -ContentType 'application/json'

Write-Host ""
Write-Host "Strategie creee : $($created.name)" -ForegroundColor Green
Write-Host "  id : $($created.id)"
Write-Host ""
Write-Host "ETAPE SUIVANTE : assigner la strategie au groupe pilote dans le portail," -ForegroundColor Yellow
Write-Host "puis deployer l'app Win32 en 'Install behavior = System' - AU MEME GROUPE," -ForegroundColor Yellow
Write-Host "faute de quoi l'installeur n'est pas eleve et les installations echouent en 1223." -ForegroundColor Yellow
