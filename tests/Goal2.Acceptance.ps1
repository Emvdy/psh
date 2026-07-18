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
        Get-ChildItem -LiteralPath $Root -Recurse -File |
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

foreach ($requiredPath in @(
    $moduleManifestPath,
    $dependencyVerifierPath,
    $installProfilePath,
    $uninstallProfilePath
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
$psCompletionsLock = @($lock.components | Where-Object { $_.name -ceq 'PSCompletions' })[0]
Assert-PshGoal2Condition ([bool]$psCompletionsLock.runtimeAudit.startsUpdateJobOnImport) 'The lock does not record the PSCompletions update-job risk.'
Assert-PshGoal2Condition ([bool]$psCompletionsLock.runtimeAudit.mayContactNetworkAfterImport) 'The lock does not record the PSCompletions network risk.'
Assert-PshGoal2Condition (-not [bool]$psCompletionsLock.runtimeAudit.gitCompletionIncluded) 'The lock incorrectly claims that the Gallery package contains Git completion.'

$dependencyTreeBefore = @(Get-PshGoal2TreeFingerprint -Root $dependencyRoot)
$jobCountBefore = @(Get-Job -ErrorAction Ignore).Count
$globalPsCompletionsBefore = Get-Variable -Name PSCompletions -Scope Global -ErrorAction Ignore
Assert-PshGoal2Condition ($null -eq $globalPsCompletionsBefore) 'The acceptance session was not clean: global PSCompletions state already exists.'

$originalPrompt = (Get-Item -LiteralPath 'Function:\prompt').ScriptBlock
$interactiveTemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("psh-goal2-interactive-{0}" -f [Guid]::NewGuid().ToString('N'))
$profileTemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("psh-goal2-profile-{0}" -f [Guid]::NewGuid().ToString('N'))
$originalLocation = Get-Location

try {
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
$initialization = Initialize-PshInteractive
[PSCustomObject][ordered]@{
    success = [bool]$initialization.success
    dependency = $initialization.dependencies.psReadLine
    mismatchedPath = [IO.Path]::GetFullPath($copiedAssembly)
    mismatchedHash = $mismatchedHash
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
    Assert-PshGoal2Condition ([string]$mismatchResult.dependency.expectedAssemblyHash -ceq $expectedPsReadLineAssemblyHash) 'The mismatch test lost the bundled expected hash.'
    Assert-PshGoal2Condition ([string]$mismatchResult.dependency.actualAssemblyHash -ceq [string]$mismatchResult.mismatchedHash) 'The mismatch diagnostic did not report the active implementation hash.'
    Assert-PshGoal2Condition ([string]$mismatchResult.dependency.actualAssemblyHash -cne $expectedPsReadLineAssemblyHash) 'The altered PSReadLine fixture did not have different bytes.'
    Assert-PshGoal2Condition ([string]::Equals([string]$mismatchResult.dependency.actualAssemblyPath, [string]$mismatchResult.mismatchedPath, $modulePathComparison)) 'The mismatch diagnostic reported the wrong active implementation path.'
    Assert-PshGoal2Condition (@($mismatchResult.loadedModuleBases).Count -eq 1) 'The mismatch rollback did not restore exactly the preloaded PSReadLine module.'
    Assert-PshGoal2Condition ([string]::Equals([string]$mismatchResult.loadedModuleBases[0], (Split-Path -Parent ([string]$mismatchResult.mismatchedPath)), $modulePathComparison)) 'The mismatch rollback did not restore the original PSReadLine module base.'
    Assert-PshGoal2Condition ([bool]$diagnostic.dependencies.psCompletions.validated) 'Bundled PSCompletions metadata was not validated.'
    Assert-PshGoal2Condition (-not [bool]$diagnostic.dependencies.psCompletions.imported) 'The unsafe PSCompletions ScriptsToProcess path was executed.'
    Assert-PshGoal2Condition ([bool]$diagnostic.dependencies.psCompletions.executionSuppressed) 'PSCompletions execution suppression was not reported.'
    Assert-PshGoal2Condition ([string]$diagnostic.dependencies.psCompletions.integrationMode -ceq 'PshOfflineAdapter') 'The offline PSCompletions integration mode was not reported.'
    Assert-PshGoal2Condition ($null -eq (Get-Module -Name PSCompletions)) 'PSCompletions was loaded despite the metadata-only integration contract.'
    Assert-PshGoal2Condition ($null -eq (Get-Variable -Name PSCompletions -Scope Global -ErrorAction Ignore)) 'PSCompletions created mutable global state during initialization.'
    Assert-PshGoal2Condition (@(Get-Job -ErrorAction Ignore).Count -eq $jobCountBefore) 'Interactive initialization created a background job.'
    Assert-PshGoal2Condition (@(Compare-Object $dependencyTreeBefore @(Get-PshGoal2TreeFingerprint -Root $dependencyRoot)).Count -eq 0) 'Interactive initialization changed the locked dependency tree.'

    $warmStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $warmOutput = @(Initialize-PshInteractive)
    $warmStopwatch.Stop()
    Assert-PshGoal2Condition ($warmOutput.Count -eq 1 -and [bool]$warmOutput[0].success) 'Repeated interactive initialization was not idempotent.'
    Assert-PshGoal2Condition ($warmStopwatch.ElapsedMilliseconds -lt 2000) ("Warm interactive initialization took $($warmStopwatch.ElapsedMilliseconds) ms.")
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
    $rollbackResult = & $module {
        param($fixedDependencyRoot)
        $originalAssemblyInspector = ${function:Get-PshCommandImplementationAssembly}
        Set-Item `
            -Path 'Function:script:Get-PshCommandImplementationAssembly' `
            -Value { throw 'Forced post-removal verification failure.' } `
            -Force
        try {
            Import-PshBundledModule `
                -Name 'PSReadLine' `
                -Version ([version]'2.4.5') `
                -DependencyRoot $fixedDependencyRoot `
                -ReplaceLoadedConflicts
        }
        finally {
            Set-Item `
                -Path 'Function:script:Get-PshCommandImplementationAssembly' `
                -Value $originalAssemblyInspector `
                -Force
        }
    } $dependencyRoot
    $rollbackModulesAfter = @(
        Get-Module -Name PSReadLine |
            ForEach-Object { [IO.Path]::GetFullPath([string]$_.ModuleBase) } |
            Sort-Object
    )
    Assert-PshGoal2Condition (-not [bool]$rollbackResult.imported) 'A forced post-import verification failure was reported as successful.'
    Assert-PshGoal2Condition ([string]$rollbackResult.loadAction -ceq 'reused') 'The rollback test re-imported the pre-existing bundled module.'
    Assert-PshGoal2Condition ([string]$rollbackResult.assemblyVerificationState -ceq 'failed') 'The rollback test did not report failed assembly verification.'
    Assert-PshGoal2Condition (@($rollbackResult.removedConflicts).Count -eq 1) 'The rollback test did not remove exactly one conflict.'
    Assert-PshGoal2Condition (@($rollbackResult.restoredConflicts).Count -eq 1) 'The rollback test did not restore exactly one conflict.'
    Assert-PshGoal2Condition (@($rollbackResult.restorationErrors).Count -eq 0) 'The rollback test reported a restoration error.'
    Assert-PshGoal2Condition (@(Compare-Object $rollbackModulesBefore $rollbackModulesAfter).Count -eq 0) 'A failed mixed-module import did not restore the complete pre-call module set.'
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
    $fixedPsCompletionsManifest = Join-Path $dependencyRoot 'PSCompletions/6.10.0/PSCompletions.psd1'
    $missingPromptDisabled = Initialize-PshInteractive `
        -PSReadLinePath $fixedPsReadLineManifest `
        -PSCompletionsPath $fixedPsCompletionsManifest
    $missingPromptEnabled = Initialize-PshInteractive `
        -PSReadLinePath $fixedPsReadLineManifest `
        -PSCompletionsPath $fixedPsCompletionsManifest `
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
}

Write-Output 'Goal 2 acceptance passed: fixed dependencies, offline interaction, Git completion, prompt behavior, and lossless profile transactions.'
