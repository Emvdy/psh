# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param([string]$RepositoryRoot)

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $scriptPath = [string]$MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($scriptPath)) { throw 'Goal 6 workflow contract could not resolve its script path.' }
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $scriptPath)
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Goal6WorkflowAssertions = 0

function Assert-PshGoal6Workflow {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw "Goal 6 workflow contract failed: $Message" }
    $script:Goal6WorkflowAssertions++
}

function Get-PshGoal6StrictText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshGoal6Workflow ([IO.File]::Exists($Path)) "$Description is missing: $Path"
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-PshGoal6Workflow ($bytes.Length -gt 0) "$Description is empty."
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -or
        ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)))
    Assert-PshGoal6Workflow (-not $hasBom) "$Description must not contain a byte-order mark."
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    try { $text = $utf8.GetString($bytes) }
    catch { throw "Goal 6 workflow contract failed: $Description is not strict UTF-8: $($_.Exception.Message)" }
    Assert-PshGoal6Workflow ($text.IndexOf("`r", [StringComparison]::Ordinal) -lt 0) "$Description must use LF line endings."
    Assert-PshGoal6Workflow ($text.EndsWith("`n", [StringComparison]::Ordinal)) "$Description must end with a newline."
    return $text
}

function Assert-PshGoal6WorkflowMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$Minimum = 1,
        [int]$Maximum = -1
    )

    $count = [regex]::Matches($Text, $Pattern).Count
    Assert-PshGoal6Workflow ($count -ge $Minimum) "$Description is missing."
    if ($Maximum -ge 0) { Assert-PshGoal6Workflow ($count -le $Maximum) "$Description occurs $count times; maximum is $Maximum." }
}

function Assert-PshGoal6WorkflowNoMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshGoal6Workflow (-not [regex]::IsMatch($Text, $Pattern)) $Description
}

function Get-PshGoal6JobBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$JobId
    )

    $match = [regex]::Match($Text, "(?ms)^  $([regex]::Escape($JobId)):\s*\n(?<body>.*?)(?=^  [a-z][a-z0-9-]*:\s*\n|\z)")
    Assert-PshGoal6Workflow $match.Success "Job '$JobId' is missing."
    return $match.Value
}

function Get-PshGoal6StepBlock {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lines = $Text.Split("`n")
    $blocks = New-Object Collections.Generic.List[object]
    for ($index = 0; $index -lt $lines.Length; $index++) {
        $nameMatch = [regex]::Match($lines[$index], '^(?<indent> +)- name:\s*(?<name>[^#]+?)\s*$')
        if (-not $nameMatch.Success) { continue }
        $stepIndent = $nameMatch.Groups['indent'].Length
        $body = New-Object Collections.Generic.List[string]
        [void]$body.Add($lines[$index])
        $bodyIndex = $index + 1
        for (; $bodyIndex -lt $lines.Length; $bodyIndex++) {
            $line = $lines[$bodyIndex]
            if ($line.Length -eq 0) { [void]$body.Add(''); continue }
            $leading = [regex]::Match($line, '^ *').Value.Length
            if ($leading -le $stepIndent) { break }
            [void]$body.Add($line)
        }

        $stepText = $body.ToArray() -join "`n"
        $directIndent = ' ' * ($stepIndent + 2)
        $conditionMatch = [regex]::Match($stepText, "(?m)^$([regex]::Escape($directIndent))if:\s*(?<value>.+?)\s*$")
        $usesMatch = [regex]::Match($stepText, "(?m)^$([regex]::Escape($directIndent))uses:\s*(?<value>[^\s#]+)")
        $shellMatch = [regex]::Match($stepText, "(?m)^$([regex]::Escape($directIndent))shell:\s*(?<value>.+?)\s*$")
        $runMatch = [regex]::Match($stepText, "(?m)^$([regex]::Escape($directIndent))run:\s*\|\s*$")
        $scriptText = ''
        if ($runMatch.Success) {
            $stepLines = $stepText.Split("`n")
            $runLineIndex = [regex]::Matches($stepText.Substring(0, $runMatch.Index), "`n").Count
            $scriptLines = New-Object Collections.Generic.List[string]
            for ($scriptIndex = $runLineIndex + 1; $scriptIndex -lt $stepLines.Length; $scriptIndex++) {
                $scriptLine = $stepLines[$scriptIndex]
                if ($scriptLine.Length -eq 0) { [void]$scriptLines.Add(''); continue }
                $leading = [regex]::Match($scriptLine, '^ *').Value.Length
                if ($leading -le ($stepIndent + 2)) { break }
                $remove = [Math]::Min($stepIndent + 4, $leading)
                [void]$scriptLines.Add($scriptLine.Substring($remove))
            }
            $scriptText = $scriptLines.ToArray() -join "`n"
        }
        [void]$blocks.Add([pscustomobject]@{
                Line = $index + 1
                Name = [string]$nameMatch.Groups['name'].Value
                Condition = if ($conditionMatch.Success) { [string]$conditionMatch.Groups['value'].Value } else { '' }
                Uses = if ($usesMatch.Success) { [string]$usesMatch.Groups['value'].Value } else { '' }
                Shell = if ($shellMatch.Success) { [string]$shellMatch.Groups['value'].Value } else { '' }
                Script = $scriptText
                Text = $stepText
            })
        $index = $bodyIndex - 1
    }
    return $blocks.ToArray()
}

function Get-PshGoal6FunctionBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    Assert-PshGoal6Workflow (@($parseErrors).Count -eq 0) "PowerShell source containing '$Name' has parser errors."
    $functionMatches = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -ceq $Name
            }, $true))
    Assert-PshGoal6Workflow ($functionMatches.Count -eq 1) "Function '$Name' was found $($functionMatches.Count) times."
    return [string]$functionMatches[0].Extent.Text
}

