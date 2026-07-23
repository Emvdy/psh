# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string] $RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent ([string]$MyInvocation.MyCommand.Path))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$script:Assertions = 0
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Goal5CatalogMembership = @{}
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal5-online-offline-' + [Guid]::NewGuid().ToString('N'))
$reportRoot = if ([string]::IsNullOrWhiteSpace($env:PSH_GOAL5_REPORT_ROOT)) {
    Join-Path ([IO.Path]::GetTempPath()) ('psh-goal5-report-' + [Guid]::NewGuid().ToString('N'))
}
else { [IO.Path]::GetFullPath($env:PSH_GOAL5_REPORT_ROOT) }
[IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
[IO.Directory]::CreateDirectory($reportRoot) | Out-Null

function Assert-PshGoal5Entry {
    param([Parameter(Mandatory = $true)][bool] $Condition, [Parameter(Mandatory = $true)][string] $Message)
    $script:Assertions++
    if (-not $Condition) { throw "Goal 5 online/offline failed: $Message" }
}

function Get-PshGoal5ShellApplicationRank {
    param([Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Path)
    $separator = [string][char]92
    $normalized = $Path.Replace('/', $separator).ToLowerInvariant()
    if ($normalized.Length -lt 3 -or -not [char]::IsLetter($normalized[0]) -or [char]$normalized[1] -ne [char]58 -or [char]$normalized[2] -ne [char]92) { return 100 }
    $relative = $normalized.Substring(2)
    if ($Name -ceq 'bash' -and $relative -ceq ($separator + 'program files' + $separator + 'git' + $separator + 'bin' + $separator + 'bash.exe')) { return 10 }
    if ($Name -ceq 'bash' -and $relative -ceq ($separator + 'program files' + $separator + 'git' + $separator + 'usr' + $separator + 'bin' + $separator + 'bash.exe')) { return 20 }
    if ($Name -ceq 'bash' -and $relative -ceq ($separator + 'windows' + $separator + 'system32' + $separator + 'bash.exe')) { return 30 }
    if ($Name -ceq 'sh' -and $relative -ceq ($separator + 'program files' + $separator + 'git' + $separator + 'usr' + $separator + 'bin' + $separator + 'sh.exe')) { return 10 }
    if ($Name -ceq 'sh' -and $relative -ceq ($separator + 'program files' + $separator + 'git' + $separator + 'bin' + $separator + 'sh.exe')) { return 20 }
    if ($Name -ceq 'sh' -and $relative -ceq ($separator + 'windows' + $separator + 'system32' + $separator + 'sh.exe')) { return 30 }
    return 100
}

function Select-PshGoal5ShellApplicationPath {
    param([Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string[]] $CandidatePaths)
    $selected = @($CandidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        [pscustomobject][ordered]@{ Path = [string]$_; Rank = Get-PshGoal5ShellApplicationRank -Name $Name -Path ([string]$_) }
    } | Sort-Object Rank, Path | Select-Object -First 1)
    if ($selected.Count -ne 1) { return $null }
    return [string]$selected[0].Path
}

function Get-PshGoal5ShellApplication {
    param([Parameter(Mandatory = $true)][ValidateSet('bash', 'sh')][string] $Name)
    $runningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $paths = @(Get-Command -Name $Name -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object {
        $path = [string]$_.Source
        if ([string]::IsNullOrWhiteSpace($path)) { $path = [string]$_.Definition }
        if (-not [string]::IsNullOrWhiteSpace($path) -and [IO.File]::Exists($path)) {
            if (-not $runningOnWindows -or (Get-PshGoal5ShellApplicationRank -Name $Name -Path $path) -lt 100) { $path }
        }
    } | Select-Object -Unique)
    return Select-PshGoal5ShellApplicationPath -Name $Name -CandidatePaths $paths
}

function ConvertTo-PshGoal5BashPath {
    param(
        [Parameter(Mandatory = $true)][string] $BashPath,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $converted = @(& $BashPath -c 'if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; elif command -v wslpath >/dev/null 2>&1; then wslpath -u "$1"; else printf "%s\n" "$1"; fi' _ $Path)
    if ([int]$LASTEXITCODE -ne 0 -or $converted.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$converted[0])) {
        throw "Unable to convert a test fixture path for Bash: $Path"
    }
    return ([string]$converted[0]).TrimEnd("`r", "`n")
}

function Get-PshGoal5EmbeddedShellScript {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $Marker,
        [Parameter(Mandatory = $true)][string] $EndText
    )

    $markerText = '$flowMarker = "' + $Marker + '"'
    $markerOffset = $Text.IndexOf($markerText, [StringComparison]::Ordinal)
    if ($markerOffset -lt 0 -or $Text.IndexOf($markerText, $markerOffset + $markerText.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Embedded shell PowerShell marker is missing or duplicated: $Marker"
    }
    $startText = '$ErrorActionPreference = "Stop"'
    $startOffset = $Text.LastIndexOf($startText, $markerOffset, [StringComparison]::Ordinal)
    $endOffset = $Text.IndexOf($EndText, $markerOffset, [StringComparison]::Ordinal)
    if ($startOffset -lt 0 -or $endOffset -lt $markerOffset) { throw "Embedded shell PowerShell script boundary is invalid: $Marker" }
    return $Text.Substring($startOffset, ($endOffset + $EndText.Length) - $startOffset)
}

function Assert-PshGoal5PowerShellParses {
    param([Parameter(Mandatory = $true)][string] $Text, [Parameter(Mandatory = $true)][string] $Label)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    Assert-PshGoal5Entry ($errors.Count -eq 0) "$Label contains PowerShell parser errors."
    return $ast
}

function Get-PshGoal5HashBytes {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PshGoal5HashFile {
    param([Parameter(Mandatory = $true)][string] $Path)
    return Get-PshGoal5HashBytes -Bytes ([IO.File]::ReadAllBytes($Path))
}

function Get-PshGoal5LockedHashFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $stream = $null
    $sha = $null
    try {
        # Snapshot writers retain ReadWrite handles shared for readers. The
        # reader must reciprocally share Write even though it never writes.
        $stream = New-Object IO.FileStream($Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::ReadWrite))
        $sha = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Write-PshGoal5Text {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function Write-PshGoal5Json {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][object] $Value)
    Write-PshGoal5Text -Path $Path -Text ((ConvertTo-PshCanonicalJson -InputObject $Value) + "`n")
}

function New-PshGoal5Catalog {
    param(
        [Parameter(Mandatory = $true)][string] $ContentRoot,
        [Parameter(Mandatory = $true)][string] $CatalogPath
    )

    $catalogCommand = Get-Command -Name New-FileCatalog -CommandType Cmdlet -ErrorAction Stop
    $contentRootFull = [IO.Path]::GetFullPath($ContentRoot)
    $catalogPathFull = [IO.Path]::GetFullPath($CatalogPath)
    if ([IO.File]::Exists($catalogPathFull)) { [IO.File]::Delete($catalogPathFull) }
    [void](& $catalogCommand -Path $contentRootFull -CatalogFilePath $catalogPathFull -CatalogVersion 2.0 -ErrorAction Stop)
    if (-not [IO.File]::Exists($catalogPathFull) -or ([IO.FileInfo]$catalogPathFull).Length -le 0) {
        throw "New-FileCatalog did not create a non-empty catalog: $catalogPathFull"
    }
    return $catalogPathFull
}

function New-PshGoal5CatalogForFiles {
    param(
        [Parameter(Mandatory = $true)][string[]] $Paths,
        [Parameter(Mandatory = $true)][string] $CatalogPath
    )

    $staging = Join-Path $script:TestRoot ('catalog-input-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    $members = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($path in $Paths) {
            $name = [IO.Path]::GetFileName($path)
            Copy-Item -LiteralPath $path -Destination (Join-Path $staging $name)
            [void]$members.Add([pscustomobject][ordered]@{ Name = $name; Sha256 = Get-PshGoal5HashFile -Path $path })
        }
        $catalog = New-PshGoal5Catalog -ContentRoot $staging -CatalogPath $CatalogPath
        $script:Goal5CatalogMembership[(Get-PshGoal5HashFile -Path $catalog)] = $members.ToArray()
        return $catalog
    }
    finally {
        if ([IO.Directory]::Exists($staging)) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}

function New-PshGoal5Response {
    param(
        [Parameter(Mandatory = $true)][int] $StatusCode,
        [Parameter(Mandatory = $true)][string] $ResponseUri,
        [Parameter()][AllowNull()][string] $Location,
        [Parameter()][AllowNull()][byte[]] $Bytes
    )
    if ($null -eq $Bytes) { $Bytes = New-Object byte[] 0 }
    $stream = New-Object IO.MemoryStream(, $Bytes)
    return [pscustomobject][ordered]@{
        StatusCode = $StatusCode
        ResponseUri = $ResponseUri
        Location = $Location
        Headers = @{}
        ContentLength = [int64]$Bytes.Length
        Bytes = [byte[]]$Bytes
        Stream = $stream
        Disposable = $stream
    }
}

function New-PshGoal5EntryPackage {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][ValidateSet('Core', 'Full')][string] $Edition,
        [Parameter()][ValidateSet('any', 'win-x64')][string] $Architecture = 'any',
        [Parameter()][switch] $RealOffline
    )

    [IO.Directory]::CreateDirectory($Root) | Out-Null
    if ($RealOffline) {
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/install/install-offline.ps1') -Destination (Join-Path $Root 'install-offline.ps1')
    }
    else {
        Write-PshGoal5Text -Path (Join-Path $Root 'install-offline.ps1') -Text @'
[CmdletBinding()]
param([string]$Edition = 'Core', [string]$Version = 'latest', [switch]$NonInteractive, [string]$ArchivePath, [string]$ArchiveSha256)
function Invoke-PshOfflineInstall {
    param([string]$Edition = 'Core', [string]$Version = 'latest', [switch]$NonInteractive, [string]$ArchivePath, [string]$ArchiveSha256)
    $log = [string]$env:PSH_GOAL5_ENTRY_LOG
    if (-not [string]::IsNullOrWhiteSpace($log)) {
        [IO.File]::AppendAllText($log, (([ordered]@{ edition = $Edition; version = $Version; nonInteractive = [bool]$NonInteractive; archivePath = $ArchivePath; archiveSha256 = $ArchiveSha256 }) | ConvertTo-Json -Compress) + "`n", (New-Object Text.UTF8Encoding($false)))
    }
    return [pscustomobject][ordered]@{ success = $true; code = 0; edition = $Edition; version = $Version; archivePath = $ArchivePath; archiveSha256 = $ArchiveSha256 }
}
'@
    }
    Write-PshGoal5Text -Path (Join-Path $Root 'install.ps1') -Text '# fixture online entry`n'
    Write-PshGoal5Text -Path (Join-Path $Root 'uninstall.ps1') -Text '# fixture uninstall`n'
    Write-PshGoal5Text -Path (Join-Path $Root 'install.sh') -Text '#!/usr/bin/env sh`n'
    [IO.File]::WriteAllBytes((Join-Path $Root 'psh-installer.exe'), [Text.Encoding]::ASCII.GetBytes('MZ fixture bootstrapper'))

    $payloadInstall = Join-Path $Root 'payload/install'
    [IO.Directory]::CreateDirectory($payloadInstall) | Out-Null
    if ($RealOffline) {
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/install/PackageLifecycle.ps1') -Destination (Join-Path $payloadInstall 'PackageLifecycle.ps1')
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/install/ReleaseTrust.ps1') -Destination (Join-Path $payloadInstall 'ReleaseTrust.ps1')
    }
    else {
        Write-PshGoal5Text -Path (Join-Path $payloadInstall 'PackageLifecycle.ps1') -Text '# fixture lifecycle helper`n'
        Write-PshGoal5Text -Path (Join-Path $payloadInstall 'ReleaseTrust.ps1') -Text '# fixture trust helper`n'
    }
    Write-PshGoal5Text -Path (Join-Path $payloadInstall 'bootstrap.ps1') -Text '# fixture bootstrap`n'
    Write-PshGoal5Text -Path (Join-Path $payloadInstall 'config.psd1') -Text ("@{{`n    SchemaVersion = 1`n    Edition = '{0}'`n    DisabledCommands = @()`n}}`n" -f $Edition)
    Write-PshGoal5Text -Path (Join-Path $payloadInstall 'Install-PshPackage.ps1') -Text @'
