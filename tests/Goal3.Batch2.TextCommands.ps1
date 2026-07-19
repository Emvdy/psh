# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent),
    [string]$GoldenRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$moduleManifest = Join-Path -Path $RepositoryRoot -ChildPath 'src/Psh/Psh.psd1'
$testRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('psh-goal3-batch2-{0}' -f [Guid]::NewGuid().ToString('N'))
$configRoot = Join-Path $testRoot 'local app data'
$fixtureRoot = Join-Path $testRoot 'fixtures with spaces'
$originalLocalAppData = $env:LOCALAPPDATA
$originalEdition = $env:PSH_EDITION
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$assertionCount = 0
$covered = @{}
$textCommandNames = @('cat', 'bat', 'head', 'tail', 'grep', 'rg', 'cut', 'tr', 'sort', 'uniq', 'wc', 'tee', 'printf', 'echo', 'base64')
$aliasNames = @('cat', 'sort', 'tee', 'echo')
$aliasBaseline = [ordered]@{}

function Assert-PshBatch2 {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) { throw ('Goal 3 Batch 2 assertion failed: {0}' -f $Message) }
    $script:assertionCount++
}

function Get-PshBatch2AliasSnapshot {
    param([Parameter(Mandatory = $true)][string]$Name)
    $alias = Get-Alias -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $alias) {
        return [PSCustomObject]@{
            Exists = $false
            Definition = $null
            Description = $null
            Options = [System.Management.Automation.ScopedItemOptions]::None
            Visibility = [System.Management.Automation.SessionStateEntryVisibility]::Public
        }
    }
    return [PSCustomObject]@{
        Exists = $true
        Definition = [string]$alias.Definition
        Description = [string]$alias.Description
        Options = $alias.Options
        Visibility = $alias.Visibility
    }
}

function Test-PshBatch2AliasSnapshot {
    param(
        [AllowNull()][System.Management.Automation.AliasInfo]$Alias,
        [Parameter(Mandatory = $true)][object]$Snapshot
    )
    if (-not $Snapshot.Exists) { return $null -eq $Alias }
    if ($null -eq $Alias) { return $false }
    return ([string]$Alias.Definition -ceq [string]$Snapshot.Definition -and
        [string]$Alias.Description -ceq [string]$Snapshot.Description -and
        $Alias.Options -eq $Snapshot.Options -and
        $Alias.Visibility -eq $Snapshot.Visibility)
}

function Invoke-PshBatch2Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),

        [AllowNull()]
        [object[]]$PipelineInput,

        [switch]$UsePipeline,

        [switch]$UseDownstream,

        [switch]$ExpectTerminatingError
    )

    $module = Get-Module -Name Psh -ErrorAction Stop
    & $module {
        if ($null -ne $script:PshRawByteSink) { $script:PshRawByteSink.Dispose() }
        $script:PshRawByteSink = New-Object IO.MemoryStream
    }
    try {
        $command = Get-Command -Name ('Psh\{0}' -f $Name) -CommandType Function -ErrorAction Stop
        $caughtError = $null
        try {
            if ($UsePipeline) {
                if ($UseDownstream) {
                    $output = @(
                        & {
                            foreach ($item in @($PipelineInput)) { ,$item }
                        } | & $command @Arguments | ForEach-Object { $_ }
                    )
                }
                else {
                    $output = @(
                        & {
                            foreach ($item in @($PipelineInput)) { ,$item }
                        } | & $command @Arguments
                    )
                }
            }
            elseif ($UseDownstream) { $output = @(& $command @Arguments | ForEach-Object { $_ }) }
            else { $output = @(& $command @Arguments) }
        }
        catch {
            if (-not $ExpectTerminatingError) { throw }
            $caughtError = $_
            $output = @()
        }
        if ($ExpectTerminatingError -and $null -eq $caughtError) {
            throw ('{0} did not raise the expected terminating error.' -f $Name)
        }
        if (-not $ExpectTerminatingError -and $null -ne $caughtError) {
            throw $caughtError
        }
        $exitCode = [int]$global:LASTEXITCODE
        $rawBase64 = & $module { [Convert]::ToBase64String($script:PshRawByteSink.ToArray()) }
        $rawBytes = [Convert]::FromBase64String([string]$rawBase64)
        foreach ($value in $output) {
            Assert-PshBatch2 ($value -is [string]) ('{0} leaked a non-string object of type {1}.' -f $Name, $value.GetType().FullName)
        }
        $script:covered[$Name] = $true
        return [PSCustomObject]@{
            Output = @($output | ForEach-Object { [string]$_ })
            RawBytes = [byte[]]$rawBytes
            ExitCode = $exitCode
            Error = $caughtError
        }
    }
    finally {
        & $module {
            if ($null -ne $script:PshRawByteSink) { $script:PshRawByteSink.Dispose() }
            $script:PshRawByteSink = $null
        }
    }
}

function Assert-PshBatch2Success {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Context
    )
    Assert-PshBatch2 ($Result.ExitCode -eq 0) ('{0} exited {1}: {2}' -f $Context, $Result.ExitCode, ($Result.Output -join ' | '))
}

