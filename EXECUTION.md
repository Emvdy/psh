# Psh v0.1.0 Execution Record

This file records execution evidence for `PLAN.md`. A goal is complete only
after every applicable StopIf condition has been checked and every DoneWhen
condition has direct evidence.

## Status

| Goal | Status | Commit | Notes |
| --- | --- | --- | --- |
| Goal 0 | COMPLETE | `1f87695` | Safety baseline and repository |
| Goal 1 | COMPLETE | `83ed21f` | Module and machine-readable specification |
| Goal 2 | COMPLETE | `20a4e59` | Amendment 1 closeout merged to `main`; final branch and main CI green |
| Goal 3 | IN_PROGRESS | - | Goal 2 prerequisite met; Batch 1 is complete; Batch 2 is pending |
| Goal 4 | PENDING | - | Blocked on Goal 3 DoneWhen |
| Goal 5 | PENDING | - | Blocked on Goal 4 DoneWhen |
| Goal 6 | PENDING | - | Blocked on Goal 5 DoneWhen |
| Goal 7 | PENDING | - | Blocked on Goal 6 DoneWhen |
| Goal 8 | PENDING | - | Blocked on Goal 7 DoneWhen |

## Goal 0: Safety Baseline And Repository

Started: 2026-07-18 (Asia/Shanghai)

### Prerequisite

- [x] No prior goal is required.

### Implementation Checklist

- [x] Reauthenticate the `Emvdy` GitHub account with `gh auth login`.
- [x] Confirm that `Emvdy/psh` is absent or contains only this project.
- [x] Create or configure public repository `Emvdy/psh`.
- [x] Add `GPL-3.0-or-later` license and bilingual README files.
- [x] Add contribution guide and security policy.
- [x] Configure protected GitHub Environment `release`.
- [x] Add `origin`, push `main`, and verify it is the default branch.
- [x] Locate the exact Parallels VM named `Windows 11`.
- [x] Record ARM64 architecture and Parallels Guest Tools state.
- [x] Create a pre-install snapshot named `psh-preinstall-<timestamp>`.
- [x] Record the pre-install snapshot ID.
- [x] Run read-only guest diagnostics with `prlctl exec --current-user`.
- [x] Review the complete Goal 0 diff for credentials and unrelated files.
- [x] Commit Goal 0 and record the commit SHA.

### StopIf Checks

| Condition | State | Evidence / action |
| --- | --- | --- |
| GitHub authentication remains invalid | NOT_HIT | After browser reauthentication, sandbox-external `gh auth status -h github.com` succeeded for `Emvdy` using the keyring. |
| Repository name belongs to unrelated content | NOT_HIT | Authenticated `gh repo view Emvdy/psh` reported that no such repository exists. |
| VM snapshot fails | NOT_HIT | Snapshot creation succeeded and its details were read back by ID. |
| Guest execution requires a plaintext password | NOT_HIT | `prlctl exec 'Windows 11' --current-user cmd.exe /d /c whoami` succeeded without a password argument. |

### Evidence Collected

- Local branch: `main`; `git status --short --branch` reported
  `No commits yet on main` with only `PLAN.md` initially untracked.
- Git remote: none (`git remote -v` produced no output).
- GitHub authentication: the initial token was invalid; browser reauthentication
  completed, then `gh auth status -h github.com` and `gh api user --jq .login`
  succeeded for `Emvdy` on 2026-07-18.
- Repository ownership pre-check: authenticated `gh repo view Emvdy/psh`
  returned `Could not resolve to a Repository`, so no existing repository will
  be overwritten or repurposed.
- Repository: <https://github.com/Emvdy/psh>, visibility `PUBLIC`; GitHub
  identifies the license as GNU GPLv3.
- Initial Goal 0 commit: `1f876951b5773bf56318db0da28d49126a9c58da`.
- Initial push output reported a new `main` branch and configured it to track
  `origin/main`.
- Remote default branch: `main`; `git ls-remote --symref origin HEAD` returned
  `ref: refs/heads/main` and the same commit SHA as local `HEAD`.
- Protected Environment: `release`; API verification returned a
  `required_reviewers` protection rule for GitHub user `Emvdy`.
- VM inventory: exact name `Windows 11`, UUID
  `{acb3e79b-bc02-4c09-9620-275777f58a23}`, status `paused`.