[CmdletBinding(SupportsShouldProcess = $true)]
param([Parameter(Mandatory=$true)][string]$PackageRoot,[string]$InstallRoot,[string]$Edition,[string]$Version,[string]$ArchiveSha256,[switch]$Offline)
$log = [string]$env:PSH_GOAL5_ENTRY_LOG
$catalogPresent = [IO.File]::Exists((Join-Path $PackageRoot 'package.manifest.cat'))
if (-not [string]::IsNullOrWhiteSpace($log)) { [IO.File]::AppendAllText($log, (([ordered]@{ edition = $Edition; version = $Version; archiveSha256 = $ArchiveSha256; offline = [bool]$Offline; catalogPresent = $catalogPresent; packageRoot = $PackageRoot }) | ConvertTo-Json -Compress) + "`n", (New-Object Text.UTF8Encoding($false))) }
[pscustomobject][ordered]@{ success = $true; code = 0; operation = 'install'; version = $Version; edition = $Edition; catalogPresent = $catalogPresent }
'@
    $module = Join-Path $Root 'payload/Psh'
    [IO.Directory]::CreateDirectory($module) | Out-Null
    Write-PshGoal5Text -Path (Join-Path $module 'Psh.psm1') -Text "# fixture module $Version`n"
    Write-PshGoal5Text -Path (Join-Path $module 'Psh.psd1') -Text "@{ RootModule = 'Psh.psm1'; ModuleVersion = '0.1.0' }`n"
    if ($Edition -ceq 'Full') {
        Write-PshGoal5Text -Path (Join-Path $Root 'payload/Psh/Tools/native-tools.lock.json') -Text '{"synthetic":true}'
        $Architecture = 'win-x64'
    }

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName)) {
        if ($file.Name -ceq 'package.manifest.json' -or $file.Name -ceq 'package.manifest.cat') { continue }
        $relative = $file.FullName.Substring(([IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar).Length).Replace([IO.Path]::DirectorySeparatorChar, '/')
        $role = if ($relative -ceq 'psh-installer.exe') { 'bootstrapper' } elseif ($relative -in @('install-offline.ps1', 'uninstall.ps1', 'install.sh')) { 'entrypoint' } else { 'payload' }
        [void]$files.Add([pscustomobject][ordered]@{ relativePath = $relative; length = [int64]$file.Length; sha256 = Get-PshGoal5HashFile -Path $file.FullName; role = $role })
    }
    $treeSha = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = $files.ToArray() })
    $bootstrap = @($files | Where-Object { $_.relativePath -ceq 'psh-installer.exe' })[0]
    $lock = @($files | Where-Object { $_.relativePath -match '(?i)native-tools\.lock\.json$' })
    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        version = $Version
        edition = $Edition
        architecture = $Architecture
        payloadRoot = 'payload'
        files = $files.ToArray()
        treeSha256 = $treeSha
        entrypoints = [pscustomobject][ordered]@{ offlinePowerShell = 'install-offline.ps1'; uninstallPowerShell = 'uninstall.ps1'; shell = 'install.sh'; bootstrapper = 'psh-installer.exe' }
        testOnly = $false
        source = [pscustomobject][ordered]@{ repository = 'https://github.com/Emvdy/psh'; commit = ('a' * 40) }
        bootstrapper = [pscustomobject][ordered]@{ relativePath = 'psh-installer.exe'; sha256 = [string]$bootstrap.sha256; anyCpu = $true }
        nativeToolsLockSha256 = if ($Edition -ceq 'Full') { [string]$lock[0].sha256 } else { $null }
    }
    $manifestPath = Join-Path $Root 'package.manifest.json'
    $catalogPath = Join-Path $Root 'package.manifest.cat'
    Write-PshGoal5Json -Path $manifestPath -Value $manifest
    [void](New-PshGoal5CatalogForFiles -Paths @($manifestPath) -CatalogPath $catalogPath)
    $package = [pscustomobject][ordered]@{ Root = $Root; Manifest = $manifest; ManifestPath = $manifestPath; CatalogPath = $catalogPath; ManifestSha256 = Get-PshGoal5HashFile -Path $manifestPath; TreeSha256 = $treeSha; Edition = $Edition; Version = $Version; Architecture = $Architecture; ArchivePath = $null; ArchiveSha256 = $null }
    if ($RealOffline) { Set-PshGoal5PackageArchiveEvidence -Package $package }
    return $package
}

