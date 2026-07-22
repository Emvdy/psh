# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
    Release trust primitives. Online trust is rooted in the SHA256 digests
    published by the fixed GitHub release-metadata API and then extended
    through catalog membership, the release index, and package manifests.
    Offline trust validates the package catalog membership and the manifest's
    complete SHA256 tree without requiring a network or a code-signing
    certificate. Authenticode verification remains available as an additional
    capability, but it is not a prerequisite for the v0.1.0 hash trust path.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($null -eq (Get-Command -Name Read-PshStrictJsonSnapshot -CommandType Function -ErrorAction SilentlyContinue)) {
    $lifecyclePath = Join-Path -Path $PSScriptRoot -ChildPath 'PackageLifecycle.ps1'
    if (-not [IO.File]::Exists($lifecyclePath)) {
        throw "Psh package lifecycle helpers were not found: $lifecyclePath"
    }
    . $lifecyclePath
}

$script:PshReleaseRepository = 'https://github.com/Emvdy/psh'
$script:PshReleaseApiRoot = 'https://api.github.com/repos/Emvdy/psh/releases'
$script:PshProductionTrustPolicyVersion = '2026-07-22.2'
$script:PshReleaseIndexKeys = @('schemaVersion', 'product', 'repository', 'version', 'tag', 'sourceCommit', 'assets')
$script:PshReleaseAssetKeys = @('name', 'role', 'url', 'length', 'sha256', 'package')
$script:PshReleasePackageKeys = @('version', 'edition', 'architecture', 'packageManifestSha256', 'treeSha256', 'testOnly')
$script:PshReleaseAssetRoles = @('installer', 'package', 'manifest', 'checksum', 'sbom', 'notice', 'other')
$script:PshPublisherPolicyKeys = @(
    'schemaVersion', 'publisher', 'subjectDistinguishedNames', 'requiredEkuOids',
    'requiredCertificatePolicyOids', 'allowedRootCertificateSha256'
)
$script:PshCodeSigningEku = '1.3.6.1.5.5.7.3.3'
if ($null -eq (Get-Variable -Name PshReleaseTrustToken -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PshReleaseTrustToken = New-Object object
}
if ($null -eq (Get-Variable -Name PshPackageTrustToken -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PshPackageTrustToken = New-Object object
}
if ($null -eq (Get-Variable -Name PshTrustedReleaseRegistry -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PshTrustedReleaseRegistry = New-Object 'System.Runtime.CompilerServices.ConditionalWeakTable[object,object]'
}
if ($null -eq (Get-Variable -Name PshTrustedPackageRegistry -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PshTrustedPackageRegistry = New-Object 'System.Runtime.CompilerServices.ConditionalWeakTable[object,object]'
}
if ($null -eq (Get-Variable -Name PshReleaseMetadataTrustToken -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PshReleaseMetadataTrustToken = New-Object object
}
if ($null -eq (Get-Variable -Name PshTrustedReleaseMetadataRegistry -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PshTrustedReleaseMetadataRegistry = New-Object 'System.Runtime.CompilerServices.ConditionalWeakTable[object,object]'
}

function Throw-PshReleaseTrustError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $ErrorId,
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter()][AllowNull()][Exception] $InnerException
    )

    $kind = if ($ExitCode -eq 3) { 'Io' } elseif ($ExitCode -eq 4) { 'Dependency' } else { 'Integrity' }
    Throw-PshLifecycleError -ExitCode $ExitCode -Kind $kind -ErrorId $ErrorId -Message $Message -InnerException $InnerException
}

function Get-PshProductionTrustPolicy {
    [CmdletBinding()]
    param()

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        policyVersion = $script:PshProductionTrustPolicyVersion
        repository = $script:PshReleaseRepository
        releaseMetadataApi = $script:PshReleaseApiRoot
        hashAlgorithm = 'SHA256'
        onlineTrustMode = 'github-release-asset-digest'
        offlineTrustMode = 'offline-external-archive-sha256+package-catalog-sha256'
        catalogMembershipRequired = $true
        archiveBindingRequired = $true
        signatureRequired = $false
        provenanceAttestationRequiredAtPublish = $true
        runtimeAttestationVerification = 'external-release-gate'
    }
}

function New-PshProductionTrustReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $TrustMode,
        [Parameter(Mandatory = $true)][string] $Checksum,
        [Parameter(Mandatory = $true)][string] $CatalogMembership,
        [Parameter(Mandatory = $true)][bool] $SignatureNotRequired,
        [Parameter(Mandatory = $true)][string] $ArchiveBinding,
        [Parameter()][AllowNull()][string] $ArchiveSha256,
        [Parameter(Mandatory = $true)][string] $AttestationVerification
    )

    $policy = Get-PshProductionTrustPolicy
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        policyVersion = [string]$policy.policyVersion
        trustMode = $TrustMode
        checksum = $Checksum
        catalogMembership = $CatalogMembership
        signatureNotRequired = $SignatureNotRequired
        archiveBinding = $ArchiveBinding
        archiveSha256 = $ArchiveSha256
        attestationVerification = $AttestationVerification
    }
}

function Close-PshReleaseMetadataResponse {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object] $Response)

    if ($null -eq $Response) { return }
    $stream = Get-PshLifecycleProperty $Response 'Stream'
    if ($stream -is [IDisposable]) {
        try { $stream.Dispose() } catch { }
    }
    $disposable = Get-PshLifecycleProperty $Response 'Disposable'
    if ($disposable -is [IDisposable] -and -not [object]::ReferenceEquals($stream, $disposable)) {
        try { $disposable.Dispose() } catch { }
    }
}

function Invoke-PshReleaseMetadataHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Uri] $Uri)

    $onlineTransport = Get-Command -Name Invoke-PshOnlineHttpRequest -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $onlineTransport) {
        return Invoke-PshOnlineHttpRequest -Uri $Uri
    }

    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $false
    $request.AutomaticDecompression = [Net.DecompressionMethods]::None
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $request.UserAgent = 'Psh-Installer/1.0'
    $request.Accept = 'application/vnd.github+json'
    $response = $null
    try {
        try { $response = [Net.HttpWebResponse]$request.GetResponse() }
        catch [Net.WebException] {
            if ($null -eq $_.Exception.Response) { throw }
            $response = [Net.HttpWebResponse]$_.Exception.Response
        }
        return [pscustomobject][ordered]@{
            StatusCode = [int]$response.StatusCode
            ResponseUri = $response.ResponseUri.AbsoluteUri
            ContentLength = [int64]$response.ContentLength
            Stream = $response.GetResponseStream()
            Disposable = $response
        }
    }
    catch {
        if ($null -ne $response) { try { $response.Dispose() } catch { } }
        throw
    }
}

function Read-PshReleaseMetadataResponseBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int64] $MaximumLength
    )

    $declaredLength = [int64](Get-PshLifecycleProperty $Response 'ContentLength')
    if ($declaredLength -gt $MaximumLength) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataLength' -Message 'GitHub release metadata exceeds the installer limit.'
    }
    $stream = Get-PshLifecycleProperty $Response 'Stream'
    if ($stream -isnot [IO.Stream] -or -not $stream.CanRead) {
        Throw-PshReleaseTrustError -ExitCode 3 -ErrorId 'PshReleaseMetadataResponse' -Message 'GitHub release metadata has no readable response stream.'
    }
    $memory = New-Object IO.MemoryStream
    try {
        $buffer = New-Object byte[] 65536
        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -eq 0) { break }
            if ($memory.Length -gt ($MaximumLength - $read)) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataLength' -Message 'GitHub release metadata exceeds the installer limit.'
            }
            $memory.Write($buffer, 0, $read)
        }
        if ($declaredLength -ge 0 -and $memory.Length -ne $declaredLength) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataLength' -Message 'GitHub release metadata length does not match its HTTPS response.'
        }
        return (, $memory.ToArray())
    }
    finally { $memory.Dispose() }
}

function Invoke-PshReleaseMetadataRequestWithRetry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Uri] $Uri)

    foreach ($attempt in 1..4) {
        $response = $null
        try { $response = Invoke-PshReleaseMetadataHttpRequest -Uri $Uri }
        catch {
            if ($attempt -lt 4) { Start-Sleep -Milliseconds (250 * $attempt); continue }
            Throw-PshReleaseTrustError -ExitCode 3 -ErrorId 'PshReleaseMetadataTransport' -Message "GitHub release metadata request failed after $attempt attempts." -InnerException $_.Exception
        }
        $statusCode = [int](Get-PshLifecycleProperty $response 'StatusCode')
        if ($statusCode -in @(502, 503, 504) -and $attempt -lt 4) {
            Close-PshReleaseMetadataResponse -Response $response
            Start-Sleep -Milliseconds (250 * $attempt)
            continue
        }
        return $response
    }
    Throw-PshReleaseTrustError -ExitCode 3 -ErrorId 'PshReleaseMetadataTransport' -Message 'GitHub release metadata request failed.'
}

