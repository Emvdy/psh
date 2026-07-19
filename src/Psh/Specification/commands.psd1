# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

@{
    SchemaVersion = '1.1'
    PshVersion = '0.1.0'

    CommandTiers = @(
        @{
            Tier = 1
            Name = 'Full common semantics'
            Description = 'Implements the common behavior represented by the documented flags.'
            Validation = 'Tier 1 text commands use normalized GNU golden output; platform-shaped commands use structural assertions.'
        }
        @{
            Tier = 2
            Name = 'Documented subset'
            Description = 'Core implements the documented subset; PowerShell-backed Full commands use the same subset, while Full native rg, fd, jq, and bat accept each pinned tool''s complete argument set.'
            Validation = 'Core and PowerShell-backed Full commands reject unsupported syntax with exit code 2; Full native commands follow their pinned tools'' argument contracts.'
        }
        @{
            Tier = 3
            Name = 'Thin wrapper'
            Description = 'Provides a thin PowerShell wrapper around the corresponding host capability.'
            Validation = 'Structural smoke tests verify the wrapper contract on each supported host.'
        }
    )

    NameCollisionPolicy = @{
        ResolutionOrder = @('Psh function', 'built-in alias', 'native executable')
        DisableConfigKey = 'DisabledCommands'
        DefaultDisabledCommands = @()
        ConfigSyntax = @(
            'psh config get [DisabledCommands]'
            'psh config set DisabledCommands <command> [<command>...]'
            'psh config reset DisabledCommands'
            'psh config --help'
        )
        ConfigPath = '%LOCALAPPDATA%\Psh\config.psd1'
        InstalledConfigFallback = 'When the canonical file does not exist and the module is loaded from <installRoot>\versions\<version>\Psh, an existing <installRoot>\config.psd1 is used. Arbitrary ancestor config.psd1 files are never scanned.'
        ConfigSummary = 'DisabledCommands is the only mutable key in v0.1.0. set replaces the complete list, reset restores the empty default, and names are validated case-insensitively against all 64 Psh commands before an atomic write.'
        Activation = 'Changes are persisted only and take effect in a new shell or after Remove-Module Psh; Import-Module Psh.'
        DisableCommandExample = 'psh config set DisabledCommands curl wget'
        ResetCommandExample = 'psh config reset DisabledCommands'
        Summary = 'Psh functions win while enabled; disabling an individual command restores normal alias-first PowerShell resolution.'
    }

    ExitCodes = @(
        @{
            Code = 0
            Name = 'Success'
            Description = 'The command completed successfully.'
        }
        @{
            Code = 1
            Name = 'NoMatch'
            Description = 'The command completed but found no matching result.'
        }
        @{
            Code = 2
            Name = 'UsageError'
            Description = 'The arguments or requested syntax are unsupported or invalid.'
        }
        @{
            Code = 3
            Name = 'RuntimeError'
            Description = 'The command failed while performing the requested operation.'
        }
        @{
            Code = 4
            Name = 'MissingDependency'
            Description = 'A required dependency or active backend is unavailable.'
        }
        @{
            Code = 5
            Name = 'IntegrityFailure'
            Description = 'A package, dependency, or generated artifact failed integrity validation.'
        }
    )

    Editions = @(
        @{
            Name = 'Core'
            Summary = 'PowerShell implementations only; no third-party utility executables.'
            NativeTools = @()
        }
        @{
            Name = 'Full'
            Summary = 'Core plus pinned native ripgrep, fd, jq, and bat executables.'
            NativeTools = @('rg', 'fd', 'jq', 'bat')
        }
    )

    ObjectApis = @(
        @{
            Name = 'Find-PshText'
            Commands = @('grep', 'rg')
            Summary = 'Returns structured text-search matches.'
        }
        @{
            Name = 'Find-PshItem'
            Commands = @('find', 'fd')
            Summary = 'Returns structured file-system search results.'
        }
        @{
            Name = 'Select-PshJson'
            Commands = @('jq')
            Summary = 'Returns objects selected by the Core jq expression subset.'
        }
        @{
            Name = 'Get-PshHead'
            Commands = @('head')
            Summary = 'Returns leading records or bytes without text formatting.'
        }
        @{
            Name = 'Get-PshTail'
            Commands = @('tail')
            Summary = 'Returns trailing records or bytes without text formatting.'
        }
        @{
            Name = 'Measure-PshText'
            Commands = @('wc')
            Summary = 'Returns structured line, word, character, and byte counts.'
        }
        @{
            Name = 'Set-PshFileTime'
            Commands = @('touch')
            Summary = 'Creates files or updates their access and modification times.'
        }
        @{
            Name = 'Invoke-PshXArgs'
            Commands = @('xargs')
            Summary = 'Invokes commands with argument arrays and without expression evaluation.'
        }
    )

    ManagementCommands = @(
        @{
            Name = 'version'
            Summary = 'Show the installed Psh version and edition.'
            SupportsJson = $false
            Flags = @('--help')
            ExitCodes = @(0, 2, 3)
            Examples = @('psh version')
        }
        @{
            Name = 'doctor'
            Summary = 'Validate installation, configuration, profiles, and active backends.'
            SupportsJson = $true
            Flags = @('--json', '--help')
            ExitCodes = @(0, 2, 3, 4, 5)
            Examples = @('psh doctor', 'psh doctor --json')
        }
        @{
            Name = 'capabilities'
            Summary = 'List commands, object APIs, editions, and active backends.'
            SupportsJson = $true
            Flags = @('--json', '--help')
            ExitCodes = @(0, 2, 3, 4, 5)
            Examples = @('psh capabilities --json')
        }
        @{
            Name = 'commands'
            Summary = 'List compatible command names and their categories.'
            SupportsJson = $false
            Flags = @('--category', '--name', '--help')
            ExitCodes = @(0, 1, 2, 3)
            Examples = @('psh commands', 'psh commands --category text')
        }
        @{
            Name = 'config'
            Summary = 'Read, set, or reset current-user Psh configuration.'
            SupportsJson = $false
            Flags = @('get', 'set', 'reset', '--help')
            ExitCodes = @(0, 1, 2, 3)
            Examples = @('psh config get', 'psh config get DisabledCommands', 'psh config set DisabledCommands curl wget', 'psh config reset DisabledCommands')
        }
        @{
            Name = 'update'
            Summary = 'Install and atomically activate a verified Psh version.'
            SupportsJson = $false
            Flags = @('--version', '--edition', '--non-interactive', '--help')
            ExitCodes = @(0, 2, 3, 4, 5)
            Examples = @('psh update', 'psh update --version 0.1.0 --edition Full')
        }
        @{
            Name = 'rollback'
            Summary = 'Atomically reactivate a retained previous Psh version.'
            SupportsJson = $false
            Flags = @('--version', '--non-interactive', '--help')
            ExitCodes = @(0, 1, 2, 3, 5)
            Examples = @('psh rollback')
        }
        @{
            Name = 'self-test'
            Summary = 'Run local command and installation health checks.'
            SupportsJson = $false
            Flags = @('--quick', '--help')
            ExitCodes = @(0, 2, 3, 4, 5)
            Examples = @('psh self-test', 'psh self-test --quick')
        }
        @{
            Name = 'uninstall'
            Summary = 'Remove Psh-owned files and restore backed-up profile content.'
            SupportsJson = $false
            Flags = @('--keep-config', '--non-interactive', '--help')
            ExitCodes = @(0, 2, 3, 5)
            Examples = @('psh uninstall')
        }
    )

    Commands = @(
        @{
            Name = 'pwd'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:pwd')
            CollisionNotes = 'Shadows the built-in pwd alias; disabling this Psh command restores alias resolution.'
            Category = 'Files and search'
            Summary = 'Print the current working directory.'
            Flags = @('-L', '-P', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('pwd', 'pwd -P')
        }
        @{
            Name = 'cd'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:cd')
            CollisionNotes = 'Shadows the built-in cd alias; disabling this Psh command restores alias resolution.'
            Category = 'Files and search'
            Summary = 'Change the current working directory.'
            Flags = @('-L', '-P', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('cd src', 'cd -P ..')
        }
        @{
            Name = 'ls'
            Tier = 1
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:ls')
            CollisionNotes = 'Shadows the built-in ls alias; disabling this Psh command restores alias resolution.'
            Category = 'Files and search'
            Summary = 'List directory entries.'
            Flags = @('-a', '-l', '-h', '-R', '-1', '-d', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('ls -la', 'ls -R src')
        }
        @{
            Name = 'mkdir'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Files and search'
            Summary = 'Create directories.'
            Flags = @('-p', '-v', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('mkdir -p build/output')
        }
        @{
            Name = 'rmdir'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:rmdir')
            CollisionNotes = 'Shadows the built-in rmdir alias; disabling this Psh command restores alias resolution.'
            Category = 'Files and search'
            Summary = 'Remove empty directories.'
            Flags = @('-p', '-v', '--ignore-fail-on-non-empty', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('rmdir -p empty/child')
        }
        @{
            Name = 'cp'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:cp')
            CollisionNotes = 'Shadows the built-in cp alias; disabling this Psh command restores alias resolution.'
            Category = 'Files and search'
            Summary = 'Copy files and directories.'
            Flags = @('-R', '-r', '-f', '-n', '-u', '-v', '-p', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('cp -R src backup', 'cp -n input.txt output.txt')
        }
        @{
            Name = 'mv'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:mv')
            CollisionNotes = 'Shadows the built-in mv alias; disabling this Psh command restores alias resolution.'
            Category = 'Files and search'
            Summary = 'Move or rename files and directories.'
            Flags = @('-f', '-n', '-u', '-v', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('mv -n old.txt new.txt')
        }
        @{
            Name = 'rm'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:rm')
            CollisionNotes = 'Shadows the built-in rm alias; disabling this Psh command restores alias resolution.'
            Category = 'Files and search'
            Summary = 'Remove files or directories while refusing drive roots and the home directory.'
            Flags = @('-R', '-r', '-f', '-v', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('rm file.txt', 'rm -r temporary-directory')
        }
        @{
            Name = 'touch'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Files and search'
            Summary = 'Create files or update file timestamps.'
            Flags = @('-a', '-m', '-c', '-r', '-t', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = 'Set-PshFileTime'
            Examples = @('touch output.txt', 'touch -r source.txt target.txt')
        }
        @{
            Name = 'ln'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Files and search'
            Summary = 'Create hard links or symbolic links.'
            Flags = @('-s', '-f', '-n', '-v', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('ln source.txt target.txt', 'ln -s target link')
        }
        @{
            Name = 'realpath'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Files and search'
            Summary = 'Print a normalized absolute path.'
            Flags = @('-e', '-m', '--relative-to', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('realpath .', 'realpath -m missing/../path')
        }
        @{
            Name = 'basename'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Files and search'
            Summary = 'Print the final component of a path.'
            Flags = @('-a', '-s', '-z', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('basename src/file.txt .txt')
        }
        @{
            Name = 'dirname'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Files and search'
            Summary = 'Print the directory component of a path.'
            Flags = @('-z', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('dirname src/file.txt')
        }
        @{
            Name = 'stat'
            Tier = 2
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Files and search'
            Summary = 'Display file or file-system status.'
            Flags = @('-c', '-f', '-L', '-t', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('stat file.txt', 'stat -c %s file.txt')
        }
        @{
            Name = 'file'
            Tier = 2
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Files and search'
            Summary = 'Classify files using content and extension checks.'
            Flags = @('-b', '-i', '-L', '-z', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('file archive.zip', 'file -i data.json')
        }
        @{
            Name = 'tree'
            Tier = 2
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @('native:tree.com')
            CollisionNotes = 'Shadows Windows tree.com; disabling this Psh command exposes native executable resolution.'
            Category = 'Files and search'
            Summary = 'Render a directory hierarchy as text.'
            Flags = @('-a', '-d', '-f', '-L', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('tree -L 2 .')
        }
        @{
            Name = 'find'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @('native:find.exe')
            CollisionNotes = 'Shadows Windows find.exe; disabling this Psh command exposes native executable resolution.'
            Category = 'Files and search'
            Summary = 'Search directory trees by name, type, depth, size, and time.'
            Flags = @('-name', '-iname', '-type', '-mindepth', '-maxdepth', '-size', '-mtime', '-mmin', '--hidden', '--exclude', '-print', '-print0', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = 'Find-PshItem'
            Examples = @('find . -name *.ps1 -type f', 'find . --hidden --exclude .git -print0')
        }
        @{
            Name = 'fd'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core implements the documented PowerShell subset; unsupported syntax exits 2. Full delegates to pinned native fd and accepts its complete argument set.'
            CollisionTargets = @('native:fd.exe')
            CollisionNotes = 'The Psh function remains public and delegates internally to pinned fd.exe in Full; disabling it exposes native executable resolution.'
            Category = 'Files and search'
            Summary = 'Search for file-system entries using the Core subset or native fd in Full.'
            Flags = @('-e', '-g', '--glob', '-t', '--type', '-d', '--max-depth', '--min-depth', '-S', '--size', '--changed-before', '--changed-within', '-H', '--hidden', '-E', '--exclude', '-0', '--print0', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'native:fd'
            ObjectApi = 'Find-PshItem'
            Examples = @('fd -e ps1 src', 'fd --hidden --exclude .git -0')
        }
        @{
            Name = 'du'
            Tier = 2
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Files and search'
            Summary = 'Estimate file and directory space usage.'
            Flags = @('-a', '-h', '-s', '-d', '--max-depth', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('du -sh .', 'du --max-depth 1')
        }
        @{
            Name = 'df'
            Tier = 2
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Files and search'
            Summary = 'Report file-system capacity and free space.'
            Flags = @('-h', '-T', '--total', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('df -h')
        }
        @{
            Name = 'mktemp'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Files and search'
            Summary = 'Create a temporary file or directory with a unique name.'
            Flags = @('-d', '-u', '-p', '--tmpdir', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('mktemp', 'mktemp -d')
        }

        @{
            Name = 'cat'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:cat')
            CollisionNotes = 'Shadows the built-in cat alias; disabling this Psh command restores alias resolution.'
            Category = 'Text and data'
            Summary = 'Concatenate files and write their content as text.'
            Flags = @('-n', '-b', '-s', '-A', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('cat file.txt', 'cat -n one.txt two.txt')
        }
        @{
            Name = 'bat'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core implements the documented PowerShell subset; unsupported syntax exits 2. Full delegates to pinned native bat and accepts its complete argument set.'
            CollisionTargets = @('native:bat.exe')
            CollisionNotes = 'The Psh function remains public and delegates internally to pinned bat.exe in Full; disabling it exposes native executable resolution.'
            Category = 'Text and data'
            Summary = 'Display files using the Core subset or native bat in Full.'
            Flags = @('-n', '-p', '-A', '-l', '--style', '--color', '--paging', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'native:bat'
            ObjectApi = ''
            Examples = @('bat -n file.ps1', 'bat --style plain data.txt')
        }
        @{
            Name = 'head'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Write the beginning of files or input.'
            Flags = @('-n', '-c', '-q', '-v', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = 'Get-PshHead'
            Examples = @('head -n 5 file.txt')
        }
        @{
            Name = 'tail'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Write the end of files or input.'
            Flags = @('-n', '-c', '-f', '-q', '-v', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = 'Get-PshTail'
            Examples = @('tail -n 20 log.txt', 'tail -f log.txt')
        }
        @{
            Name = 'grep'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Search text using literal or regular-expression patterns.'
            Flags = @('-i', '-v', '-n', '-r', '-l', '-c', '-m', '-A', '-B', '-C', '-E', '-F', '-q', '--include', '--exclude', '--hidden', '--glob', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = 'Find-PshText'
            Examples = @('grep -n error log.txt', 'grep -r --include *.ps1 TODO src')
        }
        @{
            Name = 'rg'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core implements the documented PowerShell subset; unsupported syntax exits 2. Full delegates to pinned native rg and accepts its complete argument set.'
            CollisionTargets = @('native:rg.exe')
            CollisionNotes = 'The Psh function remains public and delegates internally to pinned rg.exe in Full; disabling it exposes native executable resolution.'
            Category = 'Text and data'
            Summary = 'Search text using the Core subset or native ripgrep in Full.'
            Flags = @('-i', '-v', '-n', '-r', '-l', '-c', '-m', '-A', '-B', '-C', '-E', '-F', '-q', '--include', '--exclude', '--hidden', '--glob', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'native:rg'
            ObjectApi = 'Find-PshText'
            Examples = @('rg -n TODO src', 'rg --hidden --glob !.git/** pattern')
        }
        @{
            Name = 'sed'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Apply the supported address, substitution, delete, print, and quit subset.'
            Flags = @('-e', '-n', '-i', '-E', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('sed -e s/old/new/g file.txt', 'sed -n 1,5p file.txt')
        }
        @{
            Name = 'awk'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Run the supported fields, records, matching, printing, and aggregation subset.'
            Flags = @('-F', '-v', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('awk -F , {print $1} data.csv', 'awk {sum += $1} END {print sum} values.txt')
        }
        @{
            Name = 'jq'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core implements the documented PowerShell subset; unsupported syntax exits 2. Full delegates to pinned native jq and accepts its complete argument set.'
            CollisionTargets = @('native:jq.exe')
            CollisionNotes = 'The Psh function remains public and delegates internally to pinned jq.exe in Full; disabling it exposes native executable resolution.'
            Category = 'Text and data'
            Summary = 'Select JSON using the Core subset or native jq in Full.'
            Flags = @('-r', '-c', '-e', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'native:jq'
            ObjectApi = 'Select-PshJson'
            Examples = @('jq -r .name data.json', 'jq .items[] data.json')
        }
        @{
            Name = 'cut'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Select bytes, characters, or delimited fields from text.'
            Flags = @('-b', '-c', '-f', '-d', '-s', '--complement', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('cut -d , -f 1 data.csv')
        }
        @{
            Name = 'tr'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Translate, delete, or squeeze characters.'
            Flags = @('-c', '-d', '-s', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('tr a-z A-Z', 'tr -d 0-9')
        }
        @{
            Name = 'sort'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:sort', 'native:sort.exe')
            CollisionNotes = 'Shadows the built-in sort alias and Windows sort.exe; disabling it restores alias-first resolution.'
            Category = 'Text and data'
            Summary = 'Sort lines of text.'
            Flags = @('-b', '-f', '-n', '-r', '-u', '-k', '-t', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('sort -n values.txt', 'sort -t , -k 2 data.csv')
        }
        @{
            Name = 'uniq'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Report or omit adjacent repeated lines.'
            Flags = @('-c', '-d', '-u', '-i', '-f', '-s', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('uniq -c sorted.txt')
        }
        @{
            Name = 'wc'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Count bytes, characters, lines, and words.'
            Flags = @('-c', '-l', '-m', '-w', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = 'Measure-PshText'
            Examples = @('wc -l file.txt', 'wc -w one.txt two.txt')
        }
        @{
            Name = 'tee'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:tee')
            CollisionNotes = 'Shadows the built-in tee alias; disabling this Psh command restores alias resolution.'
            Category = 'Text and data'
            Summary = 'Copy input to standard output and files.'
            Flags = @('-a', '-i', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('tee output.txt', 'tee -a log.txt')
        }
        @{
            Name = 'xargs'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Build and invoke command argument arrays from input.'
            Flags = @('-0', '-n', '-I', '-P', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = 'Invoke-PshXArgs'
            Examples = @('xargs -n 1 echo', 'xargs -0 -I {} rm {}')
        }
        @{
            Name = 'printf'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Format and write text values.'
            Flags = @('-v', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('printf %s\\n value')
        }
        @{
            Name = 'echo'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:echo')
            CollisionNotes = 'Shadows the built-in echo alias; disabling this Psh command restores alias resolution.'
            Category = 'Text and data'
            Summary = 'Write arguments as a line of text.'
            Flags = @('-n', '-e', '-E', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('echo hello', 'echo -n value')
        }
        @{
            Name = 'base64'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Text and data'
            Summary = 'Encode or decode Base64 data.'
            Flags = @('-d', '--decode', '-w', '--wrap', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('base64 file.bin', 'base64 -d encoded.txt')
        }

        @{
            Name = 'which'
            Tier = 1
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Environment and processes'
            Summary = 'Locate commands that would be invoked.'
            Flags = @('-a', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('which pwsh', 'which -a git')
        }
        @{
            Name = 'env'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Environment and processes'
            Summary = 'Display the environment or run a command with modified variables.'
            Flags = @('-i', '-u', '-0', '--ignore-environment', '--unset', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('env', 'env -u TEMP printenv')
        }
        @{
            Name = 'printenv'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Environment and processes'
            Summary = 'Print environment variable values.'
            Flags = @('-0', '--null', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('printenv PATH')
        }
        @{
            Name = 'export'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Environment and processes'
            Summary = 'Set or display environment variables in the current session.'
            Flags = @('-p', '-n', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('export NAME=value', 'export -p')
        }
        @{
            Name = 'test'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Environment and processes'
            Summary = 'Evaluate file, string, and numeric conditions.'
            Flags = @('-e', '-f', '-d', '-r', '-w', '-x', '-s', '-L', '-n', '-z', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('test -f file.txt', 'test -n value')
        }
        @{
            Name = 'ps'
            Tier = 2
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @('alias:ps')
            CollisionNotes = 'Shadows the built-in ps alias; disabling this Psh command restores alias resolution.'
            Category = 'Environment and processes'
            Summary = 'Report process information.'
            Flags = @('-a', '-e', '-f', '-l', '-p', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('ps -ef', 'ps -p 1234')
        }
        @{
            Name = 'kill'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @('alias:kill')
            CollisionNotes = 'Shadows the built-in kill alias; disabling this Psh command restores alias resolution.'
            Category = 'Environment and processes'
            Summary = 'Send a supported termination signal to processes.'
            Flags = @('-s', '-l', '--signal', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('kill 1234', 'kill -s TERM 1234')
        }
        @{
            Name = 'pgrep'
            Tier = 2
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Environment and processes'
            Summary = 'Find process identifiers by name or command pattern.'
            Flags = @('-f', '-i', '-l', '-n', '-o', '-u', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('pgrep -l pwsh')
        }
        @{
            Name = 'pkill'
            Tier = 2
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Environment and processes'
            Summary = 'Terminate processes selected by name or command pattern.'
            Flags = @('-f', '-i', '-n', '-o', '-u', '-s', '--signal', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('pkill -f worker.ps1')
        }
        @{
            Name = 'timeout'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @('native:timeout.exe')
            CollisionNotes = 'Shadows Windows timeout.exe; disabling this Psh command exposes native executable resolution.'
            Category = 'Environment and processes'
            Summary = 'Run a command with a time limit.'
            Flags = @('-s', '-k', '--signal', '--kill-after', '--preserve-status', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('timeout 10s pwsh -File task.ps1')
        }
        @{
            Name = 'sleep'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @('alias:sleep')
            CollisionNotes = 'Shadows the built-in sleep alias; disabling this Psh command restores alias resolution.'
            Category = 'Environment and processes'
            Summary = 'Delay for a specified duration.'
            Flags = @('--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('sleep 1.5', 'sleep 250ms')
        }

        @{
            Name = 'curl'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @('alias:curl', 'native:curl.exe')
            CollisionNotes = 'Shadows the Windows PowerShell curl alias and Windows curl.exe; disabling it restores alias-first resolution.'
            Category = 'Network and archives'
            Summary = 'Transfer data from or to a URL.'
            Flags = @('-f', '-L', '-o', '-O', '-s', '-S', '-I', '-X', '-H', '-d', '--data', '--connect-timeout', '--max-time', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('curl -fL -o file.zip https://example.invalid/file.zip')
        }
        @{
            Name = 'wget'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @('alias:wget')
            CollisionNotes = 'Shadows the Windows PowerShell wget alias; disabling this Psh command restores alias resolution.'
            Category = 'Network and archives'
            Summary = 'Download content from a URL to a file or standard output.'
            Flags = @('-O', '-q', '-c', '-S', '--timeout', '--header', '--method', '--body-data', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('wget -O file.zip https://example.invalid/file.zip')
        }
        @{
            Name = 'tar'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @('native:tar.exe')
            CollisionNotes = 'Shadows Windows tar.exe; disabling this Psh command exposes native executable resolution.'
            Category = 'Network and archives'
            Summary = 'Create, list, or extract tar archives.'
            Flags = @('-c', '-x', '-t', '-f', '-C', '-z', '-v', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('tar -cf archive.tar src', 'tar -xf archive.tar -C output')
        }
        @{
            Name = 'zip'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Network and archives'
            Summary = 'Create or update ZIP archives.'
            Flags = @('-r', '-q', '-j', '-u', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('zip -r archive.zip src')
        }
        @{
            Name = 'unzip'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Network and archives'
            Summary = 'List or extract ZIP archives.'
            Flags = @('-l', '-o', '-n', '-d', '-q', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('unzip archive.zip -d output', 'unzip -l archive.zip')
        }
        @{
            Name = 'gzip'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Network and archives'
            Summary = 'Compress or decompress files using gzip.'
            Flags = @('-c', '-d', '-f', '-k', '-n', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('gzip -k file.txt', 'gzip -dc file.gz')
        }
        @{
            Name = 'gunzip'
            Tier = 2
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same documented PowerShell subset; unsupported syntax exits 2.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Network and archives'
            Summary = 'Decompress gzip files.'
            Flags = @('-c', '-f', '-k', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('gunzip -k file.gz')
        }
        @{
            Name = 'sha256sum'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Network and archives'
            Summary = 'Compute or verify SHA-256 checksums.'
            Flags = @('-c', '-b', '-t', '-z', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('sha256sum package.zip', 'sha256sum -c SHA256SUMS')
        }
        @{
            Name = 'md5sum'
            Tier = 1
            PlatformShaped = $false
            EditionNotes = 'Core and Full use the same PowerShell implementation with full common semantics.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Network and archives'
            Summary = 'Compute or verify MD5 checksums for compatibility use.'
            Flags = @('-c', '-b', '-t', '-z', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('md5sum file.bin', 'md5sum -c MD5SUMS')
        }
        @{
            Name = 'date'
            Tier = 3
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same thin PowerShell wrapper.'
            CollisionTargets = @()
            CollisionNotes = 'No default PowerShell alias or Windows executable collision is documented.'
            Category = 'Network and archives'
            Summary = 'Display or format date and time values.'
            Flags = @('-u', '-R', '-I', '-d', '--date', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('date -I', 'date -u +%Y-%m-%dT%H:%M:%SZ')
        }
        @{
            Name = 'whoami'
            Tier = 3
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same thin PowerShell wrapper.'
            CollisionTargets = @('native:whoami.exe')
            CollisionNotes = 'Shadows Windows whoami.exe; disabling this Psh command exposes native executable resolution.'
            Category = 'Network and archives'
            Summary = 'Print the current user identity.'
            Flags = @('--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('whoami')
        }
        @{
            Name = 'hostname'
            Tier = 3
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same thin PowerShell wrapper.'
            CollisionTargets = @('native:hostname.exe')
            CollisionNotes = 'Shadows Windows hostname.exe; disabling this Psh command exposes native executable resolution.'
            Category = 'Network and archives'
            Summary = 'Print host name information.'
            Flags = @('-f', '-s', '-i', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('hostname', 'hostname -s')
        }
        @{
            Name = 'clear'
            Tier = 3
            PlatformShaped = $true
            EditionNotes = 'Core and Full use the same thin PowerShell wrapper.'
            CollisionTargets = @('alias:clear')
            CollisionNotes = 'Shadows the built-in clear alias; disabling this Psh command restores alias resolution.'
            Category = 'Network and archives'
            Summary = 'Clear the terminal display.'
            Flags = @('-x', '--help')
            ExitCodes = @(0, 1, 2, 3, 4, 5)
            CoreBackend = 'powershell'
            FullBackend = 'powershell'
            ObjectApi = ''
            Examples = @('clear')
        }
    )
}
