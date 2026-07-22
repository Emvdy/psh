# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DependencyRoot,
    [Parameter(Mandatory = $true)][string]$ReportRoot,
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$LockPath = (Join-Path $PSScriptRoot 'ci-dependencies.lock.json')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Goal6.Common.ps1')

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$dependencyRootPath = [IO.Path]::GetFullPath($DependencyRoot)
$reportRootPath = [IO.Path]::GetFullPath($ReportRoot)
[void][IO.Directory]::CreateDirectory($reportRootPath)

$historyFindingsPath = Join-Path $reportRootPath 'psscriptanalyzer-history-findings.json'
$historySummaryPath = Join-Path $reportRootPath 'psscriptanalyzer-history-summary.json'
$parseErrorsPath = Join-Path $reportRootPath 'psscriptanalyzer-parse-errors.json'
$productionGateFindingsPath = Join-Path $reportRootPath 'psscriptanalyzer-production-gate-findings.json'
$goal6FindingsPath = Join-Path $reportRootPath 'psscriptanalyzer-goal6-findings.json'
$policyPath = Join-Path $reportRootPath 'psscriptanalyzer-policy.json'
$summaryPath = Join-Path $reportRootPath 'psscriptanalyzer-summary.json'

$highRiskRuleDefinitions = @(
    [pscustomobject][ordered]@{
        ruleName = 'PSAvoidUsingInvokeExpression'
        rationale = 'Dynamic string execution can bypass normal code review and input validation boundaries.'
    }
    [pscustomobject][ordered]@{
        ruleName = 'PSAvoidUsingPlainTextForPassword'
        rationale = 'Plain-text password parameters can expose credentials through source, logs, and process state.'
    }
    [pscustomobject][ordered]@{
        ruleName = 'PSAvoidUsingConvertToSecureStringWithPlainText'
        rationale = 'Converting known plain text to SecureString does not protect the original secret.'
    }
    [pscustomobject][ordered]@{
        ruleName = 'PSAvoidUsingUsernameAndPasswordParams'
        rationale = 'Separate username and password parameters bypass the PowerShell credential type.'
    }
    [pscustomobject][ordered]@{
        ruleName = 'PSAvoidUsingComputerNameHardcoded'
        rationale = 'Hard-coded remote hosts create hidden deployment and trust assumptions.'
    }
    [pscustomobject][ordered]@{
        ruleName = 'PSAvoidUsingCmdletAliases'
        rationale = 'Aliases can be environment-dependent and obscure the command actually executed.'
    }
    [pscustomobject][ordered]@{
        ruleName = 'PSUseUsingScopeModifierInNewRunspaces'
        rationale = 'Runspace references without using scope can silently read the wrong value.'
    }
    [pscustomobject][ordered]@{
        ruleName = 'PSAvoidGlobalVars'
        rationale = 'Mutable global state creates cross-command coupling and weakens isolation.'
    }
    [pscustomobject][ordered]@{
        ruleName = 'PSAvoidUsingWMICmdlet'
        rationale = 'Legacy WMI cmdlets are unavailable in modern PowerShell and are replaced by CIM cmdlets.'
    }
    [pscustomobject][ordered]@{
        ruleName = 'PSPossibleIncorrectComparisonWithNull'
        rationale = 'Putting null on the right side can produce incorrect array comparison behavior.'
    }
)
$highRiskRuleNames = @($highRiskRuleDefinitions | ForEach-Object { [string]$_.ruleName })
$highRiskRuleNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($ruleName in $highRiskRuleNames) { [void]$highRiskRuleNameSet.Add($ruleName) }

$historyFindings = New-Object System.Collections.Generic.List[object]
$parseErrors = New-Object System.Collections.Generic.List[object]
$scannedFiles = @()
$productionFiles = @()
$goal6Files = @()
$failure = $null
$moduleVersion = $null

