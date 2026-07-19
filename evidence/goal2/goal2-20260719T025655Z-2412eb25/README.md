# Goal 2 Windows 11 ARM64 Acceptance Evidence

This directory is the retained evidence set for the real-VM acceptance of
Goal 2. The evidence was captured from the Parallels VM named `Windows 11` at
runtime commit `2412eb252481d8eafe2637090ac947a9337df4f6`.

| Field | Value |
| --- | --- |
| Evidence ID | `goal2-20260719T025655Z-2412eb25` |
| Staged version | `0.1.0-vm.2412eb25` |
| VM UUID | `{acb3e79b-bc02-4c09-9620-275777f58a23}` |
| Guest | Windows 11, native ARM64, non-elevated user |
| Fixture | `C:\Users\emvdy\Psh 验收 空格\repo` |
| VS Code | `1.126.0`, ARM64 |
| PowerShell extension | `ms-vscode.powershell@2025.4.0` |
| Windows PowerShell | `5.1.26100.8655`, Desktop, ARM64 |
| PowerShell | `7.6.3`, Core, ARM64 |
| Git for Windows | `2.55.0.windows.3`, AA64 |
| Accepted branch | `feature/vscode-acceptance` |

The machine-readable source of truth for this table is
[`prepare.json`](logs/prepare.json). Its SHA-256 is
`c3f3fc8d934f3167b6ca47c45899b08945ea17983f3beab0af35954a03186110`.

## Execution Policy Boundary

The user authorized a CurrentUser-only `RemoteSigned` change on 2026-07-19.
No `Bypass` process was used, no Group Policy key was created or changed, and
the Windows PowerShell `LocalMachine` scope remained `Undefined`.

Windows PowerShell reported:

| Scope | Policy |
| --- | --- |
| MachinePolicy | `Undefined` |
| UserPolicy | `Undefined` |
| Process | `Undefined` |
| CurrentUser | `RemoteSigned` |
| LocalMachine | `Undefined` |

PowerShell 7 also reported `CurrentUser=RemoteSigned`. Its `LocalMachine`
display is `RemoteSigned` because the official packaged PowerShell 7.6.3 app
ships `$PSHOME\powershell.config.json` with that value. The package file was
audited read-only, not modified by this acceptance run, and has SHA-256
`98c0e5b6ee17eb8b8f4e4940c2b2528689cec8470db4bde427ad16d90d6a52d4`.
The separately written CurrentUser config has SHA-256
`07b07a34cba62b4a50e941fa9f568e2719c5573853ec2df77a4314f64c5d9bb2`.
Both strict session JSON files retain the complete scope and config evidence.

## Strict Session Evidence

| Shell | PID | Result | SHA-256 |
| --- | ---: | --- | --- |
| Windows PowerShell 5.1 | `11768` | [`winps51-arm64-session.json`](logs/goal2-20260719T025655Z-2412eb25-winps51-arm64-session.json) | `6d9899a133fa72400ffb3480990f287d412c4b8f30e3d71024e5a7d12d004fbd` |
| PowerShell 7.6.3 | `1572` | [`pwsh7-arm64-session.json`](logs/goal2-20260719T025655Z-2412eb25-pwsh7-arm64-session.json) | `b6cfc38d19556b348da62ea70a205445b68f6b115926fec3aeaeb1080d5c17d4` |

Each JSON was created inside the corresponding real VS Code integrated
terminal. Both prove:

- `ConsoleHost`, `TERM_PROGRAM=vscode`, native ARM64, and the expected shell
  version and edition;
- exactly one PSReadLine `2.4.5` module and one matching AppDomain assembly;
- the complete seven-file CurrentUser projection matches the bundled tree;
- the active implementation DLL SHA-256 is
  `f8e3a5b7e3e8cad2130ce10647564a2a0ea15d98db8a0cc8d589f80154c108e2`;
- the accepted VS Code `shellIntegration.ps1` SHA-256 is
  `7d27a8cce8c3b9a7e6cb0045a2035f303c34d228b23b6619fed1934a4027a4db`;
- `Tab=MenuComplete`, `Ctrl+r=ReverseSearchHistory`,
  `UpArrow=HistorySearchBackward`, and `DownArrow=HistorySearchForward`;
