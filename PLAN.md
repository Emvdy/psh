# Psh v0.1.0: PowerShell 5.1 Bash Compatibility Layer

## Summary

- Create the public `Emvdy/psh` repository under `GPL-3.0-or-later`.
- Support Windows 10/11, x64/ARM64, Windows PowerShell 5.1, and PowerShell 7.
- Keep Core free of third-party utility executables; Full adds pinned `rg`, `fd`, `jq`, and `bat` builds.
- Install for the current user by default, with no administrator requirement, execution-policy changes, permanent system `PATH` changes, or telemetry.
- Implement a command compatibility layer, not a Bash interpreter or general `.sh` runtime.
- Leave Full installed in the Parallels `Windows 11` ARM64 VM and publish release `v0.1.0`.

## Public Interfaces

- Online installer: `install.ps1 -Edition Core|Full -Version latest|x.y.z -NonInteractive`; Core is the default.
- Git Bash/WSL installer: `install.sh` downloads, verifies, and invokes `powershell.exe`; it does not duplicate installer logic.
- Offline installer: extract the ZIP and run `install-offline.ps1`, `install.sh --offline`, or `psh-installer.exe --offline`.
- Management command: `psh version|doctor|capabilities|commands|config|update|rollback|self-test|uninstall`; `doctor` and `capabilities` support `--json`.
- Bash-style commands emit text and set stable exit codes: `0` success, `1` no match, `2` usage error, `3` runtime error, `4` missing dependency, `5` integrity failure.
- Key object APIs: `Find-PshText`, `Find-PshItem`, `Select-PshJson`, `Get-PshHead`, `Get-PshTail`, `Measure-PshText`, `Set-PshFileTime`, and `Invoke-PshXArgs`.

The first release provides these 64 command names:

- Files and search: `pwd cd ls mkdir rmdir cp mv rm touch ln realpath basename dirname stat file tree find fd du df mktemp`
- Text and data: `cat bat head tail grep rg sed awk jq cut tr sort uniq wc tee xargs printf echo base64`
- Environment and processes: `which env printenv export test ps kill pgrep pkill timeout sleep`
- Network and archives: `curl wget tar zip unzip gzip gunzip sha256sum md5sum date whoami hostname clear`

In Core, `rg`, `fd`, `jq`, and `bat` use documented PowerShell subsets. In Full, they delegate to the pinned native tools and accept the tools' complete argument sets.

## Goal 0: Safety Baseline And Repository

- Reauthenticate with `gh auth login`, create public `Emvdy/psh`, and add the GPL license, bilingual README files, contribution guide, security policy, and protected `release` environment.
- Record the VM UUID, ARM64 architecture, and Guest Tools state; create snapshot `psh-preinstall-<timestamp>` before installation.
- **StopIf:** GitHub authentication remains invalid, the repository name belongs to unrelated content, the VM snapshot fails, or guest execution requires storing a plaintext password.
- **DoneWhen:** The remote accepts pushes, `main` is the default branch, the snapshot ID is recorded, and `prlctl exec --current-user` can run read-only diagnostics.

## Goal 1: Module And Machine-Readable Specification

- Create a PS5.1-compatible `Psh` module. Define command names, flags, exit codes, Core/Full backends, help, and completions in structured command specifications.
- Generate `commands.json`, compatibility documentation, and argument completions from the same specifications so implementation, documentation, and AI capability discovery cannot drift.
- Install under `%LOCALAPPDATA%\Psh` using `versions\<version>`, atomically updated `current.json`, stable `bootstrap.ps1`, and `config.psd1`.
- **StopIf:** Core unexpectedly requires PS7, administrator access, startup downloads, or third-party utility executables.
- **DoneWhen:** The module imports in clean PS5.1 and PS7 sessions, and `psh capabilities --json` reports all 64 commands and their active backends.

## Goal 2: Interactive Experience

- Pin and bundle PSReadLine 2.4.5 and PSCompletions 6.10.0 with their licenses.
- Bind `Tab` to `MenuComplete`, `Ctrl+R` to reverse history search, arrows to prefix history search, and history prediction to `History + ListView`.
- Provide a compact ASCII prompt showing the current path, previous command status, and optional Git branch without requiring Nerd Fonts.
- Maintain CurrentUserAllHosts profiles for Windows PowerShell and PowerShell 7. Insert only a marked loader block and back up existing files first.
- **StopIf:** Existing profile markers are malformed, VT is unavailable with no safe fallback, or shell startup becomes noticeably blocked.
- **DoneWhen:** VS Code shows completions below the prompt, and history view, Chinese paths, paths with spaces, and Git completion pass interactive acceptance.

## Goal 3: Command Compatibility Layer

- File commands support common `-a/-l/-h/-R/-p/-r/-f/-n/-u/-v` behavior. Resolve paths before mutation; `rm` always refuses to delete a drive root or `$HOME` itself.
- `grep/rg` support `-i -v -n -r -l -c -m -A -B -C -E -F -q --include --exclude --hidden --glob`.
- `find/fd` support names, types, depths, sizes, times, hidden entries, exclusions, and NUL output. `xargs` supports `-0 -n -I -P`, invokes commands through argument arrays, and never uses `Invoke-Expression`.
- `sed` is limited to addresses, `s///`, `d/p/q`, and `-e/-n/-i/-E`. `awk` is limited to `-F/-v`, fields, NR/NF, BEGIN/END, matching, comparisons, print/printf, and basic aggregation. Unsupported syntax exits with `2`.
- Core `jq` supports paths, array iteration, pipes, `select/length/keys/map`, and `-r/-c/-e`; Full delegates to native `jq`.
- Preserve source encoding and line endings for edits. New files use UTF-8 without BOM, and in-place changes use a temporary file plus atomic replacement.
- **StopIf:** Unsupported flags are silently accepted, text commands leak formatted PowerShell objects, destructive tests escape their temporary directory, or Core secretly uses Full tools.
- **DoneWhen:** All 64 commands have help, examples, completion, exit-code coverage, and documented Core/Full differences.