function Invoke-PshGoal6PrimaryFailureSmoke {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateBuildFunction,
        [Parameter(Mandatory = $true)][string]$FailureDetailFunction,
        [Parameter(Mandatory = $true)][string]$FailureDataValueFunction,
        [Parameter(Mandatory = $true)][string]$FailureDiagnosticFunction,
        [Parameter(Mandatory = $true)][string]$ReproStepScript
    )

    $smokeRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal6-primary-smoke-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($smokeRoot)
    try {
        return & {
            param($Root, $CandidateFunctionText, $FailureDetailText, $FailureDataValueText, $FailureDiagnosticText, $WorkflowScriptText)

            function Assert-PshGoal6Condition {
                param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
                if (-not $Condition) { throw $Message }
            }
            function Write-PshGoal6Text {
                param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
                [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
            }

            . ([scriptblock]::Create($FailureDetailText))
            . ([scriptblock]::Create($FailureDataValueText))
            . ([scriptblock]::Create($FailureDiagnosticText))
            . ([scriptblock]::Create($CandidateFunctionText))

            $utf8 = New-Object Text.UTF8Encoding($false)
            $candidateFixtureRoot = Join-Path $Root 'candidate'
            $repositoryFixtureRoot = Join-Path $candidateFixtureRoot 'repository'
            [void][IO.Directory]::CreateDirectory((Join-Path $repositoryFixtureRoot 'scripts'))
            [void][IO.Directory]::CreateDirectory((Join-Path $repositoryFixtureRoot 'src/install'))
            [IO.File]::WriteAllText((Join-Path $repositoryFixtureRoot 'src/install/install.ps1'), "# online`n", $utf8)
            [IO.File]::WriteAllText((Join-Path $repositoryFixtureRoot 'src/install/install-offline.ps1'), "# offline`n", $utf8)
            [IO.File]::WriteAllText((Join-Path $repositoryFixtureRoot 'scripts/Build-PshBootstrapper.ps1'), @'
[CmdletBinding()]
param(
    [string]$OnlineScriptPath,
    [string]$OfflineScriptPath,
    [string]$OutputPath,
    [string]$HashSourcePath,
    [string]$MSBuildPath
)
[IO.File]::WriteAllBytes($OutputPath, [byte[]](1, 2, 3, 4))
'@, $utf8)
            $candidateDriverPath = Join-Path $candidateFixtureRoot 'candidate-primary.ps1'
            [IO.File]::WriteAllText($candidateDriverPath, @'
[CmdletBinding()]
param(
    [string]$CandidateRoot,
    [string]$ReportPath,
    [string]$Version,
    [string]$SourceCommit,
    [string]$BootstrapperPath,
    [string]$ReleaseNotesPath,
    [string]$ReleaseNotesZhCnPath,
    [string]$RepositoryRoot,
    [string]$WorkingRoot
)
[void][IO.Directory]::CreateDirectory($WorkingRoot)
$exception = New-Object Exception('candidate primary smoke')
$exception.Data['PshExitCode'] = 3
$exception.Data['PshErrorId'] = 'PshGoal6CandidateSmokePrimary'
throw $exception
'@, $utf8)

            $script:PshGoal6ReproBootstrapperInvocations = 0
            $script:PshGoal6ReproBootstrapperBuilds = 0
            $script:PshGoal6ReproCandidateDriverInvocations = 0
            $script:PshGoal6ReproCandidateVerifiedBuilds = 0
            $script:PshGoal6ReproWorkingRootPreconditionCount = 0
            $script:PshGoal6ReproWorkingRootCleanupCount = 0
            $candidateFailure = $null
            try {
                $null = Invoke-PshGoal6IndependentCandidateBuild `
                    -RunRoot (Join-Path $candidateFixtureRoot 'run') `
                    -CandidateWorkingRoot (Join-Path $candidateFixtureRoot 'shared-working') `
                    -RepositoryRootPath $repositoryFixtureRoot `
                    -PackageVersion '0.1.0' `
                    -Commit ('a' * 40) `
                    -EnglishReleaseNotes (Join-Path $candidateFixtureRoot 'RELEASE_NOTES.md') `
                    -ChineseReleaseNotes (Join-Path $candidateFixtureRoot 'RELEASE_NOTES.zh-CN.md') `
                    -CandidateScriptPath $candidateDriverPath
            }
            catch { $candidateFailure = $_ }
            $candidateMetadata = Get-PshGoal6FailureDetail -ErrorRecord $candidateFailure

            $workflowFixtureRoot = Join-Path $Root 'workflow'
            $workspaceRoot = Join-Path $workflowFixtureRoot 'workspace'
            $runnerTemp = Join-Path $workflowFixtureRoot 'runner-temp'
            [void][IO.Directory]::CreateDirectory((Join-Path $workspaceRoot 'scripts/goal6'))
            [void][IO.Directory]::CreateDirectory($runnerTemp)
            [IO.File]::WriteAllText((Join-Path $workspaceRoot 'scripts/goal6/Test-Goal6Reproducibility.ps1'), @'
[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string]$Version,
    [string]$SourceCommit,
    [string]$ReleaseNotesPath,
    [string]$ReleaseNotesZhCnPath,
    [string]$RepositoryRoot
)
$exception = New-Object Exception('workflow primary smoke')
$exception.Data['PshExitCode'] = 5
$exception.Data['PshErrorId'] = 'PshGoal6WorkflowSmokePrimary'
throw $exception
'@, $utf8)
            [IO.File]::WriteAllText((Join-Path $runnerTemp 'goal6-candidate-reports'), "retention blocker`n", $utf8)

            $environmentNames = @('GITHUB_WORKSPACE', 'RUNNER_TEMP', 'PSH_GOAL6_VERSION', 'PSH_SOURCE_COMMIT')
            $savedEnvironment = @{}
            foreach ($environmentName in $environmentNames) {
                $savedEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName, 'Process')
            }
            $workflowFailure = $null
            try {
                $env:GITHUB_WORKSPACE = $workspaceRoot
                $env:RUNNER_TEMP = $runnerTemp
                $env:PSH_GOAL6_VERSION = '0.1.0'
                $env:PSH_SOURCE_COMMIT = 'b' * 40
                & ([scriptblock]::Create($WorkflowScriptText))
            }
            catch { $workflowFailure = $_ }
            finally {
                foreach ($environmentName in $environmentNames) {
                    [Environment]::SetEnvironmentVariable($environmentName, $savedEnvironment[$environmentName], 'Process')
                }
            }
            $workflowMetadata = Get-PshGoal6FailureDetail -ErrorRecord $workflowFailure

            return [pscustomobject][ordered]@{
                candidateErrorId = [string]$candidateMetadata.errorId
                candidateExitCode = [int]$candidateMetadata.exitCode
                candidateCleanupDiagnostics = Get-PshGoal6FailureDataValue -ErrorRecord $candidateFailure -Name 'PshReproCleanupDiagnostics'
                workflowErrorId = [string]$workflowMetadata.errorId
                workflowExitCode = [int]$workflowMetadata.exitCode
                workflowRetentionDiagnostics = Get-PshGoal6FailureDataValue -ErrorRecord $workflowFailure -Name 'PshWorkflowRetentionDiagnostics'
            }
        } $smokeRoot $CandidateBuildFunction $FailureDetailFunction $FailureDataValueFunction $FailureDiagnosticFunction $ReproStepScript
    }
    finally {
        if ([IO.Directory]::Exists($smokeRoot)) { Remove-Item -LiteralPath $smokeRoot -Recurse -Force }
    }
}

function Get-PshGoal6ActionBlock {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lines = $Text.Split("`n")
    $blocks = New-Object Collections.Generic.List[object]
    for ($index = 0; $index -lt $lines.Length; $index++) {
        $match = [regex]::Match($lines[$index], '^(?<indent> +)uses:\s*(?<value>[^\s#]+)')
        if (-not $match.Success) { continue }
        $usesIndent = $match.Groups['indent'].Length
        $stepIndent = $usesIndent - 2
        $body = New-Object Collections.Generic.List[string]
        [void]$body.Add($lines[$index])
        for ($bodyIndex = $index + 1; $bodyIndex -lt $lines.Length; $bodyIndex++) {
            $line = $lines[$bodyIndex]
            if ($line.Length -eq 0) { [void]$body.Add(''); continue }
            $leading = [regex]::Match($line, '^ *').Value.Length
            if ($leading -le $stepIndent) { break }
            [void]$body.Add($line)
        }
        [void]$blocks.Add([pscustomobject]@{
                Line = $index + 1
                Uses = [string]$match.Groups['value'].Value
                Text = $body.ToArray() -join "`n"
            })
    }
    return $blocks.ToArray()
}

function Get-PshGoal6RunBlock {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lines = $Text.Split("`n")
    $blocks = New-Object Collections.Generic.List[object]
    for ($index = 0; $index -lt $lines.Length; $index++) {
        $match = [regex]::Match($lines[$index], '^(?<indent> +)run:\s*\|\s*$')
        if (-not $match.Success) { continue }
        $runIndent = $match.Groups['indent'].Length
        $stepIndent = $runIndent - 2
        $stepStart = $index
        while ($stepStart -gt 0) {
            $candidate = $lines[$stepStart - 1]
            if ([regex]::IsMatch($candidate, ('^' + (' ' * $stepIndent) + '- name:'))) { $stepStart--; break }
            $stepStart--
        }
        $shell = ''
        for ($headerIndex = $stepStart; $headerIndex -lt $index; $headerIndex++) {
            $shellMatch = [regex]::Match($lines[$headerIndex], '^\s+shell:\s*(?<shell>.+?)\s*$')
            if ($shellMatch.Success) { $shell = [string]$shellMatch.Groups['shell'].Value }
        }
        $body = New-Object Collections.Generic.List[string]
        for ($bodyIndex = $index + 1; $bodyIndex -lt $lines.Length; $bodyIndex++) {
            $line = $lines[$bodyIndex]
            if ($line.Length -eq 0) { [void]$body.Add(''); continue }
            $leading = [regex]::Match($line, '^ *').Value.Length
            if ($leading -le $runIndent) { break }
            $remove = [Math]::Min($runIndent + 2, $leading)
            [void]$body.Add($line.Substring($remove))
        }
        [void]$blocks.Add([pscustomobject]@{
                Line = $index + 1
                Shell = $shell
                Script = $body.ToArray() -join "`n"
            })
    }
    return $blocks.ToArray()
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$workflowPath = Join-Path $repositoryRootPath '.github/workflows/goal6.yml'
$contractPath = [IO.Path]::GetFullPath([string]$MyInvocation.MyCommand.Path)
$workflowText = Get-PshGoal6StrictText -Path $workflowPath -Description 'Goal 6 workflow'
$contractText = Get-PshGoal6StrictText -Path $contractPath -Description 'Goal 6 workflow contract script'

$contractTokens = $null
$contractErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($contractPath, [ref]$contractTokens, [ref]$contractErrors)
Assert-PshGoal6Workflow (@($contractErrors).Count -eq 0) 'Workflow contract script has PowerShell parser errors.'

$runBlocks = @(Get-PshGoal6RunBlock -Text $workflowText)
Assert-PshGoal6Workflow ($runBlocks.Count -gt 0) 'Workflow contains no explicit run blocks.'
foreach ($runBlock in @($runBlocks | Where-Object { [string]$_.Shell -in @('powershell', 'pwsh') })) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput([string]$runBlock.Script, [ref]$tokens, [ref]$errors)
    $diagnostic = @($errors | ForEach-Object { 'workflow line {0}: {1}' -f ([int]$runBlock.Line + [int]$_.Extent.StartLineNumber), $_.Message }) -join '; '
    Assert-PshGoal6Workflow (@($errors).Count -eq 0) "Embedded PowerShell run block is invalid: $diagnostic"
}

Assert-PshGoal6WorkflowMatch $workflowText '(?m)^on:\s*$' 'on trigger block' 1 1
Assert-PshGoal6WorkflowMatch $workflowText '(?m)^  push:\s*$' 'push trigger' 1 1
Assert-PshGoal6WorkflowMatch $workflowText '(?m)^      - main\s*$' 'main push branch' 1 1
Assert-PshGoal6WorkflowMatch $workflowText "(?m)^      - 'goal6/\*\*'\s*$" 'goal6 branch family' 1 1
Assert-PshGoal6WorkflowMatch $workflowText '(?m)^  workflow_dispatch:\s*$' 'manual workflow trigger' 1 1
Assert-PshGoal6WorkflowNoMatch $workflowText '(?m)^  pull_request:\s*$' 'Workflow must not use pull_request because provenance is a mandatory same-repository gate.'
Assert-PshGoal6WorkflowMatch $workflowText '(?ms)^permissions:\s*\n  contents: read\s*$' 'top-level read-only contents permission' 1 1
Assert-PshGoal6WorkflowMatch $workflowText '(?m)^concurrency:\s*$' 'concurrency block' 1 1
Assert-PshGoal6WorkflowMatch $workflowText '(?m)^  group: goal6-\$\{\{ github\.workflow \}\}-\$\{\{ github\.ref \}\}\s*$' 'workflow/ref concurrency group' 1 1
Assert-PshGoal6WorkflowMatch $workflowText '(?m)^  cancel-in-progress: true\s*$' 'cancel-in-progress setting' 1 1

$jobsText = [regex]::Match($workflowText, '(?ms)^jobs:\s*\n(?<body>.*)\z').Groups['body'].Value
$jobIds = @([regex]::Matches($jobsText, '(?m)^  (?<id>[a-z][a-z0-9-]*):\s*$') | ForEach-Object { [string]$_.Groups['id'].Value })
$expectedJobIds = @('gnu-goldens', 'quality', 'windows-matrix', 'candidate', 'attest', 'evidence')
Assert-PshGoal6Workflow (($jobIds -join '|') -ceq ($expectedJobIds -join '|')) "Workflow job graph changed: $($jobIds -join ', ')."

$goldenJob = Get-PshGoal6JobBlock -Text $workflowText -JobId 'gnu-goldens'
$qualityJob = Get-PshGoal6JobBlock -Text $workflowText -JobId 'quality'
$matrixJob = Get-PshGoal6JobBlock -Text $workflowText -JobId 'windows-matrix'
$candidateJob = Get-PshGoal6JobBlock -Text $workflowText -JobId 'candidate'
$attestJob = Get-PshGoal6JobBlock -Text $workflowText -JobId 'attest'
$evidenceJob = Get-PshGoal6JobBlock -Text $workflowText -JobId 'evidence'

Assert-PshGoal6WorkflowMatch $goldenJob '(?m)^    runs-on: ubuntu-24\.04\s*$' 'pinned Ubuntu golden runner' 1 1
foreach ($batch in @('batch1', 'batch2', 'batch4')) {
    Assert-PshGoal6WorkflowMatch $goldenJob ([regex]::Escape("scripts/goal3-$batch-goldens.sh")) "GNU $batch generator" 1 1
}
Assert-PshGoal6WorkflowMatch $goldenJob 'sha256sum -c SHA256SUMS' 'GNU golden checksum verification' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob '(?m)^    needs: gnu-goldens\s*$' 'runtime dependency on GNU goldens' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob '(?m)^      fail-fast: false\s*$' 'non-short-circuiting matrix strategy' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob '(?m)^          - name: ' 'mandatory runtime matrix entry' 4 4
Assert-PshGoal6WorkflowMatch $matrixJob '(?ms)^          - name: AMD64 Windows PowerShell 5\.1\s*\n            runtime_id: amd64-winps51\s*\n            runner: windows-2022\s*\n            shell: powershell\s*\n            architecture: AMD64\s*\n            expected_edition: Desktop\s*\n            expected_major: 5\s*\n            expected_minor: 1\s*$' 'AMD64 Windows PowerShell 5.1 matrix entry' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob '(?ms)^          - name: AMD64 PowerShell 7\s*\n            runtime_id: amd64-pwsh7\s*\n            runner: windows-2022\s*\n            shell: pwsh\s*\n            architecture: AMD64\s*\n            expected_edition: Core\s*\n            expected_major: 7\s*\n            expected_minor: 0\s*$' 'AMD64 PowerShell 7 matrix entry' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob '(?ms)^          - name: ARM64 Windows PowerShell 5\.1\s*\n            runtime_id: arm64-winps51\s*\n            runner: windows-11-arm\s*\n            shell: powershell\s*\n            architecture: ARM64\s*\n            expected_edition: Desktop\s*\n            expected_major: 5\s*\n            expected_minor: 1\s*$' 'ARM64 Windows PowerShell 5.1 matrix entry' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob '(?ms)^          - name: ARM64 PowerShell 7\s*\n            runtime_id: arm64-pwsh7\s*\n            runner: windows-11-arm\s*\n            shell: pwsh\s*\n            architecture: ARM64\s*\n            expected_edition: Core\s*\n            expected_major: 7\s*\n            expected_minor: 0\s*$' 'ARM64 PowerShell 7 matrix entry' 1 1
Assert-PshGoal6WorkflowNoMatch $matrixJob '(?i)optional|experimental|allow[_-]?failure|continue-on-error' 'Every ARM64 and AMD64 runtime entry must be mandatory.'
Assert-PshGoal6WorkflowMatch $matrixJob "if: \$\{\{ matrix\.expected_edition == 'Desktop' \}\}" 'Windows PowerShell matrix dispatch' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob "if: \$\{\{ matrix\.expected_edition == 'Core' \}\}" 'PowerShell 7 matrix dispatch' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob '(?ms)Run exactly 27 Pester 5\.9\.0 cases in Windows PowerShell 5\.1.*?shell: powershell' 'native Windows PowerShell test step' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob '(?ms)Run exactly 27 Pester 5\.9\.0 cases in PowerShell 7.*?shell: pwsh' 'native PowerShell 7 test step' 1 1

$attestNeeds = @([regex]::Matches($attestJob, '(?m)^      - (?<job>[a-z][a-z0-9-]+)\s*$') | ForEach-Object { [string]$_.Groups['job'].Value })
Assert-PshGoal6Workflow (($attestNeeds -join '|') -ceq 'gnu-goldens|quality|windows-matrix|candidate') 'Attestation must depend on every pre-provenance gate.'
$evidenceNeeds = @([regex]::Matches($evidenceJob, '(?m)^      - (?<job>[a-z][a-z0-9-]+)\s*$') | ForEach-Object { [string]$_.Groups['job'].Value })
Assert-PshGoal6Workflow (($evidenceNeeds -join '|') -ceq 'gnu-goldens|quality|windows-matrix|candidate|attest') 'Evidence retention must depend on all Goal 6 jobs.'
Assert-PshGoal6WorkflowMatch $attestJob '(?ms)^    permissions:\s*\n      contents: read\s*\n      id-token: write\s*\n      attestations: write\s*$' 'minimal provenance job permissions' 1 1

$lockPath = Join-Path $repositoryRootPath 'scripts/goal6/ci-dependencies.lock.json'
$lock = (Get-PshGoal6StrictText -Path $lockPath -Description 'Goal 6 CI dependency lock') | ConvertFrom-Json -ErrorAction Stop
$releaseNotesText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath 'RELEASE_NOTES.md') -Description 'versioned English release notes'
$releaseNotesZhCnText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath 'RELEASE_NOTES.zh-CN.md') -Description 'versioned Simplified Chinese release notes'
Assert-PshGoal6Workflow ($releaseNotesText -match '(?m)^# .+0\.1\.0') 'English release notes do not identify version 0.1.0.'
Assert-PshGoal6Workflow ($releaseNotesZhCnText -match '(?m)^# .+0\.1\.0') 'Simplified Chinese release notes do not identify version 0.1.0.'
$lockedVersions = @{}
foreach ($dependency in @($lock.dependencies)) { $lockedVersions[[string]$dependency.id] = [string]$dependency.version }
Assert-PshGoal6Workflow ($lockedVersions['pester'] -ceq '5.9.0') 'Pester lock version is not 5.9.0.'
Assert-PshGoal6Workflow ($lockedVersions['psscriptanalyzer'] -ceq '1.25.0') 'PSScriptAnalyzer lock version is not 1.25.0.'
Assert-PshGoal6Workflow ($lockedVersions['gitleaks'] -ceq '8.30.1') 'gitleaks lock version is not 8.30.1.'
foreach ($version in @('5.9.0', '1.25.0', '8.30.1')) {
    Assert-PshGoal6WorkflowMatch $workflowText ([regex]::Escape($version)) "locked CI dependency version $version" 1 -1
}
Assert-PshGoal6WorkflowMatch $qualityJob 'scripts/goal6/Install-Goal6CiDependencies\.ps1' 'locked quality dependency installer' 1 1
Assert-PshGoal6WorkflowMatch $qualityJob 'tests/Goal6\.QualityGates\.ps1' 'quality-gate regression script' 1 1
Assert-PshGoal6WorkflowMatch $qualityJob 'scripts/goal6/Invoke-Goal6PSScriptAnalyzer\.ps1' 'PSScriptAnalyzer gate' 1 1
Assert-PshGoal6WorkflowMatch $qualityJob 'scripts/goal6/Test-Goal6SupplyChain\.ps1' 'dependency/license/SBOM gate' 1 1
Assert-PshGoal6WorkflowMatch $qualityJob 'scripts/goal6/Invoke-Goal6SecretScan\.ps1' 'all-history and worktree secret gate' 1 1
Assert-PshGoal6WorkflowMatch $qualityJob "git fetch --force --prune --prune-tags origin '\+refs/heads/\*:refs/remotes/origin/\*' '\+refs/tags/\*:refs/tags/\*'" 'exact origin heads/tags fetch' 1 1
Assert-PshGoal6WorkflowMatch $qualityJob 'rev-parse --is-shallow-repository' 'non-shallow checkout validation' 1 1
Assert-PshGoal6WorkflowMatch $qualityJob 'GITLEAKS_CONFIG_TOML' 'inherited gitleaks configuration removal' 1 1

