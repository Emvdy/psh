# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string] $RepositoryRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent ([string]$MyInvocation.MyCommand.Path))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$script:Goal5ReleaseTrustAssertions = 0
$trustPath = Join-Path $RepositoryRoot 'src/install/ReleaseTrust.ps1'
. $trustPath
$script:Goal5OriginalAuthenticodePolicy = (Get-Command Get-PshAuthenticodePublisherPolicy -CommandType Function).ScriptBlock
$script:Goal5OriginalWindowsCatalogVerifier = (Get-Command Invoke-PshWindowsCatalogTrustVerifier -CommandType Function).ScriptBlock
try {
$script:Goal5ActivePublisherPolicy = $null
$script:Goal5ActiveCatalogVerifier = $null

function Get-PshAuthenticodePublisherPolicy {
    if ($null -eq $script:Goal5ActivePublisherPolicy) {
        return & $script:Goal5OriginalAuthenticodePolicy
    }
    return Assert-PshPublisherPolicy -Policy $script:Goal5ActivePublisherPolicy
}

function Invoke-PshWindowsCatalogTrustVerifier {
    param([Parameter(Mandatory = $true)][object] $Request)

    if ($null -eq $script:Goal5ActiveCatalogVerifier) {
        return & $script:Goal5OriginalWindowsCatalogVerifier -Request $Request
    }
    return & $script:Goal5ActiveCatalogVerifier $Request
}

function Invoke-PshGoal5ReleaseTrustHarness {
    param(
        [Parameter(Mandatory = $true)][string] $IndexPath,
        [Parameter(Mandatory = $true)][string] $ChecksumPath,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][object] $PublisherPolicy,
        [Parameter(Mandatory = $true)][scriptblock] $Verifier,
        [Parameter()][switch] $Offline
    )

    $script:Goal5ActivePublisherPolicy = $PublisherPolicy
    $script:Goal5ActiveCatalogVerifier = $Verifier
    try {
        return Confirm-PshReleaseTrustBundle -IndexPath $IndexPath -ChecksumPath $ChecksumPath -CatalogPath $CatalogPath -Offline:$Offline
    }
    finally {
        $script:Goal5ActivePublisherPolicy = $null
        $script:Goal5ActiveCatalogVerifier = $null
    }
}

function Invoke-PshGoal5PackageTrustHarness {
    param(
        [Parameter(Mandatory = $true)][string] $ManifestPath,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][object] $PublisherPolicy,
        [Parameter()][AllowNull()][object] $ExpectedAsset,
        [Parameter()][AllowNull()][object] $TrustedRelease,
        [Parameter(Mandatory = $true)][scriptblock] $Verifier,
        [Parameter()][switch] $Offline
    )

    $script:Goal5ActivePublisherPolicy = $PublisherPolicy
    $script:Goal5ActiveCatalogVerifier = $Verifier
    try {
        return Confirm-PshPackageManifestTrust -ManifestPath $ManifestPath -CatalogPath $CatalogPath -ExpectedAsset $ExpectedAsset -TrustedRelease $TrustedRelease -Offline:$Offline
    }
    finally {
        $script:Goal5ActivePublisherPolicy = $null
        $script:Goal5ActiveCatalogVerifier = $null
    }
}

function Assert-PshGoal5ReleaseTrust {
    param([Parameter(Mandatory = $true)][bool] $Condition, [Parameter(Mandatory = $true)][string] $Message)
    $script:Goal5ReleaseTrustAssertions++
    if (-not $Condition) { throw "Goal 5 release trust failed: $Message" }
}

function Assert-PshGoal5ReleaseTrustFailure {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $ErrorId,
        [Parameter(Mandatory = $true)][string] $Label
    )
    $failed = $false
    try { & $Action | Out-Null }
    catch {
        $failed = $true
        $metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $_
        Assert-PshGoal5ReleaseTrust ([int]$metadata.ExitCode -eq $ExitCode) "$Label used exit code $($metadata.ExitCode), expected $ExitCode."
        Assert-PshGoal5ReleaseTrust ([string]$metadata.ErrorId -ceq $ErrorId) "$Label used error id $($metadata.ErrorId), expected $ErrorId."
    }
    Assert-PshGoal5ReleaseTrust $failed "$Label unexpectedly succeeded."
}

function Write-PshGoal5ReleaseText {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-PshGoal5ReleaseJson {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][object] $Value)
    Write-PshGoal5ReleaseText -Path $Path -Text ((ConvertTo-PshCanonicalJson -InputObject $Value) + "`n")
}

function Copy-PshGoal5ReleaseObject {
    param([Parameter(Mandatory = $true)][object] $Value)
    return ((ConvertTo-PshCanonicalJson -InputObject $Value) | ConvertFrom-Json -ErrorAction Stop)
}

function Get-PshGoal5ReleaseBytesHash {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)
    return Get-PshLifecycleSha256Bytes -Bytes $Bytes
}

function New-PshGoal5ReleaseDirectoryLink {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Target
    )

    try {
        $itemType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
        [void](New-Item -ItemType $itemType -Path $Path -Target $Target -ErrorAction Stop)
        return $true
    }
    catch { return $false }
}

