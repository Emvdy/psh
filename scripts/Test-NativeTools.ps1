# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LockPath,
    [ValidateSet('x86_64', 'aarch64', 'all')]
    [string]$Architecture = 'all'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Keep the selector for CI/job compatibility, but always validate both
# architecture trees so a single-architecture invocation cannot hide drift.
$null = $Architecture

function Assert-PshNativeTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw "Native tool verification failed: $Message" }
}

function Get-PshPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-PshFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function ConvertTo-PshNativeUtcTimestamp {
    param([AllowNull()][object]$Value)

    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Resolve-PshNativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshNativeTest (-not [string]::IsNullOrWhiteSpace($RelativePath)) "$Description is empty."
    Assert-PshNativeTest (-not [IO.Path]::IsPathRooted($RelativePath)) "$Description is rooted: $RelativePath"
    $segments = @($RelativePath.Replace('\', '/').Split('/'))
    Assert-PshNativeTest ($segments -notcontains '.' -and $segments -notcontains '..') "$Description contains a traversal segment: $RelativePath"
    Assert-PshNativeTest (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "$Description contains an empty segment: $RelativePath"
    Assert-PshNativeTest ($RelativePath -notmatch '[<>:"|?*]') "$Description contains an invalid character: $RelativePath"
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath((Join-Path -Path $fullRoot -ChildPath $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    $comparison = [StringComparison]::Ordinal
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $comparison = [StringComparison]::OrdinalIgnoreCase }
    Assert-PshNativeTest ($fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)) "$Description escapes its root: $RelativePath"
    return $fullPath
}

function Get-PshPeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-PshNativeTest ($bytes.Length -ge 64 -and $bytes[0] -eq 0x4d -and $bytes[1] -eq 0x5a) "Invalid MZ header: $Path"
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    Assert-PshNativeTest ($offset -ge 0 -and ($offset + 6) -le $bytes.Length) "Invalid PE offset: $Path"
    Assert-PshNativeTest ($bytes[$offset] -eq 0x50 -and $bytes[$offset + 1] -eq 0x45 -and $bytes[$offset + 2] -eq 0 -and $bytes[$offset + 3] -eq 0) "Invalid PE signature: $Path"
    return ('0x{0:X4}' -f [BitConverter]::ToUInt16($bytes, $offset + 4))
}

function Test-PshFixedUrl {
    param([string]$Actual, [string]$Expected, [string]$Description)

    Assert-PshNativeTest ($Actual -ceq $Expected) "$Description changed. Expected '$Expected', got '$Actual'."
    Assert-PshNativeTest ($Actual -match '\Ahttps://') "$Description is not HTTPS."
    Assert-PshNativeTest ($Actual -notmatch '(?i)(?:^|[/=])latest(?:[/?.#]|$)') "$Description uses latest."
    Assert-PshNativeTest ($Actual -notmatch '(?i)/(?:refs/heads/)?(?:main|master)(?:[/?.#]|$)') "$Description uses a floating branch."
}

function New-PshTrustedManifest {
    return [ordered]@{
        bat = [ordered]@{
            UpstreamName = 'bat'; Version = '0.26.1'; Repository = 'https://github.com/sharkdp/bat'; Tag = 'v0.26.1'; Commit = '979ba22628bc9d8171f2cffca2bd5c90c9fc0a9e'; License = 'MIT OR Apache-2.0'
            LicenseFiles = @(
                [ordered]@{ Path = 'licenses/bat-0.26.1/LICENSE-APACHE'; SourceUrl = 'https://raw.githubusercontent.com/sharkdp/bat/979ba22628bc9d8171f2cffca2bd5c90c9fc0a9e/LICENSE-APACHE'; Sha256 = 'c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4'; Size = 11357 }
                [ordered]@{ Path = 'licenses/bat-0.26.1/LICENSE-MIT'; SourceUrl = 'https://raw.githubusercontent.com/sharkdp/bat/979ba22628bc9d8171f2cffca2bd5c90c9fc0a9e/LICENSE-MIT'; Sha256 = 'dccda9eb9533f5c65624a1106536c6cfde46008d58e60b3faf154e8b9fd5b46e'; Size = 1097 }
                [ordered]@{ Path = 'licenses/bat-0.26.1/NOTICE'; SourceUrl = 'https://raw.githubusercontent.com/sharkdp/bat/979ba22628bc9d8171f2cffca2bd5c90c9fc0a9e/NOTICE'; Sha256 = 'dd46bdeebfdf5e0e55dd0b4636eff2bfbb8f8efeaea018ed86814710a23c1bda'; Size = 248 }
            )
            Artifacts = [ordered]@{
                'win-x64' = [ordered]@{ Architecture = 'x86_64'; TargetTriple = 'x86_64-pc-windows-msvc'; AssetId = 323549116; ApiUrl = 'https://api.github.com/repos/sharkdp/bat/releases/assets/323549116'; BrowserUrl = 'https://github.com/sharkdp/bat/releases/download/v0.26.1/bat-v0.26.1-x86_64-pc-windows-msvc.zip'; AssetName = 'bat-v0.26.1-x86_64-pc-windows-msvc.zip'; ArchiveType = 'zip'; ArchiveSha256 = '0f729b4b6f5f28d395c641eacc2e9ff68d0096b85aa0eec344aa62425144b69b'; ArchiveEntry = 'bat-v0.26.1-x86_64-pc-windows-msvc/bat.exe'; InstalledPath = 'win-x64/bat/bat.exe'; InstalledSha256 = '9ea9f7ab1c27aa5c9390e91543f9f47c6bd17bc53f3e30ac9db762f28f55c4fd'; PeMachine = '0x8664' }
                'win-arm64' = [ordered]@{ Architecture = 'aarch64'; TargetTriple = 'aarch64-pc-windows-msvc'; AssetId = 323548313; ApiUrl = 'https://api.github.com/repos/sharkdp/bat/releases/assets/323548313'; BrowserUrl = 'https://github.com/sharkdp/bat/releases/download/v0.26.1/bat-v0.26.1-aarch64-pc-windows-msvc.zip'; AssetName = 'bat-v0.26.1-aarch64-pc-windows-msvc.zip'; ArchiveType = 'zip'; ArchiveSha256 = 'af07dd1939e99f7f5892d197fc5653cb8cb6c5999552731135ad156eca7e38a5'; ArchiveEntry = 'bat-v0.26.1-aarch64-pc-windows-msvc/bat.exe'; InstalledPath = 'win-arm64/bat/bat.exe'; InstalledSha256 = 'e0b72283ac0ba6b7ba2c5b91233910ef40246f6f00a46cbda729dfcb3bde808c'; PeMachine = '0xAA64' }
            }
        }
        fd = [ordered]@{
            UpstreamName = 'fd'; Version = '10.4.2'; Repository = 'https://github.com/sharkdp/fd'; Tag = 'v10.4.2'; Commit = '7027d45303b412be6fa9c09d689cc6276748fb38'; License = 'MIT OR Apache-2.0'
            LicenseFiles = @(
                [ordered]@{ Path = 'licenses/fd-10.4.2/LICENSE-APACHE'; SourceUrl = 'https://raw.githubusercontent.com/sharkdp/fd/7027d45303b412be6fa9c09d689cc6276748fb38/LICENSE-APACHE'; Sha256 = '73c83c60d817e7df1943cb3f0af81e4939a8352c9a96c2fd00451b1116fa635c'; Size = 10838 }
                [ordered]@{ Path = 'licenses/fd-10.4.2/LICENSE-MIT'; SourceUrl = 'https://raw.githubusercontent.com/sharkdp/fd/7027d45303b412be6fa9c09d689cc6276748fb38/LICENSE-MIT'; Sha256 = '322cfc7aa0c774d0eca3b2610f1d414de3ddbd7d8dd4b9dea941a13a6eb07455'; Size = 1082 }
            )
            Artifacts = [ordered]@{
                'win-x64' = [ordered]@{ Architecture = 'x86_64'; TargetTriple = 'x86_64-pc-windows-msvc'; AssetId = 370661516; ApiUrl = 'https://api.github.com/repos/sharkdp/fd/releases/assets/370661516'; BrowserUrl = 'https://github.com/sharkdp/fd/releases/download/v10.4.2/fd-v10.4.2-x86_64-pc-windows-msvc.zip'; AssetName = 'fd-v10.4.2-x86_64-pc-windows-msvc.zip'; ArchiveType = 'zip'; ArchiveSha256 = 'b2816e506390a89941c63c9187d58a3cc10e9a55f2ef0685f9ea0eccaf7c98c8'; ArchiveEntry = 'fd-v10.4.2-x86_64-pc-windows-msvc/fd.exe'; InstalledPath = 'win-x64/fd/fd.exe'; InstalledSha256 = '4c9d082ee20f0d9e44881ac4e92adf765efc314d82103c53d7f576bd78dc5761'; PeMachine = '0x8664' }
                'win-arm64' = [ordered]@{ Architecture = 'aarch64'; TargetTriple = 'aarch64-pc-windows-msvc'; AssetId = 370662661; ApiUrl = 'https://api.github.com/repos/sharkdp/fd/releases/assets/370662661'; BrowserUrl = 'https://github.com/sharkdp/fd/releases/download/v10.4.2/fd-v10.4.2-aarch64-pc-windows-msvc.zip'; AssetName = 'fd-v10.4.2-aarch64-pc-windows-msvc.zip'; ArchiveType = 'zip'; ArchiveSha256 = '4f9110c2d5b33a7f760bfa5510f4c113d828109f7277d421b1053a9943c0fc92'; ArchiveEntry = 'fd-v10.4.2-aarch64-pc-windows-msvc/fd.exe'; InstalledPath = 'win-arm64/fd/fd.exe'; InstalledSha256 = 'e5f456004d0f550b5a67a0e33415e6d40520c57d1d3860dafca9bd0e24a8f977'; PeMachine = '0xAA64' }
            }
        }
        jq = [ordered]@{
            UpstreamName = 'jq'; Version = '1.8.2'; Repository = 'https://github.com/jqlang/jq'; Tag = 'jq-1.8.2'; Commit = '34f7186b86743a083a589741b6cea95293524108'; License = 'MIT AND LicenseRef-jq-embedded-notices'
            LicenseFiles = @([ordered]@{ Path = 'licenses/jq-1.8.2/COPYING'; SourceUrl = 'https://raw.githubusercontent.com/jqlang/jq/34f7186b86743a083a589741b6cea95293524108/COPYING'; Sha256 = 'ad2b4a266b2268939c1446979759706077421cf906a203aa188c6f396e8cfd74'; Size = 7887 })
            Artifacts = [ordered]@{
                'win-x64' = [ordered]@{ Architecture = 'x86_64'; TargetTriple = 'windows-amd64'; AssetId = 453012788; ApiUrl = 'https://api.github.com/repos/jqlang/jq/releases/assets/453012788'; BrowserUrl = 'https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-amd64.exe'; AssetName = 'jq-windows-amd64.exe'; ArchiveType = 'exe'; ArchiveSha256 = 'a6fc67fedaf9128a3309a1e2ebb8b986aeccf70122ee46d2cb4849e423f0c627'; ArchiveEntry = 'jq-windows-amd64.exe'; InstalledPath = 'win-x64/jq/jq.exe'; InstalledSha256 = 'a6fc67fedaf9128a3309a1e2ebb8b986aeccf70122ee46d2cb4849e423f0c627'; PeMachine = '0x8664' }
                'win-arm64' = [ordered]@{ Architecture = 'aarch64'; TargetTriple = 'windows-arm64'; AssetId = 453012789; ApiUrl = 'https://api.github.com/repos/jqlang/jq/releases/assets/453012789'; BrowserUrl = 'https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-arm64.exe'; AssetName = 'jq-windows-arm64.exe'; ArchiveType = 'exe'; ArchiveSha256 = '083b5377392bc57cf27052b6d20a2d927770683bca844632901ff38b4b7b0ac7'; ArchiveEntry = 'jq-windows-arm64.exe'; InstalledPath = 'win-arm64/jq/jq.exe'; InstalledSha256 = '083b5377392bc57cf27052b6d20a2d927770683bca844632901ff38b4b7b0ac7'; PeMachine = '0xAA64' }
            }
        }
        rg = [ordered]@{
            UpstreamName = 'ripgrep'; Version = '15.2.0'; Repository = 'https://github.com/BurntSushi/ripgrep'; Tag = '15.2.0'; TagObject = '6ec72defacfb042f203ca0b4bf2513a0a5505a7e'; Commit = 'e89fff89ac9af12e8d4ce9d5fd07beb408ca730f'; License = 'Unlicense OR MIT'
            LicenseFiles = @(
                [ordered]@{ Path = 'licenses/ripgrep-15.2.0/COPYING'; SourceUrl = 'https://raw.githubusercontent.com/BurntSushi/ripgrep/e89fff89ac9af12e8d4ce9d5fd07beb408ca730f/COPYING'; Sha256 = '01c266bced4a434da0051174d6bee16a4c82cf634e2679b6155d40d75012390f'; Size = 126 }
                [ordered]@{ Path = 'licenses/ripgrep-15.2.0/LICENSE-MIT'; SourceUrl = 'https://raw.githubusercontent.com/BurntSushi/ripgrep/e89fff89ac9af12e8d4ce9d5fd07beb408ca730f/LICENSE-MIT'; Sha256 = '0f96a83840e146e43c0ec96a22ec1f392e0680e6c1226e6f3ba87e0740af850f'; Size = 1081 }
                [ordered]@{ Path = 'licenses/ripgrep-15.2.0/UNLICENSE'; SourceUrl = 'https://raw.githubusercontent.com/BurntSushi/ripgrep/e89fff89ac9af12e8d4ce9d5fd07beb408ca730f/UNLICENSE'; Sha256 = '7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c'; Size = 1211 }
            )
            Artifacts = [ordered]@{
                'win-x64' = [ordered]@{ Architecture = 'x86_64'; TargetTriple = 'x86_64-pc-windows-msvc'; AssetId = 478119643; ApiUrl = 'https://api.github.com/repos/BurntSushi/ripgrep/releases/assets/478119643'; BrowserUrl = 'https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'; AssetName = 'ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'; ArchiveType = 'zip'; ArchiveSha256 = '71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5'; ArchiveEntry = 'ripgrep-15.2.0-x86_64-pc-windows-msvc/rg.exe'; InstalledPath = 'win-x64/rg/rg.exe'; InstalledSha256 = '14231169855ec5205cf5a1b6f1db358ff4aed4247c86b69ce8aae647c77f6680'; PeMachine = '0x8664' }
                'win-arm64' = [ordered]@{ Architecture = 'aarch64'; TargetTriple = 'aarch64-pc-windows-msvc'; AssetId = 478119680; ApiUrl = 'https://api.github.com/repos/BurntSushi/ripgrep/releases/assets/478119680'; BrowserUrl = 'https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-pc-windows-msvc.zip'; AssetName = 'ripgrep-15.2.0-aarch64-pc-windows-msvc.zip'; ArchiveType = 'zip'; ArchiveSha256 = 'e4abca10c3a64ebea742667dd7009449d49403db5460dd6873e389fa2945360f'; ArchiveEntry = 'ripgrep-15.2.0-aarch64-pc-windows-msvc/rg.exe'; InstalledPath = 'win-arm64/rg/rg.exe'; InstalledSha256 = 'd33a29a9ef03c9f4c03be9e8d88498e6e2d2e566d64cdbdef97f9afc8f13120c'; PeMachine = '0xAA64' }
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($LockPath)) {
    $LockPath = Join-Path -Path (Join-Path -Path $RepositoryRoot -ChildPath 'tools') -ChildPath 'native-tools.lock.json'
}
$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$lockPath = [IO.Path]::GetFullPath($LockPath)
Assert-PshNativeTest (Test-Path -LiteralPath $lockPath -PathType Leaf) "Lock file is missing: $lockPath"
$lockBytes = [IO.File]::ReadAllBytes($lockPath)
Assert-PshNativeTest (-not ($lockBytes.Length -ge 3 -and $lockBytes[0] -eq 0xEF -and $lockBytes[1] -eq 0xBB -and $lockBytes[2] -eq 0xBF)) 'Lock must be UTF-8 without a BOM.'
$lock = [IO.File]::ReadAllText($lockPath, (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json -ErrorAction Stop
Assert-PshNativeTest ([int]$lock.schemaVersion -eq 1) 'schemaVersion must be 1.'
Assert-PshNativeTest ([string]$lock.toolRoot -ceq 'tools') 'toolRoot must be tools.'
Assert-PshNativeTest ($null -ne $lock.manifest -and (ConvertTo-PshNativeUtcTimestamp $lock.manifest.created) -ceq '2026-07-20T00:00:00Z' -and [string]$lock.manifest.namespaceSeed -ceq 'goal4-full-tools-supply-chain-v1') 'manifest is missing or changed.'

$trusted = New-PshTrustedManifest
$expectedNames = @('bat', 'fd', 'jq', 'rg')
$actualNames = @($lock.tools | ForEach-Object { [string]$_.name })
Assert-PshNativeTest (($actualNames -join '|') -ceq ($expectedNames -join '|')) 'tools must be sorted bat, fd, jq, rg exactly.'
$expectedArtifactProperties = @('state', 'architecture', 'targetTriple', 'assetId', 'apiUrl', 'browserUrl', 'assetName', 'archiveType', 'archiveSha256', 'executableArchivePath', 'installedPath', 'installedSha256', 'peMachine')
$expectedLicenseProperties = @('path', 'sourceUrl', 'sha256', 'size')
$toolsRoot = Resolve-PshNativePath -Root $repositoryRootPath -RelativePath 'tools' -Description 'tools root'
$expectedToolFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void]$expectedToolFiles.Add('native-tools.lock.json')

foreach ($tool in @($lock.tools)) {
    $name = [string]$tool.name
    Assert-PshNativeTest ($trusted.Contains($name)) "Unexpected tool: $name"
    $pin = $trusted[$name]
    foreach ($field in @('name', 'upstreamName', 'version', 'source', 'license', 'versionProbe', 'artifacts')) {
        Assert-PshNativeTest ($null -ne $tool.PSObject.Properties[$field]) "$name is missing $field."
    }
    Assert-PshNativeTest ([string]$tool.upstreamName -ceq $pin.UpstreamName -and [string]$tool.version -ceq $pin.Version) "$name version metadata changed."
    Assert-PshNativeTest ([string]$tool.source.repository -ceq $pin.Repository -and [string]$tool.source.tag -ceq $pin.Tag -and [string]$tool.source.commit -ceq $pin.Commit) "$name source/tag/commit changed."
    $trustedTagObject = Get-PshPropertyValue -InputObject $pin -Name 'TagObject'
    if ($null -ne $trustedTagObject) { Assert-PshNativeTest ([string]$tool.source.tagObject -ceq [string]$trustedTagObject) "$name annotated tag object changed." }
    Assert-PshNativeTest ([string]$tool.license.declaredSpdx -ceq $pin.License) "$name SPDX declaration changed."
    Assert-PshNativeTest ((@($tool.versionProbe.arguments | ForEach-Object { [string]$_ }) -join '|') -ceq '--version') "$name version probe arguments changed."
    $expectedPattern = '^' + [regex]::Escape($name) + ' ' + [regex]::Escape($pin.Version) + '$'
    if ($name -ceq 'bat') { $expectedPattern = '^bat ' + [regex]::Escape($pin.Version) + ' \(' + [regex]::Escape($pin.Commit.Substring(0, 7)) + '\)$' }
    if ($name -ceq 'rg') { $expectedPattern = '^ripgrep ' + [regex]::Escape($pin.Version) + '$' }
    if ($name -ceq 'jq') { $expectedPattern = '^jq-' + [regex]::Escape($pin.Version) + '$' }
    Assert-PshNativeTest ([string]$tool.versionProbe.pattern -ceq $expectedPattern) "$name version probe pattern changed."

    $artifactNames = @($tool.artifacts.PSObject.Properties.Name)
    Assert-PshNativeTest (($artifactNames -join '|') -ceq 'win-x64|win-arm64') "$name artifacts must be ordered win-x64, win-arm64."
    foreach ($rid in @('win-x64', 'win-arm64')) {
        $artifact = $tool.artifacts.$rid
        $pinArtifact = $pin.Artifacts[$rid]
        Assert-PshNativeTest ((@($artifact.PSObject.Properties.Name) -join '|') -ceq ($expectedArtifactProperties -join '|')) "$name/$rid has a loose artifact schema."
        foreach ($field in $expectedArtifactProperties) { Assert-PshNativeTest ($null -ne $artifact.PSObject.Properties[$field]) "$name/$rid is missing $field." }
        foreach ($pair in @(
            @('architecture', 'Architecture'), @('targetTriple', 'TargetTriple'), @('assetId', 'AssetId'), @('apiUrl', 'ApiUrl'), @('browserUrl', 'BrowserUrl'), @('assetName', 'AssetName'), @('archiveType', 'ArchiveType'), @('archiveSha256', 'ArchiveSha256'), @('executableArchivePath', 'ArchiveEntry'), @('installedPath', 'InstalledPath'), @('installedSha256', 'InstalledSha256'), @('peMachine', 'PeMachine')
        )) { Assert-PshNativeTest ([string](Get-PshPropertyValue -InputObject $artifact -Name $pair[0]) -ceq [string](Get-PshPropertyValue -InputObject $pinArtifact -Name $pair[1])) "$name/$rid $($pair[0]) changed." }
        Assert-PshNativeTest ([string]$artifact.state -ceq 'pinned') "$name/$rid is not pinned."
        Assert-PshNativeTest ([string]$artifact.installedSha256 -match '\A[0-9a-fA-F]{64}\z' -and [string]$artifact.installedSha256 -match '[1-9a-fA-F]') "$name/$rid installedSha256 is empty or malformed."
        Assert-PshNativeTest ([string]$artifact.archiveSha256 -match '\A[0-9a-fA-F]{64}\z') "$name/$rid archiveSha256 is malformed."
        Assert-PshNativeTest ([int64]$artifact.assetId -gt 0) "$name/$rid assetId is not numeric."
        Assert-PshNativeTest ([string]$artifact.apiUrl -match '/releases/assets/[0-9]+\z') "$name/$rid apiUrl is not a numeric asset URL."
        Test-PshFixedUrl -Actual ([string]$artifact.apiUrl) -Expected ([string]$pinArtifact.ApiUrl) -Description "$name/$rid apiUrl"
        Test-PshFixedUrl -Actual ([string]$artifact.browserUrl) -Expected ([string]$pinArtifact.BrowserUrl) -Description "$name/$rid browserUrl"
        Assert-PshNativeTest ([string]$artifact.archiveType -in @('zip', 'exe')) "$name/$rid archiveType is unsupported."
        Assert-PshNativeTest ([string]$artifact.installedPath -match ('\A{0}/' -f [regex]::Escape($rid))) "$name/$rid installedPath is outside its architecture directory."
        $installed = Resolve-PshNativePath -Root $toolsRoot -RelativePath ([string]$artifact.installedPath) -Description "$name/$rid installedPath"
        Assert-PshNativeTest (Test-Path -LiteralPath $installed -PathType Leaf) "$name/$rid executable is missing."
        Assert-PshNativeTest ((Get-PshFileSha256 -Path $installed) -ceq ([string]$artifact.installedSha256).ToLowerInvariant()) "$name/$rid installed SHA256 mismatches."
        Assert-PshNativeTest ([string]::Equals((Get-PshPeMachine -Path $installed), [string]$artifact.peMachine, [StringComparison]::OrdinalIgnoreCase)) "$name/$rid PE machine mismatches."
        [void]$expectedToolFiles.Add(([string]$artifact.installedPath).Replace('/', [IO.Path]::DirectorySeparatorChar))
    }

    $licenseEntries = @($tool.license.files)
    Assert-PshNativeTest ($licenseEntries.Count -eq @($pin.LicenseFiles).Count) "$name license file count changed."
    foreach ($license in $licenseEntries) {
        Assert-PshNativeTest ((@($license.PSObject.Properties.Name) -join '|') -ceq ($expectedLicenseProperties -join '|')) "$name license entry has a loose schema."
        $trustedLicense = @($pin.LicenseFiles | Where-Object { [string]$_.Path -ceq [string]$license.path })[0]
        Assert-PshNativeTest ($null -ne $trustedLicense) "$name contains an unexpected license path."
        Assert-PshNativeTest ([string]$license.sourceUrl -ceq $trustedLicense.SourceUrl) "$name license source URL changed."
        Assert-PshNativeTest ([string]$license.sha256 -ceq [string]$trustedLicense.Sha256) "$name license SHA256 changed: $($license.path)"
        Assert-PshNativeTest ([int64]$license.size -eq [int64]$trustedLicense.Size) "$name license size changed: $($license.path)"
        Assert-PshNativeTest ([string]$license.path -notmatch '\A(?:[A-Za-z]:|/)' -and [string]$license.path -notmatch '(^|[\\/])\.\.?([\\/]|$)') "$name license path is not canonical."
        Test-PshFixedUrl -Actual ([string]$license.sourceUrl) -Expected ([string]$trustedLicense.SourceUrl) -Description "$name license source URL"
        Assert-PshNativeTest ([string]$license.sha256 -match '\A[0-9a-fA-F]{64}\z' -and [string]$license.sha256 -match '[1-9a-fA-F]') "$name license SHA256 is empty or malformed."
        $licensePath = Resolve-PshNativePath -Root $repositoryRootPath -RelativePath ([string]$license.path) -Description "$name license path"
        Assert-PshNativeTest (Test-Path -LiteralPath $licensePath -PathType Leaf) "$name license is missing: $($license.path)"
        Assert-PshNativeTest ((Get-PshFileSha256 -Path $licensePath) -ceq ([string]$license.sha256).ToLowerInvariant()) "$name license SHA256 mismatches: $($license.path)"
        Assert-PshNativeTest ([int64]$license.size -eq [int64](Get-Item -LiteralPath $licensePath).Length) "$name license size mismatches: $($license.path)"
    }
}

$actualToolFiles = @(Get-ChildItem -LiteralPath $toolsRoot -Recurse -File | ForEach-Object {
    $_.FullName.Substring($toolsRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
})
foreach ($path in $actualToolFiles) { Assert-PshNativeTest ($expectedToolFiles.Contains($path)) "Unexpected tool file: $path" }
Assert-PshNativeTest ($actualToolFiles.Count -eq $expectedToolFiles.Count) 'Tool tree contains missing or extra files.'

Write-Output ('Native tool verification passed: {0} tools, 8 architecture-specific executables, fixed source commits, and retained licenses.' -f @($lock.tools).Count)
