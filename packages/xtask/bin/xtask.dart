// The engine's entry point: what `dart install xtask` compiles, so it is the
// `xtask` on a PATH. It registers no verbs — the built-in `remove` is the
// engine's own, and every other verb is a project's.
//
// In a repository with a `bin/xtask.dart` of its own, that is the entry point
// the verbs are in, so this one hands the run over to it (`projectEntry`) and
// answers with what that one answers. Where there is none, the engine runs
// here. This repository is one of the first kind: its own entry point is the
// `bin/xtask.dart` at the root.
import 'dart:io';

import 'package:xtask/src/project_entry.dart';
import 'package:xtask/xtask.dart';

Future<void> main(List<String> args) async {
  final environment = Platform.environment;
  if (projectEntry(args, workingDirectory: Directory.current.path)
      case final entry?) {
    exitCode = await runProjectEntry(
      entry,
      environment: environment,
      err: stderr.writeln,
    );
    return;
  }
  exitCode = await runXtask(args);
}
