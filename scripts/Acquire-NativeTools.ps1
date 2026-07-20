# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LockPath,
    [switch]$Check
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-PshNativeCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw "Native tool acquisition failed: $Message" }
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

function Resolve-PshNativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshNativeCondition (-not [string]::IsNullOrWhiteSpace($RelativePath)) "$Description is empty."
    Assert-PshNativeCondition (-not [IO.Path]::IsPathRooted($RelativePath)) "$Description is rooted: $RelativePath"
    $segments = @($RelativePath.Replace('\', '/').Split('/'))
    Assert-PshNativeCondition (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "$Description contains an empty path segment."
    Assert-PshNativeCondition ($segments -notcontains '.') "$Description contains '.': $RelativePath"
    Assert-PshNativeCondition ($segments -notcontains '..') "$Description escapes its root: $RelativePath"
    Assert-PshNativeCondition ($RelativePath -notmatch '[<>:"|?*]') "$Description contains an invalid path character."

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $nativeRelative = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath((Join-Path -Path $fullRoot -ChildPath $nativeRelative))
    $comparison = [StringComparison]::Ordinal
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $comparison = [StringComparison]::OrdinalIgnoreCase }
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    Assert-PshNativeCondition ($fullPath.StartsWith($prefix, $comparison)) "$Description escapes its root: $RelativePath"
    return $fullPath
}

function Assert-PshFixedUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshNativeCondition ($Url -match '\Ahttps://') "$Description is not HTTPS."
    Assert-PshNativeCondition ($Url -notmatch '(?i)(?:^|[/=])latest(?:[/?.#]|$)') "$Description uses latest: $Url"
    Assert-PshNativeCondition ($Url -notmatch '(?i)/(?:refs/heads/)?(?:main|master)(?:[/?.#]|$)') "$Description uses a floating branch: $Url"
}

function Assert-PshPinnedSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshNativeCondition ($Hash -match '\A[0-9a-fA-F]{64}\z' -and $Hash -match '[1-9a-fA-F]') "$Description is not a nonzero SHA256 value."
}

function Invoke-PshFixedDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshFixedUrl -Url $Url -Description $Description
    $retryDelays = @(5, 15, 30)
    $maxAttempts = $retryDelays.Count + 1
    $lastMessage = 'unknown network error'

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $response = $null
        $input = $null
        $output = $null
        $completed = $false
        try {
            if ([IO.File]::Exists($DestinationPath)) { [IO.File]::Delete($DestinationPath) }
            $request = [Net.HttpWebRequest]::Create($Url)
            $request.Method = 'GET'
            $request.UserAgent = 'Psh-NativeTools/0.1.0'
            $request.Timeout = 120000
            $request.ReadWriteTimeout = 120000
            $response = [Net.HttpWebResponse]$request.GetResponse()
            Assert-PshNativeCondition ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300) "$Description returned HTTP $([int]$response.StatusCode)."
            $input = $response.GetResponseStream()
            $output = [IO.File]::Open($DestinationPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $input.CopyTo($output)
            $output.Flush()
            $completed = $true
        }
        catch {
            $lastMessage = $_.Exception.Message
        }
        finally {
            if ($null -ne $output) { $output.Dispose() }
            if ($null -ne $input) { $input.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
            if (-not $completed -and [IO.File]::Exists($DestinationPath)) {
                [IO.File]::Delete($DestinationPath)
            }
        }

        if ($completed) { return }
        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds ([int]$retryDelays[$attempt - 1])
        }
    }

    throw "Fixed download failed for $Description after $maxAttempts attempts: $lastMessage"
}

function Get-PshPeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-PshNativeCondition ($bytes.Length -ge 64) "PE file is too short: $Path"
    Assert-PshNativeCondition ($bytes[0] -eq 0x4d -and $bytes[1] -eq 0x5a) "PE file has no MZ header: $Path"
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    Assert-PshNativeCondition ($peOffset -ge 0 -and ($peOffset + 6) -le $bytes.Length) "PE header offset is invalid: $Path"
    Assert-PshNativeCondition ($bytes[$peOffset] -eq 0x50 -and $bytes[$peOffset + 1] -eq 0x45 -and $bytes[$peOffset + 2] -eq 0 -and $bytes[$peOffset + 3] -eq 0) "PE signature is invalid: $Path"
    return ('0x{0:X4}' -f [BitConverter]::ToUInt16($bytes, $peOffset + 4))
}

