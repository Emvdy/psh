# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [string] $Edition = 'Core',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Version = 'latest',

    [Parameter()]
    [switch] $NonInteractive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:PshOfflinePolicyRemediation = 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
$script:PshOfflineEntryPath = [IO.Path]::GetFullPath([string]$MyInvocation.MyCommand.Path)
$script:PshOfflineWasDotSourced = $MyInvocation.InvocationName -ceq '.'
$script:PshOfflineHelperLoadError = $null

function Throw-PshOfflineEntryError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $ErrorId,
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter()][string] $Kind = 'Runtime',
        [Parameter()][AllowNull()][Exception] $InnerException,
        [Parameter()][string] $Remediation
    )

    $exception = if ($null -eq $InnerException) {
        New-Object System.Exception($Message)
    }
    else {
        New-Object System.Exception($Message, $InnerException)
    }
    $exception.Data['PshExitCode'] = $ExitCode
    $exception.Data['PshErrorKind'] = $Kind
    $exception.Data['PshErrorId'] = $ErrorId
    if (-not [string]::IsNullOrWhiteSpace($Remediation)) {
        $exception.Data['PshRemediation'] = $Remediation
    }
    throw $exception
}

function Resolve-PshOfflineSupportScript {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Name)

    foreach ($candidate in @(
            (Join-Path $PSScriptRoot $Name),
            (Join-Path (Join-Path $PSScriptRoot 'payload/install') $Name)
        )) {
        if ([IO.File]::Exists($candidate)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    Throw-PshOfflineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshOfflineSupportMissing' -Message "Required offline installer support file was not found: $Name"
}

try {
    foreach ($supportName in @('PackageLifecycle.ps1', 'ReleaseTrust.ps1')) {
        . (Resolve-PshOfflineSupportScript -Name $supportName)
    }
}
catch { $script:PshOfflineHelperLoadError = $_ }

function Test-PshOfflineWindows {
    [CmdletBinding()]
    param()

    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Assert-PshOfflineEdition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Value)

    if ($Value -cnotin @('Core', 'Full')) {
        Throw-PshOfflineEntryError -ExitCode 2 -Kind 'Usage' -ErrorId 'PshOfflineEdition' -Message 'Edition must be Core or Full.'
    }
}

function Assert-PshOfflineExecutionPolicy {
    [CmdletBinding()]
    param()

    if (-not (Test-PshOfflineWindows)) { return }
    try { $effectivePolicy = [string](Get-ExecutionPolicy -ErrorAction Stop) }
    catch {
        Throw-PshOfflineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicyProbe' -Message 'Unable to determine the effective PowerShell execution policy.' -InnerException $_.Exception -Remediation $script:PshOfflinePolicyRemediation
    }
    if ($effectivePolicy -in @('Restricted', 'AllSigned')) {
        Throw-PshOfflineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicy' -Message "PowerShell execution policy '$effectivePolicy' does not allow this installer workflow." -Remediation $script:PshOfflinePolicyRemediation
    }
    if ($effectivePolicy -ine 'RemoteSigned') { return }

    try {
        $streams = @(Get-Item -LiteralPath $script:PshOfflineEntryPath -Stream * -ErrorAction Stop)
        $zoneStreams = @($streams | Where-Object { [string]$_.Stream -ceq 'Zone.Identifier' })
        if ($zoneStreams.Count -gt 1) {
            Throw-PshOfflineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicyProbe' -Message 'Multiple Zone.Identifier streams were found on the installer.' -Remediation $script:PshOfflinePolicyRemediation
        }
        if ($zoneStreams.Count -eq 0) { return }
        $zoneText = [string](Get-Content -LiteralPath $script:PshOfflineEntryPath -Stream 'Zone.Identifier' -Raw -ErrorAction Stop)
        $matches = [regex]::Matches($zoneText, '(?im)^\s*ZoneId\s*=\s*([0-9]+)\s*$')
        if ($matches.Count -ne 1) {
            Throw-PshOfflineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicyProbe' -Message 'Zone.Identifier is malformed and cannot be evaluated safely.' -Remediation $script:PshOfflinePolicyRemediation
        }
        $zoneId = [int]$matches[0].Groups[1].Value
        if ($zoneId -lt 0 -or $zoneId -gt 4) {
            Throw-PshOfflineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicyProbe' -Message 'Zone.Identifier contains an unknown zone.' -Remediation $script:PshOfflinePolicyRemediation
        }
        if ($zoneId -ge 3) {
            Throw-PshOfflineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicy' -Message 'RemoteSigned does not allow an unapproved Internet-zone installer script.' -Remediation $script:PshOfflinePolicyRemediation
        }
    }
    catch {
        if ($_.Exception.Data.Contains('PshExitCode')) { throw }
        Throw-PshOfflineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicyProbe' -Message 'Unable to inspect installer Mark-of-the-Web metadata.' -InnerException $_.Exception -Remediation $script:PshOfflinePolicyRemediation
    }
}

