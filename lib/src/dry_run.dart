/// Printing what a run would do, without doing it — `--dry-run` of §7.
library;

import 'context.dart';
import 'exec.dart';
import 'graph.dart';
import 'model.dart';
import 'resolve.dart';

/// Prints [plan] and everything in it, and runs nothing.
///
/// **A real run with the last step removed.** The plan comes from the same
/// `planRun` an execution uses (§5.1) and each body is resolved by the same
/// [Executor] — the sets expanded, `$each` substituted, the working directory
/// worked out, the program found on this machine's `PATH` (§5.4). Only the
/// starting is skipped.
///
/// That is the whole point of the slice: a dry run that read the file its own
/// way would print a plan that agrees with the run until the day one of the
/// two is changed. §1's first defect, one directory apart.
///
/// The answer is **the exit code the run would give**, not a separate
/// vocabulary: a program nothing answers to is still 3, an unknown verb still
/// 2, a missing `env-required` still 1. A resolution failure inside a `then:`
/// still reports as a continuation failure, because that is the code the run
/// would reach it with.
Future<int> dryRun({
  required XtaskFile file,
  required String root,
  required Plan plan,
  required ExecutableResolver resolver,
  required void Function(String line) log,
  Map<String, Verb> verbs = const {},
  Map<String, String> environment = const {},
}) {
  // The order, before anything that can fail to resolve. A plan whose second
  // task names a program this machine has not got is exactly when somebody
  // wants to see the order, and printing it afterwards would print nothing.
  log('plan: ${plan.names.join(', ')}');

  return Executor(
    file: file,
    root: root,
    resolver: resolver,
    starter: const RefusingProcessStarter(),
    log: log,
    verbs: verbs,
    environment: environment,
    dryRun: (body) => describe(body).forEach(log),
  ).run(plan);
}

/// The starter a dry run is handed.
///
/// **Not a stub that answers 0.** [Executor] reaches its starter only after
/// deciding to perform a body, which a dry run never does — so a call here is
/// a hole in that seam, and a hole in that seam means `--dry-run` has just
/// started a real process. Refusing turns that into a crash with a name on it
/// rather than into a build.
final class RefusingProcessStarter implements ProcessStarter {
  const RefusingProcessStarter();

  @override
  Future<int> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
  }) => throw StateError(
    'a dry run tried to start `$executable`. Nothing is started here: this is '
    'the seam that makes --dry-run dry, and it has a hole in it',
  );
}