try {
    $lock = Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath ([IO.Path]::GetFullPath($LockPath))
    $dependency = Get-PshGoal6Dependency -Lock $lock -Id 'psscriptanalyzer'
    $modulePath = Resolve-PshGoal6RelativePath -Root $dependencyRootPath -RelativePath ([string]$dependency.package.installedRelativePath) -Description 'PSScriptAnalyzer installed module manifest'
    Assert-PshGoal6Condition ([IO.File]::Exists($modulePath)) "PSScriptAnalyzer module is missing: $modulePath"
    Assert-PshGoal6Condition ((Get-PshGoal6Sha256 -Path $modulePath) -ceq [string]$dependency.package.installedSha256) 'PSScriptAnalyzer installed module manifest hash mismatches.'

    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $loadedModule = Get-Module -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
    Assert-PshGoal6Condition ($null -ne $loadedModule) 'PSScriptAnalyzer did not load.'
    $moduleVersion = [string]$loadedModule.Version
    Assert-PshGoal6Condition ($moduleVersion -ceq [string]$dependency.version) "PSScriptAnalyzer loaded version $moduleVersion instead of $($dependency.version)."

    $trackedOutput = @(& git -C $repositoryRootPath ls-files -- '*.ps1' '*.psm1' '*.psd1' 2>&1)
    $gitExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    Assert-PshGoal6Condition ($gitExitCode -eq 0) "git ls-files failed: $($trackedOutput -join ' ')"
    $scannedFiles = @($trackedOutput | ForEach-Object { ([string]$_).Replace('\', '/') } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('src/Psh/Dependencies/', [StringComparison]::Ordinal)
        } | Sort-Object -Unique)
    Assert-PshGoal6Condition ($scannedFiles.Count -gt 0) 'No Psh-owned PowerShell files were discovered.'
    $productionFiles = @($scannedFiles | Where-Object {
            $_.StartsWith('src/', [StringComparison]::Ordinal) -or $_.StartsWith('scripts/', [StringComparison]::Ordinal)
        })
    $goal6Files = @($scannedFiles | Where-Object { $_.StartsWith('scripts/goal6/', [StringComparison]::Ordinal) })

    foreach ($relativePath in $scannedFiles) {
        $fullPath = Resolve-PshGoal6RelativePath -Root $repositoryRootPath -RelativePath $relativePath -Description 'PSScriptAnalyzer input path'
        Assert-PshGoal6Condition ([IO.File]::Exists($fullPath)) "Tracked PSScriptAnalyzer input is missing: $relativePath"

        $tokens = $null
        $fileParseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$fileParseErrors)
        foreach ($parseError in @($fileParseErrors)) {
            $parseErrors.Add([pscustomobject][ordered]@{
                    source = 'PowerShellParser'
                    path = $relativePath
                    line = [int]$parseError.Extent.StartLineNumber
                    column = [int]$parseError.Extent.StartColumnNumber
                    endLine = [int]$parseError.Extent.EndLineNumber
                    endColumn = [int]$parseError.Extent.EndColumnNumber
                    severity = 'Error'
                    ruleName = 'PowerShellParser'
                    errorId = [string]$parseError.ErrorId
                    message = [string]$parseError.Message
                    incompleteInput = [bool]$parseError.IncompleteInput
                })
        }

        $results = @(Invoke-ScriptAnalyzer -Path $fullPath -Recurse:$false -ErrorAction Stop)
        foreach ($result in $results) {
            $suppressionId = Get-PshGoal6Property -InputObject $result -Name 'SuppressionID'
            $extent = Get-PshGoal6Property -InputObject $result -Name 'Extent'
            $endLine = Get-PshGoal6Property -InputObject $extent -Name 'EndLineNumber'
            $endColumn = Get-PshGoal6Property -InputObject $extent -Name 'EndColumnNumber'
            if ($null -eq $endLine) { $endLine = [int]$result.Line }
            if ($null -eq $endColumn) { $endColumn = [int]$result.Column }
            $historyFindings.Add([pscustomobject][ordered]@{
                    source = 'PSScriptAnalyzer'
                    path = $relativePath
                    line = [int]$result.Line
                    column = [int]$result.Column
                    endLine = [int]$endLine
                    endColumn = [int]$endColumn
                    severity = [string]$result.Severity
                    ruleName = [string]$result.RuleName
                    message = [string]$result.Message
                    suppressionId = if ($null -eq $suppressionId) { $null } else { [string]$suppressionId }
                })
        }
    }
}
catch {
    $failure = [string]$_.Exception.Message
}

