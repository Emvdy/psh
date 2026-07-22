# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent ([string]$MyInvocation.MyCommand.Path))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

function Assert-PshCondition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Goal 1 acceptance failed: $Message"
    }
}

function Get-PshGoal1RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, $comparison)) { return $null }
    return $fullPath.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar, '/').Replace([IO.Path]::AltDirectorySeparatorChar, '/')
}

function Assert-PshGoal1ShellPolicyTokenBoundary {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Remediation
    )

    $remediationCount = 0
    $searchOffset = 0
    while ($searchOffset -lt $Text.Length) {
        $matchOffset = $Text.IndexOf($Remediation, $searchOffset, [StringComparison]::Ordinal)
        if ($matchOffset -lt 0) { break }
        $remediationCount++
        $searchOffset = $matchOffset + $Remediation.Length
    }
    Assert-PshCondition ($remediationCount -eq 5) 'The install.sh reviewed execution-policy remediation count changed.'

    $collapsed = [regex]::Replace($Text.Replace($Remediation, ''), '\s', '')
    foreach ($separator in @(
            [string][char]39,
            [string][char]34,
            [string][char]96,
            [string][char]92,
            '+',
            '(',
            ')')) {
        $collapsed = $collapsed.Replace($separator, '')
    }
    Assert-PshCondition ($collapsed.IndexOf('Set-ExecutionPolicy', [StringComparison]::OrdinalIgnoreCase) -lt 0) 'The install.sh text contains a composed execution-policy token outside reviewed remediations.'
}

function Get-PshGoal1LockedParentShellPowerShellScript {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Marker
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $reader = New-Object IO.StringReader($Text)
    try {
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            [void]$lines.Add($line)
        }
    }
    finally {
        $reader.Dispose()
    }

    $launchLine = '    "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command ' + [char]92
    $openLine = "    '"
    $markerLine = '$flowMarker = "' + $Marker + '"'
    $startLine = '$ErrorActionPreference = "Stop"'
    $exitLine = 'exit $exitCode'
    $closeLine = "'" + ' ' + [char]92
    $redirectLine = '    </dev/null'
    $launchIndices = New-Object System.Collections.Generic.List[int]
    $markerIndices = New-Object System.Collections.Generic.List[int]
    $closeIndices = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ([string]$lines[$index] -ceq $launchLine) { [void]$launchIndices.Add($index) }
        if ([string]$lines[$index] -ceq $markerLine) { [void]$markerIndices.Add($index) }
        if ([string]$lines[$index] -ceq $closeLine -and
            $index + 1 -lt $lines.Count -and [string]$lines[$index + 1] -ceq $redirectLine) {
            [void]$closeIndices.Add($index)
        }
    }

    Assert-PshCondition ($launchIndices.Count -eq 1) "Embedded install.sh PowerShell launch is missing or duplicated: $Marker"
    $launchIndex = [int]$launchIndices[0]
    Assert-PshCondition ($launchIndex + 2 -lt $lines.Count -and
        [string]$lines[$launchIndex + 1] -ceq $openLine -and
        [string]$lines[$launchIndex + 2] -ceq $startLine) "Embedded install.sh PowerShell opening boundary is invalid: $Marker"
    Assert-PshCondition ($markerIndices.Count -eq 1) "Embedded install.sh PowerShell marker is missing or duplicated: $Marker"
    $markerIndex = [int]$markerIndices[0]
    Assert-PshCondition ($markerIndex -gt $launchIndex + 2) "Embedded install.sh PowerShell marker is outside the literal payload: $Marker"
    Assert-PshCondition ($closeIndices.Count -eq 1) "Embedded install.sh PowerShell closing boundary is missing or duplicated: $Marker"
    $closeIndex = [int]$closeIndices[0]
    $tailIndex = $closeIndex - 1
    Assert-PshCondition ($tailIndex -gt $markerIndex -and [string]$lines[$tailIndex] -ceq $exitLine) "Embedded install.sh PowerShell tail is invalid: $Marker"

    $singleQuoteLines = New-Object System.Collections.Generic.List[int]
    $exitMentions = New-Object System.Collections.Generic.List[int]
    for ($index = $launchIndex + 2; $index -le $tailIndex; $index++) {
        $lineText = [string]$lines[$index]
        if ($lineText.IndexOf([char]39) -ge 0) {
            [void]$singleQuoteLines.Add($index)
        }
        if ($lineText.IndexOf($exitLine, [StringComparison]::Ordinal) -ge 0) {
            [void]$exitMentions.Add($index)
        }
    }
    Assert-PshCondition ($singleQuoteLines.Count -eq 0) "Embedded install.sh PowerShell payload contains a shell literal quote: $Marker"
    Assert-PshCondition ($exitMentions.Count -eq 1 -and [int]$exitMentions[0] -eq $tailIndex) "Embedded install.sh PowerShell exit marker is duplicated or appears before the literal closing boundary: $Marker"

    $scriptLines = New-Object System.Collections.Generic.List[string]
    for ($index = $launchIndex + 2; $index -le $tailIndex; $index++) {
        [void]$scriptLines.Add([string]$lines[$index])
    }
    return [string]::Join("`n", $scriptLines.ToArray())
}

