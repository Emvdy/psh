# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

# Native tools are an optional Full-edition boundary.  This file is loaded by
# the module before command implementations so every native command consumes
# the same lock, architecture and verification rules.

function Get-PshNativePropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return (, $InputObject[$key])
            }
        }
        return $null
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if ([string]::Equals([string]$property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return (, $property.Value)
        }
    }

    return $null
}

function Test-PshNativeProperty {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if ([string]::Equals([string]$property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-PshNativeHexSha256 {
    param([AllowNull()][object]$Value)
    return ([string]$Value).Trim() -cmatch '\A[0-9a-fA-F]{64}\z'
}

function Test-PshNativeWindowsPlatform {
    try {
        return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Windows)
    }
    catch {
        return ($env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\')
    }
}

function Get-PshNativeToolArchitecture {
    # A private override is useful for deterministic fixture tests.  It is not
    # read from an environment variable, so ordinary production callers cannot
    # silently select an artifact for another architecture.
    $overrideVariable = Get-Variable -Name PshNativeToolArchitectureOverride -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $overrideVariable -and -not [string]::IsNullOrWhiteSpace([string]$overrideVariable.Value)) {
        $override = ([string]$overrideVariable.Value).Trim().ToLowerInvariant()
        if ($override -ne 'win-x64' -and $override -ne 'win-arm64') {
            throw ('Unsupported native-tool architecture override: {0}.' -f $override)
        }
        return $override
    }

    # Prefer the WOW64 override when present: an x86 PowerShell process on an
    # ARM64 host reports its host architecture through PROCESSOR_ARCHITEW6432.
    $architectureCandidates = @()
    $wowArchitecture = [string]$env:PROCESSOR_ARCHITEW6432
    $processEnvironmentArchitecture = [string]$env:PROCESSOR_ARCHITECTURE
    if (-not [string]::IsNullOrWhiteSpace($wowArchitecture)) { $architectureCandidates += $wowArchitecture }
    if (-not [string]::IsNullOrWhiteSpace($processEnvironmentArchitecture)) { $architectureCandidates += $processEnvironmentArchitecture }
    try {
        $architectureCandidates += [string]([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)
    }
    catch {
        # Environment variables above are the PS5.1 fallback.
    }

    foreach ($candidate in @($architectureCandidates)) {
        $architectureName = ([string]$candidate).Trim().ToLowerInvariant()
        switch ($architectureName) {
            'x64' { return 'win-x64' }
            'amd64' { return 'win-x64' }
            'arm64' { return 'win-arm64' }
            'aarch64' { return 'win-arm64' }
        }
    }
    throw ('Unsupported native-tool process architecture: {0}.' -f (($architectureCandidates -join ', ')))
}

function Get-PshNativeModuleRoot {
    $moduleRoot = $null
    try {
        if ($null -ne $ExecutionContext.SessionState.Module) {
            $moduleRoot = [string]$ExecutionContext.SessionState.Module.ModuleBase
        }
    }
    catch {
        $moduleRoot = $null
    }

    if ([string]::IsNullOrWhiteSpace($moduleRoot)) {
        # NativeTools.ps1 lives directly under the module root.
        $moduleRoot = $PSScriptRoot
    }

    return [IO.Path]::GetFullPath($moduleRoot)
}

function Get-PshNativeToolsRoot {
    param([AllowNull()][string]$ModuleRoot)
    if ([string]::IsNullOrWhiteSpace($ModuleRoot)) {
        $ModuleRoot = Get-PshNativeModuleRoot
    }
    return [IO.Path]::GetFullPath((Join-Path -Path $ModuleRoot -ChildPath 'Tools'))
}

function Test-PshNativePathContained {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowRoot
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $comparison = [System.StringComparison]::Ordinal
    if (Test-PshNativeWindowsPlatform) {
        $comparison = [System.StringComparison]::OrdinalIgnoreCase
    }
    if ($AllowRoot -and [string]::Equals($rootFull, $pathFull, $comparison)) {
        return $true
    }
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($prefix, $comparison)
}

function ConvertTo-PshNativeRelativePath {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw ('native-tools lock field {0} must be a non-empty relative path.' -f $FieldName)
    }
    $text = ([string]$Value).Trim()
    if ([IO.Path]::IsPathRooted($text) -or $text -match '\A(?:[A-Za-z]:[\\/]|[\\/])') {
        throw ('native-tools lock field {0} must not be absolute.' -f $FieldName)
    }
    if ($text -match '[<>:"|?*]') {
        throw ('native-tools lock field {0} contains an invalid path character.' -f $FieldName)
    }
    $normalized = $text.Replace('\', '/')
    $segments = $normalized.Split('/')
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -ceq '.' -or $segment -ceq '..') {
            throw ('native-tools lock field {0} contains an invalid path segment.' -f $FieldName)
        }
    }
    return ($segments -join '/')
}

function ConvertTo-PshNativeContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$RelativeValue,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    $relative = ConvertTo-PshNativeRelativePath -Value $RelativeValue -FieldName $FieldName
    $platformRelative = $relative.Replace('/', [string][IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path -Path $Root -ChildPath $platformRelative))
    if (-not (Test-PshNativePathContained -Root $Root -Path $full)) {
        throw ('native-tools lock field {0} escapes the Tools directory.' -f $FieldName)
    }
    return [PSCustomObject]@{ Relative = $relative; Full = $full }
}