$orderedHistoryFindings = @($historyFindings.ToArray() | Sort-Object path, line, column, ruleName)
$orderedParseErrors = @($parseErrors.ToArray() | Sort-Object path, line, column, errorId)
$productionParseErrors = @($orderedParseErrors | Where-Object {
        $_.path.StartsWith('src/', [StringComparison]::Ordinal) -or $_.path.StartsWith('scripts/', [StringComparison]::Ordinal)
    })
$goal6ParseErrors = @($orderedParseErrors | Where-Object { $_.path.StartsWith('scripts/goal6/', [StringComparison]::Ordinal) })

$productionBlockingAnalyzerFindings = New-Object System.Collections.Generic.List[object]
foreach ($finding in @($orderedHistoryFindings | Where-Object {
            $_.path.StartsWith('src/', [StringComparison]::Ordinal) -or $_.path.StartsWith('scripts/', [StringComparison]::Ordinal)
        })) {
    $blockingReasons = New-Object System.Collections.Generic.List[string]
    if ([string]$finding.severity -ceq 'Error') { $blockingReasons.Add('severity-error') }
    if ($highRiskRuleNameSet.Contains([string]$finding.ruleName)) { $blockingReasons.Add('high-risk-rule') }
    if ($blockingReasons.Count -gt 0) {
        $productionBlockingAnalyzerFindings.Add([pscustomobject][ordered]@{
                source = [string]$finding.source
                path = [string]$finding.path
                line = [int]$finding.line
                column = [int]$finding.column
                endLine = [int]$finding.endLine
                endColumn = [int]$finding.endColumn
                severity = [string]$finding.severity
                ruleName = [string]$finding.ruleName
                message = [string]$finding.message
                suppressionId = $finding.suppressionId
                blockingReasons = @($blockingReasons.ToArray())
            })
    }
}

$productionGateFindings = New-Object System.Collections.Generic.List[object]
foreach ($parseError in $productionParseErrors) {
    $productionGateFindings.Add([pscustomobject][ordered]@{
            source = [string]$parseError.source
            path = [string]$parseError.path
            line = [int]$parseError.line
            column = [int]$parseError.column
            endLine = [int]$parseError.endLine
            endColumn = [int]$parseError.endColumn
            severity = [string]$parseError.severity
            ruleName = [string]$parseError.ruleName
            errorId = [string]$parseError.errorId
            message = [string]$parseError.message
            incompleteInput = [bool]$parseError.incompleteInput
            blockingReasons = @('ast-parse-error')
        })
}
foreach ($finding in $productionBlockingAnalyzerFindings.ToArray()) { $productionGateFindings.Add($finding) }
$orderedProductionGateFindings = @($productionGateFindings.ToArray() | Sort-Object path, line, column, source, ruleName)
$goal6Findings = @($orderedHistoryFindings | Where-Object { $_.path.StartsWith('scripts/goal6/', [StringComparison]::Ordinal) })

$historySeveritySummary = @($orderedHistoryFindings | Group-Object severity | Sort-Object Name | ForEach-Object {
        [pscustomobject][ordered]@{ severity = [string]$_.Name; count = [int]$_.Count }
    })
$historyRuleSummary = @($orderedHistoryFindings | Group-Object ruleName | Sort-Object Name | ForEach-Object {
        [pscustomobject][ordered]@{ ruleName = [string]$_.Name; count = [int]$_.Count }
    })