function Resolve-PshTrustedReleaseMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $RequestedVersion)

    $requestedTag = $null
    $apiUriText = $null
    if ($RequestedVersion -ieq 'latest') {
        $apiUriText = $script:PshReleaseApiRoot + '/latest'
    }
    else {
        $fixedVersion = Assert-PshLifecycleSemVer -Value $RequestedVersion -Description 'Requested release version'
        $requestedTag = 'v' + $fixedVersion
        $apiUriText = $script:PshReleaseApiRoot + '/tags/' + $requestedTag
    }
    $apiUri = New-Object Uri($apiUriText, [UriKind]::Absolute)
    $response = $null
    try {
        $response = Invoke-PshReleaseMetadataRequestWithRetry -Uri $apiUri
        if ([string](Get-PshLifecycleProperty $response 'ResponseUri') -cne $apiUri.AbsoluteUri) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataRedirect' -Message 'GitHub release metadata followed an unreviewed redirect.'
        }
        if ([int](Get-PshLifecycleProperty $response 'StatusCode') -ne 200) {
            Throw-PshReleaseTrustError -ExitCode 3 -ErrorId 'PshReleaseMetadataHttpStatus' -Message "GitHub release metadata returned HTTP status $([int](Get-PshLifecycleProperty $response 'StatusCode'))."
        }
        $bytes = Read-PshReleaseMetadataResponseBytes -Response $response -MaximumLength 16777216
    }
    finally { Close-PshReleaseMetadataResponse -Response $response }

    try {
        $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
        $document = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataJson' -Message 'GitHub release metadata is not valid UTF-8 JSON.' -InnerException $_.Exception
    }
    foreach ($name in @('tag_name', 'draft', 'prerelease', 'assets')) {
        if ($null -eq $document.PSObject.Properties[$name]) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataSchema' -Message "GitHub release metadata is missing '$name'."
        }
    }
    if ($document.draft -isnot [bool] -or $document.prerelease -isnot [bool] -or [bool]$document.draft -or [bool]$document.prerelease) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataKind' -Message 'GitHub release metadata must identify a published stable release.'
    }
    $tag = [string]$document.tag_name
    if ($tag -cnotmatch '\Av.+\z') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataTag' -Message 'GitHub release metadata does not contain a fixed v-prefixed tag.'
    }
    $version = Assert-PshLifecycleSemVer -Value $tag.Substring(1) -Description 'GitHub release version'
    if ($tag -cne ('v' + $version) -or ($null -ne $requestedTag -and $tag -cne $requestedTag)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataTag' -Message 'GitHub release metadata does not match the requested fixed tag.'
    }
    if ($document.assets -isnot [System.Array]) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataAssets' -Message 'GitHub release metadata assets must be an array.'
    }

    $expectedNames = @("psh-release-$version.json", 'SHA256SUMS', "psh-release-$version.cat")
    $normalizedAssets = New-Object System.Collections.Generic.List[object]
    foreach ($expectedName in $expectedNames) {
        $assetMatches = @($document.assets | Where-Object { [string](Get-PshLifecycleProperty $_ 'name') -ceq $expectedName })
        if ($assetMatches.Count -ne 1) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataAsset' -Message "GitHub release metadata must contain exactly one '$expectedName' asset."
        }
        $asset = $assetMatches[0]
        $digest = Get-PshLifecycleProperty $asset 'digest'
        $size = Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $asset 'size') -Description "GitHub release asset '$expectedName' size" -NonNegative
        $downloadUrl = Get-PshLifecycleProperty $asset 'browser_download_url'
        $expectedUrl = "$($script:PshReleaseRepository)/releases/download/$tag/$expectedName"
        if ($digest -isnot [string] -or [string]$digest -cnotmatch '\Asha256:[0-9a-f]{64}\z' -or [int64]$size -le 0) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataDigest' -Message "GitHub release asset '$expectedName' has no valid SHA256 digest and size."
        }
        if ($downloadUrl -isnot [string] -or [string]$downloadUrl -cne $expectedUrl) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataUrl' -Message "GitHub release asset '$expectedName' has an unexpected download URL."
        }
        [void]$normalizedAssets.Add([pscustomobject][ordered]@{
                name = $expectedName
                length = [int64]$size
                sha256 = ([string]$digest).Substring(7)
                url = $expectedUrl
            })
    }

    $record = [pscustomobject][ordered]@{
        Repository = $script:PshReleaseRepository
        Version = $version
        Tag = $tag
        ApiUri = $apiUri.AbsoluteUri
        Assets = @($normalizedAssets.ToArray())
    }
    $handle = [pscustomobject][ordered]@{
        PSTypeName = 'Psh.TrustedReleaseMetadata'
        TrustToken = $script:PshReleaseMetadataTrustToken
        Repository = [string]$record.Repository
        Version = [string]$record.Version
        Tag = [string]$record.Tag
        Assets = @($record.Assets | ForEach-Object { [pscustomobject][ordered]@{ name = $_.name; length = $_.length; sha256 = $_.sha256; url = $_.url } })
    }
    [void]$script:PshTrustedReleaseMetadataRegistry.Add($handle, $record)
    return $handle
}

function Assert-PshTrustedReleaseMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)

    $record = $null
    $token = Get-PshLifecycleProperty $InputObject 'TrustToken'
    if ($null -eq $token -or -not [object]::ReferenceEquals($token, $script:PshReleaseMetadataTrustToken) -or
        -not $script:PshTrustedReleaseMetadataRegistry.TryGetValue($InputObject, [ref]$record)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshUntrustedReleaseMetadata' -Message 'Release trust requires metadata obtained from the fixed GitHub Releases API.'
    }
    return [pscustomobject][ordered]@{
        Repository = [string]$record.Repository
        Version = [string]$record.Version
        Tag = [string]$record.Tag
        ApiUri = [string]$record.ApiUri
        Assets = @($record.Assets | ForEach-Object { [pscustomobject][ordered]@{ name = $_.name; length = $_.length; sha256 = $_.sha256; url = $_.url } })
    }
}

function Close-PshPackageArchiveBindingFiles {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]] $Records)

    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $stream = Get-PshLifecycleProperty $record 'Stream'
        if ($stream -is [IDisposable]) { try { $stream.Dispose() } catch { } }
    }
}

function Open-PshPackageArchiveDirectorySnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $PackageRoot)

    $records = New-Object System.Collections.ArrayList
    try {
        $root = Assert-PshLifecycleNoReparseAncestors -Path $PackageRoot -Description 'offline package archive-binding root'
        $rootEntry = Get-PshLifecyclePathEntry -Path $root -Description 'offline package archive-binding root'
        if (-not [bool]$rootEntry.Exists -or -not [bool]$rootEntry.IsDirectory -or [bool]$rootEntry.IsReparsePoint) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchivePackageRoot' -Message "Archive binding requires a non-reparse package directory: $root"
        }
        $root = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $prefix = $root + [IO.Path]::DirectorySeparatorChar
        $files = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        $stack = New-Object System.Collections.Stack
        $stack.Push($root)
        while ($stack.Count -gt 0) {
            $directory = [string]$stack.Pop()
            [string[]]$entries = [IO.Directory]::GetFileSystemEntries($directory)
            [Array]::Sort($entries, [StringComparer]::OrdinalIgnoreCase)
            foreach ($entryPath in $entries) {
                $fullPath = Assert-PshLifecycleNoReparseAncestors -Path $entryPath -Description 'offline package archive-binding entry'
                $attributes = [IO.File]::GetAttributes($fullPath)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchivePackageReparsePoint' -Message "Archive-bound package contains a reparse point: $fullPath"
                }
                if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    $stack.Push($fullPath)
                    continue
                }
                if (-not $fullPath.StartsWith($prefix, (Get-PshLifecyclePathComparison))) {
                    Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveEntryPath' -Message "Archive-bound package path escapes its root: $fullPath"
                }
                $relativeCandidate = $fullPath.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar, '/').Replace([IO.Path]::AltDirectorySeparatorChar, '/')
                try { $relative = Assert-PshLifecycleRelativePath -Value $relativeCandidate -Description 'Archive-bound package file path' }
                catch { Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveEntryPath' -Message "Archive-bound package contains an unsafe file path: $relativeCandidate" -InnerException $_.Exception }
                if ($files.ContainsKey($relative)) {
                    Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveDuplicateEntry' -Message "Archive-bound package contains a case-insensitive duplicate file path: $relative"
                }
                $stream = $null
                try {
                    $stream = New-Object IO.FileStream($fullPath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { $sha256 = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
                    finally { $sha.Dispose() }
                    $stream.Position = 0
                    $record = [pscustomobject][ordered]@{
                        RelativePath = $relative
                        Path = $fullPath
                        Length = [int64]$stream.Length
                        Sha256 = $sha256
                        Stream = $stream
                    }
                    [void]$records.Add($record)
                    $files.Add($relative, $record)
                    $stream = $null
                }
                finally {
                    if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
                }
            }
        }
        return [pscustomobject][ordered]@{
            Root = $root
            Files = $files
            Records = $records
        }
    }
    catch {
        Close-PshPackageArchiveBindingFiles -Records @($records)
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshReleaseTrustError -ExitCode 3 -ErrorId 'PshOfflineArchivePackageRead' -Message 'Unable to snapshot the extracted package for archive binding.' -InnerException $_.Exception
    }
}