function New-PshGoal5ZipBytes {
    param([Parameter(Mandatory = $true)][string] $PackageRoot, [Parameter(Mandatory = $true)][string] $ZipPath)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $packageRootFull = [IO.Path]::GetFullPath($PackageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $zipParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ZipPath))
    if (-not [string]::IsNullOrWhiteSpace($zipParent)) { [IO.Directory]::CreateDirectory($zipParent) | Out-Null }
    $stream = $null
    $archive = $null
    try {
        $stream = New-Object IO.FileStream($ZipPath, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::None))
        $archive = New-Object IO.Compression.ZipArchive($stream, ([IO.Compression.ZipArchiveMode]::Create), $true, (New-Object Text.UTF8Encoding($false)))
        $files = @(Get-ChildItem -LiteralPath $packageRootFull -Recurse -Force -File | ForEach-Object {
            $relative = $_.FullName.Substring(($packageRootFull + [IO.Path]::DirectorySeparatorChar).Length)
            $relative = $relative.Replace([IO.Path]::DirectorySeparatorChar, '/').Replace([IO.Path]::AltDirectorySeparatorChar, '/')
            [pscustomobject][ordered]@{ Name = $relative; Path = [string]$_.FullName }
        } | Sort-Object Name)
        foreach ($file in $files) {
            $entry = $archive.CreateEntry([string]$file.Name, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = New-Object DateTimeOffset(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $entry.ExternalAttributes = 0
            $entryStream = $null
            $sourceStream = $null
            try {
                $entryStream = $entry.Open()
                $sourceStream = New-Object IO.FileStream([string]$file.Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
                $sourceStream.CopyTo($entryStream)
            }
            finally {
                if ($null -ne $sourceStream) { $sourceStream.Dispose() }
                if ($null -ne $entryStream) { $entryStream.Dispose() }
            }
        }
    }
    catch {
        if ([IO.File]::Exists($ZipPath)) { try { [IO.File]::Delete($ZipPath) } catch { } }
        throw
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $readArchive = $null
    try {
        $readArchive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        $backslashEntries = @($readArchive.Entries | Where-Object { ([string]$_.FullName).Contains('\') })
        Assert-PshGoal5Entry ($backslashEntries.Count -eq 0) 'The online/offline fixture ZIP contains a non-canonical backslash entry name.'
    }
    finally {
        if ($null -ne $readArchive) { $readArchive.Dispose() }
    }
    return [IO.File]::ReadAllBytes($ZipPath)
}

function Set-PshGoal5PackageArchiveEvidence {
    param([Parameter(Mandatory = $true)][object] $Package)

    $archiveRoot = Join-Path $script:TestRoot 'offline-archives'
    [IO.Directory]::CreateDirectory($archiveRoot) | Out-Null
    $archivePath = Join-Path $archiveRoot ("{0}-{1}-{2}.zip" -f [string]$Package.Version, [string]$Package.Edition, [Guid]::NewGuid().ToString('N'))
    [void](New-PshGoal5ZipBytes -PackageRoot ([string]$Package.Root) -ZipPath $archivePath)
    $Package.ArchivePath = $archivePath
    $Package.ArchiveSha256 = Get-PshGoal5HashFile -Path $archivePath
}

function New-PshGoal5ReleaseFixture {
    param([Parameter(Mandatory = $true)][string] $Root)
    $version = '1.2.3'
    $core = New-PshGoal5EntryPackage -Root (Join-Path $Root 'core') -Version $version -Edition Core
    $full = New-PshGoal5EntryPackage -Root (Join-Path $Root 'full') -Version $version -Edition Full -Architecture win-x64
    $coreBytes = New-PshGoal5ZipBytes -PackageRoot $core.Root -ZipPath (Join-Path $Root 'psh-core.zip')
    $fullBytes = New-PshGoal5ZipBytes -PackageRoot $full.Root -ZipPath (Join-Path $Root 'psh-full.zip')
    $coreName = "psh-$version-core.zip"
    $fullName = "psh-$version-full-win-x64.zip"
    $assets = @(
        [pscustomobject][ordered]@{ name = $coreName; role = 'package'; url = "https://github.com/Emvdy/psh/releases/download/v$version/$coreName"; length = [int64]$coreBytes.Length; sha256 = Get-PshGoal5HashBytes $coreBytes; package = [pscustomobject][ordered]@{ version = $version; edition = 'Core'; architecture = 'any'; packageManifestSha256 = $core.ManifestSha256; treeSha256 = $core.TreeSha256; testOnly = $false } },
        [pscustomobject][ordered]@{ name = $fullName; role = 'package'; url = "https://github.com/Emvdy/psh/releases/download/v$version/$fullName"; length = [int64]$fullBytes.Length; sha256 = Get-PshGoal5HashBytes $fullBytes; package = [pscustomobject][ordered]@{ version = $version; edition = 'Full'; architecture = 'win-x64'; packageManifestSha256 = $full.ManifestSha256; treeSha256 = $full.TreeSha256; testOnly = $false } }
    )
    $index = [pscustomobject][ordered]@{ schemaVersion = 1; product = 'Psh'; repository = 'https://github.com/Emvdy/psh'; version = $version; tag = "v$version"; sourceCommit = ('a' * 40); assets = $assets }
    $indexPath = Join-Path $Root "psh-release-$version.json"
    $checksumPath = Join-Path $Root 'SHA256SUMS'
    $catalogPath = Join-Path $Root "psh-release-$version.cat"
    Write-PshGoal5Json -Path $indexPath -Value $index
    Write-PshGoal5Text -Path $checksumPath -Text ((@($assets | ForEach-Object { '{0}  {1}' -f $_.sha256, $_.name }) -join "`n") + "`n")
    [void](New-PshGoal5CatalogForFiles -Paths @($indexPath, $checksumPath) -CatalogPath $catalogPath)
    $policy = [pscustomobject][ordered]@{ schemaVersion = 1; publisher = 'Emvdy Software'; subjectDistinguishedNames = @('CN=Emvdy Software, O=Emvdy'); requiredEkuOids = @('1.3.6.1.5.5.7.3.3'); requiredCertificatePolicyOids = @(); allowedRootCertificateSha256 = @('a' * 64) }
    return [pscustomobject][ordered]@{ Root = $Root; Version = $version; IndexPath = $indexPath; ChecksumPath = $checksumPath; CatalogPath = $catalogPath; Index = $index; Assets = $assets; Core = $core; Full = $full; CoreBytes = $coreBytes; FullBytes = $fullBytes; Policy = $policy }
}

function Add-PshGoal5ResponseQueue {
    param([Parameter(Mandatory = $true)][hashtable] $Map, [Parameter(Mandatory = $true)][string] $Uri, [Parameter(Mandatory = $true)][object] $Response)
    if (-not $Map.ContainsKey($Uri)) { $Map[$Uri] = New-Object System.Collections.ArrayList }
    [void]$Map[$Uri].Add($Response)
}

function Set-PshGoal5OnlineTransportFixture {
    param(
        [Parameter(Mandatory = $true)][object] $Fixture,
        [switch] $CorruptPackage,
        [switch] $BadRedirect,
        [switch] $BadTag,
        [switch] $BadTrustDigest,
        [switch] $BadReleaseCatalogMembership
    )
    $script:Goal5OnlineMap = @{}
    $script:Goal5AcquisitionMap = @{}
    $bootstrapBytes = @{}
    $apiAssets = New-Object System.Collections.Generic.List[object]
    foreach ($path in @($Fixture.IndexPath, $Fixture.ChecksumPath, $Fixture.CatalogPath)) {
        $name = [IO.Path]::GetFileName($path)
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($BadReleaseCatalogMembership -and $path -ceq $Fixture.IndexPath) {
            $modifiedIndex = (ConvertTo-PshCanonicalJson -InputObject $Fixture.Index) | ConvertFrom-Json -ErrorAction Stop
            $modifiedIndex.sourceCommit = 'b' * 40
            $bytes = $script:Utf8.GetBytes((ConvertTo-PshCanonicalJson -InputObject $modifiedIndex) + "`n")
        }
        $bootstrapBytes[$path] = $bytes
        $sha256 = Get-PshGoal5HashBytes -Bytes $bytes
        if ($BadTrustDigest -and $path -ceq $Fixture.IndexPath) { $sha256 = 'f' * 64 }
        [void]$apiAssets.Add([pscustomobject][ordered]@{
                name = $name
                size = [int64]$bytes.Length
                digest = 'sha256:' + $sha256
                browser_download_url = "https://github.com/Emvdy/psh/releases/download/v1.2.3/$name"
            })
    }
    $apiDocument = [ordered]@{
        tag_name = if ($BadTag) { 'v9.9.9' } else { 'v1.2.3' }
        draft = $false
        prerelease = $false
        assets = $apiAssets.ToArray()
    }
    $apiBytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $apiDocument -Depth 8 -Compress))
    Add-PshGoal5ResponseQueue -Map $script:Goal5OnlineMap -Uri 'https://api.github.com/repos/Emvdy/psh/releases/latest' -Response (New-PshGoal5Response 502 'https://api.github.com/repos/Emvdy/psh/releases/latest' -Bytes ([byte[]]::new(0)))
    Add-PshGoal5ResponseQueue -Map $script:Goal5OnlineMap -Uri 'https://api.github.com/repos/Emvdy/psh/releases/latest' -Response (New-PshGoal5Response 200 'https://api.github.com/repos/Emvdy/psh/releases/latest' -Bytes $apiBytes)
    Add-PshGoal5ResponseQueue -Map $script:Goal5OnlineMap -Uri 'https://api.github.com/repos/Emvdy/psh/releases/tags/v1.2.3' -Response (New-PshGoal5Response 200 'https://api.github.com/repos/Emvdy/psh/releases/tags/v1.2.3' -Bytes $apiBytes)
    foreach ($path in @($Fixture.IndexPath, $Fixture.ChecksumPath, $Fixture.CatalogPath)) {
        $uri = if ($path -ceq $Fixture.IndexPath) { "https://github.com/Emvdy/psh/releases/download/v1.2.3/psh-release-1.2.3.json" } elseif ($path -ceq $Fixture.ChecksumPath) { 'https://github.com/Emvdy/psh/releases/download/v1.2.3/SHA256SUMS' } else { 'https://github.com/Emvdy/psh/releases/download/v1.2.3/psh-release-1.2.3.cat' }
        Add-PshGoal5ResponseQueue -Map $script:Goal5OnlineMap -Uri $uri -Response (New-PshGoal5Response 200 $uri -Bytes ([byte[]]$bootstrapBytes[$path]))
    }
    for ($assetIndex = 0; $assetIndex -lt 2; $assetIndex++) {
        $asset = $Fixture.Assets[$assetIndex]
        $assetBytes = if ($assetIndex -eq 0 -and $CorruptPackage) { [Text.Encoding]::UTF8.GetBytes('corrupt package') } elseif ($assetIndex -eq 0) { [byte[]]$Fixture.CoreBytes } else { [byte[]]$Fixture.FullBytes }
        $initial = [string]$asset.url
        $leaf = if ($assetIndex -eq 0) { 'core.zip' } else { 'full.zip' }
        $cdn = "https://release-assets.githubusercontent.com/github-production-release-asset/fixture/$leaf`?x=1"
        $location = if ($assetIndex -eq 0 -and $BadRedirect) { 'https://evil.invalid/core.zip' } else { $cdn }
        Add-PshGoal5ResponseQueue -Map $script:Goal5AcquisitionMap -Uri $initial -Response (New-PshGoal5Response 302 $initial $location -Bytes ([byte[]]::new(0)))
        Add-PshGoal5ResponseQueue -Map $script:Goal5AcquisitionMap -Uri $cdn -Response (New-PshGoal5Response 200 $cdn -Bytes $assetBytes)
    }
}

function Set-PshGoal5TrustMocks {
    $script:Goal5ActivePolicy = $script:Goal5Fixture.Policy
    Set-Item -Path Function:\Get-PshProductionPublisherPolicy -Value $script:Goal5PolicyShim
    Set-Item -Path Function:\Invoke-PshWindowsCatalogTrustVerifier -Value $script:Goal5VerifierShim
    Set-Item -Path Function:\Invoke-PshWindowsCatalogMembershipVerifier -Value $script:Goal5MembershipVerifierShim
}

$script:Goal5PolicyShim = {
        return Assert-PshPublisherPolicy -Policy $script:Goal5ActivePolicy
}
$script:Goal5VerifierShim = {
    param([Parameter(Mandatory = $true)][object] $Request)
    $script:Goal5VerifierCalls++
    return [pscustomobject][ordered]@{ Trusted = $true; Publisher = [string]$script:Goal5ActivePolicy.publisher }
}
$script:Goal5MembershipVerifierShim = {
    param([Parameter(Mandatory = $true)][object] $Request)

    $script:Goal5MembershipVerifierCalls++
    $catalogPath = [string](Get-PshLifecycleProperty $Request 'CatalogPath')
    $contentRoot = [string](Get-PshLifecycleProperty $Request 'ContentRoot')
    $offline = Get-PshLifecycleProperty $Request 'Offline'
    if ([string]::IsNullOrWhiteSpace($catalogPath) -or [string]::IsNullOrWhiteSpace($contentRoot) -or
        $offline -isnot [bool] -or -not [bool]$offline -or -not [IO.File]::Exists($catalogPath) -or
        -not [IO.Directory]::Exists($contentRoot)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogContent' -Message 'Catalog membership verification received an invalid request.'
    }

    $catalogSha256 = Get-PshGoal5LockedHashFile -Path $catalogPath
    if (-not $script:Goal5CatalogMembership.ContainsKey($catalogSha256)) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogContent' -Message 'Catalog content validation failed: unregistered catalog bytes.'
    }
    $expectedMembers = @($script:Goal5CatalogMembership[$catalogSha256])
    $contentEntries = @(Get-ChildItem -LiteralPath $contentRoot -Force)
    if ($contentEntries.Count -ne $expectedMembers.Count -or @($contentEntries | Where-Object { $_.PSIsContainer }).Count -ne 0) {
        Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogContent' -Message 'Catalog content validation failed: member set mismatch.'
    }
    foreach ($expectedMember in $expectedMembers) {
        $matches = @($contentEntries | Where-Object { [string]$_.Name -ceq [string]$expectedMember.Name })
        if ($matches.Count -ne 1 -or (Get-PshGoal5LockedHashFile -Path $matches[0].FullName) -cne [string]$expectedMember.Sha256) {
            Throw-PshReleaseTrustError -ExitCode 5 -ErrorId 'PshCatalogContent' -Message ('Catalog content validation failed: member mismatch for {0}.' -f [string]$expectedMember.Name)
        }
    }
    return [pscustomobject][ordered]@{ Trusted = $true; CatalogMembership = 'verified'; SignatureNotRequired = $true }
}

function Invoke-PshGoal5OnlineHttpMock {
    param([Parameter(Mandatory = $true)][Uri] $Uri)
    $key = $Uri.AbsoluteUri
    [void]$script:Goal5OnlineSeen.Add($key)
    if (-not $script:Goal5OnlineMap.ContainsKey($key)) { throw "online fixture URI was not mapped: $key" }
    $queue = $script:Goal5OnlineMap[$key]
    $response = $queue[0]
    if ($queue.Count -gt 1) { $queue.RemoveAt(0) }
    return New-PshGoal5Response -StatusCode $response.StatusCode -ResponseUri $response.ResponseUri -Location $response.Location -Bytes ([byte[]]$response.Bytes)
}

function Invoke-PshGoal5AcquisitionHttpMock {
    param([Parameter(Mandatory = $true)][object] $Request)
    $key = [string]$Request.Uri
    [void]$script:Goal5AcquisitionSeen.Add($key)
    if (-not $script:Goal5AcquisitionMap.ContainsKey($key)) { throw "acquisition fixture URI was not mapped: $key" }
    $queue = $script:Goal5AcquisitionMap[$key]
    $response = $queue[0]
    if ($queue.Count -gt 1) { $queue.RemoveAt(0) }
    return New-PshGoal5Response -StatusCode $response.StatusCode -ResponseUri $response.ResponseUri -Location $response.Location -Bytes ([byte[]]$response.Bytes)
}

function Assert-PshGoal5Failure {
    param([Parameter(Mandatory = $true)][scriptblock] $Action, [Parameter(Mandatory = $true)][int] $ExitCode, [Parameter()][string] $ErrorId)
    $failure = $null
    try { & $Action | Out-Null }
    catch { $failure = $_ }
    Assert-PshGoal5Entry ($null -ne $failure) 'Expected operation to fail.'
    $metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $failure
    Assert-PshGoal5Entry ([int]$metadata.ExitCode -eq $ExitCode) "Expected exit code $ExitCode, got $($metadata.ExitCode)."
    if (-not [string]::IsNullOrWhiteSpace($ErrorId)) { Assert-PshGoal5Entry ([string]$metadata.ErrorId -ceq $ErrorId) "Expected error id $ErrorId, got $($metadata.ErrorId)." }
}

$onlinePath = Join-Path $RepositoryRoot 'src/install/install.ps1'
$offlinePath = Join-Path $RepositoryRoot 'src/install/install-offline.ps1'
$shellPath = Join-Path $RepositoryRoot 'src/install/install.sh'
foreach ($path in @($onlinePath, $offlinePath, $shellPath)) { Assert-PshGoal5Entry ([IO.File]::Exists($path)) "Missing entry file: $path" }
$onlineText = [IO.File]::ReadAllText($onlinePath, $script:Utf8)
$offlineText = [IO.File]::ReadAllText($offlinePath, $script:Utf8)
$shellText = [IO.File]::ReadAllText($shellPath, $script:Utf8)
Assert-PshGoal5Entry ((@([regex]::Matches($onlineText, 'PSH_EMBED_HELPERS_BEGIN')).Count -eq 1) -and (@([regex]::Matches($onlineText, 'PSH_EMBED_HELPERS_END')).Count -eq 1)) 'Online helper embedding markers are not unique.'
Assert-PshGoal5Entry ($onlineText -notmatch '(?i)irm\s*\|\s*iex|Invoke-Expression|ExecutionPolicy\s+(Bypass|Unrestricted)|TestCore') 'Online entry contains a forbidden bypass or test hook.'
Assert-PshGoal5Entry ($offlineText -notmatch '(?i)Invoke-WebRequest|HttpWebRequest|WebClient|curl\s|wget\s|Invoke-Expression|ExecutionPolicy\s+(Bypass|Unrestricted)|TestCore') 'Offline entry contains a transport or bypass.'
Assert-PshGoal5Entry ($shellText -match 'api\.github\.com/repos/Emvdy/psh/releases/(latest|tags/)' -and $shellText -match 'digest' -and
    $shellText -match 'browser_download_url' -and $shellText -match 'PshShellEntryDigest') 'Shell online entry is not rooted in exact GitHub release asset metadata and a local digest check.'
Assert-PshGoal5Entry ($shellText -match '--archive-path' -and $shellText -match '--archive-sha256' -and $shellText -notmatch 'PshEntrySignature') 'Shell archive evidence or non-blocking Authenticode policy contract is missing.'
$tempScript = Get-PshGoal5EmbeddedShellScript -Text $shellText -Marker 'PshShellTempRoot' -EndText ("    throw`n}")
$cleanupScript = Get-PshGoal5EmbeddedShellScript -Text $shellText -Marker 'PshShellCleanupRoot' -EndText 'catch { exit 1 }'
$lockedParentScript = Get-PshGoal5EmbeddedShellScript -Text $shellText -Marker 'PshShellLockedParent' -EndText 'exit $exitCode'
[void](Assert-PshGoal5PowerShellParses -Text $tempScript -Label 'Shell Windows TEMP creator')
[void](Assert-PshGoal5PowerShellParses -Text $cleanupScript -Label 'Shell Windows TEMP cleanup')
$lockedParentAst = Assert-PshGoal5PowerShellParses -Text $lockedParentScript -Label 'Shell locked parent'
Assert-PshGoal5Entry (@([regex]::Matches($shellText, 'PshShellLockedParent')).Count -eq 1) 'Shell entry does not contain exactly one locked parent flow.'
Assert-PshGoal5Entry ($lockedParentScript -match '\[IO\.FileAccess\]::Read' -and $lockedParentScript -match '\[IO\.FileShare\]::Read' -and
    @([regex]::Matches($lockedParentScript, 'ComputeHash\(')).Count -eq 2) 'Shell locked parent does not retain one read/share-read entry handle across both authenticated hashes.'
Assert-PshGoal5Entry ($lockedParentScript -match 'Get-ExecutionPolicy\s+-ErrorAction\s+Stop' -and $lockedParentScript -match 'Stream\s+-ieq\s+"Zone\.Identifier"' -and
    $lockedParentScript.IndexOf('$requiresSignature', [StringComparison]::Ordinal) -lt $lockedParentScript.IndexOf('Get-AuthenticodeSignature', [StringComparison]::Ordinal)) 'Shell locked parent does not evaluate actual policy/MOTW before conditional Authenticode.'
Assert-PshGoal5Entry ($lockedParentScript -match 'Diagnostics\.ProcessStartInfo' -and $lockedParentScript -match '\$child\.WaitForExit\(\)' -and
    $lockedParentScript.IndexOf('$child.WaitForExit()', [StringComparison]::Ordinal) -lt $lockedParentScript.LastIndexOf('$entryStream.Dispose()', [StringComparison]::Ordinal)) 'Shell locked parent does not retain the entry lock through child completion.'
Assert-PshGoal5Entry ($lockedParentScript -match 'Append\(\[char\]92,\s*\[int\]' -and $lockedParentScript -notmatch '\(\[string\]\[char\]92\)\s*\*') 'Shell Win32 argument quoting does not use the explicit StringBuilder character repeat overload.'
Assert-PshGoal5Entry ($shellText -match 'PshShellTempRoot' -and $shellText -match '\[IO\.Path\]::GetTempPath\(\)' -and $shellText -match 'to_shell_path' -and
    $shellText -match 'PSH_SHELL_RELEASE_METADATA_PATH="\$release_metadata_windows_path"' -and $shellText -match 'PSH_SHELL_ENTRY_PATH="\$entry_windows_path"') 'Shell online flow does not create in Windows TEMP and reuse exact Win32 paths for verification and execution.'
Assert-PshGoal5Entry ($cleanupScript -match 'PshShellCleanupRoot' -and $cleanupScript -match '\[IO\.File\]::Delete\(' -and
    $cleanupScript -match '\[IO\.Directory\]::Delete\(\$root,\s*\$false\)' -and $shellText -notmatch '\bmktemp\b') 'Shell online TEMP cleanup is not exact and non-recursive.'
Assert-PshGoal5Entry ($shellText -notmatch '(?i)Unblock-File|Invoke-Expression|-ExecutionPolicy\s+(Bypass|Unrestricted)|PSExecutionPolicyPreference' -and
    $shellText -notmatch '(?im)^\s*Set-ExecutionPolicy\b' -and $shellText -notmatch '(?im)^\s*(Set|Add)-Content\b[^\r\n]*Zone\.Identifier') 'Shell entry contains a forbidden execution-policy bypass, policy mutation, memory execution, or synthesized MOTW.'
Assert-PshGoal5Entry ($shellText -notmatch '(?m)^\s*(digest_status|preflight_status)=' -and $shellText -match 'higher ancestor rename remains the narrow limitation of path-based -File') 'Shell entry retains split preflight processes or omits the path-based ancestor-rename limitation.'
$argumentFunction = @($lockedParentAst.FindAll({
            param($node)
            return ($node -is [Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -ceq 'ConvertTo-PshShellProcessArgument')
        }, $true))
Assert-PshGoal5Entry ($argumentFunction.Count -eq 1) 'Shell locked parent argument encoder is missing or duplicated.'
. ([scriptblock]::Create([string]$argumentFunction[0].Extent.Text))
$onlineManifestTrustOffset = $onlineText.IndexOf('$trustedPackage = Confirm-PshPackageManifestTrust', [StringComparison]::Ordinal)
$onlineArchiveBindingOffset = $onlineText.IndexOf('$archiveBinding = Confirm-PshPackageArchiveBinding', [StringComparison]::Ordinal)
$offlineManifestTrustOffset = $offlineText.IndexOf('$trustedPackage = Confirm-PshPackageManifestTrust', [StringComparison]::Ordinal)
$offlineArchiveBindingOffset = $offlineText.IndexOf('$archiveBinding = Confirm-PshPackageArchiveBinding', [StringComparison]::Ordinal)
$offlineMaterializationOffset = $offlineText.IndexOf('$installView = New-PshOfflineInstallView', [StringComparison]::Ordinal)
Assert-PshGoal5Entry ($onlineManifestTrustOffset -ge 0 -and $onlineManifestTrustOffset -lt $onlineArchiveBindingOffset) 'Online archive binding does not bind the already parsed package manifest record.'
Assert-PshGoal5Entry ($offlineManifestTrustOffset -ge 0 -and $offlineManifestTrustOffset -lt $offlineArchiveBindingOffset -and
    $offlineArchiveBindingOffset -lt $offlineMaterializationOffset) 'Offline archive binding is not ordered between manifest parsing and hash-checked materialization.'

. $onlinePath
$onlineTransportOriginal = (Get-Command Invoke-PshOnlineHttpRequest -CommandType Function).ScriptBlock
$acquisitionTransportOriginal = (Get-Command Invoke-PshAcquisitionHttpRequest -CommandType Function).ScriptBlock
$policyOriginal = (Get-Command Get-PshProductionPublisherPolicy -CommandType Function).ScriptBlock
$verifierOriginal = (Get-Command Invoke-PshWindowsCatalogTrustVerifier -CommandType Function).ScriptBlock
$membershipVerifierOriginal = (Get-Command Invoke-PshWindowsCatalogMembershipVerifier -CommandType Function).ScriptBlock
$script:Goal5VerifierCalls = 0
$script:Goal5MembershipVerifierCalls = 0
$script:Goal5Fixture = New-PshGoal5ReleaseFixture -Root (Join-Path $script:TestRoot 'release')
$script:Goal5FixturePolicy = $script:Goal5Fixture.Policy
$script:Goal5OnlineSeen = New-Object 'System.Collections.Generic.List[string]'
$script:Goal5AcquisitionSeen = New-Object 'System.Collections.Generic.List[string]'
$script:Goal5OnlineMap = @{}
$script:Goal5AcquisitionMap = @{}
$oldArchitecture = $null
$oldPath = $null
$oldTemp = $null
$oldTmp = $null

try {
    $lockedHashPath = Join-Path $script:TestRoot 'locked-membership-hash.bin'
    $lockedHashBytes = [Text.Encoding]::UTF8.GetBytes('locked membership hash fixture')
    [IO.File]::WriteAllBytes($lockedHashPath, $lockedHashBytes)
    $lockedHashStream = $null
    try {
        $lockedHashStream = New-Object IO.FileStream($lockedHashPath, ([IO.FileMode]::Open), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::Read))
        Assert-PshGoal5Entry ((Get-PshGoal5LockedHashFile -Path $lockedHashPath) -ceq (Get-PshGoal5HashBytes -Bytes $lockedHashBytes)) 'Catalog membership hashing could not read a locked trust snapshot without weakening its writer lock.'
        $lockedWriteProbe = $null
        $lockedWriteDenied = $false
        try { $lockedWriteProbe = New-Object IO.FileStream($lockedHashPath, ([IO.FileMode]::Open), ([IO.FileAccess]::Write), ([IO.FileShare]::ReadWrite)) }
        catch { $lockedWriteDenied = $true }
        finally { if ($null -ne $lockedWriteProbe) { $lockedWriteProbe.Dispose() } }
        Assert-PshGoal5Entry $lockedWriteDenied 'Catalog membership hashing weakened the locked trust snapshot against a new writer.'
    }
    finally {
        if ($null -ne $lockedHashStream) { $lockedHashStream.Dispose() }
    }

    $bashSelectionRegression = Select-PshGoal5ShellApplicationPath -Name bash -CandidatePaths @(
        'C:\Windows\System32\bash.exe',
        'C:\Program Files\Git\usr\bin\bash.exe',
        'C:\Program Files\Git\bin\bash.exe'
    )
    Assert-PshGoal5Entry ($bashSelectionRegression -ceq 'C:\Program Files\Git\bin\bash.exe') 'Bash application selection did not prefer one deterministic Git Bash executable.'
    $shSelectionRegression = Select-PshGoal5ShellApplicationPath -Name sh -CandidatePaths @(
        'C:\Windows\System32\sh.exe',
        'C:\Program Files\Git\bin\sh.exe',
        'C:\Program Files\Git\usr\bin\sh.exe'
    )
    Assert-PshGoal5Entry ($shSelectionRegression -ceq 'C:\Program Files\Git\usr\bin\sh.exe') 'sh application selection did not preserve Git Bash coverage.'
    Assert-PshGoal5Entry ((Get-PshGoal5ShellApplicationRank -Name bash -Path 'C:\spoof\Program Files\Git\bin\bash.exe') -eq 100) 'A nested Git Bash suffix spoof received a trusted rank.'
    Set-Item -Path Function:\Invoke-PshOnlineHttpRequest -Value ${function:Invoke-PshGoal5OnlineHttpMock}
    Set-Item -Path Function:\Invoke-PshAcquisitionHttpRequest -Value ${function:Invoke-PshGoal5AcquisitionHttpMock}
    Set-PshGoal5TrustMocks
    $oldArchitecture = $env:PROCESSOR_ARCHITECTURE
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    $logPath = Join-Path $script:TestRoot 'entry.log'
    $env:PSH_GOAL5_ENTRY_LOG = $logPath

    Set-PshGoal5OnlineTransportFixture -Fixture $script:Goal5Fixture
    $coreResult = @(Invoke-PshOnlineInstall -Edition Core -Version latest -NonInteractive)[-1]
    Assert-PshGoal5Entry ([bool]$coreResult.success -and [string]$coreResult.version -ceq '1.2.3') 'Online latest Core installation did not complete.'
    Assert-PshGoal5Entry ([string]$coreResult.trust.trustMode -ceq 'github-release-asset-digest+archive-binding+package-catalog-sha256' -and
        [string]$coreResult.trust.checksum -ceq 'release-asset-archive-manifest-tree-sha256-verified' -and
        [string]$coreResult.trust.catalogMembership -ceq 'verified' -and [bool]$coreResult.trust.signatureNotRequired -and
        [string]$coreResult.trust.archiveBinding -ceq 'verified' -and [string]$coreResult.trust.archiveSha256 -ceq [string]$coreResult.archiveSha256 -and
        [bool]$coreResult.trust.attestationRequiredAtPublish -and
        [string]$coreResult.trust.attestationVerification -ceq 'not-verified-at-runtime') 'Online installation did not report the production archive/hash/catalog trust mode honestly.'
    Assert-PshGoal5Entry (@($script:Goal5OnlineSeen | Where-Object { $_ -match '/v1\.2\.3/' }).Count -ge 3) 'Online release assets were not pinned to the fixed tag.'
    Assert-PshGoal5Entry (@($script:Goal5OnlineSeen | Where-Object { $_ -match '/latest' }).Count -eq 2) 'Online latest resolution did not retry the GitHub API route exactly once after the 502 fixture.'
    Assert-PshGoal5Entry (@($script:Goal5AcquisitionSeen | Where-Object { $_ -match '/v1\.2\.3/' }).Count -ge 1) 'Package acquisition did not use a fixed-tag URI.'
    Assert-PshGoal5Entry ([string]$coreResult.edition -ceq 'Core') 'Core was not the online default edition.'
    Assert-PshGoal5Entry ($script:Goal5MembershipVerifierCalls -eq 2 -and $script:Goal5VerifierCalls -eq 0) 'Online hash-policy trust did not use exactly the release and package catalog membership verifiers.'

    $script:Goal5OnlineSeen.Clear(); $script:Goal5AcquisitionSeen.Clear()
    Set-PshGoal5OnlineTransportFixture -Fixture $script:Goal5Fixture
    $fullResult = @(Invoke-PshOnlineInstall -Edition Full -Version 1.2.3 -NonInteractive)[-1]
    Assert-PshGoal5Entry ([bool]$fullResult.success -and [string]$fullResult.edition -ceq 'Full') 'Online Full installation did not select the Full asset.'
    Assert-PshGoal5Entry (@($script:Goal5AcquisitionSeen | Where-Object { $_ -match 'full-win-x64' }).Count -ge 1) 'Online Full did not acquire the x64 package.'

    Set-PshGoal5OnlineTransportFixture -Fixture $script:Goal5Fixture -BadTag
    Assert-PshGoal5Failure -Action { Invoke-PshOnlineInstall -Edition Core -Version latest -NonInteractive } -ExitCode 5 -ErrorId 'PshReleaseMetadataAsset'
    Set-PshGoal5OnlineTransportFixture -Fixture $script:Goal5Fixture -BadTrustDigest
    Assert-PshGoal5Failure -Action { Invoke-PshOnlineInstall -Edition Core -Version 1.2.3 -NonInteractive } -ExitCode 5 -ErrorId 'PshReleaseMetadataDigestMismatch'
    Set-PshGoal5OnlineTransportFixture -Fixture $script:Goal5Fixture -BadReleaseCatalogMembership
    Assert-PshGoal5Failure -Action { Invoke-PshOnlineInstall -Edition Core -Version 1.2.3 -NonInteractive } -ExitCode 5 -ErrorId 'PshCatalogContent'
    Set-PshGoal5OnlineTransportFixture -Fixture $script:Goal5Fixture -CorruptPackage
    Assert-PshGoal5Failure -Action { Invoke-PshOnlineInstall -Edition Core -Version 1.2.3 -NonInteractive } -ExitCode 5
    Set-PshGoal5OnlineTransportFixture -Fixture $script:Goal5Fixture -BadRedirect
    Assert-PshGoal5Failure -Action { Invoke-PshOnlineInstall -Edition Core -Version 1.2.3 -NonInteractive } -ExitCode 5

    # Keep the fixture source ASCII while retaining Unicode path coverage.
    $unicodeChinese = ([string][char]0x4E2D) + ([string][char]0x6587)
    $unicodePath = ([string][char]0x8DEF) + ([string][char]0x5F84)
    $unicodeSpace = ([string][char]0x7A7A) + ([string][char]0x683C)
    $offlineRoot = Join-Path $script:TestRoot ($unicodeChinese + ' ' + $unicodePath + '/offline-one')
    $offlinePackage = New-PshGoal5EntryPackage -Root $offlineRoot -Version '0.0.1-test' -Edition Core -RealOffline
    . (Join-Path $offlineRoot 'install-offline.ps1')
    Set-PshGoal5TrustMocks
    $script:Goal5OnlineSeen.Clear(); $script:Goal5AcquisitionSeen.Clear()
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Core -Version latest -NonInteractive } -ExitCode 4 -ErrorId 'PshOfflineArchiveEvidenceRequired'
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Core -Version latest -NonInteractive -ArchivePath $offlinePackage.ArchivePath -ArchiveSha256 ('f' * 64) } -ExitCode 5 -ErrorId 'PshOfflineArchiveHashMismatch'
    $offlineResult = @(Invoke-PshOfflineInstall -Edition Core -Version latest -NonInteractive -ArchivePath $offlinePackage.ArchivePath -ArchiveSha256 ([string]$offlinePackage.ArchiveSha256).ToUpperInvariant())[-1]
    Assert-PshGoal5Entry ([bool]$offlineResult.success -and [string]$offlineResult.version -ceq '0.0.1-test') 'Offline installation did not complete.'
    Assert-PshGoal5Entry ([string]$offlineResult.trust.trustMode -ceq 'offline-external-archive-sha256+package-catalog-sha256' -and
        [string]$offlineResult.trust.checksum -ceq 'external-archive-manifest-tree-sha256-verified' -and
        [string]$offlineResult.trust.catalogMembership -ceq 'verified' -and [bool]$offlineResult.trust.signatureNotRequired -and
        [string]$offlineResult.trust.archiveBinding -ceq 'verified' -and [string]$offlineResult.trust.archiveSha256 -ceq [string]$offlinePackage.ArchiveSha256 -and
        [bool]$offlineResult.trust.attestationRequiredAtPublish -and
        [string]$offlineResult.trust.attestationVerification -ceq 'not-verified-at-runtime') 'Offline installation did not report the external archive/hash/catalog trust mode honestly.'
    Assert-PshGoal5Entry ($script:Goal5OnlineSeen.Count -eq 0 -and $script:Goal5AcquisitionSeen.Count -eq 0) 'Offline installation touched a transport.'
    $offlineLog = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-PshGoal5Entry ($offlineLog.Count -ge 1 -and -not [bool]$offlineLog[-1].catalogPresent) 'The package manifest catalog sidecar entered the lifecycle PackageRoot.'

    $offlineTwoRoot = Join-Path $script:TestRoot 'offline-two'
    $offlineTwo = New-PshGoal5EntryPackage -Root $offlineTwoRoot -Version '0.0.2-test' -Edition Core -RealOffline
    . (Join-Path $offlineTwoRoot 'install-offline.ps1')
    Set-PshGoal5TrustMocks
    [void](Invoke-PshOfflineInstall -Edition Core -Version 0.0.2-test -NonInteractive -ArchivePath $offlineTwo.ArchivePath -ArchiveSha256 $offlineTwo.ArchiveSha256)
    . (Join-Path $offlineRoot 'install-offline.ps1')
    Set-PshGoal5TrustMocks
    [void](Invoke-PshOfflineInstall -Edition Core -Version 0.0.1-test -NonInteractive -ArchivePath $offlinePackage.ArchivePath -ArchiveSha256 $offlinePackage.ArchiveSha256)
    $sequence = @(Get-Content -LiteralPath $logPath | ForEach-Object { ($_ | ConvertFrom-Json).version })
    Assert-PshGoal5Entry (@($sequence | Where-Object { $_ -in @('0.0.1-test', '0.0.2-test') }).Count -ge 3) 'Repeat/upgrade/rollback entry sequencing was not exercised.'
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Full -Version 0.0.1-test -NonInteractive -ArchivePath $offlinePackage.ArchivePath -ArchiveSha256 $offlinePackage.ArchiveSha256 } -ExitCode 5 -ErrorId 'PshOfflineEditionMismatch'

    $manifestTamper = New-PshGoal5EntryPackage -Root (Join-Path $script:TestRoot 'offline-manifest-tamper') -Version '0.0.3-test' -Edition Core -RealOffline
    [IO.File]::AppendAllText($manifestTamper.ManifestPath, " `n", $script:Utf8)
    Set-PshGoal5PackageArchiveEvidence -Package $manifestTamper
    . (Join-Path $manifestTamper.Root 'install-offline.ps1')
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Core -Version 0.0.3-test -NonInteractive -ArchivePath $manifestTamper.ArchivePath -ArchiveSha256 $manifestTamper.ArchiveSha256 } -ExitCode 5 -ErrorId 'PshCatalogContent'

    $catalogTamper = New-PshGoal5EntryPackage -Root (Join-Path $script:TestRoot 'offline-catalog-tamper') -Version '0.0.4-test' -Edition Core -RealOffline
    [IO.File]::AppendAllText($catalogTamper.CatalogPath, 'tamper', $script:Utf8)
    Set-PshGoal5PackageArchiveEvidence -Package $catalogTamper
    . (Join-Path $catalogTamper.Root 'install-offline.ps1')
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Core -Version 0.0.4-test -NonInteractive -ArchivePath $catalogTamper.ArchivePath -ArchiveSha256 $catalogTamper.ArchiveSha256 } -ExitCode 5 -ErrorId 'PshCatalogContent'

    $payloadTamper = New-PshGoal5EntryPackage -Root (Join-Path $script:TestRoot 'offline-payload-tamper') -Version '0.0.5-test' -Edition Core -RealOffline
    $payloadTamperPath = Join-Path $payloadTamper.Root 'payload/Psh/Psh.psm1'
    $payloadTamperBytes = [IO.File]::ReadAllBytes($payloadTamperPath)
    $payloadTamperBytes[0] = $payloadTamperBytes[0] -bxor 1
    [IO.File]::WriteAllBytes($payloadTamperPath, $payloadTamperBytes)
    . (Join-Path $payloadTamper.Root 'install-offline.ps1')
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Core -Version 0.0.5-test -NonInteractive -ArchivePath $payloadTamper.ArchivePath -ArchiveSha256 $payloadTamper.ArchiveSha256 } -ExitCode 5 -ErrorId 'PshOfflineArchiveEntryHash'

    $payloadManifestMismatch = New-PshGoal5EntryPackage -Root (Join-Path $script:TestRoot 'offline-payload-manifest-mismatch') -Version '0.0.5-test.1' -Edition Core -RealOffline
    $payloadManifestMismatchPath = Join-Path $payloadManifestMismatch.Root 'payload/Psh/Psh.psm1'
    $payloadManifestMismatchBytes = [IO.File]::ReadAllBytes($payloadManifestMismatchPath)
    $payloadManifestMismatchBytes[0] = $payloadManifestMismatchBytes[0] -bxor 1
    [IO.File]::WriteAllBytes($payloadManifestMismatchPath, $payloadManifestMismatchBytes)
    Set-PshGoal5PackageArchiveEvidence -Package $payloadManifestMismatch
    . (Join-Path $payloadManifestMismatch.Root 'install-offline.ps1')
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Core -Version 0.0.5-test.1 -NonInteractive -ArchivePath $payloadManifestMismatch.ArchivePath -ArchiveSha256 $payloadManifestMismatch.ArchiveSha256 } -ExitCode 5 -ErrorId 'PshOfflineFileHash'

    $archiveExtra = New-PshGoal5EntryPackage -Root (Join-Path $script:TestRoot 'offline-archive-extra') -Version '0.0.5-test.2' -Edition Core -RealOffline
    Write-PshGoal5Text -Path (Join-Path $archiveExtra.Root 'unexpected.txt') -Text 'unexpected'
    . (Join-Path $archiveExtra.Root 'install-offline.ps1')
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Core -Version 0.0.5-test.2 -NonInteractive -ArchivePath $archiveExtra.ArchivePath -ArchiveSha256 $archiveExtra.ArchiveSha256 } -ExitCode 5 -ErrorId 'PshOfflineArchivePackageExtraFile'

    $archiveMissing = New-PshGoal5EntryPackage -Root (Join-Path $script:TestRoot 'offline-archive-missing') -Version '0.0.5-test.3' -Edition Core -RealOffline
    [IO.File]::Delete((Join-Path $archiveMissing.Root 'payload/Psh/Psh.psm1'))
    . (Join-Path $archiveMissing.Root 'install-offline.ps1')
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Core -Version 0.0.5-test.3 -NonInteractive -ArchivePath $archiveMissing.ArchivePath -ArchiveSha256 $archiveMissing.ArchiveSha256 } -ExitCode 5 -ErrorId 'PshOfflineArchivePackageMissingFile'

    $missingCatalog = New-PshGoal5EntryPackage -Root (Join-Path $script:TestRoot 'offline-missing-catalog') -Version '0.0.6-test' -Edition Core -RealOffline
    [IO.File]::Delete($missingCatalog.CatalogPath)
    Set-PshGoal5PackageArchiveEvidence -Package $missingCatalog
    . (Join-Path $missingCatalog.Root 'install-offline.ps1')
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Core -Version 0.0.6-test -NonInteractive -ArchivePath $missingCatalog.ArchivePath -ArchiveSha256 $missingCatalog.ArchiveSha256 } -ExitCode 5 -ErrorId 'PshOfflineTrustAssetsMissing'

    $missingManifest = New-PshGoal5EntryPackage -Root (Join-Path $script:TestRoot 'offline-missing-manifest') -Version '0.0.6-test.1' -Edition Core -RealOffline
    [IO.File]::Delete($missingManifest.ManifestPath)
    Set-PshGoal5PackageArchiveEvidence -Package $missingManifest
    . (Join-Path $missingManifest.Root 'install-offline.ps1')
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Core -Version 0.0.6-test.1 -NonInteractive -ArchivePath $missingManifest.ArchivePath -ArchiveSha256 $missingManifest.ArchiveSha256 } -ExitCode 5 -ErrorId 'PshOfflineTrustAssetsMissing'

    $wrongRepository = New-PshGoal5EntryPackage -Root (Join-Path $script:TestRoot 'offline-wrong-repository') -Version '0.0.7-test' -Edition Core -RealOffline
    $wrongRepository.Manifest.source.repository = 'https://example.invalid/Emvdy/psh'
    Write-PshGoal5Json -Path $wrongRepository.ManifestPath -Value $wrongRepository.Manifest
    [void](New-PshGoal5CatalogForFiles -Paths @($wrongRepository.ManifestPath) -CatalogPath $wrongRepository.CatalogPath)
    Set-PshGoal5PackageArchiveEvidence -Package $wrongRepository
    . (Join-Path $wrongRepository.Root 'install-offline.ps1')
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Core -Version 0.0.7-test -NonInteractive -ArchivePath $wrongRepository.ArchivePath -ArchiveSha256 $wrongRepository.ArchiveSha256 } -ExitCode 5 -ErrorId 'PshManifestSourceMismatch'

    $shellFixture = Join-Path $script:TestRoot ($unicodeChinese + ' ' + $unicodeSpace + '/shell')
    [IO.Directory]::CreateDirectory($shellFixture) | Out-Null
    $shellScriptPath = Join-Path $shellFixture 'install.sh'
    $shellOfflineFixturePath = Join-Path $shellFixture 'install-offline.ps1'
    Copy-Item -LiteralPath $shellPath -Destination $shellScriptPath
    Write-PshGoal5Text -Path $shellOfflineFixturePath -Text @'
