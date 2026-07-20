# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LockPath,
    [string]$InteractiveLockPath,
    [string]$NoticesPath,
    [string]$SbomPath,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$script:ExpectedToolNames = @('bat', 'fd', 'jq', 'rg')
$script:ExpectedArtifactNames = @('win-x64', 'win-arm64')

function Throw-PshSupplyChainError {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw ('Supply-chain artifact generation failed: {0}' -f $Message)
}

function Get-PshProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-PshProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $false }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function ConvertTo-PshUtcTimestamp {
    param([AllowNull()][object]$Value)

    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Get-PshStrictUtf8Text {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.File]::Exists($Path)) {
        Throw-PshSupplyChainError ('Required file is missing: {0}' -f $Path)
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Throw-PshSupplyChainError ('File has a UTF-8 BOM: {0}' -f $Path)
    }

    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
    try {
        return $encoding.GetString($bytes)
    }
    catch {
        Throw-PshSupplyChainError ('File is not valid UTF-8: {0}' -f $Path)
    }
}

function ConvertTo-PshLf {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '' }
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function ConvertTo-PshCanonicalJsonEscapes {
    param([Parameter(Mandatory = $true)][string]$Json)

    # Windows PowerShell 5.1 escapes HTML-sensitive characters. Normalize
    # newer ConvertTo-Json output and non-ASCII text to one portable form.
    $escaped = $Json.Replace('&', '\u0026').Replace("'", '\u0027').Replace('<', '\u003c').Replace('>', '\u003e')
    $builder = New-Object Text.StringBuilder
    foreach ($character in $escaped.ToCharArray()) {
        if ([int]$character -gt 0x7F) {
            [void]$builder.Append(('\u{0:x4}' -f [int]$character))
        }
        else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Get-PshUtf8NoBom {
    return (New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true))
}

function Write-PshUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void][IO.Directory]::CreateDirectory($parent)
    }
    [IO.File]::WriteAllText($Path, (ConvertTo-PshLf $Text), (Get-PshUtf8NoBom))
}

function Get-PshSha256Bytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-PshSha256Text {
    param([Parameter(Mandatory = $true)][string]$Text)
    return Get-PshSha256Bytes -Bytes ((Get-PshUtf8NoBom).GetBytes((ConvertTo-PshLf $Text)))
}

function Get-PshSha256File {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Get-PshSha256Bytes -Bytes ([IO.File]::ReadAllBytes($Path))
}

function Get-PshSha1Bytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-PshSha1File {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Get-PshSha1Bytes -Bytes ([IO.File]::ReadAllBytes($Path))
}

function Get-PshPackageVerificationCode {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    Assert-PshCondition ($Paths.Count -gt 0) 'SPDX package verification code requires at least one file.'
    $sha1Values = @($Paths | ForEach-Object { Get-PshSha1File -Path $_ } | Sort-Object)
    return Get-PshSha1Bytes -Bytes ([Text.Encoding]::ASCII.GetBytes(($sha1Values -join '')))
}

function Assert-PshCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { Throw-PshSupplyChainError $Message }
}

function Assert-PshHttpsPinnedUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace($Url)) "$Description is empty."
    Assert-PshCondition ($Url -match '\Ahttps://') "$Description must use HTTPS: $Url"
    Assert-PshCondition ($Url -notmatch '(?i)(?:^|[/=])latest(?:[/?.#]|$)') "$Description uses a floating latest reference: $Url"
    Assert-PshCondition ($Url -notmatch '(?i)/(?:refs/heads/)?(?:main|master)(?:[/?.#]|$)') "$Description uses a floating branch reference: $Url"
}

function Assert-PshRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace($Path)) "$Description is empty."
    Assert-PshCondition (-not [IO.Path]::IsPathRooted($Path)) "$Description is rooted: $Path"
    Assert-PshCondition ($Path -notmatch '\\') "$Description must use forward slashes: $Path"
    $normalized = $Path.Replace('\', '/')
    $segments = @($normalized.Split('/'))
    Assert-PshCondition (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "$Description has an empty segment: $Path"
    Assert-PshCondition ($segments -notcontains '.') "$Description has a dot segment: $Path"
    Assert-PshCondition ($segments -notcontains '..') "$Description escapes its root: $Path"
    Assert-PshCondition ($normalized -ceq $Path.Replace('\', '/')) "$Description is not canonical: $Path"
}

function Resolve-PshRepositoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRootPath,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshRelativePath -Path $RelativePath -Description $Description
    $root = [IO.Path]::GetFullPath($RepositoryRootPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path -Path $root -ChildPath $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    Assert-PshCondition ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, $comparison)) "$Description escapes the repository root: $RelativePath"
    return $full
}

function Get-PshPeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-PshCondition ($bytes.Length -ge 64 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) "Installed artifact is not a PE image: $Path"
    $offset = [BitConverter]::ToInt32($bytes, 0x3C)
    Assert-PshCondition ($offset -ge 0 -and $offset + 6 -le $bytes.Length) "Installed artifact has an invalid PE offset: $Path"
    Assert-PshCondition ($bytes[$offset] -eq 0x50 -and $bytes[$offset + 1] -eq 0x45 -and $bytes[$offset + 2] -eq 0 -and $bytes[$offset + 3] -eq 0) "Installed artifact has an invalid PE signature: $Path"
    return ('0x{0:X4}' -f [BitConverter]::ToUInt16($bytes, $offset + 4))
}