function Confirm-PshPackageArchiveBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][string] $ArchiveSha256,
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter()][switch] $RetainLocks
    )

    if ($ArchiveSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $ArchiveSha256 -ceq ('0' * 64)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveSha256' -Message 'Offline archive SHA256 evidence must be a non-zero lowercase SHA256 value.'
    }
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    }
    catch {
        Throw-PshReleaseTrustError -ExitCode 4 -ErrorId 'PshOfflineArchiveSupportUnavailable' -Message 'ZIP archive verification support is unavailable on this runtime.' -InnerException $_.Exception
    }

    $archiveFullPath = Assert-PshLifecycleNoReparseAncestors -Path $ArchivePath -Description 'offline package archive evidence'
    $archiveEntry = Get-PshLifecyclePathEntry -Path $archiveFullPath -Description 'offline package archive evidence'
    if (-not [bool]$archiveEntry.Exists -or -not [bool]$archiveEntry.IsRegularFile -or [bool]$archiveEntry.IsReparsePoint) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveFile' -Message "Offline archive evidence must be a regular non-reparse file: $archiveFullPath"
    }

    $archiveStream = $null
    $archive = $null
    $packageSnapshot = $null
    try {
        $archiveStream = New-Object IO.FileStream($archiveFullPath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
        $archiveSha = [Security.Cryptography.SHA256]::Create()
        try { $actualArchiveSha256 = ([BitConverter]::ToString($archiveSha.ComputeHash($archiveStream))).Replace('-', '').ToLowerInvariant() }
        finally { $archiveSha.Dispose() }
        if ($actualArchiveSha256 -cne $ArchiveSha256) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveHashMismatch' -Message 'Offline package archive does not match its trusted SHA256 evidence.'
        }
        $archiveStream.Position = 0
        try { $archive = New-Object IO.Compression.ZipArchive($archiveStream, ([IO.Compression.ZipArchiveMode]::Read), $true, (New-Object Text.UTF8Encoding($false, $true))) }
        catch { Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveFormat' -Message 'Offline package archive is not a valid ZIP file.' -InnerException $_.Exception }

        $packageSnapshot = Open-PshPackageArchiveDirectorySnapshot -PackageRoot $PackageRoot
        $packageFiles = Get-PshLifecycleProperty $packageSnapshot 'Files'
        $archivePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $entryRecords = New-Object System.Collections.Generic.List[object]
        foreach ($zipEntry in @($archive.Entries)) {
            $entryName = [string]$zipEntry.FullName
            if ([string]::IsNullOrWhiteSpace($entryName) -or [string]::IsNullOrEmpty([string]$zipEntry.Name) -or $entryName.EndsWith('/')) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveDirectoryEntry' -Message "Offline package ZIP contains an explicit or malformed directory entry: $entryName"
            }
            try { $relative = Assert-PshLifecycleRelativePath -Value $entryName -Description 'Offline package ZIP entry path' }
            catch { Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveEntryPath' -Message "Offline package ZIP contains an unsafe entry path: $entryName" -InnerException $_.Exception }
            if (-not $archivePaths.Add($relative)) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveDuplicateEntry' -Message "Offline package ZIP contains a case-insensitive duplicate entry: $relative"
            }

            [int64]$externalAttributes = [int64]$zipEntry.ExternalAttributes
            if ($externalAttributes -lt 0) { $externalAttributes += 4294967296 }
            [int64]$dosAttributes = $externalAttributes -band 65535
            [int64]$unixMode = ($externalAttributes -shr 16) -band 65535
            [int64]$unixType = $unixMode -band 61440
            if (($dosAttributes -band ([int][IO.FileAttributes]::Directory)) -ne 0 -or
                ($dosAttributes -band ([int][IO.FileAttributes]::ReparsePoint)) -ne 0 -or
                ($unixType -ne 0 -and $unixType -ne 32768)) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveEntryType' -Message "Offline package ZIP contains a link, directory, or special entry: $relative"
            }
            if (-not $packageFiles.ContainsKey($relative)) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchivePackageMissingFile' -Message "Extracted package is missing a file from its trusted archive: $relative"
            }
            $packageFile = $packageFiles[$relative]
            if ([string](Get-PshLifecycleProperty $packageFile 'RelativePath') -cne $relative) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveEntryPath' -Message "ZIP entry case does not match the extracted package path: $relative"
            }
            if ([int64]$zipEntry.Length -ne [int64](Get-PshLifecycleProperty $packageFile 'Length')) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveEntryLength' -Message "ZIP entry length does not match the extracted package file: $relative"
            }

            $entryStream = $null
            $entrySha = $null
            try {
                $entryStream = $zipEntry.Open()
                $entrySha = [Security.Cryptography.SHA256]::Create()
                $buffer = New-Object byte[] 65536
                [int64]$entryLength = 0
                while ($true) {
                    $read = $entryStream.Read($buffer, 0, $buffer.Length)
                    if ($read -eq 0) { break }
                    $entryLength += [int64]$read
                    if ($entryLength -gt [int64](Get-PshLifecycleProperty $packageFile 'Length')) {
                        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveEntryLength' -Message "ZIP entry expands beyond the extracted package file length: $relative"
                    }
                    [void]$entrySha.TransformBlock($buffer, 0, $read, $buffer, 0)
                }
                $empty = New-Object byte[] 0
                [void]$entrySha.TransformFinalBlock($empty, 0, 0)
                $entrySha256 = ([BitConverter]::ToString($entrySha.Hash)).Replace('-', '').ToLowerInvariant()
                if ($entryLength -ne [int64](Get-PshLifecycleProperty $packageFile 'Length') -or
                    $entrySha256 -cne [string](Get-PshLifecycleProperty $packageFile 'Sha256')) {
                    Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveEntryHash' -Message "ZIP entry bytes do not match the extracted package file: $relative"
                }
            }
            catch {
                if (Test-PshLifecycleExceptionMetadata $_) { throw }
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveEntryRead' -Message "Unable to read ZIP entry for archive binding: $relative" -InnerException $_.Exception
            }
            finally {
                if ($null -ne $entrySha) { try { $entrySha.Dispose() } catch { } }
                if ($null -ne $entryStream) { try { $entryStream.Dispose() } catch { } }
            }
            [void]$entryRecords.Add([pscustomobject][ordered]@{
                    relativePath = $relative
                    length = [int64](Get-PshLifecycleProperty $packageFile 'Length')
                    sha256 = [string](Get-PshLifecycleProperty $packageFile 'Sha256')
                })
        }

        [string[]]$packageNames = @($packageFiles.Keys)
        [Array]::Sort($packageNames, [StringComparer]::Ordinal)
        foreach ($packageName in $packageNames) {
            if (-not $archivePaths.Contains($packageName)) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchivePackageExtraFile' -Message "Extracted package contains a file missing from its trusted archive: $packageName"
            }
        }
        $result = [pscustomobject][ordered]@{
            PSTypeName = 'Psh.PackageArchiveBinding'
            Trusted = $true
            ArchiveBinding = 'verified'
            ArchivePath = $archiveFullPath
            ArchiveSha256 = $actualArchiveSha256
            FileCount = $entryRecords.Count
            Files = $entryRecords.ToArray()
        }
        if ($RetainLocks) {
            $result | Add-Member -NotePropertyName Released -NotePropertyValue $false
            $result | Add-Member -NotePropertyName PackageRecords -NotePropertyValue @((Get-PshLifecycleProperty $packageSnapshot 'Records'))
            $result | Add-Member -NotePropertyName Archive -NotePropertyValue $archive
            $result | Add-Member -NotePropertyName ArchiveStream -NotePropertyValue $archiveStream
            $result | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
                if ([bool]$this.Released) { return }
                foreach ($record in @($this.PackageRecords)) {
                    $stream = Get-PshLifecycleProperty $record 'Stream'
                    if ($stream -is [IDisposable]) { try { $stream.Dispose() } catch { } }
                }
                if ($this.Archive -is [IDisposable]) { try { $this.Archive.Dispose() } catch { } }
                if ($this.ArchiveStream -is [IDisposable]) { try { $this.ArchiveStream.Dispose() } catch { } }
                $this.Released = $true
                $this.PackageRecords = @()
                $this.Archive = $null
                $this.ArchiveStream = $null
            }
            $packageSnapshot = $null
            $archive = $null
            $archiveStream = $null
        }
        return $result
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveVerification' -Message 'Offline package archive verification failed closed.' -InnerException $_.Exception
    }
    finally {
        if ($null -ne $packageSnapshot) {
            Close-PshPackageArchiveBindingFiles -Records @((Get-PshLifecycleProperty $packageSnapshot 'Records'))
        }
        if ($null -ne $archive) { try { $archive.Dispose() } catch { } }
        if ($null -ne $archiveStream) { try { $archiveStream.Dispose() } catch { } }
    }
}

function Assert-PshReleaseRequiredProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $InputObject,
        [Parameter(Mandatory = $true)][string[]] $Required,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $present = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($propertyName in (Get-PshLifecyclePropertyNames -InputObject $InputObject)) {
        [void]$present.Add($propertyName)
    }
    foreach ($requiredName in $Required) {
        if (-not $present.Contains($requiredName)) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshMissingField' -Message "$Description is missing required field '$requiredName'."
        }
    }
}

function Assert-PshReleaseStringArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter()][switch] $AllowEmpty,
        [Parameter()][string] $Pattern
    )

    if ($Value -isnot [System.Array]) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseArray' -Message "$Description must be an array."
    }
    $result = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Value)) {
        if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$entry)) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseArray' -Message "$Description entries must be non-empty strings."
        }
        $text = [string]$entry
        if (-not [string]::IsNullOrWhiteSpace($Pattern) -and $text -cnotmatch $Pattern) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseArray' -Message "$Description contains an invalid value: $text"
        }
        if (-not $seen.Add($text)) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseDuplicate' -Message "$Description contains a duplicate value: $text"
        }
        [void]$result.Add($text)
    }
    if (-not $AllowEmpty -and $result.Count -eq 0) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseArray' -Message "$Description must not be empty."
    }
    return @($result.ToArray())
}

function Assert-PshReleaseLeafName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter()][AllowNull()][System.Collections.Generic.HashSet[string]] $Seen
    )

    if ($Value -isnot [string] -or [string]$Value -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,199}\z') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseAssetName' -Message "$Description must be a portable ASCII file name."
    }
    $name = Assert-PshLifecycleRelativePath -Value ([string]$Value) -Description $Description
    if ($name.Contains('/')) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseAssetName' -Message "$Description must not contain a directory: $name"
    }
    if ($null -ne $Seen -and -not $Seen.Add($name)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseAssetDuplicate' -Message "$Description is duplicated case-insensitively: $name"
    }
    return $name
}

function Assert-PshReleaseRepositoryUri {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Value)

    if ($Value -isnot [string] -or [string]$Value -cne $script:PshReleaseRepository) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseRepository' -Message "Release repository must be exactly '$($script:PshReleaseRepository)'."
    }
    return [string]$Value
}

function Assert-PshReleaseTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Version
    )

    $expected = 'v' + $Version
    if ($Value -isnot [string] -or [string]$Value -cne $expected -or [string]$Value -match '(?i)latest|refs/heads|/main|/master') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseTag' -Message "Release tag must be the fixed tag '$expected'."
    }
    return $expected
}

function Assert-PshReleaseAssetUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Tag,
        [Parameter(Mandatory = $true)][string] $AssetName
    )

    $expected = '{0}/releases/download/{1}/{2}' -f $Repository, $Tag, $AssetName
    if ($Value -isnot [string] -or [string]$Value -cne $expected) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseAssetUrl' -Message "Release asset URL must be exactly '$expected'."
    }
    try { $uri = New-Object -TypeName Uri -ArgumentList ([string]$Value, [UriKind]::Absolute) }
    catch { Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseAssetUrl' -Message "Release asset URL is invalid: $Value" -InnerException $_.Exception }
    if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'github.com' -or -not $uri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseAssetUrl' -Message "Release asset URL crosses the fixed HTTPS release boundary: $Value"
    }
    return $uri.AbsoluteUri
}

function Get-PshReleaseExpectedPackageName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][string] $Edition,
        [Parameter(Mandatory = $true)][string] $Architecture
    )

    if ($Edition -ceq 'Core') { return "psh-$Version-core.zip" }
    return "psh-$Version-full-$Architecture.zip"
}

