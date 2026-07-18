# Current-User Installation Layout

Psh uses a versioned, current-user installation rooted at
`%LOCALAPPDATA%\Psh`. The layout contract is:

```text
%LOCALAPPDATA%\Psh\
|-- bootstrap.ps1
|-- config.psd1
|-- current.json
`-- versions\
    `-- <version>\
        `-- Psh\
            |-- Psh.psd1
            `-- ...
```

`<version>` is a semantic version such as `0.1.0`, without the release tag's
leading `v`. A version is eligible to become current only when
`versions\<version>\Psh\Psh.psd1` exists.

## Stable Files

`bootstrap.ps1` is the stable entry point for a shell session. It reads only
the adjacent local `current.json`, validates its schema and version, verifies
the selected module manifest, and imports that manifest into the session. It
does not download content, request elevation, change an execution policy,
change `PATH`, or edit a PowerShell profile.

`config.psd1` is current-user configuration shared by installed versions. Its
initial contents select the Core edition:

```powershell
@{
    SchemaVersion = 1
    Edition       = 'Core'
}
```

Version packages are immutable after their integrity has been verified. An
upgrade installs a new version directory rather than overwriting the selected
one.

## Version Pointer

`current.json` is local machine-readable state with this schema:

```json
{"schemaVersion":1,"version":"0.1.0"}
```

`Set-PshCurrentVersion.ps1` is the only primitive in this contract that writes
the pointer. Before writing, it validates the semantic version and the target
module manifest. It encodes a uniquely named temporary file as UTF-8 without a
BOM in the same directory as `current.json`, then performs one same-volume
filesystem operation:

- `File.Replace` with a unique same-directory backup when `current.json`
  already exists, followed by best-effort cleanup of that Psh-owned backup;
- `File.Move` when no pointer exists yet.

If validation or replacement fails, the previous `current.json` is left in
place and the script removes only the temporary and backup files it created.
The optional `-InstallRoot` parameter exists for installer staging and
isolated tests; the installed default remains `%LOCALAPPDATA%\Psh`.

## Lifecycle Status

These files define the Goal 1 layout and switching contract. They are not an
online or offline installer, do not modify PowerShell profiles, and do not
claim that a Psh release has been published. Staged installation, package
verification, profile backup and restoration, rollback retention, and
uninstallation belong to the Goal 5 installer lifecycle.
