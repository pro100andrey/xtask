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
/// `bin/xtask.dart` calling this, and `dart run :xtask <task>` reaches it by
/// file name (§7, §9). **The answer is the process's exit code and has to be
/// used as one** — a caller that discards it reports success whatever
/// happened.
Future<int> runXtask(
  List<String> args, {
  Map<String, Verb> verbs = const {},
}) async {
  // **Refuses, rather than succeeding at nothing.** The CLI surface of §7 is
  // the `cli` slice and everything it dispatches to is a slice of its own —
  // but until then this function must not answer 0, whatever it is asked.
  //
  // §7.1 tells a pipeline to run `dart run :xtask ci-analyze` as a job's only
  // step, and milestone item 9 makes this repository its own first user. A 0
  // here gives whoever wires that up a permanently green job that ran nothing,
  // indistinguishable from a passing gate — §1's third defect, produced by the
  // tool written to remove it, in a package that argues at length that a green
  // result nobody checked is the worst available answer.
  //
  // 2 rather than 1: §5.3 reserves 1 for a task that ran and failed, which
  // would send somebody looking for the failing task. A 2 is "the invocation
  // was refused", which is what this is.
  stderr.writeln(
    'xtask: the command surface is not implemented yet (xtask.md §7, §13). '
    'Refusing rather than reporting success: a green result nobody checked is '
    'the failure this tool exists to remove.',
  );
  return 2;
}