function Assert-PshSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$AllowZero
    )

    Assert-PshCondition ($Hash -match '\A[0-9a-fA-F]{64}\z') "$Description is not a SHA-256 value: $Hash"
    if (-not $AllowZero) {
        Assert-PshCondition ($Hash -notmatch '\A0{64}\z') "$Description is an all-zero placeholder."
    }
}

function Get-PshArrayProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = Get-PshProperty -InputObject $InputObject -Name $Name
    if ($null -eq $value) { return @() }
    return @($value)
}

function Get-PshArtifact {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $artifacts = Get-PshProperty -InputObject $Tool -Name 'artifacts'
    Assert-PshCondition ($null -ne $artifacts) ("Tool {0} has no artifacts object." -f [string](Get-PshProperty $Tool 'name'))
    $artifact = Get-PshProperty -InputObject $artifacts -Name $Name
    Assert-PshCondition ($null -ne $artifact) ("Tool {0} is missing artifact {1}." -f [string](Get-PshProperty $Tool 'name'), $Name)
    return $artifact
}

function Assert-PshLock {
    param(
        [Parameter(Mandatory = $true)][object]$Lock,
        [Parameter(Mandatory = $true)][string]$RepositoryRootPath
    )

    Assert-PshCondition ([int](Get-PshProperty $Lock 'schemaVersion') -eq 1) 'Lock schemaVersion must be 1.'
    $toolRoot = [string](Get-PshProperty $Lock 'toolRoot')
    Assert-PshCondition ($toolRoot -ceq 'tools') "Lock toolRoot must be 'tools'."
    Assert-PshRelativePath -Path $toolRoot -Description 'Lock toolRoot'
    $toolsRootPath = Resolve-PshRepositoryPath -RepositoryRootPath $RepositoryRootPath -RelativePath $toolRoot -Description 'Lock toolRoot'

    $manifest = Get-PshProperty -InputObject $Lock -Name 'manifest'
    Assert-PshCondition ($null -ne $manifest) 'Lock manifest is missing.'
    $created = ConvertTo-PshUtcTimestamp (Get-PshProperty $manifest 'created')
    $namespaceSeed = [string](Get-PshProperty $manifest 'namespaceSeed')
    Assert-PshCondition ($created -match '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z') "Lock manifest.created is not a fixed UTC timestamp: $created"
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace($namespaceSeed)) 'Lock manifest.namespaceSeed is empty.'

    $tools = Get-PshArrayProperty -InputObject $Lock -Name 'tools'
    Assert-PshCondition ($tools.Count -eq $script:ExpectedToolNames.Count) 'Lock must contain exactly four tools.'
    for ($index = 0; $index -lt $script:ExpectedToolNames.Count; $index++) {
        $toolName = [string](Get-PshProperty $tools[$index] 'name')
        Assert-PshCondition ($toolName -ceq $script:ExpectedToolNames[$index]) ("Tools must be ordinal-sorted; index {0} is {1}." -f $index, $toolName)
    }

    foreach ($tool in $tools) {
        $name = [string](Get-PshProperty $tool 'name')
        Assert-PshCondition (-not [string]::IsNullOrWhiteSpace($name)) 'A tool name is empty.'
        Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string](Get-PshProperty $tool 'upstreamName'))) "$name upstreamName is empty."
        Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string](Get-PshProperty $tool 'version'))) "$name version is empty."

        $source = Get-PshProperty -InputObject $tool -Name 'source'
        Assert-PshCondition ($null -ne $source) "$name source is missing."
        Assert-PshHttpsPinnedUrl -Url ([string](Get-PshProperty $source 'repository')) -Description "$name source.repository"
        Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string](Get-PshProperty $source 'tag'))) "$name source.tag is empty."
        $commit = [string](Get-PshProperty $source 'commit')
        Assert-PshCondition ($commit -match '\A[0-9a-fA-F]{40}\z') "$name source.commit is not a full SHA-1: $commit"

        $license = Get-PshProperty -InputObject $tool -Name 'license'
        Assert-PshCondition ($null -ne $license) "$name license is missing."
        Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string](Get-PshProperty $license 'declaredSpdx'))) "$name license.declaredSpdx is empty."
        $licenseFiles = Get-PshArrayProperty -InputObject $license -Name 'files'
        Assert-PshCondition ($licenseFiles.Count -gt 0) "$name has no license files."
        foreach ($licenseFile in $licenseFiles) {
            $licensePath = [string](Get-PshProperty $licenseFile 'path')
            Assert-PshRelativePath -Path $licensePath -Description "$name license path"
            Assert-PshHttpsPinnedUrl -Url ([string](Get-PshProperty $licenseFile 'sourceUrl')) -Description "$name license sourceUrl"
            $licenseFilePath = Resolve-PshRepositoryPath -RepositoryRootPath $RepositoryRootPath -RelativePath $licensePath -Description "$name license path"
            Assert-PshCondition ([IO.File]::Exists($licenseFilePath)) "$name license file is missing: $licensePath"
            $licenseHash = [string](Get-PshProperty $licenseFile 'sha256')
            Assert-PshSha256 -Hash $licenseHash -Description "$name license SHA-256"
            Assert-PshCondition ((Get-PshSha256File -Path $licenseFilePath) -ceq $licenseHash.ToLowerInvariant()) "$name license SHA-256 does not match the retained file: $licensePath"
        }

        $probe = Get-PshProperty -InputObject $tool -Name 'versionProbe'
        Assert-PshCondition ($null -ne $probe) "$name versionProbe is missing."
        Assert-PshCondition ((Get-PshArrayProperty -InputObject $probe -Name 'arguments').Count -gt 0) "$name versionProbe.arguments is empty."
        Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string](Get-PshProperty $probe 'pattern'))) "$name versionProbe.pattern is empty."

        $artifacts = Get-PshProperty -InputObject $tool -Name 'artifacts'
        Assert-PshCondition ($null -ne $artifacts) "$name artifacts is missing."
        $artifactProperties = @($artifacts.PSObject.Properties | ForEach-Object { [string]$_.Name })
        Assert-PshCondition ($artifactProperties.Count -eq $script:ExpectedArtifactNames.Count) "$name artifacts has an unexpected number of architectures."
        for ($index = 0; $index -lt $script:ExpectedArtifactNames.Count; $index++) {
            Assert-PshCondition ($artifactProperties[$index] -ceq $script:ExpectedArtifactNames[$index]) "$name artifacts must be ordered win-x64 then win-arm64."
        }

        foreach ($artifactName in $script:ExpectedArtifactNames) {
            $artifact = Get-PshArtifact -Tool $tool -Name $artifactName
            $state = [string](Get-PshProperty $artifact 'state')
            Assert-PshCondition ($state -ceq 'pinned') "$name $artifactName state must be pinned."
            $expectedArchitecture = if ($artifactName -ceq 'win-x64') { 'x86_64' } else { 'aarch64' }
            Assert-PshCondition ([string](Get-PshProperty $artifact 'architecture') -ceq $expectedArchitecture) "$name $artifactName architecture is not $expectedArchitecture."
            $archiveType = [string](Get-PshProperty $artifact 'archiveType')
            Assert-PshCondition ($archiveType -in @('zip', 'exe')) "$name $artifactName archiveType must be zip or exe."
            $assetId = 0L
            Assert-PshCondition ([long]::TryParse([string](Get-PshProperty $artifact 'assetId'), [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$assetId) -and $assetId -gt 0) "$name $artifactName assetId is invalid."
            Assert-PshHttpsPinnedUrl -Url ([string](Get-PshProperty $artifact 'apiUrl')) -Description "$name $artifactName apiUrl"
            Assert-PshHttpsPinnedUrl -Url ([string](Get-PshProperty $artifact 'browserUrl')) -Description "$name $artifactName browserUrl"
            Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string](Get-PshProperty $artifact 'assetName'))) "$name $artifactName assetName is empty."
            Assert-PshSha256 -Hash ([string](Get-PshProperty $artifact 'archiveSha256')) -Description "$name $artifactName archive SHA-256"
            Assert-PshRelativePath -Path ([string](Get-PshProperty $artifact 'executableArchivePath')) -Description "$name $artifactName archive executable path"
            $installedRelativePath = [string](Get-PshProperty $artifact 'installedPath')
            Assert-PshRelativePath -Path $installedRelativePath -Description "$name $artifactName installed path"
            $installedPath = Resolve-PshRepositoryPath -RepositoryRootPath $toolsRootPath -RelativePath $installedRelativePath -Description "$name $artifactName installed path"
            Assert-PshCondition ([IO.File]::Exists($installedPath)) "$name $artifactName installed executable is missing: $installedRelativePath"
            $installedHash = [string](Get-PshProperty $artifact 'installedSha256')
            Assert-PshSha256 -Hash $installedHash -Description "$name $artifactName installed SHA-256"
            Assert-PshCondition ((Get-PshSha256File -Path $installedPath) -ceq $installedHash.ToLowerInvariant()) "$name $artifactName installed SHA-256 does not match the retained executable."
            $expectedMachine = if ($artifactName -ceq 'win-x64') { '0x8664' } else { '0xAA64' }
            $peMachine = [string](Get-PshProperty $artifact 'peMachine')
            Assert-PshCondition ($peMachine -ieq $expectedMachine) "$name $artifactName peMachine must be $expectedMachine."
            Assert-PshCondition ((Get-PshPeMachine -Path $installedPath) -ieq $peMachine) "$name $artifactName PE machine does not match the retained executable."
        }
    }

    return [PSCustomObject]@{
        Manifest = $manifest
        Tools = $tools
        ToolRoot = $toolRoot
    }
}