function Test-PshByteSequence {
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

function Normalize-PshBatch2Text {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $value = $Text.Replace("`r`n", "`n").Replace("`r", "`n").Replace('\', '/')
    if ($value.EndsWith("`n")) { $value = $value.Substring(0, $value.Length - 1) }
    return $value
}

function Compare-PshBatch2Golden {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [AllowNull()][string[]]$Actual = @()
    )
    $path = Join-Path $GoldenRoot ($Id + '.txt')
    Assert-PshBatch2 ([IO.File]::Exists($path)) ('GNU golden is missing: {0}' -f $path)
    $expected = Normalize-PshBatch2Text ([IO.File]::ReadAllText($path, $utf8NoBom))
    $actualText = Normalize-PshBatch2Text ($Actual -join "`n")
    Assert-PshBatch2 ([string]::Equals($expected, $actualText, [StringComparison]::Ordinal)) ('GNU golden mismatch for {0}. Expected <{1}>, actual <{2}>.' -f $Id, $expected, $actualText)
}

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [void][IO.Directory]::CreateDirectory($configRoot)
    $env:LOCALAPPDATA = $configRoot
    $env:PSH_EDITION = 'Core'
    foreach ($name in $aliasNames) {
        $aliasBaseline[$name] = Get-PshBatch2AliasSnapshot -Name $name
    }

    $lfPath = Join-Path $fixtureRoot '中文 lf.txt'
    $crlfPath = Join-Path $fixtureRoot 'space crlf.txt'
    $emptyPath = Join-Path $fixtureRoot 'empty.txt'
    $noFinalPath = Join-Path $fixtureRoot 'no-final.txt'
    $binaryPath = Join-Path $fixtureRoot 'binary.bin'
    [IO.File]::WriteAllText($lfPath, "alpha`n中文 line`n`nbeta`n", $utf8NoBom)
    [IO.File]::WriteAllText($crlfPath, "one`r`ntwo`r`nthree`r`n", $utf8NoBom)
    [IO.File]::WriteAllBytes($emptyPath, [byte[]]@())
    [IO.File]::WriteAllText($noFinalPath, 'last line', $utf8NoBom)
    $binaryBytes = New-Object byte[] 256
    for ($index = 0; $index -lt 256; $index++) { $binaryBytes[$index] = [byte]$index }
    [IO.File]::WriteAllBytes($binaryPath, $binaryBytes)

    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    foreach ($name in $aliasNames) {
        $projected = Get-Command -Name $name -ErrorAction Stop
        Assert-PshBatch2 ($projected.CommandType -eq 'Function' -and $projected.Source -eq 'Psh') ('{0} alias was not projected to a Psh function.' -f $name)
    }

    $catText = Invoke-PshBatch2Command -Name cat -Arguments @('-n', $lfPath)
    Assert-PshBatch2Success $catText 'cat -n file'
    Assert-PshBatch2 (($catText.Output -join "`n") -match '中文 line') 'cat lost Unicode text.'
    Assert-PshBatch2 (($catText.Output -join '') -like "     1`talpha*") 'cat numbering did not use a tab separator.'
    $catPipeline = Invoke-PshBatch2Command -Name cat -Arguments @('-s') -PipelineInput @('a', '', '', 'b') -UsePipeline
    Assert-PshBatch2 ($catPipeline.ExitCode -eq 0 -and (Normalize-PshBatch2Text ($catPipeline.Output -join "`n")) -eq "a`n`nb") 'cat stdin squeeze behavior failed.'
    $catBinary = Invoke-PshBatch2Command -Name cat -Arguments @($binaryPath)
    Assert-PshBatch2 ($catBinary.ExitCode -eq 0 -and (Test-PshByteSequence $catBinary.RawBytes $binaryBytes)) 'cat did not preserve binary bytes through raw stdout.'
    $asciiByteChunks = New-Object object[] 2
    $asciiByteChunks[0] = [byte[]](65, 66)
    $asciiByteChunks[1] = [byte[]](67, 68)
    $catByteChunks = Invoke-PshBatch2Command -Name cat -PipelineInput $asciiByteChunks -UsePipeline
    Assert-PshBatch2 ($catByteChunks.ExitCode -eq 0 -and $catByteChunks.Output.Count -eq 0 -and (Test-PshByteSequence $catByteChunks.RawBytes ([byte[]](65, 66, 67, 68)))) 'cat inserted data or treated ASCII byte chunks as text.'

    $batFile = Invoke-PshBatch2Command -Name bat -Arguments @('-nA', '--style', 'numbers', '--color', 'never', '--paging', 'never', '-l', 'text', $lfPath)
    Assert-PshBatch2 ($batFile.ExitCode -eq 0 -and ($batFile.Output -join "`n") -match '\$') 'Core bat file subset did not number/show line endings.'
    Assert-PshBatch2 (($batFile.Output -join '') -like "     1`talpha*") 'Core bat numbering did not use a tab separator.'
    $batPipeline = Invoke-PshBatch2Command -Name bat -Arguments @('-p') -PipelineInput @('stdin bat') -UsePipeline
    Assert-PshBatch2 ($batPipeline.ExitCode -eq 0 -and ($batPipeline.Output -join '') -eq 'stdin bat') 'Core bat stdin behavior failed.'
    $batInvalid = Invoke-PshBatch2Command -Name bat -Arguments @('--color', 'always', $lfPath)
    Assert-PshBatch2 ($batInvalid.ExitCode -eq 2) 'Core bat accepted an unsupported color mode.'

    $headFile = Invoke-PshBatch2Command -Name head -Arguments @('-n', '2', $crlfPath)
    Assert-PshBatch2 ($headFile.ExitCode -eq 0 -and (Normalize-PshBatch2Text ($headFile.Output -join "`n")) -eq "one`ntwo") 'head file line selection failed.'
    $headPipeline = Invoke-PshBatch2Command -Name head -Arguments @('-n2') -PipelineInput @('one', 'two', 'three') -UsePipeline
    Assert-PshBatch2 ($headPipeline.ExitCode -eq 0 -and (Normalize-PshBatch2Text ($headPipeline.Output -join "`n")) -eq "one`ntwo") 'head stdin selection failed.'
    $headBytes = Invoke-PshBatch2Command -Name head -Arguments @('-c', '4', $binaryPath)
    Assert-PshBatch2 ($headBytes.ExitCode -eq 0 -and (Test-PshByteSequence $headBytes.RawBytes ([byte[]](0, 1, 2, 3)))) 'head -c did not preserve raw bytes.'
    $headBinaryDownstream = Invoke-PshBatch2Command -Name head -Arguments @('-c1', $binaryPath) -UseDownstream
    Assert-PshBatch2 ($headBinaryDownstream.ExitCode -eq 2) 'head -c allowed NUL output into the object pipeline.'
    $tailFile = Invoke-PshBatch2Command -Name tail -Arguments @('-n', '2', $crlfPath)
    Assert-PshBatch2 ($tailFile.ExitCode -eq 0 -and (Normalize-PshBatch2Text ($tailFile.Output -join "`n")) -eq "two`nthree") 'tail file line selection failed.'
    $tailPipeline = Invoke-PshBatch2Command -Name tail -Arguments @('-n', '+2') -PipelineInput @('one', 'two', 'three') -UsePipeline
    Assert-PshBatch2 ($tailPipeline.ExitCode -eq 0 -and (Normalize-PshBatch2Text ($tailPipeline.Output -join "`n")) -eq "two`nthree") 'tail stdin +N selection failed.'
    $tailBytes = Invoke-PshBatch2Command -Name tail -Arguments @('-c4', $binaryPath)
    Assert-PshBatch2 ($tailBytes.ExitCode -eq 0 -and (Test-PshByteSequence $tailBytes.RawBytes ([byte[]](252, 253, 254, 255)))) 'tail -c did not preserve raw bytes.'
    $followDecode = & (Get-Module -Name Psh -ErrorAction Stop) {
        $decoder = New-PshUtf8FollowDecoder
        [PSCustomObject]@{
            First = ConvertFrom-PshFollowBytes -Decoder $decoder -Bytes ([byte[]](228, 184))
            Second = ConvertFrom-PshFollowBytes -Decoder $decoder -Bytes ([byte[]](173))
        }
    }
    Assert-PshBatch2 ([string]$followDecode.First -eq '' -and [string]$followDecode.Second -eq '中') 'tail follow decoder did not preserve a split UTF-8 code point.'
    $utf16FollowPath = Join-Path $fixtureRoot 'utf16-follow.txt'
    [IO.File]::WriteAllText($utf16FollowPath, "one`ntwo`n", (New-Object Text.UnicodeEncoding($false, $true, $true)))
    $tailUtf16Follow = Invoke-PshBatch2Command -Name tail -Arguments @('-f', $utf16FollowPath)
    Assert-PshBatch2 ($tailUtf16Follow.ExitCode -eq 2) 'tail -f did not reject a non-UTF-8 text file before following.'

    $cutFieldsPath = Join-Path $fixtureRoot 'fields.csv'
    [IO.File]::WriteAllText($cutFieldsPath, "one,two,three`nno-delimiter`n甲,乙,丙`n", $utf8NoBom)
    $cutFile = Invoke-PshBatch2Command -Name cut -Arguments @('-d,', '-f1,3', '-s', $cutFieldsPath)
    Assert-PshBatch2 ($cutFile.ExitCode -eq 0 -and (Normalize-PshBatch2Text ($cutFile.Output -join "`n")) -eq "one,three`n甲,丙") 'cut field/file behavior failed.'
    $cutUnsuppressed = Invoke-PshBatch2Command -Name cut -Arguments @('-d,', '-f2', $cutFieldsPath)
    Assert-PshBatch2 ($cutUnsuppressed.ExitCode -eq 0 -and (Normalize-PshBatch2Text ($cutUnsuppressed.Output -join "`n")) -eq "two`nno-delimiter`n乙") 'cut -f discarded a line without the delimiter.'
    $cutCharacters = Invoke-PshBatch2Command -Name cut -Arguments @('-c2') -PipelineInput @('A😀中') -UsePipeline
    Assert-PshBatch2 ($cutCharacters.ExitCode -eq 0 -and ($cutCharacters.Output -join '') -eq '😀') 'cut -c split a Unicode surrogate pair.'
    $cutBytes = Invoke-PshBatch2Command -Name cut -Arguments @('-b1-3', $binaryPath)
    Assert-PshBatch2 ($cutBytes.ExitCode -eq 0 -and (Test-PshByteSequence $cutBytes.RawBytes ([byte[]](0, 1, 2, 10, 11, 12, 13)))) 'cut -b raw byte selection failed.'
    $cutBinaryDownstream = Invoke-PshBatch2Command -Name cut -Arguments @('-b2', $binaryPath) -UseDownstream
    Assert-PshBatch2 ($cutBinaryDownstream.ExitCode -eq 2) 'cut -b allowed a control byte into the object pipeline.'

    $trTranslate = Invoke-PshBatch2Command -Name tr -Arguments @('a-z', 'A-Z') -PipelineInput @('alpha beta') -UsePipeline
    Assert-PshBatch2 ($trTranslate.ExitCode -eq 0 -and ($trTranslate.Output -join '') -eq 'ALPHA BETA') 'tr range translation failed.'
    $trDelete = Invoke-PshBatch2Command -Name tr -Arguments @('-d', '[:digit:]') -PipelineInput @('a1b2') -UsePipeline
    Assert-PshBatch2 ($trDelete.ExitCode -eq 0 -and ($trDelete.Output -join '') -eq 'ab') 'tr class deletion failed.'
    $trSqueeze = Invoke-PshBatch2Command -Name tr -Arguments @('-s', ' ') -PipelineInput @('a   b') -UsePipeline
    Assert-PshBatch2 ($trSqueeze.ExitCode -eq 0 -and ($trSqueeze.Output -join '') -eq 'a b') 'tr squeeze failed.'

    $sortPath = Join-Path $fixtureRoot 'sort.txt'
    [IO.File]::WriteAllText($sortPath, "10,z`n2,b`n2,a`n", $utf8NoBom)
    $sortFile = Invoke-PshBatch2Command -Name sort -Arguments @('-t,', '-k1', '-n', $sortPath)
    Assert-PshBatch2 ($sortFile.ExitCode -eq 0 -and ($sortFile.Output -join '|') -eq '2,a|2,b|10,z') 'sort numeric key/file behavior failed.'
    $sortPipeline = Invoke-PshBatch2Command -Name sort -Arguments @('-fu') -PipelineInput @('Beta', 'alpha', 'ALPHA') -UsePipeline
    Assert-PshBatch2 ($sortPipeline.ExitCode -eq 0 -and $sortPipeline.Output.Count -eq 2) 'sort stdin case-fold unique behavior failed.'

    $uniqPath = Join-Path $fixtureRoot 'uniq.txt'
    [IO.File]::WriteAllText($uniqPath, "a`na`nb`nc`nc`n", $utf8NoBom)
    $uniqFile = Invoke-PshBatch2Command -Name uniq -Arguments @('-c', $uniqPath)
    Assert-PshBatch2 ($uniqFile.ExitCode -eq 0 -and $uniqFile.Output.Count -eq 3 -and $uniqFile.Output[0] -match '^\s+2 a$') 'uniq count/file behavior failed.'
    $uniqPipeline = Invoke-PshBatch2Command -Name uniq -Arguments @('-i') -PipelineInput @('A', 'a', 'B') -UsePipeline
    Assert-PshBatch2 ($uniqPipeline.ExitCode -eq 0 -and ($uniqPipeline.Output -join '|') -eq 'A|B') 'uniq stdin ignore-case behavior failed.'

    $wcFile = Invoke-PshBatch2Command -Name wc -Arguments @('-lwmc', $lfPath)
    Assert-PshBatch2 ($wcFile.ExitCode -eq 0 -and $wcFile.Output.Count -eq 1 -and $wcFile.Output[0] -match '^\s*4\s+4\s+20\s+24\s+') 'wc Unicode/file counts were not stable.'
    $wcPipeline = Invoke-PshBatch2Command -Name wc -Arguments @('-w') -PipelineInput @('one two', 'three') -UsePipeline
    Assert-PshBatch2 ($wcPipeline.ExitCode -eq 0 -and $wcPipeline.Output[0].Trim() -eq '3') 'wc stdin word count failed.'

    $searchRoot = Join-Path $fixtureRoot 'search tree'
    [void][IO.Directory]::CreateDirectory((Join-Path $searchRoot 'sub'))
    [IO.File]::WriteAllText((Join-Path $searchRoot 'visible.txt'), "before`nTODO First`nafter`nTODO second`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $searchRoot 'sub/child.ps1'), "alpha`nTODO child`nomega`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $searchRoot 'sub/skip.ps1'), "TODO skip`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $searchRoot 'sub/excluded.log'), "TODO log`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $searchRoot '.hidden.txt'), "TODO hidden`n", $utf8NoBom)

    $grepFile = Invoke-PshBatch2Command -Name grep -Arguments @('-in', '-m1', 'todo', (Join-Path $searchRoot 'visible.txt'))
    Assert-PshBatch2 ($grepFile.ExitCode -eq 0 -and $grepFile.Output.Count -eq 1 -and $grepFile.Output[0] -eq '2:TODO First') 'grep -i/-n/-m file behavior failed.'
    $grepInvert = Invoke-PshBatch2Command -Name grep -Arguments @('-v', 'TODO', (Join-Path $searchRoot 'visible.txt'))
    Assert-PshBatch2 ($grepInvert.ExitCode -eq 0 -and ($grepInvert.Output -join '|') -eq 'before|after') 'grep -v failed.'
    $grepContext = Invoke-PshBatch2Command -Name grep -Arguments @('-n', '-A1', '-B1', 'First', (Join-Path $searchRoot 'visible.txt'))
    Assert-PshBatch2 ($grepContext.ExitCode -eq 0 -and ($grepContext.Output -join '|') -eq '1-before|2:TODO First|3-after') 'grep -A/-B context output failed.'
    $grepContextC = Invoke-PshBatch2Command -Name grep -Arguments @('-n', '-C1', 'child', (Join-Path $searchRoot 'sub/child.ps1'))
    Assert-PshBatch2 ($grepContextC.ExitCode -eq 0 -and $grepContextC.Output.Count -eq 3) 'grep -C context output failed.'
    $grepRecursive = Invoke-PshBatch2Command -Name grep -Arguments @('-r', '--include', '*.ps1', '--exclude', 'skip*', '--glob', '!*.log', 'TODO', $searchRoot)
    Assert-PshBatch2 ($grepRecursive.ExitCode -eq 0 -and $grepRecursive.Output.Count -eq 1 -and $grepRecursive.Output[0] -match 'child\.ps1:TODO child$') 'grep recursive include/exclude/glob behavior failed.'
    $grepHiddenDefault = Invoke-PshBatch2Command -Name grep -Arguments @('-r', 'hidden', $searchRoot)
    $grepHidden = Invoke-PshBatch2Command -Name grep -Arguments @('-r', '--hidden', 'hidden', $searchRoot)
    Assert-PshBatch2 ($grepHiddenDefault.ExitCode -eq 1 -and $grepHidden.ExitCode -eq 0 -and $grepHidden.Output.Count -eq 1) 'grep --hidden behavior failed.'
    $grepList = Invoke-PshBatch2Command -Name grep -Arguments @('-l', 'TODO', (Join-Path $searchRoot 'visible.txt'), (Join-Path $searchRoot 'sub/child.ps1'))
    Assert-PshBatch2 ($grepList.ExitCode -eq 0 -and $grepList.Output.Count -eq 2) 'grep -l failed.'
    $grepCount = Invoke-PshBatch2Command -Name grep -Arguments @('-c', 'TODO', (Join-Path $searchRoot 'visible.txt'))
    Assert-PshBatch2 ($grepCount.ExitCode -eq 0 -and $grepCount.Output[0] -eq '2') 'grep -c failed.'
    $grepQuiet = Invoke-PshBatch2Command -Name grep -Arguments @('-q', 'TODO', (Join-Path $searchRoot 'visible.txt'))
    Assert-PshBatch2 ($grepQuiet.ExitCode -eq 0 -and $grepQuiet.Output.Count -eq 0) 'grep -q emitted output or failed.'
    $grepExtended = Invoke-PshBatch2Command -Name grep -Arguments @('-E', 'TODO (First|second)', (Join-Path $searchRoot 'visible.txt'))
    $grepLiteral = Invoke-PshBatch2Command -Name grep -Arguments @('-F', 'TODO (First|second)', (Join-Path $searchRoot 'visible.txt'))
    Assert-PshBatch2 ($grepExtended.ExitCode -eq 0 -and $grepLiteral.ExitCode -eq 1) 'grep -E/-F semantics failed.'
    $grepBasicPlus = Invoke-PshBatch2Command -Name grep -Arguments @('a+b') -PipelineInput @('a+b', 'aaab') -UsePipeline
    $grepExtendedPlus = Invoke-PshBatch2Command -Name grep -Arguments @('-E', 'a+b') -PipelineInput @('a+b', 'aaab') -UsePipeline
    Assert-PshBatch2 (($grepBasicPlus.Output -join '|') -eq 'a+b' -and ($grepExtendedPlus.Output -join '|') -eq 'aaab') 'grep default BRE and -E did not differ on +.'
    $grepPipeline = Invoke-PshBatch2Command -Name grep -Arguments @('-n', 'two') -PipelineInput @('one', 'two', 'three') -UsePipeline
    Assert-PshBatch2 ($grepPipeline.ExitCode -eq 0 -and $grepPipeline.Output[0] -eq '2:two') 'grep stdin behavior failed.'
    $grepRepeatedStdin = Invoke-PshBatch2Command -Name grep -Arguments @('two', '-', '-') -PipelineInput @('one', 'two') -UsePipeline
    Assert-PshBatch2 ($grepRepeatedStdin.ExitCode -eq 0 -and $grepRepeatedStdin.Output.Count -eq 1 -and $grepRepeatedStdin.Output[0] -eq '(standard input):two') 'grep replayed stdin for a repeated - operand.'
    $grepMixedSources = Invoke-PshBatch2Command -Name grep -Arguments @('TODO', '-', (Join-Path $searchRoot 'visible.txt')) -PipelineInput @('TODO stdin') -UsePipeline
    Assert-PshBatch2 ($grepMixedSources.ExitCode -eq 0 -and $grepMixedSources.Output.Count -eq 3 -and $grepMixedSources.Output[0] -eq '(standard input):TODO stdin' -and $grepMixedSources.Output[1] -match 'visible\.txt:TODO First$') 'grep stdin plus file operands did not use source prefixes.'
    $grepBinary = Invoke-PshBatch2Command -Name grep -Arguments @('-F', 'ABC', $binaryPath)
    Assert-PshBatch2 ($grepBinary.ExitCode -eq 0 -and $grepBinary.Output[0] -match '^Binary file .+ matches$') 'grep binary behavior was not stable.'
    $grepNoMatch = Invoke-PshBatch2Command -Name grep -Arguments @('not-present', $lfPath)
    Assert-PshBatch2 ($grepNoMatch.ExitCode -eq 1) 'grep no-match did not exit 1.'

    $rgRecursive = Invoke-PshBatch2Command -Name rg -Arguments @('-n', '--include', '*.ps1', '--exclude', 'skip*', '--glob', '!*.log', 'TODO', $searchRoot)
    Assert-PshBatch2 ($rgRecursive.ExitCode -eq 0 -and $rgRecursive.Output.Count -eq 1 -and $rgRecursive.Output[0] -match 'child\.ps1:2:TODO child$') 'Core rg recursive filters failed.'
    $rgPipeline = Invoke-PshBatch2Command -Name rg -Arguments @('-i', '-F', 'stdin rg') -PipelineInput @('STDIN RG') -UsePipeline
    Assert-PshBatch2 ($rgPipeline.ExitCode -eq 0 -and $rgPipeline.Output[0] -eq 'STDIN RG') 'Core rg stdin literal search failed.'
    $rgNoMatch = Invoke-PshBatch2Command -Name rg -Arguments @('not-present', $searchRoot)
    Assert-PshBatch2 ($rgNoMatch.ExitCode -eq 1) 'Core rg no-match did not exit 1.'

    $findTextObjects = @(Find-PshText -Pattern 'TODO' -Path $searchRoot -Recurse -Include '*.ps1' -Exclude 'skip*')
    Assert-PshBatch2 ($findTextObjects.Count -eq 1 -and $findTextObjects[0].LineNumber -eq 2 -and $findTextObjects[0].Line -eq 'TODO child') 'Find-PshText did not return structured matches.'
    $headObjectBytes = [byte[]](Get-PshHead -Path $binaryPath -Count 3 -Bytes)
    $tailObjectBytes = [byte[]](Get-PshTail -Path $binaryPath -Count 3 -Bytes)
    Assert-PshBatch2 ((Test-PshByteSequence $headObjectBytes ([byte[]](0, 1, 2))) -and (Test-PshByteSequence $tailObjectBytes ([byte[]](253, 254, 255)))) 'Get-PshHead/Get-PshTail byte APIs failed.'
    $measureObject = Measure-PshText -Path $lfPath
    Assert-PshBatch2 ($measureObject.Lines -eq 4 -and $measureObject.Characters -eq 20 -and $measureObject.Bytes -eq 24) 'Measure-PshText returned wrong structured counts.'

    $teeOne = Join-Path $fixtureRoot 'tee-one.txt'
    $teeTwo = Join-Path $fixtureRoot 'tee-two.txt'
    $teeText = Invoke-PshBatch2Command -Name tee -Arguments @($teeOne, $teeTwo) -PipelineInput @('tee text') -UsePipeline
    Assert-PshBatch2 ($teeText.ExitCode -eq 0 -and ($teeText.Output -join '') -eq 'tee text' -and [IO.File]::ReadAllText($teeOne, $utf8NoBom) -eq 'tee text' -and [IO.File]::ReadAllText($teeTwo, $utf8NoBom) -eq 'tee text') 'tee overwrite/multiple-file behavior failed.'
    $teeAppend = Invoke-PshBatch2Command -Name tee -Arguments @('-a', $teeOne) -PipelineInput @(' plus') -UsePipeline
    Assert-PshBatch2 ($teeAppend.ExitCode -eq 0 -and [IO.File]::ReadAllText($teeOne, $utf8NoBom) -eq 'tee text plus') 'tee append failed.'
    $teeBinaryPath = Join-Path $fixtureRoot 'tee-binary.bin'
    $teeBinary = Invoke-PshBatch2Command -Name tee -Arguments @($teeBinaryPath) -PipelineInput ([object[]](,$binaryBytes)) -UsePipeline
    Assert-PshBatch2 ($teeBinary.ExitCode -eq 0 -and (Test-PshByteSequence $teeBinary.RawBytes $binaryBytes) -and (Test-PshByteSequence ([IO.File]::ReadAllBytes($teeBinaryPath)) $binaryBytes)) 'tee binary raw/file behavior failed.'
    $teeChunkPath = Join-Path $fixtureRoot 'tee-chunks.bin'
    $teeByteChunks = Invoke-PshBatch2Command -Name tee -Arguments @($teeChunkPath) -PipelineInput $asciiByteChunks -UsePipeline
    Assert-PshBatch2 ($teeByteChunks.ExitCode -eq 0 -and (Test-PshByteSequence $teeByteChunks.RawBytes ([byte[]](65, 66, 67, 68))) -and (Test-PshByteSequence ([IO.File]::ReadAllBytes($teeChunkPath)) ([byte[]](65, 66, 67, 68)))) 'tee altered adjacent raw byte chunks.'

    $printfBasic = Invoke-PshBatch2Command -Name printf -Arguments @('%s\n', 'one', 'two')
    Assert-PshBatch2 ($printfBasic.ExitCode -eq 0 -and [Text.Encoding]::UTF8.GetString($printfBasic.RawBytes) -eq "one`ntwo`n") 'printf repeated format/raw output failed.'
    $printfNumeric = Invoke-PshBatch2Command -Name printf -Arguments @('%05d %.2f %X %u', '12', '1.5', '255', '-1')
    Assert-PshBatch2 ($printfNumeric.ExitCode -eq 0 -and [Text.Encoding]::UTF8.GetString($printfNumeric.RawBytes) -eq '00012 1.50 FF 18446744073709551615') 'printf numeric formatting failed.'
    $printfMissingNumeric = Invoke-PshBatch2Command -Name printf -Arguments @('%d %.1f %s')
    Assert-PshBatch2 ($printfMissingNumeric.ExitCode -eq 0 -and [Text.Encoding]::UTF8.GetString($printfMissingNumeric.RawBytes) -eq '0 0.0 ') 'printf missing numeric arguments did not default to zero.'
    $printfEscapes = Invoke-PshBatch2Command -Name printf -Arguments @('%b ignored', 'a\nb\cTAIL')
    Assert-PshBatch2 ($printfEscapes.ExitCode -eq 0 -and [Text.Encoding]::UTF8.GetString($printfEscapes.RawBytes) -eq "a`nb") 'printf %b/\c behavior failed.'
    Remove-Variable -Name PshBatch2PrintfValue -Scope Global -Force -ErrorAction SilentlyContinue
    $printfVariable = Invoke-PshBatch2Command -Name printf -Arguments @('-v', 'PshBatch2PrintfValue', '%s-%d', 'value', '7')
    Assert-PshBatch2 ($printfVariable.ExitCode -eq 0 -and $printfVariable.Output.Count -eq 0 -and $printfVariable.RawBytes.Length -eq 0 -and $global:PshBatch2PrintfValue -eq 'value-7') 'printf -v assignment failed.'
    Remove-Variable -Name PshBatch2PrintfValue -Scope Global -Force

    $echoDefault = Invoke-PshBatch2Command -Name echo -Arguments @('hello', '中文')
    Assert-PshBatch2 ($echoDefault.ExitCode -eq 0 -and $echoDefault.Output[0] -eq 'hello 中文') 'echo default output failed.'
    $echoEscapes = Invoke-PshBatch2Command -Name echo -Arguments @('-e', 'one\ntwo')
    Assert-PshBatch2 ($echoEscapes.ExitCode -eq 0 -and ($echoEscapes.Output -join '') -eq "one`ntwo") 'echo -e failed.'
    $echoLiteral = Invoke-PshBatch2Command -Name echo -Arguments @('-E', 'one\ntwo')
    Assert-PshBatch2 ($echoLiteral.ExitCode -eq 0 -and ($echoLiteral.Output -join '') -eq 'one\ntwo') 'echo -E failed.'
    $echoNoNewline = Invoke-PshBatch2Command -Name echo -Arguments @('-n', 'value')
    Assert-PshBatch2 ($echoNoNewline.ExitCode -eq 0 -and [Text.Encoding]::UTF8.GetString($echoNoNewline.RawBytes) -eq 'value') 'echo -n raw output failed.'

    $smallBinary = [byte[]](0, 1, 2, 253, 254, 255)
    $smallBinaryPath = Join-Path $fixtureRoot 'small.bin'
    [IO.File]::WriteAllBytes($smallBinaryPath, $smallBinary)
    $base64File = Invoke-PshBatch2Command -Name base64 -Arguments @('-w0', $smallBinaryPath)
    Assert-PshBatch2 ($base64File.ExitCode -eq 0 -and $base64File.Output.Count -eq 0 -and [Text.Encoding]::UTF8.GetString($base64File.RawBytes) -eq [Convert]::ToBase64String($smallBinary)) 'base64 file encoding failed.'
    $base64Pipeline = Invoke-PshBatch2Command -Name base64 -Arguments @('-w', '0') -PipelineInput @('stdin base64') -UsePipeline
    Assert-PshBatch2 ($base64Pipeline.ExitCode -eq 0 -and $base64Pipeline.Output.Count -eq 0 -and [Text.Encoding]::UTF8.GetString($base64Pipeline.RawBytes) -eq [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('stdin base64'))) 'base64 stdin encoding failed.'
    $base64Chunks = Invoke-PshBatch2Command -Name base64 -Arguments @('-w', '0') -PipelineInput $asciiByteChunks -UsePipeline
    Assert-PshBatch2 ($base64Chunks.ExitCode -eq 0 -and $base64Chunks.Output.Count -eq 0 -and [Text.Encoding]::UTF8.GetString($base64Chunks.RawBytes) -eq 'QUJDRA==') 'base64 inserted bytes between adjacent raw chunks.'
    $base64UnwrappedDownstream = Invoke-PshBatch2Command -Name base64 -Arguments @('-w0') -PipelineInput @('a') -UsePipeline -UseDownstream -ExpectTerminatingError
    Assert-PshBatch2 ($base64UnwrappedDownstream.ExitCode -eq 2 -and $base64UnwrappedDownstream.RawBytes.Length -eq 0 -and $base64UnwrappedDownstream.Output.Count -eq 0 -and [int]$base64UnwrappedDownstream.Error.Exception.Data['PshExitCode'] -eq 2) 'base64 -w0 did not fail cleanly for downstream output.'
    $nativeTee = Get-Command -Name tee -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $nativeTee) {
        $nativeCapturePath = Join-Path $fixtureRoot 'base64-native-downstream.bin'
        $nativeDownstreamError = $null
        try {
            & { ,'a' } | & (Get-Command -Name 'Psh\base64' -CommandType Function -ErrorAction Stop) -w0 | & $nativeTee.Path $nativeCapturePath | Out-Null
        }
        catch { $nativeDownstreamError = $_ }
        $nativeCaptureEmpty = -not [IO.File]::Exists($nativeCapturePath) -or ([IO.FileInfo]$nativeCapturePath).Length -eq 0
        Assert-PshBatch2 ($null -ne $nativeDownstreamError -and [int]$nativeDownstreamError.Exception.Data['PshExitCode'] -eq 2 -and $nativeCaptureEmpty) 'base64 -w0 sent failure text or payload to a native downstream command.'
        # The expected native downstream failure must not become this test script's exit status.
        $global:LASTEXITCODE = 0
    }
    $base64Decode = Invoke-PshBatch2Command -Name base64 -Arguments @('-d') -PipelineInput @([Convert]::ToBase64String($smallBinary)) -UsePipeline
    Assert-PshBatch2 ($base64Decode.ExitCode -eq 0 -and (Test-PshByteSequence $base64Decode.RawBytes $smallBinary)) 'base64 binary decode/raw output failed.'
    $base64BinaryDownstream = Invoke-PshBatch2Command -Name base64 -Arguments @('-d') -PipelineInput @('AA==') -UsePipeline -UseDownstream
    Assert-PshBatch2 ($base64BinaryDownstream.ExitCode -eq 2) 'base64 -d allowed NUL output into the object pipeline.'
    $base64Invalid = Invoke-PshBatch2Command -Name base64 -Arguments @('-d') -PipelineInput @('not-base64!') -UsePipeline
    Assert-PshBatch2 ($base64Invalid.ExitCode -eq 3) 'base64 invalid input did not exit 3.'

    foreach ($name in $textCommandNames) {
        $bad = Invoke-PshBatch2Command -Name $name -Arguments @('--definitely-unsupported')
        Assert-PshBatch2 ($bad.ExitCode -eq 2) ('{0} silently accepted unsupported syntax.' -f $name)
    }
    $missingText = Invoke-PshBatch2Command -Name head -Arguments @((Join-Path $fixtureRoot 'missing.txt'))
    Assert-PshBatch2 ($missingText.ExitCode -eq 3) 'text file runtime failure did not exit 3.'

    $env:PSH_EDITION = 'Full'
    $missingBat = Invoke-PshBatch2Command -Name bat -Arguments @('--version')
    $missingRg = Invoke-PshBatch2Command -Name rg -Arguments @('--version')
    Assert-PshBatch2 ($missingBat.ExitCode -eq 4 -and $missingRg.ExitCode -eq 4) 'Full bat/rg missing dependencies did not exit 4.'
    $env:PSH_EDITION = 'Core'

    if (-not [string]::IsNullOrWhiteSpace($GoldenRoot)) {
        $goldenFixture = Join-Path $fixtureRoot 'golden'
        [void][IO.Directory]::CreateDirectory($goldenFixture)
        $goldenText = Join-Path $goldenFixture 'text.txt'
        $goldenCsv = Join-Path $goldenFixture 'data.csv'
        $goldenTextContent = "alpha`n`nbeta`nbeta`n10`n2`n"
        [IO.File]::WriteAllText($goldenText, $goldenTextContent, $utf8NoBom)
        [IO.File]::WriteAllText($goldenCsv, "one,two,three`nfour,five,six`n", $utf8NoBom)
        Compare-PshBatch2Golden -Id 'cat_ns' -Actual (Invoke-PshBatch2Command -Name cat -Arguments @('-ns', $goldenText)).Output
        Compare-PshBatch2Golden -Id 'head_n2' -Actual (Invoke-PshBatch2Command -Name head -Arguments @('-n', '2', $goldenText)).Output
        Compare-PshBatch2Golden -Id 'tail_n2' -Actual (Invoke-PshBatch2Command -Name tail -Arguments @('-n', '2', $goldenText)).Output
        Compare-PshBatch2Golden -Id 'cut_fields' -Actual (Invoke-PshBatch2Command -Name cut -Arguments @('-d,', '-f1,3', $goldenCsv)).Output
        Compare-PshBatch2Golden -Id 'tr_upper' -Actual (Invoke-PshBatch2Command -Name tr -Arguments @('a-z', 'A-Z') -PipelineInput @('alpha beta') -UsePipeline).Output
        Compare-PshBatch2Golden -Id 'sort_numeric' -Actual (Invoke-PshBatch2Command -Name sort -Arguments @('-n') -PipelineInput @('10', '2', '1') -UsePipeline).Output
        Compare-PshBatch2Golden -Id 'uniq_count' -Actual (Invoke-PshBatch2Command -Name uniq -Arguments @('-c') -PipelineInput @('a', 'a', 'b') -UsePipeline).Output
        Compare-PshBatch2Golden -Id 'wc_lw' -Actual (Invoke-PshBatch2Command -Name wc -Arguments @('-lw') -PipelineInput @($goldenTextContent) -UsePipeline).Output
        Compare-PshBatch2Golden -Id 'tee_text' -Actual (Invoke-PshBatch2Command -Name tee -Arguments @((Join-Path $goldenFixture 'tee.txt')) -PipelineInput @('tee golden') -UsePipeline).Output
        $printfGolden = Invoke-PshBatch2Command -Name printf -Arguments @('%s:%03d\n', 'value', '7')
        Compare-PshBatch2Golden -Id 'printf_format' -Actual @([Text.Encoding]::UTF8.GetString($printfGolden.RawBytes))
        Compare-PshBatch2Golden -Id 'echo_escape' -Actual (Invoke-PshBatch2Command -Name echo -Arguments @('-e', 'one\ttwo')).Output
        $base64Golden = Invoke-PshBatch2Command -Name base64 -Arguments @('-w0', $smallBinaryPath)
        Compare-PshBatch2Golden -Id 'base64_encode' -Actual @([Text.Encoding]::UTF8.GetString($base64Golden.RawBytes))
    }

    foreach ($name in $textCommandNames) {
        Assert-PshBatch2 ($covered.ContainsKey($name)) ('no behavior row executed for {0}.' -f $name)
    }

    Remove-Module -Name Psh -Force -ErrorAction Stop
    foreach ($name in $aliasNames) {
        Assert-PshBatch2 (Test-PshBatch2AliasSnapshot -Alias (Get-Alias -Name $name -ErrorAction SilentlyContinue) -Snapshot $aliasBaseline[$name]) ('Remove-Module did not restore {0} exactly.' -f $name)
    }

    $fullModuleRoot = Join-Path $testRoot 'full-module/Psh'
    [void][IO.Directory]::CreateDirectory((Split-Path $fullModuleRoot -Parent))
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/Psh') -Destination $fullModuleRoot -Recurse -Force
    $dependencyRoot = Join-Path $fullModuleRoot 'Dependencies'
    $nativeRoot = Join-Path $dependencyRoot 'native'
    [void][IO.Directory]::CreateDirectory($nativeRoot)
    $rgToolPath = Join-Path $nativeRoot 'rg-native.ps1'
    $batToolPath = Join-Path $nativeRoot 'bat-native.ps1'
    $toolTemplate = @'