function Get-PshHostRid {
    $candidates = @(
        [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432'),
        [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
    )
    foreach ($candidate in $candidates) {
        $normalized = ([string]$candidate).ToUpperInvariant()
        switch ($normalized) {
            'AMD64' { return 'win-x64' }
            'X64' { return 'win-x64' }
            'ARM64' { return 'win-arm64' }
            'AARCH64' { return 'win-arm64' }
        }
    }
    return $null
}

function Copy-PshZipEntry {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$EntryPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $found = $false
    try {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($archive.Entries)) {
            $normalized = ([string]$entry.FullName).Replace('\', '/')
            Assert-PshNativeCondition (-not $normalized.StartsWith('/') -and $normalized -notmatch '\A[A-Za-z]:') "Archive contains an absolute entry: $normalized"
            $parts = @($normalized.TrimEnd('/').Split('/'))
            Assert-PshNativeCondition ($parts -notcontains '..' -and $parts -notcontains '.') "Archive contains a non-canonical entry: $normalized"
            Assert-PshNativeCondition (@($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "Archive contains an empty entry segment: $normalized"
            Assert-PshNativeCondition ($seen.Add($normalized)) "Archive contains a case-insensitive duplicate entry: $normalized"
        }

        foreach ($entry in @($archive.Entries)) {
            $normalized = ([string]$entry.FullName).Replace('\', '/')
            if (-not [string]::Equals($normalized, $EntryPath, [StringComparison]::Ordinal)) { continue }
            Assert-PshNativeCondition (-not $normalized.EndsWith('/')) "Selected archive entry is a directory: $EntryPath"
            $parent = [IO.Path]::GetDirectoryName($DestinationPath)
            [void][IO.Directory]::CreateDirectory($parent)
            $input = $entry.Open()
            $output = [IO.File]::Open($DestinationPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $input.CopyTo($output) }
            finally {
                $output.Dispose()
                $input.Dispose()
            }
            $found = $true
            break
        }
    }
    finally { $archive.Dispose() }
    Assert-PshNativeCondition $found "Archive entry was not found: $EntryPath"
}

function Invoke-PshNativeVersionProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Probe,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $arguments = @($Probe.arguments | ForEach-Object { [string]$_ })
    $output = @(& $Path @arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $text = ($output -join "`n").Trim()
    $versionLine = if ($output.Count -eq 0) { '' } else { ([string]$output[0]).Trim() }
    Assert-PshNativeCondition ($exitCode -eq 0) ("{0} version probe exited {1}: {2}" -f $Name, $exitCode, $text)
    Assert-PshNativeCondition ($versionLine -match [string]$Probe.pattern) "$Name version probe did not match '$($Probe.pattern)': $text"
}

function Test-PshNativeTree {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRootPath,
        [Parameter(Mandatory = $true)][object]$Lock
    )

    $toolsRoot = Resolve-PshNativePath -Root $RepositoryRootPath -RelativePath ([string]$Lock.toolRoot) -Description 'toolRoot'
    $expected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$expected.Add('native-tools.lock.json')
    foreach ($tool in @($Lock.tools)) {
        foreach ($rid in @('win-x64', 'win-arm64')) {
            $artifact = Get-PshPropertyValue -InputObject $tool.artifacts -Name $rid
            Assert-PshNativeCondition ([string]$artifact.state -ceq 'pinned') "$($tool.name)/$rid is not pinned."
            Assert-PshPinnedSha256 -Hash ([string]$artifact.installedSha256) -Description "$($tool.name)/$rid installedSha256"
            $path = Resolve-PshNativePath -Root $toolsRoot -RelativePath ([string]$artifact.installedPath) -Description "$($tool.name)/$rid installedPath"
            Assert-PshNativeCondition (Test-Path -LiteralPath $path -PathType Leaf) "$($tool.name)/$rid executable is missing: $path"
            Assert-PshNativeCondition ((Get-PshFileSha256 -Path $path) -ceq ([string]$artifact.installedSha256).ToLowerInvariant()) "$($tool.name)/$rid executable SHA256 mismatches."
            Assert-PshNativeCondition ([string]::Equals((Get-PshPeMachine -Path $path), [string]$artifact.peMachine, [StringComparison]::OrdinalIgnoreCase)) "$($tool.name)/$rid PE machine mismatches."
            [void]$expected.Add(([string]$artifact.installedPath).Replace('/', [IO.Path]::DirectorySeparatorChar))
        }
        foreach ($license in @($tool.license.files)) {
            Assert-PshPinnedSha256 -Hash ([string]$license.sha256) -Description "$($tool.name) license SHA256"
            Assert-PshNativeCondition ([int64]$license.size -gt 0) "$($tool.name) license size is not positive: $($license.path)"
            $licensePath = Resolve-PshNativePath -Root $RepositoryRootPath -RelativePath ([string]$license.path) -Description "$($tool.name) license"
            Assert-PshNativeCondition (Test-Path -LiteralPath $licensePath -PathType Leaf) "$($tool.name) license is missing: $($license.path)"
            Assert-PshNativeCondition ((Get-PshFileSha256 -Path $licensePath) -ceq ([string]$license.sha256).ToLowerInvariant()) "$($tool.name) license SHA256 mismatches: $($license.path)"
            Assert-PshNativeCondition ([int64](Get-Item -LiteralPath $licensePath).Length -eq [int64]$license.size) "$($tool.name) license size mismatches: $($license.path)"
        }
    }
    $actual = @(Get-ChildItem -LiteralPath $toolsRoot -Recurse -File | ForEach-Object {
        $_.FullName.Substring($toolsRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    })
    foreach ($relative in $actual) {
        Assert-PshNativeCondition ($expected.Contains($relative)) "Unexpected tool file: $relative"
    }
    Assert-PshNativeCondition ($actual.Count -eq $expected.Count) 'Tool tree contains missing or extra files.'
}

if ([string]::IsNullOrWhiteSpace($LockPath)) {
    $LockPath = Join-Path -Path (Join-Path -Path $RepositoryRoot -ChildPath 'tools') -ChildPath 'native-tools.lock.json'
}
$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$lockPath = [IO.Path]::GetFullPath($LockPath)
Assert-PshNativeCondition (Test-Path -LiteralPath $lockPath -PathType Leaf) "Lock file is missing: $lockPath"
$lock = [IO.File]::ReadAllText($lockPath, (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json -ErrorAction Stop
Assert-PshNativeCondition ([int]$lock.schemaVersion -eq 1) 'Unsupported lock schemaVersion.'
Assert-PshNativeCondition ([string]$lock.toolRoot -ceq 'tools') 'Unexpected toolRoot.'

try {
    if ($Check) {
        Test-PshNativeTree -RepositoryRootPath $repositoryRootPath -Lock $lock
        Write-Output 'Native tool tree check passed without network access.'
        return
    }

    $toolsRoot = Resolve-PshNativePath -Root $repositoryRootPath -RelativePath ([string]$lock.toolRoot) -Description 'toolRoot'
    $temporaryRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('psh-native-tools-{0}' -f ([Guid]::NewGuid().ToString('N')))
    [void][IO.Directory]::CreateDirectory($temporaryRoot)
    $hostRid = Get-PshHostRid
    try {
        foreach ($tool in @($lock.tools)) {
            foreach ($rid in @('win-x64', 'win-arm64')) {
                $artifact = Get-PshPropertyValue -InputObject $tool.artifacts -Name $rid
                Assert-PshNativeCondition ([string]$artifact.state -ceq 'pinned') "$($tool.name)/$rid is not pinned."
                Assert-PshPinnedSha256 -Hash ([string]$artifact.archiveSha256) -Description "$($tool.name)/$rid archiveSha256"
                Assert-PshPinnedSha256 -Hash ([string]$artifact.installedSha256) -Description "$($tool.name)/$rid installedSha256"
                Assert-PshFixedUrl -Url ([string]$artifact.browserUrl) -Description "$($tool.name)/$rid browserUrl"
                Assert-PshFixedUrl -Url ([string]$artifact.apiUrl) -Description "$($tool.name)/$rid apiUrl"
                Assert-PshNativeCondition ([string]$artifact.archiveType -in @('zip', 'exe')) "$($tool.name)/$rid archiveType is unsupported."
                $downloadPath = Resolve-PshNativePath -Root $temporaryRoot -RelativePath ([string]$artifact.assetName) -Description "$($tool.name)/$rid assetName"
                Invoke-PshFixedDownload -Url ([string]$artifact.browserUrl) -DestinationPath $downloadPath -Description "$($tool.name)/$rid browserUrl"
                Assert-PshNativeCondition ((Get-PshFileSha256 -Path $downloadPath) -ceq ([string]$artifact.archiveSha256).ToLowerInvariant()) "$($tool.name)/$rid archive SHA256 mismatches."

                $stagedPath = Join-Path -Path $temporaryRoot -ChildPath ('{0}-{1}.exe' -f $tool.name, $rid)
                if ([string]$artifact.archiveType -ceq 'zip') {
                    Copy-PshZipEntry -ArchivePath $downloadPath -EntryPath ([string]$artifact.executableArchivePath) -DestinationPath $stagedPath
                }
                else {
                    Assert-PshNativeCondition ([string]$artifact.executableArchivePath -ceq [string]$artifact.assetName) "$($tool.name)/$rid executableArchivePath must equal assetName for a direct executable."
                    [IO.File]::Copy($downloadPath, $stagedPath, $true)
                }
                $installedSha = Get-PshFileSha256 -Path $stagedPath
                $lockedSha = [string]$artifact.installedSha256
                Assert-PshNativeCondition ($installedSha -ceq $lockedSha.ToLowerInvariant()) "$($tool.name)/$rid installed SHA256 mismatches lock."
                Assert-PshNativeCondition ([string]::Equals((Get-PshPeMachine -Path $stagedPath), [string]$artifact.peMachine, [StringComparison]::OrdinalIgnoreCase)) "$($tool.name)/$rid PE machine mismatches lock."

                $destinationPath = Resolve-PshNativePath -Root $toolsRoot -RelativePath ([string]$artifact.installedPath) -Description "$($tool.name)/$rid installedPath"
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destinationPath))
                [IO.File]::Copy($stagedPath, $destinationPath, $true)
                if ($null -ne $hostRid -and $hostRid -ceq $rid) {
                    Invoke-PshNativeVersionProbe -Path $destinationPath -Probe $tool.versionProbe -Name ([string]$tool.name)
                }
            }
        }

        $licenseOrdinal = 0
        foreach ($tool in @($lock.tools)) {
            foreach ($license in @($tool.license.files)) {
                $licenseOrdinal++
                $licenseName = '{0}-license-{1}.bin' -f ([string]$tool.name), $licenseOrdinal
                $licenseDownloadPath = Resolve-PshNativePath -Root $temporaryRoot -RelativePath $licenseName -Description "$($tool.name) license download"
                Assert-PshPinnedSha256 -Hash ([string]$license.sha256) -Description "$($tool.name) license SHA256"
                Assert-PshNativeCondition ([int64]$license.size -gt 0) "$($tool.name) license size is not positive: $($license.path)"
                Invoke-PshFixedDownload -Url ([string]$license.sourceUrl) -DestinationPath $licenseDownloadPath -Description "$($tool.name) license sourceUrl"
                Assert-PshNativeCondition ((Get-PshFileSha256 -Path $licenseDownloadPath) -ceq ([string]$license.sha256).ToLowerInvariant()) "$($tool.name) license SHA256 mismatches source: $($license.path)"
                Assert-PshNativeCondition ([int64](Get-Item -LiteralPath $licenseDownloadPath).Length -eq [int64]$license.size) "$($tool.name) license size mismatches source: $($license.path)"
                $licensePath = Resolve-PshNativePath -Root $repositoryRootPath -RelativePath ([string]$license.path) -Description "$($tool.name) license"
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($licensePath))
                [IO.File]::Copy($licenseDownloadPath, $licensePath, $true)
            }
        }

        Test-PshNativeTree -RepositoryRootPath $repositoryRootPath -Lock $lock
        Write-Output ('Native tool acquisition passed: {0} tools, x64 and ARM64 artifacts, and fixed licenses.' -f @($lock.tools).Count)
    }
    finally {
        if ([IO.Directory]::Exists($temporaryRoot)) {
            [IO.Directory]::Delete($temporaryRoot, $true)
        }
    }
}
catch {
    throw
}
