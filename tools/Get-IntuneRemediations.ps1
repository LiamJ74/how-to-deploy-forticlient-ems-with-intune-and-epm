<#
.SYNOPSIS
    Inventorie les Proactive Remediations d'Intune : affectations et contenu reel des scripts.

.DESCRIPTION
    Repond a la question "qu'est-ce qui tourne VRAIMENT sur la flotte ?", qui ne se lit ni
    dans le portail (le contenu des scripts n'y est pas affiche en clair) ni dans le dossier
    local (le tenant peut heberger une version differente de celle qu'on a sous la main).

    Constate le 2026-09-22 : la remediation 'FortiCLient EMS - Remediation' rendait un message
    absent de remediation-detect.ps1 -> le tenant et le disque avaient diverge.

    LECTURE SEULE par defaut. Les scripts sont exportes dans un dossier pour etre relus a tete
    reposee. -RemoveAssignment retire les affectations d'une remediation nommee, apres
    confirmation ; il ne supprime jamais la remediation elle-meme, pour que l'operation reste
    reversible depuis le portail.

.PARAMETER Filter
    Ne garde que les remediations dont le nom contient ce texte.

.PARAMETER ExportFolder
    Dossier ou ecrire les scripts extraits. Defaut : .\remediations-export

.PARAMETER RemoveAssignment
    Nom EXACT de la remediation dont il faut retirer les affectations. Demande confirmation.

.EXAMPLE
    .\Get-IntuneRemediations.ps1 -Filter forti
.EXAMPLE
    .\Get-IntuneRemediations.ps1 -RemoveAssignment 'FortiCLient EMS - Remediation'
#>

[CmdletBinding()]
param(
    [string] $Filter,
    [string] $ExportFolder = (Join-Path $PSScriptRoot 'remediations-export'),
    [string] $RemoveAssignment,

    # Ciblage par id : insensible aux pieges de nommage (espaces en fin de chaine, casse,
    # doublons). A preferer des que le nom n'est pas trivial.
    [string] $RemoveAssignmentId
)

$ErrorActionPreference = 'Stop'
$GraphBase = 'https://graph.microsoft.com/beta'

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Module manquant. Installer : Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$scopes = if ($RemoveAssignment) { 'DeviceManagementConfiguration.ReadWrite.All' }
          else                   { 'DeviceManagementConfiguration.Read.All' }
Connect-MgGraph -Scopes $scopes -NoWelcome
Write-Host "Connecte : $((Get-MgContext).Account)"
Write-Host ''

# --- Inventaire ------------------------------------------------------------
$uri = "$GraphBase/deviceManagement/deviceHealthScripts"
$all = @()
do {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri
    $all += $page.value
    $uri = $page.'@odata.nextLink'
} while ($uri)

$list = if ($Filter) { $all | Where-Object { $_.displayName -match [regex]::Escape($Filter) } } else { $all }
if (-not $list) { Write-Host "Aucune remediation ne correspond a '$Filter'."; return }

New-Item -ItemType Directory -Path $ExportFolder -Force | Out-Null

foreach ($r in $list) {
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host $r.displayName -ForegroundColor Cyan
    Write-Host "  id            : $($r.id)"
    Write-Host "  publisher     : $($r.publisher)"
    Write-Host "  modifie le    : $($r.lastModifiedDateTime)"
    Write-Host "  contexte      : $(if ($r.runAsAccount) { $r.runAsAccount } else { 'system' })  |  64 bits : $(-not $r.runAs32Bit)"

    # Les affectations disent si la remediation tourne reellement sur la flotte : une
    # remediation "active" sans affectation ne s'execute nulle part.
    $asg = (Invoke-MgGraphRequest -Method GET -Uri "$GraphBase/deviceManagement/deviceHealthScripts/$($r.id)/assignments").value
    if ($asg) {
        Write-Host "  AFFECTEE a $($asg.Count) groupe(s) :" -ForegroundColor Yellow
        foreach ($a in $asg) {
            $t = $a.target
            $g = if ($t.groupId) { $t.groupId } else { $t.'@odata.type' -replace '#microsoft.graph.', '' }
            Write-Host "     $g   (planification : $($a.runSchedule.'@odata.type' -replace '#microsoft.graph.',''))"
        }
    } else {
        Write-Host '  non affectee (ne tourne nulle part)' -ForegroundColor DarkGray
    }

    # Le contenu des scripts n'est pas consultable dans le portail : c'est la seule facon de
    # savoir ce qui s'execute vraiment.
    # /!\ La collection deviceHealthScripts ne renvoie PAS detectionScriptContent : il faut
    # relire chaque remediation par son id, sinon rien n'est exporte (et le dossier reste vide).
    $full = Invoke-MgGraphRequest -Method GET -Uri "$GraphBase/deviceManagement/deviceHealthScripts/$($r.id)"

    $safe = ($r.displayName -replace '[^\w\-]', '_')
    foreach ($kind in 'detectionScriptContent', 'remediationScriptContent') {
        if ($full.$kind) {
            $txt  = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($full.$kind))
            $suffix = if ($kind -eq 'detectionScriptContent') { 'detect' } else { 'remediate' }
            $path = Join-Path $ExportFolder "$safe-$suffix.ps1"
            $txt | Out-File $path -Encoding UTF8 -Force
            $lines = ($txt -split "`n").Count
            Write-Host "  -> $suffix : $lines lignes, exporte dans $([IO.Path]::GetFileName($path))"
        }
    }
}

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor DarkGray
Write-Host "Scripts exportes dans : $ExportFolder" -ForegroundColor Green

# --- Retrait des affectations ----------------------------------------------
if (-not $RemoveAssignment -and -not $RemoveAssignmentId) { return }

if ($RemoveAssignmentId) {
    $target = @($all | Where-Object { $_.id -eq $RemoveAssignmentId })
    if (-not $target) { throw "Aucune remediation d'id '$RemoveAssignmentId'." }
} else {
    # Comparaison sur nom TRIMME : plusieurs remediations du tenant portent un espace en fin
    # de chaine ('FortiCLient EMS - Remediation ', 'Lecteurs Reseaux '), invisible dans le
    # portail mais suffisant a faire echouer une egalite stricte.
    $target = @($all | Where-Object { $_.displayName.Trim() -eq $RemoveAssignment.Trim() })
    if (-not $target)        { throw "Aucune remediation nommee '$RemoveAssignment' (comparaison sans espaces de bord)." }
    if ($target.Count -gt 1) { throw "Plusieurs remediations portent ce nom - utiliser -RemoveAssignmentId." }
}
$target = $target[0]
$RemoveAssignment = $target.displayName.Trim()

$asg = (Invoke-MgGraphRequest -Method GET -Uri "$GraphBase/deviceManagement/deviceHealthScripts/$($target.id)/assignments").value
if (-not $asg) { Write-Host "'$RemoveAssignment' n'a deja aucune affectation."; return }

Write-Host ''
Write-Host "Retrait de $($asg.Count) affectation(s) sur '$RemoveAssignment' ($($target.id))" -ForegroundColor Yellow
Write-Host 'La remediation elle-meme est CONSERVEE : reversible depuis le portail.' -ForegroundColor Yellow
$answer = Read-Host "Confirmer ? (oui/non)"
if ($answer -ne 'oui') { Write-Host 'Annule.'; return }

# L'API n'expose pas de DELETE par affectation : on reecrit la liste complete, vide.
Invoke-MgGraphRequest -Method POST `
    -Uri "$GraphBase/deviceManagement/deviceHealthScripts/$($target.id)/assign" `
    -Body (@{ deviceHealthScriptAssignments = @() } | ConvertTo-Json) -ContentType 'application/json' | Out-Null

$after = (Invoke-MgGraphRequest -Method GET -Uri "$GraphBase/deviceManagement/deviceHealthScripts/$($target.id)/assignments").value
if ($after) { Write-Host "ECHEC : il reste $($after.Count) affectation(s)." -ForegroundColor Red }
else        { Write-Host "'$RemoveAssignment' n'est plus affectee a aucun groupe." -ForegroundColor Green }