function Assert-PshNativePathChain {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not (Test-PshNativePathContained -Root $rootFull -Path $pathFull)) {
        throw ('native-tools lock field {0} escapes the Tools directory.' -f $FieldName)
    }

    $pathsToInspect = @($rootFull)
    $relative = $pathFull.Substring($rootFull.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $current = $rootFull
    foreach ($segment in @($relative.Split([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) | Where-Object { $_.Length -gt 0 })) {
        $current = Join-Path -Path $current -ChildPath $segment
        $pathsToInspect += $current
    }

    foreach ($candidate in $pathsToInspect) {
        if (-not [IO.File]::Exists($candidate) -and -not [IO.Directory]::Exists($candidate)) {
            throw ('native-tools lock field {0} contains a missing path component.' -f $FieldName)
        }
        $attributes = [IO.File]::GetAttributes($candidate)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('native-tools lock field {0} traverses a reparse point.' -f $FieldName)
        }
    }
}

function Get-PshNativeToolLockPath {
    param([AllowNull()][string]$ModuleRoot)

    $toolsRoot = Get-PshNativeToolsRoot -ModuleRoot $ModuleRoot
    $lockPath = [IO.Path]::GetFullPath((Join-Path -Path $toolsRoot -ChildPath 'native-tools.lock.json'))
    if (-not (Test-PshNativePathContained -Root $toolsRoot -Path $lockPath)) {
        throw 'native-tools lock path is outside the Tools directory.'
    }
    return [PSCustomObject]@{ Path = $lockPath; ToolsRoot = $toolsRoot }
}