Assert-PshGoal6WorkflowMatch $qualityJob 'tests/Goal6\.WorkflowContract\.ps1' 'standalone workflow contract invocation' 1 1
Assert-PshGoal6WorkflowMatch $qualityJob 'independentFromPester = \$true' 'standalone contract evidence' 1 1
$pesterRunnerText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath 'scripts/Invoke-Goal6Pester.ps1') -Description 'Goal 6 Pester runner'
$acceptanceText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath 'tests/Goal6.Acceptance.Tests.ps1') -Description 'Goal 6 acceptance Pester tests'
$installerEdgesText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath 'tests/Goal6.InstallerEdges.Tests.ps1') -Description 'Goal 6 installer-edge Pester tests'
foreach ($pesterScope in @($pesterRunnerText, $acceptanceText, $installerEdgesText)) {
    Assert-PshGoal6Workflow (-not $pesterScope.Contains('Goal6.WorkflowContract.ps1')) 'The standalone workflow contract became part of the fixed Pester matrix.'
}
Assert-PshGoal6WorkflowMatch $pesterRunnerText 'TotalCount -ne 27' 'fixed 27-case Pester runner assertion' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob "-PesterVersion '5\.9\.0'" 'exact Pester runner version' 2 2
Assert-PshGoal6WorkflowMatch $matrixJob '\[int\]\$summary\.totalCount -ne 27' 'workflow 27-case summary assertion' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob '\[int\]\$summary\.passedCount -ne 27' 'workflow 27-passed assertion' 1 1
foreach ($zeroField in @('failedCount', 'skippedCount', 'notRunCount')) {
    Assert-PshGoal6WorkflowMatch $matrixJob ("\[int\]\`$summary\." + $zeroField + ' -ne 0') "zero $zeroField assertion" 1 1
}
Assert-PshGoal6WorkflowMatch $matrixJob 'processArchitecture -cne \$env:PSH_EXPECTED_ARCHITECTURE' 'native process architecture assertion' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob 'osArchitecture -cne \$env:PSH_EXPECTED_ARCHITECTURE' 'native OS architecture assertion' 1 1
Assert-PshGoal6WorkflowMatch $matrixJob 'is64BitProcess' 'native 64-bit runtime assertion' 1 -1
foreach ($runtimeId in @('amd64-winps51', 'amd64-pwsh7', 'arm64-winps51', 'arm64-pwsh7')) {
    Assert-PshGoal6WorkflowMatch $workflowText ([regex]::Escape("goal6-runtime-$runtimeId")) "retained runtime artifact $runtimeId" 1 -1
}