function Read-PshReleaseIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter()][AllowNull()][object] $Snapshot
    )

    if ($null -eq $Snapshot) {
        $Snapshot = Read-PshStrictJsonSnapshot -Path $Path -Description 'Psh release index'
    }
    else {
        $snapshotPath = [string](Get-PshLifecycleProperty -InputObject $Snapshot -Name 'Path')
        if ([string]::IsNullOrWhiteSpace($snapshotPath) -or
            -not [string]::Equals([IO.Path]::GetFullPath($snapshotPath), [IO.Path]::GetFullPath($Path), (Get-PshLifecyclePathComparison))) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseIndexSnapshot' -Message 'Release index snapshot path does not match the requested path.'
        }
    }
    $document = Get-PshLifecycleProperty -InputObject $Snapshot -Name 'Document'
    Assert-PshLifecycleAllowedProperties -InputObject $document -Allowed $script:PshReleaseIndexKeys -Description 'Release index'
    Assert-PshReleaseRequiredProperties -InputObject $document -Required $script:PshReleaseIndexKeys -Description 'Release index'
    if ([int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $document 'schemaVersion') -Description 'Release index schemaVersion' -NonNegative) -ne 1) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseIndexSchema' -Message 'Release index schemaVersion must be 1.'
    }
    if ([string](Get-PshLifecycleProperty $document 'product') -cne 'Psh') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseIndexProduct' -Message 'Release index product must be Psh.'
    }
    $repository = Assert-PshReleaseRepositoryUri -Value (Get-PshLifecycleProperty $document 'repository')
    $version = Assert-PshLifecycleSemVer -Value (Get-PshLifecycleProperty $document 'version') -Description 'Release index version'
    $tag = Assert-PshReleaseTag -Value (Get-PshLifecycleProperty $document 'tag') -Version $version
    $sourceCommit = Get-PshLifecycleProperty $document 'sourceCommit'
    if ($sourceCommit -isnot [string] -or [string]$sourceCommit -cnotmatch '\A[0-9a-f]{40}\z') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseSourceCommit' -Message 'Release index sourceCommit must be a lowercase 40-character commit id.'
    }

    $assetsValue = Get-PshLifecycleProperty $document 'assets'
    if ($assetsValue -isnot [System.Array] -or @($assetsValue).Count -eq 0) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseAssets' -Message 'Release index assets must be a non-empty array.'
    }
    $assetNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $packageSlots = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $assets = New-Object System.Collections.Generic.List[object]
    foreach ($asset in @($assetsValue)) {
        Assert-PshLifecycleAllowedProperties -InputObject $asset -Allowed $script:PshReleaseAssetKeys -Description 'Release asset'
        Assert-PshReleaseRequiredProperties -InputObject $asset -Required $script:PshReleaseAssetKeys -Description 'Release asset'
        $name = Assert-PshReleaseLeafName -Value (Get-PshLifecycleProperty $asset 'name') -Description 'Release asset name' -Seen $assetNames
        $role = Get-PshLifecycleProperty $asset 'role'
        if ($role -isnot [string] -or [string]$role -cnotin $script:PshReleaseAssetRoles) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseAssetRole' -Message "Release asset '$name' has an invalid role."
        }
        $length = [int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $asset 'length') -Description "Release asset '$name' length" -NonNegative)
        if ($length -le 0) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseAssetLength' -Message "Release asset '$name' length must be positive."
        }
        $sha256 = Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $asset 'sha256') -Description "Release asset '$name' SHA256"
        $url = Assert-PshReleaseAssetUri -Value (Get-PshLifecycleProperty $asset 'url') -Repository $repository -Tag $tag -AssetName $name
        $packageValue = Get-PshLifecycleProperty $asset 'package'
        $package = $null
        if ([string]$role -ceq 'package') {
            Assert-PshLifecycleAllowedProperties -InputObject $packageValue -Allowed $script:PshReleasePackageKeys -Description "Release package '$name'"
            Assert-PshReleaseRequiredProperties -InputObject $packageValue -Required $script:PshReleasePackageKeys -Description "Release package '$name'"
            $packageVersion = Assert-PshLifecycleSemVer -Value (Get-PshLifecycleProperty $packageValue 'version') -Description "Release package '$name' version"
            if ($packageVersion -cne $version) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleasePackageVersion' -Message "Release package '$name' version does not match the release index."
            }
            $edition = Get-PshLifecycleProperty $packageValue 'edition'
            if ($edition -isnot [string] -or [string]$edition -cnotin @('Core', 'Full')) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleasePackageEdition' -Message "Release package '$name' edition must be Core or Full."
            }
            $architecture = Get-PshLifecycleProperty $packageValue 'architecture'
            if ($architecture -isnot [string] -or
                ([string]$edition -ceq 'Core' -and [string]$architecture -cne 'any') -or
                ([string]$edition -ceq 'Full' -and [string]$architecture -cnotin @('win-x64', 'win-arm64'))) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleasePackageArchitecture' -Message "Release package '$name' architecture is invalid for its edition."
            }
            $expectedName = Get-PshReleaseExpectedPackageName -Version $version -Edition ([string]$edition) -Architecture ([string]$architecture)
            if ($name -cne $expectedName) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleasePackageName' -Message "Release package '$name' must be named '$expectedName'."
            }
            $slot = '{0}|{1}' -f [string]$edition, [string]$architecture
            if (-not $packageSlots.Add($slot)) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleasePackageDuplicate' -Message "Release index contains duplicate package slot '$slot'."
            }
            $manifestSha256 = Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $packageValue 'packageManifestSha256') -Description "Release package '$name' manifest SHA256"
            $treeSha256 = Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $packageValue 'treeSha256') -Description "Release package '$name' tree SHA256"
            $testOnly = Get-PshLifecycleProperty $packageValue 'testOnly'
            if ($testOnly -isnot [bool]) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleasePackageTestOnly' -Message "Release package '$name' testOnly must be boolean."
            }
            $package = [pscustomobject][ordered]@{
                version = $packageVersion
                edition = [string]$edition
                architecture = [string]$architecture
                packageManifestSha256 = $manifestSha256
                treeSha256 = $treeSha256
                testOnly = [bool]$testOnly
            }
        }
        elseif ($null -ne $packageValue) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseAssetPackage' -Message "Non-package release asset '$name' must set package to null."
        }
        [void]$assets.Add([pscustomobject][ordered]@{
                name = $name
                role = [string]$role
                url = $url
                length = $length
                sha256 = $sha256
                package = $package
            })
    }
    $expectedIndexName = "psh-release-$version.json"
    if ([IO.Path]::GetFileName($Path) -cne $expectedIndexName) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseIndexName' -Message "Release index file must be named '$expectedIndexName'."
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        repository = $repository
        version = $version
        tag = $tag
        sourceCommit = [string]$sourceCommit
        assets = @($assets.ToArray())
    }
}

function Read-PshTrustTextSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $Path = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description
    $entry = Get-PshLifecyclePathEntry -Path $Path -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustFile' -Message "$Description must be a regular non-reparse file: $Path"
    }
    try {
        $stream = New-Object IO.FileStream($Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
        try {
            $memory = New-Object IO.MemoryStream
            try { $stream.CopyTo($memory); $bytes = $memory.ToArray() }
            finally { $memory.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch { Throw-PshReleaseTrustError -ExitCode 3 -ErrorId 'PshTrustFileRead' -Message "Unable to read ${Description}: $Path" -InnerException $_.Exception }
    return New-PshTrustTextSnapshotFromBytes -Path $Path -Bytes $bytes -Description $Description
}

function New-PshTrustTextSnapshotFromBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustFileBom' -Message "$Description must be UTF-8 without a BOM."
    }
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    try { $text = $encoding.GetString($Bytes) }
    catch { Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustFileUtf8' -Message "$Description is not valid UTF-8." -InnerException $_.Exception }
    return [pscustomobject][ordered]@{
        Path = [IO.Path]::GetFullPath($Path)
        Bytes = $Bytes
        Text = $text
        Length = [int64]$Bytes.Length
        Sha256 = Get-PshLifecycleSha256Bytes -Bytes $Bytes
    }
}

function Read-PshSha256Sums {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter()][AllowNull()][object] $Snapshot
    )

    if ([IO.Path]::GetFileName($Path) -cne 'SHA256SUMS') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshChecksumName' -Message 'Checksum file must be named exactly SHA256SUMS.'
    }
    if ($null -eq $Snapshot) { $Snapshot = Read-PshTrustTextSnapshot -Path $Path -Description 'SHA256SUMS' }
    $snapshotPath = [string](Get-PshLifecycleProperty $Snapshot 'Path')
    if ([string]::IsNullOrWhiteSpace($snapshotPath) -or
        -not [string]::Equals([IO.Path]::GetFullPath($snapshotPath), [IO.Path]::GetFullPath($Path), (Get-PshLifecyclePathComparison))) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshChecksumSnapshot' -Message 'SHA256SUMS snapshot path does not match the requested path.'
    }
    $text = [string](Get-PshLifecycleProperty $Snapshot 'Text')
    if ([string]::IsNullOrEmpty($text)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshChecksumEmpty' -Message 'SHA256SUMS must not be empty.'
    }
    $normalized = $text.Replace("`r`n", "`n")
    if ($normalized.Contains("`r") -or -not $normalized.EndsWith("`n", [StringComparison]::Ordinal)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshChecksumLineEnding' -Message 'SHA256SUMS must use LF or CRLF lines and end with one newline.'
    }
    $lines = @($normalized.Substring(0, $normalized.Length - 1).Split([char]10))
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '\A([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]{0,199})\z')
        if (-not $match.Success -or $match.Groups[1].Value -ceq ('0' * 64)) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshChecksumLine' -Message "SHA256SUMS contains an invalid line: $line"
        }
        $name = Assert-PshReleaseLeafName -Value $match.Groups[2].Value -Description 'SHA256SUMS asset name' -Seen $seen
        [void]$entries.Add([pscustomobject][ordered]@{ name = $name; sha256 = $match.Groups[1].Value })
    }
    if ($entries.Count -eq 0) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshChecksumEmpty' -Message 'SHA256SUMS must contain at least one entry.'
    }
    return [pscustomobject][ordered]@{ entries = @($entries.ToArray()) }
}

function Assert-PshReleaseIndexChecksums {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Index,
        [Parameter(Mandatory = $true)][object] $Checksums
    )

    $assets = @((Get-PshLifecycleProperty $Index 'assets'))
    $entries = @((Get-PshLifecycleProperty $Checksums 'entries'))
    if ($assets.Count -ne $entries.Count) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshChecksumSet' -Message 'SHA256SUMS entries do not exactly match release index assets.'
    }
    $byName = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) { $byName[[string]$entry.name] = $entry }
    foreach ($asset in $assets) {
        $name = [string]$asset.name
        if (-not $byName.ContainsKey($name)) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshChecksumMissing' -Message "SHA256SUMS is missing release asset '$name'."
        }
        $entry = $byName[$name]
        if ([string]$entry.name -cne $name -or [string]$entry.sha256 -cne [string]$asset.sha256) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshChecksumMismatch' -Message "SHA256SUMS does not match release asset '$name'."
        }
    }
    return $true
}