[CmdletBinding()]
param([string]$Edition = 'Core', [string]$Version = 'latest', [switch]$NonInteractive, [string]$ArchivePath, [string]$ArchiveSha256)
$entryPath = [IO.Path]::GetFullPath([string]$MyInvocation.MyCommand.Path)
$writeDenied = $false
$writeProbe = $null
try { $writeProbe = New-Object IO.FileStream($entryPath, ([IO.FileMode]::Open), ([IO.FileAccess]::Write), ([IO.FileShare]::ReadWrite)) }
catch { $writeDenied = $true }
finally { if ($null -ne $writeProbe) { $writeProbe.Dispose() } }
$record = [ordered]@{ edition = $Edition; version = $Version; nonInteractive = [bool]$NonInteractive; archivePath = $ArchivePath; archiveSha256 = $ArchiveSha256; entryPath = $entryPath; writeDenied = $writeDenied }
[IO.File]::AppendAllText([string]$env:PSH_SHELL_TEST_CHILD_LOG, (($record | ConvertTo-Json -Compress) + "`n"), (New-Object Text.UTF8Encoding($false)))
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and -not $writeDenied) { exit 91 }
exit 7
'@
    $bashPath = Get-PshGoal5ShellApplication -Name bash
    $shPath = Get-PshGoal5ShellApplication -Name sh
    Assert-PshGoal5Entry (-not [string]::IsNullOrWhiteSpace($bashPath) -and -not [string]::IsNullOrWhiteSpace($shPath)) 'bash and sh are required dependencies for the shell entry contract.'
    & $bashPath -n $shellScriptPath
    Assert-PshGoal5Entry ([int]$LASTEXITCODE -eq 0) 'bash -n rejected install.sh.'
    & $shPath -n $shellScriptPath
    Assert-PshGoal5Entry ([int]$LASTEXITCODE -eq 0) 'sh -n rejected install.sh.'

    $quoteCharacter = [string][char]34
    $slashCharacter = [string][char]92
    $argumentValues = @(
        'plain',
        ('space ' + $unicodeChinese),
        ('embedded' + $quoteCharacter + 'quote'),
        ('C:' + $slashCharacter + 'space path' + $slashCharacter)
    )
    $argumentRecorderPath = Join-Path $shellFixture 'argument recorder.ps1'
    $argumentRecordPath = Join-Path $shellFixture 'argument record.json'
    Write-PshGoal5Text -Path $argumentRecorderPath -Text @'
