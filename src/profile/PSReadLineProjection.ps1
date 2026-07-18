# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version 2.0

. (Join-Path -Path $PSScriptRoot -ChildPath 'ProfileBlock.ps1')

$script:PshPSReadLineProjectionVersion = '2.4.5'
$script:PshPSReadLineProjectionManifestName = 'manifest.json'
$script:PshPSReadLineProjectionComponent = 'PSReadLineProjection'

function Get-PshPSReadLineProjectionExpectedFile {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject][ordered]@{
            RelativePath = 'Microsoft.PowerShell.PSReadLine.dll'
            Length       = [long] 339528
            Sha256       = 'f8e3a5b7e3e8cad2130ce10647564a2a0ea15d98db8a0cc8d589f80154c108e2'
        }
        [pscustomobject][ordered]@{
            RelativePath = 'Microsoft.PowerShell.Pager.dll'
            Length       = [long] 16784
            Sha256       = '451994c3d3e38d939b4fa5f8594d0207840f45e7a210aa75f81aef85aa17c592'
        }
        [pscustomobject][ordered]@{
            RelativePath = 'PSReadLine.format.ps1xml'
            Length       = [long] 26820
            Sha256       = '1ca887463598d38aa18236a97a4193b2228d1d8434fa73cc8c7932f42a0565cf'
        }
        [pscustomobject][ordered]@{
            RelativePath = 'PSReadLine.psd1'
            Length       = [long] 15471
            Sha256       = 'dd8766bd4db0c1d17111b81d145d32448f61f48451d51c780a79be9ca98d837e'
        }
        [pscustomobject][ordered]@{
            RelativePath = 'PSReadLine.psm1'
            Length       = [long] 15076
            Sha256       = '9bc0252f616067ca5ef1d0328ec0b97c7d31c757f9fc80adee234ea6132a9c7e'
        }
        [pscustomobject][ordered]@{
            RelativePath = 'net6plus/Microsoft.PowerShell.PSReadLine.Polyfiller.dll'
            Length       = [long] 14920
            Sha256       = '6d33ea289b405c64bf5daa9c59e459596cac59ece399d0d215ee9f3d46afd675'
        }
        [pscustomobject][ordered]@{
            RelativePath = 'netstd/Microsoft.PowerShell.PSReadLine.Polyfiller.dll'
            Length       = [long] 16928
            Sha256       = '2e63dc86d9240243ccfb07da5d0b4fce2bc5ce5f9952658a7ce68c26bcd3e14c'
        }
    )
}

function Get-PshPSReadLineProjectionPathComparison {
    [CmdletBinding()]
    param()

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return [StringComparison]::OrdinalIgnoreCase
    }
    return [StringComparison]::Ordinal
}

function Test-PshPSReadLineProjectionPathEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Left,

        [Parameter(Mandatory = $true)]
        [string] $Right
    )

    $leftPath = Resolve-PshFullPath -Path $Left -Description 'Left projection path'
    $rightPath = Resolve-PshFullPath -Path $Right -Description 'Right projection path'
    return [string]::Equals(
        $leftPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        $rightPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        (Get-PshPSReadLineProjectionPathComparison)
    )
}

function Get-PshPSReadLineProjectionFileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($stream)
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
    return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Get-PshPSReadLineProjectionTreeHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Files
    )

    $builder = New-Object Text.StringBuilder
    foreach ($file in @($Files | Sort-Object -Property RelativePath)) {
        [void] $builder.Append([string] $file.RelativePath)
        [void] $builder.Append('|')
        [void] $builder.Append(([long] $file.Length).ToString([Globalization.CultureInfo]::InvariantCulture))
        [void] $builder.Append('|')
        [void] $builder.Append([string] $file.Sha256)
        [void] $builder.Append("`n")
    }
    $utf8 = New-Object Text.UTF8Encoding($false)
    return Get-PshSha256Hex -Bytes $utf8.GetBytes($builder.ToString())
}

function Get-PshPSReadLineProjectionTrustedFingerprint {
    [CmdletBinding()]
    param()

    $files = @(Get-PshPSReadLineProjectionExpectedFile)
    return [pscustomobject][ordered]@{
        Version    = $script:PshPSReadLineProjectionVersion
        FileCount  = $files.Count
        TreeSha256 = Get-PshPSReadLineProjectionTreeHash -Files $files
        Files      = $files
    }
}

function Assert-PshPSReadLineProjectionDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Description
    )

    if ([IO.File]::Exists($Path)) {
        throw "$Description is a file: $Path"
    }
    if (-not [IO.Directory]::Exists($Path)) {
        throw "$Description is missing: $Path"
    }
    Assert-PshNotReparsePoint -Path $Path -Description $Description
}

function Assert-PshPSReadLineProjectionDirectoryPathCreatable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Description
    )

    $cursor = Resolve-PshFullPath -Path $Path -Description $Description
    while (-not [IO.Directory]::Exists($cursor)) {
        if ([IO.File]::Exists($cursor)) {
            throw "$Description has a file where a directory is required: $cursor"
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or
            [string]::Equals($parent, $cursor, (Get-PshPSReadLineProjectionPathComparison))) {
            throw "$Description has no existing directory ancestor: $Path"
        }
        $cursor = $parent
    }
}

function Get-PshPSReadLineProjectionTreeFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter()]
        [string] $Description = 'PSReadLine projection tree'
    )

    $rootPath = Resolve-PshFullPath -Path $Root -Description $Description
    Assert-PshPSReadLineProjectionDirectory -Path $rootPath -Description $Description

    $trusted = Get-PshPSReadLineProjectionTrustedFingerprint
    $expectedRootFiles = @(
        $trusted.Files |
            Where-Object { ([string] $_.RelativePath).IndexOf('/') -lt 0 } |
            ForEach-Object { [string] $_.RelativePath }
    )
    $expectedDirectories = @('net6plus', 'netstd')

    foreach ($entry in @(Get-ChildItem -LiteralPath $rootPath -Force -ErrorAction Stop)) {
        Assert-PshNotReparsePoint -Path $entry.FullName -Description "$Description entry"
        if ($entry.PSIsContainer) {
            if ($expectedDirectories -cnotcontains [string] $entry.Name) {
                throw "$Description contains an unexpected directory: $($entry.FullName)"
            }
        }
        elseif ($expectedRootFiles -cnotcontains [string] $entry.Name) {
            throw "$Description contains an unexpected file: $($entry.FullName)"
        }
    }

    foreach ($directoryName in $expectedDirectories) {
        $directoryPath = Join-Path -Path $rootPath -ChildPath $directoryName
        Assert-PshPSReadLineProjectionDirectory -Path $directoryPath -Description "$Description directory"
        $expectedNames = @(
            $trusted.Files |
                Where-Object { ([string] $_.RelativePath).StartsWith($directoryName + '/', [StringComparison]::Ordinal) } |
                ForEach-Object { [IO.Path]::GetFileName(([string] $_.RelativePath).Replace('/', [IO.Path]::DirectorySeparatorChar)) }
        )
        foreach ($entry in @(Get-ChildItem -LiteralPath $directoryPath -Force -ErrorAction Stop)) {
            Assert-PshNotReparsePoint -Path $entry.FullName -Description "$Description entry"
            if ($entry.PSIsContainer -or $expectedNames -cnotcontains [string] $entry.Name) {
                throw "$Description contains an unexpected entry: $($entry.FullName)"
            }
        }
    }

    $actualFiles = New-Object System.Collections.Generic.List[object]
    foreach ($expectedFile in $trusted.Files) {
        $nativeRelativePath = ([string] $expectedFile.RelativePath).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $filePath = Join-Path -Path $rootPath -ChildPath $nativeRelativePath
        if (-not [IO.File]::Exists($filePath) -or [IO.Directory]::Exists($filePath)) {
            throw "$Description is missing a required file: $filePath"
        }
        Assert-PshNotReparsePoint -Path $filePath -Description "$Description file"
        $item = Get-Item -LiteralPath $filePath -Force -ErrorAction Stop
        if ([long] $item.Length -ne [long] $expectedFile.Length) {
            throw "$Description has the wrong length for $($expectedFile.RelativePath)."
        }
        $hash = Get-PshPSReadLineProjectionFileSha256 -Path $filePath
        if ($hash -cne [string] $expectedFile.Sha256) {
            throw "$Description has the wrong SHA-256 for $($expectedFile.RelativePath)."
        }
        $actualFiles.Add([pscustomobject][ordered]@{
            RelativePath = [string] $expectedFile.RelativePath
            Length       = [long] $item.Length
            Sha256       = $hash
        })
    }

    if ($actualFiles.Count -ne 7) {
        throw "$Description does not contain exactly seven trusted files."
    }
    $treeHash = Get-PshPSReadLineProjectionTreeHash -Files $actualFiles.ToArray()
    if ($treeHash -cne [string] $trusted.TreeSha256) {
        throw "$Description fingerprint differs from the trusted PSReadLine 2.4.5 fingerprint."
    }

    return [pscustomobject][ordered]@{
        Root       = $rootPath
        Version    = $script:PshPSReadLineProjectionVersion
        FileCount  = $actualFiles.Count
        TreeSha256 = $treeHash
        Files      = $actualFiles.ToArray()
    }
}

function Get-PshPSReadLineProjectionDefaultSourcePath {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable; the installed Psh version cannot be resolved.'
    }
    $installRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Psh'
    $currentPath = Join-Path -Path $installRoot -ChildPath 'current.json'
    if (-not [IO.File]::Exists($currentPath) -or [IO.Directory]::Exists($currentPath)) {
        throw "Psh current.json is missing: $currentPath"
    }
    Assert-PshNotReparsePoint -Path $currentPath -Description 'Psh current.json'
    [byte[]] $currentBytes = [IO.File]::ReadAllBytes($currentPath)
    $currentInfo = Get-PshProfileTextInfo -Bytes $currentBytes -Path $currentPath
    if ($currentInfo.PreambleLength -ne 0 -or $currentInfo.Encoding.CodePage -ne 65001) {
        throw 'Psh current.json must be UTF-8 without a byte-order mark.'
    }
    try {
        $current = $currentInfo.Text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Psh current.json is invalid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $current -or $current -is [Array]) {
        throw 'Psh current.json must be one JSON object.'
    }
    Assert-PshJsonPropertyName -InputObject $current -ExpectedNames @('schemaVersion', 'version') -Context 'Psh current.json'
    $schemaVersion = Get-PshRequiredJsonProperty -InputObject $current -Name 'schemaVersion' -Context 'Psh current.json'
    $version = Get-PshRequiredJsonProperty -InputObject $current -Name 'version' -Context 'Psh current.json'
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or $schemaVersion -ne 1) {
        throw 'Psh current.json has an unsupported schemaVersion.'
    }
    $versionPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z'
    if ($version -isnot [string] -or $version -notmatch $versionPattern) {
        throw 'Psh current.json contains an invalid version.'
    }

    $versionRoot = Join-Path -Path (Join-Path -Path $installRoot -ChildPath 'versions') -ChildPath $version
    $moduleRoot = Join-Path -Path $versionRoot -ChildPath 'Psh'
    $dependencyRoot = Join-Path -Path $moduleRoot -ChildPath 'Dependencies'
    $psReadLineRoot = Join-Path -Path $dependencyRoot -ChildPath 'PSReadLine'
    return Join-Path -Path $psReadLineRoot -ChildPath $script:PshPSReadLineProjectionVersion
}