function Get-PshOfflinePathComparison {
    [CmdletBinding()]
    param()

    if (Test-PshOfflineWindows) { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Get-PshOfflineRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, (Get-PshOfflinePathComparison))) {
        Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflinePathEscape' -Message "Package path escapes its root: $Path"
    }
    return $fullPath.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar, '/').Replace([IO.Path]::AltDirectorySeparatorChar, '/')
}

function Resolve-PshOfflineChildPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )

    $relative = Assert-PshLifecycleRelativePath -Value $RelativePath -Description 'Trusted package relative path'
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $fullRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    if (-not $candidate.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, (Get-PshOfflinePathComparison))) {
        Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflinePathEscape' -Message "Trusted package path escapes its root: $relative"
    }
    return $candidate
}

function Assert-PshOfflineSourceSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter(Mandatory = $true)][object] $Manifest
    )

    $root = [IO.Path]::GetFullPath($PackageRoot)
    if (-not [IO.Directory]::Exists($root)) {
        Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflinePackageRoot' -Message "Offline package root was not found: $root"
    }
    [void](Assert-PshLifecycleNoReparseAncestors -Path $root -Description 'offline package root')
    $expected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$expected.Add('package.manifest.json')
    [void]$expected.Add('package.manifest.cat')
    foreach ($file in @($Manifest.files)) {
        if ([string]$file.relativePath -ieq 'package.manifest.cat') {
            Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineManifestSidecarListed' -Message 'package.manifest.cat must remain outside the manifest files and tree digest.'
        }
        [void]$expected.Add([string]$file.relativePath)
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $directory = [string]$stack.Pop()
        foreach ($entry in [IO.Directory]::GetFileSystemEntries($directory)) {
            $attributes = [IO.File]::GetAttributes($entry)
            $relative = Get-PshOfflineRelativePath -Root $root -Path $entry
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineReparsePoint' -Message "Offline package contains a reparse point: $relative"
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $stack.Push($entry)
                continue
            }
            if (-not $expected.Contains($relative)) {
                Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineUnexpectedFile' -Message "Offline package contains an unlisted file: $relative"
            }
            if (-not $seen.Add($relative)) {
                Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineDuplicateFile' -Message "Offline package contains a duplicate path: $relative"
            }
        }
    }
    foreach ($relative in $expected) {
        if (-not $seen.Contains($relative)) {
            Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineMissingFile' -Message "Offline package is missing a required file: $relative"
        }
    }
}

function New-PshOfflineOwnedRoot {
    [CmdletBinding()]
    param()

    $root = Join-Path ([IO.Path]::GetTempPath()) ('psh-offline-entry-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    return [pscustomobject][ordered]@{
        Root = [IO.Path]::GetFullPath($root)
        Files = New-Object System.Collections.Generic.List[string]
        Directories = New-Object System.Collections.Generic.List[string]
    }
}

function Add-PshOfflineOwnedDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Context,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $root = [IO.Path]::GetFullPath([string]$Context.Root)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals($full, $root, (Get-PshOfflinePathComparison)) -and
        -not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, (Get-PshOfflinePathComparison))) {
        Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineTempEscape' -Message "Temporary path escapes its owned root: $full"
    }
    $relative = if ([string]::Equals($full, $root, (Get-PshOfflinePathComparison))) { '' } else { Get-PshOfflineRelativePath -Root $root -Path $full }
    $current = $root
    foreach ($segment in @($relative -split '/' | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
        $current = Join-Path $current $segment
        if ([IO.File]::Exists($current)) {
            Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineTempConflict' -Message "Temporary directory path is a file: $current"
        }
        if (-not [IO.Directory]::Exists($current)) {
            [IO.Directory]::CreateDirectory($current) | Out-Null
            [void]$Context.Directories.Add([IO.Path]::GetFullPath($current))
        }
        elseif (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineTempConflict' -Message "Temporary directory is a reparse point: $current"
        }
    }
}