function Get-PshGoal1InstallShellPowerShellPayloads {
    param(
        [Parameter(Mandatory = $true)][string]$Text
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $reader = New-Object IO.StringReader($Text)
    try {
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            [void]$lines.Add($line)
        }
    }
    finally {
        $reader.Dispose()
    }

    $quote = [string][char]39
    $conversionLine = 'powershell_windows_path="$(to_windows_path "$powershell_path")" || fail_json 3 ' +
        $quote + 'PshShellPath' + $quote + ' ' + $quote + 'Unable to convert the Windows PowerShell path.' + $quote
    $cleanupLaunchLine = '            "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command ' + $quote
    $tempLaunchLine = '    temporary_fields="$("$powershell_path" -NoLogo -NoProfile -NonInteractive -Command ' + $quote
    $metadataLaunchLine = '        "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command ' + [char]92
    $lockedLaunchLine = '    "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command ' + [char]92
    $expectedReferenceLines = [ordered]@{
        conversion = $conversionLine
        cleanup = $cleanupLaunchLine
        temp = $tempLaunchLine
        metadata = $metadataLaunchLine
        locked = $lockedLaunchLine
    }
    $allowedReferenceLines = @($expectedReferenceLines.Values)
    $referenceCount = 0
    $launchHead = '-NoLogo -NoProfile -NonInteractive -Command'
    $launchHeadCount = 0
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $lineText = [string]$lines[$index]
        $lineReferences = [regex]::Matches(
            $lineText,
            '\$(?:powershell_path|\{powershell_path\})',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant
        ).Count
        if ($lineReferences -gt 0) {
            $referenceCount += $lineReferences
            Assert-PshCondition ($lineReferences -eq 1 -and $allowedReferenceLines -ccontains $lineText) 'The install.sh powershell_path reference inventory changed.'
        }
        $searchOffset = 0
        while ($searchOffset -lt $lineText.Length) {
            $launchOffset = $lineText.IndexOf($launchHead, $searchOffset, [StringComparison]::Ordinal)
            if ($launchOffset -lt 0) { break }
            $launchHeadCount++
            $searchOffset = $launchOffset + $launchHead.Length
        }
    }
    Assert-PshCondition ($referenceCount -eq 5) 'The install.sh powershell_path reference inventory must contain exactly five occurrences.'
    Assert-PshCondition ($launchHeadCount -eq 4) 'The install.sh PowerShell launch inventory must contain exactly four command heads.'

    $referenceIndices = @{}
    foreach ($name in @($expectedReferenceLines.Keys)) {
        $matches = New-Object System.Collections.Generic.List[int]
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ([string]$lines[$index] -ceq [string]$expectedReferenceLines[$name]) {
                [void]$matches.Add($index)
            }
        }
        Assert-PshCondition ($matches.Count -eq 1) "The install.sh $name powershell_path reference is missing or duplicated."
        $referenceIndices[$name] = [int]$matches[0]
    }

    $cleanupIndex = [int]$referenceIndices['cleanup']
    $cleanupMarkerLine = '$flowMarker = "PshShellCleanupRoot"'
    $cleanupCloseLine = $quote + ' </dev/null || cleanup_failed=1'
    $cleanupCloseIndices = New-Object System.Collections.Generic.List[int]
    $cleanupMarkerIndices = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ([string]$lines[$index] -ceq $cleanupCloseLine) { [void]$cleanupCloseIndices.Add($index) }
        if ([string]$lines[$index] -ceq $cleanupMarkerLine) { [void]$cleanupMarkerIndices.Add($index) }
    }
    Assert-PshCondition ($cleanupIndex + 2 -lt $lines.Count -and
        [string]$lines[$cleanupIndex + 1] -ceq '$ErrorActionPreference = "Stop"' -and
        [string]$lines[$cleanupIndex + 2] -ceq $cleanupMarkerLine -and
        $cleanupMarkerIndices.Count -eq 1) 'The install.sh cleanup PowerShell opening boundary is invalid.'
    Assert-PshCondition ($cleanupCloseIndices.Count -eq 1 -and
        [int]$cleanupCloseIndices[0] -gt $cleanupIndex + 2 -and
        [string]$lines[[int]$cleanupCloseIndices[0] - 1] -ceq 'catch { exit 1 }') 'The install.sh cleanup PowerShell closing boundary is invalid.'
    $cleanupLines = New-Object System.Collections.Generic.List[string]
    for ($index = $cleanupIndex + 1; $index -lt [int]$cleanupCloseIndices[0]; $index++) {
        $lineText = [string]$lines[$index]
        Assert-PshCondition ($lineText.IndexOf([char]39) -lt 0) 'The install.sh cleanup PowerShell payload contains a shell literal quote.'
        [void]$cleanupLines.Add($lineText)
    }

    $tempIndex = [int]$referenceIndices['temp']
    $tempMarkerLine = '$flowMarker = "PshShellTempRoot"'
    $tempCloseLine = $quote + ')"'
    $tempCloseIndices = New-Object System.Collections.Generic.List[int]
    $tempMarkerIndices = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ([string]$lines[$index] -ceq $tempCloseLine) { [void]$tempCloseIndices.Add($index) }
        if ([string]$lines[$index] -ceq $tempMarkerLine) { [void]$tempMarkerIndices.Add($index) }
    }
    Assert-PshCondition ($tempIndex + 2 -lt $lines.Count -and
        [string]$lines[$tempIndex + 1] -ceq '$ErrorActionPreference = "Stop"' -and
        [string]$lines[$tempIndex + 2] -ceq $tempMarkerLine -and
        $tempMarkerIndices.Count -eq 1) 'The install.sh TEMP PowerShell opening boundary is invalid.'
    Assert-PshCondition ($tempCloseIndices.Count -eq 1 -and
        [int]$tempCloseIndices[0] -gt $tempIndex + 2 -and
        [string]$lines[[int]$tempCloseIndices[0] - 2] -ceq '    throw' -and
        [string]$lines[[int]$tempCloseIndices[0] - 1] -ceq '}') 'The install.sh TEMP PowerShell closing boundary is invalid.'
    $tempLines = New-Object System.Collections.Generic.List[string]
    for ($index = $tempIndex + 1; $index -lt [int]$tempCloseIndices[0]; $index++) {
        $lineText = [string]$lines[$index]
        Assert-PshCondition ($lineText.IndexOf([char]39) -lt 0) 'The install.sh TEMP PowerShell payload contains a shell literal quote.'
        [void]$tempLines.Add($lineText)
    }

    $metadataIndex = [int]$referenceIndices['metadata']
    $metadataEnvironmentLine = '    metadata_fields="$(PSH_SHELL_RELEASE_METADATA_PATH="$release_metadata_windows_path" PSH_SHELL_REQUESTED_TAG="$requested_tag" ' + [char]92
    Assert-PshCondition ($metadataIndex -gt 0 -and [string]$lines[$metadataIndex - 1] -ceq $metadataEnvironmentLine -and
        $metadataIndex + 1 -lt $lines.Count) 'The install.sh metadata PowerShell launch boundary is invalid.'
    $metadataLine = [string]$lines[$metadataIndex + 1]
    $metadataPrefix = '        ' + $quote
    $metadataSuffix = $quote + ')"'
    $metadataQuoteCount = 0
    foreach ($character in $metadataLine.ToCharArray()) {
        if ($character -eq [char]39) { $metadataQuoteCount++ }
    }
    Assert-PshCondition ($metadataQuoteCount -eq 2 -and
        $metadataLine.StartsWith($metadataPrefix, [StringComparison]::Ordinal) -and
        $metadataLine.EndsWith($metadataSuffix, [StringComparison]::Ordinal) -and
        $metadataLine.Length -gt $metadataPrefix.Length + $metadataSuffix.Length) 'The install.sh metadata PowerShell shell wrapper is invalid.'
    $metadataScript = $metadataLine.Substring(
        $metadataPrefix.Length,
        $metadataLine.Length - $metadataPrefix.Length - $metadataSuffix.Length
    )
    Assert-PshCondition ($metadataScript.StartsWith('$ErrorActionPreference="Stop";', [StringComparison]::Ordinal) -and
        $metadataScript.IndexOf([char]39) -lt 0) 'The install.sh metadata PowerShell payload is invalid.'

    $lockedScript = Get-PshGoal1LockedParentShellPowerShellScript -Text $Text -Marker 'PshShellLockedParent'
    return @(
        [pscustomobject][ordered]@{ Label = 'cleanup'; Text = [string]::Join("`n", $cleanupLines.ToArray()) },
        [pscustomobject][ordered]@{ Label = 'temp'; Text = [string]::Join("`n", $tempLines.ToArray()) },
        [pscustomobject][ordered]@{ Label = 'metadata'; Text = $metadataScript },
        [pscustomobject][ordered]@{ Label = 'locked-parent'; Text = $lockedScript }
    )
}

