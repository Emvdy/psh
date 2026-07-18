<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# PowerShell Profile Management

Psh manages only a small loader block in the current user's all-host profiles.
It does not own, replace, or evaluate the rest of a profile.

## Targets

With no `-ProfilePath` argument, both CurrentUserAllHosts locations are resolved
from the current user's redirected Documents known folder:

```text
<Documents>\WindowsPowerShell\profile.ps1
<Documents>\PowerShell\profile.ps1
```

The first target is used by Windows PowerShell 5.1 and the second by PowerShell
7. An explicit literal array can be supplied by an installer or isolated test:

```powershell
& .\Install-PshProfile.ps1 -ProfilePath @($windowsProfile, $pwshProfile)
& .\Uninstall-PshProfile.ps1 -ProfilePath @($windowsProfile, $pwshProfile)
```

Duplicate targets, directories, reparse-point files, invalid paths, and targets
inside the Psh profile-state directory are rejected before any profile write.

## Managed Block

The marker text and loader body are fixed. Each marker occupies its own exact
line:

```powershell
# >>> Psh managed profile >>>
$null = & {
    try {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            return
        }
        $pshBootstrap = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Psh\bootstrap.ps1'
        if (-not (Test-Path -LiteralPath $pshBootstrap -PathType Leaf)) {
            return
        }
        . $pshBootstrap
        if ($null -ne (Get-Command -Name Initialize-PshInteractive -CommandType Function -ErrorAction Ignore)) {
            $pshInteractive = Initialize-PshInteractive -EnablePrompt
            if ($null -eq $pshInteractive -or -not [bool]$pshInteractive.success) {
                $pshInteractiveError = @($pshInteractive.errors) -join '; '
                if ([string]::IsNullOrWhiteSpace($pshInteractiveError)) {
                    $pshInteractiveError = 'unknown failure'
                }
                Write-Warning ('Psh interactive initialization reported a failure: {0}' -f $pshInteractiveError) -WarningAction Continue
            }
        }
        else {
            Write-Warning 'Psh bootstrap loaded, but Initialize-PshInteractive is unavailable.' -WarningAction Continue
        }
    }
    catch {
        Write-Warning ('Psh interactive initialization failed: {0}' -f $_.Exception.Message) -WarningAction Continue
    }
}
# <<< Psh managed profile <<<
```

A missing bootstrap is a quiet no-op. A successful initialization emits no
startup object or setup text. A present bootstrap that fails to load, does not
expose `Initialize-PshInteractive`, throws, or returns `success = false`
produces one concise warning and lets shell startup continue. The loader
performs no download and does not change execution policy, GPO, or `PATH`.
It runs bootstrap and initialization in a child scope, so bootstrap strict mode,
preference variables, and temporary names cannot leak into or overwrite the
user's profile scope. Module import remains global by explicit bootstrap design.
Loader warnings explicitly continue even when earlier profile content set
`$WarningPreference` to `Stop`.

Install is idempotent only when the existing block is canonical and its backup
metadata is trusted. A marked block with modified content is a conflict, not an
invitation to overwrite it.

## Byte Preservation And State

Existing bytes are read before any write. UTF-8 (with or without BOM), UTF-16,
UTF-32, and a losslessly round-trippable system Windows ANSI encoding are
supported. PowerShell 7 reads that code page from the Windows API rather than
using .NET's UTF-8 `Encoding.Default` value.
The original BOM and every pre-existing byte, including CRLF/LF choice and an
empty file, are retained in the backup. A file that cannot be decoded and
encoded losslessly is rejected.

Profile state defaults to:

```text
%LOCALAPPDATA%\Psh\profile-state\
|-- manifest.json
`-- backups\
    `-- <sha256-of-normalized-profile-path>.bin
```

`manifest.json` is UTF-8 without BOM and records schema/product identifiers,
the normalized absolute profile path, the path-derived profile ID, the derived
backup filename, whether the profile originally existed, original length and
SHA-256, and the SHA-256 of the exact first installed image. Backup filenames
are never taken as arbitrary relative paths: they must equal the derived ID
plus `.bin` and remain under `backups`. Before metadata is trusted, the path,
ID, filename, byte length, and backup hash must all agree. State files and
backup files that are reparse points are rejected.

The installer serializes operations for a state root with a cross-process named
mutex, then preflights every requested profile and all existing state. It
creates and verifies all new backups, atomically writes the manifest, and
updates profiles using uniquely named same-directory temporary files plus
`File.Replace` (or a same-directory `File.Move` for a new file). Every replace
compares the bytes actually displaced at the atomic commit point with the
preflight image. A mismatch restores the displaced bytes and fails instead of
deleting a concurrent editor save. If a later write fails, completed profile
writes and the manifest are rolled back and backups created by that attempt are
removed.

## Uninstall And Restoration

Uninstall uses two deliberately different paths:

- If current bytes exactly match the recorded installed SHA-256, a profile that
  existed before Psh is restored from the same in-memory backup bytes that
  passed manifest length/hash validation, byte for byte. A profile created only
  for Psh is moved to a same-directory quarantine during the transaction and
  removed after the manifest update succeeds.
- If content outside the canonical block changed after installation, uninstall
  removes only the exact canonical block and its following line terminator. It
  preserves all other current bytes rather than replacing post-install edits
  with an older backup.

If the block is already absent, uninstall does not recreate, overwrite, or
delete the current profile. It retires the matching Psh metadata because the
user's current absence or replacement of the block is treated as intentional.
If the original profile did not exist but the current file has post-install
edits, a surgically emptied file is conservatively retained unless its bytes
matched the exact Psh-installed image.

## Failure Semantics

The following are hard preflight failures:

- unmatched, duplicate, reversed, nested, inline, or otherwise malformed Psh
  markers in any requested target;
- a canonical marked block without trusted matching backup metadata;
- a canonical marker pair whose loader content was changed;
- invalid, missing, hash-mismatched, path-mismatched, duplicate, traversing, or
  reparse-point manifest/backup state;
- an unsupported or non-lossless profile encoding; or
- a target that changes between preflight and its atomic commit.

Preflight covers the complete `-ProfilePath` array before the first target is
modified, so a conflict in one target leaves every target unchanged. A runtime
failure after writes begin triggers reverse-order rollback. If a concurrent
actor prevents safe rollback, the scripts stop, retain the remaining Psh-owned
backup/quarantine evidence, and report both the original failure and each
rollback failure; they never overwrite the concurrent content to hide the
problem.

The scripts do not weaken enterprise policy, alter permanent environment state,
or claim that a Psh package or release has been published. They are lifecycle
primitives used by later installer work.
