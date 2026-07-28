# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

param(
    [string]$GoldenRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$moduleManifest = Join-Path -Path $repositoryRoot -ChildPath 'src/Psh/Psh.psd1'
$originalLocation = (Get-Location).ProviderPath
$originalLocalAppData = $env:LOCALAPPDATA
$originalEdition = $env:PSH_EDITION
$testRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('psh-goal3-batch1-{0}' -f [Guid]::NewGuid().ToString('N'))
$outsideSentinel = $testRoot + '-outside-sentinel.txt'
$crossVolumeRoot = $null
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$covered = @{}
$assertionCount = 0

. (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers/GoldenNormalization.ps1')

function Assert-PshBatch1 {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw ('Goal 3 Batch 1 assertion failed: {0}' -f $Message)
    }
    $script:assertionCount++
}

function Invoke-PshBatch1Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    $command = Get-Command -Name ('Psh\{0}' -f $Name) -CommandType Function -ErrorAction Stop
    $output = @(& $command @Arguments)
    $exitCode = [int]$global:LASTEXITCODE
    foreach ($value in $output) {
        Assert-PshBatch1 ($value -is [string]) ('{0} leaked a formatted/non-string object of type {1}.' -f $Name, $value.GetType().FullName)
    }
    $script:covered[$Name] = $true
    return [PSCustomObject]@{
        Output = @($output | ForEach-Object { [string]$_ })
        ExitCode = $exitCode
    }
}

function Assert-PshBatch1Success {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    Assert-PshBatch1 ($Result.ExitCode -eq 0) ('{0} exited {1}: {2}' -f $Context, $Result.ExitCode, ($Result.Output -join ' | '))
}

function Test-PshBatch1RecognizedSymbolicLinkError {
    param(
        [AllowNull()]
        [string]$Message
    )

    return -not [string]::IsNullOrWhiteSpace($Message) -and
        $Message -match '(?i)required privilege|privilege is not held|operation not permitted|symbolic links?.*(?:not supported|disabled)|not supported.*symbolic link'
}

function ConvertTo-PshBatch1ExpectedSymbolicLinkTarget {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Target
    )

    if ($null -eq $Target) { return '' }
    if ($env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\') {
        return $Target.Replace('/', '\')
    }
    return $Target
}