function Get-PshDocumentIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$NativeLockText,
        [Parameter(Mandatory = $true)][string]$InteractiveLockText
    )

    $nativeInput = (ConvertTo-PshLf $NativeLockText).TrimEnd([char]0x0A)
    $interactiveInput = (ConvertTo-PshLf $InteractiveLockText).TrimEnd([char]0x0A)
    $summaryText = @(
        'generator=psh-supply-chain-generator/2'
        'native-tools.lock.json'
        $nativeInput
        'interactive.lock.json'
        $interactiveInput
        ''
    ) -join "`n"
    $summaryHash = Get-PshSha256Text -Text $summaryText
    $seed = [string](Get-PshProperty $Manifest 'namespaceSeed')
    $safeSeed = [regex]::Replace($seed, '[^A-Za-z0-9._-]', '-')
    return [PSCustomObject]@{
        Summary = $summaryText
        SummarySha256 = $summaryHash
        Namespace = ('https://github.com/Emvdy/psh/spdx/{0}/{1}' -f $safeSeed, $summaryHash)
    }
}

function ConvertTo-PshMarkdownCell {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '-' }
    return $Value.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function New-PshNativeNoticeLines {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][AllowEmptyString()][System.Collections.Generic.List[string]]$Lines
    )

    $name = [string](Get-PshProperty $Tool 'name')
    $source = Get-PshProperty $Tool 'source'
    $license = Get-PshProperty $Tool 'license'
    $probe = Get-PshProperty $Tool 'versionProbe'
    [void]$Lines.Add(('### {0} {1}' -f $name, [string](Get-PshProperty $Tool 'version')))
    [void]$Lines.Add('')
    [void]$Lines.Add(('- Upstream name: `{0}`' -f (ConvertTo-PshMarkdownCell ([string](Get-PshProperty $Tool 'upstreamName')))))
    [void]$Lines.Add(('- Source repository: <{0}>' -f [string](Get-PshProperty $source 'repository')))
    [void]$Lines.Add(('- Source tag: `{0}`; resolved commit: `{1}`' -f [string](Get-PshProperty $source 'tag'), [string](Get-PshProperty $source 'commit')))
    if (Test-PshProperty -InputObject $source -Name 'tagObject') {
        [void]$Lines.Add(('- Annotated tag object: `{0}`' -f [string](Get-PshProperty $source 'tagObject')))
    }
    [void]$Lines.Add(('- Declared SPDX expression: `{0}`' -f (ConvertTo-PshMarkdownCell ([string](Get-PshProperty $license 'declaredSpdx')))))
    $licenseNotes = [string](Get-PshProperty $Tool 'licenseNotes')
    if (-not [string]::IsNullOrWhiteSpace($licenseNotes)) {
        [void]$Lines.Add(('- License notes: {0}' -f (ConvertTo-PshMarkdownCell $licenseNotes)))
    }
    [void]$Lines.Add('')
    [void]$Lines.Add('| License file (repo-relative) | Fixed source URL | SHA256 |')
    [void]$Lines.Add('| --- | --- | --- |')
    foreach ($licenseFile in (Get-PshArrayProperty -InputObject $license -Name 'files')) {
        [void]$Lines.Add(('| `{0}` | <{1}> | `{2}` |' -f (ConvertTo-PshMarkdownCell ([string](Get-PshProperty $licenseFile 'path'))), [string](Get-PshProperty $licenseFile 'sourceUrl'), [string](Get-PshProperty $licenseFile 'sha256')))
    }
    [void]$Lines.Add('')
    $probeArgs = @((Get-PshArrayProperty -InputObject $probe -Name 'arguments') | ForEach-Object { '`' + (ConvertTo-PshMarkdownCell ([string]$_)) + '`' }) -join ' '
    [void]$Lines.Add(('- Runtime version probe: {0}; expected pattern `{1}`' -f $probeArgs, (ConvertTo-PshMarkdownCell ([string](Get-PshProperty $probe 'pattern')))))
    [void]$Lines.Add('- GitHub release metadata observed `immutable=false`; version-pinned URLs and SHA256 values are recorded, but this is not a claim of immutable release storage or reproducible builds.')
    [void]$Lines.Add('')
    foreach ($artifactName in $script:ExpectedArtifactNames) {
        $artifact = Get-PshArtifact -Tool $Tool -Name $artifactName
        [void]$Lines.Add(('#### {0}' -f $artifactName))
        [void]$Lines.Add('')
        [void]$Lines.Add(('- State: `{0}`; architecture: `{1}`; target: `{2}`; PE machine: `{3}`' -f [string](Get-PshProperty $artifact 'state'), [string](Get-PshProperty $artifact 'architecture'), [string](Get-PshProperty $artifact 'targetTriple'), [string](Get-PshProperty $artifact 'peMachine')))
        [void]$Lines.Add(('- Asset: `{0}`; archive type: `{1}`; archive SHA256: `{2}`' -f [string](Get-PshProperty $artifact 'assetName'), [string](Get-PshProperty $artifact 'archiveType'), [string](Get-PshProperty $artifact 'archiveSha256')))
        [void]$Lines.Add(('- Fixed numeric asset identity URL / metadata locator (the upstream release object may be deleted): <{0}>' -f [string](Get-PshProperty $artifact 'apiUrl')))
        [void]$Lines.Add(('- Version-pinned download URL: <{0}>' -f [string](Get-PshProperty $artifact 'browserUrl')))
        [void]$Lines.Add(('- Executable in archive: `{0}`; installed path (relative to `tools`): `{1}`' -f [string](Get-PshProperty $artifact 'executableArchivePath'), [string](Get-PshProperty $artifact 'installedPath')))
        [void]$Lines.Add(('- Installed SHA256: `{0}`' -f [string](Get-PshProperty $artifact 'installedSha256')))
        [void]$Lines.Add('')
    }
}

