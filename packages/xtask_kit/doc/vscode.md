# Installing a VS Code extension

A project that builds a VS Code extension of its own installs the VSIX with
`vsCodeInstall`, removes it with `vsCodeUninstall`, and lists the profiles
with `vsCodeProfiles`. The extension is described by where it lives; its id
and the file `vsce package` writes are read from its `package.json` when the
verb runs (`<publisher>.<name>`, `<name>-<version>.vsix`), so a version bump
does not leave the install looking for the last build:

```dart
const extension = VsCodeExtension(directory: 'vscode');

exitCode = await runXtask(args, verbs: {
  'ext-install': vsCodeInstall(extension),
  'ext-uninstall': vsCodeUninstall(extension),
  'profiles': vsCodeProfiles(extension),
});
```

```yaml
version: 1

tasks:
  ext-vsce:
    desc: build the extension's VSIX
    in: vscode
    run: [npx, --yes, '@vscode/vsce', package]

  ext-install:
    desc: install the built VSIX into PROFILE
    needs: [ext-vsce]
    do: ext-install

  ext-uninstall:
    desc: remove the extension from PROFILE
    do: ext-uninstall

  profiles:
    desc: the VS Code profiles, and the build each holds
    do: profiles
```

## Which profile

VS Code installs extensions per profile, and `code --profile <name>` creates a
profile that does not exist rather than refusing — a mistyped name installs
into a new, empty one and reports success. So the profile, `-- --profile
<name>` or else `PROFILE` from the environment, is checked against the
profiles VS Code keeps, and a name not among them is refused, with the list.
Where that list cannot be read the name is used anyway, with a warning: not
being able to look is no evidence of a typo. Without a name the install goes
to the Default profile and says so.

## What each verb does

The install is `--force`, so a rebuild of an unchanged version is installed
rather than declined. The uninstall asks what the profile holds first, and
succeeds where the extension is not there. `profiles` lists every profile with
the version of the extension it holds, or `—`.

## Refusals and exit codes

Without `code` on `PATH` every verb answers `3` before anything else. An
unknown profile, an argument other than `--profile <name>`, a `package.json`
without `publisher`, `name` or `version`, and a VSIX not built yet are refused
with `1`.

## On Windows

The verbs work the same there. `code` on Windows is a `.cmd` shim, which the
engine starts as it starts any `run:` body. The profiles are read from VS
Code's user directory: `%APPDATA%\Code\User` on Windows,
`~/Library/Application Support/Code/User` on macOS, and
`$XDG_CONFIG_HOME/Code/User` (`~/.config` without it) on Linux.

## As functions

`installVsCodeExtension` and `uninstallVsCodeExtension` are the same work as
functions.