- `PredictionSource=History`, `PredictionViewStyle=ListView`, zero jobs, and
  zero imported PSCompletions modules;
- the CJK and space-containing fixture is both the Git root and current
  directory, with branch `feature/vscode-acceptance`;
- the compact ASCII prompt reports status, path, and Git branch before and
  after warm initialization.

The terminal sentinels are retained in
[`winps-session-ok.png`](screenshots/winps-session-ok.png) and
[`pwsh-session-ok.png`](screenshots/pwsh-session-ok.png). The PowerShell 7
image contains one discarded empty-`FixturePath` parameter attempt immediately
above the successful corrected command. That attempt wrote no JSON. The
corrected command is also retained in
[`pwsh-session-command.png`](screenshots/pwsh-session-command.png).

## Startup StopIf Evidence

All four fresh profile probes used `-NoExit`, exited `0`, emitted only their
single JSON probe line, loaded Psh and PSReadLine exactly once, imported no
PSCompletions module, and created no job.

| Shell | Probe | Duration | Log |
| --- | --- | ---: | --- |
| Windows PowerShell 5.1 | cold | `832 ms` | [`startup-winps51-cold.log`](logs/startup-winps51-cold.log) |
| Windows PowerShell 5.1 | warm | `730 ms` | [`startup-winps51-warm.log`](logs/startup-winps51-warm.log) |
| PowerShell 7.6.3 | cold | `866 ms` | [`startup-pwsh7-cold.log`](logs/startup-pwsh7-cold.log) |
| PowerShell 7.6.3 | warm | `807 ms` | [`startup-pwsh7-warm.log`](logs/startup-pwsh7-warm.log) |

Every result is below the enforced `5000 ms` threshold. The complete automated
VM acceptance output is retained in
[`goal2-winps51-arm64.log`](logs/goal2-winps51-arm64.log) and
[`goal2-pwsh7-arm64.log`](logs/goal2-pwsh7-arm64.log).

## Interactive Trace

The VM UI was controlled through `prlctl`; no host-wide screenshot was taken.
Plain text was sent through a short WScript helper invoked by `prlctl exec`.
Single-key interactions used guest scan codes (`Tab=15`, `Enter=28`,
`Up=72`, `Down=80`) or an equivalent guest Win32 key-down/key-up sequence.
`Ctrl+R` used one complete guest Win32 modifier sequence. Screenshots were
captured with `prlctl capture` after each observable state.

| Acceptance | Windows PowerShell 5.1 | PowerShell 7.6.3 |
| --- | --- | --- |
| Git command menu below prompt | [`winps-git-command-menu.png`](screenshots/winps-git-command-menu.png) | [`pwsh-git-command-menu.png`](screenshots/pwsh-git-command-menu.png) |
| History ListView | [`winps-prefix-before-up.png`](screenshots/winps-prefix-before-up.png) | [`pwsh-listview.png`](screenshots/pwsh-listview.png) |
| Reverse history search | [`winps-ctrl-r.png`](screenshots/winps-ctrl-r.png) | [`pwsh-ctrl-r.png`](screenshots/pwsh-ctrl-r.png) |
| Prefix history Up | [`winps-prefix-up.png`](screenshots/winps-prefix-up.png) | [`pwsh-prefix-up.png`](screenshots/pwsh-prefix-up.png) |
| Prefix history Down | [`winps-prefix-down.png`](screenshots/winps-prefix-down.png) | [`pwsh-prefix-down.png`](screenshots/pwsh-prefix-down.png) |
| Git ref completion | [`winps-git-ref-menu.png`](screenshots/winps-git-ref-menu.png) | [`pwsh-git-ref-menu.png`](screenshots/pwsh-git-ref-menu.png) |
| Completed ref executed | [`winps-git-ref-executed.png`](screenshots/winps-git-ref-executed.png) | [`pwsh-git-ref-executed.png`](screenshots/pwsh-git-ref-executed.png) |

The prompt in these images directly displays the Chinese and space-containing
path. The executed-ref images directly display the resulting
`feature/vscode-acceptance` branch.

## Integrity

`SHA256SUMS` covers this README, all original VM logs/JSON, and every retained
screenshot. It intentionally does not cover itself. Verify from this directory:

```text
shasum -a 256 -c SHA256SUMS
```
