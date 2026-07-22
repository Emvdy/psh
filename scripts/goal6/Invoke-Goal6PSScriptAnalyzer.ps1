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

function ConvertTo-PshGoal6SuppressionDetail {
    param([Parameter(Mandatory = $true)][object]$Suppression)

    return [pscustomobject][ordered]@{
        ruleName = [string](Get-PshGoal6Property -InputObject $Suppression -Name 'RuleName')
        ruleSuppressionId = [string](Get-PshGoal6Property -InputObject $Suppression -Name 'RuleSuppressionID')
        scope = [string](Get-PshGoal6Property -InputObject $Suppression -Name 'Scope')
        target = [string](Get-PshGoal6Property -InputObject $Suppression -Name 'Target')
        justification = [string](Get-PshGoal6Property -InputObject $Suppression -Name 'Justification')
        error = [string](Get-PshGoal6Property -InputObject $Suppression -Name 'Error')
        startAttributeLine = Get-PshGoal6Property -InputObject $Suppression -Name 'StartAttributeLine'
        startOffset = Get-PshGoal6Property -InputObject $Suppression -Name 'StartOffset'
        endOffset = Get-PshGoal6Property -InputObject $Suppression -Name 'EndOffset'
        typeNames = @($Suppression.PSObject.TypeNames | ForEach-Object { [string]$_ })
    }
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$dependencyRootPath = [IO.Path]::GetFullPath($DependencyRoot)
$reportRootPath = [IO.Path]::GetFullPath($ReportRoot)
[void][IO.Directory]::CreateDirectory($reportRootPath)

$historyFindingsPath = Join-Path $reportRootPath 'psscriptanalyzer-history-findings.json'
$historySummaryPath = Join-Path $reportRootPath 'psscriptanalyzer-history-summary.json'
$parseErrorsPath = Join-Path $reportRootPath 'psscriptanalyzer-parse-errors.json'
$productionGateFindingsPath = Join-Path $reportRootPath 'psscriptanalyzer-production-gate-findings.json'
$goal6FindingsPath = Join-Path $reportRootPath 'psscriptanalyzer-goal6-findings.json'
$suppressionsPath = Join-Path $reportRootPath 'psscriptanalyzer-suppressions.json'
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
$suppressionAnnotations = New-Object System.Collections.Generic.List[object]
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
    $analyzerSettings = @{
        IncludeDefaultRules = $true
        RecurseCustomRulePath = $false
    }

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
        $ast = [Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$fileParseErrors)
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

        $fileSuppressionAttributes = @($ast.FindAll({
                    param($node)
                    if ($node -isnot [Management.Automation.Language.AttributeAst]) { return $false }
                    $typeName = [string]$node.TypeName.FullName
                    return $typeName -match '(?i)(^|\.)SuppressMessage(Attribute)?$'
                }, $true))
        foreach ($attribute in $fileSuppressionAttributes) {
            $suppressionAnnotations.Add([pscustomobject][ordered]@{
                    source = 'PowerShellAst'
                    path = $relativePath
                    line = [int]$attribute.Extent.StartLineNumber
                    column = [int]$attribute.Extent.StartColumnNumber
                    endLine = [int]$attribute.Extent.EndLineNumber
                    endColumn = [int]$attribute.Extent.EndColumnNumber
                    attributeType = [string]$attribute.TypeName.FullName
                    text = [string]$attribute.Extent.Text
                })
        }

        $results = @(Invoke-ScriptAnalyzer -Path $fullPath -Recurse:$false -Settings $analyzerSettings -IncludeSuppressed -ErrorAction Stop)
        foreach ($result in $results) {
            $extent = Get-PshGoal6Property -InputObject $result -Name 'Extent'
            $line = Get-PshGoal6Property -InputObject $result -Name 'Line'
            $column = Get-PshGoal6Property -InputObject $result -Name 'Column'
            if ($null -eq $line) { $line = Get-PshGoal6Property -InputObject $extent -Name 'StartLineNumber' }
            if ($null -eq $column) { $column = Get-PshGoal6Property -InputObject $extent -Name 'StartColumnNumber' }
            $endLine = Get-PshGoal6Property -InputObject $extent -Name 'EndLineNumber'
            $endColumn = Get-PshGoal6Property -InputObject $extent -Name 'EndColumnNumber'
            if ($null -eq $line) { $line = 0 }
            if ($null -eq $column) { $column = 0 }
            if ($null -eq $endLine) { $endLine = [int]$line }
            if ($null -eq $endColumn) { $endColumn = [int]$column }

            $isSuppressedProperty = $result.PSObject.Properties['IsSuppressed']
            $suppressionState = 'unknown'
            $isSuppressed = $null
            if ($null -ne $isSuppressedProperty -and $null -ne $isSuppressedProperty.Value) {
                try {
                    $isSuppressed = [bool]$isSuppressedProperty.Value
                    $suppressionState = if ($isSuppressed) { 'suppressed' } else { 'active' }
                }
                catch { $suppressionState = 'unknown' }
            }
            $suppressionDetails = @()
            $suppressionProperty = $result.PSObject.Properties['Suppression']
            if ($null -ne $suppressionProperty -and $null -ne $suppressionProperty.Value) {
                $suppressionDetails = @($suppressionProperty.Value | ForEach-Object { ConvertTo-PshGoal6SuppressionDetail -Suppression $_ })
            }
            $historyFindings.Add([pscustomobject][ordered]@{
                    source = 'PSScriptAnalyzer'
                    path = $relativePath
                    line = [int]$line
                    column = [int]$column
                    endLine = [int]$endLine
                    endColumn = [int]$endColumn
                    severity = [string]$result.Severity
                    ruleName = [string]$result.RuleName
                    message = [string]$result.Message
                    suppressionState = $suppressionState
                    isSuppressed = $isSuppressed
                    ruleSuppressionId = [string](Get-PshGoal6Property -InputObject $result -Name 'RuleSuppressionID')
                    suppressionMetadataComplete = ($suppressionState -cne 'unknown' -and ($suppressionState -cne 'suppressed' -or $suppressionDetails.Count -gt 0))
                    suppressions = $suppressionDetails
                    resultTypeNames = @($result.PSObject.TypeNames | ForEach-Object { [string]$_ })
                })
        }
    }
}
catch {
    $failure = [string]$_.Exception.Message
}