[CmdletBinding()]
param([string]$One, [string]$Two, [string]$Three, [string]$Four, [string]$OutputPath)
$record = [ordered]@{ values = @($One, $Two, $Three, $Four) }
[IO.File]::WriteAllText($OutputPath, (($record | ConvertTo-Json -Compress) + "`n"), (New-Object Text.UTF8Encoding($false)))
'@
    $argumentProcessValues = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $argumentRecorderPath) + $argumentValues + @($argumentRecordPath)
    $argumentStartInfo = New-Object Diagnostics.ProcessStartInfo
    $argumentStartInfo.FileName = [string](Get-Process -Id $PID).Path
    $argumentStartInfo.Arguments = [string]::Join(' ', @($argumentProcessValues | ForEach-Object { ConvertTo-PshShellProcessArgument -Value ([string]$_) }))
    $argumentStartInfo.UseShellExecute = $false
    $argumentProcess = New-Object Diagnostics.Process
    $argumentProcess.StartInfo = $argumentStartInfo
    try {
        Assert-PshGoal5Entry ([bool]$argumentProcess.Start()) 'Unable to start the shell Win32 argument quoting probe.'
        $argumentProcess.WaitForExit()
        Assert-PshGoal5Entry ([int]$argumentProcess.ExitCode -eq 0) 'Shell Win32 argument quoting probe returned a nonzero exit code.'
    }
    finally { $argumentProcess.Dispose() }
    $argumentRecord = [IO.File]::ReadAllText($argumentRecordPath, $script:Utf8) | ConvertFrom-Json
    Assert-PshGoal5Entry (@($argumentRecord.values).Count -eq $argumentValues.Count -and
        [string]$argumentRecord.values[0] -ceq $argumentValues[0] -and [string]$argumentRecord.values[1] -ceq $argumentValues[1] -and
        [string]$argumentRecord.values[2] -ceq $argumentValues[2] -and [string]$argumentRecord.values[3] -ceq $argumentValues[3]) 'Shell Win32 argument quoting changed a plain, Unicode/space, quoted, or trailing-backslash value.'

    $windowsPowerShellPath = [string](Get-Command -Name powershell.exe -CommandType Application -ErrorAction Stop).Source
    $windowsPowerShellBashPath = ConvertTo-PshGoal5BashPath -BashPath $bashPath -Path $windowsPowerShellPath
    $realCygpath = @(& $bashPath -c 'command -v cygpath')
    Assert-PshGoal5Entry ($realCygpath.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$realCygpath[0])) 'Git Bash cygpath is required for the Win32 shell path contract.'
    $realCygpathBashPath = ([string]$realCygpath[0]).TrimEnd("`r", "`n")
    $fakeBin = Join-Path $script:TestRoot 'fake-bin'
    [IO.Directory]::CreateDirectory($fakeBin) | Out-Null
    $fakeCurl = Join-Path $fakeBin 'curl'
    Write-PshGoal5Text -Path $fakeCurl -Text @'