$historyFileSummary = @($orderedHistoryFindings | Group-Object path | Sort-Object Name | ForEach-Object {
        [pscustomobject][ordered]@{ path = [string]$_.Name; count = [int]$_.Count }
    })
$parseFileSummary = @($orderedParseErrors | Group-Object path | Sort-Object Name | ForEach-Object {
        [pscustomobject][ordered]@{ path = [string]$_.Name; count = [int]$_.Count }
    })

$historySummary = [pscustomobject][ordered]@{
    schemaVersion = 1
    report = 'psscriptanalyzer-history'
    status = if ($null -eq $failure) { 'reported' } else { 'incomplete' }
    blocking = $false
    ruleMode = 'all-default-rules-no-suppressions'
    inputMode = 'git-tracked-ps1-psm1-psd1'
    excludedPrefixes = @('src/Psh/Dependencies/')
    scannedFileCount = $scannedFiles.Count
    findingCount = $orderedHistoryFindings.Count
    parseErrorCount = $orderedParseErrors.Count
    bySeverity = $historySeveritySummary
    byRule = $historyRuleSummary
    byFile = $historyFileSummary
    parseErrorsByFile = $parseFileSummary
    findingsReport = 'psscriptanalyzer-history-findings.json'
    parseErrorsReport = 'psscriptanalyzer-parse-errors.json'
    error = $failure
}

$policy = [pscustomobject][ordered]@{
    schemaVersion = 1
    gate = 'psscriptanalyzer'
    module = [pscustomobject][ordered]@{
        name = 'PSScriptAnalyzer'
        version = $moduleVersion
        ruleMode = 'all-default-rules-no-suppressions'
    }
    scopes = @(
        [pscustomobject][ordered]@{
            name = 'history'
            input = 'all git-tracked .ps1, .psm1, and .psd1 files'
            excludedPrefixes = @('src/Psh/Dependencies/')
            disposition = 'report-only'
        }
        [pscustomobject][ordered]@{
            name = 'production'
            includedPrefixes = @('src/', 'scripts/')
            excludedPrefixes = @('src/Psh/Dependencies/')
            disposition = 'hard-gate-by-predicate'
        }
        [pscustomobject][ordered]@{
            name = 'goal6'
            includedPrefixes = @('scripts/goal6/')
            disposition = 'hard-gate-zero-default-findings'
        }
    )
    blockingConditions = @(
        [pscustomobject][ordered]@{
            id = 'production-ast-parse-error'
            scope = 'production'
            predicate = 'PowerShell parser error count is greater than zero'
        }
        [pscustomobject][ordered]@{
            id = 'production-severity-error'
            scope = 'production'
            predicate = 'PSScriptAnalyzer severity equals Error'
            minimumSeverity = 'Error'
        }
        [pscustomobject][ordered]@{
            id = 'production-high-risk-rule'
            scope = 'production'
            predicate = 'PSScriptAnalyzer ruleName is in highRiskRules at any emitted severity'
            rules = $highRiskRuleNames
        }
        [pscustomobject][ordered]@{
            id = 'goal6-zero-default-findings'
            scope = 'goal6'
            predicate = 'PSScriptAnalyzer default finding count is greater than zero'
        }
    )
    highRiskRules = $highRiskRuleDefinitions
    nonBlockingConditions = @(
        [pscustomobject][ordered]@{
            id = 'history-default-rule-debt'
            scope = 'history'
            predicate = 'Any default-rule finding outside a production blocking predicate'
            rationale = 'Existing debt remains fully visible with severity, rule, and file summaries while narrowly defined correctness and security predicates protect production code.'
        }
    )
    exceptions = @(
        [pscustomobject][ordered]@{
            ruleName = 'PSAvoidAssignmentToAutomaticVariable'
            scope = 'production'
            disposition = 'Warning findings are report-only; Error findings are blocked by production-severity-error.'
            rationale = 'Existing Warning findings involving conventional variables such as input and matches remain explicit debt. Assignments classified as Error can collide with read-only automatic variables and are never accepted.'
        }
        [pscustomobject][ordered]@{
            ruleName = 'PSAvoidUsingBrokenHashAlgorithms'
            scope = 'production'
            disposition = 'report-only'
            rationale = 'Psh intentionally implements md5sum compatibility semantics. MD5 is user-requested checksum functionality and is not used for credentials, signatures, dependency verification, or another trust decision.'
        }
    )
    reports = [pscustomobject][ordered]@{
        historyFindings = 'psscriptanalyzer-history-findings.json'
        historySummary = 'psscriptanalyzer-history-summary.json'
        parseErrors = 'psscriptanalyzer-parse-errors.json'
        productionGateFindings = 'psscriptanalyzer-production-gate-findings.json'
        goal6Findings = 'psscriptanalyzer-goal6-findings.json'
        summary = 'psscriptanalyzer-summary.json'
    }
}