function Assert-PshNativeLockShape {
    param([Parameter(Mandatory = $true)][object]$Lock)

    $schemaVersion = Get-PshNativePropertyValue -InputObject $Lock -Name 'schemaVersion'
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [int64]$schemaVersion -ne 1) {
        throw 'Unsupported native-tools lock schemaVersion; expected integer 1.'
    }
    $manifest = Get-PshNativePropertyValue -InputObject $Lock -Name 'manifest'
    if ($null -eq $manifest) {
        throw 'native-tools lock manifest is missing.'
    }
    $created = Get-PshNativePropertyValue -InputObject $manifest -Name 'created'
    if (($created -isnot [string] -and $created -isnot [DateTime] -and $created -isnot [DateTimeOffset]) -or
        [string]::IsNullOrWhiteSpace([string]$created)) {
        throw 'native-tools lock manifest.created is missing.'
    }
    $namespaceSeed = Get-PshNativePropertyValue -InputObject $manifest -Name 'namespaceSeed'
    if ($namespaceSeed -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$namespaceSeed)) {
        throw 'native-tools lock manifest.namespaceSeed is missing.'
    }
    $tools = Get-PshNativePropertyValue -InputObject $Lock -Name 'tools'
    if ($null -eq $tools -or @($tools).Count -eq 0) {
        throw 'native-tools lock tools array is missing or empty.'
    }

    $known = @('bat', 'fd', 'jq', 'rg')
    $actualNames = @($tools | ForEach-Object { ([string](Get-PshNativePropertyValue $_ 'name')).Trim().ToLowerInvariant() })
    if (($actualNames -join '|') -cne ($known -join '|')) {
        throw 'native-tools lock tools must contain exactly bat, fd, jq, rg in ordinal order.'
    }
    $seen = @{}
    foreach ($tool in @($tools)) {
        if ($null -eq $tool -or -not (Test-PshNativeProperty $tool 'name')) {
            throw 'native-tools lock contains a tool without name.'
        }
        $name = ([string](Get-PshNativePropertyValue $tool 'name')).Trim().ToLowerInvariant()
        if ($known -notcontains $name) {
            throw ('native-tools lock contains unknown tool: {0}.' -f $name)
        }
        if ($seen.ContainsKey($name)) {
            throw ('native-tools lock contains duplicate tool: {0}.' -f $name)
        }
        $seen[$name] = $true
        foreach ($field in @('upstreamName', 'version', 'source', 'license', 'versionProbe', 'artifacts')) {
            if (-not (Test-PshNativeProperty $tool $field)) {
                throw ('native-tools lock tool {0} is missing {1}.' -f $name, $field)
            }
        }
        foreach ($field in @('upstreamName', 'version')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-PshNativePropertyValue $tool $field))) {
                throw ('native-tools lock tool {0} {1} is empty.' -f $name, $field)
            }
        }
        $source = Get-PshNativePropertyValue $tool 'source'
        foreach ($field in @('repository', 'tag', 'commit')) {
            if ($null -eq $source -or [string]::IsNullOrWhiteSpace([string](Get-PshNativePropertyValue $source $field))) {
                throw ('native-tools lock tool {0} source.{1} is missing.' -f $name, $field)
            }
        }
        $license = Get-PshNativePropertyValue $tool 'license'
        if ([string]::IsNullOrWhiteSpace([string](Get-PshNativePropertyValue $license 'declaredSpdx'))) {
            throw ('native-tools lock tool {0} license.declaredSpdx is missing.' -f $name)
        }
        $licenseFiles = Get-PshNativePropertyValue $license 'files'
        if ($null -eq $licenseFiles -or @($licenseFiles).Count -eq 0) {
            throw ('native-tools lock tool {0} license.files is missing.' -f $name)
        }
        foreach ($licenseFile in @($licenseFiles)) {
            foreach ($field in @('path', 'sourceUrl', 'sha256')) {
                if ([string]::IsNullOrWhiteSpace([string](Get-PshNativePropertyValue $licenseFile $field))) {
                    throw ('native-tools lock tool {0} license file is missing {1}.' -f $name, $field)
                }
            }
            $null = ConvertTo-PshNativeRelativePath -Value (Get-PshNativePropertyValue $licenseFile 'path') -FieldName 'license.files.path'
            $licenseSha256 = [string](Get-PshNativePropertyValue $licenseFile 'sha256')
            if (-not (Test-PshNativeHexSha256 $licenseSha256) -or $licenseSha256 -cmatch '\A0{64}\z') {
                throw ('native-tools lock tool {0} license file SHA256 is invalid.' -f $name)
            }
        }
        $probe = Get-PshNativePropertyValue $tool 'versionProbe'
        $probeArguments = Get-PshNativePropertyValue $probe 'arguments'
        if ($null -eq $probeArguments -or $probeArguments -is [string] -or @($probeArguments).Count -eq 0 -or
            [string]::IsNullOrWhiteSpace([string](Get-PshNativePropertyValue $probe 'pattern'))) {
            throw ('native-tools lock tool {0} versionProbe is invalid.' -f $name)
        }
        foreach ($argument in @($probeArguments)) {
            if ($argument -isnot [string]) {
                throw ('native-tools lock tool {0} versionProbe arguments must be strings.' -f $name)
            }
        }
        try {
            $probePattern = [string](Get-PshNativePropertyValue $probe 'pattern')
            $null = New-Object Text.RegularExpressions.Regex -ArgumentList @($probePattern)
        }
        catch {
            throw ('native-tools lock tool {0} versionProbe pattern is invalid.' -f $name)
        }
        $artifacts = Get-PshNativePropertyValue $tool 'artifacts'
        if ($null -eq $artifacts) {
            throw ('native-tools lock tool {0} artifacts is null.' -f $name)
        }
        $artifactNames = @($artifacts.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if (($artifactNames -join '|') -cne 'win-x64|win-arm64') {
            throw ('native-tools lock tool {0} artifacts must be ordered win-x64, win-arm64.' -f $name)
        }
        foreach ($architecture in @('win-x64', 'win-arm64')) {
            if (-not (Test-PshNativeProperty $artifacts $architecture)) {
                throw ('native-tools lock tool {0} is missing artifacts.{1}.' -f $name, $architecture)
            }
            try {
                # Validate both architecture records while importing the lock,
                # even though only the host-selected executable is resolved.
                # A malformed inactive record must not hide in an otherwise
                # usable lock.
                $null = Get-PshNativeToolArtifact -Tool $tool -Architecture $architecture
            }
            catch {
                throw ('native-tools lock tool {0} artifact {1} is invalid: {2}' -f $name, $architecture, $_.Exception.Message)
            }
        }
    }

    return $Lock
}

