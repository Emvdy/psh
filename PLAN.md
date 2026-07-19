# Psh v0.1.0: PowerShell 5.1 Bash Compatibility Layer

## Summary

- Create the public `Emvdy/psh` repository under `GPL-3.0-or-later`.
- Support Windows 10/11, x64/ARM64, Windows PowerShell 5.1, and PowerShell 7.
- Keep Core free of third-party utility executables; Full adds pinned `rg`, `fd`, `jq`, and `bat` builds.
- Install for the current user by default, with no administrator requirement, execution-policy changes, permanent system `PATH` changes, or telemetry.
- Implement a command compatibility layer, not a Bash interpreter or general `.sh` runtime.
- Leave Full installed in the Parallels `Windows 11` ARM64 VM and publish release `v0.1.0`.

## Execution Constraints

These rules bind every goal. They exist because the first execution attempt
lost more than twelve hours to GUI automation and unbounded self-verification.

- **Orchestration.** The main agent only plans, delegates, reviews subagent
  summaries, integrates, and commits. Implementation, test execution, CI
  diagnosis, license audits, research, and documentation run in subagents.
  Subagents return conclusions plus artifact paths, never full logs. The main
  agent must not run long verification matrices itself or paste long raw
  output into its own context. Multiple subagents must never edit the same
  file concurrently.
- **No GUI automation.** Never drive a UI with synthesized keyboard or mouse
  events (`prlctl send-key-event`, `SendKeys`) or screenshot-based assertions.
  Anything that requires a human interaction model is verified by a human
  checklist that the agent prepares and the user executes.
- **VM discipline.** The Parallels VM is used only in Goal 0 (baseline and
  provisioning, already complete) and Goal 7 (final acceptance). During Goals
  1–6 the VM must not be started, resumed, or queried. PS5.1 and PS7
  verification runs on Windows x64 GitHub CI; ARM64 automation moves to
  GitHub `windows-11-arm` runners if the Goal 6 evaluation confirms they are
  usable, otherwise it is deferred to Goal 7 headless scripts.
- **Evidence standard.** Evidence is commands, outputs, file paths, commit
  SHAs, and CI run links recorded in `EXECUTION.md`. No screenshot hash
  manifests, no tamper-injection tests of third-party dependencies outside
  the Goal 6 checksum gates, and no testing of third-party internals (for
  example PSReadLine private APIs).
- **Verification ceiling.** Verify what a DoneWhen literally requires and no
  more. Do not invent additional negative, capacity, or adversarial tests
  beyond the stated gates.
- **Budget guardrail.** If a single DoneWhen item resists three distinct
  approaches or roughly two hours of effort, stop and report the options to
  the user instead of continuing to grind. This does not weaken any gate; it
  returns the decision to the user.

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

### Command Tiers

All 64 names ship, but their fidelity targets differ. DoneWhen checks apply
per tier; a Tier 2 command that rejects unsupported syntax with exit code `2`
is complete, not deficient.

- **Tier 1 — full common semantics.** Text-processing members are validated
  against GNU golden output: `pwd cd ls mkdir rmdir cp mv rm touch ln
  realpath basename dirname mktemp cat head tail cut tr sort uniq wc tee
  printf echo base64 which env printenv test sleep sha256sum md5sum`.
- **Tier 2 — documented subsets.** Behavior tests cover the documented subset
  only; anything outside it exits `2`: `stat file tree find fd du df bat grep
  rg sed awk jq xargs export ps kill pgrep pkill timeout curl wget tar zip
  unzip gzip gunzip`.
- **Tier 3 — thin wrappers:** `date whoami hostname clear`.

### Name Collision Policy

At least ten of the 64 names collide with PowerShell built-in aliases
(`curl`, `wget`, `ps`, `kill`, `echo`, `sort`, and others) or Windows native
executables (`sort.exe`, `find.exe`, `where.exe`). Goal 1 must define, and
`commands.json` must record, the resolution order (Psh function over built-in
alias over native executable), the per-command collision notes, and a
documented `psh config` switch to disable individual commands. The
compatibility documentation must state the policy.

## Goal 0: Safety Baseline And Repository

