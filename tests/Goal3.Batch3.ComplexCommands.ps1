# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$moduleManifest = Join-Path -Path $RepositoryRoot -ChildPath 'src/Psh/Psh.psd1'
$testRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('psh-goal3-batch3-{0}' -f [Guid]::NewGuid().ToString('N'))
$configRoot = Join-Path $testRoot 'local app data'
$fixtureRoot = Join-Path $testRoot 'fixtures with spaces'
$sentinelRoot = Join-Path $testRoot 'sentinels'
$originalLocalAppData = $env:LOCALAPPDATA
$originalEdition = $env:PSH_EDITION
$originalPath = $env:PATH
$originalPathSentinel = $env:PSH_BATCH3_PATH_SENTINEL
$originalLocation = (Get-Location).ProviderPath
$utf8NoBom = New-Object Text.UTF8Encoding($false, $true)
$utf8Bom = New-Object Text.UTF8Encoding($true, $true)
$utf16Le = New-Object Text.UnicodeEncoding($false, $true, $true)
$assertionCount = 0
$covered = @{}
$commandNames = @('sed', 'awk', 'jq', 'xargs')

function Assert-PshBatch3 {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) { throw ('Goal 3 Batch 3 assertion failed: {0}' -f $Message) }
    $script:assertionCount++
}

function Invoke-PshBatch3Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),

        [AllowNull()]
        [object[]]$PipelineInput,

        [switch]$UsePipeline,

        [switch]$CountsAsBehavior
    )

    $command = Get-Command -Name ('Psh\{0}' -f $Name) -CommandType Function -ErrorAction Stop
    $global:LASTEXITCODE = 0
    if ($UsePipeline) {
        $output = @(
            & {
                foreach ($item in @($PipelineInput)) { ,$item }
            } | & $command @Arguments
        )
    }
    else {
        $output = @(& $command @Arguments)
    }
    $exitCode = [int]$global:LASTEXITCODE
    foreach ($value in $output) {
        $typeName = if ($null -eq $value) { '<null>' } else { $value.GetType().FullName }
        Assert-PshBatch3 ($value -is [string]) ('{0} leaked a non-string object of type {1}.' -f $Name, $typeName)
    }
    if ($CountsAsBehavior) { $script:covered[$Name] = $true }
    return [PSCustomObject]@{
        Output = @($output | ForEach-Object { [string]$_ })
        ExitCode = $exitCode
    }
}

function Assert-PshBatch3Success {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Assert-PshBatch3 ($Result.ExitCode -eq 0) ('{0} exited {1}: {2}' -f $Context, $Result.ExitCode, ($Result.Output -join ' | '))
}

function Normalize-PshBatch3Text {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '' }
    $value = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($value.EndsWith("`n")) { $value = $value.Substring(0, $value.Length - 1) }
    return $value
}

function Test-PshBatch3ByteSequence {
    param(
        [AllowNull()][byte[]]$Left,
        [AllowNull()][byte[]]$Right
    )

    $leftValues = [byte[]]$Left
    $rightValues = [byte[]]$Right
    if ($leftValues.Length -ne $rightValues.Length) { return $false }
    for ($index = 0; $index -lt $leftValues.Length; $index++) {
        if ($leftValues[$index] -ne $rightValues[$index]) { return $false }
    }
    return $true
}

function Format-PshBatch3ByteDiagnostic {
    param(
        [AllowNull()][byte[]]$Actual,
        [AllowNull()][byte[]]$Expected
    )

    [byte[]]$actualValues = @()
    [byte[]]$expectedValues = @()
    if ($null -ne $Actual) { $actualValues = [byte[]]$Actual }
    if ($null -ne $Expected) { $expectedValues = [byte[]]$Expected }

    $firstMismatch = -1
    $sharedLength = [Math]::Min($actualValues.Length, $expectedValues.Length)
    for ($index = 0; $index -lt $sharedLength; $index++) {
        if ($actualValues[$index] -ne $expectedValues[$index]) {
            $firstMismatch = $index
            break
        }
    }
    if ($firstMismatch -lt 0 -and $actualValues.Length -ne $expectedValues.Length) {
        $firstMismatch = $sharedLength
    }

    $actualHex = if ($actualValues.Length -eq 0) { '<empty>' } else { [BitConverter]::ToString($actualValues) }
    $expectedHex = if ($expectedValues.Length -eq 0) { '<empty>' } else { [BitConverter]::ToString($expectedValues) }
    $actualBase64 = if ($actualValues.Length -eq 0) { '<empty>' } else { [Convert]::ToBase64String($actualValues) }
    $expectedBase64 = if ($expectedValues.Length -eq 0) { '<empty>' } else { [Convert]::ToBase64String($expectedValues) }
    $mismatchText = '<none>'
    if ($firstMismatch -ge 0) {
        $actualValue = if ($firstMismatch -lt $actualValues.Length) { '0x{0:X2}' -f $actualValues[$firstMismatch] } else { '<missing>' }
        $expectedValue = if ($firstMismatch -lt $expectedValues.Length) { '0x{0:X2}' -f $expectedValues[$firstMismatch] } else { '<missing>' }
        $mismatchText = '{0} (actual={1}; expected={2})' -f $firstMismatch, $actualValue, $expectedValue
    }

    return ('actual length={0}, hex={1}, base64={2}; expected length={3}, hex={4}, base64={5}; first mismatch={6}' -f
        $actualValues.Length, $actualHex, $actualBase64, $expectedValues.Length, $expectedHex, $expectedBase64, $mismatchText)
}

function ConvertTo-PshBatch3EncodedBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][Text.Encoding]$Encoding
    )

    $preamble = [byte[]]$Encoding.GetPreamble()
    $payload = [byte[]]$Encoding.GetBytes($Text)
    $bytes = New-Object byte[] ($preamble.Length + $payload.Length)
    if ($preamble.Length -gt 0) { [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length) }
    if ($payload.Length -gt 0) { [Array]::Copy($payload, 0, $bytes, $preamble.Length, $payload.Length) }
    return [byte[]]$bytes
}

function Get-PshBatch3Names {
    param([Parameter(Mandatory = $true)][string]$Path)

    return @(
        Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop |
            Sort-Object -Property Name |
            ForEach-Object { [string]$_.Name }
    )
}