function Import-PshNativeToolLock {
    param(
        [AllowNull()][string]$ModuleRoot,
        [switch]$AllowMissing
    )

    $location = Get-PshNativeToolLockPath -ModuleRoot $ModuleRoot
    if (-not [IO.File]::Exists($location.Path)) {
        if ($AllowMissing) { return $null }
        throw 'native-tools lock is unavailable.'
    }
    try {
        Assert-PshNativePathChain -Root $location.ToolsRoot -Path $location.Path -FieldName 'native-tools.lock.json'
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        $text = [IO.File]::ReadAllText($location.Path, $encoding)
        $lock = $text | ConvertFrom-Json -ErrorAction Stop
        Assert-PshNativeLockShape -Lock $lock | Out-Null
        return [PSCustomObject]@{ Lock = $lock; Path = $location.Path; ToolsRoot = $location.ToolsRoot }
    }
    catch {
        if ($_.Exception.Message -like 'Unsupported native-tools lock*' -or $_.Exception.Message -like 'native-tools lock*') {
            throw
        }
        throw ('cannot parse native-tools lock: {0}' -f $_.Exception.Message)
    }
}

function Get-PshNativeToolEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Lock,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $tools = Get-PshNativePropertyValue -InputObject $Lock -Name 'tools'
    foreach ($tool in @($tools)) {
        if ([string]::Equals([string](Get-PshNativePropertyValue $tool 'name'), $Name, [StringComparison]::OrdinalIgnoreCase)) {
            return $tool
        }
    }
    return $null
}

