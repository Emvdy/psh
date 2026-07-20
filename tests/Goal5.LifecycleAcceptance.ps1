# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Assertions = 0
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

$lifecycleHelpers = Join-Path $RepositoryRoot 'src/install/PackageLifecycle.ps1'
$installScript = Join-Path $RepositoryRoot 'src/install/Install-PshPackage.ps1'
$rollbackScript = Join-Path $RepositoryRoot 'src/install/Rollback-PshVersion.ps1'
$uninstallScript = Join-Path $RepositoryRoot 'src/install/Uninstall-Psh.ps1'
. $lifecycleHelpers

function Assert-PshGoal5Lifecycle {
    param([Parameter(Mandatory = $true)][bool] $Condition, [Parameter(Mandatory = $true)][string] $Message)
    $script:Assertions++
    if (-not $Condition) { throw "Goal 5 lifecycle acceptance failed: $Message" }
}

function Get-PshGoal5LifecycleHash {
    param([Parameter(Mandatory = $true)][string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Test-PshGoal5LifecycleBytesEqual {
    param([Parameter(Mandatory = $true)][byte[]] $Left, [Parameter(Mandatory = $true)][byte[]] $Right)
    return [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right)
}

function Write-PshGoal5LifecycleText {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Text)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function Get-PshGoal5LifecycleRelative {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Path)
    $rootUri = New-Object Uri(([IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar))
    $pathUri = New-Object Uri([IO.Path]::GetFullPath($Path))
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('\', '/')
}

function New-PshGoal5LifecyclePackage {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Version,
        [string] $Marker = 'default',
        [switch] $BundleComponents,
        [ValidateSet('Core', 'Full')][string] $Edition = 'Core',
        [ValidateSet('any', 'win-x64', 'win-arm64')][string] $Architecture,
        [ValidateSet('Core', 'Full')][string] $ConfigEdition,
        [string] $ProfileSourceMutationPath,
        [string] $SetCurrentConflictText
    )
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    Write-PshGoal5LifecycleText -Path (Join-Path $Root 'install-offline.ps1') -Text "# offline test entrypoint`n"
    Write-PshGoal5LifecycleText -Path (Join-Path $Root 'uninstall.ps1') -Text "# uninstall test entrypoint`n"
    Write-PshGoal5LifecycleText -Path (Join-Path $Root 'install.sh') -Text "#!/bin/sh`n# offline test entrypoint`n"
    Write-PshGoal5LifecycleText -Path (Join-Path $Root 'psh-installer.exe') -Text "MZ synthetic AnyCPU bootstrapper $Marker`n"

    $moduleRoot = Join-Path $Root 'payload/Psh'
    Write-PshGoal5LifecycleText -Path (Join-Path $moduleRoot 'Psh.psd1') -Text @"
@{
    RootModule = 'Psh.psm1'
    ModuleVersion = '0.0.1'
    GUID = '11111111-2222-3333-4444-555555555555'
    FunctionsToExport = @()
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
"@
    Write-PshGoal5LifecycleText -Path (Join-Path $moduleRoot 'Psh.psm1') -Text "# synthetic $Version $Marker`n"
    $payloadInstall = Join-Path $Root 'payload/install'
    [IO.Directory]::CreateDirectory($payloadInstall) | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/install/bootstrap.ps1') -Destination (Join-Path $payloadInstall 'bootstrap.ps1')
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/install/config.psd1') -Destination (Join-Path $payloadInstall 'config.psd1')
    $effectiveConfigEdition = if ([string]::IsNullOrWhiteSpace($ConfigEdition)) { $Edition } else { $ConfigEdition }
    if ($effectiveConfigEdition -cne 'Core') {
        Write-PshGoal5LifecycleText -Path (Join-Path $payloadInstall 'config.psd1') -Text ("@{{`n    SchemaVersion = 1`n    Edition = '{0}'`n    DisabledCommands = @()`n}}`n" -f $effectiveConfigEdition)
    }
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/install/Set-PshCurrentVersion.ps1') -Destination (Join-Path $payloadInstall 'Set-PshCurrentVersion.ps1')
    if (-not [string]::IsNullOrWhiteSpace($SetCurrentConflictText)) {
        $conflictScript = @"
[CmdletBinding(SupportsShouldProcess = `$true)]
param([Parameter(Mandatory = `$true)][string]`$Version, [string]`$InstallRoot, [AllowNull()][string]`$ExpectedCurrentSha256)
Set-StrictMode -Version 2.0
`$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText((Join-Path `$InstallRoot 'ownership.json'), '$SetCurrentConflictText', (New-Object System.Text.UTF8Encoding(`$false)))
`$e = New-Object System.InvalidOperationException('synthetic metadata CAS conflict')
`$e.Data['PshExitCode'] = 5
`$e.Data['PshErrorKind'] = 'IntegrityFailure'
throw `$e
"@
        Write-PshGoal5LifecycleText -Path (Join-Path $payloadInstall 'Set-PshCurrentVersion.ps1') -Text $conflictScript
    }
    $payloadProfile = Join-Path $Root 'payload/profile'
    [IO.Directory]::CreateDirectory($payloadProfile) | Out-Null
    foreach ($name in @('ProfileBlock.ps1', 'Install-PshProfile.ps1', 'Uninstall-PshProfile.ps1')) {
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot ('src/profile/' + $name)) -Destination (Join-Path $payloadProfile $name)
    }
    if (-not [string]::IsNullOrWhiteSpace($ProfileSourceMutationPath)) {
        Copy-Item -LiteralPath (Join-Path $payloadProfile 'Install-PshProfile.ps1') -Destination (Join-Path $payloadProfile 'Install-PshProfile.Real.ps1')
        $wrapper = @"
[CmdletBinding(SupportsShouldProcess = `$true, ConfirmImpact = 'Low')]
param([AllowNull()][string[]]`$ProfilePath, [string]`$StateRoot)
Set-StrictMode -Version 2.0
`$ErrorActionPreference = 'Stop'
[IO.File]::AppendAllText('$ProfileSourceMutationPath', '# source-after-stage-tamper`n', (New-Object System.Text.UTF8Encoding(`$false)))
& (Join-Path `$PSScriptRoot 'Install-PshProfile.Real.ps1') -ProfilePath `$ProfilePath -StateRoot `$StateRoot -WhatIf:`$WhatIfPreference -Confirm:`$false
"@
        Write-PshGoal5LifecycleText -Path (Join-Path $payloadProfile 'Install-PshProfile.ps1') -Text $wrapper
    }
    if ($BundleComponents) {
        foreach ($name in @(
                'PSReadLineProjection.ps1',
                'Install-PshPSReadLineProjection.ps1',
                'Uninstall-PshPSReadLineProjection.ps1')) {
            Copy-Item -LiteralPath (Join-Path $RepositoryRoot ('src/profile/' + $name)) -Destination (Join-Path $payloadProfile $name)
        }
        $projectionParent = Join-Path $moduleRoot 'Dependencies/PSReadLine'
        [IO.Directory]::CreateDirectory($projectionParent) | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/Psh/Dependencies/PSReadLine/2.4.5') -Destination $projectionParent -Recurse
    }
    $effectiveArchitecture = if ([string]::IsNullOrWhiteSpace($Architecture)) { if ($Edition -ceq 'Full') { 'win-x64' } else { 'any' } } else { $Architecture }
    $nativeLockHash = $null
    if ($Edition -ceq 'Full') {
        $nativeLockPath = Join-Path $Root 'payload/native-tools.lock.json'
        Write-PshGoal5LifecycleText -Path $nativeLockPath -Text "{`"synthetic`":true}`n"
        $nativeLockHash = Get-PshGoal5LifecycleHash -Path $nativeLockPath
    }

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName)) {
        if ($file.Name -ceq 'package.manifest.json' -and [string]::Equals($file.DirectoryName, [IO.Path]::GetFullPath($Root), [StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = Get-PshGoal5LifecycleRelative -Root $Root -Path $file.FullName
        $role = if ($relative -ceq 'psh-installer.exe') { 'bootstrapper' } elseif ($relative -in @('install-offline.ps1', 'uninstall.ps1', 'install.sh')) { 'entrypoint' } else { 'payload' }
        $files.Add([pscustomobject][ordered]@{ relativePath = $relative; length = [long]$file.Length; sha256 = Get-PshGoal5LifecycleHash -Path $file.FullName; role = $role })
    }
    $treeSha = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = $files.ToArray() })
    $bootstrapHash = Get-PshGoal5LifecycleHash -Path (Join-Path $Root 'psh-installer.exe')
    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        version = $Version
        edition = $Edition
        architecture = $effectiveArchitecture
        payloadRoot = 'payload'
        files = $files.ToArray()
        treeSha256 = $treeSha
        entrypoints = [pscustomobject][ordered]@{ offlinePowerShell = 'install-offline.ps1'; uninstallPowerShell = 'uninstall.ps1'; shell = 'install.sh'; bootstrapper = 'psh-installer.exe' }
        testOnly = $true
        source = [pscustomobject][ordered]@{ repository = 'https://github.com/Emvdy/psh'; commit = ('1' * 40) }
        bootstrapper = [pscustomobject][ordered]@{ relativePath = 'psh-installer.exe'; sha256 = $bootstrapHash; anyCpu = $true }
        nativeToolsLockSha256 = $nativeLockHash
    }
    [IO.File]::WriteAllText((Join-Path $Root 'package.manifest.json'), (($manifest | ConvertTo-Json -Depth 20) + "`n"), $script:Utf8)
    return $Root
}

function Invoke-PshGoal5LifecycleFailure {
    param([Parameter(Mandatory = $true)][scriptblock] $Action)
    try { & $Action | Out-Null }
    catch { return $_ }
    throw 'Expected lifecycle operation to fail.'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal5-lifecycle-' + [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $testRoot 'installed/Psh'
$profilePath = Join-Path $testRoot 'profiles/PowerShell/profile.ps1'
$originalProfile = "# user profile`r`n`$global:Goal5UserValue = 7`r`n"

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    Write-PshGoal5LifecycleText -Path $profilePath -Text $originalProfile
    $packageOne = New-PshGoal5LifecyclePackage -Root (Join-Path $testRoot 'packages/one') -Version '0.0.1-test' -Marker 'one'
    $packageTwo = New-PshGoal5LifecyclePackage -Root (Join-Path $testRoot 'packages/two') -Version '0.0.2-test' -Marker 'two'

    $stagingFileRoot = Join-Path $testRoot 'obstruction-staging/Psh'
    [IO.Directory]::CreateDirectory($stagingFileRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $stagingFileRoot '.staging'), 'file obstruction', $script:Utf8)
    $stagingFailure = Invoke-PshGoal5LifecycleFailure { & $installScript -PackageRoot $packageOne -InstallRoot $stagingFileRoot -ProfilePath @() -ModuleRoot @() -Offline -Confirm:$false }
    Assert-PshGoal5Lifecycle ([int]$stagingFailure.Exception.Data['PshExitCode'] -eq 5 -and -not [IO.File]::Exists((Join-Path $stagingFileRoot 'ownership.json'))) 'A file obstruction at .staging was not rejected before installation.'

    $quarantineFileRoot = Join-Path $testRoot 'obstruction-quarantine/Psh'
    [IO.Directory]::CreateDirectory($quarantineFileRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $quarantineFileRoot '.quarantine'), 'file obstruction', $script:Utf8)
    $quarantineFailure = Invoke-PshGoal5LifecycleFailure { & $installScript -PackageRoot $packageOne -InstallRoot $quarantineFileRoot -ProfilePath @() -ModuleRoot @() -Offline -Confirm:$false }
    Assert-PshGoal5Lifecycle ([int]$quarantineFailure.Exception.Data['PshExitCode'] -eq 5 -and -not [IO.File]::Exists((Join-Path $quarantineFileRoot 'transaction.json'))) 'A file obstruction at .quarantine was not rejected before installation.'

    $backupFileRoot = Join-Path $testRoot 'obstruction-backup/Psh'
    [IO.Directory]::CreateDirectory((Join-Path $backupFileRoot '.lifecycle')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $backupFileRoot '.lifecycle/backups'), 'file obstruction', $script:Utf8)
    $backupFailure = Invoke-PshGoal5LifecycleFailure { & $installScript -PackageRoot $packageOne -InstallRoot $backupFileRoot -ProfilePath @() -ModuleRoot @() -Offline -Confirm:$false }
    Assert-PshGoal5Lifecycle ([int]$backupFailure.Exception.Data['PshExitCode'] -eq 5 -and -not [IO.File]::Exists((Join-Path $backupFileRoot 'ownership.json'))) 'A file obstruction at .lifecycle/backups was not rejected before installation.'

    $filesystemRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($testRoot))
    $rootFailures = @(
        (Invoke-PshGoal5LifecycleFailure { & $installScript -PackageRoot $packageOne -InstallRoot $filesystemRoot -ProfilePath @() -ModuleRoot @() -Offline })
        (Invoke-PshGoal5LifecycleFailure { & $rollbackScript -InstallRoot $filesystemRoot -Version '0.0.1-test' -ModuleRoot @() -Offline })
        (Invoke-PshGoal5LifecycleFailure { & $uninstallScript -InstallRoot $filesystemRoot -ProfilePath @() -ModuleRoot @() -Confirm:$false })
    )
    Assert-PshGoal5Lifecycle ($rootFailures.Count -eq 3 -and @($rootFailures | Where-Object { [int]$_.Exception.Data['PshExitCode'] -eq 5 -and [string]$_.Exception.Message -like '*filesystem root*' }).Count -eq 3) 'Lifecycle entry points accepted a filesystem-root InstallRoot.'

    $first = @(& $installScript -PackageRoot $packageOne -InstallRoot $installRoot -Edition Core -Version '0.0.1-test' -ProfilePath @($profilePath) -ModuleRoot @() -Offline)
    $firstResult = $first[-1]
    Assert-PshGoal5Lifecycle ([bool]$firstResult.success -and [int]$firstResult.code -eq 0) 'Initial offline installation failed.'
    Assert-PshGoal5Lifecycle ([IO.File]::Exists((Join-Path $installRoot 'versions/0.0.1-test/Psh/Psh.psd1'))) 'Initial version was not published.'
    $currentText = [IO.File]::ReadAllText((Join-Path $installRoot 'current.json'), $script:Utf8)
    Assert-PshGoal5Lifecycle ($currentText -ceq "{`"schemaVersion`":1,`"version`":`"0.0.1-test`"}`n") 'current.json did not keep its exact two-field schema.'
    Assert-PshGoal5Lifecycle ([IO.File]::ReadAllText($profilePath, $script:Utf8).Contains('# >>> Psh managed profile >>>')) 'Profile loader was not installed.'
    Assert-PshGoal5Lifecycle (-not [IO.File]::Exists((Join-Path $installRoot 'transaction.json'))) 'Completed install left a transaction journal.'

    $repeat = @(& $installScript -PackageRoot $packageOne -InstallRoot $installRoot -ProfilePath @($profilePath) -ModuleRoot @() -Offline)
    Assert-PshGoal5Lifecycle ([bool]$repeat[-1].idempotent) 'Repeat installation of the same package was not idempotent.'

    $installedModulePath = Join-Path $installRoot 'versions/0.0.1-test/Psh/Psh.psm1'
    [byte[]]$installedModuleBytes = [IO.File]::ReadAllBytes($installedModulePath)
    [IO.File]::AppendAllText($installedModulePath, '# installed-tree tamper', $script:Utf8)
    $installedTreeTamper = Invoke-PshGoal5LifecycleFailure { & $installScript -PackageRoot $packageOne -InstallRoot $installRoot -ProfilePath @($profilePath) -ModuleRoot @() -Offline -Confirm:$false }
    Assert-PshGoal5Lifecycle ([int]$installedTreeTamper.Exception.Data['PshExitCode'] -eq 5 -and [IO.File]::Exists((Join-Path $installRoot 'ownership.json'))) 'Same-version installed-tree tampering was not rejected with code 5.'
    [IO.File]::WriteAllBytes($installedModulePath, $installedModuleBytes)

    $strictAfterDotSource = & {
        $null = . $installScript -PackageRoot $packageOne -InstallRoot $installRoot -ProfilePath @($profilePath) -ModuleRoot @() -Offline -WhatIf
        $invalidOwnership = Read-PshOwnershipState -InstallRoot $installRoot
        $invalidOwnership | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        try { Write-PshOwnershipState -InstallRoot $installRoot -State $invalidOwnership | Out-Null }
        catch { return $_ }
        return $null
    }
    Assert-PshGoal5Lifecycle ($null -ne $strictAfterDotSource -and [int]$strictAfterDotSource.Exception.Data['PshExitCode'] -eq 5) 'Dot-sourcing the installer weakened the core unknown-field validator.'

    $upgrade = @(& $installScript -PackageRoot $packageTwo -InstallRoot $installRoot -ProfilePath @($profilePath) -ModuleRoot @() -Offline)
    Assert-PshGoal5Lifecycle ([string]$upgrade[-1].version -ceq '0.0.2-test') 'Upgrade did not activate the second version.'
    [byte[]]$rollbackCurrentBeforeWhatIf = [IO.File]::ReadAllBytes((Join-Path $installRoot 'current.json'))
    [byte[]]$rollbackOwnershipBeforeWhatIf = [IO.File]::ReadAllBytes((Join-Path $installRoot 'ownership.json'))
    [byte[]]$rollbackProfileBeforeWhatIf = [IO.File]::ReadAllBytes($profilePath)
    $rollbackWhatIf = @(& $rollbackScript -InstallRoot $installRoot -Version '0.0.1-test' -ModuleRoot @() -Offline -WhatIf -Confirm:$false)
    Assert-PshGoal5Lifecycle ([bool]$rollbackWhatIf[-1].whatIf -and (Test-PshGoal5LifecycleBytesEqual $rollbackCurrentBeforeWhatIf ([IO.File]::ReadAllBytes((Join-Path $installRoot 'current.json')))) -and (Test-PshGoal5LifecycleBytesEqual $rollbackOwnershipBeforeWhatIf ([IO.File]::ReadAllBytes((Join-Path $installRoot 'ownership.json')))) -and (Test-PshGoal5LifecycleBytesEqual $rollbackProfileBeforeWhatIf ([IO.File]::ReadAllBytes($profilePath))) -and -not [IO.File]::Exists((Join-Path $installRoot 'transaction.json'))) 'Rollback -WhatIf changed lifecycle state.'

    $rollbackObstruction = Join-Path $installRoot '.quarantine'
    if ([IO.Directory]::Exists($rollbackObstruction)) { [IO.Directory]::Delete($rollbackObstruction, $false) }
    [IO.File]::WriteAllText($rollbackObstruction, 'file obstruction', $script:Utf8)
    $rollbackObstructionFailure = Invoke-PshGoal5LifecycleFailure { & $rollbackScript -InstallRoot $installRoot -Version '0.0.1-test' -ModuleRoot @() -Offline -Confirm:$false }
    Assert-PshGoal5Lifecycle ([int]$rollbackObstructionFailure.Exception.Data['PshExitCode'] -eq 5 -and (Test-PshGoal5LifecycleBytesEqual $rollbackCurrentBeforeWhatIf ([IO.File]::ReadAllBytes((Join-Path $installRoot 'current.json')))) -and -not [IO.File]::Exists((Join-Path $installRoot 'transaction.json'))) 'Rollback accepted a .quarantine file obstruction.'
    [IO.File]::Delete($rollbackObstruction)
    $rollback = @(& $rollbackScript -InstallRoot $installRoot -Version '0.0.1-test' -ModuleRoot @() -Offline)
    Assert-PshGoal5Lifecycle ([string]$rollback[-1].status -ceq 'switched') 'Offline rollback did not switch versions.'
    $rolledCurrent = [IO.File]::ReadAllText((Join-Path $installRoot 'current.json'), $script:Utf8)
    Assert-PshGoal5Lifecycle ($rolledCurrent.Contains('"version":"0.0.1-test"')) 'Rollback selected the wrong version.'

    $conflictingPackage = New-PshGoal5LifecyclePackage -Root (Join-Path $testRoot 'packages/conflict') -Version '0.0.1-test' -Marker 'different-content'
    $conflict = Invoke-PshGoal5LifecycleFailure { & $installScript -PackageRoot $conflictingPackage -InstallRoot $installRoot -ProfilePath @($profilePath) -ModuleRoot @() -Offline }
    Assert-PshGoal5Lifecycle ([int]$conflict.Exception.Data['PshExitCode'] -eq 5) 'Same-version different-hash package did not fail with code 5.'

    $corruptPackage = New-PshGoal5LifecyclePackage -Root (Join-Path $testRoot 'packages/corrupt') -Version '0.0.3-test' -Marker 'corrupt'
    [IO.File]::AppendAllText((Join-Path $corruptPackage 'payload/Psh/Psh.psm1'), '# tampered', $script:Utf8)
    $corrupt = Invoke-PshGoal5LifecycleFailure { & $installScript -PackageRoot $corruptPackage -InstallRoot (Join-Path $testRoot 'corrupt-install') -ProfilePath @($profilePath) -ModuleRoot @() -Offline }
    Assert-PshGoal5Lifecycle ([int]$corrupt.Exception.Data['PshExitCode'] -eq 5) 'Corrupted package did not fail with code 5.'

    $whatIfRoot = Join-Path $testRoot 'what-if/Psh'
    $whatIf = @(& $installScript -PackageRoot $packageOne -InstallRoot $whatIfRoot -ProfilePath @($profilePath) -ModuleRoot @() -Offline -WhatIf)
    Assert-PshGoal5Lifecycle ([bool]$whatIf[-1].whatIf -and -not [IO.Directory]::Exists($whatIfRoot)) 'Install -WhatIf mutated the install root.'

    [byte[]]$uninstallCurrentBeforeWhatIf = [IO.File]::ReadAllBytes((Join-Path $installRoot 'current.json'))
    [byte[]]$uninstallOwnershipBeforeWhatIf = [IO.File]::ReadAllBytes((Join-Path $installRoot 'ownership.json'))
    [byte[]]$uninstallProfileBeforeWhatIf = [IO.File]::ReadAllBytes($profilePath)
    $uninstallWhatIf = @(& $uninstallScript -InstallRoot $installRoot -ProfilePath @($profilePath) -ModuleRoot @() -WhatIf -Confirm:$false)
    Assert-PshGoal5Lifecycle ([bool]$uninstallWhatIf[-1].whatIf -and (Test-PshGoal5LifecycleBytesEqual $uninstallCurrentBeforeWhatIf ([IO.File]::ReadAllBytes((Join-Path $installRoot 'current.json')))) -and (Test-PshGoal5LifecycleBytesEqual $uninstallOwnershipBeforeWhatIf ([IO.File]::ReadAllBytes((Join-Path $installRoot 'ownership.json')))) -and (Test-PshGoal5LifecycleBytesEqual $uninstallProfileBeforeWhatIf ([IO.File]::ReadAllBytes($profilePath))) -and -not [IO.File]::Exists((Join-Path $installRoot 'transaction.json'))) 'Uninstall -WhatIf changed lifecycle state.'

    $uninstallObstruction = Join-Path $installRoot '.staging'
    if ([IO.Directory]::Exists($uninstallObstruction)) { if (@(Get-ChildItem -LiteralPath $uninstallObstruction -Force).Count -eq 0) { [IO.Directory]::Delete($uninstallObstruction, $false) } else { throw 'Unexpected staging artifacts blocked the obstruction probe.' } }
    [IO.File]::WriteAllText($uninstallObstruction, 'file obstruction', $script:Utf8)
    $uninstallObstructionFailure = Invoke-PshGoal5LifecycleFailure { & $uninstallScript -InstallRoot $installRoot -ProfilePath @($profilePath) -ModuleRoot @() -WhatIf -Confirm:$false }
    Assert-PshGoal5Lifecycle ([int]$uninstallObstructionFailure.Exception.Data['PshExitCode'] -eq 5 -and (Test-PshGoal5LifecycleBytesEqual $uninstallCurrentBeforeWhatIf ([IO.File]::ReadAllBytes((Join-Path $installRoot 'current.json')))) -and -not [IO.File]::Exists((Join-Path $installRoot 'transaction.json'))) 'Uninstall accepted a .staging file obstruction.'
    [IO.File]::Delete($uninstallObstruction)

    $lockedPath = Join-Path $installRoot 'versions/0.0.1-test/Psh/Psh.psm1'
    $lockStream = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { $lockedResult = @(& $uninstallScript -InstallRoot $installRoot -ProfilePath @($profilePath) -ModuleRoot @() -Confirm:$false)[-1] }
    finally { $lockStream.Dispose() }
    Assert-PshGoal5Lifecycle (-not [bool]$lockedResult.success -and [int]$lockedResult.code -eq 3 -and [bool]$lockedResult.restartRequired) 'Locked file did not return structured restartRequired/code 3.'
    Assert-PshGoal5Lifecycle ([IO.File]::Exists($lockedPath)) 'Locked-file preflight removed installed content.'

    $uninstall = @(& $uninstallScript -InstallRoot $installRoot -ProfilePath @($profilePath) -ModuleRoot @() -Confirm:$false)
    $uninstallResult = $uninstall[-1]
    Assert-PshGoal5Lifecycle ([bool]$uninstallResult.success -and -not [bool]$uninstallResult.restartRequired) 'Ownership-safe uninstall failed.'
    Assert-PshGoal5Lifecycle ([IO.File]::ReadAllText($profilePath, $script:Utf8) -ceq $originalProfile) 'Uninstall did not restore the original profile bytes.'
    Assert-PshGoal5Lifecycle (-not [IO.File]::Exists((Join-Path $installRoot 'ownership.json'))) 'Uninstall retained completed ownership state.'
    Assert-PshGoal5Lifecycle (-not [IO.File]::Exists((Join-Path $installRoot 'current.json'))) 'Uninstall retained the owned current pointer.'

    $componentRoot = Join-Path $testRoot 'component-bundled/Psh'
    $componentProfile = Join-Path $testRoot 'component-bundled/profile.ps1'
    $componentModuleRoot = Join-Path $testRoot 'component-bundled/modules'
    $componentProfileOriginal = "# bundled component profile`r`n"
    Write-PshGoal5LifecycleText -Path $componentProfile -Text $componentProfileOriginal
    $componentPackage = New-PshGoal5LifecyclePackage -Root (Join-Path $testRoot 'packages/component-bundled') -Version '0.0.4-test' -Marker 'component-bundled' -BundleComponents
    $componentInstall = @(& $installScript -PackageRoot $componentPackage -InstallRoot $componentRoot -ProfilePath @($componentProfile) -ModuleRoot @($componentModuleRoot) -Offline -Confirm:$false)
    $componentOwnership = Read-PshOwnershipState -InstallRoot $componentRoot
    Assert-PshGoal5Lifecycle ([bool]$componentInstall[-1].success -and [bool]$componentOwnership.components.profile.installed -and [bool]$componentOwnership.components.psReadLineProjection.installed) 'Bundled profile and projection components were not installed from the version payload.'
    $componentUninstall = @(& $uninstallScript -InstallRoot $componentRoot -ProfilePath @($componentProfile) -ModuleRoot @($componentModuleRoot) -Confirm:$false)
    Assert-PshGoal5Lifecycle ([bool]$componentUninstall[-1].success -and [IO.File]::ReadAllText($componentProfile, $script:Utf8) -ceq $componentProfileOriginal -and -not [IO.Directory]::Exists((Join-Path $componentModuleRoot 'PSReadLine/2.4.5')) -and -not [IO.File]::Exists((Join-Path $componentRoot 'ownership.json'))) 'Uninstall could not execute component scripts after their owned version tree moved to quarantine.'

    # The package builder must provide an edition-specific config.  Lifecycle
    # validation fails closed when the manifest and config disagree.
    $originalProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE
    $originalProcessorArchitectureW6432 = $env:PROCESSOR_ARCHITEW6432
    try {
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue
        $editionMismatchPackage = New-PshGoal5LifecyclePackage -Root (Join-Path $testRoot 'packages/edition-mismatch') -Version '0.0.5-test' -Edition Full -Architecture win-x64 -ConfigEdition Core
        $editionMismatchRoot = Join-Path $testRoot 'edition-mismatch/Psh'
        $editionMismatch = Invoke-PshGoal5LifecycleFailure { & $installScript -PackageRoot $editionMismatchPackage -InstallRoot $editionMismatchRoot -ProfilePath @() -ModuleRoot @() -Offline -Confirm:$false }
        Assert-PshGoal5Lifecycle ([int]$editionMismatch.Exception.Data['PshExitCode'] -eq 5 -and -not [IO.File]::Exists((Join-Path $editionMismatchRoot 'ownership.json'))) 'A Full package with a Core config was not rejected before ownership commit.'
        $fullPackage = New-PshGoal5LifecyclePackage -Root (Join-Path $testRoot 'packages/full') -Version '0.0.6-test' -Edition Full -Architecture win-x64
        $fullRoot = Join-Path $testRoot 'full/Psh'
        $fullInstall = @(& $installScript -PackageRoot $fullPackage -InstallRoot $fullRoot -ProfilePath @() -ModuleRoot @() -Offline -Confirm:$false)
        Assert-PshGoal5Lifecycle ([bool]$fullInstall[-1].success -and (Get-Content -LiteralPath (Join-Path $fullRoot 'config.psd1') -Raw).Contains("Edition = 'Full'")) 'A matching Full package did not persist an edition-specific config.'
    }
    finally {
        $env:PROCESSOR_ARCHITECTURE = $originalProcessorArchitecture
        if ($null -eq $originalProcessorArchitectureW6432) { Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue } else { $env:PROCESSOR_ARCHITEW6432 = $originalProcessorArchitectureW6432 }
    }

    # Mutating the original package after staging must not alter published
    # stable bytes or the script that is actually executed.
    $sourceTamperPath = Join-Path $testRoot 'packages/source-tamper/payload/install/bootstrap.ps1'
    $sourceTamperPackage = New-PshGoal5LifecyclePackage -Root (Join-Path $testRoot 'packages/source-tamper') -Version '0.0.7-test' -ProfileSourceMutationPath $sourceTamperPath
    $sourceTamperRoot = Join-Path $testRoot 'source-tamper/Psh'
    $sourceTamperProfile = Join-Path $testRoot 'source-tamper/profile.ps1'
    Write-PshGoal5LifecycleText -Path $sourceTamperProfile -Text "# source tamper profile`n"
    [byte[]]$sourceBootstrapBefore = [IO.File]::ReadAllBytes($sourceTamperPath)
    $sourceTamperInstall = @(& $installScript -PackageRoot $sourceTamperPackage -InstallRoot $sourceTamperRoot -ProfilePath @($sourceTamperProfile) -ModuleRoot @() -Offline -Confirm:$false)
    Assert-PshGoal5Lifecycle ([bool]$sourceTamperInstall[-1].success -and (Test-PshGoal5LifecycleBytesEqual $sourceBootstrapBefore ([IO.File]::ReadAllBytes((Join-Path $sourceTamperRoot 'bootstrap.ps1')))) -and ([IO.File]::ReadAllText($sourceTamperPath, $script:Utf8)).Contains('# source-after-stage-tamper')) 'Source-after-stage mutation affected or failed to prove published stable isolation.'

    # A metadata CAS conflict must leave the transaction evidence and must not
    # destructively remove the already-installed component or version tree.
    $externalOwnershipText = '{"external":true}'
    $metadataConflictPackage = New-PshGoal5LifecyclePackage -Root (Join-Path $testRoot 'packages/metadata-conflict') -Version '0.0.8-test' -SetCurrentConflictText $externalOwnershipText
    $metadataConflictRoot = Join-Path $testRoot 'metadata-conflict/Psh'
    $metadataConflictProfile = Join-Path $testRoot 'metadata-conflict/profile.ps1'
    Write-PshGoal5LifecycleText -Path $metadataConflictProfile -Text "# metadata conflict profile`n"
    $metadataConflict = Invoke-PshGoal5LifecycleFailure { & $installScript -PackageRoot $metadataConflictPackage -InstallRoot $metadataConflictRoot -ProfilePath @($metadataConflictProfile) -ModuleRoot @() -Offline -Confirm:$false }
    Assert-PshGoal5Lifecycle ([int]$metadataConflict.Exception.Data['PshExitCode'] -eq 5 -and [IO.File]::Exists((Join-Path $metadataConflictRoot 'transaction.json')) -and [IO.Directory]::Exists((Join-Path $metadataConflictRoot 'versions/0.0.8-test')) -and ([IO.File]::ReadAllText((Join-Path $metadataConflictRoot 'ownership.json'), $script:Utf8) -ceq $externalOwnershipText) -and ([IO.File]::ReadAllText($metadataConflictProfile, $script:Utf8)).Contains('# >>> Psh managed profile >>>')) 'Metadata CAS conflict performed destructive compensation or discarded evidence.'

    # Dot-sourced invocation restores the caller's WhatIfPreference, and an
    # expected-current disappearance cannot create a new pointer.
    $whatIfPreferenceRestored = & {
        $WhatIfPreference = $true
        . $installScript -PackageRoot $packageOne -InstallRoot $installRoot -ProfilePath @() -ModuleRoot @() -Offline -WhatIf -Confirm:$false | Out-Null
        return [bool]$WhatIfPreference
    }
    Assert-PshGoal5Lifecycle $whatIfPreferenceRestored 'Dot-sourced installer did not restore WhatIfPreference.'
    $casRoot = Join-Path $testRoot 'current-cas/Psh'
    [IO.Directory]::CreateDirectory((Join-Path $casRoot 'versions/0.0.9-test/Psh')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $packageOne 'payload/Psh/Psh.psd1') -Destination (Join-Path $casRoot 'versions/0.0.9-test/Psh/Psh.psd1')
    $casCurrentPath = Join-Path $casRoot 'current.json'
    Write-PshGoal5LifecycleText -Path $casCurrentPath -Text "{`"schemaVersion`":1,`"version`":`"0.0.1-test`"}`n"
    $casExpectedSha = Get-PshGoal5LifecycleHash -Path $casCurrentPath
    [IO.File]::Delete($casCurrentPath)
    $casFailure = Invoke-PshGoal5LifecycleFailure { & (Join-Path $RepositoryRoot 'src/install/Set-PshCurrentVersion.ps1') -InstallRoot $casRoot -Version '0.0.9-test' -ExpectedCurrentSha256 $casExpectedSha -Confirm:$false }
    Assert-PshGoal5Lifecycle ([int]$casFailure.Exception.Data['PshExitCode'] -eq 5 -and -not [IO.File]::Exists($casCurrentPath)) 'Expected-current disappearance was not reported as a CAS conflict or recreated the pointer.'

    Write-Output ("Goal 5 lifecycle acceptance passed: {0} assertions; synthetic packages only; no network." -f $script:Assertions)
}
finally {
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
