# Running a shell script under bash

`bashScript()` runs a project's shell script under bash — on Windows Git's
bash, never WSL's launcher.

```dart
exitCode = await runXtask(args, verbs: {'bash': bashScript()});
```

```yaml
version: 1

tasks:
  release-notes:
    desc: write the release notes
    do: bash
    args: [tool/release_notes.sh]
```

The task's `args:` name the script first, then what it is given, and whatever
follows `--` comes after them. Off Windows it runs under the `bash` on `PATH`.

## On Windows

On Windows that program is the wrong one or none: a plain `PATH` has no bash
on it, and the one found first is often WSL's launcher in `System32`, which
runs the script in another machine's filesystem with another machine's tools.
So there it runs under Git's bash, looked for:

- beside the `git` on `PATH` — the Git the scripts and hooks already use;
- where `git --exec-path` says Git lives, for a shim such as Scoop's that
  stands somewhere else than the Git it starts;
- where Git for Windows installs itself: under `ProgramFiles`,
  `ProgramW6432`, `ProgramFiles(x86)`, and `LOCALAPPDATA\Programs`;
- last, a bash on `PATH` that is not in `System32` or `WindowsApps`.

## Refusals and exit codes

Without a script it refuses with `2`. On Windows with no Git's bash found it
answers `3`, a missing tool, saying where it looked. The script's own exit
code is the task's.

## As functions

`runBashScript` is the same as a function, for a verb that does more around
the script. `findBash(context)` answers which bash that is — `bash` off
Windows, Git's on it, null where there is none — for a verb that starts bash
itself, such as one running a suite of scripts. `findGitBash` is the Windows
search on its own, with everything it reads handed to it, for a test.