function Get-PshNativeToolArtifact {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][string]$Architecture
    )

    $artifacts = Get-PshNativePropertyValue $Tool 'artifacts'
    $artifact = Get-PshNativePropertyValue $artifacts $Architecture
    if ($null -eq $artifact) {
        throw ('native-tools lock has no artifact for architecture {0}.' -f $Architecture)
    }
    $expectedArchitecture = if ($Architecture -ceq 'win-x64') { 'x86_64' } else { 'aarch64' }
    $expectedMachine = if ($Architecture -ceq 'win-x64') { '0x8664' } else { '0xAA64' }
    foreach ($field in @('state', 'architecture', 'targetTriple', 'assetId', 'apiUrl', 'browserUrl', 'assetName', 'archiveType', 'archiveSha256', 'executableArchivePath', 'installedPath', 'installedSha256', 'peMachine')) {
        if (-not (Test-PshNativeProperty $artifact $field)) {
            throw ('native-tools artifact {0} is missing {1}.' -f $Architecture, $field)
        }
    }
    if ([string]$artifact.state -cne 'pinned') {
        throw ('native-tools artifact {0} is not pinned.' -f $Architecture)
    }
    if ([string]$artifact.architecture -cne $expectedArchitecture) {
        throw ('native-tools artifact {0} architecture does not match its key.' -f $Architecture)
    }
    foreach ($field in @('targetTriple', 'apiUrl', 'browserUrl', 'assetName')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-PshNativePropertyValue $artifact $field))) {
            throw ('native-tools artifact {0} {1} is empty.' -f $Architecture, $field)
        }
    }
    foreach ($field in @('apiUrl', 'browserUrl')) {
        if (-not ([string](Get-PshNativePropertyValue $artifact $field)).StartsWith('https://', [StringComparison]::Ordinal)) {
            throw ('native-tools artifact {0} {1} must be HTTPS.' -f $Architecture, $field)
        }
    }
    if (([string]$artifact.archiveType).ToLowerInvariant() -notin @('zip', 'exe')) {
        throw ('native-tools artifact {0} has an unsupported archiveType.' -f $Architecture)
    }
    $assetId = Get-PshNativePropertyValue $artifact 'assetId'
    if (($assetId -isnot [int] -and $assetId -isnot [long]) -or [int64]$assetId -le 0) {
        throw ('native-tools artifact {0} assetId is invalid.' -f $Architecture)
    }
    foreach ($field in @('archiveSha256', 'installedSha256')) {
        $sha256 = [string](Get-PshNativePropertyValue $artifact $field)
        if (-not (Test-PshNativeHexSha256 $sha256) -or $sha256 -cmatch '\A0{64}\z') {
            throw ('native-tools artifact {0} {1} is not SHA256.' -f $Architecture, $field)
        }
    }
    if ([string]$artifact.peMachine -ine $expectedMachine) {
        throw ('native-tools artifact {0} peMachine does not match its architecture.' -f $Architecture)
    }
    $null = ConvertTo-PshNativeRelativePath -Value $artifact.executableArchivePath -FieldName 'executableArchivePath'
    $installedRelative = ConvertTo-PshNativeRelativePath -Value $artifact.installedPath -FieldName 'installedPath'
    if (-not $installedRelative.StartsWith($Architecture + '/', [StringComparison]::Ordinal)) {
        throw ('native-tools artifact {0} installedPath is outside its architecture directory.' -f $Architecture)
    }
    return $artifact
}