function New-PshGoal5ArchiveBindingZip {
    param(
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter(Mandatory = $true)][string] $ZipPath,
        [Parameter()][object[]] $ExtraEntries = @()
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $root = [IO.Path]::GetFullPath($PackageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $stream = New-Object IO.FileStream($ZipPath, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::None))
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, ([IO.Compression.ZipArchiveMode]::Create), $true, (New-Object Text.UTF8Encoding($false)))
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Sort-Object FullName)) {
                $relative = $file.FullName.Substring(($root + [IO.Path]::DirectorySeparatorChar).Length).Replace([IO.Path]::DirectorySeparatorChar, '/').Replace([IO.Path]::AltDirectorySeparatorChar, '/')
                $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
                $entry.ExternalAttributes = 0
                $entryStream = $entry.Open()
                $fileStream = New-Object IO.FileStream($file.FullName, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
                try { $fileStream.CopyTo($entryStream) }
                finally { $fileStream.Dispose(); $entryStream.Dispose() }
            }
            foreach ($extra in @($ExtraEntries)) {
                $entry = $archive.CreateEntry([string]$extra.Name, [IO.Compression.CompressionLevel]::Optimal)
                $external = Get-PshLifecycleProperty $extra 'ExternalAttributes'
                if ($null -ne $external) { $entry.ExternalAttributes = [int]$external }
                $bytes = [byte[]](Get-PshLifecycleProperty $extra 'Bytes')
                $entryStream = $entry.Open()
                try { $entryStream.Write($bytes, 0, $bytes.Length) }
                finally { $entryStream.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
    return [pscustomobject][ordered]@{
        Path = $ZipPath
        Sha256 = Get-PshLifecycleFileSha256 -Path $ZipPath | Select-Object -ExpandProperty Sha256
    }
}

function New-PshGoal5ReleaseFixture {
    param([Parameter(Mandatory = $true)][string] $Root)

    [void][IO.Directory]::CreateDirectory($Root)
    $encoding = New-Object Text.UTF8Encoding($false)
    $version = '1.2.3'
    $commit = '1234567890abcdef1234567890abcdef12345678'
    $fileSpecs = @(
        @{ Path = 'install-offline.ps1'; Role = 'entrypoint'; Text = '# offline' },
        @{ Path = 'uninstall.ps1'; Role = 'entrypoint'; Text = '# uninstall' },
        @{ Path = 'install.sh'; Role = 'entrypoint'; Text = '# shell' },
        @{ Path = 'psh-installer.exe'; Role = 'bootstrapper'; Text = 'bootstrapper' }
    )
    $manifestFiles = @()
    foreach ($spec in $fileSpecs) {
        $bytes = $encoding.GetBytes([string]$spec.Text)
        $manifestFiles += [pscustomobject][ordered]@{
            relativePath = [string]$spec.Path
            length = [int64]$bytes.Length
            sha256 = Get-PshGoal5ReleaseBytesHash -Bytes $bytes
            role = [string]$spec.Role
        }
    }
    $treeSha256 = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = $manifestFiles })
    $bootstrapperFile = @($manifestFiles | Where-Object { $_.relativePath -ceq 'psh-installer.exe' })[0]
    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        version = $version
        edition = 'Core'
        architecture = 'any'
        payloadRoot = 'payload'
        files = $manifestFiles
        treeSha256 = $treeSha256
        entrypoints = [pscustomobject][ordered]@{
            offlinePowerShell = 'install-offline.ps1'
            uninstallPowerShell = 'uninstall.ps1'
            shell = 'install.sh'
            bootstrapper = 'psh-installer.exe'
        }
        testOnly = $false
        source = [pscustomobject][ordered]@{ repository = 'https://github.com/Emvdy/psh'; commit = $commit }
        bootstrapper = [pscustomobject][ordered]@{ relativePath = 'psh-installer.exe'; sha256 = [string]$bootstrapperFile.sha256; anyCpu = $true }
        nativeToolsLockSha256 = $null
    }
    $manifestPath = Join-Path $Root 'package.manifest.json'
    Write-PshGoal5ReleaseJson -Path $manifestPath -Value $manifest
    $manifestHash = Get-PshLifecycleFileSha256 -Path $manifestPath

    $assetData = [ordered]@{
        "psh-$version-core.zip" = $encoding.GetBytes('core package bytes')
        "psh-$version-full-win-x64.zip" = $encoding.GetBytes('full x64 package bytes')
        "install-online-$version.ps1" = $encoding.GetBytes('# online installer')
    }
    foreach ($assetName in $assetData.Keys) {
        [IO.File]::WriteAllBytes((Join-Path $Root $assetName), [byte[]]$assetData[$assetName])
    }
    $coreName = "psh-$version-core.zip"
    $fullName = "psh-$version-full-win-x64.zip"
    $installerName = "install-online-$version.ps1"
    $coreSha = Get-PshGoal5ReleaseBytesHash -Bytes ([byte[]]$assetData[$coreName])
    $fullSha = Get-PshGoal5ReleaseBytesHash -Bytes ([byte[]]$assetData[$fullName])
    $installerSha = Get-PshGoal5ReleaseBytesHash -Bytes ([byte[]]$assetData[$installerName])
    $assets = @(
        [pscustomobject][ordered]@{
            name = $coreName; role = 'package'
            url = "https://github.com/Emvdy/psh/releases/download/v$version/$coreName"
            length = [int64]$assetData[$coreName].Length; sha256 = $coreSha
            package = [pscustomobject][ordered]@{
                version = $version; edition = 'Core'; architecture = 'any'
                packageManifestSha256 = [string]$manifestHash.Sha256; treeSha256 = $treeSha256; testOnly = $false
            }
        },
        [pscustomobject][ordered]@{
            name = $fullName; role = 'package'
            url = "https://github.com/Emvdy/psh/releases/download/v$version/$fullName"
            length = [int64]$assetData[$fullName].Length; sha256 = $fullSha
            package = [pscustomobject][ordered]@{
                version = $version; edition = 'Full'; architecture = 'win-x64'
                packageManifestSha256 = [string]$manifestHash.Sha256; treeSha256 = $treeSha256; testOnly = $false
            }
        },
        [pscustomobject][ordered]@{
            name = $installerName; role = 'installer'
            url = "https://github.com/Emvdy/psh/releases/download/v$version/$installerName"
            length = [int64]$assetData[$installerName].Length; sha256 = $installerSha; package = $null
        }
    )
    $index = [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        repository = 'https://github.com/Emvdy/psh'
        version = $version
        tag = "v$version"
        sourceCommit = $commit
        assets = $assets
    }
    $indexPath = Join-Path $Root "psh-release-$version.json"
    Write-PshGoal5ReleaseJson -Path $indexPath -Value $index
    $checksumLines = @($assets | ForEach-Object { '{0}  {1}' -f [string]$_.sha256, [string]$_.name })
    $checksumText = ([string]::Join("`n", $checksumLines)) + "`n"
    $checksumPath = Join-Path $Root 'SHA256SUMS'
    Write-PshGoal5ReleaseText -Path $checksumPath -Text $checksumText
    $catalogPath = Join-Path $Root 'release.cat'
    [IO.File]::WriteAllBytes($catalogPath, $encoding.GetBytes('catalog fixture'))
    $packageCatalogPath = Join-Path $Root 'package.manifest.cat'
    [IO.File]::WriteAllBytes($packageCatalogPath, $encoding.GetBytes('package catalog fixture'))
    $policy = [pscustomobject][ordered]@{
        schemaVersion = 1
        publisher = 'Emvdy Software'
        subjectDistinguishedNames = @('CN=Emvdy Software, O=Emvdy')
        requiredEkuOids = @('1.3.6.1.5.5.7.3.3')
        requiredCertificatePolicyOids = @('1.3.6.1.4.1.311.76.3.1')
        allowedRootCertificateSha256 = @('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
    }
    return [pscustomobject][ordered]@{
        Root = $Root; Version = $version; Commit = $commit
        Index = $index; IndexPath = $indexPath
        ChecksumPath = $checksumPath; ChecksumText = $checksumText
        CatalogPath = $catalogPath; Policy = $policy
        Manifest = $manifest; ManifestPath = $manifestPath; PackageCatalogPath = $packageCatalogPath
        CoreAsset = $assets[0]
    }
}