function Test-PshGoal1AllowedPolicyRemediationMatch {
    param(
        [Parameter(Mandatory = $true)][object]$Match,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Remediation
    )

    $relative = Get-PshGoal1RelativePath -Root $Root -Path ([string]$Match.Path)
    $line = ([string]$Match.Line).Trim()
    $singleQuotedRemediation = "'$Remediation'"
    switch -CaseSensitive ($relative) {
        'src/bootstrapper/Program.cs' {
            return $line -ceq ('private const string PolicyRemediation = "' + $Remediation + '";')
        }
        'src/install/install.ps1' {
            return $line -ceq ('$script:PshOnlinePolicyRemediation = ' + $singleQuotedRemediation)
        }
        'src/install/install-offline.ps1' {
            return $line -ceq ('$script:PshOfflinePolicyRemediation = ' + $singleQuotedRemediation)
        }
        'src/install/install.sh' {
            if ($line -ceq ('policy_remediation=' + $singleQuotedRemediation)) { return $true }
            $allowedParentRemediationLines = @(
                ('catch { Throw-PshShellParentFailure 4 "PshExecutionPolicyProbe" "Dependency" "Unable to determine the effective PowerShell execution policy." "' + $Remediation + '" }'),
                ('catch { Throw-PshShellParentFailure 4 "PshExecutionPolicyProbe" "Dependency" ([string]$_.Exception.Message) "' + $Remediation + '" }'),
                ('catch { Throw-PshShellParentFailure 4 "PshExecutionPolicyProbe" "Dependency" "Unable to inspect the installer Authenticode status required by execution policy." "' + $Remediation + '" }'),
                ('Throw-PshShellParentFailure 4 "PshExecutionPolicy" "Dependency" "PowerShell execution policy does not allow this installer workflow." "' + $Remediation + '"')
            )
            return $allowedParentRemediationLines -ccontains $line
        }
    }
    return $false
}

function Get-PshGoal1PowerShellMutationFindingsFromAst {
    param(
        [Parameter(Mandatory = $true)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $findings = New-Object System.Collections.Generic.List[string]
    foreach ($command in @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
        $name = [string]$command.GetCommandName()
        $leafName = $name
        if (-not [string]::IsNullOrEmpty($name) -and $name.LastIndexOf('\') -ge 0) {
            $leafName = $name.Substring($name.LastIndexOf('\') + 1)
        }
        if ($leafName -iin @('Set-ExecutionPolicy', 'Set-GPRegistryValue', 'Remove-GPRegistryValue', 'Set-GPLink', 'New-GPLink', 'Remove-GPLink')) {
            $findings.Add(('{0}:{1}:{2}' -f $Label, $command.Extent.StartLineNumber, $leafName))
        }
        if ($leafName -iin @('Set-Item', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty') -and
            [string]$command.Extent.Text -match '(?i)(?:\\Policies\\|(?:Env:|Environment).*\bPath\b)') {
            $findings.Add(('{0}:{1}:registry-or-path-mutation' -f $Label, $command.Extent.StartLineNumber))
        }
        if ($command.CommandElements.Count -gt 0) {
            $collapsedHead = [regex]::Replace([string]$command.CommandElements[0].Extent.Text, '[\s''"`+()]', '')
            if ($collapsedHead -ieq 'Set-ExecutionPolicy') {
                $findings.Add(('{0}:{1}:composed-Set-ExecutionPolicy' -f $Label, $command.Extent.StartLineNumber))
            }
        }
    }
    foreach ($binary in @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.BinaryExpressionAst] }, $true))) {
        $collapsedExpression = [regex]::Replace([string]$binary.Extent.Text, '[\s''"`+()]', '')
        if ($collapsedExpression -ieq 'Set-ExecutionPolicy') {
            $findings.Add(('{0}:{1}:composed-Set-ExecutionPolicy' -f $Label, $binary.Extent.StartLineNumber))
        }
    }
    foreach ($assignment in @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true))) {
        if ([string]$assignment.Left.Extent.Text -match '(?i)\A\s*\$env:path\s*\z') {
            $findings.Add(('{0}:{1}:environment-PATH-mutation' -f $Label, $assignment.Extent.StartLineNumber))
        }
    }
    foreach ($memberCall in @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) {
        $memberName = if ($memberCall.Member -is [Management.Automation.Language.StringConstantExpressionAst]) { [string]$memberCall.Member.Value } else { [string]$memberCall.Member.Extent.Text }
        $memberText = [string]$memberCall.Extent.Text
        if ($memberName -ieq 'SetEnvironmentVariable' -and
            $memberText -match '(?i)SetEnvironmentVariable\s*\(\s*[''"]Path[''"]' -and
            $memberText -match '(?i)[''"](?:User|Machine)[''"]\s*\)') {
            $findings.Add(('{0}:{1}:persistent-PATH-mutation' -f $Label, $memberCall.Extent.StartLineNumber))
        }
        if ($memberName -ieq 'SetValue' -and $memberText -match '(?i)(?:\\Policies\\|\\Environment\\.*\bPath\b)') {
            $findings.Add(('{0}:{1}:registry-policy-or-PATH-mutation' -f $Label, $memberCall.Extent.StartLineNumber))
        }
    }
    return $findings.ToArray()
}

function Convert-PshOutputFromJson {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Output
    )

    $text = ($Output -join [Environment]::NewLine)
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace($text)) 'JSON output was empty.'
    return ($text | ConvertFrom-Json)
}

$expectedCommands = @(
    'pwd', 'cd', 'ls', 'mkdir', 'rmdir', 'cp', 'mv', 'rm', 'touch', 'ln',
    'realpath', 'basename', 'dirname', 'stat', 'file', 'tree', 'find', 'fd',
    'du', 'df', 'mktemp', 'cat', 'bat', 'head', 'tail', 'grep', 'rg', 'sed',
    'awk', 'jq', 'cut', 'tr', 'sort', 'uniq', 'wc', 'tee', 'xargs', 'printf',
    'echo', 'base64', 'which', 'env', 'printenv', 'export', 'test', 'ps',
    'kill', 'pgrep', 'pkill', 'timeout', 'sleep', 'curl', 'wget', 'tar', 'zip',
    'unzip', 'gzip', 'gunzip', 'sha256sum', 'md5sum', 'date', 'whoami',
    'hostname', 'clear'
)
$expectedManagementCommands = @(
    'version', 'doctor', 'capabilities', 'commands', 'config', 'update',
    'rollback', 'self-test', 'uninstall'
)
$nativeFullCommands = @('bat', 'fd', 'jq', 'rg')
$expectedTierPartitions = @{
    1 = @('pwd cd ls mkdir rmdir cp mv rm touch ln realpath basename dirname mktemp cat head tail cut tr sort uniq wc tee printf echo base64 which env printenv test sleep sha256sum md5sum'.Split(' '))
    2 = @('stat file tree find fd du df bat grep rg sed awk jq xargs export ps kill pgrep pkill timeout curl wget tar zip unzip gzip gunzip'.Split(' '))
    3 = @('date whoami hostname clear'.Split(' '))
}
$expectedPlatformShapedCommands = @(
    'ls', 'stat', 'file', 'tree', 'du', 'df', 'which', 'ps', 'pgrep', 'pkill',
    'date', 'whoami', 'hostname', 'clear'
)

$specificationPath = Join-Path $RepositoryRoot 'src/Psh/Specification/commands.psd1'
$manifestPath = Join-Path $RepositoryRoot 'src/Psh/Psh.psd1'
$generatorPath = Join-Path $RepositoryRoot 'scripts/Generate-CommandArtifacts.ps1'