Assert-PshGoal6WorkflowMatch $candidateJob '(?m)^    runs-on: windows-2022\s*$' 'canonical candidate AMD64 runner' 1 1
Assert-PshGoal6WorkflowMatch $candidateJob 'PSH_SOURCE_COMMIT: \$\{\{ github\.sha \}\}' 'candidate source commit binding' 1 1
Assert-PshGoal6WorkflowMatch $candidateJob 'scripts/Build-PshBootstrapper\.ps1' 'real bootstrapper build' 1 1
Assert-PshGoal6WorkflowMatch $candidateJob 'scripts/goal6/New-Goal6Candidate\.ps1' 'canonical candidate driver' 1 1
Assert-PshGoal6WorkflowMatch $candidateJob 'Join-Path \$env:GITHUB_WORKSPACE ''RELEASE_NOTES\.md''' 'versioned English release notes input' 2 2
Assert-PshGoal6WorkflowMatch $candidateJob 'Join-Path \$env:GITHUB_WORKSPACE ''RELEASE_NOTES\.zh-CN\.md''' 'versioned Simplified Chinese release notes input' 2 2
Assert-PshGoal6WorkflowNoMatch $candidateJob '(?i)englishNotes|chineseNotes|goal6-candidate-inputs' 'Workflow must not synthesize release-note inputs.'
Assert-PshGoal6WorkflowMatch $candidateJob 'tests/Goal6\.CandidateArtifacts\.ps1' 'candidate catalog contract regression' 1 1
Assert-PshGoal6WorkflowMatch $candidateJob 'scripts/goal6/Invoke-Goal6DefenderScan\.ps1' 'Defender or SHA inventory gate' 1 1
Assert-PshGoal6WorkflowMatch $candidateJob 'scripts/goal6/Test-Goal6Reproducibility\.ps1' 'two-build reproducibility gate' 1 1
Assert-PshGoal6WorkflowMatch $candidateJob 'candidate-verified' 'candidate verified phase assertion' 2 -1
Assert-PshGoal6WorkflowMatch $candidateJob 'exact-13-public-assets-before-provenance-attestation' 'exact pre-provenance asset contract' 1 -1
Assert-PshGoal6WorkflowMatch $candidateJob 'catalogMembershipVerified' 'candidate catalog membership assertion' 2 -1
Assert-PshGoal6WorkflowMatch $candidateJob 'FileAttributes\]::ReparsePoint' 'canonical candidate reparse rejection' 1 -1
Assert-PshGoal6WorkflowMatch $candidateJob 'regular non-reparse files' 'canonical candidate regular-file assertion' 1 1
Assert-PshGoal6WorkflowMatch $candidateJob 'reproducibility-summary\.json' 'retained reproducibility summary' 1 1
Assert-PshGoal6WorkflowMatch $candidateJob 'goal6-candidate-exact-13' 'canonical candidate artifact' 1 1
Assert-PshGoal6WorkflowMatch $candidateJob '(?m)^          name: goal6-candidate-reports\s*$' 'separate candidate report artifact' 1 1
Assert-PshGoal6WorkflowNoMatch $candidateJob '(?i)attestation-(?:bundle|statement).*goal6-candidate(?:[\x27\x22/\\]|\b)' 'Candidate job must not place provenance evidence in the canonical candidate root.'