- VM architecture: `BIOS type: efi-arm64` and CPU `type=arm`.
- Parallels Guest Tools: installed, version `26.2.0-57363`.
- Pre-install snapshot: name `psh-preinstall-20260718-135918`, ID
  `{9f0989bf-a672-45a3-b0d4-e8895e860ce4}`, created
  `2026-07-18 13:59:43`, state `pause`, current `yes`.
- Passwordless guest diagnostic:
  `prlctl exec 'Windows 11' --current-user cmd.exe /d /c whoami` returned
  `emvdy217f\emvdy`.
- Post-diagnostic VM status: `VM Windows 11 exist paused`.

### DoneWhen Audit

- [x] Remote accepts pushes.
- [x] `main` is the default branch.
- [x] Pre-install snapshot ID is recorded.
- [x] `prlctl exec --current-user` runs read-only diagnostics.

### Remaining Work

None. All Goal 0 StopIf conditions were checked and not hit after remediation,
and all Goal 0 DoneWhen conditions have direct evidence. Goal 1 may start.

## Goal 1: Module And Machine-Readable Specification

Started: 2026-07-18 (Asia/Shanghai)

### Prerequisite

- [x] Goal 0 is complete and all four Goal 0 DoneWhen checks have direct
  evidence above.

### Implementation Checklist

- [x] Create a Windows PowerShell 5.1-compatible `Psh` module and manifest.
- [x] Define all 64 command names, flags, exit codes, Core/Full backends, help,
  examples, object APIs, and completion data in one structured specification.
- [x] Define all management commands and JSON-capable interfaces in the same
  specification.
- [x] Generate `commands.json` deterministically from the specification.
- [x] Generate the compatibility documentation from the specification.
- [x] Generate argument completers from the specification.
- [x] Implement `psh capabilities --json` with active Core/Full backends.
- [x] Implement the `%LOCALAPPDATA%\Psh\versions\<version>` layout contract.
- [x] Add stable `bootstrap.ps1`, default `config.psd1`, and atomic
  `current.json` switching support.
- [x] Add focused Goal 1 tests, including generated-artifact drift checks.
- [x] Verify Core has no third-party utility executable dependency.
- [x] Import the module in clean PowerShell 7 and verify 64 capabilities.
- [x] Import the module in clean Windows PowerShell 5.1 and verify 64
  capabilities.
- [x] Review the complete Goal 1 diff for secrets and unrelated files.
- [x] Commit Goal 1, push it, and record the commit SHA and test evidence.

### StopIf Checks

| Condition | State | Evidence / action |
| --- | --- | --- |
| Core unexpectedly requires PowerShell 7 | NOT_HIT | Windows x64 CI imported and exercised the module in Windows PowerShell 5.1.26100.32995. |
| Core requires administrator access | NOT_HIT | Acceptance uses an isolated current-user temporary layout; source scan found no elevation request. |
| Core performs startup downloads | NOT_HIT | Module/bootstrap review and acceptance found no network API; import and bootstrap are local-only. |
| Core requires third-party utility executables | NOT_HIT | Core reports all backends as `powershell`; source contains no EXE/DLL and acceptance passes without native tools. |

### Evidence Collected

- Authoritative specification:
  `src/Psh/Specification/commands.psd1`, schema `1.0`, version `0.1.0`,
  exactly 64 unique commands and management actions from PLAN.md.
- Deterministic generator: PowerShell 7.6.3 ARM64 generated
  `generated/commands.json`, `docs/compatibility.md`, and
  `src/Psh/Generated/ArgumentCompleters.ps1`; a separate `-Check` run returned
  `Generated command artifacts are up to date.`
- PS7 test runtime: official PowerShell `v7.6.3` macOS ARM64 portable asset;
  SHA256 `f0263c2072fe7d0953781c60497a574bea99b37237f2554a59ce4bad07de8d36`
  matched the official `hashes.sha256` asset. The runtime remained under
  `/private/tmp` and was not installed or added to PATH.
- Clean PS7 acceptance output:
  `Goal 1 acceptance passed: specification, generated artifacts, module`
  `capabilities, safety constraints, and install layout.`
- Direct capabilities output: Core reported 64 commands, no native backends,
  exit `0`; Full reported 64 commands with only `fd,bat,rg,jq` native, exit
  `0`.
- Real VM PS5.1 runtime: `5.1.26100.8655`. Parser API read-only validation
  returned `PS5.1_PARSE files=9 errors=0`.