Assert-PshCondition (Test-Path -LiteralPath $specificationPath -PathType Leaf) 'The command specification is missing.'
Assert-PshCondition (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'The module manifest is missing.'
Assert-PshCondition (Test-Path -LiteralPath $generatorPath -PathType Leaf) 'The artifact generator is missing.'

$specification = Import-PowerShellDataFile -LiteralPath $specificationPath
Assert-PshCondition ([string]$specification.SchemaVersion -eq '1.1') 'Unexpected specification schema version.'
Assert-PshCondition ($specification.PshVersion -eq '0.1.0') 'Unexpected Psh version in the specification.'
Assert-PshCondition ((@($specification.CommandTiers.Tier) -join ',') -eq '1,2,3') 'The specification does not define command tiers 1 through 3.'
Assert-PshCondition ([string]$specification.CommandTiers[1].Description -match 'Core implements the documented subset') 'Tier 2 does not document the Core subset boundary.'
Assert-PshCondition ([string]$specification.CommandTiers[1].Description -match 'Full native rg, fd, jq, and bat accept') 'Tier 2 does not document the Full native complete-argument exception.'
Assert-PshCondition ([string]$specification.CommandTiers[1].Validation -match 'exit code 2') 'Tier 2 does not document usage exit code 2 for unsupported PowerShell-subset syntax.'
Assert-PshCondition ((@($specification.NameCollisionPolicy.ResolutionOrder) -join '|') -eq 'Psh function|built-in alias|native executable') 'The name-collision resolution order drifted from PLAN.md.'
Assert-PshCondition ([string]$specification.NameCollisionPolicy.DisableConfigKey -eq 'DisabledCommands') 'The name-collision disable key is not DisabledCommands.'

$actualNames = @($specification.Commands | ForEach-Object { $_.Name })
Assert-PshCondition ($actualNames.Count -eq 64) 'The specification must contain exactly 64 commands.'
Assert-PshCondition (@($actualNames | Group-Object | Where-Object { $_.Count -ne 1 }).Count -eq 0) 'Command names must be unique.'
Assert-PshCondition (@(Compare-Object ($expectedCommands | Sort-Object) ($actualNames | Sort-Object)).Count -eq 0) 'The 64 command names do not match PLAN.md.'

foreach ($tierNumber in @(1, 2, 3)) {
    $actualTierCommands = @($specification.Commands | Where-Object { [int]$_.Tier -eq $tierNumber } | ForEach-Object { [string]$_.Name })
    Assert-PshCondition (($actualTierCommands -join '|') -eq ($expectedTierPartitions[$tierNumber] -join '|')) "Tier $tierNumber does not exactly match PLAN.md."
}
$actualPlatformShapedCommands = @($specification.Commands | Where-Object { [bool]$_.PlatformShaped } | ForEach-Object { [string]$_.Name })
Assert-PshCondition (($actualPlatformShapedCommands -join '|') -eq ($expectedPlatformShapedCommands -join '|')) 'Platform-shaped command metadata drifted.'

$actualManagement = @($specification.ManagementCommands | ForEach-Object { $_.Name })
Assert-PshCondition (@(Compare-Object ($expectedManagementCommands | Sort-Object) ($actualManagement | Sort-Object)).Count -eq 0) 'Management commands do not match PLAN.md.'
Assert-PshCondition (((@($specification.ExitCodes | ForEach-Object { [int]$_.Code }) | Sort-Object) -join ',') -eq '0,1,2,3,4,5') 'The exit-code contract must define 0 through 5.'

foreach ($command in $specification.Commands) {
    Assert-PshCondition ([int]$command.Tier -in @(1, 2, 3)) "$($command.Name) has invalid tier metadata."
    Assert-PshCondition ($command.PlatformShaped -is [bool]) "$($command.Name) has non-Boolean PlatformShaped metadata."
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.EditionNotes)) "$($command.Name) has no Core/Full compatibility notes."
    Assert-PshCondition ($null -ne $command.CollisionTargets) "$($command.Name) has no collision target data."
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.CollisionNotes)) "$($command.Name) has no collision notes."
    foreach ($collisionTarget in @($command.CollisionTargets)) {
        Assert-PshCondition ([string]$collisionTarget -match '^(alias|native):[^:]+$') "$($command.Name) uses an unsupported collision category: $collisionTarget"
    }
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.Summary)) "$($command.Name) has no help summary."
    Assert-PshCondition ($null -ne $command.Flags) "$($command.Name) has no completion flag data."
    Assert-PshCondition (@($command.ExitCodes).Count -gt 0) "$($command.Name) has no exit-code data."
    Assert-PshCondition (@($command.Examples).Count -gt 0) "$($command.Name) has no examples."
    Assert-PshCondition ($command.CoreBackend -eq 'powershell') "$($command.Name) Core backend is not PowerShell."

    if ([int]$command.Tier -eq 2) {
        Assert-PshCondition (@($command.ExitCodes) -contains 2) "$($command.Name) Tier 2 contract does not expose usage exit code 2."
        Assert-PshCondition ([string]$command.EditionNotes -match 'unsupported syntax exits 2') "$($command.Name) Tier 2 notes do not document unsupported syntax exit code 2."
    }

    if ($nativeFullCommands -contains $command.Name) {
        Assert-PshCondition ($command.FullBackend -eq ("native:{0}" -f $command.Name)) "$($command.Name) Full backend is not its pinned native tool."
    }
    else {
        Assert-PshCondition ($command.FullBackend -eq 'powershell') "$($command.Name) unexpectedly uses a native Full backend."
    }
}

& $generatorPath -Check

$specificationText = [IO.File]::ReadAllText($specificationPath)
$generatorValidationRoot = Join-Path ([IO.Path]::GetTempPath()) ("psh-goal1-generator-{0}" -f [Guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($generatorValidationRoot) | Out-Null
    $generatorMutationCases = @(
        @{
            Name = 'tier-partition'
            Find = "            Name = 'pwd'`n            Tier = 1"
            Replace = "            Name = 'pwd'`n            Tier = 2"
            ExpectedError = 'Tier 1 command partition does not exactly match PLAN.md.'
        }
        @{
            Name = 'collision-order'
            Find = "ResolutionOrder = @('Psh function', 'built-in alias', 'native executable')"
            Replace = "ResolutionOrder = @('built-in alias', 'Psh function', 'native executable')"
            ExpectedError = 'NameCollisionPolicy resolution order must be Psh function, built-in alias, then native executable.'
        }
        @{
            Name = 'required-command-metadata'
            Find = "            CollisionNotes = 'Shadows the built-in pwd alias; disabling this Psh command restores alias resolution.'"
            Replace = "            CollisionDetail = 'Shadows the built-in pwd alias; disabling this Psh command restores alias resolution.'"
            ExpectedError = "command 'pwd' is missing 'CollisionNotes'."
        }
    )

    foreach ($mutationCase in $generatorMutationCases) {
        Assert-PshCondition ($specificationText.Contains([string]$mutationCase.Find)) "Generator validation fixture '$($mutationCase.Name)' did not match the canonical specification."
        $mutatedSpecification = $specificationText.Replace([string]$mutationCase.Find, [string]$mutationCase.Replace)
        $mutatedSpecificationPath = Join-Path $generatorValidationRoot ("{0}.psd1" -f $mutationCase.Name)
        [IO.File]::WriteAllText($mutatedSpecificationPath, $mutatedSpecification, (New-Object System.Text.UTF8Encoding($false)))

        $validationError = $null
        try {
            & $generatorPath -Check -SpecificationPath $mutatedSpecificationPath | Out-Null
        }
        catch {
            $validationError = $_.Exception.Message
        }
        Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$validationError)) "Generator accepted invalid '$($mutationCase.Name)' metadata."
        Assert-PshCondition ([string]$validationError -like ("*{0}*" -f $mutationCase.ExpectedError)) "Generator rejected '$($mutationCase.Name)' for the wrong reason: $validationError"
    }
}
finally {
    if (Test-Path -LiteralPath $generatorValidationRoot) {
        Remove-Item -LiteralPath $generatorValidationRoot -Recurse -Force
    }
}