$orderedHistoryFindings = @($historyFindings.ToArray() | Sort-Object path, line, column, ruleName)
$orderedParseErrors = @($parseErrors.ToArray() | Sort-Object path, line, column, errorId)
$orderedSuppressionAnnotations = @($suppressionAnnotations.ToArray() | Sort-Object path, line, column, attributeType)
$productionParseErrors = @($orderedParseErrors | Where-Object {
        $_.path.StartsWith('src/', [StringComparison]::Ordinal) -or $_.path.StartsWith('scripts/', [StringComparison]::Ordinal)
    })
$goal6ParseErrors = @($orderedParseErrors | Where-Object { $_.path.StartsWith('scripts/goal6/', [StringComparison]::Ordinal) })
$productionSuppressionAnnotations = @($orderedSuppressionAnnotations | Where-Object {
        $_.path.StartsWith('src/', [StringComparison]::Ordinal) -or $_.path.StartsWith('scripts/', [StringComparison]::Ordinal)
    })
$goal6SuppressionAnnotations = @($orderedSuppressionAnnotations | Where-Object { $_.path.StartsWith('scripts/goal6/', [StringComparison]::Ordinal) })

$productionBlockingAnalyzerFindings = New-Object System.Collections.Generic.List[object]
foreach ($finding in @($orderedHistoryFindings | Where-Object {
            $_.path.StartsWith('src/', [StringComparison]::Ordinal) -or $_.path.StartsWith('scripts/', [StringComparison]::Ordinal)
        })) {
    $blockingReasons = New-Object System.Collections.Generic.List[string]
    if ([string]$finding.severity -ceq 'Error') { $blockingReasons.Add('severity-error') }
    if ($highRiskRuleNameSet.Contains([string]$finding.ruleName)) { $blockingReasons.Add('high-risk-rule') }
    if ([string]$finding.suppressionState -ceq 'suppressed') { $blockingReasons.Add('suppressed-diagnostic') }
    if ([string]$finding.suppressionState -ceq 'unknown') { $blockingReasons.Add('suppression-state-unknown') }
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
                suppressionState = [string]$finding.suppressionState
                isSuppressed = $finding.isSuppressed
                ruleSuppressionId = [string]$finding.ruleSuppressionId
                suppressionMetadataComplete = [bool]$finding.suppressionMetadataComplete
                suppressions = @($finding.suppressions)
                resultTypeNames = @($finding.resultTypeNames)
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
foreach ($annotation in $productionSuppressionAnnotations) {
    $productionGateFindings.Add([pscustomobject][ordered]@{
            source = [string]$annotation.source
            path = [string]$annotation.path
            line = [int]$annotation.line
            column = [int]$annotation.column
            endLine = [int]$annotation.endLine
            endColumn = [int]$annotation.endColumn
            severity = 'Error'
            ruleName = 'SuppressMessageAttribute'
            message = 'PSScriptAnalyzer suppression attributes are not permitted in production or Goal 6 gate code.'
            attributeType = [string]$annotation.attributeType
            text = [string]$annotation.text
            blockingReasons = @('suppression-attribute')
        })
}
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
$suppressedDiagnostics = @($orderedHistoryFindings | Where-Object { [string]$_.suppressionState -ceq 'suppressed' })
$unknownSuppressionDiagnostics = @($orderedHistoryFindings | Where-Object { [string]$_.suppressionState -ceq 'unknown' })
$suppressionReport = [pscustomobject][ordered]@{
    schemaVersion = 1
    report = 'psscriptanalyzer-suppressions'
    analyzerInvocation = 'Invoke-ScriptAnalyzer -IncludeSuppressed with explicit default-rule settings'
    annotationCount = $orderedSuppressionAnnotations.Count
    suppressedDiagnosticCount = $suppressedDiagnostics.Count
    unknownSuppressionStateCount = $unknownSuppressionDiagnostics.Count
    annotations = $orderedSuppressionAnnotations
    suppressedDiagnostics = $suppressedDiagnostics
    unknownSuppressionStateDiagnostics = $unknownSuppressionDiagnostics
}

$historySummary = [pscustomobject][ordered]@{
    schemaVersion = 1
    report = 'psscriptanalyzer-history'
    status = if ($null -eq $failure) { 'reported' } else { 'incomplete' }
    blocking = $false
    ruleMode = 'all-default-rules-include-suppressed'
    inputMode = 'git-tracked-ps1-psm1-psd1'
    excludedPrefixes = @('src/Psh/Dependencies/')
    scannedFileCount = $scannedFiles.Count
    findingCount = $orderedHistoryFindings.Count
    parseErrorCount = $orderedParseErrors.Count
    suppressionAnnotationCount = $orderedSuppressionAnnotations.Count
    suppressedDiagnosticCount = $suppressedDiagnostics.Count
    unknownSuppressionStateCount = $unknownSuppressionDiagnostics.Count
    bySeverity = $historySeveritySummary
    byRule = $historyRuleSummary
    byFile = $historyFileSummary
    parseErrorsByFile = $parseFileSummary
    findingsReport = 'psscriptanalyzer-history-findings.json'
    parseErrorsReport = 'psscriptanalyzer-parse-errors.json'
    suppressionsReport = 'psscriptanalyzer-suppressions.json'
    error = $failure
}

$policy = [pscustomobject][ordered]@{
    schemaVersion = 1
    gate = 'psscriptanalyzer'
    module = [pscustomobject][ordered]@{
        name = 'PSScriptAnalyzer'
        version = $moduleVersion
        ruleMode = 'all-default-rules-include-suppressed'
        settingsMode = 'explicit hashtable enables all default rules and prevents repository settings discovery'
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
            id = 'production-suppression'
            scope = 'production'
            predicate = 'A SuppressMessage attribute, suppressed diagnostic, or diagnostic with unknown suppression state is present'
        }
        [pscustomobject][ordered]@{
            id = 'goal6-zero-default-findings'
            scope = 'goal6'
            predicate = 'PSScriptAnalyzer default finding or suppression annotation count is greater than zero'
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
        suppressions = 'psscriptanalyzer-suppressions.json'
        summary = 'psscriptanalyzer-summary.json'
    }
}

$goal6BlockingCount = $goal6Findings.Count + $goal6SuppressionAnnotations.Count
$status = if ($null -ne $failure -or $orderedProductionGateFindings.Count -gt 0 -or $goal6BlockingCount -gt 0) { 'failed' } else { 'passed' }
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
        suppressionAnnotationCount = $orderedSuppressionAnnotations.Count
        suppressedDiagnosticCount = $suppressedDiagnostics.Count
        unknownSuppressionStateCount = $unknownSuppressionDiagnostics.Count
        findingsReport = 'psscriptanalyzer-history-findings.json'
        summaryReport = 'psscriptanalyzer-history-summary.json'
    }
    production = [pscustomobject][ordered]@{
        blocking = $true
        scannedFileCount = $productionFiles.Count
        parseErrorCount = $productionParseErrors.Count
        analyzerFindingCount = $productionBlockingAnalyzerFindings.Count
        suppressionAnnotationCount = $productionSuppressionAnnotations.Count
        blockingFindingCount = $orderedProductionGateFindings.Count
        findingsReport = 'psscriptanalyzer-production-gate-findings.json'
    }
    goal6 = [pscustomobject][ordered]@{
        blocking = $true
        scannedFileCount = $goal6Files.Count
        parseErrorCount = $goal6ParseErrors.Count
        defaultFindingCount = $goal6Findings.Count
        suppressionAnnotationCount = $goal6SuppressionAnnotations.Count
        blockingFindingCount = $goal6BlockingCount
        findingsReport = 'psscriptanalyzer-goal6-findings.json'
    }
    error = $failure
}

