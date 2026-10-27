# Installing command-line tools

`cliInstall` and `cliUninstall` install what `dart build cli` leaves — a
bundle with `bin/` and `lib/` — for whoever runs the task, and remove it
again:

```dart
const cli = DartCli(
  name: 'mytool',
  bundles: ['build/cli/bundle', 'build/server/bundle'],
  commands: {'mytool': 'mytool', 'mytool-server': 'server'},
);

exitCode = await runXtask(args, verbs: {
  'install': cliInstall(cli),
  'uninstall': cliUninstall(cli),
});
```

```yaml
version: 1

tasks:
  build-cli:
    desc: build the command-line bundle
    run: [dart, build, cli]

  install:
    desc: put mytool on your PATH
    needs: [build-cli]
    do: install

  uninstall:
    desc: remove what install laid down
    do: uninstall
```

## Where it goes

Every bundle goes into one `~/.local/share/<name>/bin` and one `.../lib`, so
each executable finds every native library at `../lib`, where a Dart
executable looks. That makes a library — or an executable — two bundles carry
under one name a conflict unless it is the same file, and the install refuses
one that is not, before anything is copied. The bundles are copied into
`<name>.new` beside the earlier install and swapped in once the copy is whole,
so a copy that fails halfway leaves the earlier install working and answers
`1`, naming the file; an uninstall removes the `<name>.new` it leaves. Once
the new install is in place it has succeeded: an earlier one that cannot be
removed stays as `<name>.old-<time>`, and the next install removes it.

The directory carries a `.xtask_kit` file naming the tool, the mark that
tells it from a `~/.local/share/<name>` somebody else made: `~/.local/share`
is every application's, and the install refuses a `<name>` there without the
mark — before anything is copied — rather than replace it. The uninstall
leaves such a directory whole, and what on `PATH` links into it, says why,
and answers `0`.

Each command goes to `~/.local/bin`: a link on Linux and macOS, a copy on
Windows — no symlink without developer mode — with the libraries copied to
`~/.local/lib`, which is `../lib` from the copy.

## What is somebody else's

That directory is not only this tool's, so the install replaces only what it
laid down there: on Linux and macOS a link into `~/.local/share/<name>` — not
one pipx or `uv tool` made — on Windows a copy of an executable the earlier
install holds, written as `<command>.new` and renamed into place so that a
copy cut off halfway does not pass for somebody else's. Anything else of a
command's name is somebody else's; the install refuses, naming it, and the
uninstall leaves it and says so.

`retired:` names commands an earlier version put on `PATH` and this one does
not; both verbs remove them, under the same rule as any other command.

`adopt:` takes a `~/.local/share/<name>` without the mark as this tool's own
— the install a project's verbs laid down before it used this package — on
the evidence an `EarlierInstall` names: `linked: true`, a command or a retired
one on `PATH` linking into it (on Linux and macOS, where a command is a link),
or `files:`, a file from the directory only that install wrote, such as
`files: ['bin/BUILD']`. Either is enough for both verbs to treat it as
marked; without it, the directory is refused as before.

## Refusals and exit codes

The install refuses with `1`, before anything is copied, without `HOME` (on
Windows, `USERPROFILE`), where a bundle has not been built, where a command
starts an executable no bundle has, where two bundles carry different files
of one name, where a command's place on `PATH` is somebody else's, and where
`~/.local/share/<name>` is. A file
it cannot copy or remove answers `1` too, naming it; so does an uninstall
without `HOME`. `0` is the tool installed, or removed.

## On Windows

A running executable cannot be deleted but can be renamed, so what the install
cannot remove it moves aside as `<file>.old-<time>`, and the next install
removes what nothing holds any more — only names of exactly that shape, and
only on Windows; elsewhere nothing is moved aside, and a `.old-` file is
somebody's backup. It is meant to reinstall the
tool an editor is running; this package's own suite runs on Windows but does
not hold a file open while it does.

## As functions

`installCli` and `uninstallCli` are the same work as functions, for an install
that does more after it: call it first, and go on where it answers `0`.
