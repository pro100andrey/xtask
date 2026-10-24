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
  working;
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

`uninstall` removes the link (if it is the install's own; anything else there
it leaves and says so), the menu entry, every icon named
for the application id, and the app's directory. It succeeds on a machine with
nothing installed.

## Refusals and exit codes

The install refuses, saying why, off Linux, without `HOME`, when the bundle
lacks a file `requires:` names, and when `~/.local/bin/<binary>` is something
other than a link into `~/.local/lib/<binary>` — a file, or a link pipx,
`uv tool` or another installer made, is somebody else's, and replacing it
would destroy it. A link into the app's own directory is the earlier
install's, dangling or not. Every refusal answers `1`, as does a copy that
fails; `0` is an app installed.

## On Windows and macOS

There is nothing to install there: the install refuses with `1`, and the
uninstall, finding nothing installed, answers `0`.