$generatedFiles = @(
    (Join-Path $RepositoryRoot 'generated/commands.json'),
    (Join-Path $RepositoryRoot 'docs/compatibility.md'),
    (Join-Path $RepositoryRoot 'docs/install-layout.md'),
    (Join-Path $RepositoryRoot 'src/Psh/Generated/ArgumentCompleters.ps1')
)
foreach ($generatedFile in $generatedFiles) {
    Assert-PshCondition (Test-Path -LiteralPath $generatedFile -PathType Leaf) "Missing generated artifact: $generatedFile"
    $bytes = [IO.File]::ReadAllBytes($generatedFile)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Assert-PshCondition (-not $hasBom) "Generated artifact has a UTF-8 BOM: $generatedFile"
}

$generatedSpecification = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'generated/commands.json') -Raw | ConvertFrom-Json
Assert-PshCondition ([string]$generatedSpecification.SchemaVersion -eq '1.1') 'Generated commands.json has the wrong schema version.'
Assert-PshCondition ((@($generatedSpecification.NameCollisionPolicy.ResolutionOrder) -join '|') -eq 'Psh function|built-in alias|native executable') 'Generated commands.json has the wrong collision resolution order.'
Assert-PshCondition ([string]$generatedSpecification.NameCollisionPolicy.DisableConfigKey -eq 'DisabledCommands') 'Generated commands.json has the wrong disable config key.'
Assert-PshCondition (@($generatedSpecification.CommandTiers).Count -eq @($specification.CommandTiers).Count) 'Generated commands.json has the wrong command-tier count.'
for ($tierIndex = 0; $tierIndex -lt @($specification.CommandTiers).Count; $tierIndex++) {
    $sourceTier = @($specification.CommandTiers)[$tierIndex]
    $generatedTier = @($generatedSpecification.CommandTiers)[$tierIndex]
    foreach ($tierProperty in @('Tier', 'Name', 'Description', 'Validation')) {
        Assert-PshCondition ([string]$generatedTier.$tierProperty -ceq [string]$sourceTier[$tierProperty]) "Generated command tier $($tierIndex + 1) '$tierProperty' drifted from the source specification."
    }
}
Assert-PshCondition (@($generatedSpecification.Commands).Count -eq 64) 'Generated commands.json does not contain 64 commands.'
Assert-PshCondition (@(Compare-Object ($expectedCommands | Sort-Object) (@($generatedSpecification.Commands.Name) | Sort-Object)).Count -eq 0) 'Generated commands.json command names drifted from PLAN.md.'
Assert-PshCondition ((@($generatedSpecification.Commands.Name) -join '|') -eq ($actualNames -join '|')) 'Generated commands.json command order drifted from the source specification.'
Assert-PshCondition (@($generatedSpecification.Commands | Where-Object { [int]$_.Tier -eq 1 }).Count -eq 33) 'Generated commands.json has the wrong Tier 1 count.'
Assert-PshCondition (@($generatedSpecification.Commands | Where-Object { [int]$_.Tier -eq 2 }).Count -eq 27) 'Generated commands.json has the wrong Tier 2 count.'
Assert-PshCondition (@($generatedSpecification.Commands | Where-Object { [int]$_.Tier -eq 3 }).Count -eq 4) 'Generated commands.json has the wrong Tier 3 count.'
Assert-PshCondition (@($generatedSpecification.Commands | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.CollisionNotes) }).Count -eq 0) 'Generated commands.json omitted per-command collision notes.'

$sourceCommandByName = @{}
foreach ($sourceCommand in @($specification.Commands)) {
    $sourceCommandByName[[string]$sourceCommand.Name] = $sourceCommand
}
foreach ($generatedCommand in @($generatedSpecification.Commands)) {
    $sourceCommand = $sourceCommandByName[[string]$generatedCommand.Name]
    Assert-PshCondition ($null -ne $sourceCommand) "Generated commands.json contains unknown command '$($generatedCommand.Name)'."
    foreach ($metadataProperty in @('Tier', 'PlatformShaped', 'EditionNotes', 'CollisionTargets', 'CollisionNotes')) {
        Assert-PshCondition ($null -ne $generatedCommand.PSObject.Properties[$metadataProperty]) "$($generatedCommand.Name) generated metadata is missing '$metadataProperty'."
    }
    Assert-PshCondition ([int]$generatedCommand.Tier -eq [int]$sourceCommand.Tier) "$($generatedCommand.Name) generated Tier drifted from the source specification."
    Assert-PshCondition ([bool]$generatedCommand.PlatformShaped -eq [bool]$sourceCommand.PlatformShaped) "$($generatedCommand.Name) generated PlatformShaped drifted from the source specification."
    Assert-PshCondition ([string]$generatedCommand.EditionNotes -ceq [string]$sourceCommand.EditionNotes) "$($generatedCommand.Name) generated EditionNotes drifted from the source specification."
    Assert-PshCondition ((@($generatedCommand.CollisionTargets) -join '|') -ceq (@($sourceCommand.CollisionTargets) -join '|')) "$($generatedCommand.Name) generated CollisionTargets drifted from the source specification."
    Assert-PshCondition ([string]$generatedCommand.CollisionNotes -ceq [string]$sourceCommand.CollisionNotes) "$($generatedCommand.Name) generated CollisionNotes drifted from the source specification."
}

$compatibilityText = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'docs/compatibility.md'))
foreach ($requiredDocumentation in @(
    'Tier 2 uses documented PowerShell subsets in Core',
    'unsupported syntax in those subsets is rejected with exit code `2`',
    'Full native `rg`, `fd`, `jq`, and `bat` instead accept their pinned tools'' complete argument sets',
    'Psh function` > `built-in alias` > `native executable',
    'psh config set DisabledCommands curl wget',
    'Full delegates `rg`, `fd`, `jq`, and `bat`'
)) {
    Assert-PshCondition ($compatibilityText.Contains($requiredDocumentation)) "Compatibility documentation is missing: $requiredDocumentation"
}

$defaultConfig = Import-PowerShellDataFile -LiteralPath (Join-Path $RepositoryRoot 'src/install/config.psd1')
Assert-PshCondition ($defaultConfig.Contains('DisabledCommands')) 'Default config.psd1 is missing DisabledCommands.'
Assert-PshCondition (@($defaultConfig.DisabledCommands).Count -eq 0) 'Default config.psd1 must enable all commands with an empty DisabledCommands array.'

$installLayoutText = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'docs/install-layout.md'))
Assert-PshCondition ($installLayoutText.Contains('DisabledCommands = @()')) 'Generated install layout omits the required DisabledCommands default.'
Assert-PshCondition ($installLayoutText.Contains('Changes are persisted only and take effect in a new shell or after `Remove-Module Psh; Import-Module Psh`.')) 'Generated install layout omits config activation semantics.'

$sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'src') -Recurse -File)
$allowedManagedDependencyRoot = [IO.Path]::GetFullPath(
    (Join-Path $RepositoryRoot 'src/Psh/Dependencies/PSReadLine/2.4.5')
).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$allowedManagedDependencyPrefix = $allowedManagedDependencyRoot + [IO.Path]::DirectorySeparatorChar
$pathComparison = [StringComparison]::Ordinal
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $pathComparison = [StringComparison]::OrdinalIgnoreCase
}
$unexpectedBinaries = @(
    $sourceFiles |
        Where-Object {
            if ($_.Extension -in @('.exe', '.com', '.msi')) {
                return $true
            }
            if ($_.Extension -ne '.dll') {
                return $false
            }
            return -not $_.FullName.StartsWith($allowedManagedDependencyPrefix, $pathComparison)
        }
)
Assert-PshCondition ($unexpectedBinaries.Count -eq 0) 'Core source contains an executable binary outside the fixed managed dependency directory.'

$unsafePatterns = @(
    'Invoke-WebRequest',
    'Start-BitsTransfer',
    'Download(File|String|Data)',
    '#requires\s+-RunAsAdministrator',
    'Start-Process[^\r\n]+-Verb\s+RunAs'
)
foreach ($pattern in $unsafePatterns) {
    $matches = @(
        $sourceFiles | ForEach-Object {
            Select-String -LiteralPath $_.FullName -Pattern $pattern
        }
    )
    Assert-PshCondition ($matches.Count -eq 0) "Goal 1 source contains a forbidden startup, elevation, or policy pattern: $pattern"
}

# Goal 5 entrypoints may print this exact read-only remediation. Every literal
# occurrence is pinned to a reviewed assignment or locked-parent failure site;
# executable PowerShell, including the install.sh parent payload, is checked by AST.
$policyRemediation = 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
$policyLiteralMatches = @(
    $sourceFiles | ForEach-Object {
        Select-String -LiteralPath $_.FullName -SimpleMatch 'Set-ExecutionPolicy'
    }
)
$unexpectedPolicyLiteralMatches = @(
    $policyLiteralMatches | Where-Object {
        -not (Test-PshGoal1AllowedPolicyRemediationMatch -Match $_ -Root $RepositoryRoot -Remediation $policyRemediation)
    }
)
Assert-PshCondition ($policyLiteralMatches.Count -eq 8 -and $unexpectedPolicyLiteralMatches.Count -eq 0) 'Goal 1 source contains an execution-policy mutation or an unapproved policy diagnostic.'

$policyCommandFindings = New-Object System.Collections.Generic.List[string]
foreach ($powerShellSource in @($sourceFiles | Where-Object { $_.Extension -in @('.ps1', '.psm1') })) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($powerShellSource.FullName, [ref]$tokens, [ref]$parseErrors)
    Assert-PshCondition (@($parseErrors).Count -eq 0) "PowerShell source could not be parsed for policy-command validation: $($powerShellSource.FullName)"
    foreach ($finding in @(Get-PshGoal1PowerShellMutationFindingsFromAst -Ast $ast -Label $powerShellSource.FullName)) { $policyCommandFindings.Add($finding) }
}

$shellPolicyMatches = @($policyLiteralMatches | Where-Object {
        (Get-PshGoal1RelativePath -Root $RepositoryRoot -Path ([string]$_.Path)) -ceq 'src/install/install.sh' -and
        ([string]$_.Line).Trim() -cne ('policy_remediation=' + "'$policyRemediation'")
    })
Assert-PshCondition ($shellPolicyMatches.Count -eq 4) 'The install.sh locked-parent policy remediation sites were not exactly identified.'
$shellPath = Join-Path $RepositoryRoot 'src/install/install.sh'
$shellText = [IO.File]::ReadAllText($shellPath)
Assert-PshGoal1ShellPolicyTokenBoundary -Text $shellText -Remediation $policyRemediation
$shellPowerShellPayloads = @(Get-PshGoal1InstallShellPowerShellPayloads -Text $shellText)
$expectedShellPayloadLabels = @('cleanup', 'temp', 'metadata', 'locked-parent')
Assert-PshCondition ($shellPowerShellPayloads.Count -eq 4 -and
    (@($shellPowerShellPayloads | ForEach-Object { [string]$_.Label }) -join '|') -ceq ($expectedShellPayloadLabels -join '|')) 'The install.sh PowerShell payload inventory changed.'
$earlyEndFixtureLines = @(
    ('    "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command ' + [char]92),
    "    '",
    '$ErrorActionPreference = "Stop"',
    '$flowMarker = "PshShellLockedParent"',
    '# exit $exitCode',
    '& ("Set-" + "ExecutionPolicy") -Scope CurrentUser RemoteSigned',
    'exit $exitCode',
    ("'" + ' ' + [char]92),
    '    </dev/null'
)
$earlyEndFixture = [string]::Join("`n", $earlyEndFixtureLines)
$earlyEndFailure = $null
try {
    [void](Get-PshGoal1LockedParentShellPowerShellScript -Text $earlyEndFixture -Marker 'PshShellLockedParent')
}
catch {
    $earlyEndFailure = $_
}
Assert-PshCondition ($null -ne $earlyEndFailure -and
    [string]$earlyEndFailure.Exception.Message -like '*exit marker is duplicated or appears before the literal closing boundary*') 'An early commented exit marker allowed a later composed policy mutation to escape install.sh payload extraction.'
$shellEscapeFixtureLines = @(
    ('    "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command ' + [char]92),
    "    '",
    '$ErrorActionPreference = "Stop"',
    '$flowMarker = "PshShellLockedParent"',
    "'",
    '"$powershell_path" -NoLogo -NoProfile -NonInteractive -Command "& (\"Set-\" + \"ExecutionPolicy\") -Scope CurrentUser RemoteSigned"',
    "'",
    'exit $exitCode',
    ("'" + ' ' + [char]92),
    '    </dev/null'
)
$shellEscapeFixture = [string]::Join("`n", $shellEscapeFixtureLines)
$shellEscapeFailure = $null
try {
    [void](Get-PshGoal1LockedParentShellPowerShellScript -Text $shellEscapeFixture -Marker 'PshShellLockedParent')
}
catch {
    $shellEscapeFailure = $_
}
Assert-PshCondition ($null -ne $shellEscapeFailure -and
    [string]$shellEscapeFailure.Exception.Message -like '*payload contains a shell literal quote*') 'A shell literal close-command-reopen sequence escaped install.sh payload extraction.'
$findPowerShellLaunchFixture = $shellText + "`n" +
    '"$(find_powershell)" -NoProfile -NonInteractive -Command "& (\"Set-\" + \"ExecutionPolicy\") -Scope CurrentUser RemoteSigned"' + "`n"
$findPowerShellTokenFailure = $null
try {
    Assert-PshGoal1ShellPolicyTokenBoundary -Text $findPowerShellLaunchFixture -Remediation $policyRemediation
}
catch {
    $findPowerShellTokenFailure = $_
}
Assert-PshCondition ($null -ne $findPowerShellTokenFailure -and
    [string]$findPowerShellTokenFailure.Exception.Message -like '*composed execution-policy token outside reviewed remediations*') 'A find_powershell external composed policy launch escaped the install.sh token boundary.'
