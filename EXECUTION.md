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
| Goal 3 | COMPLETE | `9254f3b` | Merged to `main` at `71fbda8`; final branch and `main` CI green |
| Goal 4 | IN_PROGRESS | `5d0477c` | Branch DoneWhen green; evidence commit and `main` merge pending |
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
| 2 | Text search | COMPLETE |
| 3 | Complex `sed`/`awk`/`jq`/`xargs` | COMPLETE |
| 4 | System/network/archive | COMPLETE |

All four batches ended with their own implementation, tests, commit chain, and
green final branch CI. Goal 3 DoneWhen is complete on this branch.

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

### Batch 2 Evidence

- Implementation and Windows-harness fix chain: `ba5548622e004682377d5c6fe6c14b83c3e7e4ec`
  (`feat: add Goal 3 Batch 2 text commands`),
  `41d6b1abc781cdbb2dd493ea306d51f8315c9358` (`test: stabilize Batch 2
  Windows text checks`), `15ee5db009065048d57c647a96779212a030353c`
  (`test: clear expected native failure status`), and
  `e18dba49c3ed76f3ff51700404e57d5203d9e357` (`test: normalize batch 2
  harness exit status`).
- Batch 2 CI run: <https://github.com/Emvdy/psh/actions/runs/29699973023>,
  head `e18dba49c3ed76f3ff51700404e57d5203d9e357`, conclusion `success`.
  All jobs succeeded:
  - [GNU Tier 1 goldens](https://github.com/Emvdy/psh/actions/runs/29699973023/job/88227259616)
    generated and uploaded the deterministic text-command golden artifact.
  - [Windows PowerShell 5.1](https://github.com/Emvdy/psh/actions/runs/29699973023/job/88227272787)
    ran the Batch 2 validation and regression suite.
  - [PowerShell 7](https://github.com/Emvdy/psh/actions/runs/29699973023/job/88227272803)
    ran the same Batch 2 validation and regression suite.
- Batch 1 regression CI rerun: <https://github.com/Emvdy/psh/actions/runs/29699973031>,
  conclusion `success`; GNU `88227259630`, Windows PowerShell 5.1
  `88227272868`, and PowerShell 7 `88227272891` all succeeded.
- TextCommands covered 15 commands with 214 assertions without a golden root
  and 251 assertions with GNU golden comparisons. Coverage includes text and
  raw-byte paths, Tier 2 search flags, Core/Full delegation, downstream
  pipeline contracts, Unicode fixtures, and structured object APIs.
- The implementation gate passed generated-artifact `-Check`, PowerShell AST
  validation for 21 files, `actionlint`, `shellcheck`, `bash -n`, and
  `git diff --check`.
- The known Batch 1 macOS-only golden replay mismatch remains unchanged: the
  sandbox can spell the same temporary path as `/var` versus `/private/var`.
  Ubuntu-generated goldens and both Windows CI runtimes remain green; Batch 2
  did not alter Batch 1 behavior or its normalization contract.

### Batch 3 Evidence

- Implementation and stabilization chain:
  `c267e47f23ff383236e20ee35b891951239024b2` (`feat: add Goal 3 Batch 3
  complex commands`), `fd935ca9af3b482aa229494f283bc2f253db0dbd` (`fix:
  stabilize Batch 3 Windows sed behavior`),
  `ba48cc70d3c744376fd3020704a8b53e6333ca48` (`fix: harden Batch 3 Windows
  sed transactions`), `561f6c3395e3a9cf72ae4a24363498d14cd3c50b` (`fix:
  preserve single-record sed input on WinPS`),
  `107453927804041e8cfbf68f5eb1cb7f473f8b6f` (`fix: restore exact Windows
  sed DACL`), `3e15b5a59f96bd8d2d916132e373fa51656211f6` (`test: normalize jq keys
  across PowerShell`), `23ebc308f717f50b42f348df840f8141990e4fca` (`test:
  diagnose native jq byte forwarding`), and
  `7c9bbafada62db07ab16a2e16d0686521ad52108` (`fix: prevent WinPS native
  stdin BOM`).
- Batch 3 CI run: <https://github.com/Emvdy/psh/actions/runs/29707922858>,
  head `7c9bbafada62db07ab16a2e16d0686521ad52108`, conclusion `success`.
  Both jobs succeeded:
  - [Windows PowerShell 5.1](https://github.com/Emvdy/psh/actions/runs/29707922858/job/88247861546)
    ran the Batch 3 validation and regression suite.
  - [PowerShell 7](https://github.com/Emvdy/psh/actions/runs/29707922858/job/88247861575)
    ran the same Batch 3 validation and regression suite.
- Final regression CI at the same head also passed:
  [Batch 1](https://github.com/Emvdy/psh/actions/runs/29707922918) succeeded
  for GNU Tier 1 goldens (`88247861666`), Windows PowerShell 5.1
  (`88247872785`), and PowerShell 7 (`88247872794`); [Batch
  2](https://github.com/Emvdy/psh/actions/runs/29707922859) succeeded for GNU
  Tier 1 goldens (`88247861540`), Windows PowerShell 5.1 (`88247873268`), and
  PowerShell 7 (`88247873296`).
- Coverage includes Core implementations and Full native delegation for
  `sed`, `awk`, `jq`, and `xargs`; exact native argument forwarding; and exact
  UTF-8 pipeline input without a Windows PowerShell BOM.
- Windows `sed -i` coverage verifies encoding, BOM, line-ending, and final
  newline preservation; atomic failure recovery; transaction cleanup; mtime
  updates; and exact original DACL restoration.
- The final Batch 3 validation covered all four commands with 336 assertions in
  both Windows runtimes.

### Batch 4 Evidence

- Implementation and stabilization chain:
  `42ef4afebff6ad5740c5f7f9e7523b725c5066b7` (`feat: add Goal 3 Batch 4
  compatibility commands`),
  `48027b48d5c8b41411e43d45394d63905441e948` (`fix: preserve env assignment
  order`), `468b447836795a7c7830116529295765eb29f6be` (`test: compare env output by
  variable name`), `919ffe04833ae74d583047c8b1e45c18a03e5e57` (`test: allow timeout
  fixture trailing argv`), `df30303ce6c0b020eb92c4645379fc2b93b16e28` (`fix: bound timeout
  pipe capture`), `03afecf5bf82afcb2a4a93d8efdef085ddd8fe83` (`test: synchronize
  timeout pipe fixture`), `f13e5d4c138a6b5a6467c671a960d3f5403bab15` (`test: inherit timeout
  pipe handles explicitly`), `283d8b74ad3dd9b884acdd772b7c1b00dd3f69e5` (`test: preserve
  all-scope network aliases`), and
  `9254f3bb93b11a470b82b7d06ade55d017203239` (`test: expect GNU checksum
  escaping`).
- Final Batch 4 CI run:
  <https://github.com/Emvdy/psh/actions/runs/29731161836>, head
  `9254f3bb93b11a470b82b7d06ade55d017203239`, conclusion `success`.
  All jobs succeeded:
  - [GNU system/process and checksum goldens](https://github.com/Emvdy/psh/actions/runs/29731161836/job/88315734806)
    generated and verified the deterministic golden artifact.
  - [PowerShell 7](https://github.com/Emvdy/psh/actions/runs/29731161836/job/88315766852)
    ran the Batch 4 validation and full regression suite.
  - [Windows PowerShell 5.1](https://github.com/Emvdy/psh/actions/runs/29731161836/job/88315766907)
    ran the same Batch 4 validation and full regression suite.
- Retained Batch 4 artifacts:
  - `goal3-batch4-gnu-goldens`, artifact ID `8456322963`, contains
    `manifest.json`, `SHA256SUMS`, and `toolchain-report.txt`.
  - `goal3-batch4-report-pwsh7`, artifact ID `8456391105`, contains
    `validation-transcript.txt` for PowerShell 7.
  - `goal3-batch4-report-winps51`, artifact ID `8456388958`, contains
    `validation-transcript.txt` for Windows PowerShell 5.1.
- Final regression runs at the same head all concluded `success`: [Batch
  1](https://github.com/Emvdy/psh/actions/runs/29731161851), [Batch
  2](https://github.com/Emvdy/psh/actions/runs/29731161803), [Batch
  3](https://github.com/Emvdy/psh/actions/runs/29731161826), and [Batch
  4](https://github.com/Emvdy/psh/actions/runs/29731161836).
- Batch 4 covers 24 commands: 15 system/process commands (`which`, `env`,
  `printenv`, `export`, `test`, `sleep`, `date`, `whoami`, `hostname`, `clear`,
  `ps`, `kill`, `pgrep`, `pkill`, and `timeout`), two network commands (`curl`
  and `wget`), and seven archive commands (`tar`, `zip`, `unzip`, `gzip`,
  `gunzip`, `sha256sum`, and `md5sum`).
- Both Windows runtimes passed 766 system/process assertions plus four GNU
  comparisons, 124 network assertions, and 283 archive assertions with GNU
  checksum goldens.
- The local Unix archive replay passed 285 assertions. Its only two additional
  assertions are the explicitly non-Windows native `tar` and `gzip` format
  oracles; both Windows runs still executed the six-assertion filesystem
  symlink/reparse input and extraction-safety block.

### DoneWhen Audit

- [x] `scripts/Generate-CommandArtifacts.ps1 -Check` passed in both final
  Windows jobs.
- [x] Behavior tests cover all 64 commands: Batch 1 has 21, Batch 2 has 15,
  Batch 3 has four, and Batch 4 has 24.
- [x] Tier 1 GNU golden comparison passed for Batches 1 and 2; Batch 4 adds six
  comparisons, comprising four system/process comparisons and two checksum
  comparisons.
- [x] Core/Full differences are generated from
  `src/Psh/Specification/commands.psd1` into `docs/compatibility.md`. Full uses
  native backends only for `rg`, `fd`, `jq`, and `bat`; every Batch 4 command is
  PowerShell-backed in both editions, and the broader PowerShell
  `curl --connect-timeout` budget is documented.

### StopIf Audit

- Unsupported or invalid syntax is rejected with exit code `2`; it is not
  silently accepted.
- Text output remains strings, while binary command paths use the tested raw-byte
  sink rather than formatted PowerShell objects.
- Destructive fixtures remain inside unique temporary roots. Traversal,
  absolute/drive/UNC paths, archive link metadata, filesystem symlinks/reparse
  points, outside sentinels, and transaction cleanup are covered.
- Core/Full parity checks passed. Core does not use Full tools, and the only Full
  native backends are the four documented commands above.

No Goal 3 StopIf condition was hit.

### Remaining Work

None. Goal 3 was fast-forward merged to `main` at
`71fbda8d27877a091caaecbf0f1617ab8133644c`. Final `main` validation runs all
concluded `success` at that head:

- [Core validation](https://github.com/Emvdy/psh/actions/runs/29735749344)
- [Batch 1](https://github.com/Emvdy/psh/actions/runs/29735749348)
- [Batch 2](https://github.com/Emvdy/psh/actions/runs/29735749357)
- [Batch 3](https://github.com/Emvdy/psh/actions/runs/29735749358)
- [Batch 4](https://github.com/Emvdy/psh/actions/runs/29735749343)

## Goal 4: Full Tools And Supply Chain

Started: 2026-07-20 (Asia/Shanghai)

### Prerequisite

- [x] Goal 3 is fast-forward merged to `main` at
  `71fbda8d27877a091caaecbf0f1617ab8133644c`, and all five final `main` CI runs
  above are green.

### StopIf / DoneWhen

- **StopIf:** A checksum mismatches, a license cannot be aggregated with GPL, or source and tag differ.
- **DoneWhen:** Core remains functional after deleting `tools`, and Full reports every pinned (or documented-degraded) tool version on x64 CI.

### Locked Supply Chain

- The lock records stable `bat` `0.26.1`, `fd` `10.4.2`, `jq` `1.8.2`, and
  `rg` `15.2.0` for both `win-x64` and `win-arm64`; all eight executables are
  official architecture-matched release assets, so no ARM64 degradation was
  required.
- Tags resolve to fixed source commits: bat
  `979ba22628bc9d8171f2cffca2bd5c90c9fc0a9e`, fd
  `7027d45303b412be6fa9c09d689cc6276748fb38`, jq
  `34f7186b86743a083a589741b6cea95293524108`, and ripgrep
  `e89fff89ac9af12e8d4ce9d5fd07beb408ca730f`. Download URLs are versioned,
  numeric release-asset locators are retained, and no `latest` reference is
  used.
- `THIRD_PARTY_NOTICES.md`, retained upstream license files, provenance records,
  and `sbom.spdx.json` are generated from the lock. The deterministic lock
  summary SHA256 is
  `1cd062f042777a4cdc570ddd1d85b2562532473d7f95de21e8603f7544bcda64`.

### Evidence Collected

- Implementation commits:
  `02ef8609b637e6a0533cd5c452f93d6083326325` (`feat: add Full native tools
  supply chain`), `498793c96291c2475b62a09c826fa8294038f018` (`fix: stabilize
  native tool CI probes`), and
  `382cd4b97af60b51596624774f5b878703c75dc6` (`fix: pin ripgrep revision
  probe`). The ripgrep probe is fixed to the release binary's exact
  `ripgrep 15.2.0 (rev e89fff89ac)` identity derived from the locked source
  commit.
- Regression-isolation commits:
  `2bad6a158f3025481cf8cc5fae7a9da1105a4389` (`test: isolate prompt error
  history assertion`) and `5d0477cbcfbf35f6c98524fe3a88202765379fff`
  (`test: clean junction fixtures safely`). These preserve the original Goal 2
  prompt assertion and make the Batch 2 reparse fixture cleanup safe on Windows
  PowerShell 5.1 without changing product behavior.
- Local PowerShell 7.6.3 validation at `5d0477c` passed: Goal 4 acceptance with
  693 assertions; native verification for four tools and eight
  architecture-specific executables; Goal 1 acceptance; Batch 2 with 238
  assertions; Batch 3 with 327 assertions; both artifact generators in `-Check`
  mode; official SPDX 2.3 schema validation; `actionlint`; and
  `git diff --check`.
- Final branch CI run:
  <https://github.com/Emvdy/psh/actions/runs/29757503335>, head
  `5d0477cbcfbf35f6c98524fe3a88202765379fff`, conclusion `success`.
  Both jobs and every test, smoke, report, and upload step succeeded:
  - [Windows PowerShell 5.1 x64](https://github.com/Emvdy/psh/actions/runs/29757503335/job/88403550592)
    ran PowerShell `5.1.26100.32995`, passed Goal 4 with 730 assertions and the
    complete Goal 1-3 regression suite, then passed the Core-without-tools smoke
    and Full x64 version report. Report artifact ID: `8467391121`.
  - [PowerShell 7 x64](https://github.com/Emvdy/psh/actions/runs/29757503335/job/88403550618)
    ran PowerShell `7.6.3`, passed the same Goal 4 and regression matrix, then
    passed the same Core and Full checks. Report artifact ID: `8467397009`.
- In both final jobs, supply-chain artifacts were current, the independent
  verifier accepted four fixed tools and eight executables, Core exposed all 64
  commands after the optional tools boundary and native lock were removed, and
  Full reported pinned x64 metadata plus exact executable and public-wrapper
  version probes for `bat`, `fd`, `jq`, and `rg`.

### DoneWhen Audit

- [x] Exact versions, tags, source commits, versioned download URLs, archive and
  installed SHA256 values, architectures, release-asset identities, and licenses
  are locked for all four tools.
- [x] Official x64 and ARM64 assets are retained for every tool; no executable
  was relabeled and no documented degradation was required.
- [x] Upstream licenses, provenance, notices, and the SPDX 2.3 SBOM are retained
  and deterministically generated.
- [x] Core remained functional with all 64 commands after deleting the optional
  tools boundary in both x64 CI runtimes.
- [x] Full reported every pinned x64 tool as `native:<name>` / `pinned`, with
  the locked version, SHA256, architecture, executable probe, and wrapper probe.

### StopIf Audit

- Independent verification accepted every archive, installed executable, and
  retained license hash; negative fixtures reject checksum and path tampering.
- The declared BSD-2-Clause, MIT/Apache-2.0, MIT with embedded notices, and
  Unlicense/MIT terms were retained with no GPL aggregation conflict.
- Every tag-to-source relationship and exact version probe is fixed and checked;
  source/tag or revision drift is rejected.

No Goal 4 StopIf condition was hit.

### Remaining Work

Commit and push this execution evidence, fast-forward Goal 4 to `main`, and
confirm the resulting `main` CI run before marking Goal 4 complete and starting
Goal 5.
