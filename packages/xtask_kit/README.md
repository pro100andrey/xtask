# xtask_kit

Verbs for [`xtask`](https://pub.dev/packages/xtask) that projects otherwise
write again each.

A verb is a Dart function a project registers with `runXtask`. Some of them
turn out to be the same function in every project that has one — installing a
built Linux app under `~/.local` was written twice, line for line, before it
was written here. This package is those, configured with data and registered
like any verb of the project's own.

## Installing a Linux app

```dart
import 'dart:io';

import 'package:xtask/xtask.dart';
import 'package:xtask_kit/xtask_kit.dart';

const app = LinuxApp(
  binary: 'myapp',
  applicationId: 'dev.example.myapp',
  bundle: 'build/linux/x64/release/bundle',
  desktopEntry: 'linux/packaging/dev.example.myapp.desktop',
  requires: ['lib/libapp.so'],
  icons: IconTree('linux/packaging/icons/hicolor'),
);

Future<void> main(List<String> args) async {
  exitCode = await runXtask(args, verbs: {
    'install': linuxAppInstall(app),
    'uninstall': linuxAppUninstall(app),
  });
}
```

```yaml
tasks:
  build-linux:
    desc: build the release bundle
    run: [flutter, build, linux, --release]

  install:
    desc: install the app for you under ~/.local (Linux only)
    needs: [build-linux]
    do: install

  uninstall:
    desc: remove what install laid down
    do: uninstall
```

`install` puts:

- the bundle in `~/.local/lib/<binary>`, copied beside an earlier install
  first and swapped in, so a copy that fails halfway leaves the earlier one
  working;
- a link to it at `~/.local/bin/<binary>`;
- the menu entry in `$XDG_DATA_HOME/applications` (`~/.local/share` without
  it), its `Exec=` and `TryExec=` naming that link rather than the bare
  command — a session started by a display manager often has no
  `~/.local/bin` on its `PATH`. In `Exec=` the path is quoted where it has a
  space or another character the desktop entry specification reserves;
  `TryExec=` is a plain path and takes it as it is;
- the icons in `$XDG_DATA_HOME/icons/hicolor`.

It refuses, saying why, off Linux, without `HOME`, when the bundle lacks a
file `requires:` names, and when `~/.local/bin/<binary>` is something other
than a link — that file is somebody else's, and replacing it would destroy it.
It ends by saying whether `PATH` reaches what it installed: the build just
installed, another command of that name found first, or nothing.

Building is not the verb's job. A build that fails is the build's failure,
reported as one, and `--dry-run` shows its command line — neither is true of a
`flutter build` started from inside a verb.

`uninstall` removes the link (if it is one), the menu entry, every icon named
for the application id, and the app's directory. It succeeds on a machine with
nothing installed.

## Installing command-line tools

What `dart build cli` leaves — a bundle with `bin/` and `lib/` — installed for
whoever runs the task:

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

Every bundle goes into one `~/.local/share/<name>/bin` and one `.../lib`, so
each executable finds every native library at `../lib`, where a Dart
executable looks. That makes a library — or an executable — two bundles carry
under one name a conflict unless it is the same file, and the install refuses
one that is not, before anything is copied. The bundles are copied into
`<name>.new` beside the earlier install and swapped in once the copy is whole,
so a copy that fails halfway leaves the earlier install working and answers
`1`, naming the file.

Each command goes to `~/.local/bin`: a link on Linux and macOS, a copy on
Windows — no symlink without developer mode — with the libraries copied to
`~/.local/lib`, which is `../lib` from the copy. That directory is not only
this tool's, so the install replaces only what it laid down there: on Linux
and macOS a link, on Windows a copy of an executable the earlier install
holds. Anything else of a command's name is somebody else's; the install
refuses, naming it, and the uninstall leaves it and says so. On Windows a
running executable cannot be deleted but can be renamed, so what the install
cannot remove it moves aside as `<file>.old-<time>`, and the next install
removes what nothing holds any more — only names of exactly that shape, and
only on Windows; elsewhere nothing is moved aside, and a `.old-` file is
somebody's backup. It is meant to reinstall the
tool an editor is running; this package's own suite runs on Windows but does
not hold a file open while it does.

`retired:` names commands an earlier version put on `PATH` and this one does
not; both verbs remove them, under the same rule as any other command. `installCli` and `uninstallCli` are the same work
as functions, for an install that does more after it: call it first, and go
on where it answers `0`.

## Installing a VS Code extension

A project that builds a VS Code extension of its own installs the VSIX with
these. The extension is described by where it lives; its id and the file
`vsce package` writes are read from its `package.json` when the verb runs
(`<publisher>.<name>`, `<name>-<version>.vsix`), so a version bump does not
leave the install looking for the last build:

```dart
const extension = VsCodeExtension(directory: 'vscode');

exitCode = await runXtask(args, verbs: {
  'ext-install': vsCodeInstall(extension),
  'ext-uninstall': vsCodeUninstall(extension),
  'profiles': vsCodeProfiles(extension),
});
```

```yaml
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

VS Code installs extensions per profile, and `code --profile <name>` creates a
profile that does not exist rather than refusing — a mistyped name installs
into a new, empty one and reports success. So the profile, `-- --profile
<name>` or else `PROFILE` from the environment, is checked against the
profiles VS Code keeps, and a name not among them is refused, with the list.
Where that list cannot be read the name is used anyway, with a warning: not
being able to look is no evidence of a typo. Without a name the install goes
to the Default profile and says so.

The install is `--force`, so a rebuild of an unchanged version is installed
rather than declined. The uninstall asks what the profile holds first, and
succeeds where the extension is not there. `profiles` lists every profile with
the version of the extension it holds, or `—`.

Without `code` on `PATH` every verb answers `3` before anything else. An
unknown profile, an argument other than `--profile <name>`, a `package.json`
without `publisher`, `name` or `version`, and a VSIX not built yet are refused
with `1`. `installVsCodeExtension` and `uninstallVsCodeExtension` are the same
work as functions.

## Running a shell script under bash

```dart
exitCode = await runXtask(args, verbs: {'bash': bashScript()});
```

```yaml
tasks:
  release-notes:
    desc: write the release notes
    do: bash
    args: [tool/release_notes.sh]
```

The task's `args:` name the script first, then what it is given, and whatever
follows `--` comes after them. Off Windows it runs under the `bash` on `PATH`.
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

Without a script it refuses with `2`. On Windows with no Git's bash found it
answers `3`, a missing tool, saying where it looked. The script's own exit
code is the task's. `runBashScript` is the same as a function, for a verb that
does more around the script; `findGitBash` is the search on its own.

## Tests, package by package

`packageTests()` runs one package's tests with the runner it needs: `flutter
test` where its pubspec takes anything from the Flutter SDK (`sdk: flutter`,
in `dependencies` or `dev_dependencies`), `dart test` where it does not. The
engine never makes that choice by reading a pubspec; registering the verb is
the project making it.

```dart
exitCode = await runXtask(args, verbs: {'tests': packageTests()});
```

```yaml
sets:
  packages:
    include: [packages/*]
    containing: [pubspec.yaml]

tasks:
  pkg-test:
    desc: every package's tests, with the runner each needs
    each: packages
    in: $each
    do: tests
    args: [--reporter=failures-only]
```

The package is the nearest directory with a `pubspec.yaml` from the member up,
so a member can be the package's directory, its `pubspec.yaml`, or a path
inside it; without `each:` it is found from the task's `in:`. A task with
`each:` has to write `$each` somewhere, and `in: $each` is the place here —
`args:` go to the runner. The runner starts
in the package's directory, and the task's `args:` follow `test`.

A package without `test/` is skipped with a line, and succeeds. A failing
suite answers `1`, whatever the runner said; a runner that is not on `PATH` —
`flutter` on a machine with only Dart — answers `3`, asked before it starts. A member in no package is refused
with `2`; a `pubspec.yaml` that is not YAML answers `1`, naming the file.
`runPackageTests` is the same as a function, and `usesFlutter` the check on
its own.

## Publishing to pub

`pubPublish` publishes a package and does not report success until the
registry serves it:

```dart
exitCode = await runXtask(args, verbs: {
  'publish': pubPublish(const PubPackage('packages/my_pkg')),
});
```

```yaml
tasks:
  check:
    desc: the checks a release needs
    run: [dart, analyze, --fatal-infos]

  publish:
    desc: publish my_pkg to pub.dev and wait until it is served
    needs: [check]
    do: publish
```

An upload cannot be taken back, and a version cannot be uploaded twice, so
before it the verb checks:

- that the `pubspec.yaml` names the package and its version and does not say
  `publish_to: none`;
- that `CHANGELOG.md` names the version in a heading (`## 1.2.0`,
  `## [1.2.0] - 2026-10-23`, `# v1.2.0`) — pub.dev shows, for each version,
  the changelog it was uploaded with;
- that `git status` shows the package matching HEAD, untracked files
  included — pub packs the directory, not the index;
- that every file `dart pub publish --dry-run` lists is one git tracks — a
  `.pubignore` stops pub reading the `.gitignore` beside it, and pub never
  reads `.git/info/exclude`, so a file git ignores can be in the archive
  without `git status` showing it;
- that the registry does not already serve the version, and could be asked.

Then `dart pub publish --force` in the package, and a bounded wait,
`registryWaits` (about three and a half minutes), until the registry lists the
version. The registry is where pub uploads: the `publish_to:` URL, or
`PUB_HOSTED_URL`, or pub.dev, asked through
pub's API without a credential; a private registry that wants one takes a
`probe:` of the project's own.

Three endings. Nothing was uploaded: `2` where there is no package to publish
(no `pubspec.yaml`, no name or version, `publish_to: none`), `1` for any other
refusal. Uploaded and served: `0`. Uploaded, and the registry
has not served it in time: `4`. Pub answering other than `0` is not proof
that nothing went up, so the registry is asked once then: serving the version
is a `0`, not serving it a `1`, not answering a `4` — it may have been
uploaded. The upload is not undone, and a pipeline must
not read that as a failed publish — the registry will not take the version
again. `publishToPub` is the same as a function.

## License

MIT — see [LICENSE](LICENSE).
