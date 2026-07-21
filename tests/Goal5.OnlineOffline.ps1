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
param([string]$Edition = 'Core', [string]$Version = 'latest', [switch]$NonInteractive)
function Invoke-PshOfflineInstall {
    param([string]$Edition = 'Core', [string]$Version = 'latest', [switch]$NonInteractive, [string]$ArchiveSha256)
    $log = [string]$env:PSH_GOAL5_ENTRY_LOG
    if (-not [string]::IsNullOrWhiteSpace($log)) {
        [IO.File]::AppendAllText($log, (([ordered]@{ edition = $Edition; version = $Version; nonInteractive = [bool]$NonInteractive; archiveSha256 = $ArchiveSha256 }) | ConvertTo-Json -Compress) + "`n", (New-Object Text.UTF8Encoding($false)))
    }
    return [pscustomobject][ordered]@{ success = $true; code = 0; edition = $Edition; version = $Version; archiveSha256 = $ArchiveSha256 }
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
    Write-PshGoal5Json -Path (Join-Path $Root 'package.manifest.json') -Value $manifest
    Write-PshGoal5Text -Path (Join-Path $Root 'package.manifest.cat') -Text "fixture catalog $Version $Edition`n"
    return [pscustomobject][ordered]@{ Root = $Root; Manifest = $manifest; ManifestPath = (Join-Path $Root 'package.manifest.json'); ManifestSha256 = Get-PshGoal5HashFile -Path (Join-Path $Root 'package.manifest.json'); TreeSha256 = $treeSha; Edition = $Edition; Version = $Version; Architecture = $Architecture }
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
    Write-PshGoal5Text -Path $catalogPath -Text "release catalog $version`n"
    $policy = [pscustomobject][ordered]@{ schemaVersion = 1; publisher = 'Emvdy Software'; subjectDistinguishedNames = @('CN=Emvdy Software, O=Emvdy'); requiredEkuOids = @('1.3.6.1.5.5.7.3.3'); requiredCertificatePolicyOids = @(); allowedRootCertificateSha256 = @('a' * 64) }
    return [pscustomobject][ordered]@{ Root = $Root; Version = $version; IndexPath = $indexPath; ChecksumPath = $checksumPath; CatalogPath = $catalogPath; Index = $index; Assets = $assets; Core = $core; Full = $full; CoreBytes = $coreBytes; FullBytes = $fullBytes; Policy = $policy }
}

function Add-PshGoal5ResponseQueue {
    param([Parameter(Mandatory = $true)][hashtable] $Map, [Parameter(Mandatory = $true)][string] $Uri, [Parameter(Mandatory = $true)][object] $Response)
    if (-not $Map.ContainsKey($Uri)) { $Map[$Uri] = New-Object System.Collections.ArrayList }
    [void]$Map[$Uri].Add($Response)
}

function Set-PshGoal5OnlineTransportFixture {
    param([Parameter(Mandatory = $true)][object] $Fixture, [switch] $CorruptPackage, [switch] $BadRedirect, [switch] $BadTag)
    $script:Goal5OnlineMap = @{}
    $script:Goal5AcquisitionMap = @{}
    $apiBytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json ([ordered]@{ tag_name = if ($BadTag) { 'v9.9.9' } else { 'v1.2.3' }; draft = $false; prerelease = $false }) -Compress))
    Add-PshGoal5ResponseQueue -Map $script:Goal5OnlineMap -Uri 'https://api.github.com/repos/Emvdy/psh/releases/latest' -Response (New-PshGoal5Response 502 'https://api.github.com/repos/Emvdy/psh/releases/latest' -Bytes ([byte[]]::new(0)))
    Add-PshGoal5ResponseQueue -Map $script:Goal5OnlineMap -Uri 'https://api.github.com/repos/Emvdy/psh/releases/latest' -Response (New-PshGoal5Response 200 'https://api.github.com/repos/Emvdy/psh/releases/latest' -Bytes $apiBytes)
    foreach ($path in @($Fixture.IndexPath, $Fixture.ChecksumPath, $Fixture.CatalogPath)) {
        $uri = if ($path -ceq $Fixture.IndexPath) { "https://github.com/Emvdy/psh/releases/download/v1.2.3/psh-release-1.2.3.json" } elseif ($path -ceq $Fixture.ChecksumPath) { 'https://github.com/Emvdy/psh/releases/download/v1.2.3/SHA256SUMS' } else { 'https://github.com/Emvdy/psh/releases/download/v1.2.3/psh-release-1.2.3.cat' }
        Add-PshGoal5ResponseQueue -Map $script:Goal5OnlineMap -Uri $uri -Response (New-PshGoal5Response 200 $uri -Bytes ([IO.File]::ReadAllBytes($path)))
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
}