- Reauthenticate with `gh auth login`, create public `Emvdy/psh`, and add the GPL license, bilingual README files, contribution guide, security policy, and protected `release` environment.
- Record the VM UUID, ARM64 architecture, and Guest Tools state; create snapshot `psh-preinstall-<timestamp>` before installation.
- Provision the VM for later acceptance in one pass: CurrentUser
  `RemoteSigned` execution policy (user-authorized), Git for Windows ARM64,
  and Windows Terminal availability. Re-snapshot after provisioning so Goal 7
  starts from a ready baseline.
- **StopIf:** GitHub authentication remains invalid, the repository name belongs to unrelated content, the VM snapshot fails, or guest execution requires storing a plaintext password.
- **DoneWhen:** The remote accepts pushes, `main` is the default branch, the snapshot ID is recorded, `prlctl exec --current-user` can run read-only diagnostics, and the VM can import a signed script under the provisioned policy.

## Goal 1: Module And Machine-Readable Specification

- Create a PS5.1-compatible `Psh` module. Define command names, flags, exit codes, Core/Full backends, help, and completions in structured command specifications.
- Define the name-collision resolution order and per-command collision notes in the same specification (see Name Collision Policy).
- Generate `commands.json`, compatibility documentation, and argument completions from the same specifications so implementation, documentation, and AI capability discovery cannot drift.
- Install under `%LOCALAPPDATA%\Psh` using `versions\<version>`, atomically updated `current.json`, stable `bootstrap.ps1`, and `config.psd1`.
- **StopIf:** Core unexpectedly requires PS7, administrator access, startup downloads, or third-party utility executables.
- **DoneWhen:** The module imports in clean PS5.1 and PS7 sessions **on Windows x64 CI**, and `psh capabilities --json` reports all 64 commands and their active backends.

## Goal 2: Interactive Experience

- Pin and bundle PSReadLine 2.4.5 with its license.
- PSCompletions is out of scope for v0.1.0: its `ScriptsToProcess` performs
  network access and module-directory mutation and cannot be imported safely.
  Git completion uses the Psh-owned offline adapter instead. Remove the
  unused vendored PSCompletions package during closeout.
- Bind `Tab` to `MenuComplete`, `Ctrl+R` to reverse history search, arrows to prefix history search, and history prediction to `History + ListView` with a safe documented fallback.
- Provide a compact ASCII prompt showing the current path, previous command status, and optional Git branch without requiring Nerd Fonts.
- Maintain CurrentUserAllHosts profiles for Windows PowerShell and PowerShell 7. Insert only a marked loader block and back up existing files first.
- **StopIf:** Existing profile markers are malformed, VT is unavailable with no safe fallback, or the profile adds more than 1000 ms to cold shell startup.
- **DoneWhen (automated, on Windows x64 CI):** `Get-PSReadLineKeyHandler`
  lists the four required bindings; `Get-PSReadLineOption` reports
  `History` prediction with `ListView` (or the documented fallback);
  the prompt renders status, a Chinese-and-space path, and a Git branch in a
  headless session; profile install and uninstall round-trip byte-identically.
- Interactive human verification of the same experience is performed once, in
  Goal 7, via the human checklist. It is not a Goal 2 gate.

## Goal 3: Command Compatibility Layer

- Work proceeds in four batches — file commands, text search, complex `sed/awk/jq/xargs`, system/network/archive — each batch ending with its own commit and green CI. A completed batch is not revisited by later batches.
- File commands support common `-a/-l/-h/-R/-p/-r/-f/-n/-u/-v` behavior. Resolve paths before mutation; `rm` always refuses to delete a drive root or `$HOME` itself.
- `grep/rg` support `-i -v -n -r -l -c -m -A -B -C -E -F -q --include --exclude --hidden --glob`.
- `find/fd` support names, types, depths, sizes, times, hidden entries, exclusions, and NUL output. `xargs` supports `-0 -n -I -P`, invokes commands through argument arrays, and never uses `Invoke-Expression`.
- `sed` is limited to addresses, `s///`, `d/p/q`, and `-e/-n/-i/-E`. `awk` is limited to `-F/-v`, fields, NR/NF, BEGIN/END, matching, comparisons, print/printf, and basic aggregation. Unsupported syntax exits with `2`.
- Core `jq` supports paths, array iteration, pipes, `select/length/keys/map`, and `-r/-c/-e`; Full delegates to native `jq`.
- Preserve source encoding and line endings for edits. New files use UTF-8 without BOM, and in-place changes use a temporary file plus atomic replacement.
- Help, examples, and completions are generated from the Goal 1 specification, not hand-verified per command.
- **StopIf:** Unsupported flags are silently accepted, text commands leak formatted PowerShell objects, destructive tests escape their temporary directory, or Core secretly uses Full tools.
- **DoneWhen:** The specification generator `-Check` passes; every command has at least one behavior test appropriate to its tier; Tier 1 text commands pass golden comparison; Core/Full differences are documented.