$status = if ($null -ne $failure -or $orderedProductionGateFindings.Count -gt 0 -or $goal6Findings.Count -gt 0) { 'failed' } else { 'passed' }
$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    gate = 'psscriptanalyzer'
    status = $status
    module = 'PSScriptAnalyzer'
    moduleVersion = $moduleVersion
    policyReport = 'psscriptanalyzer-policy.json'
    history = [pscustomobject][ordered]@{
        blocking = $false
        scannedFileCount = $scannedFiles.Count
        findingCount = $orderedHistoryFindings.Count
        parseErrorCount = $orderedParseErrors.Count
        findingsReport = 'psscriptanalyzer-history-findings.json'
        summaryReport = 'psscriptanalyzer-history-summary.json'
    }
    production = [pscustomobject][ordered]@{
        blocking = $true
        scannedFileCount = $productionFiles.Count
        parseErrorCount = $productionParseErrors.Count
        analyzerFindingCount = $productionBlockingAnalyzerFindings.Count
        blockingFindingCount = $orderedProductionGateFindings.Count
        findingsReport = 'psscriptanalyzer-production-gate-findings.json'
    }
    goal6 = [pscustomobject][ordered]@{
        blocking = $true
        scannedFileCount = $goal6Files.Count
        parseErrorCount = $goal6ParseErrors.Count
        defaultFindingCount = $goal6Findings.Count
        findingsReport = 'psscriptanalyzer-goal6-findings.json'
    }
    error = $failure
}

Write-PshGoal6Json -Path $historyFindingsPath -InputObject $orderedHistoryFindings
Write-PshGoal6Json -Path $historySummaryPath -InputObject $historySummary
Write-PshGoal6Json -Path $parseErrorsPath -InputObject $orderedParseErrors
Write-PshGoal6Json -Path $productionGateFindingsPath -InputObject $orderedProductionGateFindings
Write-PshGoal6Json -Path $goal6FindingsPath -InputObject $goal6Findings
Write-PshGoal6Json -Path $policyPath -InputObject $policy
Write-PshGoal6Json -Path $summaryPath -InputObject $summary

if ($null -ne $failure) { throw "PSScriptAnalyzer gate failed: $failure" }
if ($orderedProductionGateFindings.Count -gt 0) {
    throw "PSScriptAnalyzer production gate found $($orderedProductionGateFindings.Count) blocking findings. See $productionGateFindingsPath"
}
if ($goal6Findings.Count -gt 0) {
    throw "PSScriptAnalyzer Goal 6 zero-debt gate found $($goal6Findings.Count) default-rule findings. See $goal6FindingsPath"
}
Write-Output ("PSScriptAnalyzer {0} passed: {1} history findings reported, {2} production files gated, and {3} Goal 6 files at zero debt." -f $moduleVersion, $orderedHistoryFindings.Count, $productionFiles.Count, $goal6Files.Count)