function New-PshThirdPartyNotices {
    param(
        [Parameter(Mandatory = $true)][object]$Lock,
        [Parameter(Mandatory = $true)][object]$InteractiveLock,
        [Parameter(Mandatory = $true)][object]$Identity
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $manifest = Get-PshProperty $Lock 'manifest'
    [void]$lines.Add('# Third-party notices')
    [void]$lines.Add('')
    [void]$lines.Add('<!-- SPDX-License-Identifier: GPL-3.0-or-later -->')
    [void]$lines.Add('<!-- Generated by scripts/Generate-SupplyChainArtifacts.ps1. Do not edit. -->')
    [void]$lines.Add('')
    [void]$lines.Add('This file is generated from `tools/native-tools.lock.json` and the pinned PSReadLine lock.')
    [void]$lines.Add(('Lock manifest created: `{0}`.' -f (ConvertTo-PshUtcTimestamp (Get-PshProperty $manifest 'created'))))
    [void]$lines.Add(('Lock namespace seed: `{0}`; deterministic summary SHA256: `{1}`.' -f [string](Get-PshProperty $manifest 'namespaceSeed'), [string]$Identity.SummarySha256))
    [void]$lines.Add('Source repository, release tag, and resolved commit are provenance records. The GitHub release objects were observed with `immutable=false`; numeric asset IDs and SHA256 values pin the selected bytes as far as the upstream metadata permits. No reproducible-build claim is made.')
    [void]$lines.Add('')
    [void]$lines.Add('## PSReadLine')
    [void]$lines.Add('')
    $component = @((Get-PshArrayProperty -InputObject $InteractiveLock -Name 'components') | Where-Object { [string](Get-PshProperty $_ 'name') -ceq 'PSReadLine' })[0]
    Assert-PshCondition ($null -ne $component) 'PSReadLine is missing from interactive.lock.json.'
    $repository = Get-PshProperty $component 'repository'
    $package = Get-PshProperty $component 'package'
    $componentLicense = Get-PshProperty $component 'license'
    [void]$lines.Add(('- Version: `{0}`; source repository: <{1}>; tag: `{2}`; commit: `{3}`' -f [string](Get-PshProperty $component 'version'), [string](Get-PshProperty $repository 'url'), [string](Get-PshProperty $repository 'tag'), [string](Get-PshProperty $repository 'commit')))
    [void]$lines.Add(('- Declared SPDX: `{0}`; vendored license path: `{1}`; vendored SHA256: `{2}`; fixed source URL: <{3}>; fixed source SHA256: `{4}`' -f [string](Get-PshProperty $componentLicense 'spdxId'), [string](Get-PshProperty $componentLicense 'vendoredPath'), [string](Get-PshProperty $componentLicense 'sha256'), [string](Get-PshProperty $componentLicense 'fixedSourceUrl'), [string](Get-PshProperty $componentLicense 'fixedSourceSha256')))
    [void]$lines.Add(('- Package provenance: <{0}>; package SHA256: `{1}`.' -f [string](Get-PshProperty $package 'downloadUrl'), [string](Get-PshProperty $package 'sha256')))
    [void]$lines.Add('')
    [void]$lines.Add('## Native tools')
    [void]$lines.Add('')
    foreach ($tool in (Get-PshArrayProperty -InputObject $Lock -Name 'tools')) {
        New-PshNativeNoticeLines -Tool $tool -Lines $lines
    }
    return (ConvertTo-PshLf ((($lines -join "`n").TrimEnd([char]0x0A)) + "`n"))
}

function ConvertTo-PshSpdxId {
    param([Parameter(Mandatory = $true)][string]$Value)
    $safe = [regex]::Replace($Value, '[^A-Za-z0-9.-]', '-')
    return ('SPDXRef-{0}' -f $safe)
}

function New-PshSpdxFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string]$License,
        [Parameter(Mandatory = $true)][string]$Id
    )

    return [ordered]@{
        SPDXID = $Id
        fileName = $Path
        checksums = @([ordered]@{ algorithm = 'SHA256'; checksumValue = $Hash.ToLowerInvariant() })
        licenseConcluded = $License
        licenseInfoInFiles = @('NOASSERTION')
        copyrightText = 'NOASSERTION'
    }
}

