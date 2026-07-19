# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

function Assert-PshGoal2Condition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Goal 2 acceptance failed: $Message"
    }
}

function Test-PshGoal2ByteArrayEqual {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Left,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function Join-PshGoal2ByteArray {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$First,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Second
    )

    $result = New-Object byte[] ($First.Length + $Second.Length)
    if ($First.Length -gt 0) {
        [Array]::Copy($First, 0, $result, 0, $First.Length)
    }
    if ($Second.Length -gt 0) {
        [Array]::Copy($Second, 0, $result, $First.Length, $Second.Length)
    }
    return ,$result
}

function ConvertTo-PshGoal2Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [Text.Encoding]$Encoding,

        [switch]$IncludePreamble
    )

    [byte[]]$body = $Encoding.GetBytes($Text)
    if (-not $IncludePreamble) {
        return ,$body
    }
    [byte[]]$preamble = $Encoding.GetPreamble()
    return Join-PshGoal2ByteArray -First $preamble -Second $body
}

function Get-PshGoal2TreeFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
            ForEach-Object {
                $relative = $_.FullName.Substring($Root.Length).TrimStart(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar
                ).Replace('\', '/')
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                '{0}|{1}|{2}' -f $relative, $_.Length, $hash
            } |
            Sort-Object
    )
}

function Remove-PshGoal2TemporaryTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [IO.Directory]::Exists($Path)) {
        return
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction Ignore)) {
        [IO.File]::SetAttributes($file.FullName, [IO.FileAttributes]::Normal)
    }
    [IO.Directory]::Delete($Path, $true)
}

function Assert-PshGoal2ExpectedFailure {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $failed = $false
    try {
        & $Action
    }
    catch {
        $failed = $true
    }
    Assert-PshGoal2Condition $failed $Message
}

function Invoke-PshGoal2Git {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitPath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    $output = @(& $GitPath @ArgumentList 2>&1)
    Assert-PshGoal2Condition ($LASTEXITCODE -eq 0) ("Local Git command failed: git {0}. Output: {1}" -f ($ArgumentList -join ' '), ($output -join ' '))
}

function Invoke-PshGoal2PSReadLineCompletion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputScript
    )

    $readLineCommand = Get-Command -Name 'Set-PSReadLineOption' -ErrorAction Stop
    $readLineType = $readLineCommand.ImplementingType.Assembly.GetType(
        'Microsoft.PowerShell.PSConsoleReadLine',
        $false
    )
    if ($null -eq $readLineType) {
        throw 'The active PSReadLine implementation type is unavailable.'
    }

    $staticFlags = [Reflection.BindingFlags]'Static, NonPublic'
    $instanceFlags = [Reflection.BindingFlags]'Instance, NonPublic'
    $singletonField = $readLineType.GetField('_singleton', $staticFlags)
    $bufferField = $readLineType.GetField('_buffer', $instanceFlags)
    $currentField = $readLineType.GetField('_current', $instanceFlags)
    $runspaceField = $readLineType.GetField('_runspace', $instanceFlags)
    $tabCountField = $readLineType.GetField('_tabCommandCount', $instanceFlags)
    $tabCompletionsField = $readLineType.GetField('_tabCompletions', $instanceFlags)
    $directorySeparatorField = $readLineType.GetField('_directorySeparator', $instanceFlags)
    $mockableMethodsField = $readLineType.GetField('_mockableMethods', $instanceFlags)
    $consoleField = $readLineType.GetField('_console', $instanceFlags)
    $initialYField = $readLineType.GetField('_initialY', $instanceFlags)
    $getCompletionsMethod = $readLineType.GetMethod('GetCompletions', $instanceFlags)
    foreach ($requiredMember in @(
        $singletonField,
        $bufferField,
        $currentField,
        $runspaceField,
        $tabCountField,
        $tabCompletionsField,
        $directorySeparatorField,
        $mockableMethodsField,
        $consoleField,
        $initialYField,
        $getCompletionsMethod
    )) {
        if ($null -eq $requiredMember) {
            throw 'The pinned PSReadLine completion test surface is unavailable.'
        }
    }

    $memoryConsoleTypeName = 'Psh.Goal2.Acceptance.MemoryConsole'
    $memoryConsoleType = $memoryConsoleTypeName -as [type]
    if ($null -eq $memoryConsoleType) {
        $memoryConsoleSource = @'
using System;
using System.Text;
using Microsoft.PowerShell.Internal;

namespace Psh.Goal2.Acceptance
{
    public sealed class MemoryConsole : IConsole
    {
        public MemoryConsole()
        {
            CursorSize = 25;
            CursorVisible = true;
            BufferWidth = 120;
            BufferHeight = 3000;
            WindowWidth = 120;
            WindowHeight = 40;
            BackgroundColor = ConsoleColor.Black;
            ForegroundColor = ConsoleColor.Gray;
            OutputEncoding = Encoding.UTF8;
        }

        public bool KeyAvailable { get { return false; } }
        public int CursorLeft { get; set; }
        public int CursorTop { get; set; }
        public int CursorSize { get; set; }
        public bool CursorVisible { get; set; }
        public int BufferWidth { get; set; }
        public int BufferHeight { get; set; }
        public int WindowWidth { get; set; }
        public int WindowHeight { get; set; }
        public int WindowTop { get; set; }
        public ConsoleColor BackgroundColor { get; set; }
        public ConsoleColor ForegroundColor { get; set; }
        public Encoding OutputEncoding { get; set; }

        public ConsoleKeyInfo ReadKey()
        {
            throw new InvalidOperationException("The Goal 2 completion test cannot read interactive input.");
        }

        public void SetWindowPosition(int left, int top)
        {
            WindowTop = top;
        }

        public void SetCursorPosition(int left, int top)
        {
            CursorLeft = left;
            CursorTop = top;
        }

        public void WriteLine(string value) { }
        public void Write(string value) { }
        public void BlankRestOfLine() { }
    }
}
'@
        $compilerReferences = @($readLineCommand.ImplementingType.Assembly.Location)
        $consoleAssemblyPath = [ConsoleColor].Assembly.Location
        if (-not [string]::Equals(
            $consoleAssemblyPath,
            [object].Assembly.Location,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $compilerReferences += $consoleAssemblyPath
        }
        $netstandardAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { $_.GetName().Name -ceq 'netstandard' } |
            Select-Object -First 1
        if ($null -ne $netstandardAssembly -and
            -not [string]::IsNullOrWhiteSpace($netstandardAssembly.Location)) {
            $compilerReferences += $netstandardAssembly.Location
        }
        $memoryConsoleType = @(
            Add-Type `
                -TypeDefinition $memoryConsoleSource `
                -ReferencedAssemblies $compilerReferences `
                -PassThru `
                -ErrorAction Stop |
                Where-Object { $_.FullName -ceq $memoryConsoleTypeName }
        ) | Select-Object -First 1
    }
    if ($null -eq $memoryConsoleType) {
        throw 'The test-only PSReadLine memory console type is unavailable.'
    }
    $memoryConsole = [Activator]::CreateInstance($memoryConsoleType)
    if (-not $consoleField.FieldType.IsInstanceOfType($memoryConsole)) {
        throw 'The test-only memory console does not implement the active PSReadLine IConsole interface.'
    }

    $singleton = $singletonField.GetValue($null)
    if (-not [object]::ReferenceEquals($mockableMethodsField.GetValue($singleton), $singleton)) {
        throw 'The active PSReadLine completion provider was replaced by a test double.'
    }
    $buffer = $bufferField.GetValue($singleton)
    $savedBuffer = [string]$buffer.ToString()
    $savedCurrent = $currentField.GetValue($singleton)
    $savedRunspace = $runspaceField.GetValue($singleton)
    $savedTabCount = $tabCountField.GetValue($singleton)
    $savedTabCompletions = $tabCompletionsField.GetValue($singleton)
    $savedDirectorySeparator = $directorySeparatorField.GetValue($singleton)
    $savedConsole = $consoleField.GetValue($singleton)
    $savedInitialY = $initialYField.GetValue($singleton)
    $completion = $null
    $completionError = $null
    $restorationErrors = @()
    try {
        [void]$buffer.Clear()
        [void]$buffer.Append($InputScript)
        $currentField.SetValue($singleton, $InputScript.Length)
        $runspaceField.SetValue($singleton, [Management.Automation.Runspaces.Runspace]::DefaultRunspace)
        $tabCountField.SetValue($singleton, 0)
        $tabCompletionsField.SetValue($singleton, $null)
        $consoleField.SetValue($singleton, $memoryConsole)
        $completion = $getCompletionsMethod.Invoke($singleton, $null)
    }
    catch {
        $completionError = $_.Exception
    }
    finally {
        $restoreActions = @(
            { $consoleField.SetValue($singleton, $savedConsole) },
            { $initialYField.SetValue($singleton, $savedInitialY) },
            { $directorySeparatorField.SetValue($singleton, $savedDirectorySeparator) },
            {
                [void]$buffer.Clear()
                [void]$buffer.Append($savedBuffer)
            },
            { $currentField.SetValue($singleton, $savedCurrent) },
            { $runspaceField.SetValue($singleton, $savedRunspace) },
            { $tabCountField.SetValue($singleton, $savedTabCount) },
            { $tabCompletionsField.SetValue($singleton, $savedTabCompletions) }
        )
        foreach ($restoreAction in $restoreActions) {
            try {
                & $restoreAction
            }
            catch {
                $restorationErrors += $_.Exception
            }
        }
    }

    if ($restorationErrors.Count -gt 0) {
        throw ('The PSReadLine completion test could not restore singleton state: {0}' -f @(
            $restorationErrors | ForEach-Object { $_.Message }
        ) -join '; ')
    }
    if ($null -ne $completionError) {
        while ($null -ne $completionError.InnerException -and @(
            [Reflection.TargetInvocationException],
            [Management.Automation.MethodInvocationException]
        ) -contains $completionError.GetType()) {
            $completionError = $completionError.InnerException
        }
        throw $completionError
    }
    return $completion
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$moduleManifestPath = Join-Path -Path $repositoryRootPath -ChildPath 'src/Psh/Psh.psd1'
$dependencyRoot = Join-Path -Path $repositoryRootPath -ChildPath 'src/Psh/Dependencies'
$dependencyVerifierPath = Join-Path -Path $repositoryRootPath -ChildPath 'scripts/Test-InteractiveDependencies.ps1'
$installProfilePath = Join-Path -Path $repositoryRootPath -ChildPath 'src/profile/Install-PshProfile.ps1'
$uninstallProfilePath = Join-Path -Path $repositoryRootPath -ChildPath 'src/profile/Uninstall-PshProfile.ps1'
$installProjectionPath = Join-Path -Path $repositoryRootPath -ChildPath 'src/profile/Install-PshPSReadLineProjection.ps1'
$uninstallProjectionPath = Join-Path -Path $repositoryRootPath -ChildPath 'src/profile/Uninstall-PshPSReadLineProjection.ps1'

foreach ($requiredPath in @(
    $moduleManifestPath,
    $dependencyVerifierPath,
    $installProfilePath,
    $uninstallProfilePath,
    $installProjectionPath,
    $uninstallProjectionPath
)) {
    Assert-PshGoal2Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) "Required file is missing: $requiredPath"
}

& $dependencyVerifierPath -RepositoryRoot $repositoryRootPath

$ownedSourceFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repositoryRootPath 'src/Psh/Interactive') -File
    Get-ChildItem -LiteralPath (Join-Path $repositoryRootPath 'src/profile') -File
    Get-Item -LiteralPath (Join-Path $repositoryRootPath 'src/Psh/Psh.psm1')
    Get-Item -LiteralPath (Join-Path $repositoryRootPath 'src/Psh/Psh.psd1')
    Get-Item -LiteralPath $dependencyVerifierPath
    Get-Item -LiteralPath (Join-Path $repositoryRootPath 'tests/Goal2.VM.Prepare.ps1')
    Get-Item -LiteralPath (Join-Path $repositoryRootPath 'tests/Goal2.VM.SessionEvidence.ps1')
    Get-Item -LiteralPath $PSCommandPath
)
$parseFailureCount = 0
foreach ($sourceFile in $ownedSourceFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $sourceFile.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in @($parseErrors)) {
        Write-Output ("{0}:{1}:{2}: {3}" -f $sourceFile.FullName, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
        $parseFailureCount++
    }
}
Assert-PshGoal2Condition ($parseFailureCount -eq 0) 'A Psh-owned Goal 2 source file has a PowerShell parse error.'

$forbiddenIntegrationPatterns = @(
    'Invoke-Expression',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    'Start-Job',
    'Start-ThreadJob',
    'Set-ExecutionPolicy',
    'Start-Process[^\r\n]+-Verb\s+RunAs'
)
foreach ($pattern in $forbiddenIntegrationPatterns) {
    $matches = @(
        $ownedSourceFiles |
            Where-Object { $_.FullName -notlike '*Test-InteractiveDependencies.ps1' -and $_.FullName -notlike '*Goal2.Acceptance.ps1' } |
            ForEach-Object { Select-String -LiteralPath $_.FullName -Pattern $pattern }
    )
    Assert-PshGoal2Condition ($matches.Count -eq 0) "Psh-owned Goal 2 integration contains a forbidden startup or evaluation pattern: $pattern"
}