function Copy-PshOfflineTrustedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Context,
        [Parameter(Mandatory = $true)][string] $SourcePath,
        [Parameter(Mandatory = $true)][string] $DestinationPath,
        [Parameter(Mandatory = $true)][int64] $ExpectedLength,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256
    )

    $source = Assert-PshLifecycleNoReparseAncestors -Path $SourcePath -Description 'trusted package source file'
    $sourceAttributes = [IO.File]::GetAttributes($source)
    if (($sourceAttributes -band [IO.FileAttributes]::Directory) -ne 0 -or ($sourceAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineSourceFile' -Message "Trusted package source is not a regular file: $source"
    }
    Add-PshOfflineOwnedDirectory -Context $Context -Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($DestinationPath)))
    $input = $null
    $output = $null
    $sha = $null
    try {
        $input = New-Object IO.FileStream($source, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
        $output = New-Object IO.FileStream($DestinationPath, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None))
        [void]$Context.Files.Add([IO.Path]::GetFullPath($DestinationPath))
        $sha = [Security.Cryptography.SHA256]::Create()
        $buffer = New-Object byte[] 65536
        [int64]$length = 0
        while ($true) {
            $read = $input.Read($buffer, 0, $buffer.Length)
            if ($read -eq 0) { break }
            $output.Write($buffer, 0, $read)
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
            $length += [int64]$read
            if ($length -gt $ExpectedLength) {
                Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineFileLength' -Message "Trusted package file is longer than its manifest: $source"
            }
        }
        $empty = New-Object byte[] 0
        [void]$sha.TransformFinalBlock($empty, 0, 0)
        try { $output.Flush($true) } catch { $output.Flush() }
        $actualSha256 = ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
        if ($length -ne $ExpectedLength -or $actualSha256 -cne $ExpectedSha256) {
            Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineFileHash' -Message "Trusted package file does not match its manifest: $source"
        }
    }
    catch {
        if ($_.Exception.Data.Contains('PshExitCode')) { throw }
        Throw-PshOfflineEntryError -ExitCode 3 -Kind 'Io' -ErrorId 'PshOfflineFileCopy' -Message "Unable to materialize trusted package file: $source" -InnerException $_.Exception
    }
    finally {
        if ($null -ne $output) { try { $output.Dispose() } catch { } }
        if ($null -ne $input) { try { $input.Dispose() } catch { } }
        if ($null -ne $sha) { try { $sha.Dispose() } catch { } }
    }
}

function New-PshOfflineInstallView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Context,
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter(Mandatory = $true)][object] $TrustedPackage
    )

    $record = Assert-PshTrustedPackageManifest -InputObject $TrustedPackage
    $manifest = $record.Manifest
    Assert-PshOfflineSourceSet -PackageRoot $PackageRoot -Manifest $manifest
    $viewRoot = Join-Path ([string]$Context.Root) 'package'
    Add-PshOfflineOwnedDirectory -Context $Context -Path $viewRoot
    Copy-PshOfflineTrustedFile -Context $Context -SourcePath (Join-Path $PackageRoot 'package.manifest.json') -DestinationPath (Join-Path $viewRoot 'package.manifest.json') -ExpectedLength ([int64]$record.ManifestLength) -ExpectedSha256 ([string]$record.ManifestSha256)
    foreach ($file in @($manifest.files)) {
        $relative = [string]$file.relativePath
        Copy-PshOfflineTrustedFile -Context $Context -SourcePath (Resolve-PshOfflineChildPath -Root $PackageRoot -RelativePath $relative) -DestinationPath (Resolve-PshOfflineChildPath -Root $viewRoot -RelativePath $relative) -ExpectedLength ([int64]$file.length) -ExpectedSha256 ([string]$file.sha256)
    }
    return $viewRoot
}

