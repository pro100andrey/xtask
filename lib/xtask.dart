/// `xtask` — a task runner whose tasks are data.
///
/// The design this implements is `xtask.md` in this repository. Read it before
/// changing anything here: it states three rules and a list of anti-goals, and
/// each one is there because it prevents a failure that has already happened
/// somewhere.
library;

import 'dart:io';

/// A job the project implements in Dart, named by a task's `do:` key.
///
/// Rule R1 pushes logic here deliberately: the file cannot branch, so a task
/// that needs a condition becomes one of these instead. The context a verb
/// receives — its arguments, the resolved members of its `argv-from` set, its
/// environment, its working directory and a logger — is defined by the slice
/// that builds body execution; until then this typedef names the shape without
/// pretending to the detail.
typedef Verb = Future<int> Function(List<String> args);

/// Runs `xtask` with the verbs this project supplies, and answers with the
/// process exit code — see §5.3 of `xtask.md` for what each code means.
///
/// This is the whole public surface. A project depends on `xtask`, writes
/// `bin/xtask.dart` calling this, and declares it in its own manifest so
/// `dart run :xtask <task>` reaches it (§7, §9).
Future<int> runXtask(
  List<String> args, {
  Map<String, Verb> verbs = const {},
}) async {
  // Placeholder. The CLI surface of §7 — --list, --gate, --gates, --validate,
  // --dry-run and running a task — is the `cli` slice, and everything it
  // dispatches to is a slice of its own. What this proves today is only that
  // the package is reachable as `dart run :xtask`, which is the question the
  // skeleton exists to answer.
  //
  // `stdout` rather than `print` on purpose, and not only because the house
  // lints say so: §5.2 requires a task's output to pass through as it arrives,
  // never buffered to the end, and that is a property of the sink this engine
  // writes to from the start.
  stdout.writeln('xtask: not implemented yet; see xtask.md §13.');
  return 0;
}
