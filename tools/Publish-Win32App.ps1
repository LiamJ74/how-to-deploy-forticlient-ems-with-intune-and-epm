<#
.SYNOPSIS
    Publie n'importe quel package Win32 dans Intune : creation de l'app, televersement du
    .intunewin, validation du contenu.

.DESCRIPTION
    Version generique de Publish-FortiClientWin32App.ps1. Suppose la convention de nommage
    maison : un dossier source contenant install.ps1, uninstall.ps1 et detection.ps1.

    Le script peut aussi construire le .intunewin lui-meme (-Build).

    L'app est toujours creee SANS AFFECTATION : le ciblage se fait dans le portail.

.PARAMETER SourceFolder
    Dossier source du package (celui qui contient install.ps1 et les binaires).

.PARAMETER DisplayName
    Nom de l'application dans Intune. Par defaut, le nom du dossier source.

.PARAMETER RunAsAccount
    'system' (defaut) ou 'user'. 'user' fait tourner install.ps1 sous le jeton de
    l'utilisateur connecte, sans elevation : a ne choisir que si l'installation en a besoin
    (acces au profil, a HKCU, ou a un jeton d'identite).

.PARAMETER FailOnElevationDenied
    Ajoute le code 1223 comme ECHEC. 1223 = elevation refusee par l'utilisateur ou absence de
    regle EPM. A activer pour une app en contexte user dont l'installeur exige l'elevation :
    sans cela, une installation qui n'a jamais eu lieu remonte en succes.

.PARAMETER Build
    Construit le .intunewin avant de publier, avec IntuneWinAppUtil.exe.

.PARAMETER Update
    Met a jour l'app existante portant ce DisplayName (nouvelle version de contenu) au lieu
    d'en creer une seconde.

.EXAMPLE
    .\Publish-Win32App.ps1 -SourceFolder '.\Forticlient\FortiClient EMS - ULTRA SIMPLE' -Build
.EXAMPLE
    .\Publish-Win32App.ps1 -SourceFolder '.\MonApp' -DisplayName 'Mon App' -RunAsAccount user -FailOnElevationDenied
.EXAMPLE
    .\Publish-Win32App.ps1 -SourceFolder '.\MonApp' -Build -Update

.NOTES
    Points qui ont coute du temps a etablir, conserves ici pour ne pas les reperdre :
      - L'etat d'un mobileAppContentFile est porte par 'uploadState'. Il n'existe PAS de
        propriete 'azureStorageUriRequestState' : la tester revient a comparer $null a une
        chaine, et la boucle d'attente tourne jusqu'au timeout sans rien detecter.
      - Le SAS de l'URI de stockage expire ; il faut le renouveler pendant le televersement
        des gros paquets.
      - Sans PATCH final de committedContentVersion, l'app existe mais reste sans contenu.
#>

[CmdletBinding()]
param(
    # Omis -> une fenetre demande le dossier et le nom de l'app.
    [string] $SourceFolder,

    [string] $DisplayName,
    [string] $Publisher    = 'Your Organization',
    [string] $Description,
    [string] $IntunewinPath,
    [string] $SetupFile    = 'install.ps1',
    [string] $UninstallFile = 'uninstall.ps1',
    [string] $DetectionFile = 'detection.ps1',

    [ValidateSet('system', 'user')]
    [string] $RunAsAccount = 'system',

    [string] $Architectures      = 'x64,arm64',
    [string] $MinWindowsRelease  = '1809',

    [switch] $FailOnElevationDenied,
    [switch] $Build,
    [switch] $Update,
    [switch] $NoGui,
    [string] $IntuneWinAppUtil = (Join-Path $PSScriptRoot 'IntuneWinAppUtil.exe')
)

$ErrorActionPreference = 'Stop'
$GraphBase = 'https://graph.microsoft.com/beta'

function Write-Section ($t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# 0. Fenetre de saisie
#    Affichee des que le dossier source n'est pas passe en parametre. Les valeurs saisies
#    remplacent les parametres ; -NoGui force le mode ligne de commande (scripts, CI).
# ---------------------------------------------------------------------------
function Show-PublishDialog {
    param([string]$Root, [string]$Folder, [string]$Name, [string]$Pub,
          [string]$RunAs, [bool]$DoBuild, [bool]$DoUpdate, [bool]$Fail1223)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $f = New-Object Windows.Forms.Form
    $f.Text = 'Publier une application Win32 dans Intune'
    $f.Size = New-Object Drawing.Size(640, 330)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false

    function New-Label ($text, $y) {
        $l = New-Object Windows.Forms.Label
        $l.Text = $text; $l.Location = New-Object Drawing.Point(15, $y)
        $l.Size = New-Object Drawing.Size(140, 20); $f.Controls.Add($l); return $l
    }

    $null = New-Label 'Dossier du package' 22
    $tbFolder = New-Object Windows.Forms.TextBox
    $tbFolder.Location = New-Object Drawing.Point(160, 20)
    $tbFolder.Size = New-Object Drawing.Size(370, 22)
    $tbFolder.Text = $Folder
    $f.Controls.Add($tbFolder)

    $btBrowse = New-Object Windows.Forms.Button
    $btBrowse.Text = 'Parcourir...'
    $btBrowse.Location = New-Object Drawing.Point(540, 18)
    $btBrowse.Size = New-Object Drawing.Size(80, 26)
    $f.Controls.Add($btBrowse)

    $null = New-Label 'Nom de l''application' 58
    $tbName = New-Object Windows.Forms.TextBox
    $tbName.Location = New-Object Drawing.Point(160, 56)
    $tbName.Size = New-Object Drawing.Size(460, 22)
    $tbName.Text = $Name
    $f.Controls.Add($tbName)

    # Le nom suit le dossier tant que l'utilisateur ne l'a pas saisi lui-meme.
    $script:nameEdited = [bool]$Name
    $tbName.Add_TextChanged({ if ($tbName.Focused) { $script:nameEdited = $true } })
    $syncName = {
        if (-not $script:nameEdited -and $tbFolder.Text) {
            $tbName.Text = Split-Path $tbFolder.Text -Leaf
        }
    }
    $tbFolder.Add_TextChanged($syncName)

    $btBrowse.Add_Click({
        $d = New-Object Windows.Forms.FolderBrowserDialog
        $d.Description = 'Dossier contenant install.ps1, uninstall.ps1 et detection.ps1'
        if ($tbFolder.Text -and (Test-Path $tbFolder.Text)) { $d.SelectedPath = $tbFolder.Text }
        elseif ($Root) { $d.SelectedPath = $Root }
        if ($d.ShowDialog() -eq 'OK') { $tbFolder.Text = $d.SelectedPath }
    })

    $null = New-Label 'Editeur' 94
    $tbPub = New-Object Windows.Forms.TextBox
    $tbPub.Location = New-Object Drawing.Point(160, 92)
    $tbPub.Size = New-Object Drawing.Size(240, 22)
    $tbPub.Text = $Pub
    $f.Controls.Add($tbPub)

    $null = New-Label 'Contexte d''install.' 130
    $cbRun = New-Object Windows.Forms.ComboBox
    $cbRun.Location = New-Object Drawing.Point(160, 128)
    $cbRun.Size = New-Object Drawing.Size(120, 22)
    $cbRun.DropDownStyle = 'DropDownList'
    $null = $cbRun.Items.AddRange(@('system', 'user'))
    $cbRun.SelectedItem = $RunAs
    $f.Controls.Add($cbRun)

    $lblHint = New-Object Windows.Forms.Label
    $lblHint.Location = New-Object Drawing.Point(290, 131)
    $lblHint.Size = New-Object Drawing.Size(330, 20)
    $lblHint.ForeColor = [Drawing.Color]::DimGray
    $lblHint.Text = 'user = sous le jeton de l''utilisateur, sans elevation'
    $f.Controls.Add($lblHint)

    function New-Check ($text, $y, $checked) {
        $c = New-Object Windows.Forms.CheckBox
        $c.Text = $text; $c.Location = New-Object Drawing.Point(160, $y)
        $c.Size = New-Object Drawing.Size(460, 22); $c.Checked = $checked
        $f.Controls.Add($c); return $c
    }
    $chkBuild  = New-Check 'Construire le .intunewin avant de publier' 160 $DoBuild
    $chkUpdate = New-Check 'Mettre a jour l''app existante du meme nom (sinon en creer une)' 184 $DoUpdate
    $chk1223   = New-Check 'Traiter le code 1223 (elevation refusee) comme un echec' 208 $Fail1223

    $btOk = New-Object Windows.Forms.Button
    $btOk.Text = 'Publier'; $btOk.Location = New-Object Drawing.Point(420, 245)
    $btOk.Size = New-Object Drawing.Size(95, 30); $btOk.DialogResult = 'OK'
    $f.Controls.Add($btOk); $f.AcceptButton = $btOk

    $btCancel = New-Object Windows.Forms.Button
    $btCancel.Text = 'Annuler'; $btCancel.Location = New-Object Drawing.Point(525, 245)
    $btCancel.Size = New-Object Drawing.Size(95, 30); $btCancel.DialogResult = 'Cancel'
    $f.Controls.Add($btCancel); $f.CancelButton = $btCancel

    # Validation avant fermeture : un dossier sans les trois scripts ne sert a rien, autant
    # le dire ici plutot que d'echouer apres la connexion a Graph.
    $btOk.Add_Click({
        if (-not $tbFolder.Text -or -not (Test-Path $tbFolder.Text)) {
            [Windows.Forms.MessageBox]::Show('Dossier introuvable.', 'Erreur', 'OK', 'Error') | Out-Null
            $f.DialogResult = 'None'; return
        }
        $missing = @('install.ps1', 'uninstall.ps1', 'detection.ps1') |
                   Where-Object { -not (Test-Path (Join-Path $tbFolder.Text $_)) }
        if ($missing) {
            [Windows.Forms.MessageBox]::Show(
                "Scripts manquants dans le dossier :`n  " + ($missing -join "`n  "),
                'Package incomplet', 'OK', 'Error') | Out-Null
            $f.DialogResult = 'None'; return
        }
        if (-not $tbName.Text.Trim()) {
            [Windows.Forms.MessageBox]::Show('Le nom de l''application est obligatoire.', 'Erreur', 'OK', 'Error') | Out-Null
            $f.DialogResult = 'None'; return
        }
    })

    if ($f.ShowDialog() -ne 'OK') { return $null }

    return [pscustomobject]@{
        SourceFolder = $tbFolder.Text
        DisplayName  = $tbName.Text.Trim()
        Publisher    = $tbPub.Text.Trim()
        RunAsAccount = $cbRun.SelectedItem
        Build        = $chkBuild.Checked
        Update       = $chkUpdate.Checked
        Fail1223     = $chk1223.Checked
    }
}

if (-not $SourceFolder -and -not $NoGui) {
    $r = Show-PublishDialog -Root $PSScriptRoot -Folder '' -Name $DisplayName -Pub $Publisher `
             -RunAs $RunAsAccount -DoBuild $Build.IsPresent -DoUpdate $Update.IsPresent `
             -Fail1223 $FailOnElevationDenied.IsPresent
    if (-not $r) { Write-Host 'Annule.'; return }
    $SourceFolder          = $r.SourceFolder
    $DisplayName           = $r.DisplayName
    $Publisher             = $r.Publisher
    $RunAsAccount          = $r.RunAsAccount
    $Build                 = [switch]$r.Build
    $Update                = [switch]$r.Update
    $FailOnElevationDenied = [switch]$r.Fail1223
}
if (-not $SourceFolder) { throw 'SourceFolder est requis avec -NoGui.' }

# ---------------------------------------------------------------------------
# 1a. Resolution des chemins
# ---------------------------------------------------------------------------
$SourceFolder = (Resolve-Path $SourceFolder).Path
if (-not $DisplayName) { $DisplayName = Split-Path $SourceFolder -Leaf }
if (-not $Description) { $Description = "$DisplayName - deploye via package Win32 (install.ps1)" }

foreach ($f in $SetupFile, $UninstallFile, $DetectionFile) {
    if (-not (Test-Path (Join-Path $SourceFolder $f))) { throw "Introuvable dans le package : $f" }
}
$detectionPs1 = Join-Path $SourceFolder $DetectionFile

if (-not $IntunewinPath) {
    $outDir = "$SourceFolder - output"
    $IntunewinPath = Join-Path $outDir ([IO.Path]::GetFileNameWithoutExtension($SetupFile) + '.intunewin')
}

# ---------------------------------------------------------------------------
# 1b. Construction optionnelle du .intunewin
# ---------------------------------------------------------------------------
if ($Build) {
    Write-Section 'Construction du .intunewin'
    if (-not (Test-Path $IntuneWinAppUtil)) { throw "IntuneWinAppUtil.exe introuvable : $IntuneWinAppUtil" }
    $outDir = Split-Path $IntunewinPath -Parent
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    & $IntuneWinAppUtil -c $SourceFolder -s $SetupFile -o $outDir -q
    if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil a echoue (exit $LASTEXITCODE)." }
    Write-Host "Construit : $IntunewinPath"
}
if (-not (Test-Path $IntunewinPath)) { throw "Introuvable : $IntunewinPath (utiliser -Build)" }

# ---------------------------------------------------------------------------
# 2. Lecture du .intunewin
#    ZIP contenant la charge CHIFFREE et Detection.xml, qui porte les cles que le commit exige.
# ---------------------------------------------------------------------------
Write-Section 'Lecture du package'

Add-Type -AssemblyName System.IO.Compression.FileSystem
$work = Join-Path $env:TEMP ('win32-publish-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$createdAppId = $null   # renseigne uniquement si CE script cree l'app (voir le catch)

try {
    $zip = [IO.Compression.ZipFile]::OpenRead($IntunewinPath)
    try {
        $xmlEntry = $zip.Entries | Where-Object { $_.FullName -like '*Metadata/Detection.xml' } | Select-Object -First 1
        $binEntry = $zip.Entries | Where-Object { $_.FullName -like '*Contents/IntunePackage.intunewin' } | Select-Object -First 1
        if (-not $xmlEntry -or -not $binEntry) { throw 'Structure .intunewin inattendue.' }

        $sr = New-Object IO.StreamReader($xmlEntry.Open())
        [xml]$meta = $sr.ReadToEnd(); $sr.Close()

        $payload = Join-Path $work 'IntunePackage.bin'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($binEntry, $payload, $true)
    } finally { $zip.Dispose() }

    $ai  = $meta.ApplicationInfo
    $enc = $ai.EncryptionInfo
    $encryptedSize = (Get-Item $payload).Length

    Write-Host "  App               : $DisplayName"
    Write-Host "  Fichier de setup  : $($ai.SetupFile)"
    Write-Host "  Taille            : $([math]::Round([int64]$ai.UnencryptedContentSize/1MB,1)) Mo"
    Write-Host "  Contexte          : $RunAsAccount"

    # ---------------------------------------------------------------------------
    # 3. Connexion Graph
    # ---------------------------------------------------------------------------
    Write-Section 'Connexion a Microsoft Graph'
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Module manquant. Installer : Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Connect-MgGraph -Scopes 'DeviceManagementApps.ReadWrite.All' -NoWelcome
    Write-Host "Connecte : $((Get-MgContext).Account)"

    # ---------------------------------------------------------------------------
    # 4. Creation (ou reprise) de l'application
    # ---------------------------------------------------------------------------
    Write-Section 'Application Win32'

    $codes = @(
        @{ returnCode = 0;    type = 'success' }
        @{ returnCode = 3010; type = 'softReboot' }
        @{ returnCode = 1641; type = 'hardReboot' }
        @{ returnCode = 1618; type = 'retry' }
    )
    # 1223 = elevation refusee. Le laisser en succes ferait remonter comme installee une app
    # qui n'a jamais ete posee - le faux positif le plus couteux a diagnostiquer.
    if ($FailOnElevationDenied) { $codes += @{ returnCode = 1223; type = 'failed' } }

    $appBody = @{
        '@odata.type'                  = '#microsoft.graph.win32LobApp'
        displayName                    = $DisplayName
        description                    = $Description
        publisher                      = $Publisher
        fileName                       = [IO.Path]::GetFileName($IntunewinPath)
        setupFilePath                  = $ai.SetupFile
        installCommandLine             = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\$SetupFile"
        uninstallCommandLine           = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\$UninstallFile"
        applicableArchitectures        = $Architectures
        minimumSupportedWindowsRelease = $MinWindowsRelease
        installExperience              = @{
            runAsAccount          = $RunAsAccount
            deviceRestartBehavior = 'basedOnReturnCode'
        }
        returnCodes                    = $codes
        detectionRules                 = @(
            @{
                '@odata.type'         = '#microsoft.graph.win32LobAppPowerShellScriptDetection'
                enforceSignatureCheck = $false
                runAs32Bit            = $false
                scriptContent         = [Convert]::ToBase64String([IO.File]::ReadAllBytes($detectionPs1))
            }
        )
        msiInformation                 = $null
    }

    $existing = $null
    if ($Update) {
        $esc  = $DisplayName.Replace("'", "''")
        $hits = Invoke-MgGraphRequest -Method GET `
                  -Uri "$GraphBase/deviceAppManagement/mobileApps?`$filter=displayName eq '$esc'"
        $matching = @($hits.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.win32LobApp' })
        if ($matching.Count -gt 1) {
            Write-Host "$($matching.Count) apps portent ce nom :" -ForegroundColor Yellow
            $matching | ForEach-Object { Write-Host "   $($_.id)" }
            throw "Ambigu : plusieurs apps nommees '$DisplayName'. Supprimer les doublons d'abord."
        }
        $existing = $matching | Select-Object -First 1
    }

    if ($existing) {
        $appId = $existing.id
        Write-Host "Mise a jour de l'app existante : $appId"
        Invoke-MgGraphRequest -Method PATCH -Uri "$GraphBase/deviceAppManagement/mobileApps/$appId" `
            -Body ($appBody | ConvertTo-Json -Depth 20) -ContentType 'application/json' | Out-Null
    } else {
        $app   = Invoke-MgGraphRequest -Method POST -Uri "$GraphBase/deviceAppManagement/mobileApps" `
                    -Body ($appBody | ConvertTo-Json -Depth 20) -ContentType 'application/json'
        $appId = $app.id
        $createdAppId = $appId
        Write-Host "App creee : $appId"
    }

    $appUri = "$GraphBase/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp"

    # ---------------------------------------------------------------------------
    # 5. Version de contenu et entree de fichier
    # ---------------------------------------------------------------------------
    Write-Section 'Version de contenu'

    $cv = Invoke-MgGraphRequest -Method POST -Uri "$appUri/contentVersions" -Body '{}' -ContentType 'application/json'
    Write-Host "contentVersion : $($cv.id)"

    $fileBody = @{
        '@odata.type' = '#microsoft.graph.mobileAppContentFile'
        name          = 'IntunePackage.intunewin'
        size          = [int64]$ai.UnencryptedContentSize
        sizeEncrypted = [int64]$encryptedSize
        manifest      = $null
        isDependency  = $false
    }
    $file = Invoke-MgGraphRequest -Method POST -Uri "$appUri/contentVersions/$($cv.id)/files" `
                -Body ($fileBody | ConvertTo-Json) -ContentType 'application/json'

    # /!\ L'etat est porte par 'uploadState' (enum mobileAppContentFileUploadState), PAS par
    # une propriete 'azureStorageUriRequestState' - celle-ci n'existe pas.
    $fileUri  = "$appUri/contentVersions/$($cv.id)/files/$($file.id)"
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 3
        $file = Invoke-MgGraphRequest -Method GET -Uri $fileUri
        if ($file.uploadState -in 'azureStorageUriRequestFailed', 'azureStorageUriRequestTimedOut') {
            throw "Provisionnement du stockage Azure echoue (uploadState=$($file.uploadState))."
        }
    } while ($file.uploadState -ne 'azureStorageUriRequestSuccess' -and (Get-Date) -lt $deadline)
    if ($file.uploadState -ne 'azureStorageUriRequestSuccess') {
        throw "Timeout : pas d'URI de stockage Azure (uploadState=$($file.uploadState))."
    }
    Write-Host 'Stockage Azure pret.'

    # ---------------------------------------------------------------------------
    # 6. Televersement par blocs (SAS renouvele en cours de route)
    # ---------------------------------------------------------------------------
    Write-Section 'Televersement'

    $blockSize = 6MB
    $fs        = [IO.File]::OpenRead($payload)
    $blockIds  = New-Object System.Collections.Generic.List[string]
    $sasUri    = $file.azureStorageUri
    $sasRenew  = (Get-Date).AddMinutes(30)
    $i         = 0
    $sw        = [Diagnostics.Stopwatch]::StartNew()

    try {
        $buffer = New-Object byte[] $blockSize
        while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
            # /!\ Copie typee, surtout pas $buffer[0..($read-1)] : l'indexation par plage rend
            # un object[], pas un byte[]. Le dernier bloc - le seul partiel - partait alors
            # serialise autrement que les autres, le blob etait corrompu sur sa fin, et le
            # commit echouait en 'commitFileFailed' apres un televersement en apparence reussi.
            if ($read -eq $buffer.Length) {
                $chunk = $buffer
            } else {
                $chunk = New-Object byte[] $read
                [Array]::Copy($buffer, 0, $chunk, 0, $read)
            }
            $blockId = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($i.ToString('D6')))
            $blockIds.Add($blockId)

            if ((Get-Date) -gt $sasRenew) {
                Invoke-MgGraphRequest -Method POST -Uri "$fileUri/renewUpload" -Body '{}' -ContentType 'application/json' | Out-Null
                $d2 = (Get-Date).AddMinutes(5)
                do {
                    Start-Sleep -Seconds 3
                    $file = Invoke-MgGraphRequest -Method GET -Uri $fileUri
                } while ($file.uploadState -ne 'azureStorageUriRenewalSuccess' -and
                         $file.uploadState -ne 'azureStorageUriRequestSuccess' -and (Get-Date) -lt $d2)
                $sasUri   = $file.azureStorageUri
                $sasRenew = (Get-Date).AddMinutes(30)
                Write-Host '  (SAS renouvele)'
            }

            Invoke-RestMethod -Method PUT -Uri "$sasUri&comp=block&blockid=$blockId" `
                -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -Body $chunk -ContentType 'application/octet-stream' | Out-Null

            $i++
            $pct = [math]::Round(($fs.Position / $fs.Length) * 100)
            Write-Progress -Activity "Televersement de $DisplayName" -Status "$pct% ($i blocs)" -PercentComplete $pct
        }
    } finally { $fs.Close(); Write-Progress -Activity "Televersement de $DisplayName" -Completed }

    $sw.Stop()
    Write-Host "$i blocs televerses en $([math]::Round($sw.Elapsed.TotalMinutes,1)) min."

    # Sans la liste de blocs, le blob reste vide cote Azure.
    $xmlList = '<?xml version="1.0" encoding="utf-8"?><BlockList>' +
               (($blockIds | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
    Invoke-RestMethod -Method PUT -Uri "$sasUri&comp=blocklist" -Body $xmlList -ContentType 'application/xml' | Out-Null
    Write-Host 'Liste de blocs validee.'

    # ---------------------------------------------------------------------------
    # 7. Commit : Intune dechiffre avec les cles du manifeste
    # ---------------------------------------------------------------------------
    Write-Section 'Validation du contenu'

    $commit = @{ fileEncryptionInfo = @{
        encryptionKey        = $enc.EncryptionKey
        macKey               = $enc.MacKey
        initializationVector = $enc.InitializationVector
        mac                  = $enc.Mac
        profileIdentifier    = $enc.ProfileIdentifier
        fileDigest           = $enc.FileDigest
        fileDigestAlgorithm  = $enc.FileDigestAlgorithm
    } }
    Invoke-MgGraphRequest -Method POST -Uri "$fileUri/commit" `
        -Body ($commit | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null

    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 5
        $file = Invoke-MgGraphRequest -Method GET -Uri $fileUri
        if ($file.uploadState -eq 'commitFileFailed') { throw "Validation du fichier echouee cote Intune (uploadState=$($file.uploadState)). Contenu televerse illisible : verifier que chaque bloc est bien un byte[]." }
    } while ($file.uploadState -ne 'commitFileSuccess' -and (Get-Date) -lt $deadline)
    if ($file.uploadState -ne 'commitFileSuccess') { throw "Timeout sur la validation (uploadState=$($file.uploadState))." }
    Write-Host 'Contenu valide.'

    # Tant que committedContentVersion ne pointe pas sur cette version, l'app reste sans contenu.
    Invoke-MgGraphRequest -Method PATCH -Uri "$GraphBase/deviceAppManagement/mobileApps/$appId" `
        -Body (@{ '@odata.type' = '#microsoft.graph.win32LobApp'
                  committedContentVersion = $cv.id } | ConvertTo-Json) -ContentType 'application/json' | Out-Null

    Write-Section 'Termine'
    Write-Host "Application : $DisplayName" -ForegroundColor Green
    Write-Host "  id               : $appId"
    Write-Host "  contentVersion   : $($cv.id)"
    Write-Host "  Install behavior : $RunAsAccount"
    Write-Host ''
    Write-Host "L'app est creee SANS AFFECTATION - a cibler dans le portail." -ForegroundColor Yellow

    $createdAppId = $null   # publication reussie : plus rien a nettoyer

} catch {
    # Une app creee mais restee sans contenu n'est bonne a rien et polluerait le tenant.
    # On ne supprime QUE ce que cette execution a cree : jamais une app reprise par -Update.
    if ($createdAppId) {
        Write-Host ''
        Write-Host "Echec avant la validation du contenu - suppression de l'app creee ($createdAppId)" -ForegroundColor Yellow
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "$GraphBase/deviceAppManagement/mobileApps/$createdAppId" | Out-Null
            Write-Host 'App incomplete supprimee.' -ForegroundColor Yellow
        } catch {
            Write-Host "Suppression impossible : $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "A supprimer a la main dans le portail : $createdAppId" -ForegroundColor Red
        }
    }
    throw

} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