function Resolve-PshPSReadLineProjectionSource {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string] $SourcePath
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        $SourcePath = Get-PshPSReadLineProjectionDefaultSourcePath
    }
    $resolved = Resolve-PshFullPath -Path $SourcePath -Description 'PSReadLine projection source'
    $fingerprint = Get-PshPSReadLineProjectionTreeFingerprint -Root $resolved -Description 'PSReadLine projection source'
    return [pscustomobject][ordered]@{
        Path        = $resolved
        Fingerprint = $fingerprint
    }
}

function Get-PshPSReadLineProjectionDefaultModuleRoot {
    [CmdletBinding()]
    param()

    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if ([string]::IsNullOrWhiteSpace($documents)) {
        throw 'The current user Documents directory is unavailable; PSReadLine module roots cannot be resolved.'
    }
    return @(
        (Join-Path -Path (Join-Path -Path $documents -ChildPath 'WindowsPowerShell') -ChildPath 'Modules')
        (Join-Path -Path (Join-Path -Path $documents -ChildPath 'PowerShell') -ChildPath 'Modules')
    )
}

function Resolve-PshPSReadLineProjectionModuleRoot {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string[]] $ModuleRoot,

        [Parameter(Mandatory = $true)]
        [bool] $WasSpecified
    )

    $candidates = @(if ($WasSpecified) { $ModuleRoot } else { Get-PshPSReadLineProjectionDefaultModuleRoot })
    if ($candidates.Count -eq 0) {
        throw 'At least one PSReadLine projection module root is required.'
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        if ($null -eq $candidate -or [string]::IsNullOrWhiteSpace($candidate)) {
            throw 'ModuleRoot cannot contain null, empty, or whitespace values.'
        }
        $fullPath = Resolve-PshFullPath -Path $candidate -Description 'PSReadLine module root'
        $pathRoot = [IO.Path]::GetPathRoot($fullPath)
        if ([string]::Equals($fullPath, $pathRoot, (Get-PshPSReadLineProjectionPathComparison))) {
            throw "A filesystem root cannot be used as a PSReadLine module root: $fullPath"
        }
        if (-not $seen.Add($fullPath)) {
            throw "ModuleRoot contains the same target more than once: $fullPath"
        }
        if ([IO.File]::Exists($fullPath)) {
            throw "A PSReadLine module root is a file: $fullPath"
        }
        Assert-PshPSReadLineProjectionDirectoryPathCreatable -Path $fullPath -Description 'PSReadLine module root'
        if ([IO.Directory]::Exists($fullPath)) {
            Assert-PshNotReparsePoint -Path $fullPath -Description 'A PSReadLine module root'
        }
        $resolved.Add($fullPath)
    }
    return $resolved.ToArray()
}

function Get-PshPSReadLineProjectionStateRoot {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string] $StateRoot
    )

    if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA is unavailable; PSReadLine projection state cannot be resolved.'
        }
        $StateRoot = Join-Path -Path (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Psh') -ChildPath 'psreadline-projection-state'
    }
    $resolved = Resolve-PshFullPath -Path $StateRoot -Description 'PSReadLine projection state root'
    $pathRoot = [IO.Path]::GetPathRoot($resolved)
    if ([string]::Equals($resolved, $pathRoot, (Get-PshPSReadLineProjectionPathComparison))) {
        throw "A filesystem root cannot be used as PSReadLine projection state: $resolved"
    }
    if ([IO.File]::Exists($resolved)) {
        throw "The PSReadLine projection state root is a file: $resolved"
    }
    Assert-PshPSReadLineProjectionDirectoryPathCreatable -Path $resolved -Description 'PSReadLine projection state root'
    if ([IO.Directory]::Exists($resolved)) {
        Assert-PshNotReparsePoint -Path $resolved -Description 'The PSReadLine projection state root'
    }
    return $resolved
}

function Get-PshPSReadLineProjectionStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    $manifestPath = Join-Path -Path $StateRoot -ChildPath $script:PshPSReadLineProjectionManifestName
    if (-not (Test-PshPathWithinRoot -Path $manifestPath -Root $StateRoot)) {
        throw 'The PSReadLine projection manifest escaped its state root.'
    }
    return $manifestPath
}

function Enter-PshPSReadLineProjectionLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter()]
        [ValidateRange(1, 300000)]
        [int] $TimeoutMilliseconds = 30000
    )

    $normalized = (Resolve-PshFullPath -Path $StateRoot -Description 'PSReadLine projection state root').TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ).ToUpperInvariant()
    $utf8 = New-Object Text.UTF8Encoding($false)
    $mutexName = 'Psh.PSReadLineProjection.' + (Get-PshSha256Hex -Bytes $utf8.GetBytes($normalized))
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Timed out waiting for another PSReadLine projection transaction: $StateRoot"
        }
        return [pscustomobject]@{
            Mutex    = $mutex
            Acquired = $true
            Name     = $mutexName
        }
    }
    catch {
        $lockError = $_
        if ($acquired) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        $mutex.Dispose()
        throw $lockError
    }
}

function Exit-PshPSReadLineProjectionLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Lock
    )

    try {
        if ([bool] $Lock.Acquired) {
            $Lock.Mutex.ReleaseMutex()
            $Lock.Acquired = $false
        }
    }
    finally {
        $Lock.Mutex.Dispose()
    }
}

function Get-PshPSReadLineProjectionTargetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ModuleRoot
    )

    return Join-Path -Path (Join-Path -Path $ModuleRoot -ChildPath 'PSReadLine') -ChildPath $script:PshPSReadLineProjectionVersion
}

function Get-PshPSReadLineProjectionTargetState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ModuleRoot,

        [Parameter()]
        [AllowNull()]
        [string] $AllowedStagePath
    )

    $moduleRootPath = Resolve-PshFullPath -Path $ModuleRoot -Description 'PSReadLine module root'
    if ([IO.File]::Exists($moduleRootPath)) {
        throw "The PSReadLine module root is a file: $moduleRootPath"
    }
    if ([IO.Directory]::Exists($moduleRootPath)) {
        Assert-PshNotReparsePoint -Path $moduleRootPath -Description 'The PSReadLine module root'
    }
    $containerPath = Join-Path -Path $moduleRootPath -ChildPath 'PSReadLine'
    $targetPath = Join-Path -Path $containerPath -ChildPath $script:PshPSReadLineProjectionVersion
    if ([IO.File]::Exists($containerPath)) {
        throw "An unversioned PSReadLine module occupies the projection path: $containerPath"
    }
    if (-not [IO.Directory]::Exists($containerPath)) {
        return [pscustomobject][ordered]@{
            ModuleRoot    = $moduleRootPath
            ContainerPath = $containerPath
            TargetPath    = $targetPath
            Exists        = $false
            Fingerprint   = $null
        }
    }
    Assert-PshNotReparsePoint -Path $containerPath -Description 'The PSReadLine module container'

    foreach ($entry in @(Get-ChildItem -LiteralPath $containerPath -Force -ErrorAction Stop)) {
        Assert-PshNotReparsePoint -Path $entry.FullName -Description 'A PSReadLine module-container entry'
        if (-not [string]::IsNullOrWhiteSpace($AllowedStagePath) -and
            (Test-PshPSReadLineProjectionPathEqual -Left $entry.FullName -Right $AllowedStagePath)) {
            continue
        }
        if ($entry.Name -ceq $script:PshPSReadLineProjectionVersion -and $entry.PSIsContainer) {
            continue
        }
        if (-not $entry.PSIsContainer) {
            throw "An unversioned or unexpected PSReadLine module file blocks projection: $($entry.FullName)"
        }
        $parsedVersion = $null
        if ([version]::TryParse([string] $entry.Name, [ref] $parsedVersion) -and
            $parsedVersion -gt [version] $script:PshPSReadLineProjectionVersion) {
            throw "A higher PSReadLine version blocks fixed 2.4.5 projection: $($entry.FullName)"
        }
        throw "A different or unexpected PSReadLine module directory blocks projection: $($entry.FullName)"
    }

    if ([IO.File]::Exists($targetPath)) {
        throw "The versioned PSReadLine projection target is a file: $targetPath"
    }
    if (-not [IO.Directory]::Exists($targetPath)) {
        return [pscustomobject][ordered]@{
            ModuleRoot    = $moduleRootPath
            ContainerPath = $containerPath
            TargetPath    = $targetPath
            Exists        = $false
            Fingerprint   = $null
        }
    }
    $fingerprint = Get-PshPSReadLineProjectionTreeFingerprint -Root $targetPath -Description 'Existing PSReadLine projection target'
    return [pscustomobject][ordered]@{
        ModuleRoot    = $moduleRootPath
        ContainerPath = $containerPath
        TargetPath    = $targetPath
        Exists        = $true
        Fingerprint   = $fingerprint
    }
}

function Assert-PshPSReadLineProjectionStateRootClean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    if (-not [IO.Directory]::Exists($StateRoot)) {
        return
    }
    Assert-PshNotReparsePoint -Path $StateRoot -Description 'The PSReadLine projection state root'
    $manifestPath = Get-PshPSReadLineProjectionStatePath -StateRoot $StateRoot
    foreach ($entry in @(Get-ChildItem -LiteralPath $StateRoot -Force -ErrorAction Stop)) {
        Assert-PshNotReparsePoint -Path $entry.FullName -Description 'A PSReadLine projection state entry'
        if (-not (Test-PshPSReadLineProjectionPathEqual -Left $entry.FullName -Right $manifestPath)) {
            throw "The PSReadLine projection state root contains an unexpected entry: $($entry.FullName)"
        }
        if ($entry.PSIsContainer) {
            throw "The PSReadLine projection manifest path is a directory: $($entry.FullName)"
        }
    }
}

