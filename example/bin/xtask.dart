// The entry point a project writes, and the whole of what it has to write.
//
// `dart run :xtask <task>` resolves to this file by name. It exists for one
// reason: a verb is a function in THIS repository, and no engine shipped by
// somebody else can contain it.
import 'dart:io';

import 'package:xtask/xtask.dart';

/// A verb: ordinary Dart, given the arguments its task resolved to.
///
/// `context.args` here is the expanded `argv-from: sources` — the engine did
/// the globbing, so a verb never touches the filesystem to find out what it
/// was asked about.
Future<int> countLines(VerbContext context) async {
  var lines = 0;
  for (final relative in context.args) {
    lines += File(inside(context, relative)).readAsLinesSync().length;
  }
  final files = context.args.length;
  context.log('$lines lines in $files ${files == 1 ? 'file' : 'files'}');
  // The exit code is the run's. A verb is written against the same table the
  // engine answers with, which is why a verb may say `2` for "the file is
  // wrong" where a process only ever says "it failed".
  return 0;
}

/// A set's members are relative to the repository root, and a verb is told
/// where that is rather than having to guess.
String inside(VerbContext context, String relative) =>
    '${context.workingDirectory}${Platform.pathSeparator}$relative';

Future<void> main(List<String> args) async {
  // Assigned, not discarded: `runXtask` answers with the exit code, and a
  // caller that throws it away reports success for every outcome.
  exitCode = await runXtask(args, verbs: {'count-lines': countLines});
}
