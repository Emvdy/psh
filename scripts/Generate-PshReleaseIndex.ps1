# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ReleaseAssetsRoot,
    [Parameter(Mandatory = $true)][string] $Version,
    [Parameter(Mandatory = $true)][ValidatePattern('\A[0-9a-f]{40}\z')][string] $SourceCommit,
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $Finalize,
    [AllowNull()][string] $ReleaseCatalogPath,
    [AllowNull()][string] $MakeCatPath,
    [AllowNull()][string] $CatalogStagingRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$lifecyclePath = Join-Path $RepositoryRoot 'src/install/PackageLifecycle.ps1'
$trustPath = Join-Path $RepositoryRoot 'src/install/ReleaseTrust.ps1'
if (-not [IO.File]::Exists($lifecyclePath) -or -not [IO.File]::Exists($trustPath)) {
    throw 'Package lifecycle or release trust helpers are missing.'
}
. $lifecyclePath
. $trustPath

function Throw-PshReleaseIndexBuildError {
    param(
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $ErrorId,
        [Parameter(Mandatory = $true)][string] $Message,
        [AllowNull()][Exception] $InnerException
    )

    $exception = if ($null -eq $InnerException) { New-Object Exception($Message) } else { New-Object Exception($Message, $InnerException) }
    $exception.Data['PshExitCode'] = $ExitCode
    $exception.Data['PshErrorId'] = $ErrorId
    throw $exception
}

function Resolve-PshReleaseIndexFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)

    try { $full = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description }
    catch { Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexInputPath' -Message "$Description path is unsafe: $Path" -InnerException $_.Exception }
    $entry = Get-PshLifecyclePathEntry -Path $full -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) {
        Throw-PshReleaseIndexBuildError -ExitCode 4 -ErrorId 'PshReleaseIndexInputMissing' -Message "$Description must be an existing regular non-reparse file: $full"
    }
    return $full
}

function Resolve-PshReleaseIndexDirectory {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)

    try { $full = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description }
    catch { Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexInputPath' -Message "$Description path is unsafe: $Path" -InnerException $_.Exception }
    $entry = Get-PshLifecyclePathEntry -Path $full -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsDirectory -or [bool]$entry.IsReparsePoint) {
        Throw-PshReleaseIndexBuildError -ExitCode 4 -ErrorId 'PshReleaseIndexInputMissing' -Message "$Description must be an existing non-reparse directory: $full"
    }
    return $full
}

function Write-PshReleaseIndexText {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text
    )

    if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexOutputExists' -Message "Release index output already exists and will not be overwritten: $Path"
    }
    try { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }
    catch { Throw-PshReleaseIndexBuildError -ExitCode 3 -ErrorId 'PshReleaseIndexWrite' -Message "Unable to write release index output: $Path" -InnerException $_.Exception }
}

function Copy-PshReleaseIndexFile {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $Source = Resolve-PshReleaseIndexFile -Path $Source -Description $Description
    if ([IO.File]::Exists($Destination) -or [IO.Directory]::Exists($Destination)) {
        Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexOutputExists' -Message "$Description destination already exists: $Destination"
    }
    try { [IO.File]::Copy($Source, $Destination, $false) }
    catch { Throw-PshReleaseIndexBuildError -ExitCode 3 -ErrorId 'PshReleaseIndexCopy' -Message "Unable to copy ${Description}: $Destination" -InnerException $_.Exception }
}

function Get-PshReleaseIndexFileState {
    param([Parameter(Mandatory = $true)][string] $Path)

    $state = Get-PshLifecycleFileSha256 -Path $Path
    if ([int64]$state.Length -le 0) {
        Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexEmptyAsset' -Message "Release asset must not be empty: $Path"
    }
    return [pscustomobject][ordered]@{ Length = [int64]$state.Length; Sha256 = [string]$state.Sha256 }
}

