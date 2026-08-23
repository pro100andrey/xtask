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

/// How `--dry-run` prints one resolved body: what runs, where, and with what.
///
/// §13 keeps output *formats* out of this milestone — there is no `--json` and
/// no key to choose one. This is the one human-readable form, and the thing it
/// has to get right is that a person can check it against what they meant.
List<String> describe(Resolved body) {
  final member = body.member;
  return [
    if (member == null) body.task.name else '${body.task.name}  [$member]',
    switch (body) {
      ResolvedProcess(:final executable, :final arguments) =>
        '  run  ${_command(executable, arguments)}',
      // The name written in the file, not the Dart function it found: a verb
      // is the project's, and `Closure: (VerbContext) => Future<int>` tells
      // the reader nothing they can check.
      ResolvedVerb(:final verb, :final arguments) =>
        '  do   ${_command(verb, arguments)}',
    },
    '  in   ${body.workingDirectory}',
    // **The task's own `env:`, not the environment the body will see.** The
    // second is this machine's environment with two entries changed, and
    // printing it would bury the two lines that are part of the plan under a
    // hundred that are part of the terminal. What `env-required` asked for is
    // not printed either: by the time a body resolves, it is set.
    for (final variable in body.task.env.entries)
      '  env  ${variable.key}=${_quoted(variable.value)}',
    if (body case ResolvedProcess(runInShell: true))
      '  via  cmd.exe, which is the only way to start a batch file (§5.4)',
  ];
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

String _command(String head, List<String> arguments) =>
    [head, ...arguments].map(_quoted).join(' ');

/// [word] written so that its edges are visible.
///
/// A plan that cannot tell one argument from two is not one anybody can check
/// against what they meant: `dart test a b` and `dart test 'a b'` are
/// different commands, and an argument that is the empty string disappears
/// entirely. This is for **reading** — xtask starts no shell (§5.4), so there
/// is no shell for it to be correct for, and it does not claim to be.
String _quoted(String word) => word.isEmpty || _needsQuotes.hasMatch(word)
    ? "'${word.replaceAll("'", r"\'")}'"
    : word;

final _needsQuotes = RegExp(r'''[\s'"]''');