function New-PshSpdxPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$License,
        [Parameter(Mandatory = $true)][string]$DownloadLocation,
        [Parameter(Mandatory = $true)][string]$SourceInfo,
        [Parameter(Mandatory = $true)][string]$Comment,
        [Parameter(Mandatory = $true)][string[]]$FileIds,
        [Parameter(Mandatory = $true)][string]$VerificationCode
    )

    $package = [ordered]@{
        SPDXID = (ConvertTo-PshSpdxId -Value ("{0}-{1}" -f $Name, $Version))
        name = $Name
        versionInfo = $Version
        downloadLocation = $DownloadLocation
        filesAnalyzed = $true
        packageVerificationCode = [ordered]@{ packageVerificationCodeValue = $VerificationCode }
        licenseInfoFromFiles = @('NOASSERTION')
        licenseConcluded = $License
        licenseDeclared = $License
        copyrightText = 'NOASSERTION'
        sourceInfo = $SourceInfo
        comment = $Comment
        hasFiles = @($FileIds)
    }
    return $package
}

function New-PshSpdxDocument {
    param(
        [Parameter(Mandatory = $true)][object]$Lock,
        [Parameter(Mandatory = $true)][object]$InteractiveLock,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][string]$RepositoryRootPath
    )

    $manifest = Get-PshProperty $Lock 'manifest'
    $packages = New-Object 'System.Collections.Generic.List[object]'
    $files = New-Object 'System.Collections.Generic.List[object]'
    $relationships = New-Object 'System.Collections.Generic.List[object]'
    $extracted = New-Object 'System.Collections.Generic.List[object]'

    $psComponent = @((Get-PshArrayProperty -InputObject $InteractiveLock -Name 'components') | Where-Object { [string](Get-PshProperty $_ 'name') -ceq 'PSReadLine' })[0]
    Assert-PshCondition ($null -ne $psComponent) 'PSReadLine is missing from interactive.lock.json.'
    $psLicense = Get-PshProperty $psComponent 'license'
    $psPackage = Get-PshProperty $psComponent 'package'
    $dependencyRoot = [string](Get-PshProperty $InteractiveLock 'dependencyRoot')
    Assert-PshRelativePath -Path $dependencyRoot -Description 'PSReadLine dependency root'
    $psFileIds = New-Object 'System.Collections.Generic.List[string]'
    $psVerificationPaths = New-Object 'System.Collections.Generic.List[string]'
    $psFileId = ConvertTo-PshSpdxId -Value ('PSReadLine-license-' + [string](Get-PshProperty $psComponent 'version'))
    $psLicenseRelativePath = [string](Get-PshProperty $psLicense 'vendoredPath')
    $psLicensePath = Resolve-PshRepositoryPath -RepositoryRootPath $RepositoryRootPath -RelativePath $psLicenseRelativePath -Description 'PSReadLine vendored license path'
    [void]$files.Add((New-PshSpdxFile -Path $psLicenseRelativePath -Hash ([string](Get-PshProperty $psLicense 'sha256')) -License ([string](Get-PshProperty $psLicense 'spdxId')) -Id $psFileId))
    [void]$psFileIds.Add($psFileId)
    [void]$psVerificationPaths.Add($psLicensePath)
    foreach ($vendoredFile in (Get-PshArrayProperty -InputObject $psComponent -Name 'vendoredFiles')) {
        $vendoredPath = [string](Get-PshProperty $vendoredFile 'path')
        Assert-PshRelativePath -Path $vendoredPath -Description 'PSReadLine vendored runtime path'
        $repositoryPath = '{0}/{1}' -f $dependencyRoot, $vendoredPath
        $fullPath = Resolve-PshRepositoryPath -RepositoryRootPath $RepositoryRootPath -RelativePath $repositoryPath -Description 'PSReadLine vendored runtime path'
        Assert-PshCondition ([IO.File]::Exists($fullPath)) "PSReadLine vendored runtime file is missing: $repositoryPath"
        $vendoredHash = [string](Get-PshProperty $vendoredFile 'sha256')
        Assert-PshSha256 -Hash $vendoredHash -Description "PSReadLine vendored runtime SHA-256: $repositoryPath"
        Assert-PshCondition ((Get-PshSha256File -Path $fullPath) -ceq $vendoredHash.ToLowerInvariant()) "PSReadLine vendored runtime SHA-256 does not match: $repositoryPath"
        Assert-PshCondition ([int64](Get-PshProperty $vendoredFile 'size') -eq [int64]([IO.FileInfo]$fullPath).Length) "PSReadLine vendored runtime size does not match: $repositoryPath"
        $vendoredFileId = ConvertTo-PshSpdxId -Value ('PSReadLine-runtime-' + $vendoredPath)
        [void]$files.Add((New-PshSpdxFile -Path $repositoryPath -Hash $vendoredHash -License ([string](Get-PshProperty $psLicense 'spdxId')) -Id $vendoredFileId))
        [void]$psFileIds.Add($vendoredFileId)
        [void]$psVerificationPaths.Add($fullPath)
    }
    $psVerificationCode = Get-PshPackageVerificationCode -Paths $psVerificationPaths.ToArray()
    $psSourceInfo = 'Source tag {0} resolves to commit {1}; this package describes the selected vendored runtime subset recorded in interactive.lock.json.' -f [string](Get-PshProperty (Get-PshProperty $psComponent 'repository') 'tag'), [string](Get-PshProperty (Get-PshProperty $psComponent 'repository') 'commit')
    $psComment = 'PowerShell Gallery package SHA256 {0}; retained files {1}; vendored license SHA256 {2}; fixed source license URL {3} has SHA256 {4}.' -f [string](Get-PshProperty $psPackage 'sha256'), $psFileIds.Count, [string](Get-PshProperty $psLicense 'sha256'), [string](Get-PshProperty $psLicense 'fixedSourceUrl'), [string](Get-PshProperty $psLicense 'fixedSourceSha256')
    [void]$packages.Add((New-PshSpdxPackage -Name 'PSReadLine' -Version ([string](Get-PshProperty $psComponent 'version')) -License ([string](Get-PshProperty $psLicense 'spdxId')) -DownloadLocation ([string](Get-PshProperty $psPackage 'downloadUrl')) -SourceInfo $psSourceInfo -Comment $psComment -FileIds $psFileIds.ToArray() -VerificationCode $psVerificationCode))

    foreach ($tool in (Get-PshArrayProperty -InputObject $Lock -Name 'tools')) {
        $name = [string](Get-PshProperty $tool 'name')
        $version = [string](Get-PshProperty $tool 'version')
        $source = Get-PshProperty $tool 'source'
        $license = Get-PshProperty $tool 'license'
        $packageId = ConvertTo-PshSpdxId -Value ("{0}-{1}" -f $name, $version)
        $fileIds = New-Object 'System.Collections.Generic.List[string]'
        $verificationPaths = New-Object 'System.Collections.Generic.List[string]'
        $artifactComments = New-Object 'System.Collections.Generic.List[string]'
        foreach ($licenseFile in (Get-PshArrayProperty -InputObject $license -Name 'files')) {
            $licensePath = [string](Get-PshProperty $licenseFile 'path')
            $licenseFullPath = Resolve-PshRepositoryPath -RepositoryRootPath $RepositoryRootPath -RelativePath $licensePath -Description "$name retained license path"
            $licenseFileId = ConvertTo-PshSpdxId -Value ('license-' + $licensePath)
            [void]$files.Add((New-PshSpdxFile -Path $licensePath -Hash ([string](Get-PshProperty $licenseFile 'sha256')) -License ([string](Get-PshProperty $license 'declaredSpdx')) -Id $licenseFileId))
            [void]$fileIds.Add($licenseFileId)
            [void]$verificationPaths.Add($licenseFullPath)
        }
        foreach ($artifactName in $script:ExpectedArtifactNames) {
            $artifact = Get-PshArtifact -Tool $tool -Name $artifactName
            $artifactFileId = ConvertTo-PshSpdxId -Value ('installed-' + $name + '-' + $artifactName)
            $installedPath = 'tools/{0}' -f [string](Get-PshProperty $artifact 'installedPath')
            $installedFullPath = Resolve-PshRepositoryPath -RepositoryRootPath $RepositoryRootPath -RelativePath $installedPath -Description "$name $artifactName distributed executable path"
            [void]$files.Add((New-PshSpdxFile -Path $installedPath -Hash ([string](Get-PshProperty $artifact 'installedSha256')) -License ([string](Get-PshProperty $license 'declaredSpdx')) -Id $artifactFileId))
            [void]$fileIds.Add($artifactFileId)
            [void]$verificationPaths.Add($installedFullPath)
            [void]$artifactComments.Add(('{0}: distributed file {1} SHA256 {2}, architecture {3}, target {4}, PE machine {5}; source archive {6} SHA256 {7}; fixed numeric asset metadata locator {8}; version-pinned download URL {9}. The upstream release object was observed immutable=false and may be deleted.' -f $artifactName, $installedPath, [string](Get-PshProperty $artifact 'installedSha256'), [string](Get-PshProperty $artifact 'architecture'), [string](Get-PshProperty $artifact 'targetTriple'), [string](Get-PshProperty $artifact 'peMachine'), [string](Get-PshProperty $artifact 'assetName'), [string](Get-PshProperty $artifact 'archiveSha256'), [string](Get-PshProperty $artifact 'apiUrl'), [string](Get-PshProperty $artifact 'browserUrl')))
        }
        $verificationCode = Get-PshPackageVerificationCode -Paths $verificationPaths.ToArray()
        $sourceInfo = 'Source tag {0} resolves to commit {1}; GitHub release immutable=false.' -f [string](Get-PshProperty $source 'tag'), [string](Get-PshProperty $source 'commit')
        $comment = 'Version probe: {0}; expected pattern {1}. {2}' -f ((Get-PshArrayProperty -InputObject (Get-PshProperty $tool 'versionProbe') -Name 'arguments') -join ' '), [string](Get-PshProperty (Get-PshProperty $tool 'versionProbe') 'pattern'), ($artifactComments -join ' ')
        [void]$packages.Add((New-PshSpdxPackage -Name $name -Version $version -License ([string](Get-PshProperty $license 'declaredSpdx')) -DownloadLocation ('{0}/tree/{1}' -f [string](Get-PshProperty $source 'repository'), [string](Get-PshProperty $source 'commit')) -SourceInfo $sourceInfo -Comment $comment -FileIds $fileIds.ToArray() -VerificationCode $verificationCode))
    }

    $documentId = 'SPDXRef-DOCUMENT'
    foreach ($package in $packages) {
        [void]$relationships.Add([ordered]@{ spdxElementId = $documentId; relationshipType = 'DESCRIBES'; relatedSpdxElement = [string]$package.SPDXID })
        foreach ($fileId in @($package.hasFiles)) {
            [void]$relationships.Add([ordered]@{ spdxElementId = [string]$package.SPDXID; relationshipType = 'CONTAINS'; relatedSpdxElement = [string]$fileId })
        }
    }

    $jqTool = @((Get-PshArrayProperty -InputObject $Lock -Name 'tools') | Where-Object { [string](Get-PshProperty $_ 'name') -ceq 'jq' })[0]
    $jqLicense = if ($null -eq $jqTool) { '' } else { [string](Get-PshProperty (Get-PshProperty $jqTool 'license') 'declaredSpdx') }
    if ($jqLicense -match 'LicenseRef-jq-embedded-notices') {
        $jqCopying = @((Get-PshArrayProperty -InputObject (Get-PshProperty $jqTool 'license') -Name 'files') | Where-Object { [IO.Path]::GetFileName([string](Get-PshProperty $_ 'path')) -ceq 'COPYING' })[0]
        Assert-PshCondition ($null -ne $jqCopying) 'jq LicenseRef requires a retained COPYING file.'
        $jqCopyingRelativePath = [string](Get-PshProperty $jqCopying 'path')
        $jqCopyingPath = Resolve-PshRepositoryPath -RepositoryRootPath $RepositoryRootPath -RelativePath $jqCopyingRelativePath -Description 'jq COPYING path'
        $jqCopyingText = Get-PshStrictUtf8Text -Path $jqCopyingPath
        Assert-PshCondition (-not [string]::IsNullOrWhiteSpace($jqCopyingText)) 'Retained jq COPYING is empty.'
        [void]$extracted.Add([ordered]@{
            licenseId = 'LicenseRef-jq-embedded-notices'
            name = 'jq embedded third-party notices'
            extractedText = $jqCopyingText
            crossRefs = @([ordered]@{ url = ('https://github.com/jqlang/jq/blob/{0}/COPYING' -f [string](Get-PshProperty (Get-PshProperty $jqTool 'source') 'commit')) })
        })
    }

    $root = [ordered]@{
        spdxVersion = 'SPDX-2.3'
        dataLicense = 'CC0-1.0'
        SPDXID = $documentId
        name = 'Psh Goal 4 Full Tools Supply Chain'
        documentNamespace = [string]$Identity.Namespace
        creationInfo = [ordered]@{
            created = (ConvertTo-PshUtcTimestamp (Get-PshProperty $manifest 'created'))
            creators = @('Tool: psh-supply-chain-generator/2')
            licenseListVersion = '3.26'
        }
        comment = ('Deterministic lock summary SHA256: {0}. No reproducible-build claim; GitHub release objects observed immutable=false.' -f [string]$Identity.SummarySha256)
        packages = $packages.ToArray()
        files = $files.ToArray()
        relationships = $relationships.ToArray()
    }
    if ($extracted.Count -gt 0) { $root['hasExtractedLicensingInfos'] = $extracted.ToArray() }
    return $root
}