function Test-PshBatch3StringArray {
    param(
        [AllowNull()][object[]]$Actual,
        [AllowNull()][string[]]$Expected
    )

    $actualValues = @($Actual | ForEach-Object { [string]$_ })
    $expectedValues = @($Expected | ForEach-Object { [string]$_ })
    if ($actualValues.Count -ne $expectedValues.Count) { return $false }
    for ($index = 0; $index -lt $actualValues.Count; $index++) {
        if (-not [string]::Equals($actualValues[$index], $expectedValues[$index], [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

function Format-PshBatch3DiagnosticStrings {
    param([AllowNull()][object[]]$Values)

    $items = @($Values)
    if ($items.Count -eq 0) { return '<empty>' }
    return (($items | ForEach-Object {
        $value = [string]$_
        $visible = $value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        'len={0}, text="{1}", utf8={2}' -f $value.Length, $visible, [Convert]::ToBase64String($utf8NoBom.GetBytes($value))
    }) -join ' | ')
}

function ConvertFrom-PshBatch3CaptureRow {
    param([Parameter(Mandatory = $true)][string]$Text)

    return ($Text | ConvertFrom-Json -ErrorAction Stop)
}

function ConvertFrom-PshBatch3NativeCapture {
    param([AllowEmptyCollection()][string[]]$Lines = @())

    $arguments = New-Object System.Collections.ArrayList
    $stdinBytes = $null
    $unexpected = New-Object System.Collections.ArrayList
    foreach ($line in @($Lines)) {
        if ($line.StartsWith("ARG`t", [StringComparison]::Ordinal)) {
            $bytes = [Convert]::FromBase64String($line.Substring(4))
            [void]$arguments.Add($utf8NoBom.GetString($bytes))
            continue
        }
        if ($line.StartsWith("STDIN`t", [StringComparison]::Ordinal)) {
            $stdinBytes = [byte[]][Convert]::FromBase64String($line.Substring(6))
            continue
        }
        [void]$unexpected.Add($line)
    }
    return [PSCustomObject]@{
        Arguments = [object[]]$arguments.ToArray()
        StdinBytes = $stdinBytes
        Unexpected = [object[]]$unexpected.ToArray()
    }
}

function New-PshBatch3WindowsNativeCapture {
    param([Parameter(Mandatory = $true)][string]$Root)

    $sourcePath = Join-Path $Root 'native-capture.cs'
    $outputPath = Join-Path $Root 'native-capture.exe'
    $source = @'
using System;
using System.IO;
using System.Text;

public static class PshBatch3NativeCapture
{
    public static int Main(string[] args)
    {
        for (int index = 0; index < args.Length; index++)
        {
            byte[] argumentBytes = new UTF8Encoding(false, true).GetBytes(args[index] ?? String.Empty);
            Console.WriteLine("ARG\t" + Convert.ToBase64String(argumentBytes));
        }

        if (args.Length > 0 && String.Equals(args[0], "--no-read", StringComparison.Ordinal))
        {
            Console.WriteLine("NO_READ");
            return 0;
        }

        if (args.Length > 0 && String.Equals(args[0], "--stdin", StringComparison.Ordinal))
        {
            using (Stream input = Console.OpenStandardInput())
            using (MemoryStream buffer = new MemoryStream())
            {
                input.CopyTo(buffer);
                Console.WriteLine("STDIN\t" + Convert.ToBase64String(buffer.ToArray()));
            }
        }

        if (args.Length > 0 && String.Equals(args[0], "--exit-one", StringComparison.Ordinal)) { return 1; }
        if (args.Length > 0 && String.Equals(args[0], "--exit-two", StringComparison.Ordinal)) { return 2; }
        if (args.Length > 0 && String.Equals(args[0], "--exit-nine", StringComparison.Ordinal)) { return 9; }
        if (args.Length > 0 && args[0].StartsWith("--exit=", StringComparison.Ordinal))
        {
            int code;
            if (Int32.TryParse(args[0].Substring(7), out code)) { return code; }
        }
        return 0;
    }
}
'@
    [IO.File]::WriteAllText($sourcePath, $source, $utf8NoBom)
    $cscCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $cscPath = @($cscCandidates | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1)[0]
    if ([string]::IsNullOrWhiteSpace([string]$cscPath)) { throw 'The Windows C# compiler for the native capture fixture is unavailable.' }
    $compilerOutput = @(& $cscPath '/nologo' '/target:exe' ('/out:{0}' -f $outputPath) $sourcePath 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($outputPath)) {
        throw ('The native capture fixture failed to compile: {0}' -f ($compilerOutput -join ' | '))
    }
    return $outputPath
}

function Resolve-PshBatch3ComparablePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $trimCharacters = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd($trimCharacters)
    if ($env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\') { return $fullPath }
    $nativeRealpath = Get-Command -Name realpath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $nativeRealpath) { return $fullPath }
    $resolved = @(& $nativeRealpath.Path $fullPath)
    if ($LASTEXITCODE -ne 0 -or $resolved.Count -ne 1) { return $fullPath }
    return [IO.Path]::GetFullPath([string]$resolved[0]).TrimEnd($trimCharacters)
}

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [void][IO.Directory]::CreateDirectory($configRoot)
    [void][IO.Directory]::CreateDirectory($sentinelRoot)
    $env:LOCALAPPDATA = $configRoot
    $env:PSH_EDITION = 'Core'

    $commandSourceRoot = Join-Path $RepositoryRoot 'src/Psh/Commands'
    $commandSourcePaths = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $commandSourceRoot -Filter '*.ps1' -File -ErrorAction Stop)
    $commandSourcePaths += Microsoft.PowerShell.Management\Get-Item -LiteralPath (Join-Path $RepositoryRoot 'src/Psh/Psh.psm1') -ErrorAction Stop
    Assert-PshBatch3 ($commandSourcePaths.Count -ge 1) 'No command implementation source was found.'
    foreach ($sourcePath in $commandSourcePaths) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-PshBatch3 (@($parseErrors).Count -eq 0) ('PowerShell parser errors were found in {0}.' -f $sourcePath.Name)
        $expressionCommands = @(
            $ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
                $name = $node.GetCommandName()
                return [string]::Equals($name, 'Invoke-Expression', [StringComparison]::OrdinalIgnoreCase) -or
                    [string]::Equals($name, 'iex', [StringComparison]::OrdinalIgnoreCase)
            }, $true)
        )
        Assert-PshBatch3 ($expressionCommands.Count -eq 0) ('{0} invokes Invoke-Expression/iex.' -f $sourcePath.Name)
    }

    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    foreach ($name in $commandNames) {
        $exported = Get-Command -Name ('Psh\{0}' -f $name) -CommandType Function -ErrorAction Stop
        Assert-PshBatch3 ($exported.Source -ceq 'Psh') ('{0} is not exported by Psh.' -f $name)
        $help = Invoke-PshBatch3Command -Name $name -Arguments @('--help')
        Assert-PshBatch3 ($help.ExitCode -eq 0 -and $help.Output.Count -ge 1 -and $help.Output[0] -match '^Usage:') ('{0} --help failed.' -f $name)
    }
    Assert-PshBatch3 ($null -ne (Get-Command -Name 'Select-PshJson' -CommandType Function -ErrorAction Stop)) 'Select-PshJson is not exported.'
    Assert-PshBatch3 ($null -ne (Get-Command -Name 'Invoke-PshXArgs' -CommandType Function -ErrorAction Stop)) 'Invoke-PshXArgs is not exported.'

    $coreCapabilities = Get-PshCapabilities
    $commandSpecificationPath = Join-Path $RepositoryRoot 'generated/commands.json'
    $commandSpecification = [IO.File]::ReadAllText($commandSpecificationPath, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
    foreach ($name in $commandNames) {
        $capability = @($coreCapabilities.commands | Where-Object { [string]$_.name -ceq $name })[0]
        $specificationEntry = @($commandSpecification.Commands | Where-Object { [string]$_.Name -ceq $name })[0]
        Assert-PshBatch3 ($null -ne $specificationEntry) ('generated command specification is missing {0}.' -f $name)
        $missingCapabilityFields = @(
            @('summary', 'flags', 'objectApi', 'coreBackend', 'fullBackend') | Where-Object {
                $capability.PSObject.Properties.Name -notcontains $_
            }
        )
        Assert-PshBatch3 ($missingCapabilityFields.Count -eq 0) ('Core capability for {0} is missing fields: {1}.' -f $name, ($missingCapabilityFields -join ', '))
        Assert-PshBatch3 ([string]$capability.summary -ceq [string]$specificationEntry.Summary) ('Core capability summary differs from commands.json for {0}.' -f $name)
        Assert-PshBatch3 (Test-PshBatch3StringArray @($capability.flags) @($specificationEntry.Flags)) ('Core capability flags differ from commands.json for {0}.' -f $name)
        Assert-PshBatch3 ([string]$capability.objectApi -ceq [string]$specificationEntry.ObjectApi) ('Core capability objectApi differs from commands.json for {0}.' -f $name)
        Assert-PshBatch3 ([string]$capability.coreBackend -ceq [string]$specificationEntry.CoreBackend -and [string]$capability.fullBackend -ceq [string]$specificationEntry.FullBackend) ('Core capability backend fields differ from commands.json for {0}.' -f $name)
        Assert-PshBatch3 ([string]$capability.activeBackend -ceq 'powershell') ('Core reports the wrong active backend for {0}.' -f $name)
    }

    $sedPath = Join-Path $fixtureRoot 'sed source.txt'
    [IO.File]::WriteAllText($sedPath, "alpha one`nbeta two`nbeta beta`nomega", $utf8NoBom)
    $sedSubstitute = Invoke-PshBatch3Command -Name sed -Arguments @('s/beta/B/g', $sedPath) -CountsAsBehavior
    Assert-PshBatch3 ($sedSubstitute.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($sedSubstitute.Output -join "`n")) -eq "alpha one`nB two`nB B`nomega") 'sed substitution/global behavior failed.'
    $sedPipelinePrint = Invoke-PshBatch3Command -Name sed -Arguments @('-n', 'p') -PipelineInput @('a') -UsePipeline
    Assert-PshBatch3 ($sedPipelinePrint.ExitCode -eq 0 -and ($sedPipelinePrint.Output -join '') -eq 'a') ('sed -n p did not print pipeline input. ExitCode={0}; Output.Count={1}; Output={2}' -f $sedPipelinePrint.ExitCode, $sedPipelinePrint.Output.Count, (Format-PshBatch3DiagnosticStrings $sedPipelinePrint.Output))
    $sedSameValueFilePath = Join-Path $fixtureRoot 'sed same-value source.txt'
    [IO.File]::WriteAllText($sedSameValueFilePath, 'a', $utf8NoBom)
    $sedSameValueFilePrint = Invoke-PshBatch3Command -Name sed -Arguments @('-n', 's/a/a/p', $sedSameValueFilePath)
    Assert-PshBatch3 ($sedSameValueFilePrint.ExitCode -eq 0 -and ($sedSameValueFilePrint.Output -join '') -eq 'a') ('sed s///p did not print a same-value substitution from a file. ExitCode={0}; Output.Count={1}; Output={2}' -f $sedSameValueFilePrint.ExitCode, $sedSameValueFilePrint.Output.Count, (Format-PshBatch3DiagnosticStrings $sedSameValueFilePrint.Output))
    $sedSameValuePrint = Invoke-PshBatch3Command -Name sed -Arguments @('-n', 's/a/a/p') -PipelineInput @('a') -UsePipeline
    Assert-PshBatch3 ($sedSameValuePrint.ExitCode -eq 0 -and ($sedSameValuePrint.Output -join '') -eq 'a') ('sed s///p did not print a successful substitution when the replacement produced the same text. ExitCode={0}; Output.Count={1}; Output={2}' -f $sedSameValuePrint.ExitCode, $sedSameValuePrint.Output.Count, (Format-PshBatch3DiagnosticStrings $sedSameValuePrint.Output))
    $sedLineAddress = Invoke-PshBatch3Command -Name sed -Arguments @('-n', '2p', $sedPath)
    Assert-PshBatch3 ($sedLineAddress.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($sedLineAddress.Output -join "`n")) -eq 'beta two') 'sed numeric address/print behavior failed.'
    $sedLastAddress = Invoke-PshBatch3Command -Name sed -Arguments @('-n', '$p', $sedPath)
    Assert-PshBatch3 ($sedLastAddress.ExitCode -eq 0 -and ($sedLastAddress.Output -join '') -eq 'omega') 'sed last-line address failed.'
    $sedRegexAddress = Invoke-PshBatch3Command -Name sed -Arguments @('-n', '/two/p', $sedPath)
    Assert-PshBatch3 ($sedRegexAddress.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($sedRegexAddress.Output -join "`n")) -eq 'beta two') 'sed regex address failed.'
    $sedDeleteRange = Invoke-PshBatch3Command -Name sed -Arguments @('2,3d', $sedPath)
    Assert-PshBatch3 ($sedDeleteRange.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($sedDeleteRange.Output -join "`n")) -eq "alpha one`nomega") 'sed range/delete behavior failed.'
    $sedRegexRange = Invoke-PshBatch3Command -Name sed -Arguments @('-n', '/x/,/x/p') -PipelineInput @('x', 'middle', 'x') -UsePipeline
    Assert-PshBatch3 ($sedRegexRange.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($sedRegexRange.Output -join "`n")) -eq "x`nmiddle`nx") 'sed closed a regex-ended range on its start line instead of checking the end address on later lines.'
    $sedQuit = Invoke-PshBatch3Command -Name sed -Arguments @('2q', $sedPath)
    Assert-PshBatch3 ($sedQuit.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($sedQuit.Output -join "`n")) -eq "alpha one`nbeta two") 'sed quit behavior failed.'
    $sedSecondPath = Join-Path $fixtureRoot 'sed second source.txt'
    [IO.File]::WriteAllText($sedSecondPath, "second source one`nsecond source two`n", $utf8NoBom)
    $sedMultiSourceQuit = Invoke-PshBatch3Command -Name sed -Arguments @('2q', $sedPath, $sedSecondPath)
    Assert-PshBatch3 ($sedMultiSourceQuit.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($sedMultiSourceQuit.Output -join "`n")) -eq "alpha one`nbeta two") 'sed q continued into a later file operand.'
    $sedRangeFirstPath = Join-Path $fixtureRoot 'sed range first.txt'
    $sedRangeSecondPath = Join-Path $fixtureRoot 'sed range second.txt'
    [IO.File]::WriteAllText($sedRangeFirstPath, "a1`na2`n", $utf8NoBom)
    [IO.File]::WriteAllText($sedRangeSecondPath, "b1`nb2`n", $utf8NoBom)
    $sedContinuousRange = Invoke-PshBatch3Command -Name sed -Arguments @('-n', '2,3p', $sedRangeFirstPath, $sedRangeSecondPath)
    Assert-PshBatch3 ($sedContinuousRange.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($sedContinuousRange.Output -join "`n")) -eq "a2`nb1") 'sed did not treat multiple non-in-place inputs as one continuous addressed stream.'
    $sedNoFinalFirstPath = Join-Path $fixtureRoot 'sed no-final first.txt'
    $sedBoundarySecondPath = Join-Path $fixtureRoot 'sed boundary second.txt'
    [IO.File]::WriteAllText($sedNoFinalFirstPath, 'first-without-final-newline', $utf8NoBom)
    [IO.File]::WriteAllText($sedBoundarySecondPath, "second-file-line`n", $utf8NoBom)
    $sedBoundaryAddress = Invoke-PshBatch3Command -Name sed -Arguments @('-n', '2p', $sedNoFinalFirstPath, $sedBoundarySecondPath)
    Assert-PshBatch3 ($sedBoundaryAddress.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($sedBoundaryAddress.Output -join "`n")) -eq 'second-file-line') 'sed merged adjacent file operands when the first lacked a final newline or reset global addressing.'
    $sedBoundaryOutput = Invoke-PshBatch3Command -Name sed -Arguments @('s/^//', $sedNoFinalFirstPath, $sedBoundarySecondPath)
    Assert-PshBatch3 ($sedBoundaryOutput.ExitCode -eq 0 -and ($sedBoundaryOutput.Output -join "`n") -ceq "first-without-final-newline`nsecond-file-line`n") 'sed did not synthesize the required LF at a file boundary after a missing final newline.'
    $sedExpressions = Invoke-PshBatch3Command -Name sed -Arguments @('-e', 's/alpha/A/', '-e', '/beta/d', $sedPath)
    Assert-PshBatch3 ($sedExpressions.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($sedExpressions.Output -join "`n")) -eq "A one`nomega") 'sed repeated -e behavior failed.'
    $sedBasicRegex = Invoke-PshBatch3Command -Name sed -Arguments @('s/a+/X/') -PipelineInput @('a+ aa') -UsePipeline
    $sedExtendedRegex = Invoke-PshBatch3Command -Name sed -Arguments @('-E', 's/a+/X/') -PipelineInput @('a+ aa') -UsePipeline
    Assert-PshBatch3 (($sedBasicRegex.Output -join '') -eq 'X aa' -and ($sedExtendedRegex.Output -join '') -eq 'X+ aa') 'sed default BRE and -E ERE semantics did not differ.'
    $sedInvalidBackreference = Invoke-PshBatch3Command -Name sed -Arguments @('s/a/\1/') -PipelineInput @('a') -UsePipeline
    Assert-PshBatch3 ($sedInvalidBackreference.ExitCode -eq 2) 'sed accepted a replacement backreference whose capture group does not exist.'

    $sedInPlaceRoot = Join-Path $fixtureRoot 'sed in place'
    [void][IO.Directory]::CreateDirectory($sedInPlaceRoot)
    $sedUtf8BomPath = Join-Path $sedInPlaceRoot 'utf8-bom-crlf-no-final.txt'
    $sedUtf16Path = Join-Path $sedInPlaceRoot 'utf16-le.txt'
    $sedUtf8NoBomPath = Join-Path $sedInPlaceRoot 'utf8-no-bom.txt'
    $sedFailurePath = Join-Path $sedInPlaceRoot 'failure.txt'
    $sedBinaryPath = Join-Path $sedInPlaceRoot 'binary.bin'
    $sedMetadataPath = Join-Path $sedInPlaceRoot 'metadata.txt'
    $sedUtf8BomBefore = ConvertTo-PshBatch3EncodedBytes -Text "one`r`ntwo`r`nthree" -Encoding $utf8Bom
    $sedUtf8BomAfter = ConvertTo-PshBatch3EncodedBytes -Text "one`r`nTWO`r`nthree" -Encoding $utf8Bom
    $sedUtf16Before = ConvertTo-PshBatch3EncodedBytes -Text "red`nblue`n" -Encoding $utf16Le
    $sedUtf16After = ConvertTo-PshBatch3EncodedBytes -Text "red`nBLUE`n" -Encoding $utf16Le
    $sedUtf8NoBomBefore = ConvertTo-PshBatch3EncodedBytes -Text "left`r`nright`r`n" -Encoding $utf8NoBom
    $sedUtf8NoBomAfter = ConvertTo-PshBatch3EncodedBytes -Text "left`r`nRIGHT`r`n" -Encoding $utf8NoBom
    [IO.File]::WriteAllBytes($sedUtf8BomPath, $sedUtf8BomBefore)
    [IO.File]::WriteAllBytes($sedUtf16Path, $sedUtf16Before)
    [IO.File]::WriteAllBytes($sedUtf8NoBomPath, $sedUtf8NoBomBefore)
    [IO.File]::WriteAllText($sedFailurePath, 'must remain unchanged', $utf8NoBom)
    $sedBinaryBefore = [byte[]](65, 0, 66, 10)
    [IO.File]::WriteAllBytes($sedBinaryPath, $sedBinaryBefore)
    [IO.File]::WriteAllText($sedMetadataPath, 'metadata value', $utf8NoBom)
    [IO.File]::SetLastWriteTimeUtc($sedMetadataPath, [DateTime]::UtcNow.AddHours(-4))
    $sedMetadataWriteTimeBefore = [IO.File]::GetLastWriteTimeUtc($sedMetadataPath)
    $isWindowsPlatform = $env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\'
    $sedMetadataBefore = $null
    $sedMetadataControlFlagsBefore = '<not-windows>'
    $sedMetadataHasAutoInheritedDacl = $false
    $sedUtf8BomSddlBefore = '<not-windows>'
    if ($isWindowsPlatform) {
        $sedMetadataAclBefore = Get-Acl -LiteralPath $sedMetadataPath -ErrorAction Stop
        $sedMetadataBefore = [string]$sedMetadataAclBefore.Sddl
        $sedMetadataDescriptorBefore = [byte[]]$sedMetadataAclBefore.GetSecurityDescriptorBinaryForm()
        $sedMetadataRawBefore = New-Object Security.AccessControl.RawSecurityDescriptor($sedMetadataDescriptorBefore, 0)
        $sedMetadataControlFlagsBefore = [string]$sedMetadataRawBefore.ControlFlags
        $sedMetadataHasAutoInheritedDacl = ($sedMetadataRawBefore.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited) -ne 0
        $sedUtf8BomSddlBefore = [string](Get-Acl -LiteralPath $sedUtf8BomPath -ErrorAction Stop).Sddl
    }
    else {
        & '/bin/chmod' '640' $sedMetadataPath
        if ($LASTEXITCODE -ne 0) { throw 'chmod 640 failed for the sed metadata fixture.' }
        $sedMetadataBefore = [string][IO.File]::GetUnixFileMode($sedMetadataPath)
    }
    $sedInPlaceNames = Get-PshBatch3Names -Path $sedInPlaceRoot

    $sedUtf8BomEdit = Invoke-PshBatch3Command -Name sed -Arguments @('-i', 's/two/TWO/', $sedUtf8BomPath)
    $sedUtf16Edit = Invoke-PshBatch3Command -Name sed -Arguments @('-i', 's/blue/BLUE/', $sedUtf16Path)
    $sedUtf8NoBomEdit = Invoke-PshBatch3Command -Name sed -Arguments @('-i', 's/right/RIGHT/', $sedUtf8NoBomPath)
    $sedMetadataEdit = Invoke-PshBatch3Command -Name sed -Arguments @('-i', 's/metadata/METADATA/', $sedMetadataPath)
    [byte[]]$sedUtf8BomActual = @()
    [byte[]]$sedUtf16Actual = @()
    [byte[]]$sedUtf8NoBomActual = @()
    if ([IO.File]::Exists($sedUtf8BomPath)) { $sedUtf8BomActual = [byte[]][IO.File]::ReadAllBytes($sedUtf8BomPath) }
    if ([IO.File]::Exists($sedUtf16Path)) { $sedUtf16Actual = [byte[]][IO.File]::ReadAllBytes($sedUtf16Path) }
    if ([IO.File]::Exists($sedUtf8NoBomPath)) { $sedUtf8NoBomActual = [byte[]][IO.File]::ReadAllBytes($sedUtf8NoBomPath) }
    $sedUtf8BomSddlAfter = if ($isWindowsPlatform -and [IO.File]::Exists($sedUtf8BomPath)) { [string](Get-Acl -LiteralPath $sedUtf8BomPath -ErrorAction Stop).Sddl } else { '<unavailable>' }
    Assert-PshBatch3 ($sedUtf8BomEdit.ExitCode -eq 0 -and $sedUtf8BomEdit.Output.Count -eq 0 -and (Test-PshBatch3ByteSequence $sedUtf8BomActual $sedUtf8BomAfter)) ('sed -i did not preserve UTF-8 BOM, CRLF, or no-final-newline bytes. ExitCode={0}; Output={1}; Bytes={2}; SddlBefore={3}; SddlAfter={4}' -f $sedUtf8BomEdit.ExitCode, (Format-PshBatch3DiagnosticStrings $sedUtf8BomEdit.Output), (Format-PshBatch3ByteDiagnostic -Actual $sedUtf8BomActual -Expected $sedUtf8BomAfter), $sedUtf8BomSddlBefore, $sedUtf8BomSddlAfter)
    Assert-PshBatch3 ($sedUtf16Edit.ExitCode -eq 0 -and $sedUtf16Edit.Output.Count -eq 0 -and (Test-PshBatch3ByteSequence $sedUtf16Actual $sedUtf16After)) ('sed -i did not preserve UTF-16LE encoding and line endings. ExitCode={0}; Output={1}; Bytes={2}' -f $sedUtf16Edit.ExitCode, (Format-PshBatch3DiagnosticStrings $sedUtf16Edit.Output), (Format-PshBatch3ByteDiagnostic -Actual $sedUtf16Actual -Expected $sedUtf16After))
    Assert-PshBatch3 ($sedUtf8NoBomEdit.ExitCode -eq 0 -and $sedUtf8NoBomEdit.Output.Count -eq 0 -and (Test-PshBatch3ByteSequence $sedUtf8NoBomActual $sedUtf8NoBomAfter)) ('sed -i did not preserve UTF-8 no-BOM and CRLF bytes. ExitCode={0}; Output={1}; Bytes={2}' -f $sedUtf8NoBomEdit.ExitCode, (Format-PshBatch3DiagnosticStrings $sedUtf8NoBomEdit.Output), (Format-PshBatch3ByteDiagnostic -Actual $sedUtf8NoBomActual -Expected $sedUtf8NoBomAfter))
    Assert-PshBatch3 ($sedMetadataEdit.ExitCode -eq 0 -and [IO.File]::ReadAllText($sedMetadataPath, $utf8NoBom) -ceq 'METADATA value') 'sed -i metadata fixture edit failed.'
    Assert-PshBatch3 ([IO.File]::GetLastWriteTimeUtc($sedMetadataPath) -gt $sedMetadataWriteTimeBefore) 'sed -i restored the stale source mtime instead of recording the edit.'
    if ($isWindowsPlatform) {
        $sedMetadataAclAfter = Get-Acl -LiteralPath $sedMetadataPath -ErrorAction Stop
        $sedMetadataAfter = [string]$sedMetadataAclAfter.Sddl
        $sedMetadataDescriptorAfter = [byte[]]$sedMetadataAclAfter.GetSecurityDescriptorBinaryForm()
        $sedMetadataRawAfter = New-Object Security.AccessControl.RawSecurityDescriptor($sedMetadataDescriptorAfter, 0)
        $sedMetadataControlFlagsAfter = [string]$sedMetadataRawAfter.ControlFlags
        Assert-PshBatch3 (-not $sedMetadataHasAutoInheritedDacl -and $sedMetadataAfter -ceq $sedMetadataBefore) ('sed -i changed the Windows security descriptor or the source fixture did not satisfy the control-flag precondition. FlagsBefore={0}; FlagsAfter={1}; Before={2}; After={3}' -f $sedMetadataControlFlagsBefore, $sedMetadataControlFlagsAfter, $sedMetadataBefore, $sedMetadataAfter)
    }
    else {
        Assert-PshBatch3 ([string][IO.File]::GetUnixFileMode($sedMetadataPath) -ceq $sedMetadataBefore) 'sed -i changed or relaxed the Unix 0640 mode.'
    }
    Assert-PshBatch3 (Test-PshBatch3StringArray (Get-PshBatch3Names -Path $sedInPlaceRoot) $sedInPlaceNames) 'sed -i left a temporary or backup file after success.'

    $sedFailureBefore = [IO.File]::ReadAllBytes($sedFailurePath)
    $sedUnsupportedInPlace = Invoke-PshBatch3Command -Name sed -Arguments @('-i', 'w escaped.txt', $sedFailurePath)
    $sedBinaryInPlace = Invoke-PshBatch3Command -Name sed -Arguments @('-i', 's/A/Z/', $sedBinaryPath)
    $sedPipelineInPlace = Invoke-PshBatch3Command -Name sed -Arguments @('-i', 's/a/b/') -PipelineInput @('a') -UsePipeline
    Assert-PshBatch3 ($sedUnsupportedInPlace.ExitCode -eq 2 -and (Test-PshBatch3ByteSequence ([IO.File]::ReadAllBytes($sedFailurePath)) $sedFailureBefore)) 'sed -i changed a file after rejecting unsupported syntax.'
    Assert-PshBatch3 ($sedBinaryInPlace.ExitCode -eq 2 -and (Test-PshBatch3ByteSequence ([IO.File]::ReadAllBytes($sedBinaryPath)) $sedBinaryBefore)) 'sed -i accepted or changed binary input.'
    Assert-PshBatch3 ($sedPipelineInPlace.ExitCode -eq 2) 'sed -i accepted pipeline-only input.'
    Assert-PshBatch3 (Test-PshBatch3StringArray (Get-PshBatch3Names -Path $sedInPlaceRoot) $sedInPlaceNames) 'sed -i left a temporary or backup file after failure.'

    $sedInjectionSentinel = Join-Path $sentinelRoot 'sed-injection.txt'
    $sedInjection = Invoke-PshBatch3Command -Name sed -Arguments @(('$([IO.File]::WriteAllText(''{0}'',''owned''))' -f $sedInjectionSentinel), $sedPath)
    Assert-PshBatch3 ($sedInjection.ExitCode -eq 2 -and -not [IO.File]::Exists($sedInjectionSentinel)) 'sed evaluated a code-like program.'

    $awkPath = Join-Path $fixtureRoot 'awk data.csv'
    [IO.File]::WriteAllText($awkPath, "x,10`ny,3,extra`nx,7`n", $utf8NoBom)
    $awkFields = Invoke-PshBatch3Command -Name awk -Arguments @('-F', ',', '{print $1}', $awkPath) -CountsAsBehavior
    Assert-PshBatch3 ($awkFields.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkFields.Output -join "`n")) -eq "x`ny`nx") 'awk -F/field printing failed.'
    $awkComparison = Invoke-PshBatch3Command -Name awk -Arguments @('-F,', '$1 == "x" {print $2}', $awkPath)
    Assert-PshBatch3 ($awkComparison.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkComparison.Output -join "`n")) -eq "10`n7") 'awk comparison/action selection failed.'
    $awkNumericComparison = Invoke-PshBatch3Command -Name awk -Arguments @('-F,', '$2 >= 7 {print $1}', $awkPath)
    Assert-PshBatch3 ($awkNumericComparison.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkNumericComparison.Output -join "`n")) -eq "x`nx") 'awk numeric comparison failed.'
    $awkComparisonValues = Invoke-PshBatch3Command -Name awk -Arguments @('-F,', '{print ($1 == "x")}', $awkPath)
    Assert-PshBatch3 ($awkComparisonValues.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkComparisonValues.Output -join "`n")) -eq "1`n0`n1") 'awk comparison values were not printed as 1/0.'
    $awkRegex = Invoke-PshBatch3Command -Name awk -Arguments @('-F,', '/y/ {print $0}', $awkPath)
    Assert-PshBatch3 ($awkRegex.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkRegex.Output -join "`n")) -eq 'y,3,extra') 'awk regex matching failed.'
    $awkNrNf = Invoke-PshBatch3Command -Name awk -Arguments @('-F,', '{print NR, NF, $1}', $awkPath)
    Assert-PshBatch3 ($awkNrNf.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkNrNf.Output -join "`n")) -eq "1 2 x`n2 3 y`n3 2 x") 'awk NR/NF behavior failed.'
    $awkVariables = Invoke-PshBatch3Command -Name awk -Arguments @('-F,', '-v', 'prefix=ID', '{print prefix, $1}', $awkPath)
    Assert-PshBatch3 ($awkVariables.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkVariables.Output -join "`n")) -eq "ID x`nID y`nID x") 'awk -v variables failed.'
    $awkCaseVariables = Invoke-PshBatch3Command -Name awk -Arguments @('BEGIN {Foo=1; foo+=2; print Foo,foo}')
    Assert-PshBatch3 ($awkCaseVariables.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkCaseVariables.Output -join "`n")) -eq '1 2') 'awk variable names were not case-sensitive.'
    $awkBeginEnd = Invoke-PshBatch3Command -Name awk -Arguments @('-F,', 'BEGIN {print "start"} {print $1} END {print "end"}', $awkPath)
    Assert-PshBatch3 ($awkBeginEnd.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkBeginEnd.Output -join "`n")) -eq "start`nx`ny`nx`nend") 'awk BEGIN/END blocks failed.'
    $awkAggregation = Invoke-PshBatch3Command -Name awk -Arguments @('-F,', '{sum += $2} END {print sum}', $awkPath)
    Assert-PshBatch3 ($awkAggregation.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkAggregation.Output -join "`n")) -eq '20') 'awk basic aggregation failed.'
    $awkCount = Invoke-PshBatch3Command -Name awk -Arguments @('{count++} END {print count}', $awkPath)
    Assert-PshBatch3 ($awkCount.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkCount.Output -join "`n")) -eq '3') 'awk increment aggregation failed.'
    $awkPrintf = Invoke-PshBatch3Command -Name awk -Arguments @('-F,', '{printf "%s:%d\n", $1, $2}', $awkPath)
    Assert-PshBatch3 ($awkPrintf.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkPrintf.Output -join "`n")) -eq "x:10`ny:3`nx:7") 'awk printf formatting failed.'
    $awkPipeline = Invoke-PshBatch3Command -Name awk -Arguments @('{print $1}') -PipelineInput @('one two', 'three four') -UsePipeline
    Assert-PshBatch3 ($awkPipeline.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkPipeline.Output -join "`n")) -eq "one`nthree") 'awk pipeline input failed.'

    $awkInjectionSentinel = Join-Path $sentinelRoot 'awk-injection.txt'
    $awkSystemProgram = 'BEGIN {system("' + $awkInjectionSentinel + '")}'
    $awkSystem = Invoke-PshBatch3Command -Name awk -Arguments @($awkSystemProgram, $awkPath)
    $awkFunction = Invoke-PshBatch3Command -Name awk -Arguments @('{print toupper($1)}', $awkPath)
    $awkCodeProgram = '{[IO.File]::WriteAllText("' + $awkInjectionSentinel + '","owned")}'
    $awkCode = Invoke-PshBatch3Command -Name awk -Arguments @($awkCodeProgram, $awkPath)
    Assert-PshBatch3 ($awkSystem.ExitCode -eq 2 -and $awkFunction.ExitCode -eq 2 -and $awkCode.ExitCode -eq 2 -and -not [IO.File]::Exists($awkInjectionSentinel)) 'awk accepted or evaluated unsupported function/code syntax.'
    $awkPayload = '$([IO.File]::WriteAllText("' + $awkInjectionSentinel + '","owned"))'
    $awkPayloadResult = Invoke-PshBatch3Command -Name awk -Arguments @('{print $0}') -PipelineInput @($awkPayload) -UsePipeline
    Assert-PshBatch3 ($awkPayloadResult.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($awkPayloadResult.Output -join "`n")) -eq $awkPayload -and -not [IO.File]::Exists($awkInjectionSentinel)) 'awk evaluated code-like input data.'

    $jqPath = Join-Path $fixtureRoot 'jq data.json'
    $jqText = '{"name":"alpha","active":true,"inactive":false,"payload":"literal","meta":{"z":1,"a":2},"equality":{"left":{"a":1,"b":2},"right":{"b":2,"a":1}},"order":{"left":[2,0],"right":[10,0]},"typed":[{"kind":"string","value":"2"},{"kind":"number","value":2}],"items":[{"name":"one","active":true,"score":2},{"name":"two","active":false,"score":5},{"name":"three","active":true,"score":8}]}'
    [IO.File]::WriteAllText($jqPath, $jqText, $utf8NoBom)
    $jqPathResult = Invoke-PshBatch3Command -Name jq -Arguments @('-r', '.name', $jqPath) -CountsAsBehavior
    Assert-PshBatch3 ($jqPathResult.ExitCode -eq 0 -and ($jqPathResult.Output -join '') -eq 'alpha') 'Core jq -r/path selection failed.'
    $jqNested = Invoke-PshBatch3Command -Name jq -Arguments @('.meta.a', $jqPath)
    Assert-PshBatch3 ($jqNested.ExitCode -eq 0 -and ($jqNested.Output -join '').Trim() -eq '2') 'Core jq nested path failed.'
    $jqArrayPath = Invoke-PshBatch3Command -Name jq -Arguments @('-r', '.items[1].name', $jqPath)
    Assert-PshBatch3 ($jqArrayPath.ExitCode -eq 0 -and ($jqArrayPath.Output -join '') -eq 'two') 'Core jq array-index path failed.'
    $jqTopArrayText = '[{"id":"zero"},{"id":"one"}]'
    $jqObjectIdentity = Invoke-PshBatch3Command -Name jq -Arguments @('-c', '.') -PipelineInput @($jqText) -UsePipeline
    $jqArrayIdentity = Invoke-PshBatch3Command -Name jq -Arguments @('-c', '.') -PipelineInput @($jqTopArrayText) -UsePipeline
    Assert-PshBatch3 ($jqObjectIdentity.ExitCode -eq 0 -and ($jqObjectIdentity.Output -join '') -ceq $jqText -and $jqArrayIdentity.ExitCode -eq 0 -and ($jqArrayIdentity.Output -join '') -ceq $jqTopArrayText) 'Core jq identity failed for an object or array input.'
    $jqSmallExponent = Invoke-PshBatch3Command -Name jq -Arguments @('-c', '.') -PipelineInput @('1e-100') -UsePipeline
    $jqSmallExponentValue = 0.0
    $jqSmallExponentParsed = $jqSmallExponent.Output.Count -eq 1 -and [double]::TryParse($jqSmallExponent.Output[0], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$jqSmallExponentValue)
    Assert-PshBatch3 ($jqSmallExponent.ExitCode -eq 0 -and $jqSmallExponentParsed -and $jqSmallExponentValue -ne 0.0) 'Core jq underflowed a representable 1e-100 JSON number to zero.'
    $jqNbspText = '{"a":' + ([string][char]0x00a0) + '1}'
    $jqNbsp = Invoke-PshBatch3Command -Name jq -Arguments @('-c', '.') -PipelineInput @($jqNbspText) -UsePipeline
    Assert-PshBatch3 ($jqNbsp.ExitCode -eq 3) 'Core jq accepted NBSP as structural JSON whitespace.'
    $jqDuplicateKey = Invoke-PshBatch3Command -Name jq -Arguments @('.a') -PipelineInput @('{"a":1,"a":2}') -UsePipeline
    Assert-PshBatch3 ($jqDuplicateKey.ExitCode -eq 0 -and ($jqDuplicateKey.Output -join '').Trim() -eq '2') 'Core jq did not apply last-wins semantics to a repeated identical object key.'
    $jqSameLineStream = Invoke-PshBatch3Command -Name jq -Arguments @('-c', '.') -PipelineInput @('1 2') -UsePipeline
    Assert-PshBatch3 ($jqSameLineStream.ExitCode -eq 0 -and ($jqSameLineStream.Output -join '|') -eq '1|2') 'Core jq did not parse multiple JSON values from the same input line.'
    $jqObjectIteration = Invoke-PshBatch3Command -Name jq -Arguments @('-c', '.[]') -PipelineInput @('{"only":7}') -UsePipeline
    Assert-PshBatch3 ($jqObjectIteration.ExitCode -eq 0 -and ($jqObjectIteration.Output -join '') -eq '7') 'Core jq object iteration failed.'
    $jqObjectNumericIndex = Invoke-PshBatch3Command -Name jq -Arguments @('-c', '.[0]') -PipelineInput @('{"a":1}') -UsePipeline
    $jqStringIndex = Invoke-PshBatch3Command -Name jq -Arguments @('-c', '.[0]') -PipelineInput @('"abc"') -UsePipeline
    $jqScalarIteration = Invoke-PshBatch3Command -Name jq -Arguments @('-c', '.[]') -PipelineInput @('1') -UsePipeline
    $jqNullIteration = Invoke-PshBatch3Command -Name jq -Arguments @('-c', '.[]') -PipelineInput @('null') -UsePipeline
    Assert-PshBatch3 ($jqObjectNumericIndex.ExitCode -eq 3 -and $jqStringIndex.ExitCode -eq 3 -and $jqScalarIteration.ExitCode -eq 3 -and $jqNullIteration.ExitCode -eq 3) 'Core jq accepted an index or iteration operation for an unsupported JSON type.'
    $jqTopIteration = Invoke-PshBatch3Command -Name jq -Arguments @('-r', '.[] | .id') -PipelineInput @($jqTopArrayText) -UsePipeline
    $jqTopIndex = Invoke-PshBatch3Command -Name jq -Arguments @('-r', '.[1].id') -PipelineInput @($jqTopArrayText) -UsePipeline
    Assert-PshBatch3 ($jqTopIteration.ExitCode -eq 0 -and ($jqTopIteration.Output -join '|') -eq 'zero|one' -and $jqTopIndex.ExitCode -eq 0 -and ($jqTopIndex.Output -join '') -eq 'one') 'Core jq top-level []/[1] identity failed.'
    $jqIteration = Invoke-PshBatch3Command -Name jq -Arguments @('-r', '.items[] | .name', $jqPath)
    Assert-PshBatch3 ($jqIteration.ExitCode -eq 0 -and ($jqIteration.Output -join '|') -eq 'one|two|three') 'Core jq array iteration/pipes failed.'
    $jqSelect = Invoke-PshBatch3Command -Name jq -Arguments @('-r', '.items[] | select(.active == true) | .name', $jqPath)
    Assert-PshBatch3 ($jqSelect.ExitCode -eq 0 -and ($jqSelect.Output -join '|') -eq 'one|three') 'Core jq select/comparison failed.'
    $jqTypedComparison = Invoke-PshBatch3Command -Name jq -Arguments @('-r', '.typed[] | select(.value == 2) | .kind', $jqPath)
    Assert-PshBatch3 ($jqTypedComparison.ExitCode -eq 0 -and ($jqTypedComparison.Output -join '') -eq 'number') 'Core jq comparison coerced string "2" to numeric 2.'
    $jqObjectEquality = Invoke-PshBatch3Command -Name jq -Arguments @('.equality | select(.left == .right) | .left.a', $jqPath)
    Assert-PshBatch3 ($jqObjectEquality.ExitCode -eq 0 -and ($jqObjectEquality.Output -join '').Trim() -eq '1') 'Core jq object equality depended on property order.'
    $jqArrayOrder = Invoke-PshBatch3Command -Name jq -Arguments @('-r', 'select(.order.left < .order.right) | .name', $jqPath)
    Assert-PshBatch3 ($jqArrayOrder.ExitCode -eq 0 -and ($jqArrayOrder.Output -join '') -eq 'alpha') 'Core jq array comparison was not lexicographic.'
    $jqCaseSensitiveText = '{"a":1,"A":2}'
    $jqLowerCaseKey = Invoke-PshBatch3Command -Name jq -Arguments @('.a') -PipelineInput @($jqCaseSensitiveText) -UsePipeline
    $jqUpperCaseKey = Invoke-PshBatch3Command -Name jq -Arguments @('.A') -PipelineInput @($jqCaseSensitiveText) -UsePipeline
    Assert-PshBatch3 ($jqLowerCaseKey.ExitCode -eq 0 -and ($jqLowerCaseKey.Output -join '').Trim() -eq '1' -and $jqUpperCaseKey.ExitCode -eq 0 -and ($jqUpperCaseKey.Output -join '').Trim() -eq '2') 'Core jq rejected or merged case-distinct JSON object keys.'
    $jqClrStringProperty = Invoke-PshBatch3Command -Name jq -Arguments @('.Length') -PipelineInput @('"abc"') -UsePipeline
    $jqClrArrayProperty = Invoke-PshBatch3Command -Name jq -Arguments @('.Count') -PipelineInput @('[1,2]') -UsePipeline
    Assert-PshBatch3 ($jqClrStringProperty.ExitCode -eq 3 -and $jqClrArrayProperty.ExitCode -eq 3) 'Core jq exposed CLR Length/Count properties instead of rejecting non-object indexing at runtime.'
    $jqLength = Invoke-PshBatch3Command -Name jq -Arguments @('.items | length', $jqPath)
    Assert-PshBatch3 ($jqLength.ExitCode -eq 0 -and ($jqLength.Output -join '').Trim() -eq '3') 'Core jq length failed.'
    $jqKeys = Invoke-PshBatch3Command -Name jq -Arguments @('.meta | keys', $jqPath)
    $jqKeyValues = @(($jqKeys.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop)
    Assert-PshBatch3 ($jqKeys.ExitCode -eq 0 -and (Test-PshBatch3StringArray $jqKeyValues @('a', 'z'))) 'Core jq keys failed or was not deterministic.'
    $jqScalarKeys = Invoke-PshBatch3Command -Name jq -Arguments @('.name | keys', $jqPath)
    Assert-PshBatch3 ($jqScalarKeys.ExitCode -eq 2) 'Core jq keys accepted a scalar value.'
    $jqMap = Invoke-PshBatch3Command -Name jq -Arguments @('-c', '.items | map(.name)', $jqPath)
    Assert-PshBatch3 ($jqMap.ExitCode -eq 0 -and ($jqMap.Output -join '') -eq '["one","two","three"]') 'Core jq map/-c failed.'
    $jqScalarMap = Invoke-PshBatch3Command -Name jq -Arguments @('-c', 'map(.)') -PipelineInput @('3') -UsePipeline
    Assert-PshBatch3 ($jqScalarMap.ExitCode -eq 3) 'Core jq map accepted scalar input instead of returning a runtime type error.'
    $jqPipeline = Invoke-PshBatch3Command -Name jq -Arguments @('-r', '.name') -PipelineInput @($jqText) -UsePipeline
    Assert-PshBatch3 ($jqPipeline.ExitCode -eq 0 -and ($jqPipeline.Output -join '') -eq 'alpha') 'Core jq pipeline input failed.'
    $jqExitTrue = Invoke-PshBatch3Command -Name jq -Arguments @('-e', '.active', $jqPath)
    $jqExitFalse = Invoke-PshBatch3Command -Name jq -Arguments @('-e', '.inactive', $jqPath)
    $jqExitNull = Invoke-PshBatch3Command -Name jq -Arguments @('-e', '.missing', $jqPath)
    $jqExitEmpty = Invoke-PshBatch3Command -Name jq -Arguments @('-e', '.items[] | select(.score > 99)', $jqPath)
    Assert-PshBatch3 ($jqExitTrue.ExitCode -eq 0 -and $jqExitFalse.ExitCode -eq 1 -and $jqExitNull.ExitCode -eq 1 -and $jqExitEmpty.ExitCode -eq 1) 'Core jq -e false/null/no-output exit behavior failed.'
    $jqInvalidJson = Invoke-PshBatch3Command -Name jq -Arguments @('.') -PipelineInput @('{not json}') -UsePipeline
    $jqUnsupported = Invoke-PshBatch3Command -Name jq -Arguments @('.items | sort_by(.score)', $jqPath)
    Assert-PshBatch3 ($jqInvalidJson.ExitCode -eq 3) 'Core jq invalid JSON did not exit 3.'
    Assert-PshBatch3 ($jqUnsupported.ExitCode -eq 2) 'Core jq accepted an unsupported expression.'

    $jqTyped = @($jqText | Select-PshJson -Filter '.items[] | select(.active == true)')
    Assert-PshBatch3 ($jqTyped.Count -eq 2 -and $jqTyped[0] -is [PSCustomObject] -and [string]$jqTyped[0].name -ceq 'one' -and [int]$jqTyped[1].score -eq 8) 'Select-PshJson did not return selected typed objects.'
    $jqObjectInput = [PSCustomObject]@{ name = 'object-input'; count = 2 }
    $jqObjectValue = @($jqObjectInput | Select-PshJson -Filter '.name')
    Assert-PshBatch3 ($jqObjectValue.Count -eq 1 -and $jqObjectValue[0] -is [string] -and [string]$jqObjectValue[0] -ceq 'object-input') 'Select-PshJson did not accept typed pipeline input.'
    $jqPathObjects = @(Select-PshJson -Filter '.items[] | select(.active == false)' -Path $jqPath)
    Assert-PshBatch3 ($jqPathObjects.Count -eq 1 -and [string]$jqPathObjects[0].name -ceq 'two') 'Select-PshJson -Path failed.'
    $jqMapPipelineCount = ($jqText | Select-PshJson -Filter '.items | map(.name)' | Measure-Object).Count
    $jqMapTyped = $jqText | Select-PshJson -Filter '.items | map(.name)'
    Assert-PshBatch3 ($jqMapPipelineCount -eq 1 -and $jqMapTyped -is [object[]] -and $jqMapTyped.Count -eq 3 -and [string]$jqMapTyped[2] -ceq 'three') 'Select-PshJson enumerated an array-valued result.'

    $jqInjectionSentinel = Join-Path $sentinelRoot 'jq-injection.txt'
    $jqInjection = Invoke-PshBatch3Command -Name jq -Arguments @(('$([IO.File]::WriteAllText("{0}","owned"))' -f $jqInjectionSentinel), $jqPath)
    Assert-PshBatch3 ($jqInjection.ExitCode -eq 2 -and -not [IO.File]::Exists($jqInjectionSentinel)) 'Core jq evaluated a code-like filter.'
    $jqPayloadText = '$([IO.File]::WriteAllText("' + $jqInjectionSentinel + '","owned"))'
    $jqPayloadJson = [PSCustomObject]@{ payload = $jqPayloadText } | ConvertTo-Json -Compress
    $jqPayload = Invoke-PshBatch3Command -Name jq -Arguments @('-r', '.payload') -PipelineInput @($jqPayloadJson) -UsePipeline
    Assert-PshBatch3 ($jqPayload.ExitCode -eq 0 -and ($jqPayload.Output -join '') -eq $jqPayloadText -and -not [IO.File]::Exists($jqInjectionSentinel)) 'Core jq evaluated code-like JSON data.'

    $helperRoot = Join-Path $fixtureRoot 'xargs helper'
    [void][IO.Directory]::CreateDirectory($helperRoot)
    $helperPath = Join-Path $helperRoot 'xargs-helper.ps1'
    $helperText = @'
param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Items
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$values = @($Items)
if ($Mode -ceq 'capture') {
    [PSCustomObject]@{ Count = $values.Count; Items = [object[]]$values } | ConvertTo-Json -Compress -Depth 5
    exit 0
}
if ($Mode -ceq 'sentinel') {
    [IO.File]::WriteAllText($Root, 'executed', (New-Object Text.UTF8Encoding($false)))
    exit 0
}
if ($Mode -ceq 'overlap') {
    $token = [string]$values[0]
    $start = [DateTime]::UtcNow.Ticks
    $milliseconds = if ($token -ceq 'slow') { 3000 } else { 500 }
    Start-Sleep -Milliseconds $milliseconds
    $end = [DateTime]::UtcNow.Ticks
    [IO.File]::WriteAllText((Join-Path $Root ($token + '.interval')), ('{0}|{1}' -f $start, $end), (New-Object Text.UTF8Encoding($false)))
    Write-Output ('done:' + $token)
    exit 0
}
if ($Mode -ceq 'exit') {
    $token = [string]$values[0]
    [IO.File]::WriteAllText((Join-Path $Root ($token + '.exit')), $token, (New-Object Text.UTF8Encoding($false)))
    Write-Output ('exit:' + $token)
    if ($token -ceq 'dependency') { exit 4 }
    if ($token -ceq 'integrity') { exit 5 }
    if ($token -ceq 'bad') { exit 7 }
    exit 0
}
exit 2
'@
    [IO.File]::WriteAllText($helperPath, $helperText, $utf8NoBom)
    $powershellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $helperArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $helperPath, 'capture', $helperRoot)
    $nativeCapturePath = if ($isWindowsPlatform) { New-PshBatch3WindowsNativeCapture -Root $helperRoot } else { $null }

    $xargsWildcardSentinel = Join-Path $sentinelRoot 'xargs-wildcard-command.txt'
    $xargsWildcard = Invoke-PshBatch3Command -Name xargs -Arguments @('pw*', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $helperPath, 'sentinel', $xargsWildcardSentinel) -PipelineInput @('ignored') -UsePipeline
    Assert-PshBatch3 ($xargsWildcard.ExitCode -eq 2 -and -not [IO.File]::Exists($xargsWildcardSentinel)) 'xargs accepted or executed the wildcard command name pw*.'

    $xargsNoInput = Invoke-PshBatch3Command -Name xargs
    $global:LASTEXITCODE = 5
    $xargsNoInputRows = @(Invoke-PshXArgs -Command 'Psh\echo')
    $xargsNoInputApiExit = [int]$global:LASTEXITCODE
    Assert-PshBatch3 ($xargsNoInput.ExitCode -eq 0 -and $xargsNoInput.Output.Count -eq 0 -and $xargsNoInputRows.Count -eq 0 -and $xargsNoInputApiExit -eq 0) 'xargs no-input CLI or object API invocation created a null plan, produced output, or failed.'

    $xargsDefault = Invoke-PshBatch3Command -Name xargs -PipelineInput @('one two') -UsePipeline -CountsAsBehavior
    Assert-PshBatch3 ($xargsDefault.ExitCode -eq 0 -and ($xargsDefault.Output -join '') -eq 'one two') 'xargs default echo failed.'
    $xargsWhitespace = Invoke-PshBatch3Command -Name xargs -Arguments (@('-n', '3', $powershellPath) + $helperArguments) -PipelineInput @('one "two three" four\ five') -UsePipeline
    Assert-PshBatch3Success $xargsWhitespace 'xargs quote/backslash-aware whitespace parsing'
    $xargsWhitespaceRow = ConvertFrom-PshBatch3CaptureRow -Text $xargsWhitespace.Output[0]
    Assert-PshBatch3 ([int]$xargsWhitespaceRow.Count -eq 3 -and (Test-PshBatch3StringArray @($xargsWhitespaceRow.Items) @('one', 'two three', 'four five'))) 'xargs whitespace tokenization or argument arrays failed.'
    $quotedBackslashInput = ([string][char]39) + 'a\b' + ([string][char]39) + ' ' + ([string][char]34) + 'a\b' + ([string][char]34)
    $xargsQuotedBackslashes = Invoke-PshBatch3Command -Name xargs -Arguments (@('-n', '2', $powershellPath) + $helperArguments) -PipelineInput @($quotedBackslashInput) -UsePipeline
    $xargsQuotedBackslashRow = ConvertFrom-PshBatch3CaptureRow -Text $xargsQuotedBackslashes.Output[0]
    Assert-PshBatch3 ($xargsQuotedBackslashes.ExitCode -eq 0 -and [int]$xargsQuotedBackslashRow.Count -eq 2 -and (Test-PshBatch3StringArray @($xargsQuotedBackslashRow.Items) @('a\b', 'a\b'))) 'xargs removed backslashes inside single-quoted or double-quoted default input.'
    if ($isWindowsPlatform) {
        $nativeArgumentValues = @('', 'a"b', 'trail\', 'space value')
        $nativeArgumentText = ($nativeArgumentValues -join [char]0) + [char]0
        $nativeArgumentBytes = [byte[]]$utf8NoBom.GetBytes($nativeArgumentText)
        $xargsNativeArguments = Invoke-PshBatch3Command -Name xargs -Arguments @('-0', '-n', '4', $nativeCapturePath, '--argv') -PipelineInput ([object[]](,$nativeArgumentBytes)) -UsePipeline
        $xargsNativeCapture = ConvertFrom-PshBatch3NativeCapture -Lines $xargsNativeArguments.Output
        Assert-PshBatch3 ($xargsNativeArguments.ExitCode -eq 0 -and $xargsNativeCapture.Unexpected.Count -eq 0 -and (Test-PshBatch3StringArray @($xargsNativeCapture.Arguments) (@('--argv') + $nativeArgumentValues))) 'xargs External invocation did not preserve empty, quoted, trailing-backslash, or spaced argv through the native Windows binder.'
    }
    $xargsBatches = Invoke-PshBatch3Command -Name xargs -Arguments (@('-n', '2', $powershellPath) + $helperArguments) -PipelineInput @('one two three four') -UsePipeline
    $xargsBatchRows = @($xargsBatches.Output | ForEach-Object { ConvertFrom-PshBatch3CaptureRow -Text $_ })
    Assert-PshBatch3 ($xargsBatches.ExitCode -eq 0 -and $xargsBatchRows.Count -eq 2 -and (Test-PshBatch3StringArray @($xargsBatchRows[0].Items) @('one', 'two')) -and (Test-PshBatch3StringArray @($xargsBatchRows[1].Items) @('three', 'four'))) 'xargs -n batching failed.'
    $xargsReplace = Invoke-PshBatch3Command -Name xargs -Arguments (@('-I', '{}', $powershellPath) + $helperArguments + @('pre{}post')) -PipelineInput @('alpha beta', 'gamma') -UsePipeline
    $xargsReplaceRows = @($xargsReplace.Output | ForEach-Object { ConvertFrom-PshBatch3CaptureRow -Text $_ })
    Assert-PshBatch3 ($xargsReplace.ExitCode -eq 0 -and $xargsReplaceRows.Count -eq 2 -and [string](@($xargsReplaceRows[0].Items)[0]) -ceq 'prealpha betapost' -and [string](@($xargsReplaceRows[1].Items)[0]) -ceq 'pregammapost') 'xargs -I did not preserve logical lines or replace argument text.'

    $nulChunks = New-Object object[] 2
    $nulChunks[0] = [byte[]](111, 110, 101, 0, 116, 119)
    $nulChunks[1] = [byte[]](111, 0, 115, 112, 97, 99, 101, 32, 118, 97, 108, 117, 101, 0)
    $xargsNul = Invoke-PshBatch3Command -Name xargs -Arguments (@('-0', '-n', '1', $powershellPath) + $helperArguments) -PipelineInput $nulChunks -UsePipeline
    $xargsNulRows = @($xargsNul.Output | ForEach-Object { ConvertFrom-PshBatch3CaptureRow -Text $_ })
    Assert-PshBatch3 ($xargsNul.ExitCode -eq 0 -and $xargsNulRows.Count -eq 3 -and [string](@($xargsNulRows[0].Items)[0]) -ceq 'one' -and [string](@($xargsNulRows[1].Items)[0]) -ceq 'two' -and [string](@($xargsNulRows[2].Items)[0]) -ceq 'space value') 'xargs -0 changed adjacent byte chunks or NUL-delimited items.'
    $nulReplaceBytes = [byte[]]$utf8NoBom.GetBytes(('alpha beta' + [char]0 + 'gamma delta' + [char]0))
    $xargsNulReplace = Invoke-PshBatch3Command -Name xargs -Arguments (@('-0', '-I{}', $powershellPath) + $helperArguments + @('pre{}post')) -PipelineInput ([object[]](,$nulReplaceBytes)) -UsePipeline
    $xargsNulReplaceRows = @($xargsNulReplace.Output | ForEach-Object { ConvertFrom-PshBatch3CaptureRow -Text $_ })
    Assert-PshBatch3 ($xargsNulReplace.ExitCode -eq 0 -and $xargsNulReplaceRows.Count -eq 2 -and [string](@($xargsNulReplaceRows[0].Items)[0]) -ceq 'prealpha betapost' -and [string](@($xargsNulReplaceRows[1].Items)[0]) -ceq 'pregamma deltapost') 'xargs -0 -I{} did not invoke once per NUL record or preserve embedded spaces.'

    $xargsReplaceWithoutMarker = Invoke-PshBatch3Command -Name xargs -Arguments @('-I{}', 'Psh\echo') -PipelineInput @('alpha', 'beta') -UsePipeline
    Assert-PshBatch3 ($xargsReplaceWithoutMarker.ExitCode -eq 0 -and $xargsReplaceWithoutMarker.Output.Count -eq 2 -and [string]$xargsReplaceWithoutMarker.Output[0] -ceq '' -and [string]$xargsReplaceWithoutMarker.Output[1] -ceq '') 'xargs -I with no marker in the initial arguments did not invoke once per record without appending input.'

    $parallelRoot = Join-Path $helperRoot 'parallel'
    [void][IO.Directory]::CreateDirectory($parallelRoot)
    $parallelArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $helperPath, 'overlap', $parallelRoot)
    $xargsParallel = Invoke-PshBatch3Command -Name xargs -Arguments (@('-n', '1', '-P', '2', $powershellPath) + $parallelArguments) -PipelineInput @('slow fast third fourth') -UsePipeline
    Assert-PshBatch3 ($xargsParallel.ExitCode -eq 0 -and ($xargsParallel.Output -join '|') -eq 'done:slow|done:fast|done:third|done:fourth') 'xargs -P did not preserve invocation output order.'
    $intervals = @()
    foreach ($token in @('slow', 'fast', 'third', 'fourth')) {
        $parts = [IO.File]::ReadAllText((Join-Path $parallelRoot ($token + '.interval')), $utf8NoBom).Split('|')
        $intervals += [PSCustomObject]@{ Start = [long]$parts[0]; End = [long]$parts[1] }
    }
    $maxOverlap = 0
    foreach ($interval in $intervals) {
        $overlap = @($intervals | Where-Object { $_.Start -le $interval.Start -and $_.End -gt $interval.Start }).Count
        if ($overlap -gt $maxOverlap) { $maxOverlap = $overlap }
    }
    Assert-PshBatch3 ($maxOverlap -eq 2) ('xargs -P2 did not create bounded overlap; observed maximum {0}.' -f $maxOverlap)

    $queuedTokens = @(0..95 | ForEach-Object { 'queued-{0:d3}' -f $_ })
    $queuedRows = @(($queuedTokens -join ' ') | Invoke-PshXArgs -Command 'Write-Output' -MaxArguments 1 -MaxParallelism 3)
    $queuedRowsValid = $queuedRows.Count -eq $queuedTokens.Count
    if ($queuedRowsValid) {
        for ($queuedIndex = 0; $queuedIndex -lt $queuedTokens.Count; $queuedIndex++) {
            $queuedRow = $queuedRows[$queuedIndex]
            if ([int]$queuedRow.Index -ne $queuedIndex -or
                @($queuedRow.Arguments).Count -ne 1 -or
                [string](@($queuedRow.Arguments)[0]) -cne $queuedTokens[$queuedIndex] -or
                @($queuedRow.Output).Count -ne 1 -or
                [string](@($queuedRow.Output)[0]) -cne $queuedTokens[$queuedIndex] -or
                [int]$queuedRow.ExitCode -ne 0) {
                $queuedRowsValid = $false
                break
            }
        }
    }
    Assert-PshBatch3 $queuedRowsValid 'Invoke-PshXArgs bounded scheduling lost, duplicated, or reordered lightweight queued plans.'

    $cwdRoot = Join-Path $helperRoot 'worker cwd'
    [void][IO.Directory]::CreateDirectory($cwdRoot)
    $cwdHelperPath = Join-Path $cwdRoot 'relative-helper.ps1'
    $cwdHelperText = @'
