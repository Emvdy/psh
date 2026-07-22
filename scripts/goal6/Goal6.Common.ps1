# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version 2.0

function Assert-PshGoal6Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Get-PshGoal6Utf8Encoding {
    return (New-Object Text.UTF8Encoding -ArgumentList @($false, $true))
}

function Get-PshGoal6StrictText {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-PshGoal6Condition ([IO.File]::Exists($Path)) "Required file is missing: $Path"
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-PshGoal6Condition (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "File must be UTF-8 without a BOM: $Path"
    try { return (Get-PshGoal6Utf8Encoding).GetString($bytes) }
    catch { throw "File is not valid UTF-8: $Path" }
}

function Write-PshGoal6Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($fullPath, $normalized, (Get-PshGoal6Utf8Encoding))
}

function Write-PshGoal6Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][object]$InputObject,
        [int]$Depth = 30
    )

    $json = if ($null -eq $InputObject) { 'null' } else { [string](ConvertTo-Json -InputObject $InputObject -Depth $Depth) }
    Write-PshGoal6Text -Path $Path -Text ($json + "`n")
}

function Get-PshGoal6Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-PshGoal6Condition ([IO.File]::Exists($Path)) "File to hash is missing: $Path"
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Get-PshGoal6Sha512Base64 {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-PshGoal6Condition ([IO.File]::Exists($Path)) "File to hash is missing: $Path"
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA512]::Create()
    try { return [Convert]::ToBase64String($algorithm.ComputeHash($stream)) }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Get-PshGoal6Property {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-PshGoal6PropertyName {
    param([Parameter(Mandatory = $true)][object]$InputObject)
    return @($InputObject.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Assert-PshGoal6Property {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $names = @(Get-PshGoal6PropertyName -InputObject $InputObject)
    foreach ($name in $Required) {
        Assert-PshGoal6Condition ($names -ccontains $name) "$Description is missing property '$name'."
    }
    foreach ($name in $names) {
        Assert-PshGoal6Condition ($Allowed -ccontains $name) "$Description contains unsupported property '$name'."
    }
}

function Assert-PshGoal6Sha256Value {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshGoal6Condition ($Value -match '\A[0-9a-f]{64}\z' -and $Value -notmatch '\A0{64}\z') "$Description is not a lowercase SHA256 value."
}

function Assert-PshGoal6PinnedUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshGoal6Condition ($Url -match '\Ahttps://') "$Description must use HTTPS."
    Assert-PshGoal6Condition ($Url -notmatch '(?i)(^|[/=])latest([/?#.]|$)') "$Description contains a floating latest reference."
    Assert-PshGoal6Condition ($Url -notmatch '(?i)/(main|master)([/?.#]|$)') "$Description contains a floating branch reference."
}

function Assert-PshGoal6LeafName {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshGoal6Condition (-not [string]::IsNullOrWhiteSpace($Value)) "$Description is empty."
    Assert-PshGoal6Condition ($Value -cne '.' -and $Value -cne '..') "$Description is not a file leaf name."
    Assert-PshGoal6Condition ($Value -notmatch '[/\\]') "$Description must be a single file leaf name."
    Assert-PshGoal6Condition ([IO.Path]::GetFileName($Value) -ceq $Value) "$Description must be a single file leaf name."
    Assert-PshGoal6Condition ($Value -notmatch '[:*?"<>|]') "$Description contains an invalid file-name character."
}

function Resolve-PshGoal6RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshGoal6Condition (-not [string]::IsNullOrWhiteSpace($RelativePath)) "$Description is empty."
    Assert-PshGoal6Condition (-not [IO.Path]::IsPathRooted($RelativePath)) "$Description is rooted."
    Assert-PshGoal6Condition ($RelativePath -notmatch '\\') "$Description must use forward slashes."
    $segments = @($RelativePath.Split('/'))
    Assert-PshGoal6Condition (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "$Description contains an empty segment."
    Assert-PshGoal6Condition ($segments -notcontains '.' -and $segments -notcontains '..') "$Description contains a traversal segment."
    Assert-PshGoal6Condition ($RelativePath -notmatch '[:*?"<>|]') "$Description contains an invalid path character."

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $fullRoot $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    Assert-PshGoal6Condition ($candidate.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)) "$Description escapes its root."
    return $candidate
}

function ConvertTo-PshGoal6UtcTimestamp {
    param([AllowNull()][object]$Value)

    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
    return [string]$Value
}

function Get-PshGoal6TrustedDependencyData {
    return [ordered]@{
        gitleaks = [ordered]@{
            Version = '8.30.1'
            DisplayName = 'gitleaks'
            Usage = 'ci-only-secret-scanner'
            Platform = 'windows-x64'
            Repository = 'https://github.com/gitleaks/gitleaks'
            Tag = 'v8.30.1'
            Commit = '83d9cd684c87d95d656c1458ef04895a7f1cbd8e'
            ReleaseUrl = 'https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1'
            GalleryMetadataUrl = ''
            PackageUrl = 'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_windows_x64.zip'
            PackageFileName = 'gitleaks_8.30.1_windows_x64.zip'
            PackageSize = 8438883
            PackageSha256 = 'd29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e'
            ChecksumsUrl = 'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_checksums.txt'
            ChecksumsSha256 = '061476c21adaf5441516f96f185c1a4706a83cd6329b9b38762271b3d4a52fae'
            ChecksumsSize = 999
            ExecutableArchivePath = 'gitleaks.exe'
            ModuleManifestArchivePath = ''
            InstalledRelativePath = 'gitleaks/8.30.1/win-x64/gitleaks.exe'
            InstalledSha256 = '17157e2ee8b76fc8b1d8bee607a250e34b8a8023c8bc81822d4b5ee4d78fcb7c'
            InstalledSize = 22575104
            LicenseArchivePath = 'LICENSE'
            LicenseInPackage = $true
            LicenseSpdxId = 'MIT'
            LicenseSourceUrl = 'https://raw.githubusercontent.com/gitleaks/gitleaks/83d9cd684c87d95d656c1458ef04895a7f1cbd8e/LICENSE'
            LicenseRetainedPath = 'scripts/goal6/licenses/gitleaks-8.30.1/LICENSE'
            LicenseSha256 = 'e3884b252b3bfc045e55be43a34d1e80da070bc6f804ac95bf4660e97d62ebc6'
            LicenseSize = 1069
            ProvenanceRetainedPath = 'scripts/goal6/licenses/gitleaks-8.30.1/PROVENANCE.md'
            ProvenanceSha256 = 'af11ff5e137d13b7e59eccd2d4810aaec09a05c0b5210332b7d56add4d970ec1'
        }
        pester = [ordered]@{
            Version = '5.9.0'
            DisplayName = 'Pester'
            Usage = 'ci-only-powershell-test-framework'
            Platform = 'any'
            Repository = 'https://github.com/pester/Pester'
            Tag = '5.9.0'
            Commit = '8b10038031899d023ab5875f99c29bc7b11451d9'
            ReleaseUrl = 'https://github.com/pester/Pester/releases/tag/5.9.0'
            GalleryMetadataUrl = "https://www.powershellgallery.com/api/v2/Packages(Id='Pester',Version='5.9.0')"
            PackageUrl = 'https://www.powershellgallery.com/api/v2/package/Pester/5.9.0'
            PackageFileName = 'Pester.5.9.0.nupkg'
            PackageSize = 327975
            PackageSha256 = '5a0fd80b361600bf4bbd4c307c1fd01b17f11668bab19e657add41b00ad22ab9'
            GallerySha512Base64 = 'DIfd4Itvse518HCzS/doIs7ZZ2IgtAQeKr2y3MScezDeR5rqLBoQURCoQ/XNcBTxiqFNwT2ILdI5Gg2sI3CdkQ=='
            ChecksumsUrl = ''
            ExecutableArchivePath = ''
            ModuleManifestArchivePath = 'Pester.psd1'
            InstalledRelativePath = 'Pester/5.9.0/Pester.psd1'
            InstalledSha256 = 'a35b3320360821222bf138906af05fb7d4474ae2f24f5840bd53c15f144ccb9e'
            InstalledSize = 21594
            LicenseArchivePath = ''
            LicenseInPackage = $false
            LicenseSpdxId = 'Apache-2.0'
            LicenseSourceUrl = 'https://raw.githubusercontent.com/pester/Pester/8b10038031899d023ab5875f99c29bc7b11451d9/LICENSE'
            LicenseRetainedPath = 'scripts/goal6/licenses/Pester-5.9.0/LICENSE'
            LicenseSha256 = '6a2fc73db70e674162600052e12a6537e93b51d5dfcf2340c4ed08cdb174debb'
            LicenseSize = 579
            ProvenanceRetainedPath = 'scripts/goal6/licenses/Pester-5.9.0/PROVENANCE.md'
            ProvenanceSha256 = '71c31467eb206dc0c44f97790daf3c89ea839144a3bd2a3ba49b1c9ebceaadb8'
        }
        psscriptanalyzer = [ordered]@{
            Version = '1.25.0'
            DisplayName = 'PSScriptAnalyzer'
            Usage = 'ci-only-powershell-static-analysis'
            Platform = 'any'
            Repository = 'https://github.com/PowerShell/PSScriptAnalyzer'
            Tag = '1.25.0'
            Commit = 'f05704df81b2aca17dc027ee39b3fce106d418fc'
            ReleaseUrl = ''
            GalleryMetadataUrl = "https://www.powershellgallery.com/api/v2/Packages(Id='PSScriptAnalyzer',Version='1.25.0')"
            PackageUrl = 'https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/1.25.0'
            PackageFileName = 'PSScriptAnalyzer.1.25.0.nupkg'
            PackageSize = 14658674
            PackageSha256 = '14e634c828eb98efb9f40b2918ba90f139ed5eccdf663a2a747736d996995d60'
            GallerySha512Base64 = '5/tXMmLmBLqymRSuYpIdJLl8L4i1GbQSd7QD72zhY/FLfRs23HNEmmjlrlqNlQKJGxDCZBMf0YE63ym/ExwWYw=='
            ChecksumsUrl = ''
            ExecutableArchivePath = ''
            ModuleManifestArchivePath = 'PSScriptAnalyzer.psd1'
            InstalledRelativePath = 'PSScriptAnalyzer/1.25.0/PSScriptAnalyzer.psd1'
            InstalledSha256 = '2b219f688bcdd67101040f845e530b22907d39bbf49089b4b5b2afaba7996791'
            InstalledSize = 17822
            LicenseArchivePath = 'LICENSE'
            LicenseInPackage = $true
            LicenseSpdxId = 'MIT'
            LicenseSourceUrl = 'https://raw.githubusercontent.com/PowerShell/PSScriptAnalyzer/f05704df81b2aca17dc027ee39b3fce106d418fc/LICENSE'
            LicenseRetainedPath = 'scripts/goal6/licenses/PSScriptAnalyzer-1.25.0/LICENSE'
            LicenseSha256 = '646f8936b8ddcd14e13e578ff6857e368780b0d1a4f6066bee89211923a373e2'
            LicenseSize = 1073
            ProvenanceRetainedPath = 'scripts/goal6/licenses/PSScriptAnalyzer-1.25.0/PROVENANCE.md'
            ProvenanceSha256 = 'edb48eeaf6649bede632b4c4c5e98f4b755b90fdc9fb8909e6dfc51ddf1a06f0'
        }
    }
}

function Read-PshGoal6DependencyLock {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$LockPath
    )

    $repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
    $lockText = Get-PshGoal6StrictText -Path ([IO.Path]::GetFullPath($LockPath))
    try { $lock = $lockText | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Goal 6 dependency lock is invalid JSON: $($_.Exception.Message)" }

    Assert-PshGoal6Property -InputObject $lock -Required @('schemaVersion', 'manifest', 'dependencies') -Allowed @('schemaVersion', 'manifest', 'dependencies') -Description 'Goal 6 dependency lock'
    Assert-PshGoal6Condition ([int]$lock.schemaVersion -eq 2) 'Goal 6 dependency lock schemaVersion must be 2.'
    Assert-PshGoal6Property -InputObject $lock.manifest -Required @('created', 'namespaceSeed') -Allowed @('created', 'namespaceSeed') -Description 'Goal 6 dependency lock manifest'
    Assert-PshGoal6Condition ((ConvertTo-PshGoal6UtcTimestamp $lock.manifest.created) -ceq '2026-07-22T00:00:00Z') 'Goal 6 dependency lock created timestamp changed.'
    Assert-PshGoal6Condition ([string]$lock.manifest.namespaceSeed -ceq 'goal6-ci-quality-dependencies-v2') 'Goal 6 dependency lock namespace seed changed.'

    $dependencies = @($lock.dependencies)
    Assert-PshGoal6Condition ($dependencies.Count -eq 3) 'Goal 6 dependency lock must contain exactly three CI dependencies.'
    $ids = @($dependencies | ForEach-Object { [string]$_.id })
    Assert-PshGoal6Condition (($ids -join '|') -ceq 'gitleaks|pester|psscriptanalyzer') 'Goal 6 dependencies must be ordered gitleaks, pester, psscriptanalyzer.'
    $trusted = Get-PshGoal6TrustedDependencyData

    foreach ($dependency in $dependencies) {
        Assert-PshGoal6Property -InputObject $dependency -Required @('id', 'displayName', 'version', 'usage', 'platform', 'source', 'package', 'license', 'provenance') -Allowed @('id', 'displayName', 'version', 'usage', 'platform', 'source', 'package', 'license', 'provenance') -Description 'Goal 6 dependency'
        $id = [string]$dependency.id
        Assert-PshGoal6Condition ($trusted.Contains($id)) "Untrusted Goal 6 dependency: $id"
        $pin = $trusted[$id]
        Assert-PshGoal6Condition ([string]$dependency.version -ceq [string]$pin.Version) "$id version changed."
        Assert-PshGoal6Condition ([string]$dependency.displayName -ceq [string]$pin.DisplayName) "$id display name changed."
        Assert-PshGoal6Condition ([string]$dependency.usage -ceq [string]$pin.Usage) "$id usage changed."
        Assert-PshGoal6Condition ([string]$dependency.platform -ceq [string]$pin.Platform) "$id platform changed."

        Assert-PshGoal6Property -InputObject $dependency.source -Required @('repository', 'tag', 'commit') -Allowed @('repository', 'tag', 'commit', 'releaseUrl', 'galleryMetadataUrl') -Description "$id source"
        Assert-PshGoal6PinnedUrl -Url ([string]$dependency.source.repository) -Description "$id source repository"
        Assert-PshGoal6Condition ([string]$dependency.source.repository -ceq [string]$pin.Repository) "$id source repository is not trusted."
        Assert-PshGoal6Condition ([string]$dependency.source.tag -ceq [string]$pin.Tag) "$id source tag changed."
        Assert-PshGoal6Condition ([string]$dependency.source.commit -ceq [string]$pin.Commit) "$id source commit changed."
        foreach ($urlName in @('releaseUrl', 'galleryMetadataUrl')) {
            $url = [string](Get-PshGoal6Property -InputObject $dependency.source -Name $urlName)
            if (-not [string]::IsNullOrWhiteSpace($url)) { Assert-PshGoal6PinnedUrl -Url $url -Description "$id source $urlName" }
            $expectedUrl = if ($urlName -ceq 'releaseUrl') { [string]$pin.ReleaseUrl } else { [string]$pin.GalleryMetadataUrl }
            Assert-PshGoal6Condition ($url -ceq $expectedUrl) "$id source $urlName changed."
        }

        Assert-PshGoal6Property -InputObject $dependency.package -Required @('url', 'fileName', 'archiveType', 'sha256', 'size', 'installedRelativePath', 'installedSha256', 'installedSize') -Allowed @('url', 'fileName', 'archiveType', 'sha256', 'size', 'checksumsUrl', 'checksumsSha256', 'checksumsSize', 'executableArchivePath', 'moduleManifestArchivePath', 'installedRelativePath', 'installedSha256', 'installedSize', 'peMachine', 'galleryHashAlgorithm', 'gallerySha512Base64') -Description "$id package"
        Assert-PshGoal6PinnedUrl -Url ([string]$dependency.package.url) -Description "$id package URL"
        Assert-PshGoal6Condition ([string]$dependency.package.url -ceq [string]$pin.PackageUrl) "$id package URL changed."
        Assert-PshGoal6LeafName -Value ([string]$dependency.package.fileName) -Description "$id package fileName"
        Assert-PshGoal6Condition ([string]$dependency.package.fileName -ceq [string]$pin.PackageFileName) "$id package fileName changed."
        Assert-PshGoal6Condition ([string]$dependency.package.archiveType -ceq 'zip') "$id archive type must be zip."
        Assert-PshGoal6Sha256Value -Value ([string]$dependency.package.sha256) -Description "$id package SHA256"
        Assert-PshGoal6Condition ([string]$dependency.package.sha256 -ceq [string]$pin.PackageSha256) "$id package SHA256 changed."
        Assert-PshGoal6Condition ([int64]$dependency.package.size -gt 0 -and [int64]$dependency.package.installedSize -gt 0) "$id package sizes must be positive."
        Assert-PshGoal6Condition ([int64]$dependency.package.size -eq [int64]$pin.PackageSize) "$id package size changed."
        Assert-PshGoal6Sha256Value -Value ([string]$dependency.package.installedSha256) -Description "$id installed SHA256"
        Assert-PshGoal6Condition ([string]$dependency.package.installedSha256 -ceq [string]$pin.InstalledSha256) "$id installed SHA256 changed."
        Assert-PshGoal6Condition ([int64]$dependency.package.installedSize -eq [int64]$pin.InstalledSize) "$id installed size changed."
        [void](Resolve-PshGoal6RelativePath -Root $repositoryRootPath -RelativePath ([string]$dependency.package.installedRelativePath) -Description "$id installed relative path")
        Assert-PshGoal6Condition ([string]$dependency.package.installedRelativePath -ceq [string]$pin.InstalledRelativePath) "$id installed relative path changed."

        if ($id -ceq 'gitleaks') {
            Assert-PshGoal6PinnedUrl -Url ([string]$dependency.package.checksumsUrl) -Description 'gitleaks checksums URL'
            Assert-PshGoal6Condition ([string]$dependency.package.checksumsUrl -ceq [string]$pin.ChecksumsUrl) 'gitleaks checksums URL changed.'
            Assert-PshGoal6Sha256Value -Value ([string]$dependency.package.checksumsSha256) -Description 'gitleaks checksums SHA256'
            Assert-PshGoal6Condition ([string]$dependency.package.checksumsSha256 -ceq [string]$pin.ChecksumsSha256) 'gitleaks checksums SHA256 changed.'
            Assert-PshGoal6Condition ([int64]$dependency.package.checksumsSize -eq [int64]$pin.ChecksumsSize) 'gitleaks checksums size changed.'
            Assert-PshGoal6Condition ([string]$dependency.package.executableArchivePath -ceq [string]$pin.ExecutableArchivePath) 'gitleaks executable archive path changed.'
            Assert-PshGoal6Condition ([string]$dependency.package.peMachine -ceq '0x8664') 'gitleaks PE machine must be x64.'
        }
        else {
            Assert-PshGoal6Condition ([string]$dependency.package.moduleManifestArchivePath -ceq [string]$pin.ModuleManifestArchivePath) "$id module manifest archive path changed."
            Assert-PshGoal6Condition ([string]$dependency.package.galleryHashAlgorithm -ceq 'SHA512') "$id Gallery hash algorithm must be SHA512."
            Assert-PshGoal6Condition ([string]$dependency.package.gallerySha512Base64 -ceq [string]$pin.GallerySha512Base64) "$id Gallery SHA512 changed."
        }

        Assert-PshGoal6Property -InputObject $dependency.license -Required @('spdxId', 'packageContainsLicense', 'archivePath', 'sourceUrl', 'retainedPath', 'sha256', 'size') -Allowed @('spdxId', 'packageContainsLicense', 'archivePath', 'sourceUrl', 'retainedPath', 'sha256', 'size') -Description "$id license"
        Assert-PshGoal6Condition ([string]$dependency.license.spdxId -ceq [string]$pin.LicenseSpdxId) "$id license SPDX identifier changed."
        Assert-PshGoal6Condition ($dependency.license.packageContainsLicense -is [bool]) "$id packageContainsLicense must be a JSON boolean."
        Assert-PshGoal6Condition ([bool]$dependency.license.packageContainsLicense -eq [bool]$pin.LicenseInPackage) "$id package-license policy changed."
        $archiveLicenseValue = Get-PshGoal6Property -InputObject $dependency.license -Name 'archivePath'
        $archiveLicensePath = [string]$archiveLicenseValue
        if ([bool]$pin.LicenseInPackage) {
            [void](Resolve-PshGoal6RelativePath -Root $repositoryRootPath -RelativePath $archiveLicensePath -Description "$id archive license path")
        }
        else {
            Assert-PshGoal6Condition ($null -eq $archiveLicenseValue) "$id package does not embed a license; archivePath must be null."
        }
        Assert-PshGoal6Condition ($archiveLicensePath -ceq [string]$pin.LicenseArchivePath) "$id archive license path changed."
        Assert-PshGoal6PinnedUrl -Url ([string]$dependency.license.sourceUrl) -Description "$id license source URL"
        Assert-PshGoal6Condition ([string]$dependency.license.sourceUrl -ceq [string]$pin.LicenseSourceUrl) "$id license source URL changed."
        Assert-PshGoal6Sha256Value -Value ([string]$dependency.license.sha256) -Description "$id license SHA256"
        Assert-PshGoal6Condition ([string]$dependency.license.sha256 -ceq [string]$pin.LicenseSha256) "$id license SHA256 changed."
        Assert-PshGoal6Condition ([int64]$dependency.license.size -eq [int64]$pin.LicenseSize) "$id license size changed."
        $licensePath = Resolve-PshGoal6RelativePath -Root $repositoryRootPath -RelativePath ([string]$dependency.license.retainedPath) -Description "$id retained license path"
        Assert-PshGoal6Condition ([string]$dependency.license.retainedPath -ceq [string]$pin.LicenseRetainedPath) "$id retained license path changed."
        Assert-PshGoal6Condition ([IO.File]::Exists($licensePath)) "$id retained license is missing."
        Assert-PshGoal6Condition ((Get-PshGoal6Sha256 -Path $licensePath) -ceq [string]$dependency.license.sha256) "$id retained license SHA256 mismatches."
        Assert-PshGoal6Condition ([int64](Get-Item -LiteralPath $licensePath).Length -eq [int64]$dependency.license.size) "$id retained license size mismatches."

        Assert-PshGoal6Property -InputObject $dependency.provenance -Required @('retainedPath', 'sha256') -Allowed @('retainedPath', 'sha256') -Description "$id provenance"
        Assert-PshGoal6Sha256Value -Value ([string]$dependency.provenance.sha256) -Description "$id provenance SHA256"
        Assert-PshGoal6Condition ([string]$dependency.provenance.sha256 -ceq [string]$pin.ProvenanceSha256) "$id provenance SHA256 changed."
        $provenancePath = Resolve-PshGoal6RelativePath -Root $repositoryRootPath -RelativePath ([string]$dependency.provenance.retainedPath) -Description "$id retained provenance path"
        Assert-PshGoal6Condition ([string]$dependency.provenance.retainedPath -ceq [string]$pin.ProvenanceRetainedPath) "$id retained provenance path changed."
        Assert-PshGoal6Condition ([IO.File]::Exists($provenancePath)) "$id retained provenance is missing."
        Assert-PshGoal6Condition ((Get-PshGoal6Sha256 -Path $provenancePath) -ceq [string]$dependency.provenance.sha256) "$id retained provenance SHA256 mismatches."
    }

    return $lock
}

function Get-PshGoal6Dependency {
    param(
        [Parameter(Mandatory = $true)][object]$Lock,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $dependencyMatches = @($Lock.dependencies | Where-Object { [string]$_.id -ceq $Id })
    Assert-PshGoal6Condition ($dependencyMatches.Count -eq 1) "Goal 6 dependency '$Id' is missing or duplicated."
    return $dependencyMatches[0]
}

function Complete-PshGoal6DependencyInstall {
    param(
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$SummaryPath,
        [Parameter(Mandatory = $true)][object]$Summary
    )

    $stagingRootPath = [IO.Path]::GetFullPath($StagingRoot)
    $destinationRootPath = [IO.Path]::GetFullPath($DestinationRoot)
    Assert-PshGoal6Condition ([IO.Directory]::Exists($stagingRootPath)) "Dependency staging directory is missing: $stagingRootPath"
    Assert-PshGoal6Condition (-not [IO.File]::Exists($destinationRootPath) -and -not [IO.Directory]::Exists($destinationRootPath)) "Dependency destination already exists: $destinationRootPath"

    [IO.Directory]::Move($stagingRootPath, $destinationRootPath)
    try {
        Write-PshGoal6Json -Path ([IO.Path]::GetFullPath($SummaryPath)) -InputObject $Summary
    }
    catch {
        $summaryFailure = [string]$_.Exception.Message
        try { [IO.Directory]::Delete($destinationRootPath, $true) }
        catch { throw "Dependency install summary failed and committed-directory rollback also failed: summary=$summaryFailure; rollback=$($_.Exception.Message)" }
        throw "Dependency install summary failed; committed dependency directory was rolled back: $summaryFailure"
    }
}

function ConvertTo-PshGoal6GitRefMap {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory = $true)][ValidateSet('remote', 'local-branches', 'local-tags')][string]$Kind
    )

    $result = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($lineValue in $Lines) {
        $line = [string]$lineValue
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        Assert-PshGoal6Condition ($line -match '\A([0-9a-f]{40})\s+(refs/\S+)\z') "Git ref output is malformed: $line"
        $objectId = [string]$Matches[1]
        $refName = [string]$Matches[2]
        $canonicalName = $null
        switch ($Kind) {
            'remote' {
                Assert-PshGoal6Condition ($refName.StartsWith('refs/heads/', [StringComparison]::Ordinal) -or $refName.StartsWith('refs/tags/', [StringComparison]::Ordinal)) "Remote ref is outside heads/tags: $refName"
                $canonicalName = $refName
            }
            'local-branches' {
                Assert-PshGoal6Condition ($refName.StartsWith('refs/remotes/origin/', [StringComparison]::Ordinal)) "Local remote-tracking ref is outside origin: $refName"
                if ($refName -ceq 'refs/remotes/origin/HEAD') { continue }
                $canonicalName = 'refs/heads/' + $refName.Substring('refs/remotes/origin/'.Length)
            }
            'local-tags' {
                Assert-PshGoal6Condition ($refName.StartsWith('refs/tags/', [StringComparison]::Ordinal)) "Local tag ref is malformed: $refName"
                $canonicalName = $refName
            }
        }
        Assert-PshGoal6Condition (-not $result.ContainsKey($canonicalName)) "Git ref output contains a duplicate ref: $canonicalName"
        $result.Add($canonicalName, $objectId)
    }
    return ,$result
}