$parameterFallbackFixture = $shellText + "`n" +
    '"${powershell_path:-$(find_powershell)}" -NoProfile -NonInteractive -Command "& (\"Set-\" + \"ExecutionPolicy\") -Scope CurrentUser RemoteSigned"' + "`n"
$parameterFallbackFailure = $null
try {
    Assert-PshGoal1ShellPolicyTokenBoundary -Text $parameterFallbackFixture -Remediation $policyRemediation
}
catch {
    $parameterFallbackFailure = $_
}
Assert-PshCondition ($null -ne $parameterFallbackFailure -and
    [string]$parameterFallbackFailure.Exception.Message -like '*composed execution-policy token outside reviewed remediations*') 'A parameter-fallback external composed policy launch escaped the install.sh token boundary.'
$externalLaunchFixture = $shellText + "`n" +
    '"${powershell_path}" -NoLogo -NoProfile -NonInteractive -Command "& (\"Set-\" + \"ExecutionPolicy\") -Scope CurrentUser RemoteSigned"' + "`n"
$externalLaunchTokenFailure = $null
try {
    Assert-PshGoal1ShellPolicyTokenBoundary -Text $externalLaunchFixture -Remediation $policyRemediation
}
catch {
    $externalLaunchTokenFailure = $_
}
Assert-PshCondition ($null -ne $externalLaunchTokenFailure -and
    [string]$externalLaunchTokenFailure.Exception.Message -like '*composed execution-policy token outside reviewed remediations*') 'A parameter-expanded external composed policy launch escaped the install.sh token boundary.'
$externalLaunchFailure = $null
try {
    [void](Get-PshGoal1InstallShellPowerShellPayloads -Text $externalLaunchFixture)
}
catch {
    $externalLaunchFailure = $_
}
Assert-PshCondition ($null -ne $externalLaunchFailure -and
    [string]$externalLaunchFailure.Exception.Message -like '*powershell_path reference inventory changed*') 'An extra payload-external PowerShell launch escaped the install.sh reference inventory.'

foreach ($shellPowerShellPayload in $shellPowerShellPayloads) {
    $shellPayloadTokens = $null
    $shellPayloadParseErrors = $null
    $shellPayloadAst = [System.Management.Automation.Language.Parser]::ParseInput(
        [string]$shellPowerShellPayload.Text,
        [ref]$shellPayloadTokens,
        [ref]$shellPayloadParseErrors
    )
    Assert-PshCondition (@($shellPayloadParseErrors).Count -eq 0) "The install.sh $($shellPowerShellPayload.Label) PowerShell payload could not be parsed."
    foreach ($finding in @(Get-PshGoal1PowerShellMutationFindingsFromAst -Ast $shellPayloadAst -Label ("src/install/install.sh:" + [string]$shellPowerShellPayload.Label))) {
        $policyCommandFindings.Add($finding)
    }
}

$policyFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal1-policy-fixtures-' + [Guid]::NewGuid().ToString('N'))
try {
    foreach ($relativeDirectory in @('src/bootstrapper', 'src/install', 'reject')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $policyFixtureRoot $relativeDirectory))
    }
    $fixtureEncoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $policyFixtureRoot 'src/bootstrapper/Program.cs'), ('private const string PolicyRemediation = "' + $policyRemediation + '";' + "`n"), $fixtureEncoding)
    [IO.File]::WriteAllText((Join-Path $policyFixtureRoot 'src/install/install.ps1'), ('$script:PshOnlinePolicyRemediation = ' + "'$policyRemediation'" + "`n"), $fixtureEncoding)
    [IO.File]::WriteAllText((Join-Path $policyFixtureRoot 'src/install/install-offline.ps1'), ('$script:PshOfflinePolicyRemediation = ' + "'$policyRemediation'" + "`n"), $fixtureEncoding)
    $allowedShellFixtureLines = @(
        ('policy_remediation=' + "'$policyRemediation'"),
        ('catch { Throw-PshShellParentFailure 4 "PshExecutionPolicyProbe" "Dependency" "Unable to determine the effective PowerShell execution policy." "' + $policyRemediation + '" }'),
        ('catch { Throw-PshShellParentFailure 4 "PshExecutionPolicyProbe" "Dependency" ([string]$_.Exception.Message) "' + $policyRemediation + '" }'),
        ('catch { Throw-PshShellParentFailure 4 "PshExecutionPolicyProbe" "Dependency" "Unable to inspect the installer Authenticode status required by execution policy." "' + $policyRemediation + '" }'),
        ('Throw-PshShellParentFailure 4 "PshExecutionPolicy" "Dependency" "PowerShell execution policy does not allow this installer workflow." "' + $policyRemediation + '"')
    )
    $allowedShellFixture = [string]::Join("`n", $allowedShellFixtureLines) + "`n"
    [IO.File]::WriteAllText((Join-Path $policyFixtureRoot 'src/install/install.sh'), $allowedShellFixture, $fixtureEncoding)
    $allowedFixtureFiles = @(Get-ChildItem -LiteralPath (Join-Path $policyFixtureRoot 'src') -Recurse -File)
    $allowedFixtureMatches = @($allowedFixtureFiles | ForEach-Object { Select-String -LiteralPath $_.FullName -SimpleMatch 'Set-ExecutionPolicy' })
    Assert-PshCondition ($allowedFixtureMatches.Count -eq 8 -and
        @($allowedFixtureMatches | Where-Object { -not (Test-PshGoal1AllowedPolicyRemediationMatch -Match $_ -Root $policyFixtureRoot -Remediation $policyRemediation) }).Count -eq 0) 'The exact read-only remediation fixture was not allowed.'
    $unapprovedShellMatch = [pscustomobject]@{
        Path = Join-Path $policyFixtureRoot 'src/install/install.sh'
        Line = 'Throw-PshShellParentFailure 4 "PshExecutionPolicy" "Dependency" "Unreviewed diagnostic." "' + $policyRemediation + '"'
        LineNumber = 99
    }
    Assert-PshCondition (-not (Test-PshGoal1AllowedPolicyRemediationMatch -Match $unapprovedShellMatch -Root $policyFixtureRoot -Remediation $policyRemediation)) 'An unreviewed install.sh policy remediation site was allowed.'

    $rejectedPolicyFixtures = @(
        @{ Name = 'direct-policy.ps1'; Text = 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' },
        @{ Name = 'composed-policy.ps1'; Text = "& ('Set-' + 'ExecutionPolicy') -Scope CurrentUser RemoteSigned" },
        @{ Name = 'gpo-mutation.ps1'; Text = "Set-GPRegistryValue -Name Psh -Key 'HKCU\Software\Policies\Psh' -ValueName Enabled -Value 1" },
        @{ Name = 'path-mutation.ps1'; Text = '$env:Path = ''C:\unsafe''' },
        @{ Name = 'persistent-path-mutation.ps1'; Text = "[Environment]::SetEnvironmentVariable('Path', 'C:\unsafe', 'User')" }
    )
    foreach ($fixtureCase in $rejectedPolicyFixtures) {
        $fixturePath = Join-Path (Join-Path $policyFixtureRoot 'reject') ([string]$fixtureCase.Name)
        [IO.File]::WriteAllText($fixturePath, ([string]$fixtureCase.Text + "`n"), $fixtureEncoding)
        $fixtureTokens = $null
        $fixtureParseErrors = $null
        $fixtureAst = [System.Management.Automation.Language.Parser]::ParseFile($fixturePath, [ref]$fixtureTokens, [ref]$fixtureParseErrors)
        Assert-PshCondition (@($fixtureParseErrors).Count -eq 0) "Rejected policy fixture did not parse: $($fixtureCase.Name)"
        Assert-PshCondition (@(Get-PshGoal1PowerShellMutationFindingsFromAst -Ast $fixtureAst -Label ([string]$fixtureCase.Name)).Count -gt 0) "Policy mutation fixture was not rejected: $($fixtureCase.Name)"
    }
}
finally {
    if ([IO.Directory]::Exists($policyFixtureRoot)) { Remove-Item -LiteralPath $policyFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-PshCondition ($policyCommandFindings.Count -eq 0) ('Goal 1 source mutates execution policy, GPO, or persistent PATH: {0}' -f ([string]::Join(', ', $policyCommandFindings.ToArray())))

$originalEdition = $env:PSH_EDITION
try {
    Remove-Module Psh -Force -ErrorAction SilentlyContinue
    Import-Module -Name $manifestPath -Force -ErrorAction Stop

    $module = Get-Module -Name Psh
    $completerLoadError = & $module { $script:PshCompleterLoadError }
    Assert-PshCondition ([string]::IsNullOrWhiteSpace([string]$completerLoadError)) "Generated argument completers failed to load: $completerLoadError"
    $completion = TabExpansion2 -InputScript 'psh cap' -CursorColumn 7
    Assert-PshCondition (@($completion.CompletionMatches.CompletionText) -contains 'capabilities') 'Generated management completion did not offer capabilities.'

    $configKeyInput = 'psh config set Dis'
    $configKeyCompletion = TabExpansion2 -InputScript $configKeyInput -CursorColumn $configKeyInput.Length
    Assert-PshCondition (@($configKeyCompletion.CompletionMatches.CompletionText) -contains 'DisabledCommands') 'Generated config completion did not offer DisabledCommands.'

    $fdGeneratedFlags = @(& $module { @($script:PshCommandFlags['fd']) })
    Assert-PshCondition ($fdGeneratedFlags -contains '-e') 'Generated fd completion metadata omitted the documented -e extension filter.'

    foreach ($expectedCommand in $expectedCommands) {
        $disabledCommandInput = "psh config set DisabledCommands $expectedCommand"
        $disabledCommandCompletion = TabExpansion2 -InputScript $disabledCommandInput -CursorColumn $disabledCommandInput.Length
        Assert-PshCondition (@($disabledCommandCompletion.CompletionMatches.CompletionText) -contains $expectedCommand) "Generated config completion did not offer '$expectedCommand' for DisabledCommands."
    }

    foreach ($edition in @('Core', 'Full')) {
        $env:PSH_EDITION = $edition
        $jsonOutput = @(& psh capabilities --json)
        Assert-PshCondition ($LASTEXITCODE -eq 0) "psh capabilities --json failed for $edition."
        $capabilities = Convert-PshOutputFromJson -Output $jsonOutput
        Assert-PshCondition ($capabilities.edition -eq $edition) "Capabilities reported the wrong edition for $edition."
        Assert-PshCondition (@($capabilities.commands).Count -eq 64) "Capabilities did not report 64 commands for $edition."

        foreach ($capability in $capabilities.commands) {
            if ($edition -eq 'Full' -and $nativeFullCommands -contains $capability.name) {
                $nativeState = [string]$capability.nativeState
                Assert-PshCondition ($nativeState -in @('pinned', 'unavailable', 'missing', 'invalid', 'tampered', 'wrong-architecture')) "$($capability.name) reported an unexpected Full native state: $nativeState."
                if ($nativeState -eq 'pinned') {
                    Assert-PshCondition ($capability.activeBackend -eq ("native:{0}" -f $capability.name)) "$($capability.name) reported the wrong Full backend for a healthy pinned tool."
                }
                else {
                    Assert-PshCondition ($capability.activeBackend -eq 'unavailable') "$($capability.name) exposed a usable Full backend while its pinned tool was $nativeState."
                }
            }
            else {
                Assert-PshCondition ($capability.activeBackend -eq 'powershell') "$($capability.name) reported the wrong active backend for $edition."
            }
        }
    }

    $usageOutput = @(& psh not-a-command)
    Assert-PshCondition ($LASTEXITCODE -eq 2) 'An unknown management action did not set usage exit code 2.'
    Assert-PshCondition ($usageOutput.Count -gt 0) 'An unknown management action did not emit a plain-text usage error.'
}
finally {
    $env:PSH_EDITION = $originalEdition
    Remove-Module Psh -Force -ErrorAction SilentlyContinue
}

$installRoot = Join-Path ([IO.Path]::GetTempPath()) ("psh-goal1-{0}" -f [Guid]::NewGuid().ToString('N'))
try {
    $versionRoot = Join-Path $installRoot 'versions/0.1.0'
    $installedModuleRoot = Join-Path $versionRoot 'Psh'
    [IO.Directory]::CreateDirectory($versionRoot) | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/Psh') -Destination $installedModuleRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/install/bootstrap.ps1') -Destination (Join-Path $installRoot 'bootstrap.ps1')
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/install/config.psd1') -Destination (Join-Path $installRoot 'config.psd1')

    $switchScript = Join-Path $RepositoryRoot 'src/install/Set-PshCurrentVersion.ps1'
    & $switchScript -InstallRoot $installRoot -Version '0.1.0'
    & $switchScript -InstallRoot $installRoot -Version '0.1.0'

    $currentPath = Join-Path $installRoot 'current.json'
    Assert-PshCondition (Test-Path -LiteralPath $currentPath -PathType Leaf) 'Atomic version switching did not create current.json.'
    $current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
    Assert-PshCondition ($current.version -eq '0.1.0') 'current.json points to the wrong version.'
    Assert-PshCondition (@(Get-ChildItem -LiteralPath $installRoot -Filter '.current.*.tmp' -File).Count -eq 0) 'Atomic version switching left temporary files behind.'
    Assert-PshCondition (@(Get-ChildItem -LiteralPath $installRoot -Filter '.current.*.bak' -File).Count -eq 0) 'Atomic version switching left backup files behind.'

    Remove-Module Psh -Force -ErrorAction SilentlyContinue
    . (Join-Path $installRoot 'bootstrap.ps1')
    Assert-PshCondition ($null -ne (Get-Module Psh)) 'The stable bootstrap did not import Psh.'
    $installedCapabilities = Convert-PshOutputFromJson -Output @(& psh capabilities --json)
    Assert-PshCondition ($installedCapabilities.edition -eq 'Core') 'The installed default config did not select Core.'
    Assert-PshCondition (@($installedCapabilities.commands).Count -eq 64) 'The bootstrapped module did not report 64 commands.'
}
finally {
    Remove-Module Psh -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force
    }
}

Write-Output 'Goal 1 acceptance passed: specification, generated artifacts, module capabilities, safety constraints, and install layout.'