function Get-PshNativePeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $reader = New-Object IO.BinaryReader -ArgumentList @($stream)
        if ($stream.Length -lt 64) { return $null }
        if ($reader.ReadUInt16() -ne 0x5a4d) { return $null }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset + 6 -gt $stream.Length) { return $null }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { return $null }
        return ('0x{0:X4}' -f $reader.ReadUInt16())
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Resolve-PshPinnedNativeTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$ModuleRoot
    )

    $normalizedName = $Name.Trim().ToLowerInvariant()
    $unavailable = [ordered]@{
        Code = 4; Message = ('the pinned {0} dependency is unavailable.' -f $normalizedName); Path = $null
        Name = $normalizedName; Version = $null; Sha256 = $null; Architecture = $null; State = 'unavailable'
        PeMachine = $null; VersionProbe = $null
    }
    try {
        $architecture = Get-PshNativeToolArchitecture
        $unavailable.Architecture = $architecture
        $loaded = Import-PshNativeToolLock -ModuleRoot $ModuleRoot -AllowMissing
        if ($null -eq $loaded) { return [PSCustomObject]$unavailable }
        $tool = Get-PshNativeToolEntry -Lock $loaded.Lock -Name $normalizedName
        if ($null -eq $tool) { return [PSCustomObject]$unavailable }
        $unavailable.Version = [string]$tool.version
        $unavailable.VersionProbe = Get-PshNativePropertyValue $tool 'versionProbe'
        $artifact = Get-PshNativeToolArtifact -Tool $tool -Architecture $architecture
        $unavailable.Sha256 = [string]$artifact.installedSha256
        $unavailable.PeMachine = [string]$artifact.peMachine
        $pathInfo = ConvertTo-PshNativeContainedPath -Root $loaded.ToolsRoot -RelativeValue $artifact.installedPath -FieldName 'installedPath'
        if (-not [IO.File]::Exists($pathInfo.Full)) {
            return [PSCustomObject]([ordered]@{
                Code = 4; Message = ('the pinned {0} executable is missing.' -f $normalizedName); Path = $null
                Name = $normalizedName; Version = [string]$tool.version; Sha256 = [string]$artifact.installedSha256
                Architecture = $architecture; State = 'missing'; PeMachine = $null
                VersionProbe = Get-PshNativePropertyValue $tool 'versionProbe'
            })
        }
        $resolvedPath = $pathInfo.Full
        try {
            Assert-PshNativePathChain -Root $loaded.ToolsRoot -Path $resolvedPath -FieldName 'installedPath'
            $physical = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $resolvedPath -ErrorAction Stop).Path)
            if (-not (Test-PshNativePathContained -Root $loaded.ToolsRoot -Path $physical)) {
                throw 'installedPath resolves outside the Tools directory.'
            }
            $resolvedPath = $physical
        }
        catch {
            return [PSCustomObject]([ordered]@{
                Code = 5; Message = ('the pinned {0} executable path is invalid: {1}' -f $normalizedName, $_.Exception.Message); Path = $null
                Name = $normalizedName; Version = [string]$tool.version; Sha256 = [string]$artifact.installedSha256
                Architecture = $architecture; State = 'invalid'; PeMachine = $null
                VersionProbe = Get-PshNativePropertyValue $tool 'versionProbe'
            })
        }
        $actualSha = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not [string]::Equals([string]$actualSha, ([string]$artifact.installedSha256).Trim(), [StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]([ordered]@{
                Code = 5; Message = ('the pinned {0} executable failed SHA256 verification.' -f $normalizedName); Path = $null
                Name = $normalizedName; Version = [string]$tool.version; Sha256 = [string]$artifact.installedSha256
                Architecture = $architecture; State = 'tampered'; PeMachine = $null
                VersionProbe = Get-PshNativePropertyValue $tool 'versionProbe'
            })
        }
        $actualMachine = Get-PshNativePeMachine -Path $resolvedPath
        $runningOnWindows = Test-PshNativeWindowsPlatform
        if ($runningOnWindows -and [string]::IsNullOrWhiteSpace([string]$actualMachine)) {
            return [PSCustomObject]([ordered]@{
                Code = 5; Message = ('the pinned {0} executable is not a valid PE image.' -f $normalizedName); Path = $null
                Name = $normalizedName; Version = [string]$tool.version; Sha256 = [string]$artifact.installedSha256
                Architecture = $architecture; State = 'invalid'; PeMachine = $actualMachine
                VersionProbe = Get-PshNativePropertyValue $tool 'versionProbe'
            })
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$actualMachine) -and
            [string]$actualMachine -ine [string]$artifact.peMachine) {
            return [PSCustomObject]([ordered]@{
                Code = 5; Message = ('the pinned {0} executable PE machine does not match {1}.' -f $normalizedName, $architecture); Path = $null
                Name = $normalizedName; Version = [string]$tool.version; Sha256 = [string]$artifact.installedSha256
                Architecture = $architecture; State = 'wrong-architecture'; PeMachine = $actualMachine
                VersionProbe = Get-PshNativePropertyValue $tool 'versionProbe'
            })
        }
        return [PSCustomObject]([ordered]@{
            Code = 0; Message = ''; Path = $resolvedPath; Name = $normalizedName; Version = [string]$tool.version
            Sha256 = ([string]$artifact.installedSha256).ToLowerInvariant(); Architecture = $architecture
            State = 'pinned'; PeMachine = $actualMachine; VersionProbe = Get-PshNativePropertyValue $tool 'versionProbe'
        })
    }
    catch {
        $unavailable.Code = 5
        $unavailable.State = 'invalid'
        $unavailable.Message = ('cannot verify the pinned {0} tool: {1}' -f $normalizedName, $_.Exception.Message)
        return [PSCustomObject]$unavailable
    }
}

function Get-PshNativeToolStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$ModuleRoot
    )

    $resolved = Resolve-PshPinnedNativeTool -Name $Name -ModuleRoot $ModuleRoot
    $backend = if ([int]$resolved.Code -eq 0) { 'native:{0}' -f ([string]$resolved.Name) } else { 'unavailable' }
    return [PSCustomObject]([ordered]@{
        name = [string]$resolved.Name
        backend = $backend
        state = [string]$resolved.State
        version = $resolved.Version
        path = $resolved.Path
        sha256 = $resolved.Sha256
        architecture = $resolved.Architecture
        peMachine = $resolved.PeMachine
        code = [int]$resolved.Code
        message = [string]$resolved.Message
        versionProbe = $resolved.VersionProbe
    })
}