function Assert-PshPublisherPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Policy)

    Assert-PshLifecycleAllowedProperties -InputObject $Policy -Allowed $script:PshPublisherPolicyKeys -Description 'Publisher policy'
    Assert-PshReleaseRequiredProperties -InputObject $Policy -Required $script:PshPublisherPolicyKeys -Description 'Publisher policy'
    if ([int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $Policy 'schemaVersion') -Description 'Publisher policy schemaVersion' -NonNegative) -ne 1) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshPublisherPolicySchema' -Message 'Publisher policy schemaVersion must be 1.'
    }
    $publisher = Get-PshLifecycleProperty $Policy 'publisher'
    if ($publisher -isnot [string] -or [string]$publisher -cnotmatch '\A[\x20-\x7e]{1,128}\z') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshPublisherPolicyPublisher' -Message 'Publisher policy publisher must be printable ASCII.'
    }
    $subjects = Assert-PshReleaseStringArray -Value (Get-PshLifecycleProperty $Policy 'subjectDistinguishedNames') -Description 'Publisher subjectDistinguishedNames'
    $ekus = Assert-PshReleaseStringArray -Value (Get-PshLifecycleProperty $Policy 'requiredEkuOids') -Description 'Publisher requiredEkuOids' -Pattern '\A[0-9]+(?:\.[0-9]+)+\z'
    if ($ekus -cnotcontains $script:PshCodeSigningEku) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshPublisherPolicyEku' -Message "Publisher policy must require the code-signing EKU $($script:PshCodeSigningEku)."
    }
    $policyOids = Assert-PshReleaseStringArray -Value (Get-PshLifecycleProperty $Policy 'requiredCertificatePolicyOids') -Description 'Publisher requiredCertificatePolicyOids' -AllowEmpty -Pattern '\A[0-9]+(?:\.[0-9]+)+\z'
    $rootHashes = Assert-PshReleaseStringArray -Value (Get-PshLifecycleProperty $Policy 'allowedRootCertificateSha256') -Description 'Publisher allowedRootCertificateSha256' -Pattern '\A[0-9a-f]{64}\z'
    foreach ($hash in $rootHashes) {
        if ($hash -ceq ('0' * 64)) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshPublisherPolicyRoot' -Message 'Publisher policy contains an all-zero root certificate hash.'
        }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        publisher = [string]$publisher
        subjectDistinguishedNames = @($subjects)
        requiredEkuOids = @($ekus)
        requiredCertificatePolicyOids = @($policyOids)
        allowedRootCertificateSha256 = @($rootHashes)
    }
}

function Read-PshPublisherPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    $document = Read-PshStrictJsonDocument -Path $Path -Description 'Publisher policy'
    return Assert-PshPublisherPolicy -Policy $document
}

function Get-PshCertificateRawSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Security.Cryptography.X509Certificates.X509Certificate2] $Certificate)
    return Get-PshLifecycleSha256Bytes -Bytes $Certificate.RawData
}

function Get-PshCertificateOidValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [Parameter(Mandatory = $true)][string] $ExtensionOid
    )

    $values = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($extension in @($Certificate.Extensions)) {
        if ([string]$extension.Oid.Value -cne $ExtensionOid) { continue }
        if ($ExtensionOid -ceq '2.5.29.37') {
            try {
                $eku = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$extension
                foreach ($oid in @($eku.EnhancedKeyUsages)) { [void]$values.Add([string]$oid.Value) }
                continue
            }
            catch { }
        }
        foreach ($match in [regex]::Matches([string]$extension.Format($false), '(?<![0-9])(?:[0-9]+\.)+[0-9]+(?![0-9])')) {
            [void]$values.Add([string]$match.Value)
        }
    }
    return @($values)
}

function Assert-PshPublisherCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [Parameter(Mandatory = $true)][object] $PublisherPolicy
    )

    $policy = Assert-PshPublisherPolicy -Policy $PublisherPolicy
    if (@($policy.subjectDistinguishedNames | Where-Object { [string]::Equals($_, $Certificate.Subject, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshPublisherSubject' -Message "Signer subject is outside publisher policy: $($Certificate.Subject)"
    }
    $actualEkus = @(Get-PshCertificateOidValues -Certificate $Certificate -ExtensionOid '2.5.29.37')
    foreach ($required in @($policy.requiredEkuOids)) {
        if ($actualEkus -cnotcontains $required) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshPublisherEku' -Message "Signer certificate is missing required EKU '$required'."
        }
    }
    $actualPolicies = @(Get-PshCertificateOidValues -Certificate $Certificate -ExtensionOid '2.5.29.32')
    foreach ($required in @($policy.requiredCertificatePolicyOids)) {
        if ($actualPolicies -cnotcontains $required) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshPublisherCertificatePolicy' -Message "Signer certificate is missing required certificate policy '$required'."
        }
    }
    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    try {
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
        if ($null -ne $chain.ChainPolicy.PSObject.Properties['DisableCertificateDownloads']) {
            $chain.ChainPolicy.DisableCertificateDownloads = $true
        }
        [void]$chain.ChainPolicy.ApplicationPolicy.Add((New-Object Security.Cryptography.Oid($script:PshCodeSigningEku)))
        if (-not $chain.Build($Certificate) -or $chain.ChainElements.Count -eq 0) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshPublisherChain' -Message 'Signer certificate chain is not trusted by Windows.'
        }
        $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        $rootSha256 = Get-PshCertificateRawSha256 -Certificate $root
        if (@($policy.allowedRootCertificateSha256 | Where-Object { $_ -ceq $rootSha256 }).Count -ne 1) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshPublisherRoot' -Message "Signer root certificate is outside publisher policy: $rootSha256"
        }
    }
    finally { $chain.Dispose() }
    return [pscustomobject][ordered]@{ Trusted = $true; Publisher = [string]$policy.publisher; Subject = $Certificate.Subject }
}

function Invoke-PshWindowsCatalogTrustVerifier {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Request)

    if ([bool](Get-PshLifecycleProperty $Request 'Offline')) {
        Throw-PshReleaseTrustError -ExitCode 4 -ErrorId 'PshOfflineTrustUnavailable' -Message 'Offline catalog trust cannot guarantee cache-only Authenticode validation on this runtime.'
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Throw-PshReleaseTrustError -ExitCode 4 -ErrorId 'PshTrustVerifierUnavailable' -Message 'Windows Authenticode and file-catalog verification are unavailable on this platform.'
    }
    $signatureCommand = Get-Command -Name Get-AuthenticodeSignature -CommandType Cmdlet -ErrorAction SilentlyContinue
    $catalogCommand = Get-Command -Name Test-FileCatalog -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $signatureCommand -or $null -eq $catalogCommand) {
        Throw-PshReleaseTrustError -ExitCode 4 -ErrorId 'PshTrustVerifierUnavailable' -Message 'Required Windows Authenticode or file-catalog commands are unavailable.'
    }
    $catalogPath = Assert-PshLifecycleNoReparseAncestors -Path ([string](Get-PshLifecycleProperty $Request 'CatalogPath')) -Description 'release catalog snapshot'
    $contentRoot = Assert-PshLifecycleNoReparseAncestors -Path ([string](Get-PshLifecycleProperty $Request 'ContentRoot')) -Description 'release content snapshot root'
    $policy = Assert-PshPublisherPolicy -Policy (Get-PshLifecycleProperty $Request 'PublisherPolicy')
    $catalogEntry = Get-PshLifecyclePathEntry -Path $catalogPath -Description 'release catalog'
    if (-not [bool]$catalogEntry.IsRegularFile -or [bool]$catalogEntry.IsReparsePoint) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogFile' -Message "Catalog must be a regular non-reparse file: $catalogPath"
    }
    $contentEntry = Get-PshLifecyclePathEntry -Path $contentRoot -Description 'release content snapshot root'
    if (-not [bool]$contentEntry.Exists -or -not [bool]$contentEntry.IsDirectory -or [bool]$contentEntry.IsReparsePoint) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogContentRoot' -Message "Catalog content root must be a non-reparse directory: $contentRoot"
    }
    $signature = & $signatureCommand -FilePath $catalogPath -ErrorAction Stop
    if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogSignature' -Message "Catalog Authenticode signature is not valid: $($signature.Status)"
    }
    $publisher = Assert-PshPublisherCertificate -Certificate $signature.SignerCertificate -PublisherPolicy $policy
    $validation = & $catalogCommand -CatalogFilePath $catalogPath -Path $contentRoot -Detailed -ErrorAction Stop
    $status = if ($null -ne $validation.PSObject.Properties['Status']) { [string]$validation.Status } else { [string]$validation }
    if ($status -cne 'ValidationPassed') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogContent' -Message "Catalog content validation failed: $status"
    }
    return $publisher
}

function Invoke-PshWindowsCatalogMembershipVerifier {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Request)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Throw-PshReleaseTrustError -ExitCode 4 -ErrorId 'PshCatalogMembershipUnavailable' -Message 'Windows file-catalog membership verification is unavailable on this platform.'
    }
    $catalogCommand = Get-Command -Name Test-FileCatalog -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $catalogCommand) {
        Throw-PshReleaseTrustError -ExitCode 4 -ErrorId 'PshCatalogMembershipUnavailable' -Message 'Test-FileCatalog is unavailable on this Windows runtime.'
    }
    $catalogPath = Assert-PshLifecycleNoReparseAncestors -Path ([string](Get-PshLifecycleProperty $Request 'CatalogPath')) -Description 'catalog membership snapshot'
    $contentRoot = Assert-PshLifecycleNoReparseAncestors -Path ([string](Get-PshLifecycleProperty $Request 'ContentRoot')) -Description 'catalog membership content root'
    $catalogEntry = Get-PshLifecyclePathEntry -Path $catalogPath -Description 'catalog membership snapshot'
    if (-not [bool]$catalogEntry.Exists -or -not [bool]$catalogEntry.IsRegularFile -or [bool]$catalogEntry.IsReparsePoint) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogFile' -Message "Catalog must be a regular non-reparse file: $catalogPath"
    }
    $contentEntry = Get-PshLifecyclePathEntry -Path $contentRoot -Description 'catalog membership content root'
    if (-not [bool]$contentEntry.Exists -or -not [bool]$contentEntry.IsDirectory -or [bool]$contentEntry.IsReparsePoint) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogContentRoot' -Message "Catalog content root must be a non-reparse directory: $contentRoot"
    }
    try {
        $validation = & $catalogCommand -CatalogFilePath $catalogPath -Path $contentRoot -Detailed -ErrorAction Stop
    }
    catch {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogContent' -Message 'Catalog membership verification failed.' -InnerException $_.Exception
    }
    $status = if ($null -ne $validation -and $null -ne $validation.PSObject.Properties['Status']) { [string]$validation.Status } else { [string]$validation }
    if ($status -cne 'ValidationPassed') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogContent' -Message "Catalog content validation failed: $status"
    }
    return [pscustomobject][ordered]@{
        Trusted = $true
        CatalogMembership = 'verified'
        SignatureNotRequired = $true
    }
}

function Get-PshTrustStreamBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][IO.Stream] $Stream,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if (-not $Stream.CanRead -or -not $Stream.CanSeek) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustStream' -Message "$Description must remain readable and seekable."
    }
    try {
        $Stream.Position = 0
        $memory = New-Object IO.MemoryStream
        try {
            $Stream.CopyTo($memory)
            return (, $memory.ToArray())
        }
        finally { $memory.Dispose() }
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshReleaseTrustError -ExitCode 3 -ErrorId 'PshTrustStreamRead' -Message "Unable to read ${Description}." -InnerException $_.Exception
    }
    finally {
        if ($Stream.CanSeek) {
            try { $Stream.Position = 0 } catch { }
        }
    }
}

