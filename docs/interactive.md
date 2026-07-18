<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Interactive shell behavior

Psh's interactive initializer is opt-in session setup. It verifies the copies
bundled with Psh at these fixed module-relative paths:

```text
Dependencies/PSReadLine/2.4.5/PSReadLine.psd1
Dependencies/PSCompletions/6.10.0/PSCompletions.psd1
Dependencies/interactive.lock.json
```

The initializer verifies both manifest names and exact versions from literal
paths and imports bundled PSReadLine 2.4.5 globally. It deliberately does not
execute the PSCompletions manifest: the unmodified 6.10.0 upstream manifest
starts a network-capable update job, writes below its module directory, and its
Gallery package does not contain Git completion. The original files remain
bundled and hash-verified for provenance; Psh uses an offline native Git
completion adapter instead. This avoids executing `ScriptsToProcess` while
retaining the pinned upstream artifact for audit and future review.

Interactive hosts commonly preload another PSReadLine copy. After validating
the fixed manifest, Psh removes loaded `PSReadLine` modules whose module base is
not the bundled directory, imports 2.4.5, and inspects the implementation
assembly behind `Set-PSReadLineOption`. Its SHA256 must match the bundled DLL.
Diagnostics report `fixed-path` when the bundled DLL is active,
`reused-identical` when the runtime has already loaded identical bytes from
another location, and `failed` for different bytes. Key bindings and prediction
are configured only through commands backed by the verified assembly. If the
fixed import or post-import verification fails, Psh preserves any correct module
that existed before the call, restores displaced modules, and reports both the
original and any restoration errors.

Initialization never searches `PSModulePath`, installs a module, downloads
content, requests elevation, changes execution policy, or changes `PATH`.
Tests and staged installations may pass an explicit dependency root or exact
manifest/directory paths, but the same fixed versions are required.

## Initialization contract

The profile loader calls:

```powershell
Initialize-PshInteractive -EnablePrompt
```

The complete optional parameters are `-DependencyRoot`, `-PSReadLinePath`,
`-PSCompletionsPath`, `-EnablePrompt`, `-DisableGitPrompt`, and
`-GitTimeoutMilliseconds` (25 through 2000 ms, default 150 ms). Without
`-EnablePrompt`, the initializer does not replace the session's existing
`prompt` function.

Initialization returns one diagnostic object instead of emitting setup text.
Its top-level fields are `schemaVersion`, `component`, `success`,
`dependencyRoot`, `powershell`, `terminal`, `dependencies`, `keyBindings`,
`prediction`, `gitCompletion`, `prompt`, `errors`, and `warnings`. Dependency
diagnostics record the expected, manifest, and loaded versions and paths, plus
the expected and actual implementation assembly paths and hashes and whether
execution was suppressed for the offline adapter. Binding, prediction, Git
completion, and prompt diagnostics distinguish requested, configured, safely
degraded, and failed states so `psh doctor` and tests can inspect behavior
without parsing display text.

## Keys and prediction

When bundled PSReadLine 2.4.5 loads, Psh configures:

| Key | PSReadLine function |
| --- | --- |
| `Tab` | `MenuComplete` |
| `Ctrl+R` | `ReverseSearchHistory` |
| `UpArrow` | `HistorySearchBackward` |
| `DownArrow` | `HistorySearchForward` |

History prediction uses source `History` and view style `ListView` only when
the fixed PSReadLine API and virtual-terminal support are both detected. A
redirected, non-VT, or older/incompatible host keeps the key bindings and
plain prompt, reports the prediction fallback in diagnostics, and does not
throw during shell startup.

Psh registers its Git completer through PowerShell's native argument-completion
API. Root command names are static and bundled in Psh. Ref completion for local
branches, remotes, and tags runs only when completion is requested, uses the
local `git` executable through the Process API, disables terminal prompting and
optional locks, and enforces the configured timeout. No command text is
evaluated and no network request is made during initialization.

PowerShell runtimes that expose the `Native` switch use
`Register-ArgumentCompleter -Native`. On a Windows PowerShell 5.1 runtime where
that optional switch is unavailable, `-CommandName` plus `-ScriptBlock` and no
`-ParameterName` selects the same engine native-completer registry implicitly.
This matters because PSReadLine's Tab handlers call
the engine's four-argument `CommandCompletion.CompleteInput` path, which invokes
the global `TabExpansion2` function. Psh does not replace or wrap that function;
its built-in implementation consumes the same engine native-completer registry.
Warm initialization republishes Psh's two Git entries if another module has
overwritten them.

## Prompt

The prompt is deliberately compact and uses ASCII decoration only:

```text
[0] C:\work\project (git:main)>
```

`[0]` means the previous PowerShell command succeeded and `[1]` means it did
not. The current path is displayed without ASCII transliteration, so Unicode
and Chinese paths remain readable. The Git segment is omitted outside a work
tree, when Git is missing, when `-DisableGitPrompt` is used, or when the probe
exceeds its timeout. Git standard error is captured, terminal prompting and
optional locks are disabled for the probe, and no network operation is
performed. The prompt never emits ANSI control sequences, so the same text is
the non-VT fallback and no Nerd Font is required.

## Release status

This page documents source currently under development for Goal 2. Psh
`v0.1.0` has not been published, and this is not an online or offline install
instruction. Profile backup, marked loader insertion, exact restoration, and
package installation are handled by their dedicated lifecycle components and
must pass the remaining Goal 2 and Goal 5 acceptance gates before release.
