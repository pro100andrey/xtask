# Installing a Linux app

`linuxAppInstall` and `linuxAppUninstall` install a built Linux app for
whoever runs the task, under `~/.local`, and remove it again. The app is
described by a `LinuxApp`; its icons are an `IconTree` or `IconFiles`.

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
version: 1

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

## What `install` puts

- the bundle in `~/.local/lib/<binary>`, copied beside an earlier install
  first and swapped in, so a copy that fails halfway leaves the earlier one
  working, with a `.xtask_kit` file in it naming the app's id — the mark
  that tells this install's directory from one of the same name somebody
  else put there;
- a link to it at `~/.local/bin/<binary>`;
- the menu entry in `$XDG_DATA_HOME/applications` (`~/.local/share` without
  it), its `Exec=` and `TryExec=` naming that link rather than the bare
  command — a session started by a display manager often has no
  `~/.local/bin` on its `PATH`. In `Exec=` the path is quoted where it has a
  space or another character the desktop entry specification reserves;
  `TryExec=` is a plain path, unquoted, with a `\` written `\\` as in any
  string of the entry;
- the icons in `$XDG_DATA_HOME/icons/hicolor`.

It ends by saying whether `PATH` reaches what it installed: the build just
installed, another command of that name found first, or nothing.

Building is not the verb's job. A build that fails is the build's failure,
reported as one, and `--dry-run` shows its command line — neither is true of a
`flutter build` started from inside a verb.

## What `uninstall` removes

`uninstall` removes the link, the menu entry, every icon named for the
application id, and the app's directory. It succeeds on a machine with nothing
installed.

All of it or none: where `~/.local/bin/<binary>` is anything but a link into
`~/.local/lib/<binary>`, or that directory is there without the install's
mark, the app installed here is somebody else's, and so are the menu entry
and icons named for its id. The uninstall then removes nothing, says why, and
answers `0`. Without the directory there is nothing of this install's to
remove but a link left dangling into it.

## Refusals and exit codes

The install refuses, saying why, off Linux, without `HOME`, when the bundle
lacks a file `requires:` names, and when `~/.local/bin/<binary>` is something
other than a link into `~/.local/lib/<binary>` — a file, or a link pipx,
`uv tool` or another installer made, is somebody else's, and replacing it
would destroy it. A link into the app's own directory is the earlier
install's, dangling or not. It refuses as well a `~/.local/lib/<binary>` that
has no `.xtask_kit` naming the app — an app unpacked there by hand, say —
rather than replace it whole. Every refusal answers `1`, as does a copy that
fails; `0` is an app installed.

## An install from before the kit

A project that installed its app with its own verbs before it used this
package left a `~/.local/lib/<binary>` with no mark, which the first install
after the move would refuse. `adopt:` says what shows that directory to be the
project's own:

```dart
const app = LinuxApp(
  // ...
  adopt: EarlierInstall(linked: true, files: ['BUILD']),
);
```

`linked: true` takes `~/.local/bin/<binary>` leading into the directory as
that, and `files:` any of the files named, from the directory, that only the
earlier install wrote. Either one is enough; the install then replaces the
directory, marked, and the uninstall removes it. Without the evidence, or with
a mark naming another owner, it is refused as before.

## On Windows and macOS

There is nothing to install there: the install refuses with `1`, and the
uninstall, finding nothing installed, answers `0`.
