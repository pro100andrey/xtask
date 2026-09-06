/// Printing what a run would do, without doing it — `--dry-run` of §7.
library;

import 'bodies.dart';
import 'boundary.dart';
import 'errors.dart';
import 'exit_codes.dart';
import 'graph.dart';
import 'primitives.dart';
import 'report.dart';

/// Prints [plan] and everything in it, and runs nothing.
///
/// A plan and a resolution — the same resolution a run uses, which is why what
/// it prints is what will happen rather than a second reading of the file.
///
/// The answer is the exit code the run would give, not a separate vocabulary:
/// a program nothing answers to is still 3, an unknown verb still 2, a missing
/// `env-required` still 1, and a failure inside a `then:` still a continuation
/// failure.
///
/// [bodies] is handed in rather than built, so there is one construction of
/// "what will happen" and a parameter cannot be added to only one of them.
Future<int> dryRun({
  required Plan plan,
  required BodyResolver bodies,
  required void Function(String line) log,
}) async {
  // The order, before anything that can fail to resolve. A plan whose second
  // task names a program this machine has not got is exactly when somebody
  // wants to see the order, and printing it afterwards would print nothing.
  log('plan: ${plan.names.join(', ')}');

  for (final step in plan.steps) {
    final List<Resolved> resolved;
    try {
      resolved = bodies.resolveTask(step.task);
    } on RunFailure catch (failure) {
      // **Not yet is not the same as wrong.** A task whose set the run itself
      // produces cannot be resolved before the task that makes it has run, and
      // this used to stop the print and answer 2 about a file that runs green.
      //
      // Asked of the type rather than of the exit code: guessing from the code
      // and the task's set names called a boundary violation and an unknown
      // verb premature too, and answered 0 for both. The original reason is
      // still printed, so nothing is hidden.
      if (failure is NotYetFailure) {
        log('${step.task.name}: cannot be resolved yet — ${failure.message}');
        continue;
      }
      log('error: ${failure.message}');
      // The same code the run would answer with, including the third outcome:
      // a body that would have succeeded and a continuation that would not.
      return step.isContinuation ? ExitCode.continuationFailed : failure.code;
    }

    if (resolved.isEmpty) {
      log(nothingToRun(step.task.name));
      continue;
    }
    for (final body in resolved) {
      describe(body).forEach(log);
      final deletion = _wouldDelete(body, root: bodies.root);
      deletion.lines.forEach(log);
      // **Where the run would stop.** A `do: remove` the run refuses is not a
      // block to print and walk past: the plan below it is a plan that will
      // never be reached, and printing it as though it would be is the thing
      // this mode exists not to do.
      if (deletion.refused) {
        // The code the run would give, including the third outcome — the same
        // question the resolution failure above asks. A `remove` refused
        // inside a `then:` fails as a continuation, and answering 2 here
        // would be this mode disagreeing with the run it describes.
        return step.isContinuation
            ? ExitCode.continuationFailed
            : ExitCode.invalidFile;
      }
    }
  }

  return ExitCode.success;
}

/// What a `do: remove` block would actually delete, under the block itself.
///
/// **The engine ships one verb and it deletes recursively.** `describe` shows
/// what a body was given, which for every other body is the whole of what will
/// happen — a `run:` prints the argv the child gets. For this one the argument
/// is a pattern, so the block said `do remove build/**` and left the reader to
/// guess what that is on their tree. Naming the verb here rather than in
/// `describe` is deliberate: a failure prints `describe` too, and reading the
/// filesystem while reporting a failure is not something a report may do.
///
/// Capped, because a clean tree can hold thousands and a plan is meant to be
/// read.
({List<String> lines, bool refused}) _wouldDelete(
  Resolved body, {
  required String root,
}) {
  if (body is! ResolvedVerb || body.verb != removeVerbName) {
    return (lines: const [], refused: false);
  }
  final would = removeWouldDelete(body.arguments, root: root);
  if (would.refused case final refusal?) {
    // In the run's own words, and in the run's own place: this used to render
    // as "nothing of these is on disk", which told a reader that a `remove`
    // aimed outside the repository was harmless.
    return (lines: ['error: $refusal'], refused: true);
  }
  final paths = would.paths;
  if (paths.isEmpty) {
    // Said out loud. Silence here reads as "nothing was worked out", and the
    // answer — there is nothing there, which §6 makes fine — is the one a
    // person running `clean` twice needs.
    return (
      lines: const [
        '  del  nothing of these is on disk, which is not an error',
      ],
      refused: false,
    );
  }
  const shown = 10;
  return (
    refused: false,
    lines: [
      for (final path in paths.take(shown)) '  del  $path',
      if (paths.length > shown) '  del  … and ${paths.length - shown} more',
    ],
  );
}
