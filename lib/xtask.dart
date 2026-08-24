/// `xtask` — a task runner whose tasks are data.
///
/// The design this implements is `xtask.md` in this repository. Read it before
/// changing anything here: it states three rules and a list of anti-goals, and
/// each one is there because it prevents a failure that has already happened
/// somewhere.
library;

import 'dart:io';

import 'src/cli.dart';
import 'src/context.dart';
import 'src/exec.dart';
import 'src/executables.dart';

// Re-exported rather than restated. A second declaration of `Verb` or of what
// a verb is handed would be two lists of the same thing, which is the defect
// §1 exists to remove.
export 'src/context.dart' show Verb, VerbContext;

/// Runs `xtask` with the verbs this project supplies, and answers with the
/// process exit code — see §5.3 of `xtask.md` for what each code means.
///
/// This is the whole public surface. A project depends on `xtask`, writes
/// `bin/xtask.dart` calling this, and `dart run :xtask <task>` reaches it by
/// file name (§7, §9). **The answer is the process's exit code and has to be
/// used as one** — a caller that discards it reports success whatever
/// happened.
///
/// Everything ambient is supplied here and nowhere below: the directory the
/// command was run in, the environment, the two output streams, how a program
/// is found on this machine and how one is started. [runCli] takes all of it
/// as parameters, which is what lets §7's surface and §7.1's GitHub markers be
/// tested without a toolchain and from a machine that is not a runner.
Future<int> runXtask(
  List<String> args, {
  Map<String, Verb> verbs = const {},
}) => runCli(
  args,
  workingDirectory: Directory.current.path,
  environment: Platform.environment,
  // The engine's own reports go to stdout, with the bodies' output rather
  // than beside it: §7.1's grouping markers only fold what is on the same
  // stream, and on GitHub an `::error::` written to stderr is not an
  // annotation, it is a line of red text.
  out: stdout.writeln,
  err: stderr.writeln,
  resolver: ExecutableResolver.forHost(),
  starter: const SystemProcessStarter(),
  verbs: verbs,
);
