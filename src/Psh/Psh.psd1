# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

@{
    RootModule = 'Psh.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'baf0d32a-4b5d-4b95-9d5f-fb0a65a5e40d'
    Author = 'Emvdy'
    CompanyName = 'Emvdy'
    Copyright = '(c) 2026 Emvdy. Licensed under GPL-3.0-or-later.'
    Description = 'A focused Bash-style command compatibility layer for Windows PowerShell.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    ScriptsToProcess = @('Commands/Project-FileCommands.ps1')
    FunctionsToExport = @(
        'psh'
        'Get-PshCapabilities'
        'Get-PshCommandSpecification'
        'Initialize-PshInteractive'
        'Find-PshItem'
        'Set-PshFileTime'
        'Find-PshText'
        'Get-PshHead'
        'Get-PshTail'
        'Measure-PshText'
        'Select-PshJson'
        'Invoke-PshXArgs'
        'pwd'
        'cd'
        'ls'
        'mkdir'
        'rmdir'
        'cp'
        'mv'
        'rm'
        'touch'
        'ln'
        'realpath'
        'basename'
        'dirname'
        'stat'
        'file'
        'tree'
        'find'
        'fd'
        'du'
        'df'
        'mktemp'
        'cat'
        'bat'
        'head'
        'tail'
        'grep'
        'rg'
        'sed'
        'awk'
        'jq'
        'cut'
        'tr'
        'sort'
        'uniq'
        'wc'
        'tee'
        'xargs'
        'printf'
        'echo'
        'base64'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            LicenseUri = 'https://www.gnu.org/licenses/gpl-3.0.html'
            ProjectUri = 'https://github.com/Emvdy/psh'
            Tags = @('PowerShell', 'Bash', 'compatibility', 'Windows')
        }
    }
}
