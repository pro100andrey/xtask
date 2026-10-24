# xtask_kit

Verbs for [`xtask`](https://pub.dev/packages/xtask) that projects otherwise
write again each.

A verb is a Dart function a project registers with `runXtask`. Some of them
turn out to be the same function in every project that has one — installing a
built Linux app under `~/.local` was written twice, line for line, before it
was written here. This package is those, configured with data and registered
like any verb of the project's own.

## Verbs

| Verb | What it does | Details |
| --- | --- | --- |
| `linuxAppInstall`, `linuxAppUninstall` | A built Linux app installed under `~/.local`, linked onto `PATH`, with its menu entry and icons. | [doc/linux-app.md](doc/linux-app.md) |
| `cliInstall`, `cliUninstall` | The bundles `dart build cli` leaves, installed with each command on `PATH`. | [doc/cli.md](doc/cli.md) |
| `vsCodeInstall`, `vsCodeUninstall`, `vsCodeProfiles` | A project's own VS Code extension installed into a profile that is checked to exist. | [doc/vscode.md](doc/vscode.md) |
| `bashScript` | A project's shell script run under bash — on Windows Git's bash, never WSL's launcher. | [doc/bash.md](doc/bash.md) |
| `packageTests` | One package's tests, with `flutter test` or `dart test` as its pubspec needs. | [doc/package-tests.md](doc/package-tests.md) |
| `pubPublish` | A package published to pub after the checks an upload needs, then waited for until the registry serves it. | [doc/publish.md](doc/publish.md) |

## Example

Installing a Linux app. The entry point registers the verbs:

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

and `xtask.yaml` names them in `do:`:

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

Building is not the verb's job. A build that fails is the build's failure,
reported as one, and `--dry-run` shows its command line — neither is true of a
`flutter build` started from inside a verb.

How to write a verb of your own, and everything else about the task file, is
in [`xtask`](https://pub.dev/packages/xtask)'s README.

## License

MIT — see [LICENSE](LICENSE).