Write-PshGoal6Json -Path $historyFindingsPath -InputObject $orderedHistoryFindings
Write-PshGoal6Json -Path $historySummaryPath -InputObject $historySummary
Write-PshGoal6Json -Path $parseErrorsPath -InputObject $orderedParseErrors
Write-PshGoal6Json -Path $productionGateFindingsPath -InputObject $orderedProductionGateFindings
Write-PshGoal6Json -Path $goal6FindingsPath -InputObject $goal6Findings
Write-PshGoal6Json -Path $suppressionsPath -InputObject $suppressionReport
Write-PshGoal6Json -Path $policyPath -InputObject $policy
Write-PshGoal6Json -Path $summaryPath -InputObject $summary

if ($null -ne $failure) { throw "PSScriptAnalyzer gate failed: $failure" }
if ($orderedProductionGateFindings.Count -gt 0) {
    throw "PSScriptAnalyzer production gate found $($orderedProductionGateFindings.Count) blocking findings. See $productionGateFindingsPath"
}
if ($goal6BlockingCount -gt 0) {
    throw "PSScriptAnalyzer Goal 6 zero-debt gate found $goal6BlockingCount default-rule finding(s) or suppression annotation(s). See $goal6FindingsPath and $suppressionsPath"
}
Write-Output ("PSScriptAnalyzer {0} passed: {1} history findings reported, {2} production files gated, and {3} Goal 6 files at zero debt." -f $moduleVersion, $orderedHistoryFindings.Count, $productionFiles.Count, $goal6Files.Count)