$script:Goal5PolicyShim = {
        return Assert-PshPublisherPolicy -Policy $script:Goal5ActivePolicy
}
$script:Goal5VerifierShim = {
    param([Parameter(Mandatory = $true)][object] $Request)
    $script:Goal5VerifierCalls++
    return [pscustomobject][ordered]@{ Trusted = $true; Publisher = [string]$script:Goal5ActivePolicy.publisher }
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
Assert-PshGoal5Entry ((@([regex]::Matches($onlineText, 'PSH_EMBED_HELPERS_BEGIN')).Count -eq 1) -and (@([regex]::Matches($onlineText, 'PSH_EMBED_HELPERS_END')).Count -eq 1)) 'Online helper embedding markers are not unique.'
Assert-PshGoal5Entry ($onlineText -notmatch '(?i)irm\s*\|\s*iex|Invoke-Expression|ExecutionPolicy\s+(Bypass|Unrestricted)|TestCore') 'Online entry contains a forbidden bypass or test hook.'
Assert-PshGoal5Entry ($offlineText -notmatch '(?i)Invoke-WebRequest|HttpWebRequest|WebClient|curl\s|wget\s|Invoke-Expression|ExecutionPolicy\s+(Bypass|Unrestricted)|TestCore') 'Offline entry contains a transport or bypass.'

. $onlinePath
$onlineTransportOriginal = (Get-Command Invoke-PshOnlineHttpRequest -CommandType Function).ScriptBlock
$acquisitionTransportOriginal = (Get-Command Invoke-PshAcquisitionHttpRequest -CommandType Function).ScriptBlock
$policyOriginal = (Get-Command Get-PshProductionPublisherPolicy -CommandType Function).ScriptBlock
$verifierOriginal = (Get-Command Invoke-PshWindowsCatalogTrustVerifier -CommandType Function).ScriptBlock
$script:Goal5VerifierCalls = 0
$script:Goal5Fixture = New-PshGoal5ReleaseFixture -Root (Join-Path $script:TestRoot 'release')
$script:Goal5FixturePolicy = $script:Goal5Fixture.Policy
$script:Goal5OnlineSeen = New-Object 'System.Collections.Generic.List[string]'
$script:Goal5AcquisitionSeen = New-Object 'System.Collections.Generic.List[string]'
$script:Goal5OnlineMap = @{}
$script:Goal5AcquisitionMap = @{}
$oldArchitecture = $null
$oldPath = $null

try {
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
    Assert-PshGoal5Entry (@($script:Goal5OnlineSeen | Where-Object { $_ -match '/v1\.2\.3/' }).Count -ge 3) 'Online release assets were not pinned to the fixed tag.'
    Assert-PshGoal5Entry (@($script:Goal5OnlineSeen | Where-Object { $_ -match '/latest' }).Count -eq 2) 'Online latest resolution did not retry the GitHub API route exactly once after the 502 fixture.'
    Assert-PshGoal5Entry (@($script:Goal5AcquisitionSeen | Where-Object { $_ -match '/v1\.2\.3/' }).Count -ge 1) 'Package acquisition did not use a fixed-tag URI.'
    Assert-PshGoal5Entry ([string]$coreResult.edition -ceq 'Core') 'Core was not the online default edition.'

    $script:Goal5OnlineSeen.Clear(); $script:Goal5AcquisitionSeen.Clear()
    Set-PshGoal5OnlineTransportFixture -Fixture $script:Goal5Fixture
    $fullResult = @(Invoke-PshOnlineInstall -Edition Full -Version 1.2.3 -NonInteractive)[-1]
    Assert-PshGoal5Entry ([bool]$fullResult.success -and [string]$fullResult.edition -ceq 'Full') 'Online Full installation did not select the Full asset.'
    Assert-PshGoal5Entry (@($script:Goal5AcquisitionSeen | Where-Object { $_ -match 'full-win-x64' }).Count -ge 1) 'Online Full did not acquire the x64 package.'

    Set-PshGoal5OnlineTransportFixture -Fixture $script:Goal5Fixture -BadTag
    Assert-PshGoal5Failure -Action { Invoke-PshOnlineInstall -Edition Core -Version latest -NonInteractive } -ExitCode 3
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
    $offlineResult = @(Invoke-PshOfflineInstall -Edition Core -Version latest -NonInteractive)[-1]
    Assert-PshGoal5Entry ([bool]$offlineResult.success -and [string]$offlineResult.version -ceq '0.0.1-test') 'Offline installation did not complete.'
    Assert-PshGoal5Entry ($script:Goal5OnlineSeen.Count -eq 0 -and $script:Goal5AcquisitionSeen.Count -eq 0) 'Offline installation touched a transport.'
    $offlineLog = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-PshGoal5Entry ($offlineLog.Count -ge 1 -and -not [bool]$offlineLog[-1].catalogPresent) 'The package manifest catalog sidecar entered the lifecycle PackageRoot.'

    $offlineTwoRoot = Join-Path $script:TestRoot 'offline-two'
    $offlineTwo = New-PshGoal5EntryPackage -Root $offlineTwoRoot -Version '0.0.2-test' -Edition Core -RealOffline
    . (Join-Path $offlineTwoRoot 'install-offline.ps1')
    Set-PshGoal5TrustMocks
    [void](Invoke-PshOfflineInstall -Edition Core -Version 0.0.2-test -NonInteractive)
    . (Join-Path $offlineRoot 'install-offline.ps1')
    Set-PshGoal5TrustMocks
    [void](Invoke-PshOfflineInstall -Edition Core -Version 0.0.1-test -NonInteractive)
    $sequence = @(Get-Content -LiteralPath $logPath | ForEach-Object { ($_ | ConvertFrom-Json).version })
    Assert-PshGoal5Entry (@($sequence | Where-Object { $_ -in @('0.0.1-test', '0.0.2-test') }).Count -ge 3) 'Repeat/upgrade/rollback entry sequencing was not exercised.'
    Assert-PshGoal5Failure -Action { Invoke-PshOfflineInstall -Edition Full -Version 0.0.1-test -NonInteractive } -ExitCode 5 -ErrorId 'PshOfflineEditionMismatch'

    $shellFixture = Join-Path $script:TestRoot ($unicodeChinese + ' ' + $unicodeSpace + '/shell')
    [IO.Directory]::CreateDirectory($shellFixture) | Out-Null
    Copy-Item -LiteralPath $shellPath -Destination (Join-Path $shellFixture 'install.sh')
    Copy-Item -LiteralPath $offlinePath -Destination (Join-Path $shellFixture 'install-offline.ps1')
    $bashPath = Get-PshGoal5ShellApplication -Name bash
    $shPath = Get-PshGoal5ShellApplication -Name sh
    Assert-PshGoal5Entry (-not [string]::IsNullOrWhiteSpace($bashPath) -and -not [string]::IsNullOrWhiteSpace($shPath)) 'bash and sh are required dependencies for the shell entry contract.'
    & $bashPath -n (Join-Path $shellFixture 'install.sh')
    Assert-PshGoal5Entry ([int]$LASTEXITCODE -eq 0) 'bash -n rejected install.sh.'
    & $shPath -n (Join-Path $shellFixture 'install.sh')
    Assert-PshGoal5Entry ([int]$LASTEXITCODE -eq 0) 'sh -n rejected install.sh.'
    $fakeBin = Join-Path $script:TestRoot 'fake-bin'
    [IO.Directory]::CreateDirectory($fakeBin) | Out-Null
    $fakePowerShell = Join-Path $fakeBin 'powershell.exe'
    Write-PshGoal5Text -Path $fakePowerShell -Text @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PSH_FAKE_LOG"
case " $* " in
  *" -Command "*) exit "${PSH_FAKE_PREFLIGHT_EXIT:-0}" ;;
  *) exit "${PSH_FAKE_FILE_EXIT:-7}" ;;
