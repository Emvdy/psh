# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
    Release trust primitives.  Parsing and hashing do not establish source
    trust: callers receive a trusted release or package object only after the
    production publisher policy and Windows catalog verifier authenticate the
    exact snapshot bytes used by the strict parsers below.
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

function Get-PshProductionPublisherPolicy {
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

function Get-PshTrustedReleaseRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)

    $record = $null
    $token = Get-PshLifecycleProperty $InputObject 'TrustToken'
    if ($null -eq $token -or -not [object]::ReferenceEquals($token, $script:PshReleaseTrustToken) -or
        -not $script:PshTrustedReleaseRegistry.TryGetValue($InputObject, [ref]$record)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshUntrustedRelease' -Message 'A publisher-authenticated trusted release object is required; HTTPS or a bare SHA256 is not source trust.'
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
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshUntrustedPackageManifest' -Message 'A publisher-authenticated trusted package manifest object is required.'
    }
    return Copy-PshReleaseTrustData -InputObject $record
}

function Invoke-PshReleaseTrustBundleCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $IndexPath,
        [Parameter(Mandatory = $true)][string] $ChecksumPath,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter()][switch] $Offline
    )

    $publisherPolicy = Get-PshProductionPublisherPolicy
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
        $trust = Invoke-PshCatalogTrustVerifier -Context $context -PublisherPolicy $publisherPolicy -Offline:$Offline
        [void](Assert-PshTrustSnapshotContextStable -Sources @($sources) -Context $context)

        $indexSnapshot = New-PshStrictJsonSnapshotFromBytes -Path ([string]$indexSource.Path) -Bytes ([byte[]]$indexSource.Bytes) -Description 'Psh release index'
        $checksumSnapshot = New-PshTrustTextSnapshotFromBytes -Path ([string]$checksumSource.Path) -Bytes ([byte[]]$checksumSource.Bytes) -Description 'SHA256SUMS'
        $index = Read-PshReleaseIndex -Path ([string]$indexSource.Path) -Snapshot $indexSnapshot
        $checksums = Read-PshSha256Sums -Path ([string]$checksumSource.Path) -Snapshot $checksumSnapshot
        [void](Assert-PshReleaseIndexChecksums -Index $index -Checksums $checksums)
        $record = [pscustomobject][ordered]@{
            Trusted = $true
            Publisher = [string](Get-PshLifecycleProperty $trust 'Publisher')
            Index = $index
            Checksums = $checksums
            IndexSha256 = [string]$indexSnapshot.Sha256
            ChecksumsSha256 = [string]$checksumSnapshot.Sha256
        }
        $handle = [pscustomobject][ordered]@{
            PSTypeName = 'Psh.TrustedRelease'
            TrustToken = $script:PshReleaseTrustToken
            Trusted = $true
            Publisher = [string]$record.Publisher
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
        [Parameter()][switch] $Offline
    )

    return Invoke-PshReleaseTrustBundleCore -IndexPath $IndexPath -ChecksumPath $ChecksumPath -CatalogPath $CatalogPath -Offline:$Offline
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

    $publisherPolicy = Get-PshProductionPublisherPolicy
    if ([IO.Path]::GetFileName($ManifestPath) -cne 'package.manifest.json') {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshManifestFileName' -Message 'Package manifest file must be named exactly package.manifest.json.'
    }
    $releaseIndex = $null
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
        $trust = Invoke-PshCatalogTrustVerifier -Context $context -PublisherPolicy $publisherPolicy -Offline:$Offline
        [void](Assert-PshTrustSnapshotContextStable -Sources @($sources) -Context $context)

        $snapshot = New-PshStrictJsonSnapshotFromBytes -Path ([string]$manifestSource.Path) -Bytes ([byte[]]$manifestSource.Bytes) -Description 'Package manifest'
        $manifest = Read-PshPackageManifest -Path ([string]$manifestSource.Path) -Snapshot $snapshot
        if ($null -ne $ExpectedAsset) {
            [void](Assert-PshManifestMatchesReleaseAsset -Manifest $manifest -ManifestSha256 ([string]$snapshot.Sha256) -Asset $ExpectedAsset -ReleaseIndex $releaseIndex)
        }
        $record = [pscustomobject][ordered]@{
            Trusted = $true
            Publisher = [string](Get-PshLifecycleProperty $trust 'Publisher')
            Manifest = $manifest
            ManifestSha256 = [string]$snapshot.Sha256
            ManifestLength = [int64]$snapshot.Length
        }
        $handle = [pscustomobject][ordered]@{
            PSTypeName = 'Psh.TrustedPackageManifest'
            TrustToken = $script:PshPackageTrustToken
            Trusted = $true
            Publisher = [string]$record.Publisher
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