function Get-PshReleaseZipEntryState {
    param(
        [Parameter(Mandatory = $true)][IO.Compression.ZipArchiveEntry] $Entry,
        [Parameter(Mandatory = $true)][bool] $CaptureBytes
    )

    if ([int64]$Entry.Length -lt 0 -or [int64]$Entry.Length -gt 1073741824) {
        Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexZipSize' -Message "ZIP entry length is outside the build limit: $($Entry.FullName)"
    }
    $input = $Entry.Open()
    $sha = [Security.Cryptography.SHA256]::Create()
    $memory = if ($CaptureBytes) { New-Object IO.MemoryStream } else { $null }
    try {
        $buffer = New-Object byte[] 65536
        [int64]$total = 0
        while ($true) {
            $read = $input.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $total += $read
            if ($total -gt 1073741824) {
                Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexZipSize' -Message "ZIP entry expands beyond the build limit: $($Entry.FullName)"
            }
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            if ($CaptureBytes) { $memory.Write($buffer, 0, $read) }
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        if ($total -ne [int64]$Entry.Length) {
            Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexZipLength' -Message "ZIP entry length changed while reading: $($Entry.FullName)"
        }
        return [pscustomobject][ordered]@{
            Length = $total
            Sha256 = ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
            Bytes = if ($CaptureBytes) { $memory.ToArray() } else { $null }
        }
    }
    finally {
        if ($null -ne $memory) { $memory.Dispose() }
        $sha.Dispose()
        $input.Dispose()
    }
}

function Get-PshReleasePackageMetadata {
    param(
        [Parameter(Mandatory = $true)][string] $PackagePath,
        [Parameter(Mandatory = $true)][string] $ExpectedVersion,
        [Parameter(Mandatory = $true)][string] $ExpectedEdition,
        [Parameter(Mandatory = $true)][string] $ExpectedArchitecture,
        [Parameter(Mandatory = $true)][string] $ExpectedCommit
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = New-Object IO.FileStream($PackagePath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
    try { $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $true, (New-Object Text.UTF8Encoding($false, $true))) }
    catch {
        $stream.Dispose()
        Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexZipOpen' -Message "Unable to open package ZIP: $PackagePath" -InnerException $_.Exception
    }
    try {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $entryStates = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        $manifestBytes = $null
        foreach ($entry in @($archive.Entries)) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('\') -or $name.EndsWith('/', [StringComparison]::Ordinal)) {
                Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexZipEntry' -Message "Package ZIP contains a non-file or non-canonical entry: $name"
            }
            try { $normalized = Assert-PshLifecycleRelativePath -Value $name -Description 'package ZIP entry' -Seen $seen }
            catch { Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexZipEntry' -Message "Package ZIP contains an unsafe or duplicate entry: $name" -InnerException $_.Exception }
            [int64]$attributes = [int]$entry.ExternalAttributes
            if ($attributes -lt 0) { $attributes += 4294967296 }
            $unixType = ($attributes -shr 16) -band 0xF000
            if (($unixType -ne 0 -and $unixType -ne 0x8000) -or (($attributes -band 0x400) -ne 0)) {
                Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexZipReparse' -Message "Package ZIP entry is a symlink, reparse point, or special file: $normalized"
            }
            $capture = $normalized -ceq 'package.manifest.json'
            $state = Get-PshReleaseZipEntryState -Entry $entry -CaptureBytes $capture
            if ($capture) { $manifestBytes = [byte[]]$state.Bytes }
            $entryStates[$normalized] = $state
        }
        if ($null -eq $manifestBytes -or -not $entryStates.ContainsKey('package.manifest.cat') -or
            [int64]$entryStates['package.manifest.cat'].Length -le 0) {
            Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexPackageSidecars' -Message 'Package ZIP must contain package.manifest.json and one non-empty package.manifest.cat sidecar.'
        }

        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-release-index-' + [Guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $temporaryRoot 'package.manifest.json'
        [void][IO.Directory]::CreateDirectory($temporaryRoot)
        try {
            [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
            $snapshot = Read-PshStrictJsonSnapshot -Path $manifestPath -Description 'package manifest from release ZIP'
            $manifest = Read-PshPackageManifest -Path $manifestPath -Snapshot $snapshot
        }
        finally {
            if ([IO.File]::Exists($manifestPath)) { [IO.File]::Delete($manifestPath) }
            if ([IO.Directory]::Exists($temporaryRoot)) {
                try { [IO.Directory]::Delete($temporaryRoot, $false) } catch { }
            }
        }
        if ([string]$manifest.version -cne $ExpectedVersion -or [string]$manifest.edition -cne $ExpectedEdition -or
            [string]$manifest.architecture -cne $ExpectedArchitecture -or [bool]$manifest.testOnly -or
            [string]$manifest.source.repository -cne 'https://github.com/Emvdy/psh' -or
            [string]$manifest.source.commit -cne $ExpectedCommit) {
            Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexPackageIdentity' -Message "Package manifest identity does not match its public release slot: $PackagePath"
        }
        if ($entryStates.Count -ne @($manifest.files).Count + 2) {
            Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexPackageSet' -Message "Package ZIP contains missing or extra files relative to its manifest: $PackagePath"
        }
        foreach ($file in @($manifest.files)) {
            $relative = [string]$file.relativePath
            if ([string]::Equals($relative, 'package.manifest.cat', [StringComparison]::OrdinalIgnoreCase) -or
                -not $entryStates.ContainsKey($relative)) {
                Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexPackageSet' -Message "Package manifest has an invalid or missing ZIP entry: $relative"
            }
            $actual = $entryStates[$relative]
            if ([int64]$actual.Length -ne [int64]$file.length -or [string]$actual.Sha256 -cne [string]$file.sha256) {
                Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexPackageHash' -Message "Package ZIP entry does not match its manifest: $relative"
            }
        }
        return [pscustomobject][ordered]@{
            ManifestSha256 = Get-PshLifecycleSha256Bytes -Bytes $manifestBytes
            TreeSha256 = [string]$manifest.treeSha256
            Edition = [string]$manifest.edition
            Architecture = [string]$manifest.architecture
            TestOnly = [bool]$manifest.testOnly
        }
    }
    finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

function New-PshReleaseCatalogStaging {
    param(
        [Parameter(Mandatory = $true)][string] $ExecutablePath,
        [Parameter(Mandatory = $true)][string] $StagingRoot,
        [Parameter(Mandatory = $true)][string] $IndexPath,
        [Parameter(Mandatory = $true)][string] $ChecksumPath,
        [Parameter(Mandatory = $true)][string] $CatalogName
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Throw-PshReleaseIndexBuildError -ExitCode 4 -ErrorId 'PshMakeCatUnavailable' -Message 'makecat catalog staging is available only on Windows.'
    }
    $ExecutablePath = Resolve-PshReleaseIndexFile -Path $ExecutablePath -Description 'makecat.exe'
    if ([IO.Path]::GetFileName($ExecutablePath) -ine 'makecat.exe') {
        Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshMakeCatPath' -Message 'MakeCatPath must name makecat.exe.'
    }
    $StagingRoot = [IO.Path]::GetFullPath($StagingRoot)
    [void](Assert-PshLifecycleNoReparseAncestors -Path $StagingRoot -Description 'release catalog staging root')
    if ([IO.File]::Exists($StagingRoot) -or [IO.Directory]::Exists($StagingRoot)) {
        Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexOutputExists' -Message "Release catalog staging root already exists: $StagingRoot"
    }
    [void][IO.Directory]::CreateDirectory($StagingRoot)
    $indexCopy = Join-Path $StagingRoot ([IO.Path]::GetFileName($IndexPath))
    $checksumCopy = Join-Path $StagingRoot 'SHA256SUMS'
    $cdfPath = Join-Path $StagingRoot 'release.cdf'
    Copy-PshReleaseIndexFile -Source $IndexPath -Destination $indexCopy -Description 'release index catalog input'
    Copy-PshReleaseIndexFile -Source $ChecksumPath -Destination $checksumCopy -Description 'SHA256SUMS catalog input'
    $cdf = @(
        '[CatalogHeader]',
        "Name=$CatalogName",
        'ResultDir=.',
        'PublicVersion=0x00000001',
        'EncodingType=0x00010001',
        '[CatalogFiles]',
        "<hash>$([IO.Path]::GetFileName($IndexPath))=$([IO.Path]::GetFileName($IndexPath))",
        '<hash>SHA256SUMS=SHA256SUMS'
    ) -join "`r`n"
    Write-PshReleaseIndexText -Path $cdfPath -Text ($cdf + "`r`n")
    Push-Location $StagingRoot
    try {
        $output = @(& $ExecutablePath $cdfPath 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    }
    finally { Pop-Location }
    if ($exitCode -ne 0) {
        $diagnostic = (($output | ForEach-Object { [string]$_ }) -join "`n")
        Throw-PshReleaseIndexBuildError -ExitCode 4 -ErrorId 'PshMakeCatFailed' -Message "makecat failed with code ${exitCode}: $diagnostic"
    }
    $catalogPath = Join-Path $StagingRoot $CatalogName
    if (-not [IO.File]::Exists($catalogPath) -or ([IO.FileInfo]$catalogPath).Length -le 0) {
        Throw-PshReleaseIndexBuildError -ExitCode 4 -ErrorId 'PshMakeCatOutput' -Message 'makecat completed without producing a non-empty catalog.'
    }
    return $catalogPath
}

function Confirm-PshReleaseCatalogForFinalize {
    param(
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][string] $IndexPath,
        [Parameter(Mandatory = $true)][string] $ChecksumPath
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Throw-PshReleaseIndexBuildError -ExitCode 4 -ErrorId 'PshReleaseCatalogVerificationUnavailable' -Message 'Final release catalog verification requires Windows Authenticode and file-catalog APIs.'
    }
    $signatureCommand = Get-Command Get-AuthenticodeSignature -CommandType Cmdlet -ErrorAction SilentlyContinue
    $catalogCommand = Get-Command Test-FileCatalog -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $signatureCommand -or $null -eq $catalogCommand) {
        Throw-PshReleaseIndexBuildError -ExitCode 4 -ErrorId 'PshReleaseCatalogVerificationUnavailable' -Message 'Required Windows catalog verification commands are unavailable.'
    }
    $CatalogPath = Resolve-PshReleaseIndexFile -Path $CatalogPath -Description 'externally signed release catalog'
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-release-catalog-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temporaryRoot)
    $indexCopy = Join-Path $temporaryRoot ([IO.Path]::GetFileName($IndexPath))
    $checksumCopy = Join-Path $temporaryRoot 'SHA256SUMS'
    try {
        [IO.File]::Copy($IndexPath, $indexCopy, $false)
        [IO.File]::Copy($ChecksumPath, $checksumCopy, $false)
        $signature = & $signatureCommand -FilePath $CatalogPath -ErrorAction Stop
        if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate) {
            Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseCatalogSignature' -Message "Release catalog Authenticode signature is invalid: $($signature.Status)"
        }
        $validation = & $catalogCommand -CatalogFilePath $CatalogPath -Path $temporaryRoot -Detailed -ErrorAction Stop
        $status = if ($null -ne $validation.PSObject.Properties['Status']) { [string]$validation.Status } else { [string]$validation }
        if ($status -cne 'ValidationPassed') {
            Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseCatalogMembership' -Message "Release catalog does not cover the exact index/checksum set: $status"
        }
    }
    finally {
        foreach ($path in @($indexCopy, $checksumCopy)) {
            if ([IO.File]::Exists($path)) { try { [IO.File]::Delete($path) } catch { } }
        }
        if ([IO.Directory]::Exists($temporaryRoot)) { try { [IO.Directory]::Delete($temporaryRoot, $false) } catch { } }
    }
    return $CatalogPath
}

$RepositoryRoot = Resolve-PshReleaseIndexDirectory -Path $RepositoryRoot -Description 'repository root'
$ReleaseAssetsRoot = Resolve-PshReleaseIndexDirectory -Path $ReleaseAssetsRoot -Description 'release assets root'
$Version = Assert-PshLifecycleSemVer -Value $Version -Description 'release version'
if ($Version -ceq '0.0.1-test') {
    Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexTestVersion' -Message 'Synthetic 0.0.1-test packages must never enter the public release index.'
}

$assetSpecs = @(
    [pscustomobject]@{ Name = 'install.ps1'; Role = 'installer'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = 'install.sh'; Role = 'installer'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = 'psh-installer.exe'; Role = 'installer'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = "psh-$Version-core.zip"; Role = 'package'; Edition = 'Core'; Architecture = 'any' },
    [pscustomobject]@{ Name = "psh-$Version-full-win-x64.zip"; Role = 'package'; Edition = 'Full'; Architecture = 'win-x64' },
    [pscustomobject]@{ Name = "psh-$Version-full-win-arm64.zip"; Role = 'package'; Edition = 'Full'; Architecture = 'win-arm64' },
    [pscustomobject]@{ Name = 'sbom.spdx.json'; Role = 'sbom'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = 'THIRD_PARTY_NOTICES.md'; Role = 'notice'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = 'RELEASE_NOTES.md'; Role = 'other'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = 'RELEASE_NOTES.zh-CN.md'; Role = 'other'; Edition = $null; Architecture = $null }
)
$indexName = "psh-release-$Version.json"
$catalogName = "psh-release-$Version.cat"
$expectedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($spec in $assetSpecs) { [void]$expectedNames.Add([string]$spec.Name) }
if ($Finalize) {
    [void]$expectedNames.Add($indexName)
    [void]$expectedNames.Add('SHA256SUMS')
}
$actualEntries = @(Get-ChildItem -LiteralPath $ReleaseAssetsRoot -Force)
foreach ($entry in $actualEntries) {
    if ($entry.PSIsContainer -or (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or -not $expectedNames.Contains([string]$entry.Name)) {
        Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexAssetSet' -Message "Release assets root contains an unexpected, non-file, or reparse entry: $($entry.Name)"
    }
}
if ($actualEntries.Count -ne $expectedNames.Count) {
    $expectedDescription = if ($Finalize) { 'the fixed ten public content assets plus the existing release index and SHA256SUMS' } else { 'exactly the fixed ten public content assets' }
    Throw-PshReleaseIndexBuildError -ExitCode 4 -ErrorId 'PshReleaseIndexAssetSet' -Message "Release assets root does not contain $expectedDescription."
}

$assets = New-Object System.Collections.Generic.List[object]
$packageRecords = New-Object System.Collections.Generic.List[object]
foreach ($spec in $assetSpecs) {
    $path = Resolve-PshReleaseIndexFile -Path (Join-Path $ReleaseAssetsRoot ([string]$spec.Name)) -Description "release asset '$($spec.Name)'"
    $state = Get-PshReleaseIndexFileState -Path $path
    $package = $null
    if ([string]$spec.Role -ceq 'package') {
        $metadata = Get-PshReleasePackageMetadata -PackagePath $path -ExpectedVersion $Version -ExpectedEdition ([string]$spec.Edition) -ExpectedArchitecture ([string]$spec.Architecture) -ExpectedCommit $SourceCommit
        $package = [pscustomobject][ordered]@{
            version = $Version
            edition = [string]$metadata.Edition
            architecture = [string]$metadata.Architecture
            packageManifestSha256 = [string]$metadata.ManifestSha256
            treeSha256 = [string]$metadata.TreeSha256
            testOnly = $false
        }
        $packageRecords.Add([pscustomobject][ordered]@{
                name = [string]$spec.Name
                manifestSha256 = [string]$metadata.ManifestSha256
                treeSha256 = [string]$metadata.TreeSha256
            })
    }
    $assets.Add([pscustomobject][ordered]@{
            name = [string]$spec.Name
            role = [string]$spec.Role
            url = "https://github.com/Emvdy/psh/releases/download/v$Version/$($spec.Name)"
            length = [int64]$state.Length
            sha256 = [string]$state.Sha256
            package = $package
        })
}

$index = [pscustomobject][ordered]@{
    schemaVersion = 1
    product = 'Psh'
    repository = 'https://github.com/Emvdy/psh'
    version = $Version
    tag = "v$Version"
    sourceCommit = $SourceCommit
    assets = $assets.ToArray()
}
$indexPath = Join-Path $ReleaseAssetsRoot $indexName
$checksumPath = Join-Path $ReleaseAssetsRoot 'SHA256SUMS'
$catalogDestination = Join-Path $ReleaseAssetsRoot $catalogName
$indexText = (ConvertTo-PshCanonicalJson -InputObject $index) + "`n"
$checksumLines = @($assets.ToArray() | ForEach-Object { '{0}  {1}' -f [string]$_.sha256, [string]$_.name })
$checksumText = ([string]::Join("`n", $checksumLines)) + "`n"
if ($Finalize) {
    $indexPath = Resolve-PshReleaseIndexFile -Path $indexPath -Description 'existing release index'
    $checksumPath = Resolve-PshReleaseIndexFile -Path $checksumPath -Description 'existing SHA256SUMS'
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    try {
        $existingIndexText = $utf8.GetString([IO.File]::ReadAllBytes($indexPath))
        $existingChecksumText = $utf8.GetString([IO.File]::ReadAllBytes($checksumPath))
    }
    catch { Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexFinalizeBytes' -Message 'Existing release index or SHA256SUMS is not valid UTF-8.' -InnerException $_.Exception }
    if ($existingIndexText -cne $indexText -or $existingChecksumText -cne $checksumText) {
        Throw-PshReleaseIndexBuildError -ExitCode 5 -ErrorId 'PshReleaseIndexFinalizeMismatch' -Message 'Existing release index or SHA256SUMS does not exactly match the current fixed content assets.'
    }
}
else {
    Write-PshReleaseIndexText -Path $indexPath -Text $indexText
    Write-PshReleaseIndexText -Path $checksumPath -Text $checksumText
}

$parsedIndex = Read-PshReleaseIndex -Path $indexPath
$parsedChecksums = Read-PshSha256Sums -Path $checksumPath
[void](Assert-PshReleaseIndexChecksums -Index $parsedIndex -Checksums $parsedChecksums)

$phase = 'catalog-deferred'
$code = 4
$catalogPath = $null
$unsignedCatalogPath = $null
if ($Finalize) {
    if ([string]::IsNullOrWhiteSpace($ReleaseCatalogPath)) {
        Throw-PshReleaseIndexBuildError -ExitCode 4 -ErrorId 'PshReleaseCatalogRequired' -Message 'Finalize requires an externally signed release catalog.'
    }
    $verifiedCatalog = Confirm-PshReleaseCatalogForFinalize -CatalogPath $ReleaseCatalogPath -IndexPath $indexPath -ChecksumPath $checksumPath
    Copy-PshReleaseIndexFile -Source $verifiedCatalog -Destination $catalogDestination -Description 'verified release catalog'
    $phase = 'finalized-with-verified-catalog'
    $code = 0
    $catalogPath = $catalogDestination
}
elseif (-not [string]::IsNullOrWhiteSpace($MakeCatPath)) {
    if ([string]::IsNullOrWhiteSpace($CatalogStagingRoot)) {
        Throw-PshReleaseIndexBuildError -ExitCode 4 -ErrorId 'PshReleaseCatalogStagingRoot' -Message 'CatalogStagingRoot is required when MakeCatPath is used.'
    }
    $unsignedCatalogPath = New-PshReleaseCatalogStaging -ExecutablePath $MakeCatPath -StagingRoot $CatalogStagingRoot -IndexPath $indexPath -ChecksumPath $checksumPath -CatalogName $catalogName
    $phase = 'unsigned-catalog-staged'
}

$indexState = Get-PshReleaseIndexFileState -Path $indexPath
$checksumState = Get-PshReleaseIndexFileState -Path $checksumPath
$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    product = 'Psh'
    version = $Version
    sourceCommit = $SourceCommit
    phase = $phase
    code = $code
    index = [pscustomobject][ordered]@{ name = $indexName; length = $indexState.Length; sha256 = $indexState.Sha256 }
    checksums = [pscustomobject][ordered]@{ name = 'SHA256SUMS'; length = $checksumState.Length; sha256 = $checksumState.Sha256 }
    catalog = if ($null -eq $catalogPath) { $null } else { [pscustomobject][ordered]@{ name = $catalogName; sha256 = [string](Get-PshReleaseIndexFileState -Path $catalogPath).Sha256 } }
    unsignedCatalogPath = $unsignedCatalogPath
    packages = $packageRecords.ToArray()
}
Write-Output $result