$candidateSteps = @(Get-PshGoal6StepBlock -Text $candidateJob)
$reproStepMatches = @($candidateSteps | Where-Object { [string]$_.Name -ceq 'Build two independent real candidates for reproducibility' })
Assert-PshGoal6Workflow ($reproStepMatches.Count -eq 1) 'Candidate job must contain exactly one structured reproducibility run step.'
$reproStep = $reproStepMatches[0]
Assert-PshGoal6Workflow ([string]$reproStep.Shell -ceq 'powershell' -and -not [string]::IsNullOrWhiteSpace([string]$reproStep.Script)) 'Reproducibility step must execute one PowerShell run block.'
Assert-PshGoal6WorkflowMatch ([string]$reproStep.Script) '(?m)^\$gateFailure = \$null$' 'reproducibility primary failure slot' 1 1
Assert-PshGoal6WorkflowMatch ([string]$reproStep.Script) '(?m)^\$retentionFailure = \$null$' 'reproducibility retention failure slot' 1 1
Assert-PshGoal6WorkflowMatch ([string]$reproStep.Script) '(?m)^\$retentionDiagnosticAttachmentFailure = \$null$' 'retention diagnostic attachment failure slot' 1 1
Assert-PshGoal6WorkflowMatch ([string]$reproStep.Script) '(?ms)^catch \{\n    \$gateFailure = \$_\n    throw\n\}\nfinally \{' 'bare primary rethrow before retention finally' 1 1
Assert-PshGoal6WorkflowMatch ([string]$reproStep.Script) '(?m)^\s+\$gateFailure\.Exception\.Data\[''PshWorkflowRetentionDiagnostics''\] = \[string\]\$retentionError\.Exception\.Message$' 'retention diagnostic attached to the primary failure' 1 1
Assert-PshGoal6WorkflowMatch ([string]$reproStep.Script) '(?m)^\s+catch \{ \$retentionDiagnosticAttachmentFailure = \$_ \}$' 'retention diagnostic attachment cannot replace primary failure' 1 1
Assert-PshGoal6WorkflowMatch ([string]$reproStep.Script) '(?m)^if \(\$null -ne \$retentionFailure\) \{ throw \$retentionFailure \}$' 'retention-only failure escalation' 1 1