function Assert-PshGoal6RemoteRefCoverage {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RemoteLines,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$LocalBranchLines,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$LocalTagLines
    )

    $remote = ConvertTo-PshGoal6GitRefMap -Lines $RemoteLines -Kind remote
    $localBranches = ConvertTo-PshGoal6GitRefMap -Lines $LocalBranchLines -Kind local-branches
    $localTags = ConvertTo-PshGoal6GitRefMap -Lines $LocalTagLines -Kind local-tags
    Assert-PshGoal6Condition ($remote.Count -gt 0) 'Remote branch/tag discovery returned no refs.'
    Assert-PshGoal6Condition (@($remote.Keys | Where-Object { $_.StartsWith('refs/heads/', [StringComparison]::Ordinal) }).Count -gt 0) 'Remote branch discovery returned no heads.'

    $local = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($key in $localBranches.Keys) { $local.Add($key, $localBranches[$key]) }
    foreach ($key in $localTags.Keys) { $local.Add($key, $localTags[$key]) }
    $differences = New-Object System.Collections.Generic.List[string]
    foreach ($key in $remote.Keys) {
        if (-not $local.ContainsKey($key)) { $differences.Add("missing-local:$key"); continue }
        if ([string]$local[$key] -cne [string]$remote[$key]) { $differences.Add("object-mismatch:$key") }
    }
    foreach ($key in $local.Keys) {
        if (-not $remote.ContainsKey($key)) { $differences.Add("stale-local:$key") }
    }
    Assert-PshGoal6Condition ($differences.Count -eq 0) "Local origin branch/tag refs are not an exact fetched copy of the remote: $($differences -join ', ')"

    return [pscustomobject][ordered]@{
        remoteRefCount = $remote.Count
        branchCount = @($remote.Keys | Where-Object { $_.StartsWith('refs/heads/', [StringComparison]::Ordinal) }).Count
        tagCount = @($remote.Keys | Where-Object { $_.StartsWith('refs/tags/', [StringComparison]::Ordinal) }).Count
        parity = 'exact'
    }
}

function Get-PshGoal6PeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-PshGoal6Condition ($bytes.Length -ge 64 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) "File is not a PE image: $Path"
    $offset = [BitConverter]::ToInt32($bytes, 0x3C)
    Assert-PshGoal6Condition ($offset -ge 0 -and $offset + 6 -le $bytes.Length) "PE offset is invalid: $Path"
    Assert-PshGoal6Condition ($bytes[$offset] -eq 0x50 -and $bytes[$offset + 1] -eq 0x45 -and $bytes[$offset + 2] -eq 0 -and $bytes[$offset + 3] -eq 0) "PE signature is invalid: $Path"
    return ('0x{0:X4}' -f [BitConverter]::ToUInt16($bytes, $offset + 4))
}
