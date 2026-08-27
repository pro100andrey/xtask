/// Printing what a run would do, without doing it — `--dry-run` of §7.
library;

import 'bodies.dart';
import 'context.dart';
import 'errors.dart';
import 'executables.dart';
import 'exit_codes.dart';
import 'graph.dart';
import 'model.dart';
import 'report.dart';

/// Prints [plan] and everything in it, and runs nothing.
///
/// **Not a mode of the executor any more.** It used to be one: a callback the
/// executor called instead of performing, a process starter whose only job was
/// to throw, and four branches inside the run asking whether this run was
/// pretending. What it actually is, is a plan and a resolution — the same
/// resolution a run uses, which is why what it prints is what will happen and
/// not a second reading of the file.
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
  ({String task, List<String> arguments})? passedThrough,
}) async {
  // The order, before anything that can fail to resolve. A plan whose second
  // task names a program this machine has not got is exactly when somebody
  // wants to see the order, and printing it afterwards would print nothing.
  log('plan: ${plan.names.join(', ')}');

  final bodies = BodyResolver(
    root: root,
    resolver: resolver,
    sets: file.sets,
    verbs: verbs,
    environment: environment,
    passedThrough: passedThrough,
  );

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
      log('${step.task.name}: nothing of its own to run');
      continue;
    }
    for (final body in resolved) {
      describe(body).forEach(log);
    }
  }

  return ExitCode.success;
}