param([string]$Value)
Write-Output ((Get-Location).ProviderPath + '|' + $Value)
exit 0
'@
    [IO.File]::WriteAllText($cwdHelperPath, $cwdHelperText, $utf8NoBom)
    $relativeHelperArgument = Join-Path '.' 'relative-helper.ps1'
    $beforeCwdTest = (Get-Location).ProviderPath
    try {
        Set-Location -LiteralPath $cwdRoot
        $xargsCwd = Invoke-PshBatch3Command -Name xargs -Arguments @('-n', '1', '-P', '2', $powershellPath, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $relativeHelperArgument) -PipelineInput @('first second') -UsePipeline
    }
    finally { Set-Location -LiteralPath $beforeCwdTest }
    $expectedCwd = Resolve-PshBatch3ComparablePath -Path $cwdRoot
    $cwdTokens = @()
    $cwdPathsMatch = $true
    foreach ($line in $xargsCwd.Output) {
        $separatorIndex = $line.LastIndexOf('|')
        if ($separatorIndex -lt 1) { $cwdPathsMatch = $false; continue }
        $observedCwd = Resolve-PshBatch3ComparablePath -Path $line.Substring(0, $separatorIndex)
        if (-not [string]::Equals($observedCwd, $expectedCwd, [StringComparison]::Ordinal)) { $cwdPathsMatch = $false }
        $cwdTokens += $line.Substring($separatorIndex + 1)
    }
    Assert-PshBatch3 ($xargsCwd.ExitCode -eq 0 -and $cwdPathsMatch -and (Test-PshBatch3StringArray $cwdTokens @('first', 'second'))) 'xargs -P workers did not preserve the caller FileSystem working directory for relative command arguments.'

    $beforeProviderTest = (Get-Location).ProviderPath
    try {
        Set-Location -Path Env:
        $xargsNonFileSystem = Invoke-PshBatch3Command -Name xargs -Arguments @('-n', '1', '-P', '2', 'Psh\echo') -PipelineInput @('first second') -UsePipeline
    }
    finally { Set-Location -LiteralPath $beforeProviderTest }
    Assert-PshBatch3 ($xargsNonFileSystem.ExitCode -eq 2) 'xargs -P accepted a non-FileSystem caller location.'

    $xargsPshCommand = Invoke-PshBatch3Command -Name xargs -Arguments @('-n', '1', '-P', '2', 'Psh\echo') -PipelineInput @('first second') -UsePipeline
    Assert-PshBatch3 ($xargsPshCommand.ExitCode -eq 0 -and ($xargsPshCommand.Output -join '|') -eq 'first|second') 'xargs -P did not support an exported Psh command.'
    $rawFirstPath = Join-Path $testRoot 'raw-first.b64'
    $rawSecondPath = Join-Path $testRoot 'raw-second.b64'
    [IO.File]::WriteAllText($rawFirstPath, 'QQ==', $utf8NoBom)
    [IO.File]::WriteAllText($rawSecondPath, 'QgA=', $utf8NoBom)
    $rawPathBytes = [byte[]]$utf8NoBom.GetBytes($rawFirstPath + [char]0 + $rawSecondPath + [char]0)
    $xargsRawRows = @(& { ,$rawPathBytes } | Invoke-PshXArgs -Command 'Psh\base64' -ArgumentList @('-d') -MaxArguments 1 -MaxParallelism 2 -NullDelimited)
    Assert-PshBatch3 ($xargsRawRows.Count -eq 2 -and [int]$xargsRawRows[0].Index -eq 0 -and [int]$xargsRawRows[1].Index -eq 1 -and $xargsRawRows[0].PSObject.Properties.Name -contains 'RawOutput' -and $xargsRawRows[1].PSObject.Properties.Name -contains 'RawOutput' -and (Test-PshBatch3ByteSequence ([byte[]]$xargsRawRows[0].RawOutput) ([byte[]](65))) -and (Test-PshBatch3ByteSequence ([byte[]]$xargsRawRows[1].RawOutput) ([byte[]](66, 0)))) 'Invoke-PshXArgs did not capture or stably order raw Psh command bytes by plan.'
    Set-Item -Path Function:global:Invoke-PshBatch3CallerLocal -Value { param([string]$Value) Write-Output ('local:' + $Value) } -Force
    $xargsLocalFunction = Invoke-PshBatch3Command -Name xargs -Arguments @('-n', '1', '-P', '2', 'Invoke-PshBatch3CallerLocal') -PipelineInput @('one two') -UsePipeline
    Assert-PshBatch3 ($xargsLocalFunction.ExitCode -eq 2) 'xargs -P accepted a caller-local function that cannot be projected into worker runspaces.'

    $exitRoot = Join-Path $helperRoot 'exits'
    [void][IO.Directory]::CreateDirectory($exitRoot)
    $exitArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $helperPath, 'exit', $exitRoot)
    $xargsChildFailure = Invoke-PshBatch3Command -Name xargs -Arguments (@('-n', '1', $powershellPath) + $exitArguments) -PipelineInput @('ok bad') -UsePipeline
    $xargsSeverity = Invoke-PshBatch3Command -Name xargs -Arguments (@('-n', '1', '-P', '3', $powershellPath) + $exitArguments) -PipelineInput @('bad dependency integrity') -UsePipeline
    $xargsMissing = Invoke-PshBatch3Command -Name xargs -Arguments @('psh-goal3-command-that-does-not-exist') -PipelineInput @('value') -UsePipeline
    Assert-PshBatch3 ($xargsChildFailure.ExitCode -eq 3 -and [IO.File]::Exists((Join-Path $exitRoot 'ok.exit')) -and [IO.File]::Exists((Join-Path $exitRoot 'bad.exit'))) 'xargs did not normalize a child failure to exit 3 or stopped aggregating unexpectedly.'
    Assert-PshBatch3 ($xargsSeverity.ExitCode -eq 5 -and [IO.File]::Exists((Join-Path $exitRoot 'dependency.exit')) -and [IO.File]::Exists((Join-Path $exitRoot 'integrity.exit'))) 'xargs did not aggregate child exits by severity 5 > 4 > 3 > 0.'
    Assert-PshBatch3 ($xargsMissing.ExitCode -eq 4) 'xargs missing command did not exit 4.'

    $missingWorkerPath = Join-Path $fixtureRoot 'missing-worker-input.txt'
    $xargsWorkerExceptionRows = @($missingWorkerPath | Invoke-PshXArgs -Command 'Get-Item' -ArgumentList @('{}') -ReplaceString '{}' -MaxParallelism 2)
    $xargsAfterExceptionRows = @('reuse-one reuse-two' | Invoke-PshXArgs -Command 'Write-Output' -MaxArguments 1 -MaxParallelism 2)
    Assert-PshBatch3 ($xargsWorkerExceptionRows.Count -eq 1 -and [int]$xargsWorkerExceptionRows[0].ExitCode -eq 3 -and $xargsAfterExceptionRows.Count -eq 2 -and [int]$xargsAfterExceptionRows[0].ExitCode -eq 0 -and [int]$xargsAfterExceptionRows[1].ExitCode -eq 0 -and [string](@($xargsAfterExceptionRows[0].Output)[0]) -ceq 'reuse-one' -and [string](@($xargsAfterExceptionRows[1].Output)[0]) -ceq 'reuse-two') 'Invoke-PshXArgs did not release worker resources for a successful call after a worker exception.'

    $xargsRows = @('one two' | Invoke-PshXArgs -Command $powershellPath -ArgumentList $helperArguments -MaxArguments 1 -MaxParallelism 2)
    Assert-PshBatch3 ($xargsRows.Count -eq 2 -and [int]$xargsRows[0].Index -eq 0 -and [int]$xargsRows[1].Index -eq 1 -and [string]$xargsRows[0].Command -ceq $powershellPath -and [int]$xargsRows[0].ExitCode -eq 0 -and $xargsRows[0].PSObject.Properties.Name -contains 'Arguments' -and $xargsRows[0].PSObject.Properties.Name -contains 'Output') 'Invoke-PshXArgs did not return ordered structured invocation rows.'
    $xargsRowCapture = ConvertFrom-PshBatch3CaptureRow -Text ([string](@($xargsRows[1].Output)[0]))
    Assert-PshBatch3 ([string](@($xargsRowCapture.Items)[0]) -ceq 'two' -and [string](@($xargsRows[1].Arguments)[-1]) -ceq 'two') 'Invoke-PshXArgs did not preserve child argument arrays.'

    $xargsInjectionSentinel = Join-Path $sentinelRoot 'xargs-injection.txt'
    $xargsInjectionValue = '$([IO.File]::WriteAllText("' + $xargsInjectionSentinel + '","owned"));Remove-Item *'
    $xargsInjectionBytes = [byte[]]$utf8NoBom.GetBytes($xargsInjectionValue + [char]0)
    $xargsInjection = Invoke-PshBatch3Command -Name xargs -Arguments (@('-0', '-n', '1', $powershellPath) + $helperArguments) -PipelineInput ([object[]](,$xargsInjectionBytes)) -UsePipeline
    $xargsInjectionRow = ConvertFrom-PshBatch3CaptureRow -Text $xargsInjection.Output[0]
    Assert-PshBatch3 ($xargsInjection.ExitCode -eq 0 -and [string](@($xargsInjectionRow.Items)[0]) -ceq $xargsInjectionValue -and -not [IO.File]::Exists($xargsInjectionSentinel)) 'xargs evaluated a malicious token instead of passing inert argv.'

    foreach ($name in $commandNames) {
        $bad = Invoke-PshBatch3Command -Name $name -Arguments @('--definitely-unsupported')
        Assert-PshBatch3 ($bad.ExitCode -eq 2) ('{0} silently accepted unsupported syntax.' -f $name)
    }
    $missingSed = Invoke-PshBatch3Command -Name sed -Arguments @('p', (Join-Path $fixtureRoot 'missing-sed.txt'))
    $missingAwk = Invoke-PshBatch3Command -Name awk -Arguments @('{print $0}', (Join-Path $fixtureRoot 'missing-awk.txt'))
    Assert-PshBatch3 ($missingSed.ExitCode -eq 3 -and $missingAwk.ExitCode -eq 3) 'sed/awk missing input did not exit 3.'

    $pathFallbackRoot = Join-Path $testRoot 'path fallback'
    [void][IO.Directory]::CreateDirectory($pathFallbackRoot)
    $pathFallbackSentinel = Join-Path $sentinelRoot 'path-jq-invoked.txt'
    $env:PSH_BATCH3_PATH_SENTINEL = $pathFallbackSentinel
    $pathFallbackPs1 = @'