function Get-PshTrustStreamState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][IO.Stream] $Stream,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $bytes = Get-PshTrustStreamBytes -Stream $Stream -Description $Description
    return [pscustomobject][ordered]@{
        Bytes = $bytes
        Length = [int64]$bytes.Length
        Sha256 = Get-PshLifecycleSha256Bytes -Bytes $bytes
    }
}

function Open-PshTrustLockedSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $fullPath = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description
    $entry = Get-PshLifecyclePathEntry -Path $fullPath -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustSourceFile' -Message "$Description must be a regular non-reparse file: $fullPath"
    }
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($fullPath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
        $state = Get-PshTrustStreamState -Stream $stream -Description $Description
        return [pscustomobject][ordered]@{
            Path = $fullPath
            Description = $Description
            Stream = $stream
            Bytes = [byte[]]$state.Bytes
            Length = [int64]$state.Length
            Sha256 = [string]$state.Sha256
        }
    }
    catch {
        if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshReleaseTrustError -ExitCode 3 -ErrorId 'PshTrustSourceRead' -Message "Unable to lock and read ${Description}: $fullPath" -InnerException $_.Exception
    }
}

function Get-PshTrustPathState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $fullPath = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description
    $entry = Get-PshLifecyclePathEntry -Path $fullPath -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustSourceFile' -Message "$Description must remain a regular non-reparse file: $fullPath"
    }
    $stream = $null
    try {
        # Windows validates sharing in both directions. Snapshot files retain a
        # ReadWrite handle whose FileShare.Read lock blocks outside mutation, so
        # this read-only path probe must share Write with that existing handle.
        # The probe itself never writes, and the long-lived handle still denies
        # new writers and replacement while the hash CAS is in progress.
        $stream = New-Object IO.FileStream($fullPath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::ReadWrite))
        return Get-PshTrustStreamState -Stream $stream -Description $Description
    }
    finally {
        if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
    }
}

function Assert-PshTrustLockedFileStable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Record)

    $description = [string](Get-PshLifecycleProperty $Record 'Description')
    $path = [string](Get-PshLifecycleProperty $Record 'Path')
    try {
        $handleState = Get-PshTrustStreamState -Stream (Get-PshLifecycleProperty $Record 'Stream') -Description "$description locked handle"
        $pathState = Get-PshTrustPathState -Path $path -Description "$description path"
        if ([int64]$handleState.Length -ne [int64](Get-PshLifecycleProperty $Record 'Length') -or
            [string]$handleState.Sha256 -cne [string](Get-PshLifecycleProperty $Record 'Sha256') -or
            [int64]$pathState.Length -ne [int64](Get-PshLifecycleProperty $Record 'Length') -or
            [string]$pathState.Sha256 -cne [string](Get-PshLifecycleProperty $Record 'Sha256')) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustSnapshotChanged' -Message "$description changed while trust verification was in progress: $path"
        }
    }
    catch {
        $metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $_
        if ([string]$metadata.ErrorId -ceq 'PshTrustSnapshotChanged') { throw }
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustSnapshotChanged' -Message "$description changed while trust verification was in progress: $path" -InnerException $_.Exception
    }
    return $true
}

function New-PshTrustSnapshotFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter(Mandatory = $true)][string] $Role
    )

    $fullPath = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($fullPath, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::Read))
        $stream.Write($Bytes, 0, $Bytes.Length)
        try { $stream.Flush($true) } catch { $stream.Flush() }
        $state = Get-PshTrustStreamState -Stream $stream -Description $Description
        if ([int64]$state.Length -ne [int64]$Bytes.Length -or [string]$state.Sha256 -cne (Get-PshLifecycleSha256Bytes -Bytes $Bytes)) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustSnapshotWrite' -Message "$Description did not preserve the locked source bytes."
        }
        return [pscustomobject][ordered]@{
            Path = $fullPath
            Description = $Description
            Role = $Role
            Stream = $stream
            Bytes = [byte[]]$state.Bytes
            Length = [int64]$state.Length
            Sha256 = [string]$state.Sha256
        }
    }
    catch {
        if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshReleaseTrustError -ExitCode 3 -ErrorId 'PshTrustSnapshotWrite' -Message "Unable to create ${Description}: $fullPath" -InnerException $_.Exception
    }
}

function Close-PshTrustFileRecords {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]] $Records)

    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $stream = Get-PshLifecycleProperty $record 'Stream'
        if ($stream -is [IDisposable]) { try { $stream.Dispose() } catch { } }
    }
}

function Remove-PshTrustSnapshotContext {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object] $Context)

    if ($null -eq $Context) { return }
    $files = @((Get-PshLifecycleProperty $Context 'Files'))
    Close-PshTrustFileRecords -Records $files
    foreach ($file in $files) {
        $path = [string](Get-PshLifecycleProperty $file 'Path')
        try {
            [void](Assert-PshLifecycleNoReparseAncestors -Path $path -Description 'trust snapshot cleanup file')
            $entry = Get-PshLifecyclePathEntry -Path $path -Description 'trust snapshot cleanup file'
            if (-not [bool]$entry.Exists) { continue }
            if (-not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) { continue }
            $state = Get-PshTrustPathState -Path $path -Description 'trust snapshot cleanup file'
            if ([int64]$state.Length -eq [int64](Get-PshLifecycleProperty $file 'Length') -and
                [string]$state.Sha256 -ceq [string](Get-PshLifecycleProperty $file 'Sha256')) {
                [IO.File]::Delete($path)
            }
        }
        catch { }
    }
    foreach ($directory in @((Get-PshLifecycleProperty $Context 'ContentRoot'), (Get-PshLifecycleProperty $Context 'Root'))) {
        if ([string]::IsNullOrWhiteSpace([string]$directory)) { continue }
        try {
            [void](Assert-PshLifecycleNoReparseAncestors -Path ([string]$directory) -Description 'trust snapshot cleanup directory')
            $entry = Get-PshLifecyclePathEntry -Path ([string]$directory) -Description 'trust snapshot cleanup directory'
            if ([bool]$entry.Exists -and [bool]$entry.IsDirectory -and -not [bool]$entry.IsReparsePoint) {
                [IO.Directory]::Delete([string]$directory, $false)
            }
        }
        catch { }
    }
}

function New-PshTrustSnapshotContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]] $ContentFiles,
        [Parameter(Mandatory = $true)][object] $CatalogSource
    )

    $tempBase = Assert-PshLifecycleNoReparseAncestors -Path ([IO.Path]::GetTempPath()) -Description 'trust snapshot temporary base'
    $tempEntry = Get-PshLifecyclePathEntry -Path $tempBase -Description 'trust snapshot temporary base'
    if (-not [bool]$tempEntry.Exists -or -not [bool]$tempEntry.IsDirectory -or [bool]$tempEntry.IsReparsePoint) {
        Throw-PshReleaseTrustError -ExitCode 3 -ErrorId 'PshTrustSnapshotTemp' -Message "Trust snapshot temporary base must be a non-reparse directory: $tempBase"
    }
    $root = Join-Path $tempBase ('psh-release-trust-' + [Guid]::NewGuid().ToString('N'))
    $contentRoot = Join-Path $root 'content'
    $files = New-Object System.Collections.ArrayList
    $context = [pscustomobject][ordered]@{ Root = $root; ContentRoot = $contentRoot; Catalog = $null; Files = $files }
    try {
        [void](Assert-PshLifecycleNoReparseAncestors -Path $root -Description 'trust snapshot root')
        [void][IO.Directory]::CreateDirectory($root)
        [void](Assert-PshLifecycleNoReparseAncestors -Path $root -Description 'trust snapshot root')
        [void][IO.Directory]::CreateDirectory($contentRoot)
        [void](Assert-PshLifecycleNoReparseAncestors -Path $contentRoot -Description 'trust snapshot content root')
        foreach ($contentFile in $ContentFiles) {
            $name = Assert-PshReleaseLeafName -Value (Get-PshLifecycleProperty $contentFile 'Name') -Description 'trust snapshot content file name'
            $source = Get-PshLifecycleProperty $contentFile 'Source'
            $role = [string](Get-PshLifecycleProperty $contentFile 'Role')
            $snapshot = New-PshTrustSnapshotFile -Path (Join-Path $contentRoot $name) -Bytes ([byte[]](Get-PshLifecycleProperty $source 'Bytes')) -Description "trust snapshot $role" -Role $role
            [void]$files.Add($snapshot)
        }
        $catalogName = Assert-PshReleaseLeafName -Value ([IO.Path]::GetFileName([string](Get-PshLifecycleProperty $CatalogSource 'Path'))) -Description 'trust snapshot catalog file name'
        $catalog = New-PshTrustSnapshotFile -Path (Join-Path $root $catalogName) -Bytes ([byte[]](Get-PshLifecycleProperty $CatalogSource 'Bytes')) -Description 'trust snapshot catalog' -Role 'catalog'
        [void]$files.Add($catalog)
        $context.Catalog = $catalog
        return $context
    }
    catch {
        Remove-PshTrustSnapshotContext -Context $context
        throw
    }
}

function Assert-PshTrustSnapshotContextStable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]] $Sources,
        [Parameter(Mandatory = $true)][object] $Context
    )

    foreach ($directory in @((Get-PshLifecycleProperty $Context 'Root'), (Get-PshLifecycleProperty $Context 'ContentRoot'))) {
        try {
            $path = Assert-PshLifecycleNoReparseAncestors -Path ([string]$directory) -Description 'trust snapshot directory'
            $entry = Get-PshLifecyclePathEntry -Path $path -Description 'trust snapshot directory'
            if (-not [bool]$entry.Exists -or -not [bool]$entry.IsDirectory -or [bool]$entry.IsReparsePoint) {
                Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustSnapshotChanged' -Message "Trust snapshot directory changed during verification: $path"
            }
        }
        catch {
            $metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $_
            if ([string]$metadata.ErrorId -ceq 'PshTrustSnapshotChanged') { throw }
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustSnapshotChanged' -Message "Trust snapshot directory changed during verification: $directory" -InnerException $_.Exception
        }
    }
    foreach ($record in @($Sources) + @((Get-PshLifecycleProperty $Context 'Files'))) {
        [void](Assert-PshTrustLockedFileStable -Record $record)
    }
    return $true
}