- VM import blocker: every `Get-ExecutionPolicy -List` scope is `Undefined`,
  producing the Windows client effective `Restricted` policy. A normal,
  non-bypassed `Import-Module` returned `PSSecurityException`,
  `UnauthorizedAccess`, stating that script execution is disabled. No policy
  or GPO was changed.
- Safe alternative completed: `.github/workflows/goal1.yml` ran the same
  generated-artifact and acceptance tests on Windows x64 with native Windows
  PowerShell 5.1 and PowerShell 7.
- Goal 1 implementation head: `6e5641cb34360124eade55545ed028b0b005debd`.
- Final branch CI: <https://github.com/Emvdy/psh/actions/runs/29635418864>,
  conclusion `success`. Both jobs and every non-cleanup test step succeeded.
- Windows PowerShell job: version `5.1.26100.32995`, PSEdition `Desktop`;
  generator `-Check` and Goal 1 acceptance both passed.
- PowerShell job: version `7.6.3`, PSEdition `Core`, Win32NT;
  generator `-Check` and Goal 1 acceptance both passed.
- CI action supply chain: `actions/checkout` is pinned to immutable v6 commit
  `df4cb1c069e1874edd31b4311f1884172cec0e10`; final logs contain no Node 20
  deprecation warning.
- Line-ending determinism: `.gitattributes` fixes generated and source text to
  LF; the same byte-level `-Check` passed on PS5.1 and PS7 Windows jobs.
- VM test-batch cleanup: original `pause-idle=on` was restored and
  `prlctl status 'Windows 11'` returned `VM Windows 11 exist paused`.

### DoneWhen Audit

- [x] Module imports in a clean Windows PowerShell 5.1 session.
- [x] Module imports in a clean PowerShell 7 session.
- [x] `psh capabilities --json` reports all 64 commands and active backends.

### Remaining Work

None. All Goal 1 StopIf conditions were checked and not hit, and all Goal 1
DoneWhen conditions have direct evidence. Goal 2 may start after this evidence
commit is merged to `main` and the resulting `main` workflow is green.

- Goal 1 completion evidence commit: `83ed21f99793508d8112e429c8486869f5c97869`.
- Default-branch CI: <https://github.com/Emvdy/psh/actions/runs/29636062661>,
  conclusion `success` for the same completion head on `main`.

## Goal 2: Interactive Experience

Started: 2026-07-18 (Asia/Shanghai)

### Prerequisite

- [x] Goal 1 is complete on `main`; clean Windows PowerShell 5.1 and
  PowerShell 7 jobs passed import, generated-artifact, capability, completion,
  and current-user layout acceptance.

### Implementation Checklist

- [x] Pin and bundle PSReadLine `2.4.5` from an official immutable package.
- [x] Apply Amendment 1: PSCompletions is out of scope for v0.1.0 and is not
  bundled; its package, verifier entries, and license entry were removed.
- [x] Record the PSReadLine source URL/SHA256 and retain its upstream license.
- [x] Import fixed bundled PSReadLine only and use a Psh-owned offline Git
  completion adapter.
- [x] Bind Tab to `MenuComplete` and Ctrl+R to reverse history search.
- [x] Bind Up/Down arrows to prefix history search.
- [x] Configure prediction source `History` and view style `ListView` when the
  host supports it, with a safe documented fallback.
- [x] Add a compact ASCII prompt with path, previous status, and optional Git
  branch without requiring a Nerd Font.
- [x] Provide a safe non-VT fallback and verify no startup blocking path.
- [x] Validate profile markers strictly and stop on malformed marker state.
- [x] Back up and losslessly update both Windows PowerShell and PowerShell 7
  CurrentUserAllHosts profiles using one marked loader block.
- [x] Make profile update idempotent and restore exact pre-existing bytes on
  removal.
- [x] Add PS5.1-compatible automated tests for dependency pins, key bindings,
  prompt behavior, Unicode/space paths, profile backup/restore, malformed
  markers, and startup timing.
- [x] Run the Goal 2 automated matrix in Windows PowerShell 5.1 and PowerShell
  7 CI.
- [x] Retain the pre-Amendment real Windows 11 ARM64 interactive evidence as
  grandfathered evidence; no VM or evidence redo is required.
- [x] Review the Goal 2 diff for secrets, caches, binaries, and unrelated files.
- [x] Commit Goal 2 closeout, push it, record final CI, and merge to `main`.

