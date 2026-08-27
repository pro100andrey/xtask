/// Starting a real process — the adapter behind `ProcessStarter`.
///
/// **Here rather than beside the walk that uses it.** It is the only thing in
/// the engine that knows what a pipe, a signal and a grace period are, and it
/// answers to an interface `context.dart` declares — so a run, a fan-out and a
/// test all reach it the same way, and only this file needs `dart:io` for a
/// reason other than reading a file.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'context.dart';

/// The starter that runs real processes.
final class SystemProcessStarter implements ProcessStarter {
  const SystemProcessStarter({this.grace = const Duration(seconds: 5)});

  /// How long a process that has been asked to stop is given to do it.
  ///
  /// A parameter so a test can prove the escalation without waiting out a
  /// realistic one. The default is what a test runner needs to write its
  /// partial output and a compiler to remove a half-written file.
  final Duration grace;

  @override
  Future<int> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
    Duration? timeout,
    Future<void>? until,
    void Function(String line)? output,
  }) async {
    // One question, asked once: it decides the flush above and the mode below,
    // and two spellings of it are two things that can disagree.
    final inherits = output == null;

    // **Flushed before the child starts, and only when the child inherits.**
    // Dart's `stdout` is asynchronous when it is a pipe, which is what it is
    // on CI, and an inheriting child writes to that same descriptor directly:
    // without this the `::group::` line for a task can arrive after the output
    // it is supposed to be folding, which turns §7.1's readable failure into a
    // jumble exactly where nobody can reproduce it.
    //
    // A piped child never touches this process's stdout, so there is nothing
    // to order against — and flushing anyway is not merely wasted. `flush()`
    // marks the sink bound for as long as it is in flight, so a task ending
    // and writing its buffered block while another task is starting throws
    // `Bad state: StreamSink is bound to a stream` and takes the run with it.
    // Concurrency is the only way to have both at once, and concurrency is
    // exactly when nobody inherits.
    if (inherits) {
      await stdout.flush();
    }

    Future<void>? collecting;
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: runInShell,
      // **Streaming, by not being in the way.** §5.2 requires a task's output
      // to pass through as it arrives and never be buffered to the end,
      // because a long test run has to be watchable. Inheriting the streams
      // gives that for nothing: the child writes to this process's own stdout,
      // with no copy, no line buffer and nothing to get the ordering of two
      // streams wrong.
      // **Streaming by not being in the way, unless somebody asked for
      // parallelism.** Inheriting gives §5.2's promise for nothing: the child
      // writes to this process's own stdout, with no copy, no line buffer and
      // nothing to get the ordering of two streams wrong. A parallel run
      // cannot have that — two children writing to one terminal produce a
      // transcript belonging to neither — so it pipes instead, and pays for it
      // by not seeing anything until the task ends.
      mode: inherits ? ProcessStartMode.inheritStdio : ProcessStartMode.normal,
    );

    if (output != null) {
      // Both streams into one buffer, in arrival order, because that is what
      // a terminal would have shown. Kept as futures so the collecting is not
      // waited on before the process is.
      collecting = Future.wait([
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(output),
        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(output),
      ]);
    }

    if (timeout == null && until == null) {
      final code = await process.exitCode;
      await collecting;
      return code;
    }

    // **Asked to stop, then made to.** SIGTERM lets a test runner write its
    // partial output and a compiler remove a half-written file; SIGKILL is
    // what happens to a process that ignores being asked. A short grace
    // period between them is the whole difference between a killed run that
    // leaves a corrupt artifact behind and one that does not.
    //
    // What this does NOT do is kill the process's own children. There is no
    // portable way to reach them from here — Windows has job objects, POSIX
    // has process groups, and neither is what `Process` exposes — so a task
    // that spawns a server and hangs may leave the server behind. Stated
    // rather than quietly hoped away.
    // Whichever comes first: the process ending, its deadline, or the run
    // deciding it no longer needs this. The last two end the same way, because
    // a process being stopped does not care why.
    // **Which branch won is read when it wins, not after the kill.** Setting a
    // flag from inside the losing callback let a task that genuinely ran past
    // its `timeout:` be relabelled a stop, if the run happened to give up
    // during the grace period — and a relabelled stop is not reported at all.
    int? alreadyFinished;
    final ending = process.exitCode.then<int?>((code) {
      alreadyFinished = code;
      return code;
    });
    final outcome = await Future.any([
      if (timeout == null)
        ending.then((code) => (code: code, stopped: false))
      else
        ending
            .timeout(timeout, onTimeout: () => null)
            .then((code) => (code: code, stopped: false)),
      if (until != null) until.then((_) => (code: null as int?, stopped: true)),
    ]);
    if (outcome.code != null) {
      await collecting;
      return outcome.code!;
    }
    // **A process that has already finished was not stopped.** The two futures
    // can complete in the same turn, and `Future.any` picking the other one
    // threw away a real exit code and called a dead process killed.
    final finishedAnyway = alreadyFinished;
    if (finishedAnyway != null) {
      await collecting;
      return finishedAnyway;
    }
    final stoppedEarly = outcome.stopped;

    process.kill();
    final stopped = await process.exitCode
        .then<int?>((code) => code)
        .timeout(grace, onTimeout: () => null);
    if (stopped == null) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    // **Bounded, because the pipes may outlive the process.** Collecting ends
    // when stdout and stderr close, and a grandchild that inherited them keeps
    // them open — `sh -c 'sleep 12'` killed at 0.0s still took twelve seconds
    // to report, which is `interruptible:` giving back exactly nothing and
    // billing the wait as the task's own work. The same grace as the kill: a
    // moment for what was already written, and no longer.
    await collecting?.timeout(grace, onTimeout: () => const <void>[]);
    return stoppedEarly ? interrupted : timedOut;
  }

  /// What a killed process answers with.
  ///
  /// 124 is what `timeout(1)` uses and what every script that wraps a command
  /// in one already checks for. Borrowing it costs nothing and means a shell
  /// around `xtask` does not have to learn a new number — while §5.3's own
  /// codes are untouched, because the ENGINE still answers 1: a task that hung
  /// is a task that failed, and the same person goes to look.
  static const timedOut = 124;

  /// What a process stopped because the run gave up answers with.
  ///
  /// 130 is what a shell reports for SIGINT, and this is the same event by a
  /// different route: somebody — here, an earlier failure — decided the answer
  /// was already known. Distinct from [timedOut] so a report can say which
  /// happened, and never surfaced as a task failure: a task that was stopped
  /// did not fail, it was not allowed to finish.
  static const interrupted = 130;
}