[IO.File]::WriteAllText($env:PSH_BATCH3_PATH_SENTINEL, 'invoked')
Write-Output 'PATH jq invoked'
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $pathFallbackRoot 'jq.ps1'), $pathFallbackPs1, $utf8NoBom)
    $pathFallbackCmd = "@echo off`r`n>`"%PSH_BATCH3_PATH_SENTINEL%`" echo invoked`r`necho PATH jq invoked`r`nexit /b 0`r`n"
    [IO.File]::WriteAllText((Join-Path $pathFallbackRoot 'jq.cmd'), $pathFallbackCmd, $utf8NoBom)
    if ($isWindowsPlatform) {
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $powershellPath -Destination (Join-Path $pathFallbackRoot 'jq.exe') -Force
    }
    else {
        $pathFallbackNative = Join-Path $pathFallbackRoot 'jq'
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $powershellPath -Destination $pathFallbackNative -Force
        & '/bin/chmod' '755' $pathFallbackNative
        if ($LASTEXITCODE -ne 0) { throw 'chmod 755 failed for the PATH jq fixture.' }
    }
    $env:PATH = $pathFallbackRoot + [IO.Path]::PathSeparator + $originalPath
    $env:PSH_EDITION = 'Full'
    $fullMissingPinned = Invoke-PshBatch3Command -Name jq -Arguments @('--version')
    Assert-PshBatch3 ($fullMissingPinned.ExitCode -eq 4 -and -not [IO.File]::Exists($pathFallbackSentinel)) 'Full jq fell back to PATH instead of requiring the pinned dependency.'
    Remove-Module -Name Psh -Force -ErrorAction Stop

    $fullModuleRoot = Join-Path $testRoot 'full-module/Psh'
    [void][IO.Directory]::CreateDirectory((Split-Path $fullModuleRoot -Parent))
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/Psh') -Destination $fullModuleRoot -Recurse -Force
    $dependencyRoot = Join-Path $fullModuleRoot 'Dependencies'
    $nativeRoot = Join-Path $dependencyRoot 'native'
    [void][IO.Directory]::CreateDirectory($nativeRoot)
    if ($isWindowsPlatform) {
        $jqToolRelativePath = 'native/jq-native.exe'
        $jqToolPath = Join-Path $nativeRoot 'jq-native.exe'
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $nativeCapturePath -Destination $jqToolPath -Force
    }
    else {
        $jqToolRelativePath = 'native/jq-native'
        $jqToolPath = Join-Path $nativeRoot 'jq-native'
        $jqToolText = @'
#!/bin/sh
case "$1" in
    --no-read) printf 'NO_READ\n'; exit 0 ;;
    --exit-one) exit 1 ;;
    --exit-two) exit 2 ;;
    --exit-nine) exit 9 ;;
esac
printf 'jq-native:'
separator=''
for argument in "$@"; do
    printf '%s%s' "$separator" "$argument"
    separator='|'
done
if [ "$1" = '--stdin-check' ]; then
    stdin_value=$(cat)
    printf ':stdin=%s' "$stdin_value"
fi
printf '\n'
exit 0
'@
        [IO.File]::WriteAllText($jqToolPath, $jqToolText, $utf8NoBom)
        & '/bin/chmod' '755' $jqToolPath
        if ($LASTEXITCODE -ne 0) { throw 'chmod 755 failed for the pinned jq fixture.' }
    }
    $lock = [ordered]@{
        Tools = @(
            [ordered]@{ Name = 'jq'; Path = $jqToolRelativePath; Sha256 = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $jqToolPath -Algorithm SHA256).Hash }
        )
    }
    [IO.File]::WriteAllText((Join-Path $dependencyRoot 'native-tools.lock.json'), ($lock | ConvertTo-Json -Depth 5), $utf8NoBom)
    Import-Module -Name (Join-Path $fullModuleRoot 'Psh.psd1') -Force -ErrorAction Stop
    $fullCapabilities = Get-PshCapabilities
    foreach ($name in @('sed', 'awk', 'xargs')) {
        $capability = @($fullCapabilities.commands | Where-Object { [string]$_.name -ceq $name })[0]
        Assert-PshBatch3 ([string]$capability.activeBackend -ceq 'powershell') ('Full reports the wrong active backend for {0}.' -f $name)
    }
    $fullJqCapability = @($fullCapabilities.commands | Where-Object { [string]$_.name -ceq 'jq' })[0]
    Assert-PshBatch3 ([string]$fullJqCapability.activeBackend -ceq 'native:jq') 'Full does not report native:jq as the active jq backend.'

    if ($isWindowsPlatform) {
        $fullJqArgumentValues = @('--stdin', '', 'a"b', 'trail\', 'space value')
        $fullJqUnicodeInput = ([string][char]0x6c49) + ([string][char]0x5b57) + ' caf' + ([string][char]0x00e9)
        $fullJqNative = Invoke-PshBatch3Command -Name jq -Arguments $fullJqArgumentValues -PipelineInput @($fullJqUnicodeInput) -UsePipeline
        $fullJqNativeCapture = ConvertFrom-PshBatch3NativeCapture -Lines $fullJqNative.Output
        Assert-PshBatch3 ($fullJqNative.ExitCode -eq 0 -and $fullJqNativeCapture.Unexpected.Count -eq 0 -and (Test-PshBatch3StringArray @($fullJqNativeCapture.Arguments) $fullJqArgumentValues) -and (Test-PshBatch3ByteSequence $fullJqNativeCapture.StdinBytes ([byte[]]$utf8NoBom.GetBytes($fullJqUnicodeInput)))) 'Full jq did not preserve exact native argv or write non-ASCII pipeline input as exact UTF-8 bytes.'
    }
    else {
        $fullJqArguments = Invoke-PshBatch3Command -Name jq -Arguments @('--native-only', '', 'space value', '--')
        $fullJqPipeline = Invoke-PshBatch3Command -Name jq -Arguments @('--stdin-check') -PipelineInput @('first stdin', 'second stdin') -UsePipeline
        Assert-PshBatch3 ($fullJqArguments.ExitCode -eq 0 -and $fullJqArguments.Output[0] -eq 'jq-native:--native-only||space value|--') 'Full jq did not preserve arbitrary native argv.'
        Assert-PshBatch3 ($fullJqPipeline.ExitCode -eq 0 -and ($fullJqPipeline.Output -join "`n") -eq "jq-native:--stdin-check:stdin=first stdin`nsecond stdin") 'Full jq did not forward pipeline input.'
    }
    $fullJqEarlyCloseInput = ([string][char]0x00e9) * 1048576
    $fullJqEarlyClose = Invoke-PshBatch3Command -Name jq -Arguments @('--no-read') -PipelineInput @($fullJqEarlyCloseInput) -UsePipeline
    Assert-PshBatch3 ($fullJqEarlyClose.ExitCode -eq 0 -and $fullJqEarlyClose.Output -contains 'NO_READ') 'Full jq treated a native child closing stdin early after success as a broken-pipe runtime failure.'
    $fullJqExitOne = Invoke-PshBatch3Command -Name jq -Arguments @('--exit-one')
    $fullJqExitTwo = Invoke-PshBatch3Command -Name jq -Arguments @('--exit-two')
    $fullJqExitNine = Invoke-PshBatch3Command -Name jq -Arguments @('--exit-nine')
    Assert-PshBatch3 ($fullJqExitOne.ExitCode -eq 1 -and $fullJqExitTwo.ExitCode -eq 2 -and $fullJqExitNine.ExitCode -eq 3) 'Full jq did not preserve/normalize native exits.'
    Assert-PshBatch3 (-not [IO.File]::Exists($pathFallbackSentinel)) 'Full jq invoked a PATH fallback despite a valid pinned tool.'

    $fullSed = Invoke-PshBatch3Command -Name sed -Arguments @('-n', '1p') -PipelineInput @('full sed') -UsePipeline
    $fullAwk = Invoke-PshBatch3Command -Name awk -Arguments @('{print $1}') -PipelineInput @('full awk') -UsePipeline
    $fullXargs = Invoke-PshBatch3Command -Name xargs -PipelineInput @('full xargs') -UsePipeline
    Assert-PshBatch3 ($fullSed.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($fullSed.Output -join "`n")) -eq 'full sed' -and $fullAwk.ExitCode -eq 0 -and (Normalize-PshBatch3Text ($fullAwk.Output -join "`n")) -eq 'full' -and $fullXargs.ExitCode -eq 0 -and ($fullXargs.Output -join '') -eq 'full xargs') 'Full changed the PowerShell sed/awk/xargs backend behavior.'

    [IO.File]::AppendAllText($jqToolPath, "`n# checksum mismatch", $utf8NoBom)
    $fullJqMismatch = Invoke-PshBatch3Command -Name jq -Arguments @('--version')
    Assert-PshBatch3 ($fullJqMismatch.ExitCode -eq 5 -and -not [IO.File]::Exists($pathFallbackSentinel)) 'Full jq checksum mismatch did not exit 5 or fell back to PATH.'
    [IO.File]::Delete($jqToolPath)
    $fullJqMissing = Invoke-PshBatch3Command -Name jq -Arguments @('--version')
    Assert-PshBatch3 ($fullJqMissing.ExitCode -eq 4 -and -not [IO.File]::Exists($pathFallbackSentinel)) 'Full jq missing pinned tool did not exit 4 or fell back to PATH.'

    foreach ($name in $commandNames) {
        Assert-PshBatch3 ($covered.ContainsKey($name)) ('no behavior row executed for {0}.' -f $name)
    }

    Write-Output ('Goal 3 Batch 3 complex-command acceptance passed: 4 commands, {0} assertions, strict Tier 2 subsets, encoding-preserving sed edits, typed jq, native jq isolation, and argv-safe parallel xargs.' -f $assertionCount)
    $global:LASTEXITCODE = 0
}
finally {
    Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Invoke-PshBatch3CallerLocal -Force -ErrorAction SilentlyContinue
    Set-Location -LiteralPath $originalLocation -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:PSH_EDITION = $originalEdition
    $env:PATH = $originalPath
    $env:PSH_BATCH3_PATH_SENTINEL = $originalPathSentinel
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}