### StopIf Checks

| Condition | State | Evidence / action |
| --- | --- | --- |
| Existing profile markers are malformed | NOT HIT | Five unmatched, duplicated, reversed, inline, or modified variants caused whole-batch refusal with zero profile/state writes. Both real-VM strict session records verify one exact ordered marker pair in each target profile. |
| VT is unavailable with no safe fallback | NOT HIT | Both real VS Code sessions reported supported terminal capabilities and enabled `History + ListView`. Redirected-output automation still verified the ANSI-free prompt and structured non-VT fallback. |
| Profile adds more than 1000 ms to cold shell startup | NOT HIT | Real ARM64 profile probes measured WinPS `832/730 ms` cold/warm and PowerShell 7 `866/807 ms`; both cold measurements are below `1000 ms`, with one output record, zero jobs, and no PSCompletions import. |

### Execution Policy Authorization

- On 2026-07-19 the user authorized `RemoteSigned` at `CurrentUser` only.
  Windows PowerShell retained `MachinePolicy`, `UserPolicy`, `Process`, and
  `LocalMachine` as `Undefined`. No `Bypass` process or GPO change was used.
- PowerShell 7's official MSIX package independently reports
  `LocalMachine=RemoteSigned` from its immutable `$PSHOME/powershell.config.json`.
  The acceptance run did not write that package file; its audited SHA-256 is
  `98c0e5b6ee17eb8b8f4e4940c2b2528689cec8470db4bde427ad16d90d6a52d4`.
  The CurrentUser config and complete scope evidence are retained in both
  `prepare.json` and the PowerShell 7 session JSON.

### DoneWhen Audit

- [x] On Windows x64 CI, `Get-PSReadLineKeyHandler` lists Tab `MenuComplete`,
  Ctrl+R reverse history, and Up/Down prefix history bindings.
- [x] On Windows x64 CI, prediction reports `History` with `ListView` (or the
  documented safe fallback).
- [x] On Windows x64 CI, the prompt renders previous status, a Chinese-and-space
  path, and an optional Git branch in a headless session.
- [x] On Windows x64 CI, profile install and uninstall round-trip bytes exactly.
- [x] The pre-Amendment VM interaction evidence is retained as accepted
  grandfathered evidence and is not redone.

### Automated Evidence

- Dependency verifier output after Amendment 1: `1 fixed PSReadLine component, 7
  independently pinned runtime files, and 1 verified license`. A negative
  fixture that changed a vendored file and its lock entry together was still
  rejected by the independent trusted manifest.
- Package SHA256: PSReadLine `2.4.5`
  `cb9390e9733208456c234a7971d1ec4a917886c239502aab68f4b71aa4bba235`;
  PSCompletions is not present in the v0.1.0 dependency set.
- Local runtime: official portable PowerShell `7.6.3` for macOS ARM64,
  archive SHA256
  `f0263c2072fe7d0953781c60497a574bea99b37237f2554a59ce4bad07de8d36`.
- Goal 2 implementation and Windows acceptance fixes:
  `c1d0047c8a0505b46cfcb2146a58aec3ec1467c3`,
  `0f872860c9b86e68812f961b30561c88e72eb937`,
  `2eaac03b1ad8692b9e5093361b3362381c1f9620`, and
  `380726f1b5f32b5e656e1f0742a71626e3a8cf8b`,
  `ecaa674611a9f3c229456d59ead178e7135f800f`,
  `589650805b241c781d065a8102151f1e155f2b1e`, and
  `2412eb252481d8eafe2637090ac947a9337df4f6`.
- Pre-closeout implementation CI: <https://github.com/Emvdy/psh/actions/runs/29669928412>,
  conclusion `success` at head `2412eb252481d8eafe2637090ac947a9337df4f6`;
  retained as historical evidence, not the final closeout run.
- Final closeout branch CI: <https://github.com/Emvdy/psh/actions/runs/29682778462>,
  conclusion `success` at cleanup commit `20a4e599c811d7c3ee9043af77b0588d8ff6e120`.
  Windows PowerShell 5.1 job `88181796817` and PowerShell 7 job `88181796825`
  both succeeded.