## Goal 4: Full Tools And Supply Chain

- Record exact versions, tags, source commits, download URLs, SHA256 values, architectures, and licenses for `rg`, `fd`, `jq`, and `bat`. Builds must never resolve a floating `latest` reference.
- Select the highest stable release when creating the lock file. If upstream lacks an ARM64 asset, follow this ladder: official ARM64 asset, then reproducible CI build of the pinned tag, then — with explicit user approval — that tool degrades to its Core backend on ARM64 with the limitation documented. Relabeling an x64 executable as ARM64 remains forbidden.
- Retain all upstream licenses and produce `THIRD_PARTY_NOTICES.md` and an SPDX SBOM for PSReadLine and the native tools.
- **StopIf:** A checksum mismatches, a license cannot be aggregated with GPL, or source and tag differ.
- **DoneWhen:** Core remains functional after deleting `tools`, and Full reports every pinned (or documented-degraded) tool version on x64 CI.

## Goal 5: Install, Upgrade, And Uninstall

- Online installation downloads versioned scripts, manifests, and packages, verifies SHA256, then executes. Do not recommend `irm | iex`.
- Offline ZIP files include modules, dependencies, licenses, manifests, installers, uninstallers, and the same EXE. Offline mode must not make network requests.
- Install through staging, integrity verification, and atomic version switching. Reinstallation is idempotent. Upgrade and rollback are exercised against a synthetic `0.0.1-test` package because `v0.1.0` is the first real release.
- When execution policy forbids running the installer, the installer does not bypass anything: it emits a structured diagnostic pointing the user at `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` and exits with code `4`. This behavior is tested.
- Build a small GPL C# AnyCPU bootstrapper in Actions instead of using license-incompatible PS2EXE. The EXE must respect, not bypass, PowerShell execution policy.
- **StopIf:** Profiles cannot be updated losslessly, the installer changes GPO, execution policy, or system `PATH`, or uninstall would remove pre-existing user content.
- **DoneWhen:** Core and Full pass online/offline install, upgrade, rollback, repeat-install, and uninstall tests on x64 CI, with the original profile restored after uninstall.

## Goal 6: Tests And CI