function Compare-PshGoldenCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ActualLines,

        [Parameter(Mandatory = $true)]
        [string]$CaseRoot,

        [switch]$Mktemp
    )

    $expectedPath = Join-Path -Path $GoldenRoot -ChildPath ($Id + '.txt')
    Assert-PshBatch1 ([IO.File]::Exists($expectedPath)) ('GNU golden file is missing: {0}' -f $expectedPath)
    $expected = ConvertTo-PshGoldenNormalizedText -Text ([IO.File]::ReadAllText($expectedPath, $utf8NoBom)) -PathRoot $CaseRoot
    if ($null -eq $ActualLines) { $ActualLines = @() }
    $actual = ConvertTo-PshGoldenNormalizedText -Text ($ActualLines -join "`n") -PathRoot $CaseRoot
    if ($Mktemp) {
        $expected = [Text.RegularExpressions.Regex]::Replace($expected, '(?m)(?:<ROOT>/mktemp/)?item\.[A-Za-z0-9]+$', '<TEMP_NAME>')
        $actual = [Text.RegularExpressions.Regex]::Replace($actual, '(?m)(?:<ROOT>/mktemp/)?item\.[A-Za-z0-9]+$', '<TEMP_NAME>')
    }
    Assert-PshBatch1 (Test-PshGoldenOrdinalEqual -Left $actual -Right $expected) ('GNU golden mismatch for {0}. Expected <{1}>, actual <{2}>.' -f $Id, $expected, $actual)
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    [IO.File]::WriteAllText($outsideSentinel, 'outside-safe', $utf8NoBom)

    $callerAllScopeSentinelValue = [byte[]](7, 11, 19, 23)
    Set-Variable -Name '__pshProjection_baf0d32a_Disabled' -Value $callerAllScopeSentinelValue -Option AllScope -Scope Script -Force
    Set-Item -LiteralPath Function:\global:Restore-PshCallerFileCommandProjection_baf0d32a -Value { 'caller-function-sentinel' } -Force
    $callerRestoreFunction = Get-Command -Name Restore-PshCallerFileCommandProjection_baf0d32a -CommandType Function -ErrorAction Stop
    $callerRestoreFunction.Description = 'caller restore sentinel'
    $callerRestoreFunction.Options = [System.Management.Automation.ScopedItemOptions]::AllScope
    $callerRestoreDefinition = [string]$callerRestoreFunction.Definition

    # Collision projection: known built-ins are replaced, unrelated aliases
    # survive, and Remove-Module restores the exact built-in alias metadata.
    $baselineAliases = [ordered]@{}
    foreach ($aliasName in @('pwd', 'cd', 'ls', 'rmdir', 'cp', 'mv', 'rm')) {
        $baselineAlias = Get-Alias -Name $aliasName -ErrorAction SilentlyContinue
        if ($null -eq $baselineAlias) { continue }
        $baselineAliases[$aliasName] = [PSCustomObject]@{
            Definition = [string]$baselineAlias.Definition
            Description = [string]$baselineAlias.Description
            Options = [int]$baselineAlias.Options
        }
    }
    Set-Alias -Name touch -Value Get-Date -Scope Global -Force
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    $callerSentinelDuringImport = Get-Variable -Name '__pshProjection_baf0d32a_Disabled' -Scope Script -ErrorAction Stop
    Assert-PshBatch1 ([object]::ReferenceEquals($callerSentinelDuringImport.Value, $callerAllScopeSentinelValue) -and $callerSentinelDuringImport.Value.GetType() -eq [byte[]] -and $callerSentinelDuringImport.Options -eq [System.Management.Automation.ScopedItemOptions]::AllScope) 'ScriptsToProcess changed an unrelated caller AllScope variable.'
    $callerRestoreDuringImport = Get-Command -Name Restore-PshCallerFileCommandProjection_baf0d32a -CommandType Function -ErrorAction Stop
    Assert-PshBatch1 ([string]$callerRestoreDuringImport.Definition -ceq $callerRestoreDefinition -and [string]$callerRestoreDuringImport.Description -ceq 'caller restore sentinel' -and $callerRestoreDuringImport.Options -eq [System.Management.Automation.ScopedItemOptions]::AllScope) 'Module import changed the caller restore-function sentinel.'
    foreach ($aliasName in $baselineAliases.Keys) {
        $projectedCommand = Get-Command -Name $aliasName -ErrorAction Stop
        Assert-PshBatch1 ($projectedCommand.CommandType -eq 'Function' -and $projectedCommand.Source -eq 'Psh') ('Psh {0} did not win over the known built-in alias.' -f $aliasName)
    }
    $unrelatedTouch = Get-Alias -Name touch -ErrorAction Stop
    Assert-PshBatch1 ([string]$unrelatedTouch.Definition -ceq 'Get-Date') 'An unrelated user-defined touch alias was overwritten.'
    Remove-Item -LiteralPath Alias:touch -Force
    Remove-Module -Name Psh -ErrorAction Stop
    $callerSentinelAfterRemove = Get-Variable -Name '__pshProjection_baf0d32a_Disabled' -Scope Script -ErrorAction Stop
    Assert-PshBatch1 ([object]::ReferenceEquals($callerSentinelAfterRemove.Value, $callerAllScopeSentinelValue) -and $callerSentinelAfterRemove.Options -eq [System.Management.Automation.ScopedItemOptions]::AllScope) 'Module removal changed the caller AllScope variable.'
    foreach ($aliasName in $baselineAliases.Keys) {
        $restoredAlias = Get-Alias -Name $aliasName -ErrorAction Stop
        $baselineState = $baselineAliases[$aliasName]
        Assert-PshBatch1 ([string]$restoredAlias.Definition -ceq $baselineState.Definition) ('Remove-Module did not restore the {0} alias definition.' -f $aliasName)
        Assert-PshBatch1 ([string]$restoredAlias.Description -ceq $baselineState.Description) ('Remove-Module did not restore the {0} alias description.' -f $aliasName)
        Assert-PshBatch1 ([int]$restoredAlias.Options -eq $baselineState.Options) ('Remove-Module did not restore the {0} alias options.' -f $aliasName)
    }

    # A collision with the sole child-scope context variable fails before any
    # alias mutation and leaves the caller's AllScope value byte-for-byte intact.
    $projectionContextSentinel = [byte[]](29, 31, 37)
    Set-Variable -Name '__PshProjection_baf0d32a_Context' -Value $projectionContextSentinel -Option AllScope -Scope Script -Force
    $contextCollisionFailed = $false
    try { Import-Module -Name $moduleManifest -Force -ErrorAction Stop }
    catch { $contextCollisionFailed = $true }
    Assert-PshBatch1 $contextCollisionFailed 'An AllScope projection-context collision did not fail safely.'
    $projectionContextAfter = Get-Variable -Name '__PshProjection_baf0d32a_Context' -Scope Script -ErrorAction Stop
    Assert-PshBatch1 ([object]::ReferenceEquals($projectionContextAfter.Value, $projectionContextSentinel) -and $projectionContextAfter.Options -eq [System.Management.Automation.ScopedItemOptions]::AllScope) 'Projection-context collision changed the caller variable.'
    foreach ($aliasName in $baselineAliases.Keys) {
        $collisionAlias = Get-Alias -Name $aliasName -ErrorAction Stop
        Assert-PshBatch1 ([string]$collisionAlias.Definition -ceq [string]$baselineAliases[$aliasName].Definition) ('Projection-context failure changed alias {0}.' -f $aliasName)
    }
    Remove-Variable -Name '__PshProjection_baf0d32a_Context' -Scope Script -Force

    # Root-module initialization failure after handoff consumption must invoke
    # the caller-bound restore callback explicitly; OnRemove is not guaranteed.
    $brokenModuleRoot = Join-Path $testRoot 'broken-module'
    [void][IO.Directory]::CreateDirectory($brokenModuleRoot)
    Microsoft.PowerShell.Management\Copy-Item -Path (Join-Path $repositoryRoot 'src/Psh/*') -Destination $brokenModuleRoot -Recurse -Force -ErrorAction Stop
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Join-Path $brokenModuleRoot 'Commands/FileCommands.ps1') -Force -ErrorAction Stop
    $brokenImportFailed = $false
    try { Import-Module -Name (Join-Path $brokenModuleRoot 'Psh.psd1') -Force -ErrorAction Stop }
    catch { $brokenImportFailed = $true }
    Assert-PshBatch1 $brokenImportFailed 'Broken root-module initialization unexpectedly succeeded.'
    Assert-PshBatch1 ($null -eq (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction SilentlyContinue)) 'Broken module import leaked the alias handoff variable.'
    foreach ($aliasName in $baselineAliases.Keys) {
        $failureAlias = Get-Alias -Name $aliasName -ErrorAction Stop
        Assert-PshBatch1 ([string]$failureAlias.Definition -ceq [string]$baselineAliases[$aliasName].Definition -and [string]$failureAlias.Description -ceq [string]$baselineAliases[$aliasName].Description -and [int]$failureAlias.Options -eq [int]$baselineAliases[$aliasName].Options) ('Broken module import did not restore alias {0} exactly.' -f $aliasName)
    }

    # A caller alias created while Psh is loaded wins after unload; restoration
    # never overwrites state the user created after import.
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    Set-Alias -Name pwd -Value Get-Date -Scope Global -Force
    Remove-Module -Name Psh -ErrorAction Stop
    $latePwdAlias = Get-Alias -Name pwd -ErrorAction Stop
    Assert-PshBatch1 ([string]$latePwdAlias.Definition -ceq 'Get-Date') 'Remove-Module overwrote a caller alias created after import.'
    Remove-Item -LiteralPath Alias:pwd -Force
    if ($baselineAliases.Contains('pwd')) {
        Set-Alias -Name pwd -Value ([string]$baselineAliases.pwd.Definition) -Description ([string]$baselineAliases.pwd.Description) -Option ([System.Management.Automation.ScopedItemOptions]$baselineAliases.pwd.Options) -Scope Global -Force
    }

    # Disabled commands remain absent from the module export and fall back to
    # the original alias/native command in a fresh import.
    $isolatedLocalAppData = Join-Path -Path $testRoot -ChildPath 'config-local'
    $configDirectory = Join-Path -Path $isolatedLocalAppData -ChildPath 'Psh'
    [void][IO.Directory]::CreateDirectory($configDirectory)
    [IO.File]::WriteAllText((Join-Path $configDirectory 'config.psd1'), "@{ SchemaVersion = 1; Edition = 'Core'; DisabledCommands = @('pwd', 'find') }`n", $utf8NoBom)
    $env:LOCALAPPDATA = $isolatedLocalAppData
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    $disabledPwd = Get-Command -Name pwd -ErrorAction Stop
    Assert-PshBatch1 ($disabledPwd.CommandType -eq 'Alias' -and $disabledPwd.Definition -eq 'Get-Location') 'DisabledCommands did not preserve the pwd built-in alias fallback.'
    Assert-PshBatch1 ($null -eq (Get-Command -Name 'Psh\pwd' -ErrorAction SilentlyContinue)) 'Disabled pwd remained exported by Psh.'
    $disabledFind = Get-Command -Name find -ErrorAction Stop
    Assert-PshBatch1 ($disabledFind.Source -ne 'Psh') 'Disabled find did not fall back to the native command.'
    Remove-Module -Name Psh -ErrorAction Stop

    $env:LOCALAPPDATA = $originalLocalAppData
    $env:PSH_EDITION = 'Core'
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    foreach ($nativeCollision in @('tree', 'find')) {
        $projectedNative = Get-Command -Name $nativeCollision -ErrorAction Stop
        Assert-PshBatch1 ($projectedNative.CommandType -eq 'Function' -and $projectedNative.Source -eq 'Psh') ('Psh {0} did not win over the native command name.' -f $nativeCollision)
    }

    $fixtureRoot = Join-Path -Path $testRoot -ChildPath '中文 file space'
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    Set-Location -LiteralPath $fixtureRoot
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'lf.txt'), "alpha`nbeta`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'crlf.txt'), "alpha`r`nbeta`r`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'utf16le.txt'), "alpha`r`nbeta`r`n", (New-Object Text.UnicodeEncoding($false, $true)))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'utf16be.txt'), "alpha`r`nbeta`r`n", (New-Object Text.UnicodeEncoding($true, $true)))
    [IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'empty.bin'), (New-Object byte[] 0))
    [IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'binary.bin'), [byte[]](0, 1, 2, 255, 10, 0))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot '.hidden.txt'), 'hidden', $utf8NoBom)
    [void][IO.Directory]::CreateDirectory((Join-Path $fixtureRoot '.hidden-dir'))

    $pwdResult = Invoke-PshBatch1Command -Name pwd -Arguments @('-L')
    Assert-PshBatch1Success -Result $pwdResult -Context 'pwd -L'
    Assert-PshBatch1 ([IO.Path]::GetFullPath($pwdResult.Output[0]) -eq [IO.Path]::GetFullPath($fixtureRoot)) 'pwd returned the wrong location.'

    [void][IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'cd child'))
    $cdResult = Invoke-PshBatch1Command -Name cd -Arguments @('cd child')
    Assert-PshBatch1Success -Result $cdResult -Context 'cd'
    Assert-PshBatch1 ((Get-Location).ProviderPath -eq (Join-Path $fixtureRoot 'cd child')) 'cd did not update the caller location.'
    [void](Invoke-PshBatch1Command -Name cd -Arguments @('..'))

    $lsResult = Invoke-PshBatch1Command -Name ls -Arguments @('-1')
    Assert-PshBatch1Success -Result $lsResult -Context 'ls'
    Assert-PshBatch1 ($lsResult.Output -contains 'lf.txt') 'ls omitted a visible file.'
    Assert-PshBatch1 ($lsResult.Output -notcontains '.hidden.txt') 'ls exposed hidden content without -a.'
    $lsAll = Invoke-PshBatch1Command -Name ls -Arguments @('-al')
    Assert-PshBatch1Success -Result $lsAll -Context 'ls -al'
    Assert-PshBatch1 (($lsAll.Output -join "`n") -match '\.hidden\.txt') 'ls -a omitted a hidden file.'
    Assert-PshBatch1 (@($lsAll.Output | Where-Object { $_ -match "`t" }).Count -gt 0) 'ls -l did not emit structural tab-separated text.'
    $lsHumanRecursive = Invoke-PshBatch1Command -Name ls -Arguments @('-lhR', '.')
    Assert-PshBatch1 ($lsHumanRecursive.ExitCode -eq 0 -and ($lsHumanRecursive.Output -join "`n") -match '[0-9]+(?:\.[0-9])?[BKMGT]\t') 'ls -lhR did not emit human-readable recursive structural output.'
    $lsHumanOnly = Invoke-PshBatch1Command -Name ls -Arguments @('-h')
    Assert-PshBatch1 ($lsHumanOnly.ExitCode -eq 0 -and $lsHumanOnly.Output -contains 'lf.txt') 'ls -h alone was rejected or omitted a visible file.'

    $mkdirResult = Invoke-PshBatch1Command -Name mkdir -Arguments @('-pv', 'made/one/two')
    Assert-PshBatch1Success -Result $mkdirResult -Context 'mkdir -pv'
    Assert-PshBatch1 ([IO.Directory]::Exists((Join-Path $fixtureRoot 'made/one/two'))) 'mkdir did not create nested directories.'
    $rmdirResult = Invoke-PshBatch1Command -Name rmdir -Arguments @('-pv', 'made/one/two')
    Assert-PshBatch1Success -Result $rmdirResult -Context 'rmdir -pv'
    Assert-PshBatch1 (-not [IO.Directory]::Exists((Join-Path $fixtureRoot 'made'))) 'rmdir -p did not remove the requested parent chain.'
    Assert-PshBatch1 ([IO.Directory]::Exists($fixtureRoot)) 'rmdir -p escaped the working test directory.'
    $rmdirLexicalRoot = Join-Path $testRoot 'rmdir lexical parent'
    [void][IO.Directory]::CreateDirectory((Join-Path $rmdirLexicalRoot 'one/two'))
    $rmdirLexicalOperand = Join-Path -Path (Join-Path -Path '..' -ChildPath 'rmdir lexical parent') -ChildPath 'one/two'
    $rmdirLexical = Invoke-PshBatch1Command -Name rmdir -Arguments @('-p', $rmdirLexicalOperand)
    Assert-PshBatch1 ($rmdirLexical.ExitCode -eq 0 -and -not [IO.Directory]::Exists($rmdirLexicalRoot) -and [IO.Directory]::Exists($fixtureRoot)) 'rmdir -p stopped at CWD instead of removing only the named lexical parent chain.'
    $rmdirRoot = [IO.Path]::GetPathRoot($fixtureRoot)
    $rmdirProtectedRoot = Invoke-PshBatch1Command -Name rmdir -Arguments @('-p', $rmdirRoot)
    Assert-PshBatch1 ($rmdirProtectedRoot.ExitCode -eq 3 -and [IO.Directory]::Exists($rmdirRoot)) 'rmdir -p did not refuse the file-system root.'
    $rmdirHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (-not [string]::IsNullOrWhiteSpace($rmdirHome)) {
        $rmdirProtectedHome = Invoke-PshBatch1Command -Name rmdir -Arguments @('-p', $rmdirHome)
        Assert-PshBatch1 ($rmdirProtectedHome.ExitCode -eq 3 -and [IO.Directory]::Exists($rmdirHome)) 'rmdir -p did not refuse the exact home directory.'
    }

    $copyDirectory = Join-Path $fixtureRoot 'copy cases'
    [void][IO.Directory]::CreateDirectory($copyDirectory)
    $copySource = Join-Path $copyDirectory 'source.bin'
    $copyTarget = Join-Path $copyDirectory 'target.bin'
    [IO.File]::WriteAllBytes($copySource, [byte[]](0, 3, 10, 13, 255))
    $cpResult = Invoke-PshBatch1Command -Name cp -Arguments @('-vp', $copySource, $copyTarget)
    Assert-PshBatch1Success -Result $cpResult -Context 'cp -vp'
    Assert-PshBatch1 ([Convert]::ToBase64String([IO.File]::ReadAllBytes($copySource)) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($copyTarget))) 'cp did not preserve binary bytes.'
    $copyNoClobberBefore = [IO.File]::ReadAllBytes($copyTarget)
    [IO.File]::WriteAllText($copySource, 'changed', $utf8NoBom)
    [void](Invoke-PshBatch1Command -Name cp -Arguments @('-n', $copySource, $copyTarget))
    Assert-PshBatch1 ([Convert]::ToBase64String([IO.File]::ReadAllBytes($copyTarget)) -ceq [Convert]::ToBase64String($copyNoClobberBefore)) 'cp -n overwrote an existing target.'
    $copyTreeSource = Join-Path $copyDirectory 'tree source'
    $copyTreeTarget = Join-Path $copyDirectory 'tree target'
    [void][IO.Directory]::CreateDirectory((Join-Path $copyTreeSource 'nested'))
    [IO.File]::WriteAllText((Join-Path $copyTreeSource 'nested/value.txt'), 'recursive', $utf8NoBom)
    $copyTree = Invoke-PshBatch1Command -Name cp -Arguments @('-R', $copyTreeSource, $copyTreeTarget)
    Assert-PshBatch1 ($copyTree.ExitCode -eq 0 -and [IO.File]::Exists((Join-Path $copyTreeTarget 'nested/value.txt'))) 'cp -R did not recursively copy a directory.'
    [IO.File]::SetLastWriteTimeUtc($copyTarget, [DateTime]'2030-01-01T00:00:00Z')
    $copyUpdate = Invoke-PshBatch1Command -Name cp -Arguments @('-u', $copySource, $copyTarget)
    Assert-PshBatch1 ($copyUpdate.ExitCode -eq 0 -and [IO.File]::GetLastWriteTimeUtc($copyTarget).Year -eq 2030) 'cp -u overwrote a newer destination.'
    $copyForceSource = Join-Path $copyDirectory 'copy-force-source.txt'
    $copyForceTarget = Join-Path $copyDirectory 'copy-force-target.txt'
    [IO.File]::WriteAllText($copyForceSource, 'forced-new', $utf8NoBom)
    [IO.File]::WriteAllText($copyForceTarget, 'readonly-old', $utf8NoBom)
    [IO.File]::SetAttributes($copyForceTarget, ([IO.File]::GetAttributes($copyForceTarget) -bor [IO.FileAttributes]::ReadOnly))
    $copyForce = Invoke-PshBatch1Command -Name cp -Arguments @('-f', $copyForceSource, $copyForceTarget)
    Assert-PshBatch1 ($copyForce.ExitCode -eq 0 -and [IO.File]::ReadAllText($copyForceTarget, $utf8NoBom) -ceq 'forced-new') 'cp -f did not replace a read-only destination.'

    $moveTarget = Join-Path $copyDirectory 'moved.bin'
    $mvResult = Invoke-PshBatch1Command -Name mv -Arguments @('-v', $copyTarget, $moveTarget)
    Assert-PshBatch1Success -Result $mvResult -Context 'mv -v'
    Assert-PshBatch1 ([IO.File]::Exists($moveTarget) -and -not [IO.File]::Exists($copyTarget)) 'mv did not move the source.'
    $moveUpdateSource = Join-Path $copyDirectory 'move-update-source.txt'
    $moveUpdateTarget = Join-Path $copyDirectory 'move-update-target.txt'
    [IO.File]::WriteAllText($moveUpdateSource, 'old', $utf8NoBom)
    [IO.File]::WriteAllText($moveUpdateTarget, 'new', $utf8NoBom)
    [IO.File]::SetLastWriteTimeUtc($moveUpdateSource, [DateTime]'2020-01-01T00:00:00Z')
    [IO.File]::SetLastWriteTimeUtc($moveUpdateTarget, [DateTime]'2030-01-01T00:00:00Z')
    $moveUpdate = Invoke-PshBatch1Command -Name mv -Arguments @('-u', $moveUpdateSource, $moveUpdateTarget)
    Assert-PshBatch1 ($moveUpdate.ExitCode -eq 0 -and [IO.File]::Exists($moveUpdateSource)) 'mv -u moved a source over a newer destination.'
    $moveReplaceSource = Join-Path $copyDirectory 'move-replace-source.txt'
    $moveReplaceTarget = Join-Path $copyDirectory 'move-replace-target.txt'
    [IO.File]::WriteAllText($moveReplaceSource, 'replacement-source', $utf8NoBom)
    [IO.File]::WriteAllText($moveReplaceTarget, 'replacement-target', $utf8NoBom)
    $moveReplace = Invoke-PshBatch1Command -Name mv -Arguments @($moveReplaceSource, $moveReplaceTarget)
    Assert-PshBatch1 ($moveReplace.ExitCode -eq 0 -and -not [IO.File]::Exists($moveReplaceSource) -and [IO.File]::ReadAllText($moveReplaceTarget, $utf8NoBom) -ceq 'replacement-source') 'mv did not atomically replace an existing file.'

    if ($env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\') {
        $fixtureVolume = [IO.Path]::GetPathRoot($fixtureRoot)
        foreach ($drive in [IO.DriveInfo]::GetDrives()) {
            try {
                if (-not $drive.IsReady -or [string]::Equals($drive.RootDirectory.FullName, $fixtureVolume, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $candidateRoot = Join-Path $drive.RootDirectory.FullName ('psh-goal3-cross-volume-{0}' -f [Guid]::NewGuid().ToString('N'))
                [void][IO.Directory]::CreateDirectory($candidateRoot)
                $crossVolumeRoot = $candidateRoot
                break
            }
            catch { [void]$_.Exception.Message }
        }
        if (-not [string]::IsNullOrWhiteSpace($crossVolumeRoot)) {
            $crossVolumeSource = Join-Path $copyDirectory 'cross-volume-source.txt'
            $crossVolumeTarget = Join-Path $crossVolumeRoot 'cross-volume-target.txt'
            [IO.File]::WriteAllText($crossVolumeSource, 'cross-volume-new', $utf8NoBom)
            [IO.File]::WriteAllText($crossVolumeTarget, 'cross-volume-old', $utf8NoBom)
            $crossVolumeMove = Invoke-PshBatch1Command -Name mv -Arguments @($crossVolumeSource, $crossVolumeTarget)
            Assert-PshBatch1 ($crossVolumeMove.ExitCode -eq 0 -and -not [IO.File]::Exists($crossVolumeSource) -and [IO.File]::ReadAllText($crossVolumeTarget, $utf8NoBom) -ceq 'cross-volume-new') 'mv did not replace an existing file across writable Windows volumes.'
        }
        else {
            Write-Output 'INFO: real cross-volume mv requires a second writable Windows volume; forced transaction coverage executed.'
        }
    }
    else {
        Write-Output 'INFO: real cross-volume mv is conditional on a second writable Windows volume; forced transaction coverage executed.'
    }

    # Exercise the destination-side copy/commit/delete path even on a single-volume host.
    $moveStageSource = Join-Path $copyDirectory 'move-stage-source.txt'
    $moveStageTarget = Join-Path $copyDirectory 'move-stage-target.txt'
    [IO.File]::WriteAllText($moveStageSource, 'staged-source', $utf8NoBom)
    [IO.File]::WriteAllText($moveStageTarget, 'staged-target', $utf8NoBom)
    $fileCommandModule = Get-Module -Name Psh -ErrorAction Stop
    & $fileCommandModule {
        param($Source, $Destination)
        $sourceItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Source -Force -ErrorAction Stop
        Move-PshEntryTransactionally -SourceItem $sourceItem -Destination $Destination
    } $moveStageSource $moveStageTarget
    Assert-PshBatch1 (-not [IO.File]::Exists($moveStageSource) -and [IO.File]::ReadAllText($moveStageTarget, $utf8NoBom) -ceq 'staged-source') 'The cross-volume move transaction did not commit a staged file and remove its source.'

    $moveDirectoryParent = Join-Path $copyDirectory 'move-directory-parent'
    $moveDirectorySource = Join-Path $copyDirectory 'move-empty-replacement'
    $moveDirectoryTarget = Join-Path $moveDirectoryParent 'move-empty-replacement'
    [void][IO.Directory]::CreateDirectory($moveDirectorySource)
    [void][IO.Directory]::CreateDirectory($moveDirectoryTarget)
    [IO.File]::WriteAllText((Join-Path $moveDirectorySource 'moved.txt'), 'directory-source', $utf8NoBom)
    $moveEmptyDirectory = Invoke-PshBatch1Command -Name mv -Arguments @($moveDirectorySource, $moveDirectoryParent)
    Assert-PshBatch1 ($moveEmptyDirectory.ExitCode -eq 0 -and -not [IO.Directory]::Exists($moveDirectorySource) -and [IO.File]::ReadAllText((Join-Path $moveDirectoryTarget 'moved.txt'), $utf8NoBom) -ceq 'directory-source') 'mv did not replace an existing empty same-type directory.'

    $moveNonEmptySource = Join-Path $copyDirectory 'move-nonempty-replacement'
    $moveNonEmptyTarget = Join-Path $moveDirectoryParent 'move-nonempty-replacement'
    [void][IO.Directory]::CreateDirectory($moveNonEmptySource)
    [void][IO.Directory]::CreateDirectory($moveNonEmptyTarget)
    [IO.File]::WriteAllText((Join-Path $moveNonEmptySource 'source.txt'), 'source-safe', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $moveNonEmptyTarget 'target.txt'), 'target-safe', $utf8NoBom)
    $moveNonEmptyDirectory = Invoke-PshBatch1Command -Name mv -Arguments @($moveNonEmptySource, $moveDirectoryParent)
    Assert-PshBatch1 ($moveNonEmptyDirectory.ExitCode -eq 3 -and [IO.File]::ReadAllText((Join-Path $moveNonEmptySource 'source.txt'), $utf8NoBom) -ceq 'source-safe' -and [IO.File]::ReadAllText((Join-Path $moveNonEmptyTarget 'target.txt'), $utf8NoBom) -ceq 'target-safe') 'mv mutated a source or non-empty destination directory while rejecting replacement.'

    $moveDirectorySource = Join-Path $copyDirectory 'move-directory-source'
    $moveFileTarget = Join-Path $copyDirectory 'move-file-target.txt'
    [void][IO.Directory]::CreateDirectory($moveDirectorySource)
    [IO.File]::WriteAllText((Join-Path $moveDirectorySource 'keep.txt'), 'source-directory-safe', $utf8NoBom)
    [IO.File]::WriteAllText($moveFileTarget, 'target-file-safe', $utf8NoBom)
    $moveTypeMismatch = Invoke-PshBatch1Command -Name mv -Arguments @($moveDirectorySource, $moveFileTarget)
    Assert-PshBatch1 ($moveTypeMismatch.ExitCode -eq 3 -and [IO.Directory]::Exists($moveDirectorySource) -and [IO.File]::ReadAllText($moveFileTarget, $utf8NoBom) -ceq 'target-file-safe') 'mv destroyed an existing file while rejecting a directory-over-file move.'
    $moveFileMismatchParent = Join-Path $copyDirectory 'move-file-mismatch-parent'
    $moveFileMismatchSource = Join-Path $copyDirectory 'move-file-mismatch'
    $moveFileMismatchTarget = Join-Path $moveFileMismatchParent 'move-file-mismatch'
    [void][IO.Directory]::CreateDirectory($moveFileMismatchTarget)
    [IO.File]::WriteAllText($moveFileMismatchSource, 'file-source-safe', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $moveFileMismatchTarget 'keep.txt'), 'directory-target-safe', $utf8NoBom)
    $moveFileTypeMismatch = Invoke-PshBatch1Command -Name mv -Arguments @($moveFileMismatchSource, $moveFileMismatchParent)
    Assert-PshBatch1 ($moveFileTypeMismatch.ExitCode -eq 3 -and [IO.File]::ReadAllText($moveFileMismatchSource, $utf8NoBom) -ceq 'file-source-safe' -and [IO.File]::ReadAllText((Join-Path $moveFileMismatchTarget 'keep.txt'), $utf8NoBom) -ceq 'directory-target-safe') 'mv mutated a file or directory while rejecting a file-over-directory move.'

    $installFailureRoot = Join-Path $copyDirectory 'install rollback failure'
    [void][IO.Directory]::CreateDirectory($installFailureRoot)
    $installFailureStage = Join-Path $installFailureRoot 'stage.txt'
    $installFailureTarget = Join-Path $installFailureRoot 'target.txt'
    [IO.File]::WriteAllText($installFailureStage, 'new-value', $utf8NoBom)
    [IO.File]::WriteAllText($installFailureTarget, 'old-value', $utf8NoBom)
    $installFailureState = & $fileCommandModule {
        param($Stage, $Destination)
        try {
            Install-PshStagedEntry -Stage $Stage -Destination $Destination -BeforeInstall { throw 'injected install failure' } -BeforeRollback { throw 'injected rollback failure' }
            return [PSCustomObject]@{ Failed = $false; Message = ''; Backup = '' }
        }
        catch {
            $message = [string]$_.Exception.Message
            $backup = ''
            if ($message -match 'original retained at: (?<path>.+)$') { $backup = [string]$Matches.path }
            return [PSCustomObject]@{ Failed = $true; Message = $message; Backup = $backup }
        }
    } $installFailureStage $installFailureTarget
    Assert-PshBatch1 ($installFailureState.Failed -and $installFailureState.Message -match 'staged install failed.*rollback failed' -and -not [string]::IsNullOrWhiteSpace($installFailureState.Backup) -and [IO.File]::ReadAllText($installFailureState.Backup, $utf8NoBom) -ceq 'old-value' -and [IO.File]::ReadAllText($installFailureStage, $utf8NoBom) -ceq 'new-value') 'A staged install plus rollback failure did not retain and report the original destination backup.'

    $directoryCleanupSource = Join-Path $copyDirectory 'directory-cleanup-source'
    $directoryCleanupTarget = Join-Path $copyDirectory 'directory-cleanup-target'
    [void][IO.Directory]::CreateDirectory($directoryCleanupSource)
    [void][IO.Directory]::CreateDirectory($directoryCleanupTarget)
    [IO.File]::WriteAllText((Join-Path $directoryCleanupSource 'complete.txt'), 'complete-copy', $utf8NoBom)
    $directoryCleanupState = & $fileCommandModule {
        param($Source, $Destination)
        $sourceItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Source -Force -ErrorAction Stop
        try {
            Move-PshEntryTransactionally -SourceItem $sourceItem -Destination $Destination -BeforeSourceRemoval { throw 'injected directory cleanup failure' }
            return [PSCustomObject]@{ Failed = $false; Message = ''; Backup = '' }
        }
        catch {
            $message = [string]$_.Exception.Message
            $backup = ''
            if ($message -match 'original destination retained at: (?<path>.+); source may be incomplete') { $backup = [string]$Matches.path }
            return [PSCustomObject]@{ Failed = $true; Message = $message; Backup = $backup }
        }
    } $directoryCleanupSource $directoryCleanupTarget
    Assert-PshBatch1 ($directoryCleanupState.Failed -and $directoryCleanupState.Message -match 'directory source cleanup failed' -and [IO.File]::ReadAllText((Join-Path $directoryCleanupSource 'complete.txt'), $utf8NoBom) -ceq 'complete-copy' -and [IO.File]::ReadAllText((Join-Path $directoryCleanupTarget 'complete.txt'), $utf8NoBom) -ceq 'complete-copy' -and -not [string]::IsNullOrWhiteSpace($directoryCleanupState.Backup) -and [IO.Directory]::Exists($directoryCleanupState.Backup)) 'A directory source cleanup failure did not retain the installed full copy and original destination recovery path.'

    $removePath = Join-Path $copyDirectory 'remove.txt'
    [IO.File]::WriteAllText($removePath, 'remove', $utf8NoBom)
    $rmResult = Invoke-PshBatch1Command -Name rm -Arguments @('-v', $removePath)
    Assert-PshBatch1Success -Result $rmResult -Context 'rm -v'
    Assert-PshBatch1 (-not [IO.File]::Exists($removePath)) 'rm did not remove the file.'
    $removeTree = Join-Path $copyDirectory 'remove tree'
    [void][IO.Directory]::CreateDirectory((Join-Path $removeTree 'nested'))
    [IO.File]::WriteAllText((Join-Path $removeTree 'nested/value.txt'), 'remove tree', $utf8NoBom)
    $rmTree = Invoke-PshBatch1Command -Name rm -Arguments @('-r', $removeTree)
    Assert-PshBatch1 ($rmTree.ExitCode -eq 0 -and -not [IO.Directory]::Exists($removeTree)) 'rm -r did not recursively remove a directory.'
    $removeReadOnlyTree = Join-Path $copyDirectory 'remove readonly tree'
    [void][IO.Directory]::CreateDirectory($removeReadOnlyTree)
    $removeReadOnlyChild = Join-Path $removeReadOnlyTree 'readonly.txt'
    [IO.File]::WriteAllText($removeReadOnlyChild, 'readonly', $utf8NoBom)
    [IO.File]::SetAttributes($removeReadOnlyChild, ([IO.File]::GetAttributes($removeReadOnlyChild) -bor [IO.FileAttributes]::ReadOnly))
    $rmReadOnlyTree = Invoke-PshBatch1Command -Name rm -Arguments @('-rf', $removeReadOnlyTree)
    Assert-PshBatch1 ($rmReadOnlyTree.ExitCode -eq 0 -and -not [IO.Directory]::Exists($removeReadOnlyTree)) 'rm -rf did not remove a tree containing a read-only child.'
    $removeOutsideDirectory = Join-Path $testRoot 'rm-outside-sentinel'
    $removeBoundaryTree = Join-Path $copyDirectory 'remove symlink boundary'
    [void][IO.Directory]::CreateDirectory($removeOutsideDirectory)
    [void][IO.Directory]::CreateDirectory($removeBoundaryTree)
    $removeOutsideFile = Join-Path $removeOutsideDirectory 'keep.txt'
    [IO.File]::WriteAllText($removeOutsideFile, 'outside-readonly-safe', $utf8NoBom)
    [IO.File]::SetAttributes($removeOutsideFile, ([IO.File]::GetAttributes($removeOutsideFile) -bor [IO.FileAttributes]::ReadOnly))
    $removeOutsideAttributes = [IO.File]::GetAttributes($removeOutsideFile)
    $removeLinkCreated = $false
    $removeLinkFailure = ''
    try {
        Microsoft.PowerShell.Management\New-Item -Path (Join-Path $removeBoundaryTree 'outside-link') -ItemType SymbolicLink -Target $removeOutsideDirectory -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        $removeLinkCreated = $true
    }
    catch { $removeLinkFailure = [string]$_.Exception.Message }
    if ($removeLinkCreated) {
        $rmSymlinkBoundary = Invoke-PshBatch1Command -Name rm -Arguments @('-rf', $removeBoundaryTree)
        Assert-PshBatch1 ($rmSymlinkBoundary.ExitCode -eq 0 -and -not [IO.Directory]::Exists($removeBoundaryTree)) 'rm -rf did not remove the requested tree containing a directory link.'
        Assert-PshBatch1 ([IO.File]::ReadAllText($removeOutsideFile, $utf8NoBom) -ceq 'outside-readonly-safe' -and [IO.File]::GetAttributes($removeOutsideFile) -eq $removeOutsideAttributes) 'rm -rf followed a directory link and changed the outside target.'
    }
    else {
        Assert-PshBatch1 (-not [string]::IsNullOrWhiteSpace($removeLinkFailure)) 'Symlink boundary test was skipped without an explicit platform error.'
    }
    [IO.File]::SetAttributes($removeOutsideFile, [IO.FileAttributes]::Normal)
    $rootPath = [IO.Path]::GetPathRoot($fixtureRoot)
    $rmRoot = Invoke-PshBatch1Command -Name rm -Arguments @('-rf', $rootPath)
    Assert-PshBatch1 ($rmRoot.ExitCode -eq 3) 'rm did not refuse a file-system root.'
    $homePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (-not [string]::IsNullOrWhiteSpace($homePath)) {
        $rmHome = Invoke-PshBatch1Command -Name rm -Arguments @('-rf', $homePath)
        Assert-PshBatch1 ($rmHome.ExitCode -eq 3) 'rm did not refuse the exact home directory.'
    }
    Assert-PshBatch1 ([IO.File]::ReadAllText($outsideSentinel, $utf8NoBom) -ceq 'outside-safe') 'A destructive command changed the outside sentinel.'

    $touchPath = Join-Path $fixtureRoot 'touch created.txt'
    $touchResult = Invoke-PshBatch1Command -Name touch -Arguments @($touchPath)
    Assert-PshBatch1Success -Result $touchResult -Context 'touch'
    Assert-PshBatch1 ([IO.File]::Exists($touchPath) -and (New-Object IO.FileInfo($touchPath)).Length -eq 0) 'touch did not create an empty file.'
    $referencePath = Join-Path $fixtureRoot 'touch reference.txt'
    [IO.File]::WriteAllText($referencePath, 'reference', $utf8NoBom)
    [IO.File]::SetLastWriteTimeUtc($referencePath, [DateTime]'2024-01-02T03:04:05Z')
    $touchReference = Invoke-PshBatch1Command -Name touch -Arguments @('-r', $referencePath, $touchPath)
    Assert-PshBatch1Success -Result $touchReference -Context 'touch -r'
    Assert-PshBatch1 ([IO.File]::GetLastWriteTimeUtc($touchPath) -eq [IO.File]::GetLastWriteTimeUtc($referencePath)) 'touch -r did not copy modification time.'
    $touchTimestamp = Invoke-PshBatch1Command -Name touch -Arguments @('-t', '202607190102.03', $touchPath)
    Assert-PshBatch1 ($touchTimestamp.ExitCode -eq 0 -and [IO.File]::GetLastWriteTime($touchPath).ToString('yyyy-MM-dd HH:mm:ss') -eq '2026-07-19 01:02:03') 'touch -t did not apply the documented timestamp form.'
    $touchInvalidTimestamp = Invoke-PshBatch1Command -Name touch -Arguments @('-t', 'not-a-timestamp', $touchPath)
    Assert-PshBatch1 ($touchInvalidTimestamp.ExitCode -eq 2) 'touch -t classified an invalid timestamp as a runtime failure instead of usage error 2.'
    $objectTouch = @(Set-PshFileTime -Path $touchPath -ModificationTime ([DateTime]'2025-02-03T04:05:06Z') -ModificationOnly)
    Assert-PshBatch1 ($objectTouch.Count -eq 1 -and $objectTouch[0] -is [IO.FileInfo]) 'Set-PshFileTime did not return a file object.'

    $linkSource = Join-Path $fixtureRoot 'link source.txt'
    $linkTarget = Join-Path $fixtureRoot 'link target.txt'
    [IO.File]::WriteAllText($linkSource, 'linked', $utf8NoBom)
    $lnResult = Invoke-PshBatch1Command -Name ln -Arguments @('-v', $linkSource, $linkTarget)
    Assert-PshBatch1Success -Result $lnResult -Context 'ln -v'
    [IO.File]::AppendAllText($linkSource, '-value', $utf8NoBom)
    Assert-PshBatch1 ([IO.File]::ReadAllText($linkTarget, $utf8NoBom) -ceq 'linked-value') 'ln did not create a working hard link.'
    $moveSameFile = Invoke-PshBatch1Command -Name mv -Arguments @($linkSource, $linkTarget)
    Assert-PshBatch1 ($moveSameFile.ExitCode -eq 3 -and [IO.File]::Exists($linkSource) -and [IO.File]::Exists($linkTarget) -and [IO.File]::ReadAllText($linkSource, $utf8NoBom) -ceq 'linked-value') 'mv changed two names that already referred to the same file.'
    $linkReplacement = Join-Path $fixtureRoot 'link replacement.txt'
    [IO.File]::WriteAllText($linkReplacement, 'old-target', $utf8NoBom)
    $lnReplace = Invoke-PshBatch1Command -Name ln -Arguments @('-f', $linkSource, $linkReplacement)
    Assert-PshBatch1 ($lnReplace.ExitCode -eq 0 -and [IO.File]::ReadAllText($linkReplacement, $utf8NoBom) -ceq 'linked-value') 'ln -f did not replace an existing file with the staged link.'
    $linkSameBefore = [IO.File]::ReadAllBytes($linkSource)
    $lnSame = Invoke-PshBatch1Command -Name ln -Arguments @('-f', $linkSource, $linkSource)
    Assert-PshBatch1 ($lnSame.ExitCode -eq 3 -and [IO.File]::Exists($linkSource) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($linkSource)) -ceq [Convert]::ToBase64String($linkSameBefore)) 'ln -f destroyed its source when target and link name were identical.'
    $linkDirectory = Join-Path $fixtureRoot 'link directory sentinel'
    [void][IO.Directory]::CreateDirectory($linkDirectory)
    $linkDirectorySentinel = Join-Path $linkDirectory 'keep.txt'
    [IO.File]::WriteAllText($linkDirectorySentinel, 'directory-safe', $utf8NoBom)
    $lnDirectory = Invoke-PshBatch1Command -Name ln -Arguments @('-f', $linkSource, $linkDirectory)
    Assert-PshBatch1 ($lnDirectory.ExitCode -eq 3 -and [IO.Directory]::Exists($linkDirectory) -and [IO.File]::ReadAllText($linkDirectorySentinel, $utf8NoBom) -ceq 'directory-safe') 'ln -f recursively replaced an existing directory.'

    $symlinkRoot = Join-Path $fixtureRoot 'symlink cases'
    $symlinkReal = Join-Path $symlinkRoot 'real'
    $symlinkLinks = Join-Path $symlinkRoot 'links'
    [void][IO.Directory]::CreateDirectory((Join-Path $symlinkReal 'sub'))
    [void][IO.Directory]::CreateDirectory($symlinkLinks)
    [IO.File]::WriteAllText((Join-Path $symlinkReal 'target.txt'), 'symlink-target', $utf8NoBom)
    $directorySymlinkSupported = $false
    $directorySymlinkFailure = ''
    try {
        Set-Location -LiteralPath $symlinkLinks
        Microsoft.PowerShell.Management\New-Item -Path 'dir-link' -ItemType SymbolicLink -Target '../real' -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        Microsoft.PowerShell.Management\New-Item -Path 'sub-link' -ItemType SymbolicLink -Target '../real/sub' -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        $directorySymlinkSupported = $true
    }
    catch { $directorySymlinkFailure = [string]$_.Exception.Message }
    finally { Set-Location -LiteralPath $fixtureRoot }

    $fileSymlinkSupported = $false
    $fileSymlinkFailure = ''
    try {
        Set-Location -LiteralPath $symlinkLinks
        Microsoft.PowerShell.Management\New-Item -Path 'file-link.txt' -ItemType SymbolicLink -Target '../real/target.txt' -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        $fileSymlinkSupported = $true
    }
    catch { $fileSymlinkFailure = [string]$_.Exception.Message }
    finally { Set-Location -LiteralPath $fixtureRoot }

    if ($directorySymlinkSupported) {
        $replaceOldDirectory = Join-Path $symlinkRoot 'replace-old'
        $replaceNewDirectory = Join-Path $symlinkRoot 'replace-new'
        $replaceDirectoryLink = Join-Path $symlinkRoot 'replace-dir-link'
        [void][IO.Directory]::CreateDirectory($replaceOldDirectory)
        [void][IO.Directory]::CreateDirectory($replaceNewDirectory)
        [IO.File]::WriteAllText((Join-Path $replaceOldDirectory 'keep.txt'), 'old-directory-safe', $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $replaceNewDirectory 'keep.txt'), 'new-directory-safe', $utf8NoBom)
        Microsoft.PowerShell.Management\New-Item -Path $replaceDirectoryLink -ItemType SymbolicLink -Target $replaceOldDirectory -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        $replaceDirectoryTargetOperand = 'replace-new'
        $replaceDirectorySymlink = Invoke-PshBatch1Command -Name ln -Arguments @('-sfn', $replaceDirectoryTargetOperand, $replaceDirectoryLink)
        $replaceDirectoryLinkItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $replaceDirectoryLink -Force -ErrorAction Stop
        $replaceDirectoryTarget = [string]@($replaceDirectoryLinkItem.Target)[0]
        if ($env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\') {
            Assert-PshBatch1 ($replaceDirectorySymlink.ExitCode -eq 0) ('Windows ln -sfn failed to replace a directory symbolic link: {0}' -f ($replaceDirectorySymlink.Output -join ' | '))
            Assert-PshBatch1 (([IO.FileAttributes]$replaceDirectoryLinkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and $replaceDirectoryTarget -ceq $replaceDirectoryTargetOperand) 'Windows ln -sfn did not install a symbolic link with the literal relative directory target.'
            Assert-PshBatch1 ([IO.File]::ReadAllText((Join-Path $replaceOldDirectory 'keep.txt'), $utf8NoBom) -ceq 'old-directory-safe' -and [IO.File]::ReadAllText((Join-Path $replaceNewDirectory 'keep.txt'), $utf8NoBom) -ceq 'new-directory-safe' -and [IO.File]::ReadAllText((Join-Path $replaceDirectoryLink 'keep.txt'), $utf8NoBom) -ceq 'new-directory-safe') 'Windows ln -sfn changed a target directory or did not redirect the link to the new target.'
        }
        else {
            Assert-PshBatch1 ($replaceDirectorySymlink.ExitCode -eq 0 -and $replaceDirectoryTarget -ceq $replaceDirectoryTargetOperand -and [IO.File]::ReadAllText((Join-Path $replaceOldDirectory 'keep.txt'), $utf8NoBom) -ceq 'old-directory-safe' -and [IO.File]::ReadAllText((Join-Path $replaceNewDirectory 'keep.txt'), $utf8NoBom) -ceq 'new-directory-safe') 'ln -sfn did not replace a directory symlink itself or changed a target directory.'
        }

        $symlinkRealPhysical = (Invoke-PshBatch1Command -Name realpath -Arguments @($symlinkReal)).Output[0]
        $physicalRealpath = Invoke-PshBatch1Command -Name realpath -Arguments @((Join-Path $symlinkLinks 'dir-link/target.txt'))
        Assert-PshBatch1 ($physicalRealpath.ExitCode -eq 0 -and [IO.Path]::GetFullPath($physicalRealpath.Output[0]) -eq [IO.Path]::GetFullPath((Join-Path $symlinkRealPhysical 'target.txt'))) 'realpath did not return the physical canonical path through a directory link.'
        $physicalDotDotPath = Join-Path $symlinkLinks 'sub-link/../target.txt'
        $physicalDotDotRealpath = Invoke-PshBatch1Command -Name realpath -Arguments @($physicalDotDotPath)
        Assert-PshBatch1 ($physicalDotDotRealpath.ExitCode -eq 0 -and [IO.Path]::GetFullPath($physicalDotDotRealpath.Output[0]) -eq [IO.Path]::GetFullPath((Join-Path $symlinkRealPhysical 'target.txt'))) 'realpath collapsed .. before expanding an intermediate directory link.'
        $physicalDotDotStat = Invoke-PshBatch1Command -Name stat -Arguments @('-Lt', $physicalDotDotPath)
        $physicalDotDotFile = Invoke-PshBatch1Command -Name file -Arguments @('-bL', $physicalDotDotPath)
        Assert-PshBatch1 ($physicalDotDotStat.ExitCode -eq 0 -and $physicalDotDotStat.Output[0] -match '\tfile\t') 'stat -L did not apply .. after expanding an intermediate directory link.'
        Assert-PshBatch1 ($physicalDotDotFile.ExitCode -eq 0 -and $physicalDotDotFile.Output[0] -match 'text|Unicode') 'file -L did not apply .. after expanding an intermediate directory link.'

        $cdLogical = Invoke-PshBatch1Command -Name cd -Arguments @('-L', (Join-Path $symlinkLinks 'dir-link'))
        $pwdLogical = Invoke-PshBatch1Command -Name pwd -Arguments @('-L')
        $pwdPhysical = Invoke-PshBatch1Command -Name pwd -Arguments @('-P')
        Assert-PshBatch1 ($cdLogical.ExitCode -eq 0 -and [IO.Path]::GetFullPath($pwdLogical.Output[0]) -eq [IO.Path]::GetFullPath((Join-Path $symlinkLinks 'dir-link'))) 'cd/pwd -L did not retain the logical linked directory.'
        Assert-PshBatch1 ([IO.Path]::GetFullPath($pwdPhysical.Output[0]) -eq [IO.Path]::GetFullPath($symlinkRealPhysical)) 'pwd -P did not resolve the physical linked directory.'
        [void](Invoke-PshBatch1Command -Name cd -Arguments @($fixtureRoot))
        $cdPhysical = Invoke-PshBatch1Command -Name cd -Arguments @('-P', (Join-Path $symlinkLinks 'dir-link'))
        $pwdAfterPhysicalCd = Invoke-PshBatch1Command -Name pwd -Arguments @('-L')
        Assert-PshBatch1 ($cdPhysical.ExitCode -eq 0 -and [IO.Path]::GetFullPath($pwdAfterPhysicalCd.Output[0]) -eq [IO.Path]::GetFullPath($symlinkRealPhysical)) 'cd -P did not enter the physical directory.'
        [void](Invoke-PshBatch1Command -Name cd -Arguments @($fixtureRoot))
    }
    else {
        Assert-PshBatch1 (Test-PshBatch1RecognizedSymbolicLinkError -Message $directorySymlinkFailure) ('Directory symbolic-link setup failed for an unexpected reason: {0}' -f $directorySymlinkFailure)
        Write-Output ('SKIP: directory symbolic-link behavior unavailable: {0}' -f $directorySymlinkFailure)
    }

    if ($fileSymlinkSupported) {
        $danglingLink = Join-Path $symlinkLinks 'dangling-link.txt'
        $loopLinkA = Join-Path $symlinkLinks 'loop-a'
        $loopLinkB = Join-Path $symlinkLinks 'loop-b'
        $danglingLinkResult = Invoke-PshBatch1Command -Name ln -Arguments @('-s', '../real/missing-target.txt', $danglingLink)
        $loopLinkAResult = Invoke-PshBatch1Command -Name ln -Arguments @('-s', 'loop-b', $loopLinkA)
        $loopLinkBResult = Invoke-PshBatch1Command -Name ln -Arguments @('-s', 'loop-a', $loopLinkB)
        Assert-PshBatch1 (
            $danglingLinkResult.ExitCode -eq 0 -and
            $loopLinkAResult.ExitCode -eq 0 -and
            $loopLinkBResult.ExitCode -eq 0
        ) ('ln -s could not create the dangling and loop symbolic links: {0}' -f (@($danglingLinkResult.Output + $loopLinkAResult.Output + $loopLinkBResult.Output) -join ' | '))
        $danglingRealpath = Invoke-PshBatch1Command -Name realpath -Arguments @($danglingLink)
        $loopRealpath = Invoke-PshBatch1Command -Name realpath -Arguments @($loopLinkA)
        Assert-PshBatch1 ($danglingRealpath.ExitCode -eq 3) 'realpath did not classify a dangling symbolic link as runtime failure 3.'
        Assert-PshBatch1 ($loopRealpath.ExitCode -eq 3) 'realpath did not stop a symbolic-link loop with runtime failure 3.'

        $moveLinkSource = Join-Path $symlinkRoot 'move-link-source'
        $moveLinkTarget = Join-Path $symlinkRoot 'move-link-target'
        Microsoft.PowerShell.Management\New-Item -Path $moveLinkSource -ItemType SymbolicLink -Target (Join-Path $symlinkReal 'target.txt') -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        [IO.File]::WriteAllText($moveLinkTarget, 'replace-me', $utf8NoBom)
        $moveLink = Invoke-PshBatch1Command -Name mv -Arguments @($moveLinkSource, $moveLinkTarget)
        $movedLinkItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $moveLinkTarget -Force -ErrorAction Stop
        $movedLinkTarget = [string]@($movedLinkItem.Target)[0]
        Assert-PshBatch1 ($moveLink.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $moveLinkSource) -and [string]$movedLinkItem.LinkType -ceq 'SymbolicLink' -and $movedLinkTarget -ceq (Join-Path $symlinkReal 'target.txt')) 'mv dereferenced or changed the type of a symbolic link while replacing an existing destination.'

        $statLink = Invoke-PshBatch1Command -Name stat -Arguments @('-t', (Join-Path $symlinkLinks 'file-link.txt'))
        $statFollowLink = Invoke-PshBatch1Command -Name stat -Arguments @('-Lt', (Join-Path $symlinkLinks 'file-link.txt'))
        Assert-PshBatch1 ($statLink.ExitCode -eq 0 -and $statLink.Output[0] -match '\tlink\t') 'stat default mode did not report the symbolic link itself.'
        Assert-PshBatch1 ($statFollowLink.ExitCode -eq 0 -and $statFollowLink.Output[0] -match '\tfile\t') 'stat -L did not follow a symbolic link.'

        $fileLink = Invoke-PshBatch1Command -Name file -Arguments @('-b', (Join-Path $symlinkLinks 'file-link.txt'))
        $fileFollowLink = Invoke-PshBatch1Command -Name file -Arguments @('-bL', (Join-Path $symlinkLinks 'file-link.txt'))
        Assert-PshBatch1 ($fileLink.ExitCode -eq 0 -and $fileLink.Output[0] -match '^symbolic link to ') 'file default mode did not classify the symbolic link itself.'
        Assert-PshBatch1 ($fileFollowLink.ExitCode -eq 0 -and $fileFollowLink.Output[0] -match 'text|Unicode') 'file -L did not classify the symbolic-link target.'

        Set-Location -LiteralPath $symlinkLinks
        $literalLink = Invoke-PshBatch1Command -Name ln -Arguments @('-s', '../real/target.txt', 'literal-link.txt')
        $literalLinkItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath 'literal-link.txt' -Force -ErrorAction Stop
        $literalTarget = @($literalLinkItem.Target)[0]
        $literalTargetExpected = ConvertTo-PshBatch1ExpectedSymbolicLinkTarget -Target '../real/target.txt'
        Assert-PshBatch1 ($literalLink.ExitCode -eq 0 -and [string]$literalTarget -ceq $literalTargetExpected) 'ln -s did not preserve the relative target operand literally.'

        if ($env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\') {
            $windowsLiteralFileName = 'Windows target 空格.txt'
            [IO.File]::WriteAllText((Join-Path $symlinkReal $windowsLiteralFileName), 'windows-literal-file', $utf8NoBom)
            $windowsLiteralFileTarget = '../real/../real/' + $windowsLiteralFileName
            $windowsLiteralFileLink = 'Windows literal file link.txt'
            $windowsLiteralFileResult = Invoke-PshBatch1Command -Name ln -Arguments @('-s', $windowsLiteralFileTarget, $windowsLiteralFileLink)
            $windowsLiteralFileItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $windowsLiteralFileLink -Force -ErrorAction Stop
            $windowsLiteralFilePath =
                $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
                    $windowsLiteralFileLink
                )
            $windowsLiteralFileTargetExpected = ConvertTo-PshBatch1ExpectedSymbolicLinkTarget -Target $windowsLiteralFileTarget
            Assert-PshBatch1 ($windowsLiteralFileResult.ExitCode -eq 0 -and [string]@($windowsLiteralFileItem.Target)[0] -ceq $windowsLiteralFileTargetExpected -and [IO.File]::ReadAllText($windowsLiteralFilePath, $utf8NoBom) -ceq 'windows-literal-file') 'Windows ln -s did not preserve or resolve a relative file target containing spaces, Unicode, and .. components.'
        }
        Set-Location -LiteralPath $fixtureRoot
    }
    else {
        Assert-PshBatch1 (Test-PshBatch1RecognizedSymbolicLinkError -Message $fileSymlinkFailure) ('File symbolic-link setup failed for an unexpected reason: {0}' -f $fileSymlinkFailure)
        Write-Output ('SKIP: file symbolic-link behavior unavailable: {0}' -f $fileSymlinkFailure)
    }

    if (($env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\') -and $directorySymlinkSupported) {
        Set-Location -LiteralPath $symlinkLinks
        $windowsLiteralDirectoryName = 'Windows directory 空格'
        [void][IO.Directory]::CreateDirectory((Join-Path $symlinkReal $windowsLiteralDirectoryName))
        $windowsLiteralDirectoryTarget = '../real/../real/' + $windowsLiteralDirectoryName
        $windowsLiteralDirectoryLink = 'Windows literal directory link'
        $windowsLiteralDirectoryResult = Invoke-PshBatch1Command -Name ln -Arguments @('-s', $windowsLiteralDirectoryTarget, $windowsLiteralDirectoryLink)
        $windowsLiteralDirectoryItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $windowsLiteralDirectoryLink -Force -ErrorAction Stop
        $windowsLiteralDirectoryTargetExpected = ConvertTo-PshBatch1ExpectedSymbolicLinkTarget -Target $windowsLiteralDirectoryTarget
        Assert-PshBatch1 ($windowsLiteralDirectoryResult.ExitCode -eq 0 -and [string]@($windowsLiteralDirectoryItem.Target)[0] -ceq $windowsLiteralDirectoryTargetExpected -and $windowsLiteralDirectoryItem.PSIsContainer) 'Windows ln -s did not preserve a relative directory target or set the directory symbolic-link flag.'
        Set-Location -LiteralPath $fixtureRoot
    }

    if ($directorySymlinkSupported -or $fileSymlinkSupported) {
        $copyLinkSource = Join-Path $symlinkRoot 'copy-source'
        $copyLinkTarget = Join-Path $symlinkRoot 'copy-target'
        [void][IO.Directory]::CreateDirectory((Join-Path $copyLinkSource 'real-dir'))
        [IO.File]::WriteAllText((Join-Path $copyLinkSource 'target.txt'), 'copy-link-target', $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $copyLinkSource 'real-dir/inside.txt'), 'inside', $utf8NoBom)
        Set-Location -LiteralPath $copyLinkSource
        if ($fileSymlinkSupported) {
            Microsoft.PowerShell.Management\New-Item -Path 'file-link.txt' -ItemType SymbolicLink -Target 'target.txt' -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        }
        if ($directorySymlinkSupported) {
            Microsoft.PowerShell.Management\New-Item -Path 'dir-link' -ItemType SymbolicLink -Target 'real-dir' -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        }
        Set-Location -LiteralPath $fixtureRoot
        $sourceFileLinkType = $null
        $sourceFileLinkTarget = $null
        $sourceDirectoryLinkType = $null
        $sourceDirectoryLinkTarget = $null
        if ($fileSymlinkSupported) {
            $sourceFileLinkItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath (Join-Path $copyLinkSource 'file-link.txt') -Force -ErrorAction Stop
            $sourceFileLinkType = [string]$sourceFileLinkItem.LinkType
            $sourceFileLinkTarget = ConvertTo-PshBatch1ExpectedSymbolicLinkTarget -Target ([string]@($sourceFileLinkItem.Target)[0])
        }
        if ($directorySymlinkSupported) {
            $sourceDirectoryLinkItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath (Join-Path $copyLinkSource 'dir-link') -Force -ErrorAction Stop
            $sourceDirectoryLinkType = [string]$sourceDirectoryLinkItem.LinkType
            $sourceDirectoryLinkTarget = ConvertTo-PshBatch1ExpectedSymbolicLinkTarget -Target ([string]@($sourceDirectoryLinkItem.Target)[0])
        }
        $copyLinks = Invoke-PshBatch1Command -Name cp -Arguments @('-R', $copyLinkSource, $copyLinkTarget)
        Assert-PshBatch1 ($copyLinks.ExitCode -eq 0) 'cp -R failed while preserving supported symbolic-link types.'
        if ($fileSymlinkSupported) {
            $copiedFileLink = Microsoft.PowerShell.Management\Get-Item -LiteralPath (Join-Path $copyLinkTarget 'file-link.txt') -Force -ErrorAction Stop
            $copiedFileLinkTarget = ConvertTo-PshBatch1ExpectedSymbolicLinkTarget -Target ([string]@($copiedFileLink.Target)[0])
            Assert-PshBatch1 ($sourceFileLinkType -ceq 'SymbolicLink' -and [string]$copiedFileLink.LinkType -ceq $sourceFileLinkType -and $copiedFileLinkTarget -ceq $sourceFileLinkTarget) ('cp -R changed a nested file symbolic link. Expected LinkType={0}, Target={1}; actual LinkType={2}, Target={3}.' -f $sourceFileLinkType, $sourceFileLinkTarget, [string]$copiedFileLink.LinkType, $copiedFileLinkTarget)
        }
        if ($directorySymlinkSupported) {
            $copiedDirLink = Microsoft.PowerShell.Management\Get-Item -LiteralPath (Join-Path $copyLinkTarget 'dir-link') -Force -ErrorAction Stop
            $copiedDirectoryLinkTarget = ConvertTo-PshBatch1ExpectedSymbolicLinkTarget -Target ([string]@($copiedDirLink.Target)[0])
            Assert-PshBatch1 ($sourceDirectoryLinkType -ceq 'SymbolicLink' -and [string]$copiedDirLink.LinkType -ceq $sourceDirectoryLinkType -and $copiedDirectoryLinkTarget -ceq $sourceDirectoryLinkTarget) ('cp -R changed a nested directory symbolic link. Expected LinkType={0}, Target={1}; actual LinkType={2}, Target={3}.' -f $sourceDirectoryLinkType, $sourceDirectoryLinkTarget, [string]$copiedDirLink.LinkType, $copiedDirectoryLinkTarget)
        }
    }

    if ($env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\') {
        $junctionRoot = Join-Path $fixtureRoot 'junction cases'
        $junctionTarget = Join-Path $junctionRoot 'target'
        $junctionCopySource = Join-Path $junctionRoot 'copy-source'
        $junctionCopyTarget = Join-Path $junctionRoot 'copy-target'
        [void][IO.Directory]::CreateDirectory($junctionTarget)
        [void][IO.Directory]::CreateDirectory((Join-Path $junctionTarget 'sub'))
        [void][IO.Directory]::CreateDirectory($junctionCopySource)
        [IO.File]::WriteAllText((Join-Path $junctionTarget 'keep.txt'), 'junction-target-safe', $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $junctionTarget 'physical.txt'), 'junction-physical', $utf8NoBom)
        $junctionCopySourceLink = Join-Path $junctionCopySource 'junction-link'
        Microsoft.PowerShell.Management\New-Item -Path $junctionCopySourceLink -ItemType Junction -Target $junctionTarget -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        $sourceJunction = Microsoft.PowerShell.Management\Get-Item -LiteralPath $junctionCopySourceLink -Force -ErrorAction Stop
        $copyJunction = Invoke-PshBatch1Command -Name cp -Arguments @('-R', $junctionCopySource, $junctionCopyTarget)
        $copiedJunction = Microsoft.PowerShell.Management\Get-Item -LiteralPath (Join-Path $junctionCopyTarget 'junction-link') -Force -ErrorAction Stop
        Assert-PshBatch1 ($copyJunction.ExitCode -eq 0 -and [string]$copiedJunction.LinkType -ceq 'Junction' -and [string]@($copiedJunction.Target)[0] -ceq [string]@($sourceJunction.Target)[0] -and [IO.File]::ReadAllText((Join-Path $junctionTarget 'keep.txt'), $utf8NoBom) -ceq 'junction-target-safe') 'cp -R did not preserve a Windows Junction exactly or changed its target.'

        $resolverJunction = Join-Path $junctionRoot 'resolver-junction'
        Microsoft.PowerShell.Management\New-Item -Path $resolverJunction -ItemType Junction -Target (Join-Path $junctionTarget 'sub') -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        $junctionStat = Invoke-PshBatch1Command -Name stat -Arguments @('-t', $resolverJunction)
        $junctionStatFollow = Invoke-PshBatch1Command -Name stat -Arguments @('-Lt', $resolverJunction)
        $junctionFile = Invoke-PshBatch1Command -Name file -Arguments @('-b', $resolverJunction)
        $junctionFileFollow = Invoke-PshBatch1Command -Name file -Arguments @('-bL', $resolverJunction)
        Assert-PshBatch1 ($junctionStat.ExitCode -eq 0 -and $junctionStat.Output[0] -match '\tlink\t' -and $junctionStatFollow.ExitCode -eq 0 -and $junctionStatFollow.Output[0] -match '\tdirectory\t') 'stat default/-L did not distinguish a Windows Junction from its directory target.'
        Assert-PshBatch1 ($junctionFile.ExitCode -eq 0 -and $junctionFile.Output[0] -match '^symbolic link to ' -and $junctionFileFollow.ExitCode -eq 0 -and $junctionFileFollow.Output[0] -eq 'directory') 'file default/-L did not distinguish a Windows Junction from its directory target.'
        $junctionDotDot = Invoke-PshBatch1Command -Name realpath -Arguments @((Join-Path $resolverJunction '../physical.txt'))
        Assert-PshBatch1 ($junctionDotDot.ExitCode -eq 0 -and [IO.Path]::GetFullPath($junctionDotDot.Output[0]) -eq [IO.Path]::GetFullPath((Join-Path $junctionTarget 'physical.txt'))) 'realpath collapsed .. before expanding a Windows Junction.'

        $moveJunctionSource = Join-Path $junctionRoot 'move-source'
        $moveJunctionTarget = Join-Path $junctionRoot 'move-target'
        Microsoft.PowerShell.Management\New-Item -Path $moveJunctionSource -ItemType Junction -Target $junctionTarget -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        [IO.File]::WriteAllText($moveJunctionTarget, 'replace-junction-target', $utf8NoBom)
        $moveJunction = Invoke-PshBatch1Command -Name mv -Arguments @($moveJunctionSource, $moveJunctionTarget)
        $movedJunction = Microsoft.PowerShell.Management\Get-Item -LiteralPath $moveJunctionTarget -Force -ErrorAction Stop
        Assert-PshBatch1 ($moveJunction.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $moveJunctionSource) -and [string]$movedJunction.LinkType -ceq 'Junction' -and [string]@($movedJunction.Target)[0] -ceq $junctionTarget -and [IO.File]::ReadAllText((Join-Path $junctionTarget 'keep.txt'), $utf8NoBom) -ceq 'junction-target-safe') 'mv did not preserve a Windows Junction exactly or changed its target.'
    }
    else {
        Write-Output 'SKIP: Windows Junction preservation requires Windows; symbolic-link preservation coverage executed.'
    }

    $realDirectory = Join-Path $fixtureRoot 'real path'
    [void][IO.Directory]::CreateDirectory((Join-Path $realDirectory 'child'))
    [IO.File]::WriteAllText((Join-Path $realDirectory 'target.txt'), 'target', $utf8NoBom)
    $realDirectoryPhysical = (Invoke-PshBatch1Command -Name realpath -Arguments @($realDirectory)).Output[0]
    $realResult = Invoke-PshBatch1Command -Name realpath -Arguments @((Join-Path $realDirectory 'child/../target.txt'))
    Assert-PshBatch1Success -Result $realResult -Context 'realpath'
    Assert-PshBatch1 ([IO.Path]::GetFullPath($realResult.Output[0]) -eq [IO.Path]::GetFullPath((Join-Path $realDirectoryPhysical 'target.txt'))) 'realpath returned the wrong normalized path.'

    $baseResult = Invoke-PshBatch1Command -Name basename -Arguments @((Join-Path $fixtureRoot 'report.txt'), '.txt')
    Assert-PshBatch1Success -Result $baseResult -Context 'basename'
    Assert-PshBatch1 ($baseResult.Output.Count -eq 1 -and $baseResult.Output[0] -ceq 'report') 'basename suffix removal failed.'
    $dirResult = Invoke-PshBatch1Command -Name dirname -Arguments @((Join-Path $fixtureRoot 'child/report.txt'))
    Assert-PshBatch1Success -Result $dirResult -Context 'dirname'
    Assert-PshBatch1 ($dirResult.Output[0].Replace('\', '/').EndsWith('/child')) 'dirname returned the wrong directory component.'

    $statResult = Invoke-PshBatch1Command -Name stat -Arguments @($touchPath)
    Assert-PshBatch1Success -Result $statResult -Context 'stat'
    Assert-PshBatch1 (($statResult.Output -join "`n") -match '(?m)^Path: .+\nType: file\nSize: [0-9]+\nModified: ') 'stat default output lacks required structural fields.'
    $statSize = Invoke-PshBatch1Command -Name stat -Arguments @('-c', '%s', $touchPath)
    Assert-PshBatch1 ($statSize.ExitCode -eq 0 -and $statSize.Output[0] -match '^[0-9]+$') 'stat -c %s did not emit a numeric size.'

    $fileEmpty = Invoke-PshBatch1Command -Name file -Arguments @('-b', (Join-Path $fixtureRoot 'empty.bin'))
    $fileText = Invoke-PshBatch1Command -Name file -Arguments @('-b', (Join-Path $fixtureRoot 'crlf.txt'))
    $fileUtf16LeText = Invoke-PshBatch1Command -Name file -Arguments @('-b', (Join-Path $fixtureRoot 'utf16le.txt'))
    $fileUtf16BeText = Invoke-PshBatch1Command -Name file -Arguments @('-b', (Join-Path $fixtureRoot 'utf16be.txt'))
    $fileBinary = Invoke-PshBatch1Command -Name file -Arguments @('-bi', (Join-Path $fixtureRoot 'binary.bin'))
    $fileUtf8Mime = Invoke-PshBatch1Command -Name file -Arguments @('-bi', (Join-Path $fixtureRoot 'crlf.txt'))
    $fileUtf16LeMime = Invoke-PshBatch1Command -Name file -Arguments @('-bi', (Join-Path $fixtureRoot 'utf16le.txt'))
    $fileUtf16BeMime = Invoke-PshBatch1Command -Name file -Arguments @('-bi', (Join-Path $fixtureRoot 'utf16be.txt'))
    Assert-PshBatch1 ($fileEmpty.ExitCode -eq 0 -and $fileEmpty.Output[0] -eq 'empty') 'file did not classify an empty file.'
    Assert-PshBatch1 ($fileText.Output[0] -match 'text|Unicode') 'file did not classify CRLF text as text.'
    Assert-PshBatch1 ($fileUtf16LeText.Output[0] -eq 'UTF-16 little-endian Unicode text, with CRLF line terminators') 'file -b did not describe UTF-16LE CRLF text precisely.'
    Assert-PshBatch1 ($fileUtf16BeText.Output[0] -eq 'UTF-16 big-endian Unicode text, with CRLF line terminators') 'file -b did not describe UTF-16BE CRLF text precisely.'
    Assert-PshBatch1 ($fileBinary.Output[0] -eq 'application/octet-stream') 'file did not classify binary content structurally.'
    Assert-PshBatch1 ($fileUtf8Mime.Output[0] -eq 'text/plain; charset=utf-8') 'file -i did not report UTF-8 MIME consistently.'
    Assert-PshBatch1 ($fileUtf16LeMime.Output[0] -eq 'text/plain; charset=utf-16le') 'file -i did not report UTF-16LE MIME consistently.'
    Assert-PshBatch1 ($fileUtf16BeMime.Output[0] -eq 'text/plain; charset=utf-16be') 'file -i did not report UTF-16BE MIME consistently.'

    $treeResult = Invoke-PshBatch1Command -Name tree -Arguments @('-a', '-L', '2', '.')
    Assert-PshBatch1Success -Result $treeResult -Context 'tree'
    Assert-PshBatch1 ($treeResult.Output.Count -gt 2 -and ($treeResult.Output -join "`n") -match '\|--|`--') 'tree did not emit an ASCII hierarchy.'
    Assert-PshBatch1 (($treeResult.Output -join "`n") -match '\.hidden\.txt') 'tree -a omitted hidden content.'

    $searchRoot = Join-Path $fixtureRoot 'search cases'
    [void][IO.Directory]::CreateDirectory((Join-Path $searchRoot 'one/two'))
    [IO.File]::WriteAllText((Join-Path $searchRoot 'one/two/match.ps1'), 'match', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $searchRoot 'one/two/other.txt'), 'other', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $searchRoot '.hidden.ps1'), 'hidden', $utf8NoBom)
    [IO.File]::SetLastWriteTime((Join-Path $searchRoot 'one/two/match.ps1'), (Get-Date).AddDays(-5))
    $partialDayPath = Join-Path $searchRoot 'one/partial-day.txt'
    $completeDayPath = Join-Path $searchRoot 'one/complete-day.txt'
    $partialMinutePath = Join-Path $searchRoot 'one/partial-minute.txt'
    $completeMinutePath = Join-Path $searchRoot 'one/complete-minute.txt'
    [IO.File]::WriteAllText($partialDayPath, 'partial day', $utf8NoBom)
    [IO.File]::WriteAllText($completeDayPath, 'complete day', $utf8NoBom)
    [IO.File]::WriteAllText($partialMinutePath, 'partial minute', $utf8NoBom)
    [IO.File]::WriteAllText($completeMinutePath, 'complete minute', $utf8NoBom)
    [IO.File]::SetLastWriteTime($partialDayPath, (Get-Date).AddHours(-36))
    [IO.File]::SetLastWriteTime($completeDayPath, (Get-Date).AddHours(-60))
    [IO.File]::SetLastWriteTime($partialMinutePath, (Get-Date).AddSeconds(-90))
    [IO.File]::SetLastWriteTime($completeMinutePath, (Get-Date).AddSeconds(-150))
    $findResult = Invoke-PshBatch1Command -Name find -Arguments @($searchRoot, '-name', '*.ps1', '-type', 'f', '-mindepth', '1', '-maxdepth', '3')
    Assert-PshBatch1Success -Result $findResult -Context 'find'
    Assert-PshBatch1 ($findResult.Output.Count -eq 1 -and $findResult.Output[0].EndsWith('match.ps1')) 'find did not apply name/type/depth or hidden defaults.'
    $findFiltered = Invoke-PshBatch1Command -Name find -Arguments @($searchRoot, '-name', '*.ps1', '-type', 'f', '-size', '+3', '-mtime', '+1', '--hidden', '--exclude', '.hidden*', '-print0')
    Assert-PshBatch1 ($findFiltered.ExitCode -eq 0 -and $findFiltered.Output.Count -eq 1 -and $findFiltered.Output[0].EndsWith("match.ps1$([char]0)")) 'find did not apply size/time/exclusion/NUL-output filters.'
    $findCompleteDays = Invoke-PshBatch1Command -Name find -Arguments @($searchRoot, '-name', '*-day.txt', '-mtime', '+1')
    Assert-PshBatch1 ($findCompleteDays.ExitCode -eq 0 -and $findCompleteDays.Output.Count -eq 1 -and $findCompleteDays.Output[0].EndsWith('complete-day.txt')) 'find -mtime +1 did not require two complete 24-hour intervals.'
    $findCompleteMinutes = Invoke-PshBatch1Command -Name find -Arguments @($searchRoot, '-name', '*-minute.txt', '-mmin', '+1')
    Assert-PshBatch1 ($findCompleteMinutes.ExitCode -eq 0 -and $findCompleteMinutes.Output.Count -eq 1 -and $findCompleteMinutes.Output[0].EndsWith('complete-minute.txt')) 'find -mmin +1 did not require two complete minute intervals.'
    $findHidden = Invoke-PshBatch1Command -Name find -Arguments @($searchRoot, '-name', '.hidden.ps1', '--hidden')
    Assert-PshBatch1 ($findHidden.ExitCode -eq 0 -and $findHidden.Output.Count -eq 1) 'find --hidden did not include a hidden entry.'
    $findObjects = @(Find-PshItem -Path $searchRoot -Name '*.ps1' -Type File -MinDepth 1 -MaxDepth 3)
    Assert-PshBatch1 ($findObjects.Count -eq 1 -and $findObjects[0].PSObject.Properties.Name -contains 'Depth') 'Find-PshItem did not return structured search objects.'

    $fdResult = Invoke-PshBatch1Command -Name fd -Arguments @('-e', 'ps1', $searchRoot)
    Assert-PshBatch1Success -Result $fdResult -Context 'Core fd'
    Assert-PshBatch1 ($fdResult.Output.Count -eq 1 -and $fdResult.Output[0].EndsWith('match.ps1')) 'Core fd extension filtering failed.'
    $fdGlobExtension = Invoke-PshBatch1Command -Name fd -Arguments @('-g', 'match*', '-e', 'ps1', $searchRoot)
    Assert-PshBatch1 ($fdGlobExtension.ExitCode -eq 0 -and $fdGlobExtension.Output.Count -eq 1 -and $fdGlobExtension.Output[0].EndsWith('match.ps1')) 'Core fd combined a glob and extension using incompatible pattern syntax.'
    $fdFiltered = Invoke-PshBatch1Command -Name fd -Arguments @('-0', '-e', 'ps1', '-S', '+3', '--changed-before', '1day', '-E', '.hidden*', $searchRoot)
    Assert-PshBatch1 ($fdFiltered.ExitCode -eq 0 -and $fdFiltered.Output.Count -eq 1 -and $fdFiltered.Output[0].EndsWith("match.ps1$([char]0)")) 'Core fd did not apply size/time/exclusion/NUL-output filters.'
    $fdHidden = Invoke-PshBatch1Command -Name fd -Arguments @('-H', '-e', 'ps1', $searchRoot)
    Assert-PshBatch1 ($fdHidden.ExitCode -eq 0 -and $fdHidden.Output.Count -eq 2) 'Core fd -H did not include hidden entries.'
    $env:PSH_EDITION = 'Full'
    $fdFull = Invoke-PshBatch1Command -Name fd -Arguments @('--version')
    Assert-PshBatch1 ($fdFull.ExitCode -eq 4) 'Full fd did not report missing pinned dependency with exit 4.'
    $env:PSH_EDITION = 'Core'

    $duResult = Invoke-PshBatch1Command -Name du -Arguments @('-sh', $searchRoot)
    Assert-PshBatch1Success -Result $duResult -Context 'du -sh'
    Assert-PshBatch1 ($duResult.Output.Count -eq 1 -and $duResult.Output[0] -match '^[0-9]+(?:\.[0-9])?[BKMGT]?\t.+') 'du did not emit structural size/path text.'
    foreach ($duConflict in @(@('-a', '-s'), @('-a', '-d', '1'), @('-s', '--max-depth', '1'))) {
        $duConflictResult = Invoke-PshBatch1Command -Name du -Arguments @($duConflict + $searchRoot)
        Assert-PshBatch1 ($duConflictResult.ExitCode -eq 2) ('du accepted mutually exclusive options: {0}.' -f ($duConflict -join ' '))
    }
    $dfResult = Invoke-PshBatch1Command -Name df -Arguments @('-h', $fixtureRoot)
    Assert-PshBatch1Success -Result $dfResult -Context 'df -h'
    Assert-PshBatch1 ($dfResult.Output.Count -ge 2 -and $dfResult.Output[0] -match '^Filesystem\tSize\tUsed\tAvail\tUse%$') 'df did not emit the structural header and at least one row.'
    $dfMissing = Invoke-PshBatch1Command -Name df -Arguments @((Join-Path $fixtureRoot 'missing-df-path'))
    Assert-PshBatch1 ($dfMissing.ExitCode -ne 0) 'df accepted a missing path and reported its containing volume.'

    $temporaryParent = Join-Path $fixtureRoot 'temporary names'
    [void][IO.Directory]::CreateDirectory($temporaryParent)
    $mktempResult = Invoke-PshBatch1Command -Name mktemp -Arguments @('-p', $temporaryParent, 'item.XXXXXX')
    Assert-PshBatch1Success -Result $mktempResult -Context 'mktemp file'
    Assert-PshBatch1 ([IO.File]::Exists($mktempResult.Output[0])) 'mktemp did not atomically create a file.'
    $mktempDirectory = Invoke-PshBatch1Command -Name mktemp -Arguments @('-d', '-p', $temporaryParent, 'dir.XXXXXX')
    Assert-PshBatch1 ([IO.Directory]::Exists($mktempDirectory.Output[0])) 'mktemp -d did not create a directory.'
    $mktempDry = Invoke-PshBatch1Command -Name mktemp -Arguments @('-u', '-p', $temporaryParent, 'dry.XXXXXX')
    Assert-PshBatch1 ($mktempDry.ExitCode -eq 0 -and -not [IO.File]::Exists($mktempDry.Output[0]) -and -not [IO.Directory]::Exists($mktempDry.Output[0])) 'mktemp -u unexpectedly created the candidate.'
    Set-Location -LiteralPath $temporaryParent
    try {
        $mktempRelative = Invoke-PshBatch1Command -Name mktemp -Arguments @('relative.XXXXXX')
    }
    finally {
        Set-Location -LiteralPath $fixtureRoot
    }
    Assert-PshBatch1 ($mktempRelative.ExitCode -eq 0 -and -not [IO.Path]::IsPathRooted($mktempRelative.Output[0]) -and [IO.File]::Exists((Join-Path $temporaryParent $mktempRelative.Output[0]))) 'mktemp returned an absolute path for a relative template.'

    # Every wrapper rejects unknown option syntax with usage exit 2.
    $commandNames = @('pwd', 'cd', 'ls', 'mkdir', 'rmdir', 'cp', 'mv', 'rm', 'touch', 'ln', 'realpath', 'basename', 'dirname', 'stat', 'file', 'tree', 'find', 'fd', 'du', 'df', 'mktemp')
    foreach ($name in $commandNames) {
        $badResult = Invoke-PshBatch1Command -Name $name -Arguments @('--definitely-unsupported')
        Assert-PshBatch1 ($badResult.ExitCode -eq 2) ('{0} silently accepted unsupported option syntax.' -f $name)
    }

    if (-not [string]::IsNullOrWhiteSpace($GoldenRoot)) {
        $goldenFull = [IO.Path]::GetFullPath($GoldenRoot)
        $manifestPath = Join-Path -Path $goldenFull -ChildPath 'manifest.json'
        Assert-PshBatch1 ([IO.File]::Exists($manifestPath)) ('GNU golden manifest is missing: {0}' -f $manifestPath)
        $manifest = [IO.File]::ReadAllText($manifestPath, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
        $manifestEntries = $manifest.entries
        if ($null -eq $manifestEntries) { $manifestEntries = $manifest.cases }
        Assert-PshBatch1 (@($manifestEntries).Count -ge 14) 'GNU golden manifest does not contain the agreed Batch 1 cases.'

        $goldenCaseRoot = Join-Path $testRoot 'golden-root'
        [void][IO.Directory]::CreateDirectory($goldenCaseRoot)
        Set-Location -LiteralPath $goldenCaseRoot
        Compare-PshGoldenCase -Id pwd -ActualLines (Invoke-PshBatch1Command -Name pwd -Arguments @('-P')).Output -CaseRoot $goldenCaseRoot
        [void][IO.Directory]::CreateDirectory((Join-Path $goldenCaseRoot 'cd/child'))
        [void](Invoke-PshBatch1Command -Name cd -Arguments @('cd/child'))
        Compare-PshGoldenCase -Id cd_pwd -ActualLines (Invoke-PshBatch1Command -Name pwd -Arguments @('-P')).Output -CaseRoot $goldenCaseRoot
        Set-Location -LiteralPath $goldenCaseRoot
        Compare-PshGoldenCase -Id mkdir_verbose -ActualLines (Invoke-PshBatch1Command -Name mkdir -Arguments @('-pv', 'mkdir/one/two')).Output -CaseRoot $goldenCaseRoot
        [void][IO.Directory]::CreateDirectory((Join-Path $goldenCaseRoot 'rmdir/one/two'))
        Compare-PshGoldenCase -Id rmdir_verbose -ActualLines (Invoke-PshBatch1Command -Name rmdir -Arguments @('-pv', 'rmdir/one/two')).Output -CaseRoot $goldenCaseRoot
        foreach ($caseName in @('cp', 'mv', 'rm', 'touch', 'ln', 'realpath', 'basename', 'dirname', 'mktemp')) {
            [void][IO.Directory]::CreateDirectory((Join-Path $goldenCaseRoot $caseName))
        }
        $cpSource = Join-Path $goldenCaseRoot 'cp/source.txt'; $cpTarget = Join-Path $goldenCaseRoot 'cp/copy.txt'; [IO.File]::WriteAllText($cpSource, 'copy', $utf8NoBom)
        Compare-PshGoldenCase -Id cp_verbose -ActualLines (Invoke-PshBatch1Command -Name cp -Arguments @('-v', $cpSource, $cpTarget)).Output -CaseRoot $goldenCaseRoot
        $mvSource = Join-Path $goldenCaseRoot 'mv/source.txt'; $mvTarget = Join-Path $goldenCaseRoot 'mv/moved.txt'; [IO.File]::WriteAllText($mvSource, 'move', $utf8NoBom)
        Compare-PshGoldenCase -Id mv_verbose -ActualLines (Invoke-PshBatch1Command -Name mv -Arguments @('-v', $mvSource, $mvTarget)).Output -CaseRoot $goldenCaseRoot
        $rmPath = Join-Path $goldenCaseRoot 'rm/remove.txt'; [IO.File]::WriteAllText($rmPath, 'remove', $utf8NoBom)
        Compare-PshGoldenCase -Id rm_verbose -ActualLines (Invoke-PshBatch1Command -Name rm -Arguments @('-v', $rmPath)).Output -CaseRoot $goldenCaseRoot
        $touchGolden = Join-Path $goldenCaseRoot 'touch/created.txt'
        Compare-PshGoldenCase -Id touch_quiet -ActualLines (Invoke-PshBatch1Command -Name touch -Arguments @($touchGolden)).Output -CaseRoot $goldenCaseRoot
        $lnSource = Join-Path $goldenCaseRoot 'ln/source.txt'; $lnTarget = Join-Path $goldenCaseRoot 'ln/link.txt'; [IO.File]::WriteAllText($lnSource, 'link', $utf8NoBom)
        Compare-PshGoldenCase -Id ln_verbose -ActualLines (Invoke-PshBatch1Command -Name ln -Arguments @('-v', $lnSource, $lnTarget)).Output -CaseRoot $goldenCaseRoot
        [void][IO.Directory]::CreateDirectory((Join-Path $goldenCaseRoot 'realpath/child')); [IO.File]::WriteAllText((Join-Path $goldenCaseRoot 'realpath/target.txt'), 'real', $utf8NoBom)
        Compare-PshGoldenCase -Id realpath -ActualLines (Invoke-PshBatch1Command -Name realpath -Arguments @((Join-Path $goldenCaseRoot 'realpath/child/../target.txt'))).Output -CaseRoot $goldenCaseRoot
        Compare-PshGoldenCase -Id basename -ActualLines (Invoke-PshBatch1Command -Name basename -Arguments @((Join-Path $goldenCaseRoot 'basename/report.txt'), '.txt')).Output -CaseRoot $goldenCaseRoot
        Compare-PshGoldenCase -Id dirname -ActualLines (Invoke-PshBatch1Command -Name dirname -Arguments @((Join-Path $goldenCaseRoot 'dirname/child/report.txt'))).Output -CaseRoot $goldenCaseRoot
        Set-Location -LiteralPath (Join-Path $goldenCaseRoot 'mktemp')
        $mktempGolden = (Invoke-PshBatch1Command -Name mktemp -Arguments @('item.XXXXXX')).Output
        Set-Location -LiteralPath $goldenCaseRoot
        Compare-PshGoldenCase -Id mktemp_pattern -ActualLines $mktempGolden -CaseRoot $goldenCaseRoot -Mktemp
    }

    foreach ($name in @('pwd', 'cd', 'ls', 'mkdir', 'rmdir', 'cp', 'mv', 'rm', 'touch', 'ln', 'realpath', 'basename', 'dirname', 'stat', 'file', 'tree', 'find', 'fd', 'du', 'df', 'mktemp')) {
        Assert-PshBatch1 ($covered.ContainsKey($name)) ('no behavior row executed for {0}.' -f $name)
    }
    Assert-PshBatch1 ([IO.File]::Exists($outsideSentinel)) 'The outside destructive-test sentinel was removed.'
    Write-Output ('Goal 3 Batch 1 file-command acceptance passed: 21 commands, {0} assertions, collision/disable/restore safety, object APIs, Unicode/binary/line-ending fixtures{1}.' -f $assertionCount, $(if ([string]::IsNullOrWhiteSpace($GoldenRoot)) { '' } else { ', and GNU golden comparisons' }))
}
finally {
    Set-Location -LiteralPath $originalLocation -ErrorAction SilentlyContinue
    Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:PSH_EDITION = $originalEdition
    Remove-Item -LiteralPath Alias:touch -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name '__pshProjection_baf0d32a_Disabled', '__PshProjection_baf0d32a_Context' -Scope Script -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\global:Restore-PshCallerFileCommandProjection_baf0d32a -Force -ErrorAction SilentlyContinue
    if ([IO.Directory]::Exists($testRoot)) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not [string]::IsNullOrWhiteSpace($crossVolumeRoot) -and [IO.Directory]::Exists($crossVolumeRoot)) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $crossVolumeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ([IO.File]::Exists($outsideSentinel)) {
        [IO.File]::Delete($outsideSentinel)
    }
}