- Final `main` CI: <https://github.com/Emvdy/psh/actions/runs/29682842951>,
  conclusion `success` at the same commit. Windows PowerShell 5.1 job
  `88181973143` and PowerShell 7 job `88181973157` both succeeded. Local
  `main` and `origin/main` both point at
  `20a4e599c811d7c3ee9043af77b0588d8ff6e120`.
- Windows PowerShell job used `5.1.26100.32995`, PSEdition `Desktop`; the
  PowerShell job used `7.6.3`, PSEdition `Core`, platform `Win32NT`. Both used
  Git for Windows `2.55.0.windows.2` and passed generated-artifact checking,
  Goal 1 regression, the independent dependency verifier, and full Goal 2
  acceptance.
- The Windows matrix exercised the real fixed PSReadLine completion core in a
  runner with no usable console handle by injecting only a test `IConsole`;
  `_mockableMethods` remained the production singleton and singleton state was
  restored after the call. It also drained 6,000 valid LF-formatted packed refs
  and returned the deterministic 4,096-candidate cap on both runtimes.
- Goal 1 regression passed after bundling the managed PSReadLine assemblies.
- Goal 2 acceptance passed dependency isolation, actual PSReadLine
  implementation-assembly hash verification, exact handlers, engine-native Git
  command/ref completion in a Chinese and space-containing path, the real
  PSReadLine `GetCompletions` path, a 6,000-ref pipe-drain case capped at 4,096
  results, prompt status, Git branch, `LASTEXITCODE`, missing-prompt
  degradation, and profile tests.
- Assembly conflict coverage preserved a pre-existing correct bundled module
  while restoring a second conflict after forced verification failure. A fresh
  child process preloaded a one-byte-altered PSReadLine DLL and verified
  structured refusal plus exact module rollback.
- Profile coverage passed UTF-8 LF/no-BOM, UTF-8 BOM/CRLF, UTF-16LE/CRLF,
  empty and originally absent files; repeat install; exact uninstall; outside
  edits; marker conflicts; modified backup; modified managed block; real
  bootstrap scope isolation; `WarningPreference=Stop`; relative paths; atomic
  displaced-byte compare/exchange; unread recovery interleavings; and a
  cross-process state-root mutex with trailing-separator normalization. Windows
  CI additionally runs two system-ANSI round trips.
- Fresh local timing: 229 ms cold, 73 ms warm, zero jobs, PSReadLine assembly
  state `fixed-path`, and Git registrar `NativeArgumentCompleter` using the
  explicit native switch.
- Diff review found no cache, temporary, credential, or unrelated files and no
  common private-key/token signatures. No dedicated secret-scanner executable
  was installed locally; later Goal 6 CI retains the mandatory scanner gate.
- Amendment 1 removes PSCompletions from the shipped dependency set. The
  grandfathered evidence records why its import was suppressed; no package,
  verifier entry, or license entry remains in the v0.1.0 tree.
- During early CI diagnosis the `Windows 11` VM was temporarily resumed only
  for read-only availability checks. The later user-authorized CurrentUser
  policy change and official Git/VS Code setup are fully captured by the final
  VM evidence below; no GPO or Windows PowerShell LocalMachine scope changed.

### Grandfathered Real VM Evidence (retained as-is; no redo)

- Stable pre-Amendment evidence root (preserved without rerun):
  `evidence/goal2/goal2-20260719T025655Z-2412eb25/`. Its `README.md` maps each
  DoneWhen item to direct screenshots, records the input method, and explains
  the PowerShell 7 packaged policy configuration. `SHA256SUMS` covers the
  README, 9 original logs/JSON files, and 19 screenshots.
- VM prepare record SHA-256:
  `c3f3fc8d934f3167b6ca47c45899b08945ea17983f3beab0af35954a03186110`.
  It proves non-elevated Windows 11 ARM64, VS Code `1.126.0` ARM64, PowerShell
  extension `2025.4.0`, PowerShell `7.6.3` ARM64, Git for Windows
  `2.55.0.windows.3` AA64, both profile targets, and four startup probes.
- Windows PowerShell strict session record SHA-256:
  `6d9899a133fa72400ffb3480990f287d412c4b8f30e3d71024e5a7d12d004fbd`.
  PID `11768` reported Desktop `5.1.26100.8655`, ARM64, ConsoleHost, VS Code
  shell integration, exact handlers, `History + ListView`, and the accepted
  CJK/space Git fixture.
