// This repository's own entry point, and the shape the README asks every
// consumer to write: the project owns the entry point, because the project owns
// the verbs. A project with verbs passes them here —
//
//   exitCode = await runXtask(args, verbs: {'regen': regen});
//
// — while `xtask` itself registers none yet: the built-in `remove` is the
// engine's, and no job in this repository needs real logic so far.
//
// The file name is the declaration. `dart run :xtask` resolves to this path and
// nothing else; no manifest entry names it.
//
// It is also what `dart install xtask` compiles, so it is the `xtask` on a
// PATH — and in a repository with a `bin/xtask.dart` of its own, that is not
// the entry point the verbs are in. There it hands the run over to the
// project's (`projectEntry`), and answers with what that one answers.
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
