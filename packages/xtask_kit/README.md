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
  `~/.local/bin` on its `PATH`;
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
executable looks. That makes a library two bundles carry under one name a
conflict unless it is the same file, and the install refuses one that is not,
before anything is copied.

Each command goes to `~/.local/bin`: a link on Linux and macOS, a copy on
Windows — no symlink without developer mode — with the libraries copied to
`~/.local/lib`, which is `../lib` from the copy. On Windows a running
executable cannot be deleted but can be renamed, so what the install cannot
remove it moves aside as `<file>.old-<time>`, and the next install removes
what nothing holds any more. It is meant to reinstall the
tool an editor is running; this package's own suite runs on Windows but does
not hold a file open while it does.

`retired:` names commands an earlier version put on `PATH` and this one does
not; both verbs remove them. `installCli` and `uninstallCli` are the same work
as functions, for an install that does more after it: call it first, and go
on where it answers `0`.

## License

MIT — see [LICENSE](LICENSE).
