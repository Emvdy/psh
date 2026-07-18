# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

function Assert-PshDependencyCondition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Interactive dependency verification failed: $Message"
    }
}

function Get-PshFileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [IO.File]::OpenRead($Path)
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

function Resolve-PshLockedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    Assert-PshDependencyCondition (-not [string]::IsNullOrWhiteSpace($RelativePath)) "$Description is empty."
    Assert-PshDependencyCondition (-not [IO.Path]::IsPathRooted($RelativePath)) "$Description is rooted: $RelativePath"

    $segments = @($RelativePath.Replace('\', '/').Split('/'))
    Assert-PshDependencyCondition ($segments -notcontains '..') "$Description escapes its root: $RelativePath"
    Assert-PshDependencyCondition ($segments -notcontains '.') "$Description contains a non-canonical segment: $RelativePath"
    Assert-PshDependencyCondition (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "$Description contains an empty segment: $RelativePath"

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $nativeRelativePath = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath((Join-Path -Path $fullRoot -ChildPath $nativeRelativePath))
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    $comparison = [StringComparison]::Ordinal
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $comparison = [StringComparison]::OrdinalIgnoreCase
    }
    Assert-PshDependencyCondition ($fullPath.StartsWith($prefix, $comparison)) "$Description escapes its root: $RelativePath"
    return $fullPath
}

function Assert-PshImmutableSourceUrl {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    Assert-PshDependencyCondition ($Url -match '\Ahttps://') "$Description is not HTTPS."
    Assert-PshDependencyCondition ($Url -notmatch '(?i)(?:^|[/=])latest(?:[/?.#]|$)') "$Description uses a floating latest reference: $Url"
    Assert-PshDependencyCondition ($Url -notmatch '(?i)/(?:refs/heads/)?(?:main|master)(?:[/?.#]|$)') "$Description uses a floating branch reference: $Url"
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$lockPath = Join-Path -Path $repositoryRootPath -ChildPath 'src/Psh/Dependencies/interactive.lock.json'
Assert-PshDependencyCondition (Test-Path -LiteralPath $lockPath -PathType Leaf) "Lock file is missing: $lockPath"

$lockBytes = [IO.File]::ReadAllBytes($lockPath)
$hasUtf8Bom = $lockBytes.Length -ge 3 -and $lockBytes[0] -eq 0xEF -and $lockBytes[1] -eq 0xBB -and $lockBytes[2] -eq 0xBF
Assert-PshDependencyCondition (-not $hasUtf8Bom) 'Lock file must be UTF-8 without a BOM.'
$lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json

Assert-PshDependencyCondition ([int]$lock.schemaVersion -eq 1) 'Unsupported lock schemaVersion.'
Assert-PshDependencyCondition ([string]$lock.dependencyRoot -ceq 'src/Psh/Dependencies') 'Unexpected dependencyRoot.'
$components = @($lock.components)
Assert-PshDependencyCondition ($components.Count -eq 2) 'The lock must contain exactly two components.'

$expectedPins = @{
    PSReadLine = @{
        Version       = '2.4.5'
        PackageSha256 = 'cb9390e9733208456c234a7971d1ec4a917886c239502aab68f4b71aa4bba235'
        Commit        = '98d5610f7210924b79f553d982e10a9bd64dd52f'
        License       = 'BSD-2-Clause'
        LicenseSha256 = '25c2fdfcdc653f65629233f5ef217a83287733d3c0299c207b0bca865508c463'
        Files         = @(
            @{
                Path        = 'PSReadLine/2.4.5/Microsoft.PowerShell.PSReadLine.dll'
                PackagePath = 'Microsoft.PowerShell.PSReadLine.dll'
                Size        = 339528
                Sha256      = 'f8e3a5b7e3e8cad2130ce10647564a2a0ea15d98db8a0cc8d589f80154c108e2'
            }
            @{
                Path        = 'PSReadLine/2.4.5/Microsoft.PowerShell.Pager.dll'
                PackagePath = 'Microsoft.PowerShell.Pager.dll'
                Size        = 16784
                Sha256      = '451994c3d3e38d939b4fa5f8594d0207840f45e7a210aa75f81aef85aa17c592'
            }
            @{
                Path        = 'PSReadLine/2.4.5/PSReadLine.format.ps1xml'
                PackagePath = 'PSReadLine.format.ps1xml'
                Size        = 26820
                Sha256      = '1ca887463598d38aa18236a97a4193b2228d1d8434fa73cc8c7932f42a0565cf'
            }
            @{
                Path        = 'PSReadLine/2.4.5/PSReadLine.psd1'
                PackagePath = 'PSReadLine.psd1'
                Size        = 15471
                Sha256      = 'dd8766bd4db0c1d17111b81d145d32448f61f48451d51c780a79be9ca98d837e'
            }
            @{
                Path        = 'PSReadLine/2.4.5/PSReadLine.psm1'
                PackagePath = 'PSReadLine.psm1'
                Size        = 15076
                Sha256      = '9bc0252f616067ca5ef1d0328ec0b97c7d31c757f9fc80adee234ea6132a9c7e'
            }
            @{
                Path        = 'PSReadLine/2.4.5/net6plus/Microsoft.PowerShell.PSReadLine.Polyfiller.dll'
                PackagePath = 'net6plus/Microsoft.PowerShell.PSReadLine.Polyfiller.dll'
                Size        = 14920
                Sha256      = '6d33ea289b405c64bf5daa9c59e459596cac59ece399d0d215ee9f3d46afd675'
            }
            @{
                Path        = 'PSReadLine/2.4.5/netstd/Microsoft.PowerShell.PSReadLine.Polyfiller.dll'
                PackagePath = 'netstd/Microsoft.PowerShell.PSReadLine.Polyfiller.dll'
                Size        = 16928
                Sha256      = '2e63dc86d9240243ccfb07da5d0b4fce2bc5ce5f9952658a7ce68c26bcd3e14c'
            }
        )
    }
    PSCompletions = @{
        Version       = '6.10.0'
        PackageSha256 = '9f2bf9c6d143d2dc0c50a531b964f9f6ff30393077405914ca7d746ef8e38cb7'
        Commit        = '427212789d4df206d37d1d3c3d12b4341ac73644'
        License       = 'MIT'
        LicenseSha256 = 'ff823ba75e90563c3876fbe28df694c0cde5817c721397af7879db19e8ecdd5b'
        Files         = @(
            @{
                Path        = 'PSCompletions/6.10.0/PSCompletions.ps1'
                PackagePath = 'PSCompletions.ps1'
                Size        = 120700
                Sha256      = 'b32a5bc04e9dbb099daf9aa1cc9b6e2d2927b589ac4847ddffa8e11f357b8df5'
            }
            @{
                Path        = 'PSCompletions/6.10.0/PSCompletions.psd1'
                PackagePath = 'PSCompletions.psd1'
                Size        = 1631
                Sha256      = '17b4203e9ade01a56c01c3e6cafd94db9e55f8d7d76d599ff64645c4a8a3c1ff'
            }
            @{
                Path        = 'PSCompletions/6.10.0/PSCompletions.psm1'
                PackagePath = 'PSCompletions.psm1'
                Size        = 55557
                Sha256      = 'ab67a3e31d1a57d8c53f5dbf20586a0e6cc00ab781033c2c6eed5e320f3bb610'
            }
            @{
                Path        = 'PSCompletions/6.10.0/completions/psc/config.json'
                PackagePath = 'completions/psc/config.json'
                Size        = 73
                Sha256      = '78954abccf6a908cba29635b3e3eb54263f628390857714c1e3128f1c3326c9b'
            }
            @{
                Path        = 'PSCompletions/6.10.0/completions/psc/hooks.ps1'
                PackagePath = 'completions/psc/hooks.ps1'
                Size        = 7089
                Sha256      = '8892db60ca6580a6a157902f8bb92e30ce85ae109b7c1fdf3eb47e02daf5efb5'
            }
            @{
                Path        = 'PSCompletions/6.10.0/completions/psc/language/en-US.json'
                PackagePath = 'completions/psc/language/en-US.json'
                Size        = 95436
                Sha256      = 'baaab326319e9f7615ef93211b84dacc928f3620bc52b2fe37ae992060eae0d1'
            }
            @{
                Path        = 'PSCompletions/6.10.0/completions/psc/language/zh-CN.json'
                PackagePath = 'completions/psc/language/zh-CN.json'
                Size        = 93191
                Sha256      = '0383d95e2a3dba30e07de1d074997360d31a05267e22467d317bc21d39214074'
            }
        )
    }
}

$dependencyRoot = Join-Path -Path $repositoryRootPath -ChildPath 'src/Psh/Dependencies'
$expectedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$verifiedFileCount = 0
foreach ($component in $components) {
    $name = [string]$component.name
    Assert-PshDependencyCondition ($expectedPins.ContainsKey($name)) "Unexpected component: $name"
    $pin = $expectedPins[$name]
    Assert-PshDependencyCondition ([string]$component.version -ceq $pin.Version) "$name has the wrong version."
    Assert-PshDependencyCondition ([string]$component.package.sha256 -ceq $pin.PackageSha256) "$name has the wrong package SHA-256."
    Assert-PshDependencyCondition ([string]$component.repository.commit -ceq $pin.Commit) "$name has the wrong source commit."
    Assert-PshDependencyCondition ([string]$component.license.spdxId -ceq $pin.License) "$name has the wrong SPDX license."
    Assert-PshDependencyCondition ([string]$component.license.sha256 -ceq $pin.LicenseSha256) "$name has the wrong license SHA-256."
    Assert-PshDependencyCondition ([bool]$component.package.galleryHashVerified) "$name Gallery hash was not verified."
    Assert-PshDependencyCondition ([bool]$component.archiveAudit.crcVerified) "$name archive CRC was not verified."

    # The lock is data under test, not the trust root. Keep an independent,
    # review-visible manifest of every selected package byte range here so a
    # vendored file and its lock entry cannot be changed together and pass.
    $trustedFilesByPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $trustedPackagePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($trustedFile in @($pin.Files)) {
        $trustedPath = [string]$trustedFile.Path
        $trustedPackagePath = [string]$trustedFile.PackagePath
        $derivedTrustedPath = '{0}/{1}/{2}' -f $name, $pin.Version, $trustedPackagePath
        Assert-PshDependencyCondition ($trustedPath -ceq $derivedTrustedPath) "$name trusted package path does not map to its vendored path: $trustedPackagePath"
        Assert-PshDependencyCondition (-not $trustedFilesByPath.ContainsKey($trustedPath)) "$name trusted file manifest has a duplicate path: $trustedPath"
        $trustedFilesByPath.Add($trustedPath, $trustedFile)
        Assert-PshDependencyCondition ($trustedPackagePaths.Add($trustedPackagePath)) "$name trusted package manifest has a duplicate path: $trustedPackagePath"
    }

    $includedPackagePaths = @($component.selection.includedPackagePaths | ForEach-Object { ([string]$_).Replace('\', '/') })
    Assert-PshDependencyCondition ($includedPackagePaths.Count -eq $trustedPackagePaths.Count) "$name package selection count differs from the trusted file manifest."
    $seenIncludedPackagePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($includedPackagePath in $includedPackagePaths) {
        Assert-PshDependencyCondition ($seenIncludedPackagePaths.Add($includedPackagePath)) "$name package selection contains a duplicate path: $includedPackagePath"
        Assert-PshDependencyCondition ($trustedPackagePaths.Contains($includedPackagePath)) "$name package selection is not independently pinned: $includedPackagePath"
    }
    foreach ($trustedPackagePath in $trustedPackagePaths) {
        Assert-PshDependencyCondition ($seenIncludedPackagePaths.Contains($trustedPackagePath)) "$name trusted package file is missing from the selection: $trustedPackagePath"
    }

    foreach ($urlField in @('galleryPageUrl', 'metadataUrl', 'downloadUrl', 'resolvedUrl')) {
        Assert-PshImmutableSourceUrl -Url ([string]$component.package.$urlField) -Description "$name package $urlField"
    }
    Assert-PshImmutableSourceUrl -Url ([string]$component.license.fixedSourceUrl) -Description "$name fixed license URL"

    $manifestRelativePath = [string]$component.module.manifest
    Assert-PshDependencyCondition (@($component.module.windowsPowerShell51Entry, $component.module.powerShell7Entry | Where-Object { [string]$_ -cne $manifestRelativePath }).Count -eq 0) "$name runtime entries do not use the pinned manifest."

    $seenComponentFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($file in @($component.vendoredFiles)) {
        $relativePath = ([string]$file.path).Replace('\', '/')
        Assert-PshDependencyCondition ($seenComponentFiles.Add($relativePath)) "$name has a duplicate locked file: $relativePath"
        Assert-PshDependencyCondition ($expectedFiles.Add($relativePath)) "Locked file is shared or duplicated: $relativePath"
        Assert-PshDependencyCondition ($trustedFilesByPath.ContainsKey($relativePath)) "$name locked file is not in the independent trusted manifest: $relativePath"
        $trustedFile = $trustedFilesByPath[$relativePath]
        Assert-PshDependencyCondition ([long]$file.size -eq [long]$trustedFile.Size) "$name lock size differs from the independent trusted manifest: $relativePath"
        Assert-PshDependencyCondition ([string]$file.sha256 -ceq [string]$trustedFile.Sha256) "$name lock SHA-256 differs from the independent trusted manifest: $relativePath"
        $fullPath = Resolve-PshLockedPath -Root $dependencyRoot -RelativePath $relativePath -Description "$name locked file"
        Assert-PshDependencyCondition (Test-Path -LiteralPath $fullPath -PathType Leaf) "$name locked file is missing: $relativePath"
        $item = Get-Item -LiteralPath $fullPath
        Assert-PshDependencyCondition ([long]$item.Length -eq [long]$trustedFile.Size) "$name trusted file size changed: $relativePath"
        Assert-PshDependencyCondition ((Get-PshFileSha256 -Path $fullPath) -ceq [string]$trustedFile.Sha256) "$name trusted file SHA-256 changed: $relativePath"
        $verifiedFileCount++
    }
    Assert-PshDependencyCondition ($seenComponentFiles.Count -eq $trustedFilesByPath.Count) "$name lock does not contain the exact independent trusted file set."
    foreach ($trustedPath in $trustedFilesByPath.Keys) {
        Assert-PshDependencyCondition ($seenComponentFiles.Contains($trustedPath)) "$name trusted file is missing from the lock: $trustedPath"
    }

    $manifestPath = Resolve-PshLockedPath -Root $dependencyRoot -RelativePath $manifestRelativePath -Description "$name manifest"
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    Assert-PshDependencyCondition ([string]$manifest.ModuleVersion -ceq $pin.Version) "$name manifest version changed."

    $licensePath = Resolve-PshLockedPath -Root $repositoryRootPath -RelativePath ([string]$component.license.vendoredPath) -Description "$name license"
    Assert-PshDependencyCondition (Test-Path -LiteralPath $licensePath -PathType Leaf) "$name license is missing."
    Assert-PshDependencyCondition ((Get-PshFileSha256 -Path $licensePath) -ceq $pin.LicenseSha256) "$name license SHA-256 changed."
}

Assert-PshDependencyCondition ($verifiedFileCount -eq 14) "Expected 14 locked files, verified $verifiedFileCount."
$actualFiles = @(
    Get-ChildItem -LiteralPath $dependencyRoot -Recurse -File |
        Where-Object { $_.FullName -cne $lockPath }
)
foreach ($file in $actualFiles) {
    $relativePath = $file.FullName.Substring($dependencyRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace('\', '/')
    Assert-PshDependencyCondition ($expectedFiles.Contains($relativePath)) "Untracked dependency file is present: $relativePath"
}
Assert-PshDependencyCondition ($actualFiles.Count -eq $expectedFiles.Count) 'The dependency directory is not the exact locked file set.'

$psCompletions = @($components | Where-Object { $_.name -ceq 'PSCompletions' })[0]
Assert-PshDependencyCondition ([bool]$psCompletions.runtimeAudit.startsUpdateJobOnImport) 'PSCompletions import-side update job risk is not recorded.'
Assert-PshDependencyCondition ([bool]$psCompletions.runtimeAudit.mayContactNetworkAfterImport) 'PSCompletions network risk is not recorded.'
Assert-PshDependencyCondition ([bool]$psCompletions.runtimeAudit.integrationReviewRequired) 'PSCompletions integration review gate is not recorded.'

Write-Output "Interactive dependency verification passed: 2 fixed components, $verifiedFileCount independently pinned runtime files, and 2 verified licenses."