#!/usr/bin/env bash
output=''
write_out=''
url=''
while (($# > 0)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --write-out) write_out="$2"; shift 2 ;;
    --max-redirs|--retry|--retry-delay|--connect-timeout|--max-time|--max-filesize|--proto|--proto-redir) shift 2 ;;
    --fail|--silent|--show-error|--location|--retry-all-errors) shift ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "$PSH_FAKE_CURL_LOG"
case "$url" in
  https://api.github.com/repos/Emvdy/psh/releases/latest|https://api.github.com/repos/Emvdy/psh/releases/tags/*)
    cp -- "$PSH_FAKE_RELEASE_METADATA" "$output" || exit 23
    case "$write_out" in
      *http_code*) printf '200|%s' "$url" ;;
      *) printf '%s' "$url" ;;
    esac
    ;;
  https://github.com/Emvdy/psh/releases/download/*/install.ps1)
    cp -- "$PSH_FAKE_ENTRY_SOURCE" "$output" || exit 23
    printf '%s' "$url"
    ;;
  *) exit 22 ;;
esac
'@
    $oldPath = $env:PATH
    $env:PATH = "$fakeBin$([IO.Path]::PathSeparator)$oldPath"
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    $shellWindowsTemp = Join-Path $script:TestRoot ($unicodeChinese + ' ' + $unicodeSpace + ' windows-temp')
    [IO.Directory]::CreateDirectory($shellWindowsTemp) | Out-Null
    $env:TEMP = $shellWindowsTemp
    $env:TMP = $shellWindowsTemp
    $shellChildLogPath = Join-Path $script:TestRoot 'shell-child.log'
    $shellCurlLogPath = Join-Path $script:TestRoot 'shell-curl.log'
    [IO.File]::WriteAllText($shellChildLogPath, '', $script:Utf8)
    [IO.File]::WriteAllText($shellCurlLogPath, '', $script:Utf8)
    $env:PSH_SHELL_TEST_CHILD_LOG = $shellChildLogPath
    $env:PSH_FAKE_CURL_LOG = ConvertTo-PshGoal5BashPath -BashPath $bashPath -Path $shellCurlLogPath

    function Assert-PshGoal5NoShellTempRoot {
        param([Parameter(Mandatory = $true)][string] $Label)
        $roots = @(Get-ChildItem -LiteralPath $shellWindowsTemp -Force -ErrorAction Stop | Where-Object { $_.Name -cmatch '\Apsh-install-[0-9a-f]{32}\z' })
        Assert-PshGoal5Entry ($roots.Count -eq 0) "$Label left a controlled psh-install Windows TEMP root behind."
    }

    $shellArchiveArgument = ConvertTo-PshGoal5BashPath -BashPath $bashPath -Path $offlinePackage.ArchivePath
    $shellArchiveShaUpper = ([string]$offlinePackage.ArchiveSha256).ToUpperInvariant()
    & $bashPath $shellScriptPath --offline --edition Full --version '1.2.3' --archive-path $shellArchiveArgument --archive-sha256 $shellArchiveShaUpper --non-interactive
    $shellExit = [int]$LASTEXITCODE
    Assert-PshGoal5Entry ($shellExit -eq 7) 'Shell locked parent did not preserve the offline child exit code.'
    $shellChildRecords = @([IO.File]::ReadAllLines($shellChildLogPath, $script:Utf8) | ForEach-Object { $_ | ConvertFrom-Json })
    $offlineShellChild = $shellChildRecords[-1]
    Assert-PshGoal5Entry ([bool]$offlineShellChild.writeDenied -and [string]$offlineShellChild.edition -ceq 'Full' -and
        [string]$offlineShellChild.version -ceq '1.2.3' -and [bool]$offlineShellChild.nonInteractive) 'Shell locked parent did not keep the offline entry write-denied or preserve its named arguments.'
    Assert-PshGoal5Entry ([string]$offlineShellChild.archivePath -ieq [IO.Path]::GetFullPath($offlinePackage.ArchivePath) -and
        [string]$offlineShellChild.archiveSha256 -ceq [string]$offlinePackage.ArchiveSha256) 'Shell locked parent split the Unicode/space archive path or failed to normalize its SHA256.'
    Assert-PshGoal5NoShellTempRoot -Label 'Offline shell success'
    & $bashPath $shellScriptPath --help | Out-Null
    Assert-PshGoal5Entry ([int]$LASTEXITCODE -eq 0) 'Shell help did not return zero.'

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        foreach ($shellUsageCase in @(
                @{ Arguments = @('--edition', 'Invalid'); Label = 'invalid edition' },
                @{ Arguments = @('--version', '1.2.3-01'); Label = 'leading-zero prerelease' },
                @{ Arguments = @('--version', '1.2.3-1-2'); Label = 'letterless nonnumeric prerelease' },
                @{ Arguments = @('--offline'); Label = 'offline without archive evidence' },
                @{ Arguments = @('--offline', '--archive-path'); Label = 'missing archive path value' },
                @{ Arguments = @('--offline', '--archive-path', $shellArchiveArgument); Label = 'offline with only archive path' },
                @{ Arguments = @('--offline', '--archive-sha256', $shellArchiveShaUpper); Label = 'offline with only archive SHA256' },
                @{ Arguments = @('--archive-path', $shellArchiveArgument, '--archive-sha256', $shellArchiveShaUpper); Label = 'online archive evidence misuse' },
                @{ Arguments = @('--offline', '--archive-path', $shellArchiveArgument, '--archive-sha256', ('g' * 64)); Label = 'nonhex archive SHA256' }
            )) {
            & $bashPath $shellScriptPath @($shellUsageCase.Arguments) 2>$null | Out-Null
            Assert-PshGoal5Entry ([int]$LASTEXITCODE -eq 2) ("Shell {0} did not return structured usage code 2." -f $shellUsageCase.Label)
        }
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }

    $shellEntrySource = Join-Path $script:TestRoot 'shell-online-entry.ps1'
    Copy-Item -LiteralPath $shellOfflineFixturePath -Destination $shellEntrySource
    $shellEntrySha = Get-PshGoal5HashFile -Path $shellEntrySource
    $shellEntryLength = [int64]([IO.FileInfo]$shellEntrySource).Length
    $shellEntryUrl = 'https://github.com/Emvdy/psh/releases/download/v1.2.3/install.ps1'
    $shellAsset = [ordered]@{ name = 'install.ps1'; digest = ('sha256:' + $shellEntrySha); size = $shellEntryLength; browser_download_url = $shellEntryUrl }
    $shellReleaseMetadataPath = Join-Path $script:TestRoot 'shell-release.json'
    Write-PshGoal5Json -Path $shellReleaseMetadataPath -Value ([ordered]@{ tag_name = 'v1.2.3'; draft = $false; prerelease = $false; assets = @($shellAsset) })
    $env:PSH_FAKE_RELEASE_METADATA = ConvertTo-PshGoal5BashPath -BashPath $bashPath -Path $shellReleaseMetadataPath
    $env:PSH_FAKE_ENTRY_SOURCE = ConvertTo-PshGoal5BashPath -BashPath $bashPath -Path $shellEntrySource
    [IO.File]::WriteAllText($shellCurlLogPath, '', $script:Utf8)

    & $bashPath $shellScriptPath --edition Core --version '1.2.3' --non-interactive
    Assert-PshGoal5Entry ([int]$LASTEXITCODE -eq 7) 'Shell fixed-version online entry did not preserve the verified child exit code.'
    $shellCurlLog = @([IO.File]::ReadAllLines($shellCurlLogPath, $script:Utf8))
    Assert-PshGoal5Entry (@($shellCurlLog | Where-Object { $_ -ceq 'https://api.github.com/repos/Emvdy/psh/releases/tags/v1.2.3' }).Count -eq 1 -and
        @($shellCurlLog | Where-Object { $_ -ceq $shellEntryUrl }).Count -eq 1) 'Shell fixed-version flow did not use the exact API and fixed-tag asset URLs.'
    $shellChildRecords = @([IO.File]::ReadAllLines($shellChildLogPath, $script:Utf8) | ForEach-Object { $_ | ConvertFrom-Json })
    $onlineShellChild = $shellChildRecords[-1]
    Assert-PshGoal5Entry ([bool]$onlineShellChild.writeDenied -and [string]$onlineShellChild.edition -ceq 'Core' -and
        [string]$onlineShellChild.version -ceq '1.2.3' -and [string]::IsNullOrEmpty([string]$onlineShellChild.archivePath)) 'Shell online child was not write-denied or received offline-only evidence.'
    Assert-PshGoal5Entry (([string]$onlineShellChild.entryPath).StartsWith($shellWindowsTemp, [StringComparison]::OrdinalIgnoreCase) -and
        [string]$onlineShellChild.entryPath -match '(?i)[\\/]psh-install-[0-9a-f]{32}[\\/]install\.ps1\z') 'Shell online entry was not executed from the controlled Unicode/space Windows TEMP path.'
    Assert-PshGoal5NoShellTempRoot -Label 'Fixed-version online shell success'

    [IO.File]::WriteAllText($shellCurlLogPath, '', $script:Utf8)
    & $bashPath $shellScriptPath --version latest
    Assert-PshGoal5Entry ([int]$LASTEXITCODE -eq 7) 'Shell latest online entry did not preserve the verified child exit code.'
    $shellLatestCurlLog = @([IO.File]::ReadAllLines($shellCurlLogPath, $script:Utf8))
    Assert-PshGoal5Entry (@($shellLatestCurlLog | Where-Object { $_ -ceq 'https://api.github.com/repos/Emvdy/psh/releases/latest' }).Count -eq 1 -and
        @($shellLatestCurlLog | Where-Object { $_ -ceq $shellEntryUrl }).Count -eq 1) 'Shell latest flow did not resolve metadata first and then download the fixed-tag asset.'
    Assert-PshGoal5NoShellTempRoot -Label 'Latest online shell success'

    $shellTamperedEntry = Join-Path $script:TestRoot 'shell-online-entry-tampered.ps1'
    Write-PshGoal5Text -Path $shellTamperedEntry -Text "# tampered`n"
    $env:PSH_FAKE_ENTRY_SOURCE = ConvertTo-PshGoal5BashPath -BashPath $bashPath -Path $shellTamperedEntry
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & $bashPath $shellScriptPath --version '1.2.3' 2>$null | Out-Null
        $shellDigestExit = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }
    Assert-PshGoal5Entry ($shellDigestExit -eq 5) 'Shell online entry did not reject downloaded bytes that disagreed with the authenticated asset digest.'
    Assert-PshGoal5NoShellTempRoot -Label 'Tampered online shell failure'

    $shellDuplicateMetadataPath = Join-Path $script:TestRoot 'shell-release-duplicate.json'
    Write-PshGoal5Json -Path $shellDuplicateMetadataPath -Value ([ordered]@{ tag_name = 'v1.2.3'; draft = $false; prerelease = $false; assets = @($shellAsset, $shellAsset) })
    $env:PSH_FAKE_RELEASE_METADATA = ConvertTo-PshGoal5BashPath -BashPath $bashPath -Path $shellDuplicateMetadataPath
    $env:PSH_FAKE_ENTRY_SOURCE = ConvertTo-PshGoal5BashPath -BashPath $bashPath -Path $shellEntrySource
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & $bashPath $shellScriptPath --version '1.2.3' 2>$null | Out-Null
        $shellDuplicateAssetExit = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }
    Assert-PshGoal5Entry ($shellDuplicateAssetExit -eq 5) 'Shell online entry did not reject duplicate install.ps1 assets in GitHub release metadata.'
    Assert-PshGoal5NoShellTempRoot -Label 'Duplicate-metadata shell failure'

    $env:PSH_FAKE_RELEASE_METADATA = ConvertTo-PshGoal5BashPath -BashPath $bashPath -Path $shellReleaseMetadataPath
    $fakePowerShell = Join-Path $fakeBin 'powershell.exe'
    Write-PshGoal5Text -Path $fakePowerShell -Text @'