$pipelineItems = @($input)
if ($args.Count -gt 0 -and $args[0] -ceq '--exit-one') { exit 1 }
$output = '__NAME__-native:' + ($args -join '|')
if ($pipelineItems.Count -gt 0) { $output += ':stdin=' + (($pipelineItems | ForEach-Object { [string]$_ }) -join '|') }
Write-Output $output
exit 0
'@
    [IO.File]::WriteAllText($rgToolPath, $toolTemplate.Replace('__NAME__', 'rg'), $utf8NoBom)
    [IO.File]::WriteAllText($batToolPath, $toolTemplate.Replace('__NAME__', 'bat'), $utf8NoBom)
    $lock = [ordered]@{
        Tools = @(
            [ordered]@{ Name = 'rg'; Path = 'native/rg-native.ps1'; Sha256 = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $rgToolPath -Algorithm SHA256).Hash }
            [ordered]@{ Name = 'bat'; Path = 'native/bat-native.ps1'; Sha256 = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $batToolPath -Algorithm SHA256).Hash }
        )
    }
    [IO.File]::WriteAllText((Join-Path $dependencyRoot 'native-tools.lock.json'), ($lock | ConvertTo-Json -Depth 5), $utf8NoBom)
    $env:PSH_EDITION = 'Full'
    Import-Module -Name (Join-Path $fullModuleRoot 'Psh.psd1') -Force -ErrorAction Stop
    $fullRg = Invoke-PshBatch2Command -Name rg -Arguments @('--native-only', 'value')
    $fullBat = Invoke-PshBatch2Command -Name bat -Arguments @('--native-only', 'value')
    $fullRgArguments = Invoke-PshBatch2Command -Name rg -Arguments @('--argv-check', '', 'space value', '--')
    $fullRgPipeline = Invoke-PshBatch2Command -Name rg -Arguments @('--stdin-check') -PipelineInput @('rg full stdin') -UsePipeline
    $fullBatPipeline = Invoke-PshBatch2Command -Name bat -Arguments @('--stdin-check') -PipelineInput @('bat full stdin') -UsePipeline
    $fullExitOne = Invoke-PshBatch2Command -Name rg -Arguments @('--exit-one')
    Assert-PshBatch2 ($fullRg.ExitCode -eq 0 -and $fullRg.Output[0] -eq 'rg-native:--native-only|value') ('Full rg did not transparently delegate complete native arguments (exit {0}, output <{1}>).' -f $fullRg.ExitCode, ($fullRg.Output -join '|'))
    Assert-PshBatch2 ($fullBat.ExitCode -eq 0 -and $fullBat.Output[0] -eq 'bat-native:--native-only|value') ('Full bat did not transparently delegate complete native arguments (exit {0}, output <{1}>).' -f $fullBat.ExitCode, ($fullBat.Output -join '|'))
    Assert-PshBatch2 ($fullRgArguments.ExitCode -eq 0 -and $fullRgArguments.Output[0] -eq 'rg-native:--argv-check||space value|--') 'Full rg did not preserve empty, spaced, or option-terminator arguments.'
    Assert-PshBatch2 ($fullRgPipeline.ExitCode -eq 0 -and $fullRgPipeline.Output[0] -eq 'rg-native:--stdin-check:stdin=rg full stdin') 'Full rg did not forward pipeline input to the pinned native tool.'
    Assert-PshBatch2 ($fullBatPipeline.ExitCode -eq 0 -and $fullBatPipeline.Output[0] -eq 'bat-native:--stdin-check:stdin=bat full stdin') 'Full bat did not forward pipeline input to the pinned native tool.'
    Assert-PshBatch2 ($fullExitOne.ExitCode -eq 1) 'Full rg did not preserve native exit 1.'
    [IO.File]::AppendAllText($batToolPath, "`n# checksum mismatch", $utf8NoBom)
    $fullMismatch = Invoke-PshBatch2Command -Name bat -Arguments @('--version')
    Assert-PshBatch2 ($fullMismatch.ExitCode -eq 5) 'Full bat checksum mismatch did not exit 5.'
    [IO.File]::Delete($rgToolPath)
    $fullMissing = Invoke-PshBatch2Command -Name rg -Arguments @('--version')
    Assert-PshBatch2 ($fullMissing.ExitCode -eq 4) 'Full rg missing dependency did not exit 4.'
    Remove-Module -Name Psh -Force -ErrorAction Stop

    $env:PSH_EDITION = 'Core'
    $configDirectory = Join-Path $configRoot 'Psh'
    [void][IO.Directory]::CreateDirectory($configDirectory)
    $configText = "@{`n    SchemaVersion = 1`n    Edition = 'Core'`n    DisabledCommands = @('echo')`n}`n"
    [IO.File]::WriteAllText((Join-Path $configDirectory 'config.psd1'), $configText, $utf8NoBom)
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    Assert-PshBatch2 ($null -eq (Get-Command -Name 'Psh\echo' -ErrorAction SilentlyContinue)) 'DisabledCommands did not suppress Psh echo export.'
    $fallbackEcho = Get-Command -Name echo -ErrorAction Stop
    Assert-PshBatch2 ($fallbackEcho.CommandType -eq 'Alias' -and [string]$fallbackEcho.Definition -ceq [string]$aliasBaseline.echo.Definition) 'Disabled Psh echo did not fall through to the original alias.'

    Write-Output ('Goal 3 Batch 2 text-command acceptance passed: 15 commands, {0} assertions, text/raw-byte paths, Tier 2 search flags, Core/Full delegation, and object APIs{1}.' -f $assertionCount, $(if ([string]::IsNullOrWhiteSpace($GoldenRoot)) { '' } else { ', with GNU golden comparisons' }))
}
finally {
    Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name PshBatch2PrintfValue -Scope Global -Force -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:PSH_EDITION = $originalEdition
    foreach ($name in $aliasNames) {
        $snapshot = $aliasBaseline[$name]
        $current = Get-Alias -Name $name -ErrorAction SilentlyContinue
        if (-not $snapshot.Exists) {
            if ($null -ne $current) { Remove-Item -LiteralPath ('Alias:{0}' -f $name) -Force -ErrorAction SilentlyContinue }
        }
        elseif (-not (Test-PshBatch2AliasSnapshot -Alias $current -Snapshot $snapshot)) {
            Remove-Item -LiteralPath ('Alias:{0}' -f $name) -Force -ErrorAction SilentlyContinue
            Set-Alias -Name $name -Value ([string]$snapshot.Definition) -Description ([string]$snapshot.Description) -Option $snapshot.Options -Scope Global -Force
            (Get-Alias -Name $name -Scope Global -ErrorAction Stop).Visibility = $snapshot.Visibility
        }
    }
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}

# GitHub's PowerShell shell propagates a leftover native status after a successful script.
$global:LASTEXITCODE = 0