$candidateReportUploadMatches = @($candidateSteps | Where-Object { [string]$_.Name -ceq 'Upload candidate reports' })
Assert-PshGoal6Workflow ($candidateReportUploadMatches.Count -eq 1) 'Candidate job must contain exactly one structured candidate report upload step.'
$candidateReportUploadStep = $candidateReportUploadMatches[0]
Assert-PshGoal6Workflow ([string]$candidateReportUploadStep.Condition -ceq '${{ always() }}') 'Candidate report upload step must run with always().'
Assert-PshGoal6Workflow ([string]$candidateReportUploadStep.Uses -ceq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02') 'Candidate report upload step must use the pinned upload action.'

$reproducibilityText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath 'scripts/goal6/Test-Goal6Reproducibility.ps1') -Description 'Goal 6 reproducibility gate'
$candidateBuildFunction = Get-PshGoal6FunctionBlock -Text $reproducibilityText -Name 'Invoke-PshGoal6IndependentCandidateBuild'
Assert-PshGoal6WorkflowMatch $candidateBuildFunction '(?m)^    \$candidateFailure = \$null$' 'candidate primary failure slot' 1 1
Assert-PshGoal6WorkflowMatch $candidateBuildFunction '(?m)^    \$candidateCleanupFailure = \$null$' 'candidate cleanup failure slot' 1 1
Assert-PshGoal6WorkflowMatch $candidateBuildFunction '(?m)^    \$candidateLogFailure = \$null$' 'candidate log retention failure slot' 1 1
Assert-PshGoal6WorkflowMatch $candidateBuildFunction '(?ms)^    catch \{\n        \$candidateFailure = \$_\n        \$candidateOutput \+= \$_\n    \}\n    finally \{' 'candidate primary capture before cleanup finally' 1 1
Assert-PshGoal6WorkflowNoMatch $candidateBuildFunction '(?ms)catch \{\s*\$candidateFailure = \$_.*?\n\s*throw\s*\n\s*\}' 'Candidate driver catch must not throw before cleanup diagnostics are attached.'
Assert-PshGoal6WorkflowMatch $candidateBuildFunction "PshReproCleanupDiagnostics" 'candidate cleanup diagnostic data' 1 -1
Assert-PshGoal6WorkflowMatch $candidateBuildFunction "PshReproRetentionDiagnostics" 'candidate retention diagnostic data' 1 -1
Assert-PshGoal6WorkflowMatch $candidateBuildFunction '(?m)^        \$PSCmdlet\.ThrowTerminatingError\(\$candidateFailure\)$' 'same candidate primary ErrorRecord rethrow' 1 1
Assert-PshGoal6WorkflowMatch $reproducibilityText '(?m)^    cleanupDiagnostics = \$failureCleanupDiagnostic$' 'candidate cleanup diagnostic summary field' 1 1
Assert-PshGoal6WorkflowMatch $reproducibilityText '(?m)^    retentionDiagnostics = \$failureRetentionDiagnostic$' 'candidate retention diagnostic summary field' 1 1
$failureDetailFunction = Get-PshGoal6FunctionBlock -Text $reproducibilityText -Name 'Get-PshGoal6FailureDetail'
$failureDataValueFunction = Get-PshGoal6FunctionBlock -Text $reproducibilityText -Name 'Get-PshGoal6FailureDataValue'
$failureDiagnosticFunction = Get-PshGoal6FunctionBlock -Text $reproducibilityText -Name 'Add-PshGoal6FailureDiagnostic'
$primaryFailureSmoke = Invoke-PshGoal6PrimaryFailureSmoke `
    -CandidateBuildFunction $candidateBuildFunction `
    -FailureDetailFunction $failureDetailFunction `
    -FailureDataValueFunction $failureDataValueFunction `
    -FailureDiagnosticFunction $failureDiagnosticFunction `
    -ReproStepScript ([string]$reproStep.Script)
Assert-PshGoal6Workflow ([string]$primaryFailureSmoke.candidateErrorId -ceq 'PshGoal6CandidateSmokePrimary' -and [int]$primaryFailureSmoke.candidateExitCode -eq 3) 'Candidate cleanup failure replaced the injected primary ErrorId or exit code.'
Assert-PshGoal6Workflow (-not [string]::IsNullOrWhiteSpace([string]$primaryFailureSmoke.candidateCleanupDiagnostics)) 'Candidate cleanup failure was not attached to the injected primary error.'
Assert-PshGoal6Workflow ([string]$primaryFailureSmoke.workflowErrorId -ceq 'PshGoal6WorkflowSmokePrimary' -and [int]$primaryFailureSmoke.workflowExitCode -eq 5) 'Workflow retention failure replaced the injected gate ErrorId or exit code.'
Assert-PshGoal6Workflow (-not [string]::IsNullOrWhiteSpace([string]$primaryFailureSmoke.workflowRetentionDiagnostics)) 'Workflow retention failure was not attached to the injected gate error.'
Assert-PshGoal6WorkflowMatch $reproducibilityText '\$sharedCandidateWorkingRoot\s*=\s*Join-Path \$outputRootPath ''shared-candidate-working''' 'shared deterministic candidate working root' 1 1
Assert-PshGoal6WorkflowMatch $reproducibilityText '-CandidateWorkingRoot \$sharedCandidateWorkingRoot' 'same candidate working root passed to both independent builds' 2 2
Assert-PshGoal6WorkflowMatch $reproducibilityText 'RunRoot \(Join-Path \$outputRootPath ''run-[12]''\)' 'independent candidate run roots' 2 2
Assert-PshGoal6WorkflowMatch $reproducibilityText 'PshGoal6ReproWorkingRootPreconditionCount\+\+' 'per-build shared working-root precondition' 1 1
Assert-PshGoal6WorkflowMatch $reproducibilityText 'PshGoal6ReproWorkingRootCleanupCount\+\+' 'per-build shared working-root cleanup proof' 1 1
Assert-PshGoal6WorkflowMatch $reproducibilityText 'same-absolute-path-must-not-exist-before-or-after-each-build' 'retained shared working-root policy evidence' 1 1
Assert-PshGoal6WorkflowMatch $reproducibilityText "comparison = 'exact-file-sha256'" 'exact SHA256 comparison for every non-ZIP candidate asset' 1 1
Assert-PshGoal6WorkflowMatch $reproducibilityText "comparison = 'timestamp-normalized-zip'" 'timestamp-only ZIP container normalization' 1 1
Assert-PshGoal6WorkflowMatch $reproducibilityText 'Compare-PshGoal6ZipArchiveManifest' 'full non-time ZIP comparison' 1 1
Assert-PshGoal6WorkflowMatch $reproducibilityText '\$differences\s*=\s*@\(Compare-PshGoal6CandidateManifest -First \$manifestOne -Second \$manifestTwo\)' 'final exact 13-asset candidate comparison remains gating' 1 1
Assert-PshGoal6WorkflowNoMatch $reproducibilityText '(?i)catalog-dependent|non-gating|postCatalogByteReproducible' 'Reproducibility gate must not exempt catalog-dependent candidate bytes.'

$defenderText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath 'scripts/goal6/Invoke-Goal6DefenderScan.ps1') -Description 'Goal 6 Defender gate'
Assert-PshGoal6WorkflowMatch $defenderText 'defender-asset-inventory\.json' 'mandatory Defender SHA inventory report' 1 -1
Assert-PshGoal6WorkflowMatch $defenderText "\`$mode = 'hash-only'" 'Defender-unavailable hash-only fallback' 1 1
Assert-PshGoal6WorkflowMatch $defenderText 'sha256 = Get-PshGoal6Sha256' 'fallback per-file SHA256 inventory' 1 1
Assert-PshGoal6WorkflowMatch $defenderText "status -ceq 'scan-error'" 'available Defender scan-error failure' 1 1
Assert-PshGoal6WorkflowMatch $defenderText "status -ceq 'malware-detected'" 'available Defender malware failure' 1 1

Assert-PshGoal6WorkflowMatch $attestJob 'actions/attest-build-provenance@0f67c3f4856b2e3261c31976d6725780e5e4c373' 'official v4.1.1 provenance action commit' 1 1
Assert-PshGoal6WorkflowMatch $attestJob 'official refs/tags/v4 annotated tag peels to this commit' 'official provenance ref verification comment' 1 1
Assert-PshGoal6WorkflowMatch $attestJob 'subject-path: \$\{\{ runner\.temp \}\}/goal6-attest/candidate/\*' '13-file candidate subject glob' 1 1
Assert-PshGoal6WorkflowMatch $attestJob 'attestation-id' 'attestation ID action output' 1 -1
Assert-PshGoal6WorkflowMatch $attestJob 'attestation-url' 'attestation URL action output' 1 -1
Assert-PshGoal6WorkflowMatch $attestJob 'bundle-path' 'attestation bundle output' 1 -1
Assert-PshGoal6WorkflowMatch $attestJob 'storage-record-ids' 'attestation storage record output' 1 -1
Assert-PshGoal6WorkflowMatch $attestJob 'attestationId = \$env:PSH_ATTESTATION_ID' 'reported attestation ID' 1 1
Assert-PshGoal6WorkflowMatch $attestJob 'attestationUrl = \$env:PSH_ATTESTATION_URL' 'reported attestation URL' 1 1
Assert-PshGoal6WorkflowMatch $attestJob 'storageRecordIds = \$env:PSH_ATTESTATION_STORAGE_RECORD_IDS' 'reported attestation storage record IDs' 1 1
Assert-PshGoal6WorkflowMatch $attestJob 'actionBundlePath = \$originalBundlePath' 'reported action bundle path' 1 1
Assert-PshGoal6WorkflowMatch $attestJob 'subjectCount = 13' 'provenance report subject count' 1 1
Assert-PshGoal6WorkflowMatch $attestJob 'regular non-reparse files' 'attestation subject regular-file assertion' 1 1
Assert-PshGoal6WorkflowMatch $attestJob 'evidenceLocation = \x27external-to-candidate-root\x27' 'external provenance evidence location' 1 1
Assert-PshGoal6WorkflowMatch $attestJob 'provenance-summary\.json' 'provenance JSON report' 1 1
Assert-PshGoal6WorkflowMatch $attestJob 'candidateEntries\.Count -ne 13' 'post-attestation candidate immutability check' 1 1

foreach ($retainedPath in @(
        'docs/compatibility.md',
        'generated/commands.json',
        'goal6-pester-summary.json',
        'workflow-contract-summary.json',
        'psscriptanalyzer-summary.json',
        'dependency-license-sbom-summary.json',
        'gitleaks-summary.json',
        'Goal6.CandidateArtifacts.summary.json',
        'defender-summary.json',
        'defender-asset-inventory.json',
        'reproducibility-summary.json',
        'provenance-summary.json')) {
    Assert-PshGoal6WorkflowMatch $evidenceJob ([regex]::Escape($retainedPath)) "retained evidence path $retainedPath" 1 -1
}
Assert-PshGoal6WorkflowMatch $evidenceJob 'goal6-complete-evidence' 'complete evidence artifact' 1 1
Assert-PshGoal6WorkflowMatch $evidenceJob 'workflowContractSummary\.independentFromPester' 'retained standalone workflow contract validation' 1 1
Assert-PshGoal6WorkflowMatch $evidenceJob 'candidateContractSummary\.assetCount -ne 13' 'retained candidate contract asset-count validation' 1 1
Assert-PshGoal6WorkflowMatch $evidenceJob 'candidateContractSummary\.catalogMembershipVerified' 'retained candidate contract catalog validation' 1 1
Assert-PshGoal6WorkflowMatch $evidenceJob "candidateContractSummary\.provenanceAttestation -cne 'not-created-by-this-gate'" 'retained candidate contract external-provenance validation' 1 1

$allowedActions = @{
    'actions/checkout' = 'df4cb1c069e1874edd31b4311f1884172cec0e10'
    'actions/download-artifact' = 'd3f86a106a0bac45b974a628896c90dbdf5c8093'
    'actions/upload-artifact' = 'ea165f8d65b6e75b540449e92b4886f43607fa02'
    'actions/attest-build-provenance' = '0f67c3f4856b2e3261c31976d6725780e5e4c373'
}
$actionBlocks = @(Get-PshGoal6ActionBlock -Text $workflowText)
Assert-PshGoal6Workflow ($actionBlocks.Count -gt 0) 'Workflow uses no actions.'
foreach ($actionBlock in $actionBlocks) {
    Assert-PshGoal6Workflow ([string]$actionBlock.Uses -match '\A(?<name>[^@]+)@(?<sha>[0-9a-f]{40})\z') "Action is not pinned to a full commit SHA at line $($actionBlock.Line): $($actionBlock.Uses)"
    $actionName = [string]$Matches['name']
    $actionSha = [string]$Matches['sha']
    Assert-PshGoal6Workflow $allowedActions.ContainsKey($actionName) "Unapproved action is used: $actionName"
    Assert-PshGoal6Workflow ($actionSha -ceq [string]$allowedActions[$actionName]) "Action $actionName is pinned to the wrong commit."
    if ($actionName -ceq 'actions/checkout') {
        Assert-PshGoal6Workflow ([string]$actionBlock.Text -match '(?m)^          fetch-depth: 0\s*$') "Checkout at line $($actionBlock.Line) is not fetch-depth 0."
        Assert-PshGoal6Workflow ([string]$actionBlock.Text -match '(?m)^          persist-credentials: false\s*$') "Checkout at line $($actionBlock.Line) persists a workflow credential."
    }
    if ($actionName -ceq 'actions/upload-artifact') {
        Assert-PshGoal6Workflow ([string]$actionBlock.Text -match '(?m)^          if-no-files-found: error\s*$') "Artifact upload at line $($actionBlock.Line) does not fail on missing files."
    }
}
Assert-PshGoal6Workflow (@($actionBlocks | Where-Object { [string]$_.Uses -like 'actions/checkout@*' }).Count -eq 5) 'Workflow must contain exactly five full-history checkout action definitions.'
Assert-PshGoal6Workflow (@($actionBlocks | Where-Object { [string]$_.Uses -like 'actions/attest-build-provenance@*' }).Count -eq 1) 'Workflow must contain exactly one provenance action.'

Assert-PshGoal6WorkflowNoMatch $workflowText '(?im)^\s*continue-on-error\s*:' 'Workflow must not continue after any failed gate.'
Assert-PshGoal6WorkflowNoMatch $workflowText '(?i)\bSet-ExecutionPolicy\b' 'Workflow must not modify execution policy at any scope.'
Assert-PshGoal6WorkflowNoMatch $workflowText '(?i)-ExecutionPolicy\s+Bypass\b' 'Workflow must not launch a Bypass process.'
Assert-PshGoal6WorkflowNoMatch $workflowText '(?i)PSExecutionPolicyPreference' 'Workflow must not override execution policy through the environment.'
Assert-PshGoal6WorkflowNoMatch $workflowText '(?i)\bsecrets?(?:\.|\[|:)' 'Workflow must not consume or define secrets.'
Assert-PshGoal6WorkflowNoMatch $workflowText '(?i)\b(?:prlctl|parallels|vagrant|virtualbox|vboxmanage|hyper-v|hyperv|qemu)\b' 'Workflow must not invoke VM or hypervisor tooling.'
Assert-PshGoal6WorkflowNoMatch $workflowText '(?i)\b(?:signtool|azuresigntool|Set-AuthenticodeSignature|New-GitHubRelease|Publish-Module)\b' 'Workflow must not sign or publish candidate assets.'
Assert-PshGoal6WorkflowNoMatch $workflowText '(?i)(?:^|\s)gh\s+release\b|actions/create-release|softprops/action-gh-release|ncipollo/release-action' 'Workflow must not create a GitHub release.'
Assert-PshGoal6Workflow ($contractText.Contains('independentFromPester') -or $workflowText.Contains('independentFromPester')) 'The workflow contract independence assertion is missing.'

Write-Output "Goal 6 workflow contract passed ($script:Goal6WorkflowAssertions assertions)."