function ConvertTo-PshJsonText {
    param([Parameter(Mandatory = $true)][object]$Object)
    $json = $Object | ConvertTo-Json -Depth 30 -Compress
    return (ConvertTo-PshCanonicalJsonEscapes ([string]$json)) + "`n"
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($LockPath)) { $LockPath = Join-Path $repositoryRootPath 'tools/native-tools.lock.json' }
if ([string]::IsNullOrWhiteSpace($InteractiveLockPath)) { $InteractiveLockPath = Join-Path $repositoryRootPath 'src/Psh/Dependencies/interactive.lock.json' }
if ([string]::IsNullOrWhiteSpace($NoticesPath)) { $NoticesPath = Join-Path $repositoryRootPath 'THIRD_PARTY_NOTICES.md' }
if ([string]::IsNullOrWhiteSpace($SbomPath)) { $SbomPath = Join-Path $repositoryRootPath 'sbom.spdx.json' }

$lockText = Get-PshStrictUtf8Text -Path ([IO.Path]::GetFullPath($LockPath))
try { $lock = $lockText | ConvertFrom-Json -ErrorAction Stop }
catch { Throw-PshSupplyChainError ('Lock JSON is invalid: {0}' -f $_.Exception.Message) }
$validated = Assert-PshLock -Lock $lock -RepositoryRootPath $repositoryRootPath