esac
'@
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        & $bashPath -c 'chmod +x "$1"' _ $fakePowerShell
        Assert-PshGoal5Entry ([int]$LASTEXITCODE -eq 0) 'Unable to mark the non-Windows fake powershell.exe executable.'
    }
    $oldPath = $env:PATH
    $env:PATH = "$fakeBin$([IO.Path]::PathSeparator)$oldPath"
    $env:PSH_FAKE_LOG = Join-Path $script:TestRoot 'shell.log'
    $env:PSH_FAKE_FILE_EXIT = '7'
    $env:PSH_FAKE_PREFLIGHT_EXIT = '0'
    & $bashPath (Join-Path $shellFixture 'install.sh') --offline --edition Full --version '1.2.3' --non-interactive
    $shellExit = [int]$LASTEXITCODE
    Assert-PshGoal5Entry ($shellExit -eq 7) 'Shell wrapper did not forward the PowerShell exit code.'
    $shellLog = [IO.File]::ReadAllText($env:PSH_FAKE_LOG, $script:Utf8)
    Assert-PshGoal5Entry ($shellLog.Contains('-Edition Full') -and $shellLog.Contains('-Version 1.2.3') -and $shellLog.Contains('-NonInteractive')) 'Shell wrapper did not preserve named argument quoting.'
    & $bashPath (Join-Path $shellFixture 'install.sh') --help | Out-Null
    Assert-PshGoal5Entry ([int]$LASTEXITCODE -eq 0) 'Shell help did not return zero.'
    & $bashPath (Join-Path $shellFixture 'install.sh') --edition Invalid 2>$null
    Assert-PshGoal5Entry ([int]$LASTEXITCODE -eq 2) 'Shell invalid edition did not return structured usage code 2.'

    $report = [pscustomobject][ordered]@{ schemaVersion = 1; assertions = $script:Assertions; onlineUris = @($script:Goal5OnlineSeen); acquisitionUris = @($script:Goal5AcquisitionSeen); offlineLog = $sequence }
    Write-PshGoal5Json -Path (Join-Path $reportRoot 'Goal5.OnlineOffline.summary.json') -Value $report
    Write-Output ('Goal 5 online/offline acceptance passed ({0} assertions).' -f $script:Assertions)
}
finally {
    if ($null -ne $oldArchitecture) { $env:PROCESSOR_ARCHITECTURE = $oldArchitecture } else { Remove-Item Env:PROCESSOR_ARCHITECTURE -ErrorAction SilentlyContinue }
    if ($null -ne $oldPath) { $env:PATH = $oldPath }
    Remove-Item Env:PSH_GOAL5_ENTRY_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_FAKE_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_FAKE_FILE_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_FAKE_PREFLIGHT_EXIT -ErrorAction SilentlyContinue
    Set-Item -Path Function:\Invoke-PshOnlineHttpRequest -Value $onlineTransportOriginal -ErrorAction SilentlyContinue
    Set-Item -Path Function:\Invoke-PshAcquisitionHttpRequest -Value $acquisitionTransportOriginal -ErrorAction SilentlyContinue
    Set-Item -Path Function:\Get-PshProductionPublisherPolicy -Value $policyOriginal -ErrorAction SilentlyContinue
    Set-Item -Path Function:\Invoke-PshWindowsCatalogTrustVerifier -Value $verifierOriginal -ErrorAction SilentlyContinue
    if ([IO.Directory]::Exists($script:TestRoot)) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
