# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$script:Assertions = 0
$script:ExpectedTools = @('bat', 'fd', 'jq', 'rg')
$script:ExpectedArtifacts = @('win-x64', 'win-arm64')

function Assert-PshGoal4 {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:Assertions++
    if (-not $Condition) { throw "Goal 4 acceptance failed: $Message" }
}

function Get-PshGoal4Property {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-PshGoal4Array {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string]$Name)
    $value = Get-PshGoal4Property -InputObject $InputObject -Name $Name
    if ($null -eq $value) { return @() }
    return @($value)
}

function ConvertTo-PshGoal4UtcTimestamp {
    param([AllowNull()][object]$Value)

    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Get-PshGoal4StrictText {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-PshGoal4 (Test-Path -LiteralPath $Path -PathType Leaf) "Missing file: $Path"
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-PshGoal4 (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "UTF-8 BOM found in $Path"
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
    try { return $encoding.GetString($bytes) }
    catch { throw "Goal 4 acceptance failed: invalid UTF-8 in $Path" }
}

function Get-PshGoal4Hash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PshGoal4Sha1Bytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-PshGoal4PackageVerificationCode {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    Assert-PshGoal4 ($Paths.Count -gt 0) 'Package verification code fixture has no files.'
    $fileHashes = @($Paths | ForEach-Object { Get-PshGoal4Sha1Bytes -Bytes ([IO.File]::ReadAllBytes($_)) })
    [Array]::Sort($fileHashes, [StringComparer]::Ordinal)
    return Get-PshGoal4Sha1Bytes -Bytes ([Text.Encoding]::ASCII.GetBytes(($fileHashes -join '')))
}

function Assert-PshGoal4PinnedUrl {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Description)
    Assert-PshGoal4 ($Url -match '\Ahttps://') "$Description is not HTTPS: $Url"
    Assert-PshGoal4 ($Url -notmatch '(?i)(?:^|[/=])latest(?:[/?.#]|$)') "$Description uses latest: $Url"
    Assert-PshGoal4 ($Url -notmatch '(?i)/(?:refs/heads/)?(?:main|master)(?:[/?.#]|$)') "$Description uses a branch: $Url"
}

function Resolve-PshGoal4RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshGoal4 (-not [IO.Path]::IsPathRooted($RelativePath)) "$Description is rooted: $RelativePath"
    Assert-PshGoal4 ($RelativePath -notmatch '\\') "$Description must use forward slashes: $RelativePath"
    $normalized = $RelativePath.Replace('\', '/')
    $segments = @($normalized.Split('/'))
    Assert-PshGoal4 ($segments.Count -gt 0 -and @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') }).Count -eq 0) "$Description escapes its root: $RelativePath"
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath((Join-Path -Path $fullRoot -ChildPath $normalized.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    Assert-PshGoal4 $fullPath.StartsWith($prefix, $comparison) "$Description escapes its root: $RelativePath"
    return $fullPath
}

function Assert-PshGoal4Sha {
    param([Parameter(Mandatory = $true)][string]$Hash, [Parameter(Mandatory = $true)][string]$Description)
    Assert-PshGoal4 ($Hash -match '\A[0-9a-fA-F]{64}\z' -and $Hash -notmatch '\A0{64}\z') "$Description is not a non-zero SHA256: $Hash"
}

function Get-PshGoal4Artifact {
    param([Parameter(Mandatory = $true)][object]$Tool, [Parameter(Mandatory = $true)][string]$Name)
    $artifacts = Get-PshGoal4Property -InputObject $Tool -Name 'artifacts'
    return Get-PshGoal4Property -InputObject $artifacts -Name $Name
}

function Test-PshGoal4PeMachine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedMachine
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { return $false }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length) { return $false }
    if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) { return $false }
    $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    $actual = ('0x{0:X4}' -f $machine)
    return [string]::Equals($actual, $ExpectedMachine, [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-PshGoal4Generator {
    param(
        [Parameter(Mandatory = $true)][string]$GeneratorPath,
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$Check
    )

    try {
        $output = @(& $GeneratorPath -RepositoryRoot $Root -Check:$Check 2>&1)
    }
    catch {
        throw ('Goal 4 acceptance failed: Supply-chain generator failed: {0}' -f $_.Exception.Message)
    }
    Assert-PshGoal4 ($output.Count -gt 0) 'Supply-chain generator returned no status output.'
}

function Invoke-PshGoal4ExpectedFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Mutation,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$GeneratorPath,
        [Parameter(Mandatory = $true)][string]$LockText
    )

    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal4-fixture-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    try {
        $fixtureLock = $LockText | ConvertFrom-Json
        & $Mutation $fixtureLock
        $fixtureLockPath = Join-Path $fixtureRoot 'native-tools.lock.json'
        $fixtureNoticesPath = Join-Path $fixtureRoot 'THIRD_PARTY_NOTICES.md'
        $fixtureSbomPath = Join-Path $fixtureRoot 'sbom.spdx.json'
        $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
        [IO.File]::WriteAllText($fixtureLockPath, (($fixtureLock | ConvertTo-Json -Depth 30) + "`n"), $utf8)
        $failed = $false
        try {
            & $GeneratorPath -RepositoryRoot $Root -LockPath $fixtureLockPath -NoticesPath $fixtureNoticesPath -SbomPath $fixtureSbomPath | Out-Null
        }
        catch { $failed = $true }
        Assert-PshGoal4 $failed "$Label mutation was accepted."
    }
    finally {
        if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-PshGoal4NamespaceFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$GeneratorPath,
        [Parameter(Mandatory = $true)][string]$NativeLockText,
        [Parameter(Mandatory = $true)][string]$InteractiveLockText
    )

    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal4-namespace-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    try {
        $fixtureLockPath = Join-Path $fixtureRoot 'native-tools.lock.json'
        $fixtureInteractivePath = Join-Path $fixtureRoot 'interactive.lock.json'
        $fixtureNoticesPath = Join-Path $fixtureRoot 'THIRD_PARTY_NOTICES.md'
        $fixtureSbomPath = Join-Path $fixtureRoot 'sbom.spdx.json'
        $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
        [IO.File]::WriteAllText($fixtureLockPath, $NativeLockText, $utf8)
        [IO.File]::WriteAllText($fixtureInteractivePath, $InteractiveLockText, $utf8)
        & $GeneratorPath -RepositoryRoot $Root -LockPath $fixtureLockPath -InteractiveLockPath $fixtureInteractivePath -NoticesPath $fixtureNoticesPath -SbomPath $fixtureSbomPath | Out-Null
        $fixtureSbom = (Get-PshGoal4StrictText -Path $fixtureSbomPath) | ConvertFrom-Json
        return [string]$fixtureSbom.documentNamespace
    }
    finally {
        if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-PshGoal4PackageContents {
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [Parameter(Mandatory = $true)][string[]]$ExpectedFileNames,
        [Parameter(Mandatory = $true)][object]$Sbom,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $packageName = [string]$Package.name
    Assert-PshGoal4 ([bool]$Package.filesAnalyzed) "$packageName package does not set filesAnalyzed=true."
    Assert-PshGoal4 (@($Package.licenseInfoFromFiles).Count -eq 1 -and [string]$Package.licenseInfoFromFiles[0] -ceq 'NOASSERTION') "$packageName package does not explicitly record unscanned file licenses."
    $verificationCode = [string]$Package.packageVerificationCode.packageVerificationCodeValue
    Assert-PshGoal4 ($verificationCode -match '\A[0-9a-f]{40}\z') "$packageName package verification code is malformed."
    Assert-PshGoal4 (@($Package.hasFiles).Count -eq $ExpectedFileNames.Count) "$packageName package hasFiles count is wrong."

    $expectedIds = New-Object 'System.Collections.Generic.List[string]'
    $verificationPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($fileName in $ExpectedFileNames) {
        $fileMatches = @($Sbom.files | Where-Object { [string]$_.fileName -ceq $fileName })
        Assert-PshGoal4 ($fileMatches.Count -eq 1) "$packageName package file is missing or duplicated in the SBOM: $fileName"
        $file = $fileMatches[0]
        $fileId = [string]$file.SPDXID
        [void]$expectedIds.Add($fileId)
        Assert-PshGoal4 (@($Package.hasFiles) -contains $fileId) "$packageName package does not list $fileName in hasFiles."
        $contains = @($Sbom.relationships | Where-Object {
            [string]$_.spdxElementId -ceq [string]$Package.SPDXID -and
            [string]$_.relationshipType -ceq 'CONTAINS' -and
            [string]$_.relatedSpdxElement -ceq $fileId
        })
        Assert-PshGoal4 ($contains.Count -eq 1) "$packageName package does not have exactly one CONTAINS relationship for $fileName."
        $verificationPath = Resolve-PshGoal4RelativePath -Root $Root -RelativePath $fileName -Description "$packageName verification file"
        $sha256Checksums = @($file.checksums | Where-Object { [string]$_.algorithm -ceq 'SHA256' })
        Assert-PshGoal4 ($sha256Checksums.Count -eq 1) "$packageName package file does not have exactly one SHA256 checksum: $fileName"
        Assert-PshGoal4 ([string]$sha256Checksums[0].checksumValue -ceq (Get-PshGoal4Hash -Path $verificationPath)) "$packageName package file SHA256 does not match retained content: $fileName"
        Assert-PshGoal4 (@($file.licenseInfoInFiles).Count -eq 1 -and [string]$file.licenseInfoInFiles[0] -ceq 'NOASSERTION') "$packageName package file does not explicitly record an unscanned license: $fileName"
        [void]$verificationPaths.Add($verificationPath)
    }

    $actualIds = @($Package.hasFiles | Sort-Object)
    $sortedExpectedIds = @($expectedIds.ToArray() | Sort-Object)
    Assert-PshGoal4 (($actualIds -join '|') -ceq ($sortedExpectedIds -join '|')) "$packageName package contains unexpected file identifiers."
    $expectedVerificationCode = Get-PshGoal4PackageVerificationCode -Paths $verificationPaths.ToArray()
    Assert-PshGoal4 ($verificationCode -ceq $expectedVerificationCode) "$packageName package verification code does not match its retained files."
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$lockPath = Join-Path $repositoryRootPath 'tools/native-tools.lock.json'
$generatorPath = Join-Path $repositoryRootPath 'scripts/Generate-SupplyChainArtifacts.ps1'
$interactiveLockPath = Join-Path $repositoryRootPath 'src/Psh/Dependencies/interactive.lock.json'
$workflowPath = Join-Path $repositoryRootPath '.github/workflows/goal4.yml'
$workflowText = Get-PshGoal4StrictText -Path $workflowPath
Assert-PshGoal4 ([regex]::Matches($workflowText, [regex]::Escape('-Architecture all')).Count -eq 2) 'Goal 4 workflow does not verify all native architectures in both Windows jobs.'
Assert-PshGoal4 ([regex]::Matches($workflowText, [regex]::Escape('Get-Command -Name ([string]$entry.name) -CommandType Function')).Count -eq 2) 'Goal 4 workflow does not invoke the public Psh wrapper in both Full jobs.'
Assert-PshGoal4 ([regex]::Matches($workflowText, [regex]::Escape('$wrapperExitCode = [int]$LASTEXITCODE')).Count -eq 2) 'Goal 4 workflow does not capture wrapper exit status in both Full jobs.'
Assert-PshGoal4 ([regex]::Matches($workflowText, [regex]::Escape('$wrapperFirstLine -notmatch [string]$entry.versionProbe.pattern')).Count -eq 2) 'Goal 4 workflow does not verify wrapper first-line version output in both Full jobs.'
Assert-PshGoal4 ([regex]::Matches($workflowText, [regex]::Escape('wrapperProbeOutput = $wrapperOutput')).Count -eq 2) 'Goal 4 workflow does not retain wrapper output in both reports.'
$lockText = Get-PshGoal4StrictText -Path $lockPath
$lock = $lockText | ConvertFrom-Json
Assert-PshGoal4 ([int](Get-PshGoal4Property $lock 'schemaVersion') -eq 1) 'Lock schemaVersion is not 1.'
Assert-PshGoal4 ([string](Get-PshGoal4Property $lock 'toolRoot') -ceq 'tools') 'Lock toolRoot is not tools.'
$manifest = Get-PshGoal4Property $lock 'manifest'
Assert-PshGoal4 ($null -ne $manifest) 'Lock manifest is missing.'
Assert-PshGoal4 ((ConvertTo-PshGoal4UtcTimestamp (Get-PshGoal4Property $manifest 'created')) -match '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z') 'Lock manifest.created is not fixed UTC.'
Assert-PshGoal4 (-not [string]::IsNullOrWhiteSpace([string](Get-PshGoal4Property $manifest 'namespaceSeed'))) 'Lock namespaceSeed is empty.'

$tools = Get-PshGoal4Array -InputObject $lock -Name 'tools'
Assert-PshGoal4 ($tools.Count -eq 4) 'Lock does not contain four tools.'
for ($index = 0; $index -lt $script:ExpectedTools.Count; $index++) {
    Assert-PshGoal4 ([string](Get-PshGoal4Property $tools[$index] 'name') -ceq $script:ExpectedTools[$index]) 'Tools are not sorted bat,fd,jq,rg.'
}

foreach ($tool in $tools) {
    $name = [string](Get-PshGoal4Property $tool 'name')
    $source = Get-PshGoal4Property $tool 'source'
    Assert-PshGoal4 ([string](Get-PshGoal4Property $source 'commit') -match '\A[0-9a-fA-F]{40}\z') "$name source commit is not full length."
    Assert-PshGoal4PinnedUrl -Url ([string](Get-PshGoal4Property $source 'repository')) -Description "$name repository"
    Assert-PshGoal4 (-not [string]::IsNullOrWhiteSpace([string](Get-PshGoal4Property $source 'tag'))) "$name source tag is empty."
    $license = Get-PshGoal4Property $tool 'license'
    Assert-PshGoal4 (-not [string]::IsNullOrWhiteSpace([string](Get-PshGoal4Property $license 'declaredSpdx'))) "$name SPDX is empty."
    foreach ($licenseFile in (Get-PshGoal4Array -InputObject $license -Name 'files')) {
        $licensePath = [string](Get-PshGoal4Property $licenseFile 'path')
        $resolvedLicense = Resolve-PshGoal4RelativePath -Root $repositoryRootPath -RelativePath $licensePath -Description "$name license path"
        Assert-PshGoal4 (Test-Path -LiteralPath $resolvedLicense -PathType Leaf) "$name license file is missing: $licensePath"
        $expectedHash = [string](Get-PshGoal4Property $licenseFile 'sha256')
        Assert-PshGoal4Sha -Hash $expectedHash -Description "$name license hash"
        Assert-PshGoal4 ((Get-PshGoal4Hash -Path $resolvedLicense) -ceq $expectedHash.ToLowerInvariant()) "$name license hash mismatch: $licensePath"
        Assert-PshGoal4PinnedUrl -Url ([string](Get-PshGoal4Property $licenseFile 'sourceUrl')) -Description "$name license source URL"
    }
    $artifactObject = Get-PshGoal4Property $tool 'artifacts'
    $artifactNames = @($artifactObject.PSObject.Properties | ForEach-Object { [string]$_.Name })
    Assert-PshGoal4 (($artifactNames -join '|') -ceq ($script:ExpectedArtifacts -join '|')) "$name artifact order is wrong."
    foreach ($artifactName in $script:ExpectedArtifacts) {
        $artifact = Get-PshGoal4Artifact -Tool $tool -Name $artifactName
        Assert-PshGoal4 ($null -ne $artifact) "$name $artifactName artifact is missing."
        $expectedArchitecture = if ($artifactName -ceq 'win-x64') { 'x86_64' } else { 'aarch64' }
        Assert-PshGoal4 ([string](Get-PshGoal4Property $artifact 'architecture') -ceq $expectedArchitecture) "$name $artifactName architecture mismatch."
        Assert-PshGoal4 ([string](Get-PshGoal4Property $artifact 'archiveType') -in @('zip', 'exe')) "$name $artifactName archive type is invalid."
        Assert-PshGoal4PinnedUrl -Url ([string](Get-PshGoal4Property $artifact 'apiUrl')) -Description "$name $artifactName API URL"
        Assert-PshGoal4PinnedUrl -Url ([string](Get-PshGoal4Property $artifact 'browserUrl')) -Description "$name $artifactName browser URL"
        Assert-PshGoal4Sha -Hash ([string](Get-PshGoal4Property $artifact 'archiveSha256')) -Description "$name $artifactName archive hash"
        Assert-PshGoal4Sha -Hash ([string](Get-PshGoal4Property $artifact 'installedSha256')) -Description "$name $artifactName installed hash"
        $installedPath = Resolve-PshGoal4RelativePath -Root (Join-Path $repositoryRootPath 'tools') -RelativePath ([string](Get-PshGoal4Property $artifact 'installedPath')) -Description "$name $artifactName installed path"
        Assert-PshGoal4 (Test-Path -LiteralPath $installedPath -PathType Leaf) "$name $artifactName installed executable is missing."
        Assert-PshGoal4 ((Get-PshGoal4Hash -Path $installedPath) -ceq ([string](Get-PshGoal4Property $artifact 'installedSha256')).ToLowerInvariant()) "$name $artifactName installed hash mismatch."
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            Assert-PshGoal4 (Test-PshGoal4PeMachine -Path $installedPath -ExpectedMachine ([string](Get-PshGoal4Property $artifact 'peMachine'))) "$name $artifactName PE machine mismatch."
        }
    }
}

$interactiveText = Get-PshGoal4StrictText -Path $interactiveLockPath
$interactiveLock = $interactiveText | ConvertFrom-Json
$psReadLine = @((Get-PshGoal4Array -InputObject $interactiveLock -Name 'components') | Where-Object { [string](Get-PshGoal4Property $_ 'name') -ceq 'PSReadLine' })[0]
Assert-PshGoal4 ($null -ne $psReadLine) 'PSReadLine is missing from interactive lock.'
$psLicense = Get-PshGoal4Property $psReadLine 'license'
$psLicensePath = Resolve-PshGoal4RelativePath -Root $repositoryRootPath -RelativePath ([string](Get-PshGoal4Property $psLicense 'vendoredPath')) -Description 'PSReadLine license path'
Assert-PshGoal4 (Test-Path -LiteralPath $psLicensePath -PathType Leaf) 'PSReadLine vendored license is missing.'
Assert-PshGoal4Sha -Hash ([string](Get-PshGoal4Property $psLicense 'sha256')) -Description 'PSReadLine license hash'
Assert-PshGoal4 ((Get-PshGoal4Hash -Path $psLicensePath) -ceq ([string](Get-PshGoal4Property $psLicense 'sha256')).ToLowerInvariant()) 'PSReadLine license hash mismatch.'
$dependencyRoot = [string](Get-PshGoal4Property $interactiveLock 'dependencyRoot')
$psVendoredFiles = Get-PshGoal4Array -InputObject $psReadLine -Name 'vendoredFiles'
Assert-PshGoal4 ($psVendoredFiles.Count -eq 7) 'PSReadLine vendored runtime file count is not seven.'
$psExpectedFileNames = New-Object 'System.Collections.Generic.List[string]'
[void]$psExpectedFileNames.Add([string](Get-PshGoal4Property $psLicense 'vendoredPath'))
foreach ($vendoredFile in $psVendoredFiles) {
    $vendoredPath = [string](Get-PshGoal4Property $vendoredFile 'path')
    $repositoryPath = '{0}/{1}' -f $dependencyRoot, $vendoredPath
    $resolvedPath = Resolve-PshGoal4RelativePath -Root $repositoryRootPath -RelativePath $repositoryPath -Description 'PSReadLine vendored runtime path'
    Assert-PshGoal4 (Test-Path -LiteralPath $resolvedPath -PathType Leaf) "PSReadLine vendored runtime file is missing: $repositoryPath"
    Assert-PshGoal4 ((Get-PshGoal4Hash -Path $resolvedPath) -ceq ([string](Get-PshGoal4Property $vendoredFile 'sha256')).ToLowerInvariant()) "PSReadLine vendored runtime hash mismatch: $repositoryPath"
    Assert-PshGoal4 ([int64](Get-PshGoal4Property $vendoredFile 'size') -eq [int64]([IO.FileInfo]$resolvedPath).Length) "PSReadLine vendored runtime size mismatch: $repositoryPath"
    [void]$psExpectedFileNames.Add($repositoryPath)
}
Assert-PshGoal4 (@($psExpectedFileNames.ToArray() | Select-Object -Unique).Count -eq 8) 'PSReadLine retained file list contains duplicates.'

Invoke-PshGoal4Generator -GeneratorPath $generatorPath -Root $repositoryRootPath -Check

$noticesPath = Join-Path $repositoryRootPath 'THIRD_PARTY_NOTICES.md'
$sbomPath = Join-Path $repositoryRootPath 'sbom.spdx.json'
$noticesText = Get-PshGoal4StrictText -Path $noticesPath
Assert-PshGoal4 ($noticesText.Contains('Fixed numeric asset identity URL / metadata locator')) 'Third-party notices use an inaccurate immutable asset URL claim.'
Assert-PshGoal4 (-not $noticesText.Contains('Immutable asset identity URL')) 'Third-party notices still call the numeric API URL immutable.'
$sbomText = Get-PshGoal4StrictText -Path $sbomPath
try { $sbom = $sbomText | ConvertFrom-Json -ErrorAction Stop }
catch { throw 'Goal 4 acceptance failed: sbom.spdx.json is not valid JSON.' }
Assert-PshGoal4 ([string]$sbom.spdxVersion -ceq 'SPDX-2.3') 'SBOM has the wrong SPDX version.'
Assert-PshGoal4 (@($sbom.creationInfo.creators).Count -eq 1 -and [string]$sbom.creationInfo.creators[0] -ceq 'Tool: psh-supply-chain-generator/2') 'SBOM has the wrong generator identity.'
$psPackage = @($sbom.packages | Where-Object { [string]$_.name -ceq 'PSReadLine' })[0]
Assert-PshGoal4 ($null -ne $psPackage) 'SBOM is missing the PSReadLine package.'
$psSbomFile = @($sbom.files | Where-Object { [string]$_.fileName -ceq [string]$psLicense.vendoredPath })[0]
Assert-PshGoal4 ($null -ne $psSbomFile) 'SBOM is missing the PSReadLine vendored license file.'
Assert-PshGoal4 ([string]$psSbomFile.checksums[0].checksumValue -ceq ([string]$psLicense.sha256).ToLowerInvariant()) 'SBOM uses the wrong PSReadLine license checksum.'
Assert-PshGoal4PackageContents -Package $psPackage -ExpectedFileNames $psExpectedFileNames.ToArray() -Sbom $sbom -Root $repositoryRootPath
foreach ($tool in $tools) {
    $name = [string](Get-PshGoal4Property $tool 'name')
    $package = @($sbom.packages | Where-Object { [string]$_.name -ceq $name })[0]
    Assert-PshGoal4 ($null -ne $package) "$name is missing from the SBOM."
    $expectedFileNames = New-Object 'System.Collections.Generic.List[string]'
    $license = Get-PshGoal4Property $tool 'license'
    foreach ($licenseFile in (Get-PshGoal4Array -InputObject $license -Name 'files')) {
        [void]$expectedFileNames.Add([string](Get-PshGoal4Property $licenseFile 'path'))
    }
    foreach ($artifactName in $script:ExpectedArtifacts) {
        $artifact = Get-PshGoal4Artifact -Tool $tool -Name $artifactName
        $expectedFileName = 'tools/{0}' -f [string](Get-PshGoal4Property $artifact 'installedPath')
        [void]$expectedFileNames.Add($expectedFileName)
        $sbomFile = @($sbom.files | Where-Object { [string]$_.fileName -ceq $expectedFileName })[0]
        Assert-PshGoal4 ($null -ne $sbomFile) "$name $artifactName installed file is missing from the SBOM."
        Assert-PshGoal4 ([string]$sbomFile.checksums[0].checksumValue -ceq ([string](Get-PshGoal4Property $artifact 'installedSha256')).ToLowerInvariant()) "$name $artifactName SBOM checksum does not match installedSha256."
        Assert-PshGoal4 (@($package.hasFiles) -contains [string]$sbomFile.SPDXID) "$name $artifactName package does not contain its installed file entry."
    }
    Assert-PshGoal4PackageContents -Package $package -ExpectedFileNames $expectedFileNames.ToArray() -Sbom $sbom -Root $repositoryRootPath
}
$jqTool = @($tools | Where-Object { [string](Get-PshGoal4Property $_ 'name') -ceq 'jq' })[0]
Assert-PshGoal4 ($null -ne $jqTool) 'jq is missing from the lock.'
$jqLicense = Get-PshGoal4Property $jqTool 'license'
$jqCopying = @((Get-PshGoal4Array -InputObject $jqLicense -Name 'files') | Where-Object { [IO.Path]::GetFileName([string](Get-PshGoal4Property $_ 'path')) -ceq 'COPYING' })[0]
Assert-PshGoal4 ($null -ne $jqCopying) 'jq COPYING is missing from the lock.'
$jqCopyingPath = Resolve-PshGoal4RelativePath -Root $repositoryRootPath -RelativePath ([string](Get-PshGoal4Property $jqCopying 'path')) -Description 'jq COPYING path'
$jqCopyingText = Get-PshGoal4StrictText -Path $jqCopyingPath
$jqExtracted = @($sbom.hasExtractedLicensingInfos | Where-Object { [string]$_.licenseId -ceq 'LicenseRef-jq-embedded-notices' })[0]
Assert-PshGoal4 ($null -ne $jqExtracted) 'SBOM is missing the jq embedded-notices license reference.'
Assert-PshGoal4 ([string]$jqExtracted.extractedText -ceq $jqCopyingText) 'SBOM jq extractedText is not the complete retained COPYING file.'
$jqSource = Get-PshGoal4Property $jqTool 'source'
$jqCopyingUrl = 'https://github.com/jqlang/jq/blob/{0}/COPYING' -f [string](Get-PshGoal4Property $jqSource 'commit')
Assert-PshGoal4 (@($jqExtracted.crossRefs).Count -eq 1 -and [string]$jqExtracted.crossRefs[0].url -ceq $jqCopyingUrl) 'SBOM jq LicenseRef cross-reference is missing or malformed.'

$baselineNamespace = Invoke-PshGoal4NamespaceFixture -Root $repositoryRootPath -GeneratorPath $generatorPath -NativeLockText $lockText -InteractiveLockText $interactiveText
Assert-PshGoal4 ($baselineNamespace -ceq [string]$sbom.documentNamespace) 'Namespace fixture does not reproduce the checked-in SBOM namespace.'
$nativeMutationNamespace = Invoke-PshGoal4NamespaceFixture -Root $repositoryRootPath -GeneratorPath $generatorPath -NativeLockText $lockText.Insert(1, ' ') -InteractiveLockText $interactiveText
Assert-PshGoal4 ($nativeMutationNamespace -cne $baselineNamespace) 'Native lock mutation did not change the document namespace.'
$interactiveMutationNamespace = Invoke-PshGoal4NamespaceFixture -Root $repositoryRootPath -GeneratorPath $generatorPath -NativeLockText $lockText -InteractiveLockText $interactiveText.Insert(1, ' ')
Assert-PshGoal4 ($interactiveMutationNamespace -cne $baselineNamespace) 'Interactive lock mutation did not change the document namespace.'

# Negative lock fixtures exercise independent schema/path gates without network or native execution.
Invoke-PshGoal4ExpectedFailure -Label 'missing tool' -Root $repositoryRootPath -GeneratorPath $generatorPath -LockText $lockText -Mutation {
    param($fixture)
    $fixture.tools = @($fixture.tools | Where-Object { [string](Get-PshGoal4Property $_ 'name') -cne 'rg' })
}
Invoke-PshGoal4ExpectedFailure -Label 'tampered archive hash' -Root $repositoryRootPath -GeneratorPath $generatorPath -LockText $lockText -Mutation {
    param($fixture)
    $artifact = Get-PshGoal4Property (Get-PshGoal4Property $fixture.tools[0] 'artifacts') 'win-x64'
    $artifact.archiveSha256 = ('0' * 64)
}
Invoke-PshGoal4ExpectedFailure -Label 'license path escape' -Root $repositoryRootPath -GeneratorPath $generatorPath -LockText $lockText -Mutation {
    param($fixture)
    $license = Get-PshGoal4Property $fixture.tools[0] 'license'
    $license.files[0].path = '../outside-license.txt'
}
Invoke-PshGoal4ExpectedFailure -Label 'wrong architecture' -Root $repositoryRootPath -GeneratorPath $generatorPath -LockText $lockText -Mutation {
    param($fixture)
    $artifact = Get-PshGoal4Property (Get-PshGoal4Property $fixture.tools[0] 'artifacts') 'win-x64'
    $artifact.architecture = 'aarch64'
}

# Core deletion is checked structurally on every platform and imported on Windows.
$coreFixture = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal4-core-' + [Guid]::NewGuid().ToString('N'))
try {
    $coreModule = Join-Path $coreFixture 'Psh'
    [void][IO.Directory]::CreateDirectory($coreFixture)
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'src/Psh') -Destination $coreModule -Recurse -Force
    $coreTools = Join-Path $coreModule 'Tools'
    if (Test-Path -LiteralPath $coreTools) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $coreTools -Recurse -Force }
    Assert-PshGoal4 (-not (Test-Path -LiteralPath $coreTools)) 'Core fixture still contains Tools after deletion.'
    Assert-PshGoal4 (-not (Test-Path -LiteralPath (Join-Path $coreModule 'Dependencies/native-tools.lock.json'))) 'Core fixture still contains native lock.'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $oldEdition = $env:PSH_EDITION
        try {
            $env:PSH_EDITION = 'Core'
            Import-Module -Name (Join-Path $coreModule 'Psh.psd1') -Force -ErrorAction Stop
            $capabilities = Get-PshCapabilities
            Assert-PshGoal4 (@($capabilities.commands).Count -eq 64) 'Core fixture did not expose all commands after tool deletion.'
        }
        finally {
            Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
            if ($null -eq $oldEdition) { Remove-Item Env:PSH_EDITION -ErrorAction SilentlyContinue } else { $env:PSH_EDITION = $oldEdition }
        }
    }
}
finally {
    if (Test-Path -LiteralPath $coreFixture) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $coreFixture -Recurse -Force -ErrorAction SilentlyContinue }
}

