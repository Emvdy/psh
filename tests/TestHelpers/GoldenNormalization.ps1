# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version 2.0

function ConvertTo-PshGoldenNormalizedText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [string] $Text,

        [Parameter()]
        [AllowNull()]
        [string] $PathRoot,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $PathToken = '<ROOT>'
    )

    if ($null -eq $Text) { $Text = '' }
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n").Replace('\', '/')
    if (-not [string]::IsNullOrWhiteSpace($PathRoot)) {
        $normalizedRoot = [IO.Path]::GetFullPath($PathRoot).Replace('\', '/').TrimEnd('/')
        $normalized = $normalized.Replace($normalizedRoot, $PathToken)
    }
    if ($normalized.EndsWith("`n", [StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 1)
    }
    return $normalized
}

function Test-PshGoldenOrdinalEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [string] $Left,

        [Parameter()]
        [AllowNull()]
        [string] $Right
    )

    return [string]::Equals($Left, $Right, [StringComparison]::Ordinal)
}

function ConvertTo-PshGoldenOrdinalOrder {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [string[]] $Value
    )

    [string[]] $sorted = @()
    if ($null -ne $Value) { $sorted = [string[]]$Value.Clone() }
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return $sorted
}