- Use table-driven Pester tests. Windows x64 CI runs PS5.1 and PS7.
- Evaluate GitHub `windows-11-arm` public runners. If usable, run the PS7 (and, if available, PS5.1) automated matrix there so Goal 7 needs no automated-matrix work; record the evaluation outcome either way.
- Ubuntu CI generates GNU golden output for Tier 1 text commands. Comparison uses shared normalization helpers (`\`→`/` path separators, CRLF→LF, `LC_ALL=C` collation). Platform-shaped commands (`ls du df stat ps` and similar) use structural assertions, not golden bytes.
- Installer tests cover non-admin use, non-ASCII user paths, spaces, corrupted downloads, wrong architectures, Core without tools, missing Full tools, and profile conflicts.
- Actions run PSScriptAnalyzer, dependency and license checks, secret scanning, checksums, SBOM generation, and build provenance attestation. Defender scanning of release assets is best-effort (`MpCmdRun -Scan` where available; otherwise record hash-based lookup) and its unavailability is not a failure.
- Reproducibility gate: two builds must produce identical file manifests and per-file SHA256 values; archive-container metadata (timestamps) is excluded.
- **StopIf:** Any supported matrix fails, a secret is present, or a license file is missing.
- **DoneWhen:** All automated checks pass and the reports plus command compatibility matrix are retained as workflow artifacts.

## Goal 7: Windows 11 VM Acceptance

This is the only goal that touches the VM after Goal 0, and the only
interactive acceptance point in the plan.

- Start or resume the VM from the provisioned baseline and transfer the release candidate through the shared folder.
- **Automated portion** — headless scripts via `prlctl exec` only, no GUI events: offline Core install, uninstall with profile comparison, Full install, upgrade, rollback, `psh doctor --json`, all four native tool versions, and the 64-command smoke suite. Offline testing disconnects the VM network adapter (`prlctl set ... --disconnect`) and restores it afterward.
- **Interactive portion** — the agent prepares the environment and a one-page checklist (about ten minutes): in Windows Terminal, the user verifies Tab menu completion, `History + ListView` prediction, `Ctrl+R` reverse search, Up/Down prefix search, the prompt in a Chinese-and-space path, and Git completion. The user's confirmation, recorded in `EXECUTION.md`, is the evidence. No screenshots are required.
- Create post-install snapshot `psh-v0.1.0-installed`, restore normal networking, remove temporary artifacts, and pause the VM.
- **StopIf:** The original snapshot cannot be restored, ARM64 tools fail, user files or profiles change unexpectedly, or a checklist item fails.
- **DoneWhen:** Doctor reports zero errors, Full remains installed, headless logs are archived, the user has confirmed the interactive checklist, and the VM ends paused.

## Goal 8: v0.1.0 Release

- After VM acceptance of a release candidate, push tag `v0.1.0`. Actions rerun all builds and tests; a protected Environment requires manual approval before publishing.
- The tag must point at the exact commit SHA that passed VM acceptance; any difference stops the release.
- Publish `install.ps1`, `install.sh`, an unsigned but attested AnyCPU EXE, the Core offline ZIP, x64 and ARM64 Full ZIP files, SHA256 list, SBOM, third-party notices, and bilingual release notes.
- Clearly document possible SmartScreen warnings and provide SHA256 and GitHub attestation verification commands.
- **StopIf:** The tagged SHA differs from the accepted candidate, VM acceptance is incomplete, or any release asset is absent.
- **DoneWhen:** `Emvdy/psh` is public, `v0.1.0` supports verified online and offline installation, and the Windows 11 VM retains Full.

## Assumptions

- Do not implement a Bash interpreter, shebang execution, job control, POSIX permissions, `chmod/chown/sudo`, process substitution, or general `.sh` compatibility.
- Do not bypass enterprise GPO. If the office computer forbids profiles or scripts, stop and obtain an administrator-approved deployment path.
- Full tools remain separately licensed aggregate components; all original licenses are retained. Psh-owned source uses `GPL-3.0-or-later`.
- The first version is `v0.1.0`, the repository is `Emvdy/psh`, Core is the default install edition, and the VM ends with Full installed.

## Amendment History

- **2026-07-19 — Amendment 1.** Added Execution Constraints, Command Tiers,
  Name Collision Policy; removed VS Code as an acceptance host (replaced by
  Windows Terminal human checklist in Goal 7); restricted the VM to Goals 0
  and 7; removed PSCompletions from v0.1.0 scope; converted Goal 2 DoneWhen
  to automated CI assertions; added the synthetic upgrade/rollback package,
  golden normalization rules, the `windows-11-arm` runner evaluation, and the
  ARM64 tool fallback ladder.
- **Grandfathered evidence.** Goals 0 and 1 are complete (commits `1f87695`,
  `83ed21f`). Goal 2 evidence collected under the pre-amendment standard —
  including the VS Code-based real-VM interactive acceptance in
  `evidence/goal2/goal2-20260719T025655Z-2412eb25/` and commit `f6596bc` — is
  accepted as-is and must not be redone, re-verified, or deleted. Goal 2
  closeout consists only of: recording the final CI run in `EXECUTION.md`,
  removing the unused PSCompletions bundle (with its verifier and license
  entries updated), merging `goal2/interactive-experience` to `main`, and
  marking Goal 2 complete.