function Invoke-PshCatalogTrustVerifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Context,
        [Parameter(Mandatory = $true)][object] $PublisherPolicy,
        [Parameter()][switch] $Offline
    )

    $policy = Assert-PshPublisherPolicy -Policy $PublisherPolicy
    $snapshotFiles = @((Get-PshLifecycleProperty $Context 'Files') | ForEach-Object {
            [pscustomobject][ordered]@{
                Role = [string](Get-PshLifecycleProperty $_ 'Role')
                Path = [string](Get-PshLifecycleProperty $_ 'Path')
                Length = [int64](Get-PshLifecycleProperty $_ 'Length')
                Sha256 = [string](Get-PshLifecycleProperty $_ 'Sha256')
            }
        })
    $request = [pscustomobject][ordered]@{
        CatalogPath = [string](Get-PshLifecycleProperty (Get-PshLifecycleProperty $Context 'Catalog') 'Path')
        ContentRoot = [string](Get-PshLifecycleProperty $Context 'ContentRoot')
        PublisherPolicy = $policy
        Offline = [bool]$Offline
        SnapshotFiles = $snapshotFiles
    }
    try {
        $results = @(Invoke-PshWindowsCatalogTrustVerifier -Request $request)
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustVerifierFailed' -Message 'Catalog trust verifier failed closed.' -InnerException $_.Exception
    }
    if ($results.Count -ne 1) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustVerifierResult' -Message 'Catalog trust verifier must return exactly one result.'
    }
    $result = $results[0]
    $trusted = Get-PshLifecycleProperty $result 'Trusted'
    $publisher = Get-PshLifecycleProperty $result 'Publisher'
    if ($trusted -isnot [bool] -or -not [bool]$trusted -or $publisher -isnot [string] -or [string]$publisher -cne [string]$policy.publisher) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshTrustVerifierResult' -Message 'Catalog trust verifier did not authenticate the configured publisher.'
    }
    return $result
}

function Invoke-PshProductionCatalogMembershipVerifier {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Context)

    $request = [pscustomobject][ordered]@{
        CatalogPath = [string](Get-PshLifecycleProperty (Get-PshLifecycleProperty $Context 'Catalog') 'Path')
        ContentRoot = [string](Get-PshLifecycleProperty $Context 'ContentRoot')
        Offline = $true
    }
    try {
        $results = @(Invoke-PshWindowsCatalogMembershipVerifier -Request $request)
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogMembershipFailed' -Message 'Catalog membership verifier failed closed.' -InnerException $_.Exception
    }
    if ($results.Count -ne 1 -or (Get-PshLifecycleProperty $results[0] 'Trusted') -isnot [bool] -or
        -not [bool](Get-PshLifecycleProperty $results[0] 'Trusted') -or
        [string](Get-PshLifecycleProperty $results[0] 'CatalogMembership') -cne 'verified') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogMembershipResult' -Message 'Catalog membership verifier did not return one verified result.'
    }
    return $results[0]
}

function Assert-PshReleaseMetadataFileState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Metadata,
        [Parameter(Mandatory = $true)][object] $Source
    )

    $name = [IO.Path]::GetFileName([string](Get-PshLifecycleProperty $Source 'Path'))
    $assetMatches = @((Get-PshLifecycleProperty $Metadata 'Assets') | Where-Object { [string]$_.name -ceq $name })
    if ($assetMatches.Count -ne 1) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataAsset' -Message "Trusted release metadata does not contain '$name'."
    }
    $expected = $assetMatches[0]
    if ([int64](Get-PshLifecycleProperty $Source 'Length') -ne [int64](Get-PshLifecycleProperty $expected 'length') -or
        [string](Get-PshLifecycleProperty $Source 'Sha256') -cne [string](Get-PshLifecycleProperty $expected 'sha256')) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataDigestMismatch' -Message "Release bootstrap asset '$name' does not match its GitHub release SHA256 digest and length."
    }
    return $true
}

function Get-PshProductionPublisherPolicy {
    [CmdletBinding()]
    param()

    return Get-PshProductionTrustPolicy
}

function Get-PshAuthenticodePublisherPolicy {
    [CmdletBinding()]
    param()

    Throw-PshReleaseTrustError -ExitCode 4 -ErrorId 'PshPublisherPolicyUnavailable' -Message 'The production publisher certificate policy has not been provisioned in this source tree.'
}

function Copy-PshReleaseTrustData {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)

    if ($null -eq $InputObject) { return $null }
    $json = ConvertTo-PshCanonicalJson -InputObject $InputObject
    return ($json | ConvertFrom-Json -ErrorAction Stop)
}

function Complete-PshProductionArchiveTrustReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $InputObject,
        [Parameter(Mandatory = $true)][string] $TrustMode,
        [Parameter(Mandatory = $true)][string] $Checksum,
        [Parameter(Mandatory = $true)][string] $ArchiveSha256
    )

    $report = Copy-PshReleaseTrustData -InputObject $InputObject
    if ([string](Get-PshLifecycleProperty $report 'catalogMembership') -cne 'verified' -or
        (Get-PshLifecycleProperty $report 'signatureNotRequired') -isnot [bool] -or
        -not [bool](Get-PshLifecycleProperty $report 'signatureNotRequired')) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshArchiveTrustReport' -Message 'Archive binding requires a verified hash-policy package trust report.'
    }
    if ($ArchiveSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $ArchiveSha256 -ceq ('0' * 64)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshOfflineArchiveSha256' -Message 'Completed archive trust requires a non-zero lowercase SHA256 value.'
    }
    return New-PshProductionTrustReport -TrustMode $TrustMode -Checksum $Checksum -CatalogMembership 'verified' -SignatureNotRequired $true -ArchiveBinding 'verified' -ArchiveSha256 $ArchiveSha256 -AttestationVerification 'external-release-gate'
}

function Get-PshTrustedReleaseRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)

    $record = $null
    $token = Get-PshLifecycleProperty $InputObject 'TrustToken'
    if ($null -eq $token -or -not [object]::ReferenceEquals($token, $script:PshReleaseTrustToken) -or
        -not $script:PshTrustedReleaseRegistry.TryGetValue($InputObject, [ref]$record)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshUntrustedRelease' -Message 'A production-policy trusted release object is required.'
    }
    return Copy-PshReleaseTrustData -InputObject $record
}

function Get-PshTrustedPackageRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)

    $record = $null
    $token = Get-PshLifecycleProperty $InputObject 'TrustToken'
    if ($null -eq $token -or -not [object]::ReferenceEquals($token, $script:PshPackageTrustToken) -or
        -not $script:PshTrustedPackageRegistry.TryGetValue($InputObject, [ref]$record)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshUntrustedPackageManifest' -Message 'A production-policy trusted package manifest object is required.'
    }
    return Copy-PshReleaseTrustData -InputObject $record
}

function Invoke-PshReleaseTrustBundleCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $IndexPath,
        [Parameter(Mandatory = $true)][string] $ChecksumPath,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter()][AllowNull()][object] $TrustedMetadata,
        [Parameter()][switch] $Offline
    )

    $metadata = if ($null -eq $TrustedMetadata) { $null } else { Assert-PshTrustedReleaseMetadata -InputObject $TrustedMetadata }
    $publisherPolicy = if ($null -eq $metadata) { Get-PshAuthenticodePublisherPolicy } else { $null }
    $sources = New-Object System.Collections.ArrayList
    $context = $null
    try {
        $indexSource = Open-PshTrustLockedSource -Path $IndexPath -Description 'Psh release index source'
        [void]$sources.Add($indexSource)
        $checksumSource = Open-PshTrustLockedSource -Path $ChecksumPath -Description 'SHA256SUMS source'
        [void]$sources.Add($checksumSource)
        $catalogSource = Open-PshTrustLockedSource -Path $CatalogPath -Description 'release catalog source'
        [void]$sources.Add($catalogSource)
        $context = New-PshTrustSnapshotContext -ContentFiles @(
            [pscustomobject]@{ Name = [IO.Path]::GetFileName([string]$indexSource.Path); Role = 'index'; Source = $indexSource },
            [pscustomobject]@{ Name = [IO.Path]::GetFileName([string]$checksumSource.Path); Role = 'checksums'; Source = $checksumSource }
        ) -CatalogSource $catalogSource
        [void](Assert-PshTrustSnapshotContextStable -Sources @($sources) -Context $context)
        if ($null -ne $metadata) {
            [void](Assert-PshReleaseMetadataFileState -Metadata $metadata -Source $indexSource)
            [void](Assert-PshReleaseMetadataFileState -Metadata $metadata -Source $checksumSource)
            [void](Assert-PshReleaseMetadataFileState -Metadata $metadata -Source $catalogSource)
            $trust = Invoke-PshProductionCatalogMembershipVerifier -Context $context
            $trustReport = New-PshProductionTrustReport -TrustMode 'github-release-asset-digest' -Checksum 'github-release-sha256-verified' -CatalogMembership 'verified' -SignatureNotRequired $true -ArchiveBinding 'not-applicable' -AttestationVerification 'external-release-gate'
            $publisher = $null
        }
        else {
            $trust = Invoke-PshCatalogTrustVerifier -Context $context -PublisherPolicy $publisherPolicy -Offline:$Offline
            $trustReport = New-PshProductionTrustReport -TrustMode 'authenticode-publisher-catalog' -Checksum 'catalog-sha256-verified' -CatalogMembership 'verified' -SignatureNotRequired $false -ArchiveBinding 'not-applicable' -AttestationVerification 'not-required'
            $publisher = [string](Get-PshLifecycleProperty $trust 'Publisher')
        }
        [void](Assert-PshTrustSnapshotContextStable -Sources @($sources) -Context $context)

        $indexSnapshot = New-PshStrictJsonSnapshotFromBytes -Path ([string]$indexSource.Path) -Bytes ([byte[]]$indexSource.Bytes) -Description 'Psh release index'
        $checksumSnapshot = New-PshTrustTextSnapshotFromBytes -Path ([string]$checksumSource.Path) -Bytes ([byte[]]$checksumSource.Bytes) -Description 'SHA256SUMS'
        $index = Read-PshReleaseIndex -Path ([string]$indexSource.Path) -Snapshot $indexSnapshot
        $checksums = Read-PshSha256Sums -Path ([string]$checksumSource.Path) -Snapshot $checksumSnapshot
        [void](Assert-PshReleaseIndexChecksums -Index $index -Checksums $checksums)
        if ($null -ne $metadata -and
            ([string]$index.repository -cne [string]$metadata.Repository -or
             [string]$index.version -cne [string]$metadata.Version -or
             [string]$index.tag -cne [string]$metadata.Tag)) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshReleaseMetadataIdentity' -Message 'Release index repository, version, or tag does not match the trusted GitHub release metadata.'
        }
        $record = [pscustomobject][ordered]@{
            Trusted = $true
            Publisher = $publisher
            Repository = $script:PshReleaseRepository
            Trust = $trustReport
            Index = $index
            Checksums = $checksums
            IndexSha256 = [string]$indexSnapshot.Sha256
            ChecksumsSha256 = [string]$checksumSnapshot.Sha256
        }
        $handle = [pscustomobject][ordered]@{
            PSTypeName = 'Psh.TrustedRelease'
            TrustToken = $script:PshReleaseTrustToken
            Trusted = $true
            Publisher = $record.Publisher
            Repository = [string]$record.Repository
            Trust = Copy-PshReleaseTrustData -InputObject $record.Trust
            Index = Copy-PshReleaseTrustData -InputObject $record.Index
            Checksums = Copy-PshReleaseTrustData -InputObject $record.Checksums
            IndexSha256 = [string]$record.IndexSha256
            ChecksumsSha256 = [string]$record.ChecksumsSha256
        }
        [void]$script:PshTrustedReleaseRegistry.Add($handle, $record)
        return $handle
    }
    finally {
        Remove-PshTrustSnapshotContext -Context $context
        Close-PshTrustFileRecords -Records @($sources)
    }
}