## Goal 4: Full Tools And Supply Chain

- Record exact versions, tags, source commits, download URLs, SHA256 values, architectures, and licenses for `rg`, `fd`, `jq`, and `bat`. Builds must never resolve a floating `latest` reference.
- Select the highest stable release when creating the lock file. If upstream lacks an ARM64 asset, reproducibly build the pinned tag rather than relabeling an x64 executable.
- Retain all upstream licenses and produce `THIRD_PARTY_NOTICES.md` and an SPDX SBOM for PSReadLine, PSCompletions, and native tools.
- **StopIf:** A checksum mismatches, a license cannot be aggregated with GPL, source and tag differ, or an ARM64 tool fails in the real VM.
- **DoneWhen:** Core remains functional after deleting `tools`, and Full reports every pinned tool version on x64 CI and the ARM64 VM.

## Goal 5: Install, Upgrade, And Uninstall

- Online installation downloads versioned scripts, manifests, and packages, verifies SHA256, then executes. Do not recommend `irm | iex`.
- Offline ZIP files include modules, dependencies, licenses, manifests, installers, uninstallers, and the same EXE. Offline mode must not make network requests.
- Install through staging, integrity verification, and atomic version switching. Reinstallation is idempotent, and at least one prior version remains available for rollback.
- Build a small GPL C# AnyCPU bootstrapper in Actions instead of using license-incompatible PS2EXE. The EXE must respect, not bypass, PowerShell execution policy.
- **StopIf:** Profiles cannot be updated losslessly, the installer changes GPO, execution policy, or system `PATH`, or uninstall would remove pre-existing user content.
- **DoneWhen:** Core and Full pass online/offline install, upgrade, rollback, repeat-install, and uninstall tests, with the original profile restored after uninstall.

## Goal 6: Tests And CI

- Use table-driven Pester tests. Windows x64 CI runs PS5.1 and PS7; the real VM covers Windows 11 ARM64 PS5.1.
- Ubuntu CI generates GNU golden output. Windows compares matching text, Unicode, CRLF/LF, empty files, binary files, hidden entries, and special paths.
- Installer tests cover non-admin use, non-ASCII user paths, spaces, corrupted downloads, wrong architectures, Core without tools, missing Full tools, and profile conflicts.
- Actions run PSScriptAnalyzer, dependency and license checks, secret scanning, Defender scanning, checksums, SBOM generation, and build provenance attestation.
- **StopIf:** Any supported matrix fails, Defender quarantines an asset, a secret is present, a license file is missing, or the build is not reproducible.
- **DoneWhen:** All automated checks pass and the reports plus command compatibility matrix are retained as workflow artifacts.

## Goal 7: Windows 11 VM Acceptance

- After the pre-install snapshot, start or resume the VM and transfer the release candidate through the shared folder. Test offline Core first, uninstall and compare profile state, then test Full, upgrade, rollback, and uninstall.
- Finish by installing Full, running `psh doctor --json`, checking all four native versions, executing the 64-command smoke suite, and manually verifying Tab, ListView, and Ctrl+R in VS Code.
- Create post-install snapshot `psh-v0.1.0-installed`, restore normal networking, remove temporary credentials, and pause the VM.
- **StopIf:** The original snapshot cannot be restored, ARM64 tools fail, user files or profiles change unexpectedly, or VS Code cannot show the required interaction model.
- **DoneWhen:** Doctor reports zero errors, Full remains installed, screenshots and logs are archived, and the VM ends paused.

## Goal 8: v0.1.0 Release

- After VM acceptance of a release candidate, push tag `v0.1.0`. Actions rerun all builds and tests; a protected Environment requires manual approval before publishing.
- Publish `install.ps1`, `install.sh`, an unsigned but attested AnyCPU EXE, the Core offline ZIP, x64 and ARM64 Full ZIP files, SHA256 list, SBOM, third-party notices, and bilingual release notes.
- Clearly document possible SmartScreen warnings and provide SHA256 and GitHub attestation verification commands.
- **StopIf:** GitHub authentication is not restored, final-tag behavior differs from the accepted candidate, VM acceptance is incomplete, or any release asset is absent.
- **DoneWhen:** `Emvdy/psh` is public, `v0.1.0` supports verified online and offline installation, and the Windows 11 VM retains Full.

## Assumptions

- Do not implement a Bash interpreter, shebang execution, job control, POSIX permissions, `chmod/chown/sudo`, process substitution, or general `.sh` compatibility.
- Do not bypass enterprise GPO. If the office computer forbids profiles or scripts, stop and obtain an administrator-approved deployment path.
- Full tools remain separately licensed aggregate components; all original licenses are retained. Psh-owned source uses `GPL-3.0-or-later`.
- The first version is `v0.1.0`, the repository is `Emvdy/psh`, Core is the default install edition, and the VM ends with Full installed.