$interactiveText = Get-PshStrictUtf8Text -Path ([IO.Path]::GetFullPath($InteractiveLockPath))
try { $interactiveLock = $interactiveText | ConvertFrom-Json -ErrorAction Stop }
catch { Throw-PshSupplyChainError ('Interactive lock JSON is invalid: {0}' -f $_.Exception.Message) }
$psReadLineComponent = @((Get-PshArrayProperty -InputObject $interactiveLock -Name 'components') | Where-Object { [string](Get-PshProperty $_ 'name') -ceq 'PSReadLine' })[0]
Assert-PshCondition ($null -ne $psReadLineComponent) 'PSReadLine is missing from interactive.lock.json.'
$psReadLineLicense = Get-PshProperty $psReadLineComponent 'license'
$psReadLineLicensePath = Resolve-PshRepositoryPath -RepositoryRootPath $repositoryRootPath -RelativePath ([string](Get-PshProperty $psReadLineLicense 'vendoredPath')) -Description 'PSReadLine vendored license path'
Assert-PshCondition ([IO.File]::Exists($psReadLineLicensePath)) 'PSReadLine vendored license file is missing.'
$psReadLineLicenseHash = [string](Get-PshProperty $psReadLineLicense 'sha256')
Assert-PshSha256 -Hash $psReadLineLicenseHash -Description 'PSReadLine vendored license SHA-256'
Assert-PshCondition ((Get-PshSha256File -Path $psReadLineLicensePath) -ceq $psReadLineLicenseHash.ToLowerInvariant()) 'PSReadLine vendored license SHA-256 does not match the retained file.'
Assert-PshSha256 -Hash ([string](Get-PshProperty $psReadLineLicense 'fixedSourceSha256')) -Description 'PSReadLine fixed source license SHA-256'
$identity = Get-PshDocumentIdentity -Manifest $validated.Manifest -NativeLockText $lockText -InteractiveLockText $interactiveText
$notices = New-PshThirdPartyNotices -Lock $lock -InteractiveLock $interactiveLock -Identity $identity
$sbom = ConvertTo-PshJsonText -Object (New-PshSpdxDocument -Lock $lock -InteractiveLock $interactiveLock -Identity $identity -RepositoryRootPath $repositoryRootPath)

if ($Check) {
    foreach ($pair in @(
        [PSCustomObject]@{ Path = [IO.Path]::GetFullPath($NoticesPath); Text = $notices }
        [PSCustomObject]@{ Path = [IO.Path]::GetFullPath($SbomPath); Text = $sbom }
    )) {
        Assert-PshCondition ([IO.File]::Exists($pair.Path)) "Generated output is missing: $($pair.Path)"
        $existing = Get-PshStrictUtf8Text -Path $pair.Path
        Assert-PshCondition ((Get-PshSha256Text -Text $existing) -ceq (Get-PshSha256Text -Text ([string]$pair.Text))) "Generated output differs: $($pair.Path)"
    }
    Write-Output 'Supply-chain artifacts are up to date.'
    return
}

Write-PshUtf8NoBom -Path ([IO.Path]::GetFullPath($NoticesPath)) -Text $notices
Write-PshUtf8NoBom -Path ([IO.Path]::GetFullPath($SbomPath)) -Text $sbom
Write-Output ('Generated {0} and {1}.' -f (Split-Path -Leaf $NoticesPath), (Split-Path -Leaf $SbomPath))
