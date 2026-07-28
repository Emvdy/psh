# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LockPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-PshCatalogSource {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)

    if (-not $Condition) { throw "Catalog builder source verification failed: $Message" }
}

function Get-PshCatalogSourceSha256Bytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Get-PshCatalogSourceSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Get-PshCatalogSourceSha256Bytes -Bytes ([IO.File]::ReadAllBytes($Path))
}

function Resolve-PshCatalogSourcePath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$RelativePath)

    Assert-PshCatalogSource (-not [string]::IsNullOrWhiteSpace($RelativePath) -and -not [IO.Path]::IsPathRooted($RelativePath) -and $RelativePath -notmatch '\\') "Repository path is not a forward-slash relative path: $RelativePath"
    $segments = @($RelativePath.Split('/'))
    Assert-PshCatalogSource (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -eq '.' -or $_ -eq '..' }).Count -eq 0) "Repository path contains an unsafe component: $RelativePath"
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    Assert-PshCatalogSource ($full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, $comparison)) "Repository path escapes its root: $RelativePath"
    return $full
}

$trustedCommit = '3169db01948537e61a9102477fab4a39663ba79d'
$trustedLicenseSha256 = 'ae48df11a335dc1a615f4f938b69cba73bcf4485c4f97af49b38efb0f216353b'
$trustedFiles = @(
    [pscustomobject]@{ Name = 'CatalogBuilder.cs'; UpstreamPath = 'src/Microsoft.DotNet.Build.Tasks.FileCatalog/CatalogBuilder.cs'; UpstreamSha256 = 'bee5cdeb03d46f3fc11220d145d120c8eb45235a38962d4f7d175e55fc1ccc53' },
    [pscustomobject]@{ Name = 'CatalogEntry.cs'; UpstreamPath = 'src/Microsoft.DotNet.Build.Tasks.FileCatalog/CatalogEntry.cs'; UpstreamSha256 = 'a9d3ccfa7ec3ce989fa5582fc26e1a68ecd44c7e039c5b130a969c228917c501' },
    [pscustomobject]@{ Name = 'CatalogMemberEncoder.cs'; UpstreamPath = 'src/Microsoft.DotNet.Build.Tasks.FileCatalog/CatalogMemberEncoder.cs'; UpstreamSha256 = 'bf9997625bce5f75dfcaf44b9c2f7f05c50f49b05828f51515b55b734352824d' },
    [pscustomobject]@{ Name = 'CatalogOids.cs'; UpstreamPath = 'src/Microsoft.DotNet.Build.Tasks.FileCatalog/CatalogOids.cs'; UpstreamSha256 = '2a06d1c3ede8aa08c2f586c630582a0ed76e6e594f9076bbfb6192929200915b' }
)

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($LockPath)) { $LockPath = Join-Path $repositoryRootPath 'src/catalog-builder/arcade.lock.json' }
$lockPathFull = [IO.Path]::GetFullPath($LockPath)
Assert-PshCatalogSource ([IO.File]::Exists($lockPathFull)) "Lock file is missing: $lockPathFull"
$lockBytes = [IO.File]::ReadAllBytes($lockPathFull)
Assert-PshCatalogSource (-not ($lockBytes.Length -ge 3 -and $lockBytes[0] -eq 0xEF -and $lockBytes[1] -eq 0xBB -and $lockBytes[2] -eq 0xBF)) 'Lock file has a UTF-8 BOM.'
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$lock = $utf8.GetString($lockBytes) | ConvertFrom-Json -ErrorAction Stop
Assert-PshCatalogSource ([int]$lock.schemaVersion -eq 1) 'Lock schemaVersion is not 1.'
$dependency = $lock.dependency
Assert-PshCatalogSource ([string]$dependency.name -ceq 'dotnet/arcade managed FileCatalog source') 'Dependency name changed.'
Assert-PshCatalogSource ([string]$dependency.scope -ceq 'build-time-vendored-source') 'Dependency scope changed.'
Assert-PshCatalogSource ([string]$dependency.version -ceq $trustedCommit -and [string]$dependency.source.commit -ceq $trustedCommit) 'Arcade commit changed.'
Assert-PshCatalogSource ([string]$dependency.source.repository -ceq 'https://github.com/dotnet/arcade') 'Arcade repository changed.'

$license = $dependency.license
Assert-PshCatalogSource ([string]$license.spdxId -ceq 'MIT') 'Arcade license SPDX identifier changed.'
Assert-PshCatalogSource ([string]$license.fixedSourceSha256 -ceq $trustedLicenseSha256 -and [int64]$license.fixedSourceSize -eq 1115) 'Arcade fixed-source license identity changed.'
Assert-PshCatalogSource ([string]$license.fixedSourceUrl -ceq "https://raw.githubusercontent.com/dotnet/arcade/$trustedCommit/LICENSE.TXT") 'Arcade fixed-source license URL changed.'
$licensePath = Resolve-PshCatalogSourcePath -Root $repositoryRootPath -RelativePath ([string]$license.retainedPath)
Assert-PshCatalogSource ([IO.File]::Exists($licensePath)) "Retained Arcade license is missing: $licensePath"
$licenseBytes = [IO.File]::ReadAllBytes($licensePath)
Assert-PshCatalogSource ($licenseBytes.Length -eq [int64]$license.vendoredSize -and (Get-PshCatalogSourceSha256Bytes -Bytes $licenseBytes) -ceq [string]$license.vendoredSha256) 'Retained Arcade license bytes differ from the lock.'
Assert-PshCatalogSource ($licenseBytes.Length -eq 1116 -and $licenseBytes[$licenseBytes.Length - 1] -eq 0x0A) 'Retained Arcade license does not have the documented single terminal LF difference.'
$fixedLicenseBytes = New-Object byte[] ($licenseBytes.Length - 1)
[Array]::Copy($licenseBytes, 0, $fixedLicenseBytes, 0, $fixedLicenseBytes.Length)
Assert-PshCatalogSource ((Get-PshCatalogSourceSha256Bytes -Bytes $fixedLicenseBytes) -ceq $trustedLicenseSha256) 'Removing the documented terminal LF does not reproduce the fixed-source license.'