- PowerShell 7 strict session record SHA-256:
  `b6cfc38d19556b348da62ea70a205445b68f6b115926fec3aeaeb1080d5c17d4`.
  PID `1572` reported Core `7.6.3`, ARM64, ConsoleHost, and the same strict
  interaction, projection, prompt, profile, shell-integration, and Git state.
- Both sessions loaded exactly one PSReadLine `2.4.5` assembly from the
  CurrentUser projection. The implementation DLL SHA-256 is
  `f8e3a5b7e3e8cad2130ce10647564a2a0ea15d98db8a0cc8d589f80154c108e2`;
  the accepted VS Code `shellIntegration.ps1` SHA-256 is
  `7d27a8cce8c3b9a7e6cb0045a2035f303c34d228b23b6619fed1934a4027a4db`.

### Remaining Work

None. Goal 2 is complete at `20a4e599c811d7c3ee9043af77b0588d8ff6e120`:
Amendment 1 cleanup is merged to `main`, both final CI workflows are green, and
the automated Windows x64 DoneWhen checks plus grandfathered VM evidence are
recorded. No VM or `evidence/goal2` redo was performed or required.

## Goal 3: Command Compatibility Layer

Started: 2026-07-19 (Asia/Shanghai)

### Prerequisite

- [x] Goal 2 is complete on `main` at `20a4e599c811d7c3ee9043af77b0588d8ff6e120`;
  final branch and `main` CI runs above are green.

### Batch Status

| Batch | Scope | Status |
| --- | --- | --- |
| 1 | File commands | COMPLETE |
| 2 | Text search | PENDING |
| 3 | Complex `sed`/`awk`/`jq`/`xargs` | PENDING |
| 4 | System/network/archive | PENDING |

Each batch must end with its own implementation, batch tests, commit, and green
CI before the next batch begins. Goal 3 is not complete.

### StopIf / DoneWhen

- **StopIf:** Unsupported flags are silently accepted, text commands leak
  formatted PowerShell objects, destructive tests escape their temporary
  directory, or Core secretly uses Full tools.
- **DoneWhen:** The specification generator `-Check` passes; every command has
  at least one behavior test appropriate to its tier; Tier 1 text commands pass
  golden comparison; Core/Full differences are documented.

### Batch 1 Evidence

- Implementation head: `0281ff712dcc761804a7709ea1904e1745ab2883` (`fix:
  handle Windows link metadata and empty output`). The batch changes preserve
  strict configuration snapshots, project built-in aliases across caller
  scopes, and use reparse-safe Windows link and move transactions.
- CI run: <https://github.com/Emvdy/psh/actions/runs/29696568353>, head
  `0281ff712dcc761804a7709ea1904e1745ab2883`, conclusion `success`.
- CI jobs, all conclusion `success`:
  - [GNU Tier 1 goldens](https://github.com/Emvdy/psh/actions/runs/29696568353/job/88218227648)
    generated and uploaded the deterministic golden artifact.
  - [Windows PowerShell 5.1](https://github.com/Emvdy/psh/actions/runs/29696568353/job/88218243914)
    ran the Batch 1 validation and regression suite.
  - [PowerShell 7](https://github.com/Emvdy/psh/actions/runs/29696568353/job/88218243919)
    ran the same Batch 1 validation and regression suite.
- Implemented file commands (21): `pwd`, `cd`, `ls`, `mkdir`, `rmdir`, `cp`,
  `mv`, `rm`, `touch`, `ln`, `realpath`, `basename`, `dirname`, `stat`, `file`,
  `tree`, `find`, `fd`, `du`, `df`, and `mktemp`.
- Validation summary: FileCommands covered all 21 commands with 374
  assertions; the GNU golden contract was rerun locally with 418 assertions;
  AliasScope passed 16 assertions; Config passed 80 assertions. The same
  branch CI also passed Goal 1 and Goal 2 regressions, the dependency verifier,
  generated-artifact `-Check`, PowerShell AST validation for 29 files,
  `actionlint`, and `git diff --check`.
- Batch 1 safety coverage includes binary and line-ending preservation,
  Unicode and space-containing paths, destructive-directory containment,
  collision and disabled-command restore behavior, symbolic-link metadata and
  target preservation, and empty golden-output handling.

### Remaining Work

Proceed to Batch 2 (text search) with its own implementation, tests, commit, and
green CI gate; then complete Batches 3 and 4 in order. Do not mark Goal 3
complete before all four batch gates pass.