function Remove-PshOfflineOwnedRoot {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object] $Context)

    if ($null -eq $Context) { return }
    foreach ($file in @($Context.Files.ToArray()) | Sort-Object { $_.Length } -Descending) {
        try {
            if ([IO.File]::Exists($file) -and ([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                [IO.File]::Delete($file)
            }
        }
        catch { }
    }
    $directories = @($Context.Directories.ToArray()) + @([string]$Context.Root)
    foreach ($directory in @($directories | Sort-Object { $_.Length } -Descending -Unique)) {
        try {
            if ([IO.Directory]::Exists($directory) -and ([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
                [IO.Directory]::GetFileSystemEntries($directory).Count -eq 0) {
                [IO.Directory]::Delete($directory, $false)
            }
        }
        catch { }
    }
}

function Invoke-PshOfflineInstall {
    [CmdletBinding()]
    param(
        [Parameter()][string] $Edition = 'Core',
        [Parameter()][ValidateNotNullOrEmpty()][string] $Version = 'latest',
        [Parameter()][switch] $NonInteractive,
        [Parameter()][ValidatePattern('\A[0-9a-fA-F]{64}\z')][string] $ArchiveSha256
    )

    if ($null -ne $script:PshOfflineHelperLoadError) { throw $script:PshOfflineHelperLoadError }
    Assert-PshOfflineEdition -Value $Edition
    Assert-PshOfflineExecutionPolicy
    $packageRoot = [IO.Path]::GetFullPath($PSScriptRoot)
    $manifestPath = Join-Path $packageRoot 'package.manifest.json'
    $catalogPath = Join-Path $packageRoot 'package.manifest.cat'
    if (-not [IO.File]::Exists($manifestPath) -or -not [IO.File]::Exists($catalogPath)) {
        Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineTrustAssetsMissing' -Message 'Offline package must contain package.manifest.json and package.manifest.cat at its root.'
    }
    $trustedPackage = Confirm-PshPackageManifestTrust -ManifestPath $manifestPath -CatalogPath $catalogPath -Offline
    $record = Assert-PshTrustedPackageManifest -InputObject $trustedPackage
    $manifest = $record.Manifest
    if ([string]$manifest.edition -cne $Edition) {
        Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineEditionMismatch' -Message "Requested edition '$Edition' does not match package edition '$($manifest.edition)'."
    }
    if ($Version -ine 'latest') {
        $requestedVersion = Assert-PshLifecycleSemVer -Value $Version -Description 'Requested offline version'
        if ($requestedVersion -cne [string]$manifest.version) {
            Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineVersionMismatch' -Message "Requested version '$requestedVersion' does not match package version '$($manifest.version)'."
        }
    }

    $context = $null
    try {
        $context = New-PshOfflineOwnedRoot
        $installView = New-PshOfflineInstallView -Context $context -PackageRoot $packageRoot -TrustedPackage $trustedPackage
        $installerPath = Resolve-PshOfflineChildPath -Root $installView -RelativePath 'payload/install/Install-PshPackage.ps1'
        if (-not [IO.File]::Exists($installerPath)) {
            Throw-PshOfflineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOfflineInstallerMissing' -Message 'Trusted package does not contain payload/install/Install-PshPackage.ps1.'
        }
        $arguments = @{
            PackageRoot = $installView
            Edition = $Edition
            Version = [string]$manifest.version
            Offline = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($ArchiveSha256)) { $arguments['ArchiveSha256'] = $ArchiveSha256 }
        if ($NonInteractive) { $arguments['Confirm'] = $false }
        return & $installerPath @arguments
    }
    finally {
        Remove-PshOfflineOwnedRoot -Context $context
    }
}

function Write-PshOfflineFailureEnvelope {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $ErrorRecord)

    $exception = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    $metadataCommand = Get-Command -Name Get-PshLifecycleErrorMetadata -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $metadataCommand) {
        $metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $ErrorRecord
    }
    else {
        $metadataException = $exception
        while ($null -ne $metadataException -and $metadataException -is [Exception] -and $null -ne $metadataException.InnerException -and -not $metadataException.Data.Contains('PshExitCode')) { $metadataException = $metadataException.InnerException }
        $metadata = [pscustomobject][ordered]@{
            ExitCode = if ($null -ne $metadataException -and $metadataException.Data.Contains('PshExitCode')) { [int]$metadataException.Data['PshExitCode'] } else { 3 }
            Kind = if ($null -ne $metadataException -and $metadataException.Data.Contains('PshErrorKind')) { [string]$metadataException.Data['PshErrorKind'] } else { 'Runtime' }
            ErrorId = if ($null -ne $metadataException -and $metadataException.Data.Contains('PshErrorId')) { [string]$metadataException.Data['PshErrorId'] } else { 'PshOfflineEntry' }
            Message = if ($null -ne $metadataException) { [string]$metadataException.Message } else { [string]$ErrorRecord }
        }
    }
    $remediation = $null
    while ($null -ne $exception -and $exception -is [Exception]) {
        if ($exception.Data.Contains('PshRemediation')) { $remediation = [string]$exception.Data['PshRemediation']; break }
        $exception = $exception.InnerException
    }
    $envelope = [pscustomobject][ordered]@{
        schemaVersion = 1
        code = [string]$metadata.ErrorId
        exitCode = [int]$metadata.ExitCode
        kind = [string]$metadata.Kind
        message = [string]$metadata.Message
        remediation = $remediation
    }
    [Console]::Error.WriteLine(($envelope | ConvertTo-Json -Compress))
    return [int]$metadata.ExitCode
}

if (-not $script:PshOfflineWasDotSourced) {
    try {
        Invoke-PshOfflineInstall -Edition $Edition -Version $Version -NonInteractive:$NonInteractive
        $global:LASTEXITCODE = 0
    }
    catch {
        $exitCode = Write-PshOfflineFailureEnvelope -ErrorRecord $_
        $global:LASTEXITCODE = $exitCode
        exit $exitCode
    }
}