$files = @($dependency.files)
Assert-PshCatalogSource ($files.Count -eq $trustedFiles.Count) 'Vendored Arcade file count is not four.'
for ($index = 0; $index -lt $trustedFiles.Count; $index++) {
    $file = $files[$index]
    $trusted = $trustedFiles[$index]
    Assert-PshCatalogSource ([string]$file.name -ceq [string]$trusted.Name) "Vendored Arcade file order or name changed at index $index."
    Assert-PshCatalogSource ([string]$file.upstreamPath -ceq [string]$trusted.UpstreamPath -and [string]$file.upstreamSha256 -ceq [string]$trusted.UpstreamSha256) "$($trusted.Name) upstream path or SHA256 changed."
    Assert-PshCatalogSource ([bool]$file.modified) "$($trusted.Name) is not marked as modified."
    $vendoredPath = Resolve-PshCatalogSourcePath -Root $repositoryRootPath -RelativePath ([string]$file.vendoredPath)
    Assert-PshCatalogSource ([IO.File]::Exists($vendoredPath)) "Vendored Arcade source is missing: $vendoredPath"
    Assert-PshCatalogSource ([int64]([IO.FileInfo]$vendoredPath).Length -eq [int64]$file.vendoredSize) "$($trusted.Name) vendored size differs from the lock."
    Assert-PshCatalogSource ((Get-PshCatalogSourceSha256 -Path $vendoredPath) -ceq [string]$file.vendoredSha256) "$($trusted.Name) vendored SHA256 differs from the lock."
}

$projectPath = Join-Path $repositoryRootPath 'src/catalog-builder/Psh.CatalogBuilder.csproj'
$programPath = Join-Path $repositoryRootPath 'src/catalog-builder/Program.cs'
$encoderPath = Join-Path $repositoryRootPath 'src/catalog-builder/Arcade/CatalogMemberEncoder.cs'
$builderPath = Join-Path $repositoryRootPath 'src/catalog-builder/Arcade/CatalogBuilder.cs'
foreach ($requiredPath in @($projectPath, $programPath, $encoderPath, $builderPath)) { Assert-PshCatalogSource ([IO.File]::Exists($requiredPath)) "Catalog builder source is missing: $requiredPath" }
$projectText = [IO.File]::ReadAllText($projectPath, $utf8)
$programText = [IO.File]::ReadAllText($programPath, $utf8)
$encoderText = [IO.File]::ReadAllText($encoderPath, $utf8)
$builderText = [IO.File]::ReadAllText($builderPath, $utf8)
Assert-PshCatalogSource ($projectText -match '<TargetFramework>net10\.0</TargetFramework>' -and $projectText -notmatch '(?i)PackageReference|packages\.config|NuGet') 'Catalog builder project target or no-package contract changed.'
Assert-PshCatalogSource ($encoderText -match 'CatNameValue' -and $encoderText -match 'Encoding\.Unicode\.GetBytes\(relativePath \+ "\\0"\)' -and $encoderText -match 'WriteFilePathAttribute') 'PowerShell-compatible FilePath encoding is missing.'
Assert-PshCatalogSource ($builderText -match 'StringComparer\.Ordinal\.Compare\(a\.RelativePath, b\.RelativePath\)' -and $builderText -match 'deduped\[deduped\.Count - 1\]\.RelativePath') 'Identifier/path sorting or tuple deduplication is missing.'
Assert-PshCatalogSource ($programText -match "IndexOf\('\\0'\)" -and $programText -match 'StringComparer\.OrdinalIgnoreCase' -and $programText -match 'source\.Length == 0') 'Catalog CLI path, duplicate, or empty-input validation is missing.'

$provenancePath = Resolve-PshCatalogSourcePath -Root $repositoryRootPath -RelativePath ([string]$dependency.provenancePath)
Assert-PshCatalogSource ([IO.File]::Exists($provenancePath)) 'Arcade provenance file is missing.'
$provenanceText = [IO.File]::ReadAllText($provenancePath, $utf8)
Assert-PshCatalogSource ($provenanceText.Contains($trustedCommit) -and $provenanceText.Contains($trustedLicenseSha256)) 'Arcade provenance omits the fixed commit or license hash.'
foreach ($trusted in $trustedFiles) { Assert-PshCatalogSource ($provenanceText.Contains([string]$trusted.UpstreamSha256)) "Arcade provenance omits the upstream hash for $($trusted.Name)." }

Write-Output 'Catalog builder source verification passed: fixed Arcade commit, four upstream hashes, retained MIT license, modified-source hashes, and no-PackageReference CLI contract.'