$lock = Get-Content -LiteralPath (Join-Path $dependencyRoot 'interactive.lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-PshGoal2Condition (@($lock.components).Count -eq 1 -and [string]$lock.components[0].name -ceq 'PSReadLine') 'The interactive lock must contain only PSReadLine.'

$dependencyTreeBefore = @(Get-PshGoal2TreeFingerprint -Root $dependencyRoot)
$jobCountBefore = @(Get-Job -ErrorAction Ignore).Count

$originalPrompt = (Get-Item -LiteralPath 'Function:\prompt').ScriptBlock
$interactiveTemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("psh-goal2-interactive-{0}" -f [Guid]::NewGuid().ToString('N'))
$profileTemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("psh-goal2-profile-{0}" -f [Guid]::NewGuid().ToString('N'))
$projectionTemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("p2p-{0}" -f [Guid]::NewGuid().ToString('N').Substring(0, 12))
$originalLocation = Get-Location

try {
    [IO.Directory]::CreateDirectory($projectionTemporaryRoot) | Out-Null
    $projectionSourcePath = Join-Path $dependencyRoot 'PSReadLine/2.4.5'
    $projectionSourceFingerprint = @(Get-PshGoal2TreeFingerprint -Root $projectionSourcePath)
    Assert-PshGoal2Condition ($projectionSourceFingerprint.Count -eq 7) 'The projection source is not the exact seven-file PSReadLine tree.'
    $expectedProjectionTreeHash = 'ba8c4b0064725aa107f024d243d9f8af8ab43791a4bdda39893d27b22ae6f79d'

    $projectionLifecycleRoot = Join-Path $projectionTemporaryRoot 'lifecycle'
    $projectionLifecycleRoots = @(
        (Join-Path $projectionLifecycleRoot 'WindowsPowerShell/Modules'),
        (Join-Path $projectionLifecycleRoot 'PowerShell/Modules')
    )
    $projectionLifecycleState = Join-Path $projectionLifecycleRoot 'state'
    $projectionWhatIf = @(
        & $installProjectionPath `
            -SourcePath $projectionSourcePath `
            -ModuleRoot $projectionLifecycleRoots `
            -StateRoot $projectionLifecycleState `
            -WhatIf
    )
    Assert-PshGoal2Condition ($projectionWhatIf.Count -eq 2) 'Projection install WhatIf did not report both targets.'
    Assert-PshGoal2Condition (@($projectionWhatIf | Where-Object { [string]$_.Status -cne 'WouldCreate' }).Count -eq 0) 'Projection install WhatIf did not report WouldCreate for two absent targets.'
    Assert-PshGoal2Condition (-not [IO.Directory]::Exists($projectionLifecycleState)) 'Projection install WhatIf created state.'
    foreach ($moduleRoot in $projectionLifecycleRoots) {
        $targetPath = Join-Path (Join-Path $moduleRoot 'PSReadLine') '2.4.5'
        Assert-PshGoal2Condition (-not [IO.Directory]::Exists($targetPath) -and -not [IO.File]::Exists($targetPath)) 'Projection install WhatIf created a target.'
    }

    $projectionCreated = @(
        & $installProjectionPath `
            -SourcePath $projectionSourcePath `
            -ModuleRoot $projectionLifecycleRoots `
            -StateRoot $projectionLifecycleState
    )
    Assert-PshGoal2Condition ($projectionCreated.Count -eq 2) 'Projection install did not report both created targets.'
    Assert-PshGoal2Condition (@($projectionCreated | Where-Object { [string]$_.Status -cne 'Created' -or -not [bool]$_.Owned -or -not [bool]$_.Changed }).Count -eq 0) 'Projection install reported incorrect created ownership.'
    Assert-PshGoal2Condition (@($projectionCreated | Where-Object { [int]$_.FileCount -ne 7 -or [string]$_.TreeSha256 -cne $expectedProjectionTreeHash }).Count -eq 0) 'Projection install reported the wrong trusted fingerprint.'
    foreach ($result in $projectionCreated) {
        Assert-PshGoal2Condition ([IO.Directory]::Exists([string]$result.TargetPath)) "Projection target is missing: $($result.TargetPath)"
        Assert-PshGoal2Condition (@(Compare-Object $projectionSourceFingerprint @(Get-PshGoal2TreeFingerprint -Root ([string]$result.TargetPath))).Count -eq 0) "Projection target differs from the source: $($result.TargetPath)"
    }
    $projectionManifestPath = Join-Path $projectionLifecycleState 'manifest.json'
    Assert-PshGoal2Condition ([IO.File]::Exists($projectionManifestPath)) 'Projection install did not create its ownership manifest.'
    $projectionManifest = Get-Content -LiteralPath $projectionManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    Assert-PshGoal2Condition ([string]$projectionManifest.state -ceq 'complete' -and [string]$projectionManifest.operation -ceq 'install') 'Projection install did not commit a complete install manifest.'
    Assert-PshGoal2Condition ([string]$projectionManifest.treeSha256 -ceq $expectedProjectionTreeHash -and @($projectionManifest.files).Count -eq 7) 'Projection manifest lost the trusted seven-file fingerprint.'
    Assert-PshGoal2Condition (@($projectionManifest.targets).Count -eq 2 -and @($projectionManifest.targets | Where-Object { [string]$_.disposition -cne 'created' }).Count -eq 0) 'Projection manifest has the wrong target ownership.'

    $projectionRepeat = @(
        & $installProjectionPath `
            -SourcePath $projectionSourcePath `
            -ModuleRoot $projectionLifecycleRoots `
            -StateRoot $projectionLifecycleState
    )
    Assert-PshGoal2Condition ($projectionRepeat.Count -eq 2 -and @($projectionRepeat | Where-Object { [string]$_.Status -cne 'AlreadyCreated' -or [bool]$_.Changed }).Count -eq 0) 'Projection reinstall was not idempotent.'

    [byte[]]$projectionManifestBeforeWhatIf = [IO.File]::ReadAllBytes($projectionManifestPath)
    $projectionUninstallWhatIf = @(
        & $uninstallProjectionPath `
            -ModuleRoot $projectionLifecycleRoots `
            -StateRoot $projectionLifecycleState `
            -WhatIf
    )
    Assert-PshGoal2Condition ($projectionUninstallWhatIf.Count -eq 2 -and @($projectionUninstallWhatIf | Where-Object { [string]$_.Status -cne 'WouldRemove' }).Count -eq 0) 'Projection uninstall WhatIf did not report both owned targets.'
    Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $projectionManifestBeforeWhatIf -Right ([IO.File]::ReadAllBytes($projectionManifestPath))) 'Projection uninstall WhatIf changed its manifest.'
    foreach ($result in $projectionCreated) {
        Assert-PshGoal2Condition (@(Compare-Object $projectionSourceFingerprint @(Get-PshGoal2TreeFingerprint -Root ([string]$result.TargetPath))).Count -eq 0) 'Projection uninstall WhatIf changed an owned target.'
    }

    $projectionRemoved = @(
        & $uninstallProjectionPath `
            -ModuleRoot $projectionLifecycleRoots `
            -StateRoot $projectionLifecycleState
    )
    Assert-PshGoal2Condition ($projectionRemoved.Count -eq 2 -and @($projectionRemoved | Where-Object { [string]$_.Status -cne 'Removed' -or -not [bool]$_.Changed }).Count -eq 0) 'Projection uninstall did not remove both owned targets.'
    foreach ($result in $projectionRemoved) {
        Assert-PshGoal2Condition (-not [IO.Directory]::Exists([string]$result.TargetPath) -and -not [IO.File]::Exists([string]$result.TargetPath)) 'Projection uninstall left an owned target.'
    }
    Assert-PshGoal2Condition (-not [IO.File]::Exists($projectionManifestPath)) 'Projection uninstall left its ownership manifest.'
    $projectionNotInstalled = @(
        & $uninstallProjectionPath `
            -ModuleRoot $projectionLifecycleRoots `
            -StateRoot $projectionLifecycleState
    )
    Assert-PshGoal2Condition ($projectionNotInstalled.Count -eq 2 -and @($projectionNotInstalled | Where-Object { [string]$_.Status -cne 'NotInstalled' }).Count -eq 0) 'Projection repeat uninstall was not idempotent.'

    $projectionMixedRoot = Join-Path $projectionTemporaryRoot 'mixed-ownership'
    $projectionMixedRoots = @(
        (Join-Path $projectionMixedRoot 'WindowsPowerShell/Modules'),
        (Join-Path $projectionMixedRoot 'PowerShell/Modules')
    )
    $projectionMixedState = Join-Path $projectionMixedRoot 'state'
    $preexistingProjectionTarget = Join-Path (Join-Path $projectionMixedRoots[0] 'PSReadLine') '2.4.5'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($preexistingProjectionTarget)) | Out-Null
    Copy-Item -LiteralPath $projectionSourcePath -Destination $preexistingProjectionTarget -Recurse
    $projectionMixedInstall = @(
        & $installProjectionPath `
            -SourcePath $projectionSourcePath `
            -ModuleRoot $projectionMixedRoots `
            -StateRoot $projectionMixedState
    )
    Assert-PshGoal2Condition ($projectionMixedInstall.Count -eq 2) 'Mixed-ownership projection install did not report both targets.'
    Assert-PshGoal2Condition ([string]$projectionMixedInstall[0].Status -ceq 'Reused' -and -not [bool]$projectionMixedInstall[0].Owned -and -not [bool]$projectionMixedInstall[0].Changed) 'An identical pre-existing projection was not reused without ownership.'
    Assert-PshGoal2Condition ([string]$projectionMixedInstall[1].Status -ceq 'Created' -and [bool]$projectionMixedInstall[1].Owned -and [bool]$projectionMixedInstall[1].Changed) 'The missing mixed-ownership projection was not created and owned.'
    $projectionMixedRemove = @(
        & $uninstallProjectionPath `
            -ModuleRoot $projectionMixedRoots `
            -StateRoot $projectionMixedState
    )
    Assert-PshGoal2Condition ([string]$projectionMixedRemove[0].Status -ceq 'RetainedReused' -and -not [bool]$projectionMixedRemove[0].Changed) 'Projection uninstall removed or changed reused user content.'
    Assert-PshGoal2Condition ([string]$projectionMixedRemove[1].Status -ceq 'Removed' -and [bool]$projectionMixedRemove[1].Changed) 'Projection uninstall retained a Psh-owned mixed target.'
    Assert-PshGoal2Condition (@(Compare-Object $projectionSourceFingerprint @(Get-PshGoal2TreeFingerprint -Root $preexistingProjectionTarget)).Count -eq 0) 'Projection uninstall changed the reused pre-existing tree.'
    $mixedCreatedTarget = Join-Path (Join-Path $projectionMixedRoots[1] 'PSReadLine') '2.4.5'
    Assert-PshGoal2Condition (-not [IO.Directory]::Exists($mixedCreatedTarget)) 'Projection uninstall left the Psh-owned mixed target.'

    foreach ($conflictMode in @('different-bytes', 'extra-file', 'higher-version', 'unversioned-file')) {
        $conflictRoot = Join-Path $projectionTemporaryRoot ("conflict-{0}" -f $conflictMode)
        $conflictModuleRoots = @(
            (Join-Path $conflictRoot 'WindowsPowerShell/Modules'),
            (Join-Path $conflictRoot 'PowerShell/Modules')
        )
        $conflictState = Join-Path $conflictRoot 'state'
        $conflictContainer = Join-Path $conflictModuleRoots[0] 'PSReadLine'
        [IO.Directory]::CreateDirectory($conflictContainer) | Out-Null
        switch ($conflictMode) {
            'different-bytes' {
                $conflictTarget = Join-Path $conflictContainer '2.4.5'
                Copy-Item -LiteralPath $projectionSourcePath -Destination $conflictTarget -Recurse
                $conflictFile = Join-Path $conflictTarget 'PSReadLine.psm1'
                [byte[]]$conflictBytes = [IO.File]::ReadAllBytes($conflictFile)
                $conflictBytes[$conflictBytes.Length - 1] = $conflictBytes[$conflictBytes.Length - 1] -bxor 1
                [IO.File]::WriteAllBytes($conflictFile, $conflictBytes)
            }
            'extra-file' {
                $conflictTarget = Join-Path $conflictContainer '2.4.5'
                Copy-Item -LiteralPath $projectionSourcePath -Destination $conflictTarget -Recurse
                [IO.File]::WriteAllText((Join-Path $conflictTarget 'user-extra.txt'), 'pre-existing user content', (New-Object Text.UTF8Encoding($false)))
            }
            'higher-version' {
                $conflictTarget = Join-Path $conflictContainer '9.0.0'
                [IO.Directory]::CreateDirectory($conflictTarget) | Out-Null
                [IO.File]::WriteAllText((Join-Path $conflictTarget 'user.txt'), 'higher version', (New-Object Text.UTF8Encoding($false)))
            }
            'unversioned-file' {
                $conflictTarget = Join-Path $conflictContainer 'PSReadLine.psd1'
                [IO.File]::WriteAllText($conflictTarget, '@{ ModuleVersion = ''1.0.0'' }', (New-Object Text.UTF8Encoding($false)))
            }
        }
        $conflictFingerprintBefore = @(Get-PshGoal2TreeFingerprint -Root $conflictRoot)
        Assert-PshGoal2ExpectedFailure -Action {
            & $installProjectionPath `
                -SourcePath $projectionSourcePath `
                -ModuleRoot $conflictModuleRoots `
                -StateRoot $conflictState
        } -Message "Projection conflict was accepted: $conflictMode"
        Assert-PshGoal2Condition (@(Compare-Object $conflictFingerprintBefore @(Get-PshGoal2TreeFingerprint -Root $conflictRoot)).Count -eq 0) "Projection conflict preflight changed user content: $conflictMode"
        Assert-PshGoal2Condition (-not [IO.Directory]::Exists($conflictState) -and -not [IO.File]::Exists((Join-Path $conflictState 'manifest.json'))) "Projection conflict preflight wrote state: $conflictMode"
        $conflictSecondTarget = Join-Path (Join-Path $conflictModuleRoots[1] 'PSReadLine') '2.4.5'
        Assert-PshGoal2Condition (-not [IO.Directory]::Exists($conflictSecondTarget) -and -not [IO.File]::Exists($conflictSecondTarget)) "Projection conflict preflight wrote the second target: $conflictMode"
    }

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $reparseRoot = Join-Path $projectionTemporaryRoot 'conflict-reparse'
        $reparseModuleRoots = @(
            (Join-Path $reparseRoot 'WindowsPowerShell/Modules'),
            (Join-Path $reparseRoot 'PowerShell/Modules')
        )
        $reparseState = Join-Path $reparseRoot 'state'
        $reparseTarget = Join-Path $reparseRoot 'junction-target'
        $reparseContainer = Join-Path $reparseModuleRoots[0] 'PSReadLine'
        [IO.Directory]::CreateDirectory($reparseModuleRoots[0]) | Out-Null
        [IO.Directory]::CreateDirectory($reparseTarget) | Out-Null
        $null = New-Item -ItemType Junction -Path $reparseContainer -Target $reparseTarget -ErrorAction Stop
        try {
            Assert-PshGoal2ExpectedFailure -Action {
                & $installProjectionPath `
                    -SourcePath $projectionSourcePath `
                    -ModuleRoot $reparseModuleRoots `
                    -StateRoot $reparseState
            } -Message 'A reparse-point PSReadLine container was accepted.'
            Assert-PshGoal2Condition (-not [IO.Directory]::Exists($reparseState)) 'Reparse-point conflict wrote projection state.'
            Assert-PshGoal2Condition (@(Get-ChildItem -LiteralPath $reparseTarget -Force).Count -eq 0) 'Reparse-point conflict changed its target.'
        }
        finally {
            if ([IO.Directory]::Exists($reparseContainer)) {
                [IO.Directory]::Delete($reparseContainer, $false)
            }
        }

        $installRollbackRoot = Join-Path $projectionTemporaryRoot 'install-rollback'
        $installRollbackRoots = @(
            (Join-Path $installRollbackRoot 'WindowsPowerShell/Modules'),
            (Join-Path $installRollbackRoot 'PowerShell/Modules')
        )
        $installRollbackState = Join-Path $installRollbackRoot 'state'
        foreach ($moduleRoot in $installRollbackRoots) {
            [IO.Directory]::CreateDirectory($moduleRoot) | Out-Null
        }
        $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $denyCreateRule = New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList @(
            $currentUserSid,
            [Security.AccessControl.FileSystemRights]::CreateDirectories,
            [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Deny
        )
        $installRollbackAcl = Get-Acl -LiteralPath $installRollbackRoots[1]
        [void]$installRollbackAcl.AddAccessRule($denyCreateRule)
        Set-Acl -LiteralPath $installRollbackRoots[1] -AclObject $installRollbackAcl
        try {
            Assert-PshGoal2ExpectedFailure -Action {
                & $installProjectionPath `
                    -SourcePath $projectionSourcePath `
                    -ModuleRoot $installRollbackRoots `
                    -StateRoot $installRollbackState
            } -Message 'A denied second projection target did not trigger install rollback.'
        }
        finally {
            $installRollbackAcl = Get-Acl -LiteralPath $installRollbackRoots[1]
            [void]$installRollbackAcl.RemoveAccessRuleSpecific($denyCreateRule)
            Set-Acl -LiteralPath $installRollbackRoots[1] -AclObject $installRollbackAcl
        }
        foreach ($moduleRoot in $installRollbackRoots) {
            $targetPath = Join-Path (Join-Path $moduleRoot 'PSReadLine') '2.4.5'
            Assert-PshGoal2Condition (-not [IO.Directory]::Exists($targetPath) -and -not [IO.File]::Exists($targetPath)) 'Projection install rollback left a target behind.'
        }
        Assert-PshGoal2Condition (-not [IO.File]::Exists((Join-Path $installRollbackState 'manifest.json'))) 'Projection install rollback left a manifest behind.'

        $uninstallRollbackRoot = Join-Path $projectionTemporaryRoot 'uninstall-rollback'
        $uninstallRollbackRoots = @(
            (Join-Path $uninstallRollbackRoot 'WindowsPowerShell/Modules'),
            (Join-Path $uninstallRollbackRoot 'PowerShell/Modules')
        )
        $uninstallRollbackState = Join-Path $uninstallRollbackRoot 'state'
        $uninstallRollbackInstall = @(
            & $installProjectionPath `
                -SourcePath $projectionSourcePath `
                -ModuleRoot $uninstallRollbackRoots `
                -StateRoot $uninstallRollbackState
        )
        [byte[]]$uninstallRollbackManifestBytes = [IO.File]::ReadAllBytes((Join-Path $uninstallRollbackState 'manifest.json'))
        $denyDeleteRule = New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList @(
            $currentUserSid,
            [Security.AccessControl.FileSystemRights]::Delete,
            [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Deny
        )
        $denyDeleteChildRule = New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList @(
            $currentUserSid,
            [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
            [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Deny
        )
        $uninstallRollbackTarget = [string]$uninstallRollbackInstall[1].TargetPath
        $uninstallRollbackContainer = [IO.Path]::GetDirectoryName($uninstallRollbackTarget)
        $uninstallRollbackTargetAcl = Get-Acl -LiteralPath $uninstallRollbackTarget
        [void]$uninstallRollbackTargetAcl.AddAccessRule($denyDeleteRule)
        Set-Acl -LiteralPath $uninstallRollbackTarget -AclObject $uninstallRollbackTargetAcl
        $uninstallRollbackContainerAcl = Get-Acl -LiteralPath $uninstallRollbackContainer
        [void]$uninstallRollbackContainerAcl.AddAccessRule($denyDeleteChildRule)
        Set-Acl -LiteralPath $uninstallRollbackContainer -AclObject $uninstallRollbackContainerAcl
        try {
            Assert-PshGoal2ExpectedFailure -Action {
                $null = @(
                    & $uninstallProjectionPath `
                        -ModuleRoot $uninstallRollbackRoots `
                        -StateRoot $uninstallRollbackState
                )
            } -Message 'A denied second projection target did not trigger uninstall rollback.'
        }
        finally {
            if ([IO.Directory]::Exists($uninstallRollbackTarget)) {
                $uninstallRollbackTargetAcl = Get-Acl -LiteralPath $uninstallRollbackTarget
                [void]$uninstallRollbackTargetAcl.RemoveAccessRuleSpecific($denyDeleteRule)
                Set-Acl -LiteralPath $uninstallRollbackTarget -AclObject $uninstallRollbackTargetAcl
            }
            if ([IO.Directory]::Exists($uninstallRollbackContainer)) {
                $uninstallRollbackContainerAcl = Get-Acl -LiteralPath $uninstallRollbackContainer
                [void]$uninstallRollbackContainerAcl.RemoveAccessRuleSpecific($denyDeleteChildRule)
                Set-Acl -LiteralPath $uninstallRollbackContainer -AclObject $uninstallRollbackContainerAcl
            }
        }
        Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $uninstallRollbackManifestBytes -Right ([IO.File]::ReadAllBytes((Join-Path $uninstallRollbackState 'manifest.json'))) ) 'Projection uninstall rollback did not restore the complete manifest.'
        foreach ($result in $uninstallRollbackInstall) {
            Assert-PshGoal2Condition (@(Compare-Object $projectionSourceFingerprint @(Get-PshGoal2TreeFingerprint -Root ([string]$result.TargetPath))).Count -eq 0) 'Projection uninstall rollback did not restore an owned target.'
        }
        $null = @(
            & $uninstallProjectionPath `
                -ModuleRoot $uninstallRollbackRoots `
                -StateRoot $uninstallRollbackState
        )
    }

    $projectionTamperRoot = Join-Path $projectionTemporaryRoot 'tamper'
    $projectionTamperRoots = @(
        (Join-Path $projectionTamperRoot 'WindowsPowerShell/Modules'),
        (Join-Path $projectionTamperRoot 'PowerShell/Modules')
    )
    $projectionTamperState = Join-Path $projectionTamperRoot 'state'
    $projectionTamperInstall = @(
        & $installProjectionPath `
            -SourcePath $projectionSourcePath `
            -ModuleRoot $projectionTamperRoots `
            -StateRoot $projectionTamperState
    )
    $projectionTamperManifest = Join-Path $projectionTamperState 'manifest.json'
    [byte[]]$projectionTamperManifestBytes = [IO.File]::ReadAllBytes($projectionTamperManifest)
    $projectionUserFile = Join-Path ([string]$projectionTamperInstall[1].TargetPath) 'user-added-after-install.txt'
    [IO.File]::WriteAllText($projectionUserFile, 'must survive refused uninstall', (New-Object Text.UTF8Encoding($false)))
    Assert-PshGoal2ExpectedFailure -Action {
        & $uninstallProjectionPath `
            -ModuleRoot $projectionTamperRoots `
            -StateRoot $projectionTamperState
    } -Message 'Projection uninstall accepted a user-modified owned tree.'
    Assert-PshGoal2Condition ([IO.File]::Exists($projectionUserFile)) 'Projection uninstall deleted a user-added file.'
    Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $projectionTamperManifestBytes -Right ([IO.File]::ReadAllBytes($projectionTamperManifest))) 'Projection uninstall modified state after user-content refusal.'
    Assert-PshGoal2Condition (@(Compare-Object $projectionSourceFingerprint @(Get-PshGoal2TreeFingerprint -Root ([string]$projectionTamperInstall[0].TargetPath))).Count -eq 0) 'Projection uninstall changed the first target before refusing the modified second target.'
    [IO.File]::Delete($projectionUserFile)
    $null = @(
        & $uninstallProjectionPath `
            -ModuleRoot $projectionTamperRoots `
            -StateRoot $projectionTamperState
    )

    Remove-Module Psh -Force -ErrorAction Ignore
    Remove-Module PSReadLine -Force -ErrorAction Ignore
    $expectedPsReadLineBase = [IO.Path]::GetFullPath((Join-Path $dependencyRoot 'PSReadLine/2.4.5')).TrimEnd('\', '/')
    $expectedPsReadLineAssemblyPath = [IO.Path]::GetFullPath((Join-Path $expectedPsReadLineBase 'Microsoft.PowerShell.PSReadLine.dll'))
    $expectedPsReadLineAssemblyHash = [string](Get-FileHash -LiteralPath $expectedPsReadLineAssemblyPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $modulePathComparison = [StringComparison]::Ordinal
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $modulePathComparison = [StringComparison]::OrdinalIgnoreCase
    }

    Import-Module -Name $moduleManifestPath -Force -ErrorAction Stop
    $module = Get-Module -Name Psh
    Assert-PshGoal2Condition ($null -ne $module) 'The Psh module did not import.'
    Assert-PshGoal2Condition ($null -ne (Get-Command Initialize-PshInteractive -Module Psh -ErrorAction Ignore)) 'Initialize-PshInteractive was not exported.'

    $coldStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $initializationOutput = @(Initialize-PshInteractive)
    $coldStopwatch.Stop()
    Assert-PshGoal2Condition ($initializationOutput.Count -eq 1) 'Interactive initialization emitted startup text in addition to its diagnostic object.'
    $diagnostic = $initializationOutput[0]
    Assert-PshGoal2Condition ([bool]$diagnostic.success) ("Interactive initialization failed: {0}" -f (@($diagnostic.errors) -join '; '))
    Assert-PshGoal2Condition ($coldStopwatch.ElapsedMilliseconds -lt 5000) ("Cold interactive initialization took $($coldStopwatch.ElapsedMilliseconds) ms.")
    Assert-PshGoal2Condition ([bool]$diagnostic.dependencies.psReadLine.imported) 'Bundled PSReadLine was not imported.'
    Assert-PshGoal2Condition ([string]$diagnostic.dependencies.psReadLine.loadedVersion -ceq '2.4.5') 'The wrong PSReadLine version was loaded.'
    Assert-PshGoal2Condition ([string]::Equals([string]$diagnostic.dependencies.psReadLine.loadedModuleBase, $expectedPsReadLineBase, $modulePathComparison)) 'The PSReadLine diagnostic reports the wrong module base.'
    Assert-PshGoal2Condition ([bool]$diagnostic.dependencies.psReadLine.assemblyVerified) 'The active PSReadLine implementation assembly was not verified.'
    Assert-PshGoal2Condition (@('fixed-path', 'reused-identical') -contains [string]$diagnostic.dependencies.psReadLine.assemblyVerificationState) 'The PSReadLine assembly verification state is invalid.'
    Assert-PshGoal2Condition ([bool]$diagnostic.dependencies.psReadLine.treeVerified) 'The active PSReadLine seven-file tree was not verified.'
    Assert-PshGoal2Condition ([string]$diagnostic.dependencies.psReadLine.treeVerificationState -ceq 'fixed-path') 'The cold fixed PSReadLine tree reported the wrong verification state.'
    Assert-PshGoal2Condition ([int]$diagnostic.dependencies.psReadLine.expectedTreeFileCount -eq 7 -and [int]$diagnostic.dependencies.psReadLine.actualTreeFileCount -eq 7) 'The cold PSReadLine import did not retain two seven-file fingerprints.'
    Assert-PshGoal2Condition ([string]::Equals([string]$diagnostic.dependencies.psReadLine.expectedAssemblyPath, $expectedPsReadLineAssemblyPath, $modulePathComparison)) 'The PSReadLine diagnostic reports the wrong expected assembly path.'
    Assert-PshGoal2Condition ([string]$diagnostic.dependencies.psReadLine.expectedAssemblyHash -ceq $expectedPsReadLineAssemblyHash) 'The PSReadLine diagnostic reports the wrong expected assembly hash.'
    Assert-PshGoal2Condition ([string]$diagnostic.dependencies.psReadLine.actualAssemblyHash -ceq $expectedPsReadLineAssemblyHash) 'The active PSReadLine implementation bytes differ from the bundle.'
    Assert-PshGoal2Condition (@($diagnostic.dependencies.psReadLine.removedConflicts).Count -eq 0) 'A clean-session initialization unexpectedly removed a PSReadLine conflict.'
    $loadedPsReadLineModules = @(Get-Module -Name PSReadLine)
    Assert-PshGoal2Condition ($loadedPsReadLineModules.Count -eq 1) 'More than one PSReadLine module remained loaded after fixed-path initialization.'
    Assert-PshGoal2Condition ([string]::Equals([string]$loadedPsReadLineModules[0].ModuleBase, $expectedPsReadLineBase, $modulePathComparison)) 'The active PSReadLine module is not the fixed bundled copy.'
    $activeSetOption = Get-Command -Name Set-PSReadLineOption -All | Select-Object -First 1
    Assert-PshGoal2Condition ([string]::Equals([string]$activeSetOption.Module.ModuleBase, $expectedPsReadLineBase, $modulePathComparison)) 'Set-PSReadLineOption still resolves to a non-bundled module.'
    $activePsReadLineAssemblyPath = [IO.Path]::GetFullPath([string]$activeSetOption.ImplementingType.Assembly.Location)
    $activePsReadLineAssemblyHash = [string](Get-FileHash -LiteralPath $activePsReadLineAssemblyPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-PshGoal2Condition ($activePsReadLineAssemblyHash -ceq $expectedPsReadLineAssemblyHash) 'Set-PSReadLineOption is implemented by different PSReadLine bytes.'
    $expectedAssemblyState = if ([string]::Equals($activePsReadLineAssemblyPath, $expectedPsReadLineAssemblyPath, $modulePathComparison)) { 'fixed-path' } else { 'reused-identical' }
    Assert-PshGoal2Condition ([string]$diagnostic.dependencies.psReadLine.assemblyVerificationState -ceq $expectedAssemblyState) 'The PSReadLine assembly verification state does not match its implementation location.'

    $mismatchTestScript = Join-Path $interactiveTemporaryRoot 'Test-PSReadLineAssemblyMismatch.ps1'
    $mismatchTestRoot = Join-Path $interactiveTemporaryRoot 'psreadline-mismatched-bytes'
    $mismatchTestSource = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkingRoot
)

$ErrorActionPreference = 'Stop'
$sourceDirectory = Join-Path $RepositoryRoot 'src/Psh/Dependencies/PSReadLine/2.4.5'
$copyDirectory = Join-Path $WorkingRoot 'PSReadLine/2.4.5'
[IO.Directory]::CreateDirectory((Split-Path $copyDirectory -Parent)) | Out-Null
Copy-Item -LiteralPath $sourceDirectory -Destination $copyDirectory -Recurse
$copiedAssembly = Join-Path $copyDirectory 'Microsoft.PowerShell.PSReadLine.dll'
[byte[]]$copiedBytes = [IO.File]::ReadAllBytes($copiedAssembly)
$copiedBytes[$copiedBytes.Length - 1] = $copiedBytes[$copiedBytes.Length - 1] -bxor 1
[IO.File]::WriteAllBytes($copiedAssembly, $copiedBytes)

Import-Module `
    -Name (Join-Path $copyDirectory 'PSReadLine.psd1') `
    -Global `
    -Force `
    -ErrorAction Stop `
    -WarningAction SilentlyContinue
$mismatchedHash = [string](Get-FileHash -LiteralPath $copiedAssembly -Algorithm SHA256).Hash.ToLowerInvariant()
Import-Module `
    -Name (Join-Path $RepositoryRoot 'src/Psh/Psh.psd1') `
    -Force `
    -ErrorAction Stop
$moduleBasesBefore = @(
    Get-Module -Name PSReadLine |
        ForEach-Object { [IO.Path]::GetFullPath([string]$_.ModuleBase) }
)
$assemblyLocationsBefore = @(
    [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { [string]$_.GetName().Name -ceq 'Microsoft.PowerShell.PSReadLine' } |
        ForEach-Object { [IO.Path]::GetFullPath([string]$_.Location) }
)
$promptBefore = (Get-Item -LiteralPath 'Function:\prompt').ScriptBlock.ToString()
$handlersBefore = @(
    foreach ($chord in @('Tab', 'Ctrl+r', 'UpArrow', 'DownArrow')) {
        $handler = Get-PSReadLineKeyHandler -Chord $chord -ErrorAction Stop
        '{0}|{1}' -f $chord, [string]$handler.Function
    }
)
$initialization = Initialize-PshInteractive -EnablePrompt
[PSCustomObject][ordered]@{
    success = [bool]$initialization.success
    dependency = $initialization.dependencies.psReadLine
    keyBindingCount = @($initialization.keyBindings).Count
    predictionReason = [string]$initialization.prediction.reason
    gitCompletionRegistered = [bool]$initialization.gitCompletion.registered
    promptEnabled = [bool]$initialization.prompt.enabled
    mismatchedPath = [IO.Path]::GetFullPath($copiedAssembly)
    mismatchedHash = $mismatchedHash
    moduleSetPreserved = @(
        Compare-Object `
            -ReferenceObject $moduleBasesBefore `
            -DifferenceObject @(
                Get-Module -Name PSReadLine |
                    ForEach-Object { [IO.Path]::GetFullPath([string]$_.ModuleBase) }
            )
    ).Count -eq 0
    assemblySetPreserved = @(
        Compare-Object `
            -ReferenceObject $assemblyLocationsBefore `
            -DifferenceObject @(
                [AppDomain]::CurrentDomain.GetAssemblies() |
                    Where-Object { [string]$_.GetName().Name -ceq 'Microsoft.PowerShell.PSReadLine' } |
                    ForEach-Object { [IO.Path]::GetFullPath([string]$_.Location) }
            )
    ).Count -eq 0
    promptPreserved = (Get-Item -LiteralPath 'Function:\prompt').ScriptBlock.ToString() -ceq $promptBefore
    handlersPreserved = @(
        Compare-Object `
            -ReferenceObject $handlersBefore `
            -DifferenceObject @(
                foreach ($chord in @('Tab', 'Ctrl+r', 'UpArrow', 'DownArrow')) {
                    $handler = Get-PSReadLineKeyHandler -Chord $chord -ErrorAction Stop
                    '{0}|{1}' -f $chord, [string]$handler.Function
                }
            )
    ).Count -eq 0
    loadedModuleBases = @(
        Get-Module -Name PSReadLine |
            ForEach-Object { [IO.Path]::GetFullPath([string]$_.ModuleBase) }
    )
} | ConvertTo-Json -Depth 8 -Compress
'@
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($mismatchTestScript)) | Out-Null
    [IO.File]::WriteAllText(
        $mismatchTestScript,
        $mismatchTestSource,
        (New-Object Text.UTF8Encoding($false))
    )
    $currentPowerShellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $mismatchArguments = @('-NoLogo', '-NoProfile', '-NonInteractive')
    $mismatchArguments += @(
        '-File',
        $mismatchTestScript,
        '-RepositoryRoot',
        $repositoryRootPath,
        '-WorkingRoot',
        $mismatchTestRoot
    )
    $mismatchOutput = @(& $currentPowerShellPath @mismatchArguments)
    $mismatchExitCode = $LASTEXITCODE
    Assert-PshGoal2Condition ($mismatchExitCode -eq 0) ("The PSReadLine assembly-mismatch child test failed: {0}" -f ($mismatchOutput -join ' '))
    $mismatchResult = [string]$mismatchOutput[$mismatchOutput.Count - 1] | ConvertFrom-Json
    Assert-PshGoal2Condition (-not [bool]$mismatchResult.success) 'Different preloaded PSReadLine bytes were accepted as the fixed implementation.'
    Assert-PshGoal2Condition (-not [bool]$mismatchResult.dependency.imported) 'The mismatched PSReadLine dependency was reported as imported.'
    Assert-PshGoal2Condition (-not [bool]$mismatchResult.dependency.assemblyVerified) 'Different PSReadLine bytes were reported as verified.'
    Assert-PshGoal2Condition ([string]$mismatchResult.dependency.assemblyVerificationState -ceq 'failed') 'Different PSReadLine bytes did not produce the failed verification state.'
    Assert-PshGoal2Condition ([bool]$mismatchResult.dependency.restartRequired) 'Different preloaded PSReadLine bytes did not require a fresh process.'
    Assert-PshGoal2Condition ([bool]$mismatchResult.dependency.mutationSuppressed) 'Different preloaded PSReadLine bytes were not refused before mutation.'
    Assert-PshGoal2Condition (@($mismatchResult.dependency.removedConflicts).Count -eq 0) 'Mismatch refusal removed a preloaded PSReadLine module.'
    Assert-PshGoal2Condition (@($mismatchResult.dependency.restoredConflicts).Count -eq 0) 'Mismatch refusal claimed to restore a module after zero-mutation preflight.'
    Assert-PshGoal2Condition ([string]$mismatchResult.dependency.expectedAssemblyHash -ceq $expectedPsReadLineAssemblyHash) 'The mismatch test lost the bundled expected hash.'
    Assert-PshGoal2Condition ([string]$mismatchResult.dependency.actualAssemblyHash -ceq [string]$mismatchResult.mismatchedHash) 'The mismatch diagnostic did not report the active implementation hash.'
    Assert-PshGoal2Condition ([string]$mismatchResult.dependency.actualAssemblyHash -cne $expectedPsReadLineAssemblyHash) 'The altered PSReadLine fixture did not have different bytes.'
    Assert-PshGoal2Condition ([string]::Equals([string]$mismatchResult.dependency.actualAssemblyPath, [string]$mismatchResult.mismatchedPath, $modulePathComparison)) 'The mismatch diagnostic reported the wrong active implementation path.'
    Assert-PshGoal2Condition (@($mismatchResult.loadedModuleBases).Count -eq 1) 'Mismatch refusal did not retain exactly the preloaded PSReadLine module.'
    Assert-PshGoal2Condition ([string]::Equals([string]$mismatchResult.loadedModuleBases[0], (Split-Path -Parent ([string]$mismatchResult.mismatchedPath)), $modulePathComparison)) 'Mismatch refusal changed the original PSReadLine module base.'
    Assert-PshGoal2Condition ([bool]$mismatchResult.moduleSetPreserved) 'Mismatch refusal changed the loaded PSReadLine module set.'
    Assert-PshGoal2Condition ([bool]$mismatchResult.assemblySetPreserved) 'Mismatch refusal changed the PSReadLine AppDomain assembly set.'
    Assert-PshGoal2Condition ([bool]$mismatchResult.promptPreserved) 'Mismatch refusal changed the prompt.'
    Assert-PshGoal2Condition ([bool]$mismatchResult.handlersPreserved) 'Mismatch refusal changed a PSReadLine key handler.'
    Assert-PshGoal2Condition ([int]$mismatchResult.keyBindingCount -eq 0) 'Mismatch refusal reported configured key bindings.'
    Assert-PshGoal2Condition ([string]$mismatchResult.predictionReason -ceq 'DependencyValidationFailed') 'Mismatch refusal did not skip prediction configuration.'
    Assert-PshGoal2Condition (-not [bool]$mismatchResult.gitCompletionRegistered) 'Mismatch refusal registered Git completion.'
    Assert-PshGoal2Condition (-not [bool]$mismatchResult.promptEnabled) 'Mismatch refusal enabled the Psh prompt.'

    $identicalPreloadScript = Join-Path $interactiveTemporaryRoot 'Test-PSReadLineIdenticalPreload.ps1'
    $identicalPreloadRoot = Join-Path $interactiveTemporaryRoot 'psreadline-identical-preload'
    $identicalPreloadSource = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkingRoot,

    [Parameter()]
    [AllowNull()]
    [string]$TamperRelativePath,

    [switch]$AddExtraFile
)

$ErrorActionPreference = 'Stop'
$sourceDirectory = Join-Path $RepositoryRoot 'src/Psh/Dependencies/PSReadLine/2.4.5'
$copyDirectory = Join-Path $WorkingRoot 'PSReadLine/2.4.5'
[IO.Directory]::CreateDirectory((Split-Path $copyDirectory -Parent)) | Out-Null
Copy-Item -LiteralPath $sourceDirectory -Destination $copyDirectory -Recurse
Import-Module `
    -Name (Join-Path $copyDirectory 'PSReadLine.psd1') `
    -Global `
    -Force `
    -ErrorAction Stop `
    -WarningAction SilentlyContinue
if (-not [string]::IsNullOrWhiteSpace($TamperRelativePath)) {
    $tamperPath = Join-Path $copyDirectory $TamperRelativePath
    [byte[]]$tamperBytes = [IO.File]::ReadAllBytes($tamperPath)
    [byte[]]$changedBytes = New-Object byte[] ($tamperBytes.Length + 1)
    [Array]::Copy($tamperBytes, $changedBytes, $tamperBytes.Length)
    $changedBytes[$changedBytes.Length - 1] = 0x0A
    [IO.File]::WriteAllBytes($tamperPath, $changedBytes)
}
if ($AddExtraFile) {
    [IO.File]::WriteAllText(
        (Join-Path $copyDirectory 'user-extra-after-load.txt'),
        'preloaded tree must be exact',
        (New-Object Text.UTF8Encoding($false))
    )
}
$moduleBasesBefore = @(
    Get-Module -Name PSReadLine |
        ForEach-Object { [IO.Path]::GetFullPath([string]$_.ModuleBase) }
)
$assemblyLocationsBefore = @(
    [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { [string]$_.GetName().Name -ceq 'Microsoft.PowerShell.PSReadLine' } |
        ForEach-Object { [IO.Path]::GetFullPath([string]$_.Location) }
)
Import-Module `
    -Name (Join-Path $RepositoryRoot 'src/Psh/Psh.psd1') `
    -Force `
    -ErrorAction Stop
$promptBefore = (Get-Item -LiteralPath 'Function:\prompt').ScriptBlock.ToString()
$handlersBefore = @(
    foreach ($chord in @('Tab', 'Ctrl+r', 'UpArrow', 'DownArrow')) {
        $handler = Get-PSReadLineKeyHandler -Chord $chord -ErrorAction Stop
        '{0}|{1}' -f $chord, [string]$handler.Function
    }
)
$initialization = Initialize-PshInteractive
[PSCustomObject][ordered]@{
    success = [bool]$initialization.success
    dependency = $initialization.dependencies.psReadLine
    keyBindingCount = @($initialization.keyBindings).Count
    predictionReason = [string]$initialization.prediction.reason
    gitCompletionRegistered = [bool]$initialization.gitCompletion.registered
    promptEnabled = [bool]$initialization.prompt.enabled
    expectedPreloadBase = [IO.Path]::GetFullPath($copyDirectory)
    moduleSetPreserved = @(
        Compare-Object `
            -ReferenceObject $moduleBasesBefore `
            -DifferenceObject @(
                Get-Module -Name PSReadLine |
                    ForEach-Object { [IO.Path]::GetFullPath([string]$_.ModuleBase) }
            )
    ).Count -eq 0
    assemblySetPreserved = @(
        Compare-Object `
            -ReferenceObject $assemblyLocationsBefore `
            -DifferenceObject @(
                [AppDomain]::CurrentDomain.GetAssemblies() |
                    Where-Object { [string]$_.GetName().Name -ceq 'Microsoft.PowerShell.PSReadLine' } |
                    ForEach-Object { [IO.Path]::GetFullPath([string]$_.Location) }
            )
    ).Count -eq 0
    promptPreserved = (Get-Item -LiteralPath 'Function:\prompt').ScriptBlock.ToString() -ceq $promptBefore
    handlersPreserved = @(
        Compare-Object `
            -ReferenceObject $handlersBefore `
            -DifferenceObject @(
                foreach ($chord in @('Tab', 'Ctrl+r', 'UpArrow', 'DownArrow')) {
                    $handler = Get-PSReadLineKeyHandler -Chord $chord -ErrorAction Stop
                    '{0}|{1}' -f $chord, [string]$handler.Function
                }
            )
    ).Count -eq 0
} | ConvertTo-Json -Depth 8 -Compress
'@
    [IO.File]::WriteAllText(
        $identicalPreloadScript,
        $identicalPreloadSource,
        (New-Object Text.UTF8Encoding($false))
    )
    $identicalPreloadOutput = @(
        & $currentPowerShellPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $identicalPreloadScript `
            -RepositoryRoot $repositoryRootPath `
            -WorkingRoot $identicalPreloadRoot
    )
    $identicalPreloadExitCode = $LASTEXITCODE
    Assert-PshGoal2Condition ($identicalPreloadExitCode -eq 0) ("The identical PSReadLine preload child test failed: {0}" -f ($identicalPreloadOutput -join ' '))
    $identicalPreloadResult = [string]$identicalPreloadOutput[$identicalPreloadOutput.Count - 1] | ConvertFrom-Json
    Assert-PshGoal2Condition ([bool]$identicalPreloadResult.success) 'An identical preloaded PSReadLine 2.4.5 was rejected.'
    Assert-PshGoal2Condition ([bool]$identicalPreloadResult.dependency.imported) 'An identical preloaded PSReadLine was not reported as active.'
    Assert-PshGoal2Condition ([string]$identicalPreloadResult.dependency.loadAction -ceq 'reused-preloaded-identical') 'An identical preloaded PSReadLine was not reused in place.'
    Assert-PshGoal2Condition ([bool]$identicalPreloadResult.dependency.mutationSuppressed) 'Identical preload reuse did not suppress module replacement.'
    Assert-PshGoal2Condition (-not [bool]$identicalPreloadResult.dependency.restartRequired) 'An identical preloaded PSReadLine incorrectly required a restart.'
    Assert-PshGoal2Condition ([string]$identicalPreloadResult.dependency.assemblyVerificationState -ceq 'reused-identical') 'Identical preload reuse reported the wrong assembly state.'
    Assert-PshGoal2Condition ([bool]$identicalPreloadResult.dependency.treeVerified) 'Identical preload reuse did not verify the complete module tree.'
    Assert-PshGoal2Condition ([string]$identicalPreloadResult.dependency.treeVerificationState -ceq 'reused-identical') 'Identical preload reuse reported the wrong tree state.'
    Assert-PshGoal2Condition ([int]$identicalPreloadResult.dependency.expectedTreeFileCount -eq 7 -and [int]$identicalPreloadResult.dependency.actualTreeFileCount -eq 7) 'Identical preload reuse did not compare two seven-file trees.'
    Assert-PshGoal2Condition ([string]$identicalPreloadResult.dependency.actualAssemblyHash -ceq $expectedPsReadLineAssemblyHash) 'Identical preload reuse reported the wrong implementation hash.'
    Assert-PshGoal2Condition ([string]::Equals([string]$identicalPreloadResult.dependency.loadedModuleBase, [string]$identicalPreloadResult.expectedPreloadBase, $modulePathComparison)) 'Identical preload reuse changed the active module base.'
    Assert-PshGoal2Condition (@($identicalPreloadResult.dependency.removedConflicts).Count -eq 0) 'Identical preload reuse removed a module.'
    Assert-PshGoal2Condition ([bool]$identicalPreloadResult.moduleSetPreserved) 'Identical preload reuse changed the module set.'
    Assert-PshGoal2Condition ([bool]$identicalPreloadResult.assemblySetPreserved) 'Identical preload reuse changed the AppDomain assembly set.'

    $preloadTreeMismatchCases = @(
        [PSCustomObject]@{ Name = 'modified-psm1'; RelativePath = 'PSReadLine.psm1'; AddExtra = $false },
        [PSCustomObject]@{ Name = 'modified-psd1'; RelativePath = 'PSReadLine.psd1'; AddExtra = $false },
        [PSCustomObject]@{ Name = 'extra-file'; RelativePath = $null; AddExtra = $true }
    )
    foreach ($preloadTreeMismatchCase in $preloadTreeMismatchCases) {
        $preloadTreeMismatchRoot = Join-Path $interactiveTemporaryRoot ("psreadline-tree-{0}" -f $preloadTreeMismatchCase.Name)
        $preloadTreeMismatchArguments = @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-File',
            $identicalPreloadScript,
            '-RepositoryRoot',
            $repositoryRootPath,
            '-WorkingRoot',
            $preloadTreeMismatchRoot
        )
        if (-not [string]::IsNullOrWhiteSpace([string]$preloadTreeMismatchCase.RelativePath)) {
            $preloadTreeMismatchArguments += @('-TamperRelativePath', [string]$preloadTreeMismatchCase.RelativePath)
        }
        if ([bool]$preloadTreeMismatchCase.AddExtra) {
            $preloadTreeMismatchArguments += '-AddExtraFile'
        }
        $preloadTreeMismatchOutput = @(& $currentPowerShellPath @preloadTreeMismatchArguments)
        $preloadTreeMismatchExitCode = $LASTEXITCODE
        Assert-PshGoal2Condition ($preloadTreeMismatchExitCode -eq 0) ("The {0} preload-tree child test failed: {1}" -f $preloadTreeMismatchCase.Name, ($preloadTreeMismatchOutput -join ' '))
        $preloadTreeMismatchResult = [string]$preloadTreeMismatchOutput[$preloadTreeMismatchOutput.Count - 1] | ConvertFrom-Json
        Assert-PshGoal2Condition (-not [bool]$preloadTreeMismatchResult.success) "A $($preloadTreeMismatchCase.Name) PSReadLine preload was accepted."
        Assert-PshGoal2Condition (-not [bool]$preloadTreeMismatchResult.dependency.imported) "A $($preloadTreeMismatchCase.Name) PSReadLine preload was reported as active."
        Assert-PshGoal2Condition (-not [bool]$preloadTreeMismatchResult.dependency.treeVerified -and [string]$preloadTreeMismatchResult.dependency.treeVerificationState -ceq 'failed') "A $($preloadTreeMismatchCase.Name) preload did not fail complete-tree verification."
        Assert-PshGoal2Condition ([bool]$preloadTreeMismatchResult.dependency.restartRequired -and [bool]$preloadTreeMismatchResult.dependency.mutationSuppressed) "A $($preloadTreeMismatchCase.Name) preload was not refused before mutation."
        Assert-PshGoal2Condition (@($preloadTreeMismatchResult.dependency.removedConflicts).Count -eq 0 -and @($preloadTreeMismatchResult.dependency.restoredConflicts).Count -eq 0) "A $($preloadTreeMismatchCase.Name) preload triggered module replacement or rollback."
        Assert-PshGoal2Condition ([bool]$preloadTreeMismatchResult.moduleSetPreserved -and [bool]$preloadTreeMismatchResult.assemblySetPreserved) "A $($preloadTreeMismatchCase.Name) preload changed the module or AppDomain assembly set."
        Assert-PshGoal2Condition ([bool]$preloadTreeMismatchResult.promptPreserved -and [bool]$preloadTreeMismatchResult.handlersPreserved) "A $($preloadTreeMismatchCase.Name) preload changed the prompt or key handlers."
        Assert-PshGoal2Condition ([int]$preloadTreeMismatchResult.keyBindingCount -eq 0 -and [string]$preloadTreeMismatchResult.predictionReason -ceq 'DependencyValidationFailed') "A $($preloadTreeMismatchCase.Name) preload configured PSReadLine interaction."
        Assert-PshGoal2Condition (-not [bool]$preloadTreeMismatchResult.gitCompletionRegistered -and -not [bool]$preloadTreeMismatchResult.promptEnabled) "A $($preloadTreeMismatchCase.Name) preload configured Git completion or the prompt."
    }
    $dependencyPropertyNames = @(
        $diagnostic.dependencies.PSObject.Properties |
            ForEach-Object { [string]$_.Name }
    )
    Assert-PshGoal2Condition ($dependencyPropertyNames.Count -eq 1 -and $dependencyPropertyNames[0] -ceq 'psReadLine') 'Interactive diagnostics must report only the PSReadLine dependency.'
    Assert-PshGoal2Condition (@(Get-Job -ErrorAction Ignore).Count -eq $jobCountBefore) 'Interactive initialization created a background job.'
    Assert-PshGoal2Condition (@(Compare-Object $dependencyTreeBefore @(Get-PshGoal2TreeFingerprint -Root $dependencyRoot)).Count -eq 0) 'Interactive initialization changed the locked dependency tree.'

    $warmStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $warmOutput = @(Initialize-PshInteractive)
    $warmStopwatch.Stop()
    Assert-PshGoal2Condition ($warmOutput.Count -eq 1 -and [bool]$warmOutput[0].success) 'Repeated interactive initialization was not idempotent.'
    Assert-PshGoal2Condition ($warmStopwatch.ElapsedMilliseconds -lt 2000) ("Warm interactive initialization took $($warmStopwatch.ElapsedMilliseconds) ms.")
    Assert-PshGoal2Condition ([string]$warmOutput[0].dependencies.psReadLine.loadAction -ceq 'reused-preloaded-identical') 'Repeated initialization did not reuse PSReadLine in place.'
    Assert-PshGoal2Condition ([bool]$warmOutput[0].dependencies.psReadLine.treeVerified -and [string]$warmOutput[0].dependencies.psReadLine.treeVerificationState -ceq 'fixed-path') 'Repeated initialization did not reverify the fixed seven-file tree.'
    Assert-PshGoal2Condition (-not [bool]$warmOutput[0].dependencies.psReadLine.restartRequired -and [bool]$warmOutput[0].dependencies.psReadLine.mutationSuppressed) 'Repeated initialization reported an invalid preload-mutation state.'
    Assert-PshGoal2Condition ([bool]$warmOutput[0].gitCompletion.alreadyRegistered) 'Repeated initialization did not reuse the Git completion registration.'

    $rollbackConflictRoot = Join-Path $interactiveTemporaryRoot 'psreadline-rollback-conflict'
    [IO.Directory]::CreateDirectory($rollbackConflictRoot) | Out-Null
    $rollbackConflictManifest = @"
@{
    RootModule = 'PSReadLine.psm1'
    ModuleVersion = '9.9.9'
    GUID = '$([Guid]::NewGuid())'
    FunctionsToExport = @('Get-PshGoal2RollbackConflictMarker')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
"@
    [IO.File]::WriteAllText(
        (Join-Path $rollbackConflictRoot 'PSReadLine.psd1'),
        $rollbackConflictManifest,
        (New-Object Text.UTF8Encoding($false))
    )
    [IO.File]::WriteAllText(
        (Join-Path $rollbackConflictRoot 'PSReadLine.psm1'),
        'function Get-PshGoal2RollbackConflictMarker { 1 }',
        (New-Object Text.UTF8Encoding($false))
    )
    Import-Module (Join-Path $rollbackConflictRoot 'PSReadLine.psd1') -Global -Force -ErrorAction Stop
    $rollbackModulesBefore = @(
        Get-Module -Name PSReadLine |
            ForEach-Object { [IO.Path]::GetFullPath([string]$_.ModuleBase) } |
            Sort-Object
    )
    Assert-PshGoal2Condition ($rollbackModulesBefore.Count -eq 2) 'The mixed PSReadLine rollback precondition was not established.'
    $rollbackAssembliesBefore = @(
        [AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { [string]$_.GetName().Name -ceq 'Microsoft.PowerShell.PSReadLine' } |
            ForEach-Object { [IO.Path]::GetFullPath([string]$_.Location) }
    )
    $rollbackResult = & $module {
        param($fixedDependencyRoot)
        Import-PshBundledModule `
            -Name 'PSReadLine' `
            -Version ([version]'2.4.5') `
            -DependencyRoot $fixedDependencyRoot `
            -ReplaceLoadedConflicts
    } $dependencyRoot
    $rollbackModulesAfter = @(
        Get-Module -Name PSReadLine |
            ForEach-Object { [IO.Path]::GetFullPath([string]$_.ModuleBase) } |
            Sort-Object
    )
    $rollbackAssembliesAfter = @(
        [AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { [string]$_.GetName().Name -ceq 'Microsoft.PowerShell.PSReadLine' } |
            ForEach-Object { [IO.Path]::GetFullPath([string]$_.Location) }
    )
    Assert-PshGoal2Condition (-not [bool]$rollbackResult.imported) 'A mixed-module PSReadLine state was reported as successful.'
    Assert-PshGoal2Condition ([string]$rollbackResult.assemblyVerificationState -ceq 'failed') 'Mixed-module refusal did not report failed assembly verification.'
    Assert-PshGoal2Condition ([bool]$rollbackResult.restartRequired) 'Mixed-module refusal did not require a fresh process.'
    Assert-PshGoal2Condition ([bool]$rollbackResult.mutationSuppressed) 'Mixed-module refusal was not completed before mutation.'
    Assert-PshGoal2Condition (@($rollbackResult.removedConflicts).Count -eq 0) 'Mixed-module refusal removed a conflict.'
    Assert-PshGoal2Condition (@($rollbackResult.restoredConflicts).Count -eq 0) 'Mixed-module refusal claimed to restore a conflict.'
    Assert-PshGoal2Condition (@($rollbackResult.restorationErrors).Count -eq 0) 'Mixed-module refusal reported a restoration error.'
    Assert-PshGoal2Condition (@(Compare-Object $rollbackModulesBefore $rollbackModulesAfter).Count -eq 0) 'Mixed-module refusal changed the complete pre-call module set.'
    Assert-PshGoal2Condition (@(Compare-Object $rollbackAssembliesBefore $rollbackAssembliesAfter).Count -eq 0) 'Mixed-module refusal changed the AppDomain assembly set.'
    $rollbackConflictModule = Get-Module -Name PSReadLine |
        Where-Object {
            [string]::Equals(
                [IO.Path]::GetFullPath([string]$_.ModuleBase),
                [IO.Path]::GetFullPath($rollbackConflictRoot),
                $modulePathComparison
            )
        }
    $rollbackConflictModule | Remove-Module -Force -ErrorAction Stop
    Assert-PshGoal2Condition (@(Get-Module -Name PSReadLine).Count -eq 1) 'The rollback test cleanup did not preserve only the bundled module.'

    $expectedBindings = @{
        Tab       = 'MenuComplete'
        'Ctrl+r'  = 'ReverseSearchHistory'
        UpArrow   = 'HistorySearchBackward'
        DownArrow = 'HistorySearchForward'
    }
    foreach ($chord in $expectedBindings.Keys) {
        $handler = Get-PSReadLineKeyHandler -Chord $chord
        Assert-PshGoal2Condition ($null -ne $handler) "PSReadLine has no handler for $chord."
        Assert-PshGoal2Condition ([string]$handler.Function -ceq $expectedBindings[$chord]) "$chord is bound to the wrong PSReadLine function."
        $bindingDiagnostic = @($diagnostic.keyBindings | Where-Object { [string]$_.chord -ceq $chord })[0]
        Assert-PshGoal2Condition ([string]$bindingDiagnostic.implementationAssemblyHash -ceq $expectedPsReadLineAssemblyHash) "$chord was configured through different PSReadLine implementation bytes."
    }

    if ([bool]$diagnostic.terminal.supported) {
        Assert-PshGoal2Condition ([bool]$diagnostic.prediction.enabled) ("Prediction did not enable in a VT-capable host: $($diagnostic.prediction.error)")
        Assert-PshGoal2Condition ([string]$diagnostic.prediction.source -ceq 'History') 'Prediction source is not History.'
        Assert-PshGoal2Condition ([string]$diagnostic.prediction.viewStyle -ceq 'ListView') 'Prediction view style is not ListView.'
        Assert-PshGoal2Condition ([string]$diagnostic.prediction.implementationAssemblyHash -ceq $expectedPsReadLineAssemblyHash) 'Prediction was configured through different PSReadLine implementation bytes.'
    }
    else {
        Assert-PshGoal2Condition (-not [bool]$diagnostic.prediction.enabled) 'Prediction stayed enabled in a non-VT host.'
        Assert-PshGoal2Condition (-not [string]::IsNullOrWhiteSpace([string]$diagnostic.prediction.reason)) 'Prediction fallback has no reason.'
    }

    $gitCommand = Get-Command -Name git -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    Assert-PshGoal2Condition ($null -ne $gitCommand) 'Git is required for Goal 2 Git completion acceptance.'
    Assert-PshGoal2Condition ([bool]$diagnostic.gitCompletion.registered) ("Git completion registration failed: $($diagnostic.gitCompletion.error)")
    Assert-PshGoal2Condition ([string]$diagnostic.gitCompletion.mode -ceq 'PshOfflineNativeCompleter') 'Git completion is not using the Psh offline adapter.'
    $nativeRegistrarAvailable = (Get-Command Register-ArgumentCompleter).Parameters.ContainsKey('Native')
    $expectedRegistrationSyntax = if ($nativeRegistrarAvailable) { 'ExplicitNativeSwitch' } else { 'ImplicitNativeParameterSet' }
    Assert-PshGoal2Condition ([string]$diagnostic.gitCompletion.registrar -ceq 'NativeArgumentCompleter') 'Git completion did not register with the engine native completer registry.'
    Assert-PshGoal2Condition ([string]$diagnostic.gitCompletion.registrationSyntax -ceq $expectedRegistrationSyntax) 'Git completion selected the wrong registration syntax for this PowerShell runtime.'

    $unicodeName = ([char]0x4E2D).ToString() + ([char]0x6587).ToString()
    $gitRepository = Join-Path -Path $interactiveTemporaryRoot -ChildPath ("$unicodeName path with spaces")
    [IO.Directory]::CreateDirectory($gitRepository) | Out-Null
    $gitPath = [string]$gitCommand.Source
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        $gitPath = [string]$gitCommand.Path
    }
    Invoke-PshGoal2Git -GitPath $gitPath -ArgumentList @('-C', $gitRepository, 'init')
    Invoke-PshGoal2Git -GitPath $gitPath -ArgumentList @('-C', $gitRepository, 'config', 'user.name', 'Psh Goal2 Test')
    Invoke-PshGoal2Git -GitPath $gitPath -ArgumentList @('-C', $gitRepository, 'config', 'user.email', 'goal2@example.invalid')
    [IO.File]::WriteAllText((Join-Path $gitRepository 'tracked.txt'), 'goal2', (New-Object Text.UTF8Encoding($false)))
    Invoke-PshGoal2Git -GitPath $gitPath -ArgumentList @('-C', $gitRepository, 'add', 'tracked.txt')
    Invoke-PshGoal2Git -GitPath $gitPath -ArgumentList @('-C', $gitRepository, 'commit', '-m', 'initial')
    Invoke-PshGoal2Git -GitPath $gitPath -ArgumentList @('-C', $gitRepository, 'branch', '-M', 'main')
    Invoke-PshGoal2Git -GitPath $gitPath -ArgumentList @('-C', $gitRepository, 'branch', 'feature/test')

    Set-Location -LiteralPath $gitRepository
    $rootCompletion = TabExpansion2 -InputScript 'git che' -CursorColumn 7
    $rootCompletionText = @($rootCompletion.CompletionMatches | ForEach-Object { $_.CompletionText })
    Assert-PshGoal2Condition ($rootCompletionText -contains 'checkout') 'Git root completion did not offer checkout.'
    $branchInput = 'git checkout fea'
    $branchCompletion = TabExpansion2 -InputScript $branchInput -CursorColumn $branchInput.Length
    $branchCompletionText = @($branchCompletion.CompletionMatches | ForEach-Object { $_.CompletionText })
    Assert-PshGoal2Condition ($branchCompletionText -contains 'feature/test') 'Git ref completion did not offer the local feature branch.'
    Assert-PshGoal2Condition (@(Get-Job -ErrorAction Ignore).Count -eq $jobCountBefore) 'Git completion created a background job.'

    $overwritingCompleter = { 'overwritten-sentinel' }
    if ($nativeRegistrarAvailable) {
        Register-ArgumentCompleter `
            -Native `
            -CommandName @('git', 'git.exe') `
            -ScriptBlock $overwritingCompleter
    }
    else {
        Register-ArgumentCompleter `
            -CommandName @('git', 'git.exe') `
            -ScriptBlock $overwritingCompleter
    }
    $overwrittenInput = 'git overwritten'
    $overwrittenCompletion = [Management.Automation.CommandCompletion]::CompleteInput(
        $overwrittenInput,
        $overwrittenInput.Length,
        $null
    )
    Assert-PshGoal2Condition (@($overwrittenCompletion.CompletionMatches.CompletionText) -contains 'overwritten-sentinel') 'The registry-overwrite precondition was not established.'

    $repairInitialization = Initialize-PshInteractive
    Assert-PshGoal2Condition ([bool]$repairInitialization.success) 'Warm initialization failed while repairing the Git engine completer.'
    Assert-PshGoal2Condition ([bool]$repairInitialization.gitCompletion.alreadyRegistered) 'Warm initialization did not report the existing Git registration.'
    $repairedInput = 'git che'
    $repairedCompletion = [Management.Automation.CommandCompletion]::CompleteInput(
        $repairedInput,
        $repairedInput.Length,
        $null
    )
    Assert-PshGoal2Condition (@($repairedCompletion.CompletionMatches.CompletionText) -contains 'checkout') 'Warm initialization did not repair an overwritten Git engine completer.'

    $readLineCompletion = Invoke-PshGoal2PSReadLineCompletion -InputScript $branchInput
    Assert-PshGoal2Condition ($null -ne $readLineCompletion) 'PSReadLine returned no completion object for Git input.'
    Assert-PshGoal2Condition (@($readLineCompletion.CompletionMatches.CompletionText) -contains 'feature/test') 'The real PSReadLine completion core did not receive the Git ref candidate.'

    $headOutput = @(& $gitPath -C $gitRepository rev-parse HEAD)
    $headObjectId = [string]$headOutput[0]
    Assert-PshGoal2Condition ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($headObjectId)) 'The large-ref fixture could not resolve HEAD.'
    $packedRefs = New-Object Text.StringBuilder
    [void]$packedRefs.Append("# pack-refs with: fully-peeled sorted`n")
    for ($refIndex = 0; $refIndex -lt 6000; $refIndex++) {
        [void]$packedRefs.Append(("{0} refs/heads/large-ref-{1:d5}`n" -f $headObjectId.Trim(), $refIndex))
    }
    [IO.File]::WriteAllText(
        (Join-Path $gitRepository '.git/packed-refs'),
        $packedRefs.ToString(),
        (New-Object Text.UTF8Encoding($false))
    )
    $largeRefStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $largeRefNames = @(& $module {
        param($workingDirectory, $executable)
        Get-PshGitRefNames `
            -WorkingDirectory $workingDirectory `
            -GitExecutablePath $executable `
            -TimeoutMilliseconds 2000
    } $gitRepository $gitPath)
    $largeRefStopwatch.Stop()
    Assert-PshGoal2Condition ($largeRefNames.Count -eq 4096) 'The large Git stdout stream was not drained into the bounded result set.'
    Assert-PshGoal2Condition ($largeRefNames -contains 'large-ref-00000') 'The large Git stdout regression lost expected ref data.'
    Assert-PshGoal2Condition ($largeRefStopwatch.ElapsedMilliseconds -lt 5000) 'The large Git stdout regression exceeded its bounded wait.'

    $promptInitialization = Initialize-PshInteractive -EnablePrompt
    Assert-PshGoal2Condition ([bool]$promptInitialization.success -and [bool]$promptInitialization.prompt.enabled) ("Prompt initialization failed: $($promptInitialization.prompt.error)")
    $errorCountBeforeFailurePrompt = $Error.Count
    $failurePromptText = & {
        $global:LASTEXITCODE = 37
        Write-Error 'Expected prompt-status test failure.' -ErrorAction SilentlyContinue
        prompt
    }
    Assert-PshGoal2Condition ($failurePromptText.StartsWith('[1] ')) 'The prompt did not report the previous PowerShell failure.'
    Assert-PshGoal2Condition ($failurePromptText.Contains($gitRepository)) 'The prompt did not preserve the Unicode path with spaces.'
    Assert-PshGoal2Condition ($failurePromptText.Contains('(git:main)')) 'The prompt did not report the current Git branch.'
    Assert-PshGoal2Condition ($global:LASTEXITCODE -eq 37) 'The prompt changed LASTEXITCODE after a failed command.'
    Assert-PshGoal2Condition ($Error.Count -eq ($errorCountBeforeFailurePrompt + 1)) 'The prompt polluted the Error history while rendering a failure.'
    Assert-PshGoal2Condition ($failurePromptText.IndexOf([char]27) -lt 0) 'The ASCII fallback prompt contains an ANSI escape character.'

    $global:LASTEXITCODE = 41
    $successPromptText = & {
        $null = Get-Location
        prompt
    }
    Assert-PshGoal2Condition ($successPromptText.StartsWith('[0] ')) 'The prompt did not report the previous PowerShell success.'
    Assert-PshGoal2Condition ($global:LASTEXITCODE -eq 41) 'The prompt changed a pre-existing LASTEXITCODE after success.'

    Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
    $Error.Clear()
    $noLastExitPromptText = & {
        $null = Get-Location
        prompt
    }
    Assert-PshGoal2Condition ($noLastExitPromptText.StartsWith('[0] ')) 'The prompt failed without LASTEXITCODE.'
    Assert-PshGoal2Condition ($null -eq (Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore)) 'The prompt created LASTEXITCODE in a fresh state.'
    Assert-PshGoal2Condition ($Error.Count -eq 0) 'The normal prompt path added a record to Error history.'

    Set-Location -LiteralPath $originalLocation.Path
    Remove-Module Psh -Force -ErrorAction Ignore
    $missingPromptModuleRoot = Join-Path $interactiveTemporaryRoot 'missing-prompt/Psh'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($missingPromptModuleRoot)) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'src/Psh') -Destination $missingPromptModuleRoot -Recurse
    [IO.File]::Delete((Join-Path $missingPromptModuleRoot 'Interactive/Prompt.ps1'))
    Import-Module -Name (Join-Path $missingPromptModuleRoot 'Psh.psd1') -Force -ErrorAction Stop
    $fixedPsReadLineManifest = Join-Path $dependencyRoot 'PSReadLine/2.4.5/PSReadLine.psd1'
    $missingPromptDisabled = Initialize-PshInteractive `
        -PSReadLinePath $fixedPsReadLineManifest
    $missingPromptEnabled = Initialize-PshInteractive `
        -PSReadLinePath $fixedPsReadLineManifest `
        -EnablePrompt
    Assert-PshGoal2Condition ([bool]$missingPromptDisabled.success) 'A missing prompt implementation broke initialization when the prompt was not requested.'
    Assert-PshGoal2Condition (-not [bool]$missingPromptEnabled.success) 'A missing requested prompt was not reported as a structured failure.'
    Assert-PshGoal2Condition ([string]$missingPromptEnabled.prompt.error -like 'Prompt implementation is missing:*') 'The missing-prompt diagnostic lost the original error.'
    Remove-Module Psh -Force -ErrorAction Ignore
    Remove-Module PSReadLine -Force -ErrorAction Ignore

    [IO.Directory]::CreateDirectory($profileTemporaryRoot) | Out-Null
    $profileCaseRoot = Join-Path $profileTemporaryRoot 'roundtrip'
    $profileStateRoot = Join-Path $profileCaseRoot 'state'
    $utf8NoBom = New-Object Text.UTF8Encoding($false, $true)
    $utf8Bom = New-Object Text.UTF8Encoding($true, $true)
    $utf16LittleEndian = New-Object Text.UnicodeEncoding($false, $true, $true)
    $unicodeText = '# ' + $unicodeName
    $profileCases = @(
        [PSCustomObject]@{
            Path = Join-Path $profileCaseRoot 'utf8-lf/profile.ps1'
            Bytes = ConvertTo-PshGoal2Bytes -Text ("$unicodeText`n`$value = 1") -Encoding $utf8NoBom
        }
        [PSCustomObject]@{
            Path = Join-Path $profileCaseRoot 'utf8-bom-crlf/profile.ps1'
            Bytes = ConvertTo-PshGoal2Bytes -Text ("$unicodeText`r`n`$value = 2`r`n") -Encoding $utf8Bom -IncludePreamble
        }
        [PSCustomObject]@{
            Path = Join-Path $profileCaseRoot 'utf16le-crlf/profile.ps1'
            Bytes = ConvertTo-PshGoal2Bytes -Text ("$unicodeText`r`n`$value = 3`r`n") -Encoding $utf16LittleEndian -IncludePreamble
        }
        [PSCustomObject]@{
            Path = Join-Path $profileCaseRoot 'empty/profile.ps1'
            Bytes = (New-Object byte[] 0)
        }
    )
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $ansiCodePage = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        if ($ansiCodePage -ne 65001) {
            $ansiEncoding = [Text.Encoding]::GetEncoding($ansiCodePage)
            [byte[]]$ansiBytes = $ansiEncoding.GetBytes(
                ('# ANSI ' + [char]0x00E9 + "`r`n`$value = 4`r`n")
            )
            $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
            $ansiIsDistinctFromUtf8 = $false
            try {
                $null = $strictUtf8.GetString($ansiBytes)
            }
            catch [Text.DecoderFallbackException] {
                $ansiIsDistinctFromUtf8 = $true
            }
            if ($ansiIsDistinctFromUtf8) {
                $profileCases += @(
                    [PSCustomObject]@{
                        Path = Join-Path $profileCaseRoot 'windows-ansi-1/profile.ps1'
                        Bytes = $ansiBytes
                    }
                    [PSCustomObject]@{
                        Path = Join-Path $profileCaseRoot 'windows-ansi-2/profile.ps1'
                        Bytes = $ansiEncoding.GetBytes(
                            ('# ANSI repeat ' + [char]0x00E9 + "`r`n`$value = 5`r`n")
                        )
                    }
                )
            }
        }
    }
    $originalProfileBytes = @{}
    foreach ($profileCase in $profileCases) {
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($profileCase.Path)) | Out-Null
        [IO.File]::WriteAllBytes($profileCase.Path, $profileCase.Bytes)
        $originalProfileBytes[$profileCase.Path] = $profileCase.Bytes
    }
    $absentProfilePath = Join-Path $profileCaseRoot 'absent/profile.ps1'
    $allProfilePaths = @($profileCases | ForEach-Object { $_.Path }) + @($absentProfilePath)

    $installResults = @(& $installProfilePath -ProfilePath $allProfilePaths -StateRoot $profileStateRoot)
    Assert-PshGoal2Condition ($installResults.Count -eq $allProfilePaths.Count) 'Profile install did not report every target.'
    Assert-PshGoal2Condition (@($installResults | Where-Object { $_.Status -cne 'Installed' }).Count -eq 0) 'A profile was not installed on the first pass.'
    $installedProfileBytes = @{}
    foreach ($profilePath in $allProfilePaths) {
        Assert-PshGoal2Condition ([IO.File]::Exists($profilePath)) "Installed profile is missing: $profilePath"
        [byte[]]$installedBytes = [IO.File]::ReadAllBytes($profilePath)
        $installedProfileBytes[$profilePath] = $installedBytes
        $originalLength = 0
        if ($originalProfileBytes.ContainsKey($profilePath)) {
            $originalLength = $originalProfileBytes[$profilePath].Length
        }
        Assert-PshGoal2Condition ($installedBytes.Length -gt $originalLength) "Installed profile did not gain the managed block: $profilePath"
    }
    $profileManifestPath = Join-Path $profileStateRoot 'manifest.json'
    $profileManifest = Get-Content -LiteralPath $profileManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PshGoal2Condition (@($profileManifest.profiles).Count -eq $allProfilePaths.Count) 'Profile backup manifest has the wrong target count.'

    $originalLocalAppData = $env:LOCALAPPDATA
    $profileLoaderRoot = Join-Path $profileTemporaryRoot 'loader-appdata'
    $profileLoaderPshRoot = Join-Path $profileLoaderRoot 'Psh'
    [IO.Directory]::CreateDirectory($profileLoaderPshRoot) | Out-Null
    $profileLoaderBootstrap = Join-Path $profileLoaderPshRoot 'bootstrap.ps1'
    try {
        $env:LOCALAPPDATA = $profileLoaderRoot
        $successBootstrap = @'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$currentPath = 'bootstrap-overwrite'
$pshBootstrap = 'bootstrap-overwrite'
$pshInteractive = 'bootstrap-overwrite'
$pshInteractiveError = 'bootstrap-overwrite'
function global:Initialize-PshInteractive {
    $global:PshGoal2ProfileInitCalls++
    [PSCustomObject]@{ success = $true; errors = @() }
}
'@
        [IO.File]::WriteAllText($profileLoaderBootstrap, $successBootstrap, $utf8NoBom)
        $global:PshGoal2ProfileInitCalls = 0
        $Error.Clear()
        $loaderScope = & {
            Set-StrictMode -Off
            $ErrorActionPreference = 'Continue'
            $currentPath = 'user-current-path'
            $pshBootstrap = 'user-bootstrap'
            $pshInteractive = 'user-interactive'
            $pshInteractiveError = 'user-interactive-error'
            $loaderSuccessOutput = @(. $profileCases[0].Path)
            $strictModeState = 'Off'
            try {
                $null = $PshGoal2UndefinedVariable
            }
            catch {
                $strictModeState = 'On'
            }
            [PSCustomObject]@{
                OutputCount         = $loaderSuccessOutput.Count
                ErrorAction         = [string]$ErrorActionPreference
                StrictMode          = $strictModeState
                CurrentPath         = $currentPath
                BootstrapVariable   = $pshBootstrap
                InteractiveVariable = $pshInteractive
                ErrorVariable       = $pshInteractiveError
            }
        }
        Assert-PshGoal2Condition ($loaderScope.OutputCount -eq 0) 'A successful managed profile loader emitted startup output.'
        Assert-PshGoal2Condition ($global:PshGoal2ProfileInitCalls -eq 1) 'The managed profile loader did not call Initialize-PshInteractive exactly once.'
        Assert-PshGoal2Condition ($Error.Count -eq 0) 'A successful managed profile loader polluted Error history.'
        Assert-PshGoal2Condition ($loaderScope.ErrorAction -ceq 'Continue') 'The managed loader leaked bootstrap ErrorActionPreference into the user scope.'
        Assert-PshGoal2Condition ($loaderScope.StrictMode -ceq 'Off') 'The managed loader leaked bootstrap StrictMode into the user scope.'
        Assert-PshGoal2Condition ($loaderScope.CurrentPath -ceq 'user-current-path') 'The managed loader overwrote a user currentPath variable.'
        Assert-PshGoal2Condition ($loaderScope.BootstrapVariable -ceq 'user-bootstrap') 'The managed loader overwrote a user pshBootstrap variable.'
        Assert-PshGoal2Condition ($loaderScope.InteractiveVariable -ceq 'user-interactive') 'The managed loader overwrote a user pshInteractive variable.'
        Assert-PshGoal2Condition ($loaderScope.ErrorVariable -ceq 'user-interactive-error') 'The managed loader overwrote a user pshInteractiveError variable.'

        Remove-Item -LiteralPath 'Function:\global:Initialize-PshInteractive' -Force -ErrorAction Ignore
        Copy-Item `
            -LiteralPath (Join-Path $repositoryRootPath 'src/install/bootstrap.ps1') `
            -Destination $profileLoaderBootstrap `
            -Force
        $realVersionRoot = Join-Path $profileLoaderPshRoot 'versions/0.0.0/Psh'
        [IO.Directory]::CreateDirectory($realVersionRoot) | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $profileLoaderPshRoot 'current.json'),
            '{"schemaVersion":1,"version":"0.0.0"}',
            $utf8NoBom
        )
        $realModuleManifest = @'
@{
    RootModule = 'Psh.psm1'
    ModuleVersion = '0.0.0'
    GUID = '96f4424a-bbc5-4e37-9e25-7c0c2a1a9bc4'
    FunctionsToExport = @('Initialize-PshInteractive')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
'@
        $realModuleBody = @'
function Initialize-PshInteractive {
    [CmdletBinding()]
    param([switch]$EnablePrompt)
    $global:PshGoal2RealBootstrapCalls++
    [PSCustomObject]@{ success = $true; errors = @() }
}
Export-ModuleMember -Function Initialize-PshInteractive
'@
        [IO.File]::WriteAllText((Join-Path $realVersionRoot 'Psh.psd1'), $realModuleManifest, $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $realVersionRoot 'Psh.psm1'), $realModuleBody, $utf8NoBom)
        $global:PshGoal2RealBootstrapCalls = 0
        $realBootstrapScope = & {
            Set-StrictMode -Off
            $ErrorActionPreference = 'Continue'
            $currentPath = 'user-current-path'
            $versionRoot = 'user-version-root'
            $moduleManifestPath = 'user-module-manifest'
            $realBootstrapOutput = @(. $profileCases[0].Path)
            $strictModeState = 'Off'
            try {
                $null = $PshGoal2RealBootstrapUndefinedVariable
            }
            catch {
                $strictModeState = 'On'
            }
            [PSCustomObject]@{
                OutputCount        = $realBootstrapOutput.Count
                ErrorAction        = [string]$ErrorActionPreference
                StrictMode         = $strictModeState
                CurrentPath        = $currentPath
                VersionRoot        = $versionRoot
                ModuleManifestPath = $moduleManifestPath
            }
        }
        Assert-PshGoal2Condition ($realBootstrapScope.OutputCount -eq 0) 'The real bootstrap integration emitted profile startup output.'
        Assert-PshGoal2Condition ($global:PshGoal2RealBootstrapCalls -eq 1) 'The real bootstrap integration did not initialize exactly once.'
        Assert-PshGoal2Condition ($realBootstrapScope.ErrorAction -ceq 'Continue') 'The real bootstrap leaked ErrorActionPreference into the user scope.'
        Assert-PshGoal2Condition ($realBootstrapScope.StrictMode -ceq 'Off') 'The real bootstrap leaked StrictMode into the user scope.'
        Assert-PshGoal2Condition ($realBootstrapScope.CurrentPath -ceq 'user-current-path') 'The real bootstrap overwrote the user currentPath variable.'
        Assert-PshGoal2Condition ($realBootstrapScope.VersionRoot -ceq 'user-version-root') 'The real bootstrap overwrote the user versionRoot variable.'
        Assert-PshGoal2Condition ($realBootstrapScope.ModuleManifestPath -ceq 'user-module-manifest') 'The real bootstrap overwrote the user moduleManifestPath variable.'
        Remove-Module Psh -Force -ErrorAction Ignore

        $failureBootstrap = @'
function global:Initialize-PshInteractive {
    [PSCustomObject]@{ success = $false; errors = @('expected test failure') }
}
'@
        [IO.File]::WriteAllText($profileLoaderBootstrap, $failureBootstrap, $utf8NoBom)
        $warningOutput = @(& {
            $WarningPreference = 'Stop'
            . $profileCases[0].Path
            'PshGoal2LoaderContinued'
        } 3>&1)
        $warningRecords = @($warningOutput | Where-Object { $_ -is [Management.Automation.WarningRecord] })
        Assert-PshGoal2Condition ($warningRecords.Count -eq 1) 'A failed structured initialization did not emit exactly one warning.'
        Assert-PshGoal2Condition ([string]$warningRecords[0] -like '*expected test failure*') 'The profile loader warning lost the structured initialization error.'
        Assert-PshGoal2Condition (@($warningOutput | ForEach-Object { [string]$_ }) -contains 'PshGoal2LoaderContinued') 'WarningPreference Stop escaped the isolated profile loader.'

        [IO.File]::Delete($profileLoaderBootstrap)
        $Error.Clear()
        $missingBootstrapOutput = @(. $profileCases[0].Path)
        Assert-PshGoal2Condition ($missingBootstrapOutput.Count -eq 0) 'A missing bootstrap was not a quiet profile no-op.'
        Assert-PshGoal2Condition ($Error.Count -eq 0) 'A missing bootstrap polluted Error history.'
    }
    finally {
        $env:LOCALAPPDATA = $originalLocalAppData
        Remove-Item -LiteralPath 'Function:\global:Initialize-PshInteractive' -Force -ErrorAction Ignore
        Remove-Variable -Name PshGoal2ProfileInitCalls -Scope Global -ErrorAction Ignore
        Remove-Variable -Name PshGoal2RealBootstrapCalls -Scope Global -ErrorAction Ignore
        Remove-Module Psh -Force -ErrorAction Ignore
    }

    $repeatInstallResults = @(& $installProfilePath -ProfilePath $allProfilePaths -StateRoot $profileStateRoot)
    Assert-PshGoal2Condition (@($repeatInstallResults | Where-Object { $_.Status -cne 'AlreadyInstalled' }).Count -eq 0) 'Repeated profile install was not idempotent.'
    foreach ($profilePath in $allProfilePaths) {
        Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $installedProfileBytes[$profilePath] -Right ([IO.File]::ReadAllBytes($profilePath))) "Repeated install changed profile bytes: $profilePath"
    }

    $uninstallResults = @(& $uninstallProfilePath -ProfilePath $allProfilePaths -StateRoot $profileStateRoot)
    Assert-PshGoal2Condition ($uninstallResults.Count -eq $allProfilePaths.Count) 'Profile uninstall did not report every target.'
    foreach ($profileCase in $profileCases) {
        Assert-PshGoal2Condition ([IO.File]::Exists($profileCase.Path)) "An originally existing profile was deleted: $($profileCase.Path)"
        Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $originalProfileBytes[$profileCase.Path] -Right ([IO.File]::ReadAllBytes($profileCase.Path))) "Profile bytes were not restored exactly: $($profileCase.Path)"
    }
    Assert-PshGoal2Condition (-not [IO.File]::Exists($absentProfilePath)) 'A profile created by Psh was not deleted on uninstall.'
    $emptyManifest = Get-Content -LiteralPath $profileManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PshGoal2Condition (@($emptyManifest.profiles).Count -eq 0) 'Uninstall left profile entries in the manifest.'
    Assert-PshGoal2Condition (@(Get-ChildItem -LiteralPath (Join-Path $profileStateRoot 'backups') -File -ErrorAction Ignore).Count -eq 0) 'Uninstall left a profile backup behind.'

    $relativeRoot = Join-Path $profileTemporaryRoot 'relative-paths'
    $relativeProfile = Join-Path $relativeRoot 'nested/profile.ps1'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($relativeProfile)) | Out-Null
    [byte[]]$relativeOriginal = $utf8NoBom.GetBytes("`$relative = 1`n")
    [IO.File]::WriteAllBytes($relativeProfile, $relativeOriginal)
    $locationBeforeRelativeTest = Get-Location
    try {
        Set-Location -LiteralPath $relativeRoot
        $relativeInstall = @(& $installProfilePath -ProfilePath 'nested/profile.ps1' -StateRoot 'state')
        Assert-PshGoal2Condition ([string]$relativeInstall[0].ProfilePath -ceq $relativeProfile) 'A relative profile path was not resolved from PowerShell PWD.'
        Assert-PshGoal2Condition ([string]$relativeInstall[0].BackupState -ceq (Join-Path $relativeRoot 'state')) 'A relative state root was not resolved from PowerShell PWD.'
        $null = @(& $uninstallProfilePath -ProfilePath 'nested/profile.ps1' -StateRoot 'state')
        Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $relativeOriginal -Right ([IO.File]::ReadAllBytes($relativeProfile))) 'The relative-path profile did not round-trip exactly.'
    }
    finally {
        Set-Location -LiteralPath $locationBeforeRelativeTest.Path
    }

    $profileBlockPath = Join-Path $repositoryRootPath 'src/profile/ProfileBlock.ps1'
    $casRoot = Join-Path $profileTemporaryRoot 'compare-exchange'
    [IO.Directory]::CreateDirectory($casRoot) | Out-Null
    $casResult = & {
        . $profileBlockPath
        $casPath = Join-Path $casRoot 'profile.ps1'
        [byte[]]$expectedBytes = $utf8NoBom.GetBytes('preflight image')
        [byte[]]$concurrentBytes = $utf8NoBom.GetBytes('concurrent editor image')
        [byte[]]$desiredBytes = $utf8NoBom.GetBytes('Psh image')
        [IO.File]::WriteAllBytes($casPath, $concurrentBytes)
        $writeFailed = $false
        try {
            Write-PshAtomicFileByte `
                -Path $casPath `
                -Bytes $desiredBytes `
                -ExpectedToExist $true `
                -ExpectedBytes $expectedBytes
        }
        catch {
            $writeFailed = $true
        }
        [PSCustomObject]@{
            Failed = $writeFailed
            Preserved = Test-PshByteArrayEqual `
                -Left $concurrentBytes `
                -Right ([IO.File]::ReadAllBytes($casPath))
            DebrisCount = @(
                Get-ChildItem -LiteralPath $casRoot -File -Force |
                    Where-Object { $_.Name -cne 'profile.ps1' }
            ).Count
        }
    }
    Assert-PshGoal2Condition ([bool]$casResult.Failed) 'The atomic profile writer accepted a stale preflight image.'
    Assert-PshGoal2Condition ([bool]$casResult.Preserved) 'The atomic profile writer lost a concurrent editor image.'
    Assert-PshGoal2Condition ($casResult.DebrisCount -eq 0) 'A safely rolled-back compare-exchange left recovery debris.'

    $unreadRecoveryResult = & {
        . $profileBlockPath
        $unreadPath = Join-Path $casRoot 'unread-profile.ps1'
        $unreadDisplacedPath = Join-Path $casRoot 'unread-displaced.bin'
        [byte[]]$preflightBytes = $utf8NoBom.GetBytes('preflight image')
        [byte[]]$olderConcurrentBytes = $utf8NoBom.GetBytes('older concurrent image')
        [byte[]]$newerConcurrentBytes = $utf8NoBom.GetBytes('newer concurrent image')
        [byte[]]$pshBytes = $utf8NoBom.GetBytes('Psh image')
        [IO.File]::WriteAllBytes($unreadPath, $newerConcurrentBytes)
        [IO.File]::WriteAllBytes($unreadDisplacedPath, $olderConcurrentBytes)
        $recoveryFailed = $false
        try {
            Restore-PshUnreadDisplacedFileByte `
                -Path $unreadPath `
                -DisplacedPath $unreadDisplacedPath `
                -ExpectedCurrentBytes $pshBytes `
                -ExpectedDisplacedBytes $preflightBytes
        }
        catch {
            $recoveryFailed = $true
        }
        $recoveryEvidence = @(
            Get-ChildItem -LiteralPath $casRoot -File -Force |
                Where-Object { $_.Name -like '*.recovery' }
        )
        [PSCustomObject]@{
            Failed = $recoveryFailed
            NewestImageLive = Test-PshByteArrayEqual `
                -Left $newerConcurrentBytes `
                -Right ([IO.File]::ReadAllBytes($unreadPath))
            EvidenceCount = $recoveryEvidence.Count
            OlderImageRetained = (
                $recoveryEvidence.Count -eq 1 -and
                (Test-PshByteArrayEqual `
                    -Left $olderConcurrentBytes `
                    -Right ([IO.File]::ReadAllBytes($recoveryEvidence[0].FullName)))
            )
        }
    }
    Assert-PshGoal2Condition ([bool]$unreadRecoveryResult.Failed) 'Conflicting pre/post-commit images were reported as a clean rollback.'
    Assert-PshGoal2Condition ([bool]$unreadRecoveryResult.NewestImageLive) 'Post-commit recovery overwrote the newest concurrent image.'
    Assert-PshGoal2Condition ($unreadRecoveryResult.EvidenceCount -eq 1 -and [bool]$unreadRecoveryResult.OlderImageRetained) 'Post-commit recovery lost the older displaced image.'

    $mutexStateRoot = Join-Path $profileTemporaryRoot 'mutex-state'
    $mutexResult = & {
        . $profileBlockPath
        $heldLock = Enter-PshProfileTransactionLock -StateRoot $mutexStateRoot
        $childProcess = $null
        try {
            $alternateMutexStateRoot = $mutexStateRoot + [IO.Path]::DirectorySeparatorChar
            $escapedProfileBlockPath = $profileBlockPath.Replace("'", "''")
            $escapedStateRoot = $alternateMutexStateRoot.Replace("'", "''")
            $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$escapedProfileBlockPath'
try {
    `$childLock = Enter-PshProfileTransactionLock -StateRoot '$escapedStateRoot' -TimeoutMilliseconds 500
    try {
        exit 42
    }
    finally {
        Exit-PshProfileTransactionLock -Lock `$childLock
    }
}
catch {
    if (`$_.Exception.Message -like 'Timed out waiting for another Psh profile transaction*') {
        exit 0
    }
    exit 43
}
"@
            $encodedChildScript = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($childScript)
            )
            $currentPowerShellPath = [string](Get-Process -Id $PID).Path
            if ([string]::IsNullOrWhiteSpace($currentPowerShellPath)) {
                throw 'The current PowerShell executable path is unavailable.'
            }
            $childProcess = Start-Process `
                -FilePath $currentPowerShellPath `
                -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedChildScript) `
                -PassThru
            $childExited = $childProcess.WaitForExit(10000)
            if ($childExited) {
                $childProcess.WaitForExit()
                $childExitCode = [int]$childProcess.ExitCode
            }
            else {
                $childExitCode = -1
                try {
                    $childProcess.Kill()
                }
                catch {
                }
            }
        }
        finally {
            Exit-PshProfileTransactionLock -Lock $heldLock
            if ($null -ne $childProcess) {
                $childProcess.Dispose()
            }
        }
        $postReleaseLock = Enter-PshProfileTransactionLock -StateRoot $mutexStateRoot -TimeoutMilliseconds 1000
        Exit-PshProfileTransactionLock -Lock $postReleaseLock
        [PSCustomObject]@{
            Exited = $childExited
            ExitCode = $childExitCode
        }
    }
    Assert-PshGoal2Condition ([bool]$mutexResult.Exited) 'The cross-process profile transaction mutex probe did not exit in time.'
    Assert-PshGoal2Condition ($mutexResult.ExitCode -eq 0) ("A concurrent profile transaction was not serialized by canonical state root (child exit $($mutexResult.ExitCode)).")

    $uninstallProfileSource = [IO.File]::ReadAllText($uninstallProfilePath)
    Assert-PshGoal2Condition ($uninstallProfileSource.Contains('$manifest.BackupBytesById')) 'Uninstall does not consume the backup bytes validated with the manifest.'
    Assert-PshGoal2Condition (-not $uninstallProfileSource.Contains('[IO.File]::ReadAllBytes($backupPath)')) 'Uninstall re-reads backup bytes after validation.'

    $markerStart = '# >>> Psh managed profile >>>'
    $markerEnd = '# <<< Psh managed profile <<<'
    $malformedVariants = @(
        $markerStart,
        "$markerStart`n$markerStart`n$markerEnd",
        "$markerEnd`n$markerStart",
        "prefix $markerStart`n$markerEnd",
        "$markerStart`nWrite-Output modified`n$markerEnd"
    )
    $malformedIndex = 0
    foreach ($malformedText in $malformedVariants) {
        $malformedRoot = Join-Path $profileTemporaryRoot ("malformed-{0}" -f $malformedIndex)
        $firstProfile = Join-Path $malformedRoot 'first/profile.ps1'
        $badProfile = Join-Path $malformedRoot 'second/profile.ps1'
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($firstProfile)) | Out-Null
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($badProfile)) | Out-Null
        [byte[]]$firstBytes = $utf8NoBom.GetBytes('$first = 1')
        [byte[]]$badBytes = $utf8NoBom.GetBytes($malformedText)
        [IO.File]::WriteAllBytes($firstProfile, $firstBytes)
        [IO.File]::WriteAllBytes($badProfile, $badBytes)
        $malformedState = Join-Path $malformedRoot 'state'
        Assert-PshGoal2ExpectedFailure -Action {
            & $installProfilePath -ProfilePath @($firstProfile, $badProfile) -StateRoot $malformedState
        } -Message "Malformed marker variant $malformedIndex was accepted."
        Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $firstBytes -Right ([IO.File]::ReadAllBytes($firstProfile))) "Malformed marker preflight wrote the first profile for variant $malformedIndex."
        Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $badBytes -Right ([IO.File]::ReadAllBytes($badProfile))) "Malformed marker preflight changed the bad profile for variant $malformedIndex."
        Assert-PshGoal2Condition (-not [IO.File]::Exists((Join-Path $malformedState 'manifest.json'))) "Malformed marker preflight wrote state for variant $malformedIndex."
        $malformedIndex++
    }

    $editedRoot = Join-Path $profileTemporaryRoot 'outside-edit'
    $editedProfile = Join-Path $editedRoot 'profile.ps1'
    $editedState = Join-Path $editedRoot 'state'
    [IO.Directory]::CreateDirectory($editedRoot) | Out-Null
    [byte[]]$editedOriginal = $utf8NoBom.GetBytes("`$before = 1`n")
    [byte[]]$outsideEdit = $utf8NoBom.GetBytes("`$after = 2`n")
    [IO.File]::WriteAllBytes($editedProfile, $editedOriginal)
    $null = @(& $installProfilePath -ProfilePath $editedProfile -StateRoot $editedState)
    [byte[]]$installedEditedProfile = [IO.File]::ReadAllBytes($editedProfile)
    [IO.File]::WriteAllBytes($editedProfile, (Join-PshGoal2ByteArray -First $installedEditedProfile -Second $outsideEdit))
    $editedUninstall = @(& $uninstallProfilePath -ProfilePath $editedProfile -StateRoot $editedState)
    Assert-PshGoal2Condition ([string]$editedUninstall[0].Status -ceq 'RemovedBlockPreservedUserEdits') 'Uninstall did not preserve an edit outside the managed block.'
    [byte[]]$expectedEditedBytes = Join-PshGoal2ByteArray -First $editedOriginal -Second $outsideEdit
    Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $expectedEditedBytes -Right ([IO.File]::ReadAllBytes($editedProfile))) 'Uninstall changed user content outside the managed block.'

    $tamperRoot = Join-Path $profileTemporaryRoot 'tamper'
    $tamperProfile = Join-Path $tamperRoot 'profile.ps1'
    $tamperState = Join-Path $tamperRoot 'state'
    [IO.Directory]::CreateDirectory($tamperRoot) | Out-Null
    [byte[]]$tamperOriginal = $utf8NoBom.GetBytes("`$trusted = 1`n")
    [IO.File]::WriteAllBytes($tamperProfile, $tamperOriginal)
    $null = @(& $installProfilePath -ProfilePath $tamperProfile -StateRoot $tamperState)
    [byte[]]$tamperInstalled = [IO.File]::ReadAllBytes($tamperProfile)
    $tamperManifest = Get-Content -LiteralPath (Join-Path $tamperState 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $tamperBackupPath = Join-Path (Join-Path $tamperState 'backups') ([string]$tamperManifest.profiles[0].backupFileName)
    [byte[]]$tamperBackup = [IO.File]::ReadAllBytes($tamperBackupPath)
    $tamperBackup[0] = $tamperBackup[0] -bxor 0x01
    [IO.File]::WriteAllBytes($tamperBackupPath, $tamperBackup)
    Assert-PshGoal2ExpectedFailure -Action {
        & $uninstallProfilePath -ProfilePath $tamperProfile -StateRoot $tamperState
    } -Message 'A modified profile backup was accepted.'
    Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $tamperInstalled -Right ([IO.File]::ReadAllBytes($tamperProfile))) 'Backup verification failure changed the installed profile.'

    $blockTamperRoot = Join-Path $profileTemporaryRoot 'block-tamper'
    $blockTamperProfile = Join-Path $blockTamperRoot 'profile.ps1'
    $blockTamperState = Join-Path $blockTamperRoot 'state'
    [IO.Directory]::CreateDirectory($blockTamperRoot) | Out-Null
    [IO.File]::WriteAllBytes($blockTamperProfile, $utf8NoBom.GetBytes("`$trusted = 2`n"))
    $null = @(& $installProfilePath -ProfilePath $blockTamperProfile -StateRoot $blockTamperState)
    $blockTamperText = [IO.File]::ReadAllText($blockTamperProfile, $utf8NoBom).Replace('Initialize-PshInteractive -EnablePrompt', 'Initialize-PshInteractive')
    [IO.File]::WriteAllText($blockTamperProfile, $blockTamperText, $utf8NoBom)
    [byte[]]$blockTamperBytes = [IO.File]::ReadAllBytes($blockTamperProfile)
    Assert-PshGoal2ExpectedFailure -Action {
        & $uninstallProfilePath -ProfilePath $blockTamperProfile -StateRoot $blockTamperState
    } -Message 'A modified managed profile block was accepted.'
    Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $blockTamperBytes -Right ([IO.File]::ReadAllBytes($blockTamperProfile))) 'Modified-block refusal changed the profile.'

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $rollbackRoot = Join-Path $profileTemporaryRoot 'rollback'
        $rollbackFirst = Join-Path $rollbackRoot 'first/profile.ps1'
        $rollbackSecond = Join-Path $rollbackRoot 'second/profile.ps1'
        $rollbackState = Join-Path $rollbackRoot 'state'
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($rollbackFirst)) | Out-Null
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($rollbackSecond)) | Out-Null
        [byte[]]$rollbackFirstBytes = $utf8NoBom.GetBytes("`$first = 1`r`n")
        [byte[]]$rollbackSecondBytes = $utf8NoBom.GetBytes("`$second = 2`r`n")
        [IO.File]::WriteAllBytes($rollbackFirst, $rollbackFirstBytes)
        [IO.File]::WriteAllBytes($rollbackSecond, $rollbackSecondBytes)
        [IO.File]::SetAttributes($rollbackSecond, [IO.FileAttributes]::ReadOnly)
        try {
            Assert-PshGoal2ExpectedFailure -Action {
                & $installProfilePath -ProfilePath @($rollbackFirst, $rollbackSecond) -StateRoot $rollbackState
            } -Message 'The read-only second profile did not trigger transaction rollback.'
        }
        finally {
            [IO.File]::SetAttributes($rollbackSecond, [IO.FileAttributes]::Normal)
        }
        Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $rollbackFirstBytes -Right ([IO.File]::ReadAllBytes($rollbackFirst))) 'The first profile was not rolled back after the second target failed.'
        Assert-PshGoal2Condition (Test-PshGoal2ByteArrayEqual -Left $rollbackSecondBytes -Right ([IO.File]::ReadAllBytes($rollbackSecond))) 'The failing second profile changed during rollback.'
        Assert-PshGoal2Condition (-not [IO.File]::Exists((Join-Path $rollbackState 'manifest.json'))) 'Profile transaction rollback left a manifest behind.'
    }
}
finally {
    try {
        Set-Location -LiteralPath $originalLocation.Path
    }
    catch {
    }
    try {
        Set-Item -LiteralPath 'Function:\global:prompt' -Value $originalPrompt -Force
    }
    catch {
    }
    Remove-Module Psh -Force -ErrorAction Ignore
    Remove-Module PSReadLine -Force -ErrorAction Ignore
    Remove-PshGoal2TemporaryTree -Path $interactiveTemporaryRoot
    Remove-PshGoal2TemporaryTree -Path $profileTemporaryRoot
    Remove-PshGoal2TemporaryTree -Path $projectionTemporaryRoot
}

Write-Output 'Goal 2 acceptance passed: fixed dependencies, safe PSReadLine projection, offline interaction, Git completion, prompt behavior, and lossless profile transactions.'