Assert-PshGoal5ReleaseTrust ([IO.File]::Exists($trustPath)) 'ReleaseTrust.ps1 is missing.'
foreach ($name in @(
    'Read-PshReleaseIndex', 'Read-PshSha256Sums', 'Read-PshPublisherPolicy',
    'Get-PshProductionTrustPolicy', 'Resolve-PshTrustedReleaseMetadata', 'Confirm-PshPackageArchiveBinding',
    'Confirm-PshReleaseTrustBundle', 'Confirm-PshPackageManifestTrust',
    'Test-PshTrustedRelease', 'Assert-PshTrustedRelease', 'Test-PshTrustedPackageManifest'
)) {
    Assert-PshGoal5ReleaseTrust ($null -ne (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) "Public helper is missing: $name"
}
$trustTokens = $null
$trustParseErrors = $null
$trustAst = [Management.Automation.Language.Parser]::ParseFile($trustPath, [ref]$trustTokens, [ref]$trustParseErrors)
Assert-PshGoal5ReleaseTrust ($trustParseErrors.Count -eq 0) 'ReleaseTrust.ps1 has parser errors.'
$testCoreDefinitions = @($trustAst.FindAll({
            param($node)
            return ($node -is [Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -match '(?i)TestCore')
        }, $true))
$scriptblockParameters = @($trustAst.FindAll({
            param($node)
            if ($node -isnot [Management.Automation.Language.ParameterAst]) { return $false }
            foreach ($attribute in @($node.Attributes)) {
                if ($attribute -is [Management.Automation.Language.TypeConstraintAst] -and [string]$attribute.TypeName.FullName -ieq 'scriptblock') { return $true }
            }
            return $false
        }, $true))
Assert-PshGoal5ReleaseTrust ($testCoreDefinitions.Count -eq 0) 'Production release trust source contains a discoverable TestCore function.'
Assert-PshGoal5ReleaseTrust ($scriptblockParameters.Count -eq 0) 'Production release trust source contains a scriptblock parameter.'
$trustSourceText = [IO.File]::ReadAllText($trustPath)
Assert-PshGoal5ReleaseTrust ($trustSourceText -notmatch '(?i)UseTestVerifier|PshActiveCatalogTrustTestVerifier|TestCore') 'Production release trust source retains test verifier plumbing.'
foreach ($forbiddenName in @('Invoke-PshReleaseTrustBundleTestCore', 'Invoke-PshPackageManifestTrustTestCore')) {
    Assert-PshGoal5ReleaseTrust ($null -eq (Get-Command $forbiddenName -CommandType Function -ErrorAction SilentlyContinue)) "Production test-only function is discoverable: $forbiddenName"
}
$releaseCoreCommand = Get-Command Invoke-PshReleaseTrustBundleCore -CommandType Function
$packageCoreCommand = Get-Command Invoke-PshPackageManifestTrustCore -CommandType Function
Assert-PshGoal5ReleaseTrust (-not $releaseCoreCommand.Parameters.ContainsKey('PublisherPolicy') -and -not $releaseCoreCommand.Parameters.ContainsKey('UseTestVerifier') -and -not $releaseCoreCommand.Parameters.ContainsKey('Verifier')) 'Release mint core exposes policy or verifier injection.'
Assert-PshGoal5ReleaseTrust (-not $packageCoreCommand.Parameters.ContainsKey('PublisherPolicy') -and -not $packageCoreCommand.Parameters.ContainsKey('UseTestVerifier') -and -not $packageCoreCommand.Parameters.ContainsKey('Verifier')) 'Package mint core exposes policy or verifier injection.'

$temporaryBase = if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -and [IO.Directory]::Exists('/private/tmp')) { '/private/tmp' } else { [IO.Path]::GetTempPath() }
$testRoot = Join-Path $temporaryBase ('psh-goal5-release-trust-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $fixture = New-PshGoal5ReleaseFixture -Root (Join-Path $testRoot 'valid')
    $validVerifier = { param($request) [pscustomobject][ordered]@{ Trusted = $true; Publisher = 'Emvdy Software'; Subject = 'fixture' } }

    $pathProbePath = Join-Path $testRoot 'readwrite-handle-path-probe.bin'
    $pathProbeBytes = (New-Object Text.UTF8Encoding($false)).GetBytes('path probe')
    $pathProbeStream = New-Object IO.FileStream($pathProbePath, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::Read))
    try {
        $pathProbeStream.Write($pathProbeBytes, 0, $pathProbeBytes.Length)
        try { $pathProbeStream.Flush($true) } catch { $pathProbeStream.Flush() }
        $pathProbeState = Get-PshTrustPathState -Path $pathProbePath -Description 'Goal 5 read/write handle path probe'
        Assert-PshGoal5ReleaseTrust ([int64]$pathProbeState.Length -eq [int64]$pathProbeBytes.Length -and
            [string]$pathProbeState.Sha256 -ceq (Get-PshLifecycleSha256Bytes -Bytes $pathProbeBytes)) 'Read-only trust path CAS could not coexist with an owned read/write handle.'
    }
    finally { $pathProbeStream.Dispose() }

    $parsedIndex = Read-PshReleaseIndex -Path $fixture.IndexPath
    Assert-PshGoal5ReleaseTrust ([string]$parsedIndex.version -ceq $fixture.Version -and @($parsedIndex.assets).Count -eq 3) 'Valid release index did not parse.'
    $parsedChecksums = Read-PshSha256Sums -Path $fixture.ChecksumPath
    Assert-PshGoal5ReleaseTrust ([bool](Assert-PshReleaseIndexChecksums -Index $parsedIndex -Checksums $parsedChecksums)) 'Valid SHA256SUMS did not match the release index.'
    $parsedPolicy = Assert-PshPublisherPolicy -Policy $fixture.Policy
    Assert-PshGoal5ReleaseTrust ([string]$parsedPolicy.publisher -ceq 'Emvdy Software' -and @($parsedPolicy.requiredEkuOids).Count -eq 1) 'Valid publisher policy did not normalize.'
    $policyPath = Join-Path $fixture.Root 'publisher-policy.json'
    Write-PshGoal5ReleaseJson -Path $policyPath -Value $fixture.Policy
    Assert-PshGoal5ReleaseTrust ([string](Read-PshPublisherPolicy -Path $policyPath).publisher -ceq 'Emvdy Software') 'Publisher policy file did not parse.'
    $productionPolicy = Get-PshProductionPublisherPolicy
    Assert-PshGoal5ReleaseTrust ([int]$productionPolicy.schemaVersion -eq 1 -and [string]$productionPolicy.policyVersion -ceq '2026-07-22.3' -and
        [string]$productionPolicy.onlineTrustMode -ceq 'github-release-asset-digest' -and [string]$productionPolicy.offlineTrustMode -ceq 'offline-external-archive-sha256+package-catalog-sha256' -and
        -not [bool]$productionPolicy.signatureRequired -and [bool]$productionPolicy.catalogMembershipRequired -and [bool]$productionPolicy.archiveBindingRequired -and
        [bool]$productionPolicy.attestationRequiredAtPublish -and [string]$productionPolicy.runtimeAttestationVerification -ceq 'not-verified-at-runtime') 'Production hash trust policy is not the fixed versioned archive-binding policy.'
    $runtimeAttestationReport = New-PshProductionTrustReport -TrustMode 'offline-external-archive-sha256+package-catalog-sha256' -Checksum 'archive-binding-required' -CatalogMembership 'verified' -SignatureNotRequired $true -ArchiveBinding 'required-at-entry' -AttestationVerification 'not-verified-at-runtime'
    Assert-PshGoal5ReleaseTrust ([bool]$runtimeAttestationReport.attestationRequiredAtPublish -and
        [string]$runtimeAttestationReport.attestationVerification -ceq 'not-verified-at-runtime') 'Runtime trust report does not distinguish publish attestation policy from runtime verification.'

    $archiveBindingRoot = Join-Path $testRoot 'archive-binding-package'
    [void][IO.Directory]::CreateDirectory((Join-Path $archiveBindingRoot 'sub'))
    Write-PshGoal5ReleaseText -Path (Join-Path $archiveBindingRoot 'a.txt') -Text 'alpha'
    $bindingBinaryBytes = [byte[]](1, 3, 5, 7, 9)
    [IO.File]::WriteAllBytes((Join-Path $archiveBindingRoot 'sub/b.bin'), $bindingBinaryBytes)
    $validArchive = New-PshGoal5ArchiveBindingZip -PackageRoot $archiveBindingRoot -ZipPath (Join-Path $testRoot 'archive-binding-valid.zip')
    $retainedBinding = Confirm-PshPackageArchiveBinding -ArchivePath $validArchive.Path -ArchiveSha256 $validArchive.Sha256 -PackageRoot $archiveBindingRoot -RetainLocks
    $retainedRecord = @($retainedBinding.PackageRecords)[0]
    $retainedStream = Get-PshLifecycleProperty $retainedRecord 'Stream'
    Assert-PshGoal5ReleaseTrust (-not [bool]$retainedBinding.Released -and $retainedStream -is [IO.FileStream] -and $retainedStream.CanRead) 'Retained archive binding did not keep the package snapshot live.'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $writeDenied = $false
        try {
            $writeProbe = New-Object IO.FileStream((Join-Path $archiveBindingRoot 'a.txt'), ([IO.FileMode]::Open), ([IO.FileAccess]::Write), ([IO.FileShare]::ReadWrite))
            $writeProbe.Dispose()
        }
        catch { $writeDenied = $true }
        Assert-PshGoal5ReleaseTrust $writeDenied 'Retained archive binding did not deny package mutation on Windows.'
    }
    $retainedBinding.Dispose()
    $retainedBinding.Dispose()
    Assert-PshGoal5ReleaseTrust ([bool]$retainedBinding.Released -and -not $retainedStream.CanRead) 'Retained archive binding did not release its streams idempotently.'
    $archiveBinding = Confirm-PshPackageArchiveBinding -ArchivePath $validArchive.Path -ArchiveSha256 $validArchive.Sha256 -PackageRoot $archiveBindingRoot
    Assert-PshGoal5ReleaseTrust ([bool]$archiveBinding.Trusted -and [string]$archiveBinding.ArchiveBinding -ceq 'verified' -and
        [string]$archiveBinding.ArchiveSha256 -ceq [string]$validArchive.Sha256 -and [int]$archiveBinding.FileCount -eq 2) 'Valid external archive evidence did not bind to the extracted package tree.'
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Confirm-PshPackageArchiveBinding -ArchivePath $validArchive.Path -ArchiveSha256 ('f' * 64) -PackageRoot $archiveBindingRoot
    } -ExitCode 5 -ErrorId PshOfflineArchiveHashMismatch -Label 'wrong external archive SHA256'

    Write-PshGoal5ReleaseText -Path (Join-Path $archiveBindingRoot 'a.txt') -Text 'ALPHA'
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Confirm-PshPackageArchiveBinding -ArchivePath $validArchive.Path -ArchiveSha256 $validArchive.Sha256 -PackageRoot $archiveBindingRoot
    } -ExitCode 5 -ErrorId PshOfflineArchiveEntryHash -Label 'archive-bound package byte tamper'
    Write-PshGoal5ReleaseText -Path (Join-Path $archiveBindingRoot 'a.txt') -Text 'alpha'

    Write-PshGoal5ReleaseText -Path (Join-Path $archiveBindingRoot 'extra.txt') -Text 'extra'
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Confirm-PshPackageArchiveBinding -ArchivePath $validArchive.Path -ArchiveSha256 $validArchive.Sha256 -PackageRoot $archiveBindingRoot
    } -ExitCode 5 -ErrorId PshOfflineArchivePackageExtraFile -Label 'archive-bound package extra file'
    [IO.File]::Delete((Join-Path $archiveBindingRoot 'extra.txt'))

    [IO.File]::Delete((Join-Path $archiveBindingRoot 'sub/b.bin'))
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Confirm-PshPackageArchiveBinding -ArchivePath $validArchive.Path -ArchiveSha256 $validArchive.Sha256 -PackageRoot $archiveBindingRoot
    } -ExitCode 5 -ErrorId PshOfflineArchivePackageMissingFile -Label 'archive-bound package missing file'
    [IO.File]::WriteAllBytes((Join-Path $archiveBindingRoot 'sub/b.bin'), $bindingBinaryBytes)

    $unrelatedRoot = Join-Path $testRoot 'archive-binding-unrelated'
    [void][IO.Directory]::CreateDirectory($unrelatedRoot)
    Write-PshGoal5ReleaseText -Path (Join-Path $unrelatedRoot 'unrelated.txt') -Text 'unrelated'
    $unrelatedArchive = New-PshGoal5ArchiveBindingZip -PackageRoot $unrelatedRoot -ZipPath (Join-Path $testRoot 'archive-binding-unrelated.zip')
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Confirm-PshPackageArchiveBinding -ArchivePath $unrelatedArchive.Path -ArchiveSha256 $unrelatedArchive.Sha256 -PackageRoot $archiveBindingRoot
    } -ExitCode 5 -ErrorId PshOfflineArchivePackageMissingFile -Label 'unrelated but correctly hashed archive'

    $traversalArchive = New-PshGoal5ArchiveBindingZip -PackageRoot $archiveBindingRoot -ZipPath (Join-Path $testRoot 'archive-binding-traversal.zip') -ExtraEntries @(
        [pscustomobject]@{ Name = '../escape.txt'; Bytes = [Text.Encoding]::UTF8.GetBytes('escape') }
    )
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Confirm-PshPackageArchiveBinding -ArchivePath $traversalArchive.Path -ArchiveSha256 $traversalArchive.Sha256 -PackageRoot $archiveBindingRoot
    } -ExitCode 5 -ErrorId PshOfflineArchiveEntryPath -Label 'archive traversal entry'

    $symlinkAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]2717843456), 0)
    $symlinkArchive = New-PshGoal5ArchiveBindingZip -PackageRoot $archiveBindingRoot -ZipPath (Join-Path $testRoot 'archive-binding-symlink.zip') -ExtraEntries @(
        [pscustomobject]@{ Name = 'link.txt'; Bytes = [Text.Encoding]::UTF8.GetBytes('a.txt'); ExternalAttributes = $symlinkAttributes }
    )
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Confirm-PshPackageArchiveBinding -ArchivePath $symlinkArchive.Path -ArchiveSha256 $symlinkArchive.Sha256 -PackageRoot $archiveBindingRoot
    } -ExitCode 5 -ErrorId PshOfflineArchiveEntryType -Label 'archive symlink entry'

    $duplicateArchive = New-PshGoal5ArchiveBindingZip -PackageRoot $archiveBindingRoot -ZipPath (Join-Path $testRoot 'archive-binding-duplicate.zip') -ExtraEntries @(
        [pscustomobject]@{ Name = 'A.TXT'; Bytes = [Text.Encoding]::UTF8.GetBytes('duplicate') }
    )
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Confirm-PshPackageArchiveBinding -ArchivePath $duplicateArchive.Path -ArchiveSha256 $duplicateArchive.Sha256 -PackageRoot $archiveBindingRoot
    } -ExitCode 5 -ErrorId PshOfflineArchiveDuplicateEntry -Label 'archive case-insensitive duplicate entry'

    $releaseCommand = Get-Command Confirm-PshReleaseTrustBundle -CommandType Function
    $packageCommand = Get-Command Confirm-PshPackageManifestTrust -CommandType Function
    Assert-PshGoal5ReleaseTrust (-not $releaseCommand.Parameters.ContainsKey('Verifier') -and -not $releaseCommand.Parameters.ContainsKey('PublisherPolicy')) 'Production release trust entry exposes verifier or publisher-policy injection.'
    Assert-PshGoal5ReleaseTrust (-not $packageCommand.Parameters.ContainsKey('Verifier') -and -not $packageCommand.Parameters.ContainsKey('PublisherPolicy')) 'Production package trust entry exposes verifier or publisher-policy injection.'
    Assert-PshGoal5ReleaseTrust (@($releaseCommand.Parameters.Values | Where-Object { $_.ParameterType -eq [scriptblock] }).Count -eq 0) 'Production release trust entry accepts a scriptblock parameter.'
    Assert-PshGoal5ReleaseTrust (@($packageCommand.Parameters.Values | Where-Object { $_.ParameterType -eq [scriptblock] }).Count -eq 0) 'Production package trust entry accepts a scriptblock parameter.'

    $script:Goal5SnapshotOriginalCatalog = $fixture.CatalogPath
    $script:Goal5SnapshotIndexBytes = [IO.File]::ReadAllBytes($fixture.IndexPath)
    $script:Goal5SnapshotChecksumBytes = [IO.File]::ReadAllBytes($fixture.ChecksumPath)
    $script:Goal5SnapshotCatalogBytes = [IO.File]::ReadAllBytes($fixture.CatalogPath)
    $script:Goal5SnapshotRoot = $null
    $snapshotVerifier = {
        param($request)
        $script:Goal5SnapshotRoot = [IO.Path]::GetDirectoryName([string]$request.ContentRoot)
        Assert-PshGoal5ReleaseTrust ([string]$request.CatalogPath -cne [string]$script:Goal5SnapshotOriginalCatalog) 'Verifier received the mutable source catalog path.'
        Assert-PshGoal5ReleaseTrust ([string][IO.Path]::GetDirectoryName([string]$request.CatalogPath) -ceq [string]$script:Goal5SnapshotRoot) 'Catalog snapshot is outside the locked trust root.'
        Assert-PshGoal5ReleaseTrust (@($request.SnapshotFiles).Count -eq 3) 'Release verifier did not receive index, checksums, and catalog snapshots.'
        $indexFile = @($request.SnapshotFiles | Where-Object { [string]$_.Role -ceq 'index' })[0]
        $checksumFile = @($request.SnapshotFiles | Where-Object { [string]$_.Role -ceq 'checksums' })[0]
        Assert-PshGoal5ReleaseTrust ([Convert]::ToBase64String((Get-PshTrustPathState -Path ([string]$indexFile.Path) -Description 'fixture index snapshot').Bytes) -ceq [Convert]::ToBase64String($script:Goal5SnapshotIndexBytes)) 'Index snapshot bytes differ from the locked source.'
        Assert-PshGoal5ReleaseTrust ([Convert]::ToBase64String((Get-PshTrustPathState -Path ([string]$checksumFile.Path) -Description 'fixture checksum snapshot').Bytes) -ceq [Convert]::ToBase64String($script:Goal5SnapshotChecksumBytes)) 'Checksum snapshot bytes differ from the locked source.'
        Assert-PshGoal5ReleaseTrust ([Convert]::ToBase64String((Get-PshTrustPathState -Path ([string]$request.CatalogPath) -Description 'fixture catalog snapshot').Bytes) -ceq [Convert]::ToBase64String($script:Goal5SnapshotCatalogBytes)) 'Catalog snapshot bytes differ from the locked source.'
        [pscustomobject][ordered]@{ Trusted = $true; Publisher = 'Emvdy Software'; Subject = 'fixture' }
    }
    $trusted = Invoke-PshGoal5ReleaseTrustHarness -IndexPath $fixture.IndexPath -ChecksumPath $fixture.ChecksumPath -CatalogPath $fixture.CatalogPath -PublisherPolicy $fixture.Policy -Verifier $snapshotVerifier
    Assert-PshGoal5ReleaseTrust (-not [IO.Directory]::Exists([string]$script:Goal5SnapshotRoot)) 'Owned trust snapshot root was not removed after successful verification.'
    Assert-PshGoal5ReleaseTrust (Test-PshTrustedRelease -InputObject $trusted) 'Valid verifier did not mint a trusted release handle.'
    $trustedRecord = Assert-PshTrustedRelease -InputObject $trusted
    Assert-PshGoal5ReleaseTrust ([string]$trustedRecord.Index.version -ceq $fixture.Version -and [string]$trustedRecord.Publisher -ceq 'Emvdy Software') 'Trusted release record is incorrect.'

    $trusted.Index.version = '9.9.9'
    $trusted.Index.assets[0].sha256 = ('b' * 64)
    $registeredSnapshot = Assert-PshTrustedRelease -InputObject $trusted
    Assert-PshGoal5ReleaseTrust ([string]$registeredSnapshot.Index.version -ceq $fixture.Version -and [string]$registeredSnapshot.Index.assets[0].sha256 -ceq [string]$fixture.CoreAsset.sha256) 'Public trusted handle mutation changed the registered snapshot.'
    $forged = [pscustomobject]@{ TrustToken = $trusted.TrustToken; Trusted = $true; Index = $fixture.Index }
    Assert-PshGoal5ReleaseTrust (-not (Test-PshTrustedRelease -InputObject $forged)) 'Copied TrustToken forged a trusted release handle.'
    Assert-PshGoal5ReleaseTrustFailure -Action { Assert-PshTrustedRelease -InputObject $forged } -ExitCode 5 -ErrorId PshUntrustedRelease -Label 'forged trusted release handle'

    foreach ($verifierCase in @(
        @{ Label = 'verifier false'; Block = { param($request) [pscustomobject]@{ Trusted = $false; Publisher = 'Emvdy Software' } } },
        @{ Label = 'verifier wrong publisher'; Block = { param($request) [pscustomobject]@{ Trusted = $true; Publisher = 'Other Publisher' } } },
        @{ Label = 'verifier multiple results'; Block = { param($request) [pscustomobject]@{ Trusted = $true; Publisher = 'Emvdy Software' }; [pscustomobject]@{ Trusted = $true; Publisher = 'Emvdy Software' } } }
    )) {
        $caseBlock = [scriptblock]$verifierCase.Block
        Assert-PshGoal5ReleaseTrustFailure -Action { Invoke-PshGoal5ReleaseTrustHarness -IndexPath $fixture.IndexPath -ChecksumPath $fixture.ChecksumPath -CatalogPath $fixture.CatalogPath -PublisherPolicy $fixture.Policy -Verifier $caseBlock } -ExitCode 5 -ErrorId PshTrustVerifierResult -Label ([string]$verifierCase.Label)
    }
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Invoke-PshGoal5ReleaseTrustHarness -IndexPath $fixture.IndexPath -ChecksumPath $fixture.ChecksumPath -CatalogPath $fixture.CatalogPath -PublisherPolicy $fixture.Policy -Verifier { throw 'transport verifier failure' }
    } -ExitCode 5 -ErrorId PshTrustVerifierFailed -Label 'verifier exception'

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Assert-PshGoal5ReleaseTrustFailure -Action {
            Get-PshAuthenticodePublisherPolicy
        } -ExitCode 4 -ErrorId PshPublisherPolicyUnavailable -Label 'unprovisioned production publisher policy'
    }

    $toctou = New-PshGoal5ReleaseFixture -Root (Join-Path $testRoot 'toctou')
    $script:Goal5ToctouIndexPath = $toctou.IndexPath
    $script:Goal5ToctouChecksumPath = $toctou.ChecksumPath
    $script:Goal5ToctouCatalogPath = $toctou.CatalogPath
    $script:Goal5ToctouMutationCount = 0
    $toctouVerifier = {
        param($request)
        foreach ($mutation in @(
            @{ Path = $script:Goal5ToctouIndexPath; Text = '{"tampered":true}' },
            @{ Path = $script:Goal5ToctouChecksumPath; Text = 'tampered' },
            @{ Path = $script:Goal5ToctouCatalogPath; Text = 'tampered catalog' }
        )) {
            try {
                [IO.File]::WriteAllText([string]$mutation.Path, [string]$mutation.Text, (New-Object Text.UTF8Encoding($false)))
                $script:Goal5ToctouMutationCount++
            }
            catch { }
        }
        [pscustomobject]@{ Trusted = $true; Publisher = 'Emvdy Software' }
    }
    $toctouError = $null
    $toctouHandle = $null
    try { $toctouHandle = Invoke-PshGoal5ReleaseTrustHarness -IndexPath $toctou.IndexPath -ChecksumPath $toctou.ChecksumPath -CatalogPath $toctou.CatalogPath -PublisherPolicy $toctou.Policy -Verifier $toctouVerifier }
    catch { $toctouError = $_ }
    if ($script:Goal5ToctouMutationCount -eq 0) {
        Assert-PshGoal5ReleaseTrust ($null -eq $toctouError -and (Test-PshTrustedRelease -InputObject $toctouHandle)) 'OS-enforced source locks did not permit safe trust completion.'
    }
    else {
        $toctouMetadata = Get-PshLifecycleErrorMetadata -ErrorRecord $toctouError
        Assert-PshGoal5ReleaseTrust ($null -ne $toctouError -and [int]$toctouMetadata.ExitCode -eq 5 -and [string]$toctouMetadata.ErrorId -ceq 'PshTrustSnapshotChanged') 'Mutable source replacement did not fail the post-verifier CAS.'
    }

    $catalogRace = New-PshGoal5ReleaseFixture -Root (Join-Path $testRoot 'catalog-race')
    $script:Goal5CatalogRaceMoved = $false
    $script:Goal5CatalogRaceRoot = $null
    $catalogRaceVerifier = {
        param($request)
        $script:Goal5CatalogRaceRoot = [IO.Path]::GetDirectoryName([string]$request.CatalogPath)
        try {
            [IO.File]::Move([string]$request.CatalogPath, ([string]$request.CatalogPath + '.authenticated'))
            $script:Goal5CatalogRaceMoved = $true
            [IO.File]::WriteAllText([string]$request.CatalogPath, 'replacement catalog', (New-Object Text.UTF8Encoding($false)))
        }
        catch { }
        [pscustomobject]@{ Trusted = $true; Publisher = 'Emvdy Software' }
    }
    $catalogRaceError = $null
    $catalogRaceHandle = $null
    try { $catalogRaceHandle = Invoke-PshGoal5ReleaseTrustHarness -IndexPath $catalogRace.IndexPath -ChecksumPath $catalogRace.ChecksumPath -CatalogPath $catalogRace.CatalogPath -PublisherPolicy $catalogRace.Policy -Verifier $catalogRaceVerifier }
    catch { $catalogRaceError = $_ }
    if ($script:Goal5CatalogRaceMoved) {
        $catalogRaceMetadata = Get-PshLifecycleErrorMetadata -ErrorRecord $catalogRaceError
        Assert-PshGoal5ReleaseTrust ($null -ne $catalogRaceError -and [string]$catalogRaceMetadata.ErrorId -ceq 'PshTrustSnapshotChanged') 'Catalog snapshot path replacement did not fail closed.'
        Assert-PshGoal5ReleaseTrust ([IO.Directory]::Exists([string]$script:Goal5CatalogRaceRoot)) 'Tampered catalog snapshot evidence was recursively removed.'
    }
    else {
        Assert-PshGoal5ReleaseTrust ($null -eq $catalogRaceError -and (Test-PshTrustedRelease -InputObject $catalogRaceHandle)) 'OS-enforced catalog snapshot lock did not permit safe trust completion.'
        Assert-PshGoal5ReleaseTrust (-not [IO.Directory]::Exists([string]$script:Goal5CatalogRaceRoot)) 'Untampered catalog snapshot root was not cleaned.'
    }

    $linkTarget = Join-Path $testRoot 'release-link-target'
    [void][IO.Directory]::CreateDirectory($linkTarget)
    $linkedCatalog = Join-Path $linkTarget 'release.cat'
    [IO.File]::WriteAllBytes($linkedCatalog, [IO.File]::ReadAllBytes($fixture.CatalogPath))
    $linkSentinel = Join-Path $linkTarget 'sentinel.txt'
    Write-PshGoal5ReleaseText -Path $linkSentinel -Text 'outside sentinel'
    $linkPath = Join-Path $fixture.Root 'catalog-link'
    if (New-PshGoal5ReleaseDirectoryLink -Path $linkPath -Target $linkTarget) {
        $script:Goal5LinkedVerifierCalls = 0
        Assert-PshGoal5ReleaseTrustFailure -Action {
            Invoke-PshGoal5ReleaseTrustHarness -IndexPath $fixture.IndexPath -ChecksumPath $fixture.ChecksumPath -CatalogPath (Join-Path $linkPath 'release.cat') -PublisherPolicy $fixture.Policy -Verifier { $script:Goal5LinkedVerifierCalls++; [pscustomobject]@{ Trusted = $true; Publisher = 'Emvdy Software' } }
        } -ExitCode 5 -ErrorId PshReparsePoint -Label 'catalog reparse ancestor'
        Assert-PshGoal5ReleaseTrust ($script:Goal5LinkedVerifierCalls -eq 0) 'Catalog verifier ran through a reparse ancestor.'
        Assert-PshGoal5ReleaseTrust ([IO.File]::ReadAllText($linkSentinel) -ceq 'outside sentinel') 'Catalog reparse rejection changed the external target.'
    }

    Assert-PshGoal5ReleaseTrustFailure -Action {
        Invoke-PshWindowsCatalogTrustVerifier -Request ([pscustomobject]@{ Offline = $true })
    } -ExitCode 4 -ErrorId PshOfflineTrustUnavailable -Label 'offline default verifier cache guarantee'

    $validIndexText = (ConvertTo-PshCanonicalJson -InputObject $fixture.Index) + "`n"
    $duplicateIndexText = $validIndexText.Replace('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1')
    Write-PshGoal5ReleaseText -Path $fixture.IndexPath -Text $duplicateIndexText
    Assert-PshGoal5ReleaseTrustFailure -Action { Read-PshReleaseIndex -Path $fixture.IndexPath } -ExitCode 5 -ErrorId PshDuplicateField -Label 'duplicate release index JSON key'
    $missingTagText = $validIndexText.Replace(',"tag":"v1.2.3"', '')
    Write-PshGoal5ReleaseText -Path $fixture.IndexPath -Text $missingTagText
    Assert-PshGoal5ReleaseTrustFailure -Action { Read-PshReleaseIndex -Path $fixture.IndexPath } -ExitCode 5 -ErrorId PshMissingField -Label 'missing release index field'
    Write-PshGoal5ReleaseText -Path $fixture.IndexPath -Text $validIndexText

    $indexMutations = @(
        @{ Label = 'unknown index field'; Id = 'PshUnknownField'; Apply = { param($x) $x | Add-Member -NotePropertyName unexpected -NotePropertyValue 1 } },
        @{ Label = 'wrong repository'; Id = 'PshReleaseRepository'; Apply = { param($x) $x.repository = 'https://example.invalid/Emvdy/psh' } },
        @{ Label = 'floating tag'; Id = 'PshReleaseTag'; Apply = { param($x) $x.tag = 'latest' } },
        @{ Label = 'uppercase source commit'; Id = 'PshReleaseSourceCommit'; Apply = { param($x) $x.sourceCommit = $x.sourceCommit.ToUpperInvariant() } },
        @{ Label = 'unsafe asset name'; Id = 'PshReleaseAssetName'; Apply = { param($x) $x.assets[0].name = '../core.zip' } },
        @{ Label = 'zero asset length'; Id = 'PshReleaseAssetLength'; Apply = { param($x) $x.assets[0].length = 0 } },
        @{ Label = 'uppercase asset hash'; Id = 'PshInvalidSha256'; Apply = { param($x) $x.assets[0].sha256 = $x.assets[0].sha256.ToUpperInvariant() } },
        @{ Label = 'HTTP asset URL'; Id = 'PshReleaseAssetUrl'; Apply = { param($x) $x.assets[0].url = $x.assets[0].url.Replace('https://', 'http://') } },
        @{ Label = 'query asset URL'; Id = 'PshReleaseAssetUrl'; Apply = { param($x) $x.assets[0].url = $x.assets[0].url + '?latest=1' } },
        @{ Label = 'custom-port asset URL'; Id = 'PshReleaseAssetUrl'; Apply = { param($x) $x.assets[0].url = $x.assets[0].url.Replace('github.com/', 'github.com:444/') } },
        @{ Label = 'duplicate asset name'; Id = 'PshReleaseAssetDuplicate'; Apply = { param($x) $copy = Copy-PshGoal5ReleaseObject $x.assets[0]; $x.assets = @($x.assets) + @($copy) } },
        @{ Label = 'Core architecture mismatch'; Id = 'PshReleasePackageArchitecture'; Apply = { param($x) $x.assets[0].package.architecture = 'win-x64' } },
        @{ Label = 'Full architecture mismatch'; Id = 'PshReleasePackageArchitecture'; Apply = { param($x) $x.assets[1].package.architecture = 'any' } },
        @{ Label = 'package name mismatch'; Id = 'PshReleasePackageName'; Apply = { param($x) $x.assets[0].name = 'psh-1.2.3-core-alt.zip'; $x.assets[0].url = 'https://github.com/Emvdy/psh/releases/download/v1.2.3/psh-1.2.3-core-alt.zip' } },
        @{ Label = 'non-package metadata'; Id = 'PshReleaseAssetPackage'; Apply = { param($x) $x.assets[2].package = Copy-PshGoal5ReleaseObject $x.assets[0].package } }
    )
    foreach ($mutation in $indexMutations) {
        $copy = Copy-PshGoal5ReleaseObject -Value $fixture.Index
        & ([scriptblock]$mutation.Apply) $copy
        Write-PshGoal5ReleaseJson -Path $fixture.IndexPath -Value $copy
        $expectedId = [string]$mutation.Id
        Assert-PshGoal5ReleaseTrustFailure -Action { Read-PshReleaseIndex -Path $fixture.IndexPath } -ExitCode 5 -ErrorId $expectedId -Label ([string]$mutation.Label)
    }
    Write-PshGoal5ReleaseText -Path $fixture.IndexPath -Text $validIndexText

    Write-PshGoal5ReleaseText -Path $fixture.ChecksumPath -Text "malformed`n"
    Assert-PshGoal5ReleaseTrustFailure -Action { Read-PshSha256Sums -Path $fixture.ChecksumPath } -ExitCode 5 -ErrorId PshChecksumLine -Label 'malformed SHA256SUMS'
    $bomPayload = (New-Object Text.UTF8Encoding($false)).GetBytes($fixture.ChecksumText)
    $bomBytes = New-Object byte[] ($bomPayload.Length + 3)
    $bomBytes[0] = 0xEF; $bomBytes[1] = 0xBB; $bomBytes[2] = 0xBF
    [Array]::Copy($bomPayload, 0, $bomBytes, 3, $bomPayload.Length)
    [IO.File]::WriteAllBytes($fixture.ChecksumPath, $bomBytes)
    Assert-PshGoal5ReleaseTrustFailure -Action { Read-PshSha256Sums -Path $fixture.ChecksumPath } -ExitCode 5 -ErrorId PshTrustFileBom -Label 'BOM SHA256SUMS'
    $checksumLines = @($fixture.ChecksumText.TrimEnd("`n").Split([char]10))
    Write-PshGoal5ReleaseText -Path $fixture.ChecksumPath -Text (($checksumLines[0], $checksumLines[0] -join "`n") + "`n")
    Assert-PshGoal5ReleaseTrustFailure -Action { Read-PshSha256Sums -Path $fixture.ChecksumPath } -ExitCode 5 -ErrorId PshReleaseAssetDuplicate -Label 'duplicate SHA256SUMS name'
    Write-PshGoal5ReleaseText -Path $fixture.ChecksumPath -Text $fixture.ChecksumText.TrimEnd("`n")
    Assert-PshGoal5ReleaseTrustFailure -Action { Read-PshSha256Sums -Path $fixture.ChecksumPath } -ExitCode 5 -ErrorId PshChecksumLineEnding -Label 'unterminated SHA256SUMS'
    Write-PshGoal5ReleaseText -Path $fixture.ChecksumPath -Text ((('0' * 64) + '  zero.zip') + "`n")
    Assert-PshGoal5ReleaseTrustFailure -Action { Read-PshSha256Sums -Path $fixture.ChecksumPath } -ExitCode 5 -ErrorId PshChecksumLine -Label 'zero SHA256SUMS hash'

    Write-PshGoal5ReleaseText -Path $fixture.ChecksumPath -Text (($checksumLines[0..1] -join "`n") + "`n")
    $missingChecksums = Read-PshSha256Sums -Path $fixture.ChecksumPath
    Assert-PshGoal5ReleaseTrustFailure -Action { Assert-PshReleaseIndexChecksums -Index $parsedIndex -Checksums $missingChecksums } -ExitCode 5 -ErrorId PshChecksumSet -Label 'missing SHA256SUMS entry'
    Write-PshGoal5ReleaseText -Path $fixture.ChecksumPath -Text ($fixture.ChecksumText + (('f' * 64) + '  extra.bin' + "`n"))
    $extraChecksums = Read-PshSha256Sums -Path $fixture.ChecksumPath
    Assert-PshGoal5ReleaseTrustFailure -Action { Assert-PshReleaseIndexChecksums -Index $parsedIndex -Checksums $extraChecksums } -ExitCode 5 -ErrorId PshChecksumSet -Label 'extra SHA256SUMS entry'
    $mismatchLines = @($checksumLines)
    $mismatchLines[0] = ('f' * 64) + '  ' + [string]$fixture.CoreAsset.name
    Write-PshGoal5ReleaseText -Path $fixture.ChecksumPath -Text (($mismatchLines -join "`n") + "`n")
    $mismatchChecksums = Read-PshSha256Sums -Path $fixture.ChecksumPath
    Assert-PshGoal5ReleaseTrustFailure -Action { Assert-PshReleaseIndexChecksums -Index $parsedIndex -Checksums $mismatchChecksums } -ExitCode 5 -ErrorId PshChecksumMismatch -Label 'mismatched SHA256SUMS hash'
    Write-PshGoal5ReleaseText -Path $fixture.ChecksumPath -Text $fixture.ChecksumText

    $policyNoCodeSigning = Copy-PshGoal5ReleaseObject -Value $fixture.Policy
    $policyNoCodeSigning.requiredEkuOids = @('1.2.3.4')
    Assert-PshGoal5ReleaseTrustFailure -Action { Assert-PshPublisherPolicy -Policy $policyNoCodeSigning } -ExitCode 5 -ErrorId PshPublisherPolicyEku -Label 'publisher policy without code-signing EKU'
    $policyDuplicateRoot = Copy-PshGoal5ReleaseObject -Value $fixture.Policy
    $policyDuplicateRoot.allowedRootCertificateSha256 = @($fixture.Policy.allowedRootCertificateSha256[0], $fixture.Policy.allowedRootCertificateSha256[0])
    Assert-PshGoal5ReleaseTrustFailure -Action { Assert-PshPublisherPolicy -Policy $policyDuplicateRoot } -ExitCode 5 -ErrorId PshReleaseDuplicate -Label 'publisher policy duplicate root'
    $policyZeroRoot = Copy-PshGoal5ReleaseObject -Value $fixture.Policy
    $policyZeroRoot.allowedRootCertificateSha256 = @(('0' * 64))
    Assert-PshGoal5ReleaseTrustFailure -Action { Assert-PshPublisherPolicy -Policy $policyZeroRoot } -ExitCode 5 -ErrorId PshPublisherPolicyRoot -Label 'publisher policy zero root'
    $policyUnknown = Copy-PshGoal5ReleaseObject -Value $fixture.Policy
    $policyUnknown | Add-Member -NotePropertyName thumbprints -NotePropertyValue @('legacy')
    Assert-PshGoal5ReleaseTrustFailure -Action { Assert-PshPublisherPolicy -Policy $policyUnknown } -ExitCode 5 -ErrorId PshUnknownField -Label 'publisher policy unknown field'

    $script:Goal5PackageSnapshotManifestBytes = [IO.File]::ReadAllBytes($fixture.ManifestPath)
    $script:Goal5PackageSnapshotCatalogBytes = [IO.File]::ReadAllBytes($fixture.PackageCatalogPath)
    $script:Goal5PackageSnapshotRoot = $null
    $packageSnapshotVerifier = {
        param($request)
        $script:Goal5PackageSnapshotRoot = [IO.Path]::GetDirectoryName([string]$request.ContentRoot)
        Assert-PshGoal5ReleaseTrust (@($request.SnapshotFiles).Count -eq 2) 'Package verifier did not receive manifest and catalog snapshots.'
        $manifestFile = @($request.SnapshotFiles | Where-Object { [string]$_.Role -ceq 'manifest' })[0]
        Assert-PshGoal5ReleaseTrust ([Convert]::ToBase64String((Get-PshTrustPathState -Path ([string]$manifestFile.Path) -Description 'fixture manifest snapshot').Bytes) -ceq [Convert]::ToBase64String($script:Goal5PackageSnapshotManifestBytes)) 'Package manifest snapshot bytes differ from the locked source.'
        Assert-PshGoal5ReleaseTrust ([Convert]::ToBase64String((Get-PshTrustPathState -Path ([string]$request.CatalogPath) -Description 'fixture package catalog snapshot').Bytes) -ceq [Convert]::ToBase64String($script:Goal5PackageSnapshotCatalogBytes)) 'Package catalog snapshot bytes differ from the locked source.'
        [pscustomobject][ordered]@{ Trusted = $true; Publisher = 'Emvdy Software'; Subject = 'fixture' }
    }
    $trustedPackage = Invoke-PshGoal5PackageTrustHarness -ManifestPath $fixture.ManifestPath -CatalogPath $fixture.PackageCatalogPath -PublisherPolicy $fixture.Policy -ExpectedAsset $fixture.CoreAsset -TrustedRelease $trusted -Verifier $packageSnapshotVerifier
    Assert-PshGoal5ReleaseTrust (-not [IO.Directory]::Exists([string]$script:Goal5PackageSnapshotRoot)) 'Package trust snapshot root was not removed after success.'
    Assert-PshGoal5ReleaseTrust (Test-PshTrustedPackageManifest -InputObject $trustedPackage) 'Valid package manifest did not mint a trusted handle.'
    $packageRecord = Assert-PshTrustedPackageManifest -InputObject $trustedPackage
    Assert-PshGoal5ReleaseTrust ([string]$packageRecord.Manifest.version -ceq $fixture.Version -and [string]$packageRecord.ManifestSha256 -ceq [string]$fixture.CoreAsset.package.packageManifestSha256) 'Trusted package manifest record is incorrect.'
    $trustedPackage.Manifest.version = '9.9.9'
    Assert-PshGoal5ReleaseTrust ([string](Assert-PshTrustedPackageManifest -InputObject $trustedPackage).Manifest.version -ceq $fixture.Version) 'Public package handle mutation changed the registered snapshot.'
    $forgedPackage = [pscustomobject]@{ TrustToken = $trustedPackage.TrustToken; Trusted = $true; Manifest = $fixture.Manifest }
    Assert-PshGoal5ReleaseTrust (-not (Test-PshTrustedPackageManifest -InputObject $forgedPackage)) 'Copied package TrustToken forged a trusted manifest.'
    Assert-PshGoal5ReleaseTrustFailure -Action { Assert-PshTrustedPackageManifest -InputObject $forgedPackage } -ExitCode 5 -ErrorId PshUntrustedPackageManifest -Label 'forged package manifest handle'

    $manifestRace = New-PshGoal5ReleaseFixture -Root (Join-Path $testRoot 'manifest-race')
    $script:Goal5ManifestRacePath = $manifestRace.ManifestPath
    $script:Goal5ManifestRaceMutationCount = 0
    $manifestRaceVerifier = {
        param($request)
        try {
            [IO.File]::WriteAllText($script:Goal5ManifestRacePath, '{"tampered":true}', (New-Object Text.UTF8Encoding($false)))
            $script:Goal5ManifestRaceMutationCount++
        }
        catch { }
        [pscustomobject]@{ Trusted = $true; Publisher = 'Emvdy Software' }
    }
    $manifestRaceError = $null
    $manifestRaceHandle = $null
    try {
        $manifestRaceHandle = Invoke-PshGoal5PackageTrustHarness -ManifestPath $manifestRace.ManifestPath -CatalogPath $manifestRace.PackageCatalogPath -PublisherPolicy $manifestRace.Policy -ExpectedAsset $fixture.CoreAsset -TrustedRelease $trusted -Verifier $manifestRaceVerifier
    }
    catch { $manifestRaceError = $_ }
    if ($script:Goal5ManifestRaceMutationCount -eq 0) {
        Assert-PshGoal5ReleaseTrust ($null -eq $manifestRaceError -and (Test-PshTrustedPackageManifest -InputObject $manifestRaceHandle)) 'OS-enforced manifest source lock did not permit safe trust completion.'
    }
    else {
        $manifestRaceMetadata = Get-PshLifecycleErrorMetadata -ErrorRecord $manifestRaceError
        Assert-PshGoal5ReleaseTrust ($null -ne $manifestRaceError -and [string]$manifestRaceMetadata.ErrorId -ceq 'PshTrustSnapshotChanged') 'Package manifest source replacement did not fail the post-verifier CAS.'
    }

    $forgedExpectedAsset = Copy-PshGoal5ReleaseObject -Value $fixture.CoreAsset
    $forgedExpectedAsset.package.packageManifestSha256 = ('f' * 64)
    $trustedPackageFromName = Invoke-PshGoal5PackageTrustHarness -ManifestPath $fixture.ManifestPath -CatalogPath $fixture.PackageCatalogPath -PublisherPolicy $fixture.Policy -ExpectedAsset $forgedExpectedAsset -TrustedRelease $trusted -Verifier $validVerifier
    Assert-PshGoal5ReleaseTrust (Test-PshTrustedPackageManifest -InputObject $trustedPackageFromName) 'Expected asset name did not resolve back to authenticated metadata.'
    $missingAsset = Copy-PshGoal5ReleaseObject -Value $fixture.CoreAsset
    $missingAsset.name = 'missing.zip'
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Invoke-PshGoal5PackageTrustHarness -ManifestPath $fixture.ManifestPath -CatalogPath $fixture.PackageCatalogPath -PublisherPolicy $fixture.Policy -ExpectedAsset $missingAsset -TrustedRelease $trusted -Verifier $validVerifier
    } -ExitCode 5 -ErrorId PshManifestAssetTrust -Label 'package manifest missing authenticated asset'

    $validManifestText = (ConvertTo-PshCanonicalJson -InputObject $fixture.Manifest) + "`n"
    $duplicateManifestText = $validManifestText.Replace('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1')
    Write-PshGoal5ReleaseText -Path $fixture.ManifestPath -Text $duplicateManifestText
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Invoke-PshGoal5PackageTrustHarness -ManifestPath $fixture.ManifestPath -CatalogPath $fixture.PackageCatalogPath -PublisherPolicy $fixture.Policy -ExpectedAsset $fixture.CoreAsset -TrustedRelease $trusted -Verifier $validVerifier
    } -ExitCode 5 -ErrorId PshDuplicateField -Label 'duplicate package manifest JSON key'
    $manifestMismatch = Copy-PshGoal5ReleaseObject -Value $fixture.Manifest
    $manifestMismatch.version = '1.2.4'
    Write-PshGoal5ReleaseJson -Path $fixture.ManifestPath -Value $manifestMismatch
    Assert-PshGoal5ReleaseTrustFailure -Action {
        Invoke-PshGoal5PackageTrustHarness -ManifestPath $fixture.ManifestPath -CatalogPath $fixture.PackageCatalogPath -PublisherPolicy $fixture.Policy -ExpectedAsset $fixture.CoreAsset -TrustedRelease $trusted -Verifier $validVerifier
    } -ExitCode 5 -ErrorId PshManifestReleaseMismatch -Label 'package manifest release mismatch'
    Write-PshGoal5ReleaseText -Path $fixture.ManifestPath -Text $validManifestText
}
finally {
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Variable Goal5SnapshotOriginalCatalog, Goal5SnapshotIndexBytes, Goal5SnapshotChecksumBytes, Goal5SnapshotCatalogBytes, Goal5SnapshotRoot, Goal5ToctouIndexPath, Goal5ToctouChecksumPath, Goal5ToctouCatalogPath, Goal5ToctouMutationCount, Goal5CatalogRaceMoved, Goal5CatalogRaceRoot, Goal5LinkedVerifierCalls, Goal5PackageSnapshotManifestBytes, Goal5PackageSnapshotCatalogBytes, Goal5PackageSnapshotRoot, Goal5ManifestRacePath, Goal5ManifestRaceMutationCount -Scope Script -ErrorAction SilentlyContinue
}

Write-Output "Goal 5 release trust passed ($script:Goal5ReleaseTrustAssertions assertions)."
}
finally {
    try { Set-Item -Path Function:Get-PshAuthenticodePublisherPolicy -Value $script:Goal5OriginalAuthenticodePolicy -ErrorAction Stop } catch { }
    try { Set-Item -Path Function:Invoke-PshWindowsCatalogTrustVerifier -Value $script:Goal5OriginalWindowsCatalogVerifier -ErrorAction Stop } catch { }
    Remove-Variable Goal5OriginalAuthenticodePolicy, Goal5OriginalWindowsCatalogVerifier, Goal5ActivePublisherPolicy, Goal5ActiveCatalogVerifier -Scope Script -ErrorAction SilentlyContinue
}