function ConvertTo-PshPSReadLineProjectionManifestByte {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('pending', 'complete')]
        [string] $State,

        [Parameter(Mandatory = $true)]
        [ValidateSet('install', 'uninstall')]
        [string] $Operation,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('\A[0-9a-f]{32}\z')]
        [string] $TransactionId,

        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Fingerprint,

        [Parameter(Mandatory = $true)]
        [object[]] $Targets
    )

    $document = [ordered]@{
        schemaVersion = 1
        product       = 'Psh'
        component     = $script:PshPSReadLineProjectionComponent
        version       = $script:PshPSReadLineProjectionVersion
        state         = $State
        operation     = $Operation
        transactionId = $TransactionId
        sourcePath    = $SourcePath
        fileCount     = [int] $Fingerprint.FileCount
        treeSha256    = [string] $Fingerprint.TreeSha256
        files         = @(
            $Fingerprint.Files | ForEach-Object {
                [ordered]@{
                    relativePath = [string] $_.RelativePath
                    length       = [long] $_.Length
                    sha256       = [string] $_.Sha256
                }
            }
        )
        targets       = @(
            $Targets | ForEach-Object {
                [ordered]@{
                    moduleRoot         = [string] $_.ModuleRoot
                    targetPath         = [string] $_.TargetPath
                    disposition        = [string] $_.Disposition
                    createdParentPaths = @($_.CreatedParentPaths)
                }
            }
        )
    }
    $json = ($document | ConvertTo-Json -Depth 10) + "`r`n"
    $utf8 = New-Object Text.UTF8Encoding($false)
    return ,$utf8.GetBytes($json)
}

function Read-PshPSReadLineProjectionManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    Assert-PshPSReadLineProjectionStateRootClean -StateRoot $StateRoot
    $manifestPath = Get-PshPSReadLineProjectionStatePath -StateRoot $StateRoot
    if (-not [IO.File]::Exists($manifestPath)) {
        return [pscustomobject][ordered]@{
            Exists       = $false
            Bytes        = (New-Object byte[] 0)
            ManifestPath = $manifestPath
            State        = $null
            Operation    = $null
            TransactionId = $null
            SourcePath   = $null
            Fingerprint  = $null
            Targets      = @()
        }
    }
    Assert-PshNotReparsePoint -Path $manifestPath -Description 'The PSReadLine projection manifest'
    [byte[]] $bytes = [IO.File]::ReadAllBytes($manifestPath)
    $textInfo = Get-PshProfileTextInfo -Bytes $bytes -Path $manifestPath
    if ($textInfo.PreambleLength -ne 0 -or $textInfo.Encoding.CodePage -ne 65001) {
        throw 'The PSReadLine projection manifest must be UTF-8 without a byte-order mark.'
    }
    try {
        $document = $textInfo.Text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "The PSReadLine projection manifest is invalid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $document -or $document -is [Array]) {
        throw 'The PSReadLine projection manifest must be one JSON object.'
    }
    Assert-PshJsonPropertyName -InputObject $document -ExpectedNames @(
        'schemaVersion', 'product', 'component', 'version', 'state', 'operation',
        'transactionId', 'sourcePath', 'fileCount', 'treeSha256', 'files', 'targets'
    ) -Context 'The PSReadLine projection manifest'

    $schemaVersion = Get-PshRequiredJsonProperty -InputObject $document -Name 'schemaVersion' -Context 'The PSReadLine projection manifest'
    $product = Get-PshRequiredJsonProperty -InputObject $document -Name 'product' -Context 'The PSReadLine projection manifest'
    $component = Get-PshRequiredJsonProperty -InputObject $document -Name 'component' -Context 'The PSReadLine projection manifest'
    $version = Get-PshRequiredJsonProperty -InputObject $document -Name 'version' -Context 'The PSReadLine projection manifest'
    $state = Get-PshRequiredJsonProperty -InputObject $document -Name 'state' -Context 'The PSReadLine projection manifest'
    $operation = Get-PshRequiredJsonProperty -InputObject $document -Name 'operation' -Context 'The PSReadLine projection manifest'
    $transactionId = Get-PshRequiredJsonProperty -InputObject $document -Name 'transactionId' -Context 'The PSReadLine projection manifest'
    $sourcePath = Get-PshRequiredJsonProperty -InputObject $document -Name 'sourcePath' -Context 'The PSReadLine projection manifest'
    $fileCount = Get-PshRequiredJsonProperty -InputObject $document -Name 'fileCount' -Context 'The PSReadLine projection manifest'
    $treeSha256 = Get-PshRequiredJsonProperty -InputObject $document -Name 'treeSha256' -Context 'The PSReadLine projection manifest'
    $files = @(Get-PshRequiredJsonProperty -InputObject $document -Name 'files' -Context 'The PSReadLine projection manifest')
    $targets = @(Get-PshRequiredJsonProperty -InputObject $document -Name 'targets' -Context 'The PSReadLine projection manifest')

    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or $schemaVersion -ne 1 -or
        $product -isnot [string] -or $product -cne 'Psh' -or
        $component -isnot [string] -or $component -cne $script:PshPSReadLineProjectionComponent -or
        $version -isnot [string] -or $version -cne $script:PshPSReadLineProjectionVersion) {
        throw 'The PSReadLine projection manifest identity is invalid.'
    }
    if ($state -isnot [string] -or @('pending', 'complete') -cnotcontains $state -or
        $operation -isnot [string] -or @('install', 'uninstall') -cnotcontains $operation -or
        ($state -ceq 'complete' -and $operation -cne 'install')) {
        throw 'The PSReadLine projection manifest transaction state is invalid.'
    }
    if ($transactionId -isnot [string] -or $transactionId -cnotmatch '\A[0-9a-f]{32}\z') {
        throw 'The PSReadLine projection manifest transactionId is invalid.'
    }
    if ($sourcePath -isnot [string]) {
        throw 'The PSReadLine projection manifest sourcePath is invalid.'
    }
    $normalizedSource = Resolve-PshFullPath -Path $sourcePath -Description 'Projection manifest source path'
    if ($sourcePath -cne $normalizedSource) {
        throw 'The PSReadLine projection manifest sourcePath is not normalized.'
    }

    $trusted = Get-PshPSReadLineProjectionTrustedFingerprint
    if (($fileCount -isnot [int] -and $fileCount -isnot [long]) -or [int] $fileCount -ne 7 -or
        $treeSha256 -isnot [string] -or $treeSha256 -cne [string] $trusted.TreeSha256 -or
        $files.Count -ne 7) {
        throw 'The PSReadLine projection manifest fingerprint summary is invalid.'
    }
    $validatedFiles = New-Object System.Collections.Generic.List[object]
    $expectedByPath = @{}
    foreach ($expectedFile in $trusted.Files) {
        $expectedByPath[[string] $expectedFile.RelativePath] = $expectedFile
    }
    $seenFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($file in $files) {
        if ($null -eq $file -or $file -is [Array]) {
            throw 'The PSReadLine projection manifest contains an invalid file entry.'
        }
        Assert-PshJsonPropertyName -InputObject $file -ExpectedNames @('relativePath', 'length', 'sha256') -Context 'A projection file entry'
        $relativePath = Get-PshRequiredJsonProperty -InputObject $file -Name 'relativePath' -Context 'A projection file entry'
        $length = Get-PshRequiredJsonProperty -InputObject $file -Name 'length' -Context 'A projection file entry'
        $sha256 = Get-PshRequiredJsonProperty -InputObject $file -Name 'sha256' -Context 'A projection file entry'
        if ($relativePath -isnot [string] -or -not $expectedByPath.ContainsKey($relativePath) -or -not $seenFiles.Add($relativePath)) {
            throw 'The PSReadLine projection manifest contains an unexpected or duplicate file path.'
        }
        $expected = $expectedByPath[$relativePath]
        if (($length -isnot [int] -and $length -isnot [long]) -or [long] $length -ne [long] $expected.Length -or
            $sha256 -isnot [string] -or $sha256 -cne [string] $expected.Sha256) {
            throw "The PSReadLine projection manifest file fingerprint is invalid: $relativePath"
        }
        $validatedFiles.Add([pscustomobject][ordered]@{
            RelativePath = $relativePath
            Length       = [long] $length
            Sha256       = $sha256
        })
    }
    if ((Get-PshPSReadLineProjectionTreeHash -Files $validatedFiles.ToArray()) -cne [string] $trusted.TreeSha256) {
        throw 'The PSReadLine projection manifest file tree hash is invalid.'
    }

    if ($targets.Count -eq 0) {
        throw 'The PSReadLine projection manifest contains no targets.'
    }
    $seenRoots = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $validatedTargets = New-Object System.Collections.Generic.List[object]
    foreach ($target in $targets) {
        if ($null -eq $target -or $target -is [Array]) {
            throw 'The PSReadLine projection manifest contains an invalid target entry.'
        }
        Assert-PshJsonPropertyName -InputObject $target -ExpectedNames @(
            'moduleRoot', 'targetPath', 'disposition', 'createdParentPaths'
        ) -Context 'A projection target entry'
        $moduleRoot = Get-PshRequiredJsonProperty -InputObject $target -Name 'moduleRoot' -Context 'A projection target entry'
        $targetPath = Get-PshRequiredJsonProperty -InputObject $target -Name 'targetPath' -Context 'A projection target entry'
        $disposition = Get-PshRequiredJsonProperty -InputObject $target -Name 'disposition' -Context 'A projection target entry'
        $createdParentPaths = @(Get-PshRequiredJsonProperty -InputObject $target -Name 'createdParentPaths' -Context 'A projection target entry')
        if ($moduleRoot -isnot [string] -or $targetPath -isnot [string]) {
            throw 'A PSReadLine projection manifest target path is invalid.'
        }
        $normalizedRoot = Resolve-PshFullPath -Path $moduleRoot -Description 'Projection manifest module root'
        $normalizedTarget = Resolve-PshFullPath -Path $targetPath -Description 'Projection manifest target path'
        if ($moduleRoot -cne $normalizedRoot -or $targetPath -cne $normalizedTarget -or
            -not (Test-PshPSReadLineProjectionPathEqual -Left $normalizedTarget -Right (Get-PshPSReadLineProjectionTargetPath -ModuleRoot $normalizedRoot)) -or
            -not $seenRoots.Add($normalizedRoot)) {
            throw 'A PSReadLine projection manifest target path is non-canonical or duplicated.'
        }
        if ($disposition -isnot [string] -or @('created', 'reused') -cnotcontains $disposition) {
            throw 'A PSReadLine projection manifest disposition is invalid.'
        }
        $allowedParentPaths = @(
            $normalizedRoot
            (Join-Path -Path $normalizedRoot -ChildPath 'PSReadLine')
        )
        $seenParents = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $validatedParents = New-Object System.Collections.Generic.List[string]
        foreach ($parentPath in $createdParentPaths) {
            if ($parentPath -isnot [string]) {
                throw 'A PSReadLine projection manifest created-parent path is invalid.'
            }
            $normalizedParent = Resolve-PshFullPath -Path $parentPath -Description 'Projection created-parent path'
            $isAllowed = $false
            foreach ($allowedParent in $allowedParentPaths) {
                if (Test-PshPSReadLineProjectionPathEqual -Left $normalizedParent -Right $allowedParent) {
                    $isAllowed = $true
                    break
                }
            }
            if (-not $isAllowed -or -not $seenParents.Add($normalizedParent)) {
                throw 'A PSReadLine projection manifest created-parent path is unsafe or duplicated.'
            }
            $validatedParents.Add($normalizedParent)
        }
        if ($disposition -ceq 'reused' -and $validatedParents.Count -ne 0) {
            throw 'A reused PSReadLine projection target cannot own parent directories.'
        }
        $validatedTargets.Add([pscustomobject][ordered]@{
            ModuleRoot         = $normalizedRoot
            TargetPath         = $normalizedTarget
            Disposition        = $disposition
            CreatedParentPaths = $validatedParents.ToArray()
        })
    }
    Assert-PshPSReadLineProjectionTargetsIndependent -Targets $validatedTargets.ToArray()

    return [pscustomobject][ordered]@{
        Exists        = $true
        Bytes         = $bytes
        ManifestPath  = $manifestPath
        State         = $state
        Operation     = $operation
        TransactionId = $transactionId
        SourcePath    = $normalizedSource
        Fingerprint   = [pscustomobject][ordered]@{
            Version    = $script:PshPSReadLineProjectionVersion
            FileCount  = 7
            TreeSha256 = [string] $trusted.TreeSha256
            Files      = $validatedFiles.ToArray()
        }
        Targets       = $validatedTargets.ToArray()
    }
}

function Test-PshPSReadLineProjectionTargetSetEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $ModuleRoots,

        [Parameter(Mandatory = $true)]
        [object[]] $Targets
    )

    if ($ModuleRoots.Count -ne $Targets.Count) {
        return $false
    }
    foreach ($moduleRoot in $ModuleRoots) {
        $matched = @($Targets | Where-Object {
            Test-PshPSReadLineProjectionPathEqual -Left ([string] $_.ModuleRoot) -Right $moduleRoot
        })
        if ($matched.Count -ne 1) {
            return $false
        }
    }
    return $true
}

function Assert-PshPSReadLineProjectionTargetsIndependent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Targets
    )

    for ($leftIndex = 0; $leftIndex -lt $Targets.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $Targets.Count; $rightIndex++) {
            $leftPath = [string] $Targets[$leftIndex].TargetPath
            $rightPath = [string] $Targets[$rightIndex].TargetPath
            if ((Test-PshPathWithinRoot -Path $leftPath -Root $rightPath) -or
                (Test-PshPathWithinRoot -Path $rightPath -Root $leftPath)) {
                throw "PSReadLine projection targets overlap: '$leftPath' and '$rightPath'."
            }
        }
    }
}

function Copy-PshPSReadLineProjectionTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $SourceFingerprint,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($directoryName in @('net6plus', 'netstd')) {
        [IO.Directory]::CreateDirectory((Join-Path -Path $Destination -ChildPath $directoryName)) | Out-Null
    }
    foreach ($file in $SourceFingerprint.Files) {
        $nativeRelativePath = ([string] $file.RelativePath).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $sourcePath = Join-Path -Path $SourceFingerprint.Root -ChildPath $nativeRelativePath
        $destinationPath = Join-Path -Path $Destination -ChildPath $nativeRelativePath
        [IO.File]::Copy($sourcePath, $destinationPath, $false)
    }
}

function Remove-PshPSReadLineProjectionPartialStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not [IO.Directory]::Exists($Path)) {
        return
    }
    Assert-PshNotReparsePoint -Path $Path -Description 'A PSReadLine projection stage'
    $trusted = Get-PshPSReadLineProjectionTrustedFingerprint
    foreach ($file in @($trusted.Files | Sort-Object -Property { ([string] $_.RelativePath).Length } -Descending)) {
        $filePath = Join-Path -Path $Path -ChildPath (([string] $file.RelativePath).Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ([IO.File]::Exists($filePath)) {
            Assert-PshNotReparsePoint -Path $filePath -Description 'A staged PSReadLine file'
            $item = Get-Item -LiteralPath $filePath -Force -ErrorAction Stop
            if ([long] $item.Length -ne [long] $file.Length -or
                (Get-PshPSReadLineProjectionFileSha256 -Path $filePath) -cne [string] $file.Sha256) {
                throw "A staged PSReadLine file changed and was retained: $filePath"
            }
            [IO.File]::Delete($filePath)
        }
    }
    foreach ($directoryName in @('net6plus', 'netstd')) {
        $directoryPath = Join-Path -Path $Path -ChildPath $directoryName
        if ([IO.Directory]::Exists($directoryPath) -and @(Get-ChildItem -LiteralPath $directoryPath -Force).Count -eq 0) {
            [IO.Directory]::Delete($directoryPath, $false)
        }
    }
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -ne 0) {
        throw "A PSReadLine projection stage contains unexpected content and was retained: $Path"
    }
    [IO.Directory]::Delete($Path, $false)
}

function New-PshPSReadLineProjectionTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Plan,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $SourceFingerprint
    )

    if (-not [IO.Directory]::Exists($Plan.ModuleRoot)) {
        [IO.Directory]::CreateDirectory($Plan.ModuleRoot) | Out-Null
    }
    Assert-PshNotReparsePoint -Path $Plan.ModuleRoot -Description 'The PSReadLine module root'
    $containerPath = Join-Path -Path $Plan.ModuleRoot -ChildPath 'PSReadLine'
    if (-not [IO.Directory]::Exists($containerPath)) {
        [IO.Directory]::CreateDirectory($containerPath) | Out-Null
    }
    Assert-PshNotReparsePoint -Path $containerPath -Description 'The PSReadLine module container'
    $initialState = Get-PshPSReadLineProjectionTargetState -ModuleRoot $Plan.ModuleRoot
    if ($initialState.Exists) {
        throw "The PSReadLine projection target appeared after preflight: $($Plan.TargetPath)"
    }

    $stagePath = Join-Path -Path $containerPath -ChildPath ('.psh-psreadline.{0}.stage' -f ([Guid]::NewGuid()).ToString('N'))
    try {
        Copy-PshPSReadLineProjectionTree -SourceFingerprint $SourceFingerprint -Destination $stagePath
        $null = Get-PshPSReadLineProjectionTreeFingerprint -Root $stagePath -Description 'Staged PSReadLine projection'
        $preCommitState = Get-PshPSReadLineProjectionTargetState -ModuleRoot $Plan.ModuleRoot -AllowedStagePath $stagePath
        if ($preCommitState.Exists) {
            throw "The PSReadLine projection target appeared at the commit point: $($Plan.TargetPath)"
        }
        [IO.Directory]::Move($stagePath, $Plan.TargetPath)
        $stagePath = $null
        return Get-PshPSReadLineProjectionTreeFingerprint -Root $Plan.TargetPath -Description 'Committed PSReadLine projection'
    }
    finally {
        if ($null -ne $stagePath -and [IO.Directory]::Exists($stagePath)) {
            Remove-PshPSReadLineProjectionPartialStage -Path $stagePath
        }
    }
}

function Move-PshPSReadLineProjectionToQuarantine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $TargetPath
    )

    $fingerprint = Get-PshPSReadLineProjectionTreeFingerprint -Root $TargetPath -Description 'PSReadLine projection removal target'
    $parent = [IO.Path]::GetDirectoryName($TargetPath)
    $quarantine = Join-Path -Path $parent -ChildPath ('.psh-psreadline.{0}.removed' -f ([Guid]::NewGuid()).ToString('N'))
    [IO.Directory]::Move($TargetPath, $quarantine)
    try {
        $movedFingerprint = Get-PshPSReadLineProjectionTreeFingerprint -Root $quarantine -Description 'Quarantined PSReadLine projection'
        if ($movedFingerprint.TreeSha256 -cne $fingerprint.TreeSha256) {
            throw 'The quarantined PSReadLine projection fingerprint changed.'
        }
    }
    catch {
        $moveError = $_
        if (-not [IO.Directory]::Exists($TargetPath) -and [IO.Directory]::Exists($quarantine)) {
            try {
                [IO.Directory]::Move($quarantine, $TargetPath)
                $quarantine = $null
            }
            catch {
                throw "PSReadLine projection quarantine verification failed and rollback failed. Recovery remains at '$quarantine'. Original error: $($moveError.Exception.Message). Rollback error: $($_.Exception.Message)"
            }
        }
        throw $moveError
    }
    return $quarantine
}

function Restore-PshPSReadLineProjectionQuarantine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $QuarantinePath,

        [Parameter(Mandatory = $true)]
        [string] $TargetPath
    )

    $null = Get-PshPSReadLineProjectionTreeFingerprint -Root $QuarantinePath -Description 'PSReadLine projection rollback image'
    if ([IO.File]::Exists($TargetPath) -or [IO.Directory]::Exists($TargetPath)) {
        throw "The PSReadLine projection rollback target is occupied: $TargetPath"
    }
    [IO.Directory]::Move($QuarantinePath, $TargetPath)
    $null = Get-PshPSReadLineProjectionTreeFingerprint -Root $TargetPath -Description 'Restored PSReadLine projection'
}

function Remove-PshPSReadLineProjectionExactTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $null = Get-PshPSReadLineProjectionTreeFingerprint -Root $Path -Description 'Psh-owned PSReadLine cleanup tree'
    Remove-PshPSReadLineProjectionPartialStage -Path $Path
}

function Remove-PshPSReadLineProjectionEmptyParent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Paths
    )

    foreach ($path in @($Paths | Sort-Object -Property Length -Descending)) {
        if (-not [IO.Directory]::Exists($path)) {
            continue
        }
        Assert-PshNotReparsePoint -Path $path -Description 'A Psh-created projection parent'
        if (@(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop).Count -eq 0) {
            [IO.Directory]::Delete($path, $false)
        }
    }
}

function New-PshPSReadLineProjectionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $ModuleRoot,

        [Parameter(Mandatory = $true)]
        [string] $TargetPath,

        [Parameter(Mandatory = $true)]
        [string] $Disposition,

        [Parameter(Mandatory = $true)]
        [string] $Status,

        [Parameter(Mandatory = $true)]
        [bool] $Owned,

        [Parameter(Mandatory = $true)]
        [bool] $Changed,

        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter(Mandatory = $true)]
        [string] $ManifestPath,

        [Parameter()]
        [AllowNull()]
        [string] $ManifestState
    )

    $trusted = Get-PshPSReadLineProjectionTrustedFingerprint
    return [pscustomobject][ordered]@{
        SourcePath    = $SourcePath
        ModuleRoot    = $ModuleRoot
        TargetPath    = $TargetPath
        Version       = $script:PshPSReadLineProjectionVersion
        Disposition   = $Disposition
        Status        = $Status
        Owned         = $Owned
        Changed       = $Changed
        FileCount     = [int] $trusted.FileCount
        TreeSha256    = [string] $trusted.TreeSha256
        StateRoot     = $StateRoot
        ManifestPath  = $ManifestPath
        ManifestState = $ManifestState
    }
}