# Full version reporting is simulated off-Windows; Windows jobs execute each probe.
foreach ($tool in $tools) {
    $name = [string](Get-PshGoal4Property $tool 'name')
    $probe = Get-PshGoal4Property $tool 'versionProbe'
    Assert-PshGoal4 ((Get-PshGoal4Array -InputObject $probe -Name 'arguments').Count -gt 0) "$name has no version probe arguments."
    Assert-PshGoal4 (-not [string]::IsNullOrWhiteSpace([string](Get-PshGoal4Property $probe 'pattern'))) "$name has no version probe pattern."
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $artifact = Get-PshGoal4Artifact -Tool $tool -Name 'win-x64'
        $path = Resolve-PshGoal4RelativePath -Root (Join-Path $repositoryRootPath 'tools') -RelativePath ([string](Get-PshGoal4Property $artifact 'installedPath')) -Description "$name version probe path"
        $probeLines = @(& $path @((Get-PshGoal4Array -InputObject $probe -Name 'arguments')) 2>&1 | ForEach-Object { [string]$_ })
        $probeExitCode = [int]$LASTEXITCODE
        Assert-PshGoal4 ($probeExitCode -eq 0) "$name --version failed."
        Assert-PshGoal4 ($probeLines.Count -gt 0) "$name --version returned no output."
        $probeFirstLine = ([string]$probeLines[0]).Trim()
        Assert-PshGoal4 ($probeFirstLine -match [string](Get-PshGoal4Property $probe 'pattern')) "$name --version first line did not match the pinned pattern."
    }
}

Write-Output ('Goal 4 acceptance passed: {0} assertions.' -f $script:Assertions)