function Confirm-PshReleaseTrustBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $IndexPath,
        [Parameter(Mandatory = $true)][string] $ChecksumPath,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter()][AllowNull()][object] $TrustedMetadata,
        [Parameter()][switch] $Offline
    )

    return Invoke-PshReleaseTrustBundleCore -IndexPath $IndexPath -ChecksumPath $ChecksumPath -CatalogPath $CatalogPath -TrustedMetadata $TrustedMetadata -Offline:$Offline
}

function Test-PshTrustedRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)
    $record = $null
    $token = Get-PshLifecycleProperty $InputObject 'TrustToken'
    return ($null -ne $token -and [object]::ReferenceEquals($token, $script:PshReleaseTrustToken) -and
        $script:PshTrustedReleaseRegistry.TryGetValue($InputObject, [ref]$record))
}

function Assert-PshTrustedRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)
    return Get-PshTrustedReleaseRecord -InputObject $InputObject
}

function Assert-PshManifestMatchesReleaseAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][string] $ManifestSha256,
        [Parameter(Mandatory = $true)][object] $Asset,
        [Parameter()][AllowNull()][object] $ReleaseIndex
    )

    if ([string](Get-PshLifecycleProperty $Asset 'role') -cne 'package' -or $null -eq (Get-PshLifecycleProperty $Asset 'package')) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshManifestAsset' -Message 'Expected release asset is not a package.'
    }
    $package = Get-PshLifecycleProperty $Asset 'package'
    if ($ManifestSha256 -cne [string](Get-PshLifecycleProperty $package 'packageManifestSha256') -or
        [string]$Manifest.version -cne [string]$package.version -or
        [string]$Manifest.edition -cne [string]$package.edition -or
        [string]$Manifest.architecture -cne [string]$package.architecture -or
        [string]$Manifest.treeSha256 -cne [string]$package.treeSha256 -or
        [bool]$Manifest.testOnly -ne [bool]$package.testOnly) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshManifestReleaseMismatch' -Message 'Package manifest does not match its authenticated release asset metadata.'
    }
    if ($null -ne $ReleaseIndex) {
        if ([string]$Manifest.source.repository -cne [string]$ReleaseIndex.repository -or
            [string]$Manifest.source.commit -cne [string]$ReleaseIndex.sourceCommit) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshManifestSourceMismatch' -Message 'Package manifest source does not match its authenticated release index.'
        }
    }
    return $true
}

function Invoke-PshPackageManifestTrustCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ManifestPath,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter()][AllowNull()][object] $ExpectedAsset,
        [Parameter()][AllowNull()][object] $TrustedRelease,
        [Parameter()][switch] $Offline
    )

    if ([IO.Path]::GetFileName($ManifestPath) -cne 'package.manifest.json') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshManifestFileName' -Message 'Package manifest file must be named exactly package.manifest.json.'
    }
    if ([IO.Path]::GetFileName($CatalogPath) -cne 'package.manifest.cat') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogFileName' -Message 'Package catalog file must be named exactly package.manifest.cat.'
    }
    $releaseIndex = $null
    $trusted = $null
    if ($null -ne $TrustedRelease) {
        $trusted = Assert-PshTrustedRelease -InputObject $TrustedRelease
        $releaseIndex = Get-PshLifecycleProperty $trusted 'Index'
    }
    if ($null -ne $ExpectedAsset -and $null -eq $TrustedRelease) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshManifestAssetTrust' -Message 'Expected release asset metadata requires its trusted release object.'
    }
    if ($null -ne $ExpectedAsset) {
        $expectedName = Get-PshLifecycleProperty $ExpectedAsset 'name'
        if ($expectedName -isnot [string]) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshManifestAssetTrust' -Message 'Expected release asset metadata has no authenticated asset name.'
        }
        $authenticatedAssets = @((Get-PshLifecycleProperty $releaseIndex 'assets') | Where-Object { [string]$_.name -ceq [string]$expectedName })
        if ($authenticatedAssets.Count -ne 1) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshManifestAssetTrust' -Message "Expected package asset '$expectedName' is not present in the authenticated release index."
        }
        $ExpectedAsset = $authenticatedAssets[0]
    }
    $releaseTrustMode = if ($null -eq $trusted) { $null } else { [string](Get-PshLifecycleProperty (Get-PshLifecycleProperty $trusted 'Trust') 'trustMode') }
    $useHashPolicy = [bool]$Offline -or $releaseTrustMode -ceq 'github-release-asset-digest'
    if ($useHashPolicy -and -not [bool]$Offline -and $null -eq $ExpectedAsset) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshManifestAssetTrust' -Message 'Online hash trust requires package metadata from its trusted release asset.'
    }
    $publisherPolicy = if ($useHashPolicy) { $null } else { Get-PshAuthenticodePublisherPolicy }
    $sources = New-Object System.Collections.ArrayList
    $context = $null
    try {
        $manifestSource = Open-PshTrustLockedSource -Path $ManifestPath -Description 'package manifest source'
        [void]$sources.Add($manifestSource)
        $catalogSource = Open-PshTrustLockedSource -Path $CatalogPath -Description 'package catalog source'
        [void]$sources.Add($catalogSource)
        $context = New-PshTrustSnapshotContext -ContentFiles @(
            [pscustomobject]@{ Name = 'package.manifest.json'; Role = 'manifest'; Source = $manifestSource }
        ) -CatalogSource $catalogSource
        [void](Assert-PshTrustSnapshotContextStable -Sources @($sources) -Context $context)
        if ($useHashPolicy) {
            $trust = Invoke-PshProductionCatalogMembershipVerifier -Context $context
            if ([bool]$Offline) {
                $trustReport = New-PshProductionTrustReport -TrustMode 'offline-external-archive-sha256+package-catalog-sha256' -Checksum 'archive-binding-required' -CatalogMembership 'verified' -SignatureNotRequired $true -ArchiveBinding 'required-at-entry' -AttestationVerification 'external-release-gate'
            }
            else {
                $trustReport = New-PshProductionTrustReport -TrustMode 'github-release-asset-digest+archive-binding+package-catalog-sha256' -Checksum 'archive-binding-required' -CatalogMembership 'verified' -SignatureNotRequired $true -ArchiveBinding 'required-at-entry' -AttestationVerification 'external-release-gate'
            }
            $publisher = $null
        }
        else {
            $trust = Invoke-PshCatalogTrustVerifier -Context $context -PublisherPolicy $publisherPolicy -Offline:$Offline
            $trustReport = New-PshProductionTrustReport -TrustMode 'authenticode-publisher-catalog' -Checksum 'manifest-and-tree-sha256-verified' -CatalogMembership 'verified' -SignatureNotRequired $false -ArchiveBinding 'not-applicable' -AttestationVerification 'not-required'
            $publisher = [string](Get-PshLifecycleProperty $trust 'Publisher')
        }
        [void](Assert-PshTrustSnapshotContextStable -Sources @($sources) -Context $context)

        $snapshot = New-PshStrictJsonSnapshotFromBytes -Path ([string]$manifestSource.Path) -Bytes ([byte[]]$manifestSource.Bytes) -Description 'Package manifest'
        $manifest = Read-PshPackageManifest -Path ([string]$manifestSource.Path) -Snapshot $snapshot
        if ([string]$manifest.source.repository -cne $script:PshReleaseRepository) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshManifestSourceMismatch' -Message "Package manifest source.repository must be exactly '$($script:PshReleaseRepository)'."
        }
        if ($null -ne $ExpectedAsset) {
            [void](Assert-PshManifestMatchesReleaseAsset -Manifest $manifest -ManifestSha256 ([string]$snapshot.Sha256) -Asset $ExpectedAsset -ReleaseIndex $releaseIndex)
        }
        $record = [pscustomobject][ordered]@{
            Trusted = $true
            Publisher = $publisher
            Repository = $script:PshReleaseRepository
            Trust = $trustReport
            Manifest = $manifest
            ManifestSha256 = [string]$snapshot.Sha256
            ManifestLength = [int64]$snapshot.Length
        }
        $handle = [pscustomobject][ordered]@{
            PSTypeName = 'Psh.TrustedPackageManifest'
            TrustToken = $script:PshPackageTrustToken
            Trusted = $true
            Publisher = $record.Publisher
            Repository = [string]$record.Repository
            Trust = Copy-PshReleaseTrustData -InputObject $record.Trust
            Manifest = Copy-PshReleaseTrustData -InputObject $record.Manifest
            ManifestSha256 = [string]$record.ManifestSha256
            ManifestLength = [int64]$record.ManifestLength
        }
        [void]$script:PshTrustedPackageRegistry.Add($handle, $record)
        return $handle
    }
    finally {
        Remove-PshTrustSnapshotContext -Context $context
        Close-PshTrustFileRecords -Records @($sources)
    }
}

function Confirm-PshPackageManifestTrust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ManifestPath,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter()][AllowNull()][object] $ExpectedAsset,
        [Parameter()][AllowNull()][object] $TrustedRelease,
        [Parameter()][switch] $Offline
    )

    return Invoke-PshPackageManifestTrustCore -ManifestPath $ManifestPath -CatalogPath $CatalogPath -ExpectedAsset $ExpectedAsset -TrustedRelease $TrustedRelease -Offline:$Offline
}

function Test-PshTrustedPackageManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)
    $record = $null
    $token = Get-PshLifecycleProperty $InputObject 'TrustToken'
    return ($null -ne $token -and [object]::ReferenceEquals($token, $script:PshPackageTrustToken) -and
        $script:PshTrustedPackageRegistry.TryGetValue($InputObject, [ref]$record))
}

function Assert-PshTrustedPackageManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)

    return Get-PshTrustedPackageRecord -InputObject $InputObject
}