#!/usr/bin/env bash
exec "$PSH_FAKE_REAL_POWERSHELL" "$@"
'@
    $env:PSH_FAKE_REAL_POWERSHELL = $windowsPowerShellBashPath
    $shellChildStartError = Join-Path $script:TestRoot 'shell-child-start-error.log'
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & $bashPath $shellScriptPath --version '1.2.3' 2>$shellChildStartError | Out-Null
        $shellChildStartExit = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }
    Assert-PshGoal5Entry ($shellChildStartExit -eq 3 -and [IO.File]::ReadAllText($shellChildStartError, $script:Utf8) -match 'PshShellChildStart') 'Shell child-start failure did not return structured IO exit code 3.'
    Assert-PshGoal5NoShellTempRoot -Label 'Child-start shell failure'
    [IO.File]::Delete($fakePowerShell)

    $fakeCygpath = Join-Path $fakeBin 'cygpath'
    Write-PshGoal5Text -Path $fakeCygpath -Text @'
#!/usr/bin/env bash
if [[ "$1" == '-u' ]]; then exit 37; fi
exec "$PSH_FAKE_REAL_CYGPATH" "$@"
'@
    $env:PSH_FAKE_REAL_CYGPATH = $realCygpathBashPath
    $shellMappingError = Join-Path $script:TestRoot 'shell-mapping-error.log'
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & $bashPath $shellScriptPath --version '1.2.3' 2>$shellMappingError | Out-Null
        $shellMappingExit = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }
    Assert-PshGoal5Entry ($shellMappingExit -eq 3 -and [IO.File]::ReadAllText($shellMappingError, $script:Utf8) -match 'PshShellPath') 'Shell Win32-to-Bash mapping failure did not return structured path exit code 3.'
    Assert-PshGoal5NoShellTempRoot -Label 'Win32 path-mapping shell failure'

    $report = [pscustomobject][ordered]@{ schemaVersion = 1; assertions = $script:Assertions; onlineUris = @($script:Goal5OnlineSeen); acquisitionUris = @($script:Goal5AcquisitionSeen); offlineLog = $sequence }
    Write-PshGoal5Json -Path (Join-Path $reportRoot 'Goal5.OnlineOffline.summary.json') -Value $report
    Write-Output ('Goal 5 online/offline acceptance passed ({0} assertions).' -f $script:Assertions)
}
finally {
    if ($null -ne $oldArchitecture) { $env:PROCESSOR_ARCHITECTURE = $oldArchitecture } else { Remove-Item Env:PROCESSOR_ARCHITECTURE -ErrorAction SilentlyContinue }
    if ($null -ne $oldPath) { $env:PATH = $oldPath }
    if ($null -ne $oldTemp) { $env:TEMP = $oldTemp } else { Remove-Item Env:TEMP -ErrorAction SilentlyContinue }
    if ($null -ne $oldTmp) { $env:TMP = $oldTmp } else { Remove-Item Env:TMP -ErrorAction SilentlyContinue }
    Remove-Item Env:PSH_GOAL5_ENTRY_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_SHELL_TEST_CHILD_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_FAKE_CURL_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_FAKE_REAL_POWERSHELL -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_FAKE_REAL_CYGPATH -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_FAKE_RELEASE_METADATA -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_FAKE_ENTRY_SOURCE -ErrorAction SilentlyContinue
    Set-Item -Path Function:\Invoke-PshOnlineHttpRequest -Value $onlineTransportOriginal -ErrorAction SilentlyContinue
    Set-Item -Path Function:\Invoke-PshAcquisitionHttpRequest -Value $acquisitionTransportOriginal -ErrorAction SilentlyContinue
    Set-Item -Path Function:\Get-PshProductionPublisherPolicy -Value $policyOriginal -ErrorAction SilentlyContinue
    Set-Item -Path Function:\Invoke-PshWindowsCatalogTrustVerifier -Value $verifierOriginal -ErrorAction SilentlyContinue
    Set-Item -Path Function:\Invoke-PshWindowsCatalogMembershipVerifier -Value $membershipVerifierOriginal -ErrorAction SilentlyContinue
    if ([IO.Directory]::Exists($script:TestRoot)) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
