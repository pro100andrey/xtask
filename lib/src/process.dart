/// Starting a real process — the adapter behind `ProcessStarter`.
///
/// The only part of the engine that knows what a pipe, a signal and a grace
/// period are. A run, a fan-out and a test all reach it through the interface
/// `context.dart` declares.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'context.dart';

/// The starter that runs real processes.
final class SystemProcessStarter implements ProcessStarter {
  SystemProcessStarter({
    this.grace = const Duration(seconds: 5),
    this.readerGone = _nobodyLeft,
    this.orderingDeadline = const Duration(seconds: 2),
    this.flushStdout = _flushStdout,
  });

  /// How long [flushStdout] is waited for before the run carries on without
  /// the ordering it buys.
  ///
  /// On a pipe whose reader has gone the flush can return a future nothing
  /// completes, and a Dart isolate awaiting one with no other IO outstanding
  /// ends with `exitCode` never assigned — so the run answers 0 part-done.
  final Duration orderingDeadline;

  /// How this process's own stdout is flushed. A seam, so a test can hand in
  /// a flush that never answers.
  final Future<void> Function() flushStdout;

  static Future<void> _flushStdout() => stdout.flush();

  /// Whether this process's stdout has proved it cannot be written to.
  ///
  /// **A real error, and no longer a slow answer.** A flush that exceeds
  /// [orderingDeadline] proves the descriptor is SLOW — a paused terminal, a
  /// pager, a CI log shipper — and that was being latched as proof it was
  /// dead. After it, `inherits` is false for every remaining task, and a
  /// sequential run gives those children no collector, so their output went
  /// to `_nowhere`: the run looked normal, answered the right code, and the
  /// analyzer's and the test runner's output was gone with nothing saying so.
  ///
  /// Whether anybody is reading is [readerGone]'s question and it is already
  /// asked above; this is only about the descriptor failing outright.
  var _stdoutIsGone = false;

  /// Whether the ordering flush has already cost a full [orderingDeadline].
  ///
  /// Latched so the wait is paid once rather than once per task. Losing the
  /// ordering is all this costs: the child still writes to the real
  /// descriptor, which is the part that matters.
  var _orderingGivenUp = false;

  /// Whether the process this run writes to has stopped reading.
  ///
  /// Two things here are for a reader: the flush that orders this process's
  /// lines against an inheriting child's, and handing that descriptor down
  /// with [ProcessStartMode.inheritStdio]. With no reader both are pointless,
  /// and a run must not decide what to start by who is listening.
  final bool Function() readerGone;

  static bool _nobodyLeft() => false;

  /// How long a process that has been asked to stop is given to do it.
  ///
  /// A parameter so a test need not wait a realistic one out. The default is
  /// what a test runner needs to write its partial output and a compiler to
  /// remove a half-written file.
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
    // Whether the child writes to this process's own descriptors. One
    // question, asked once: it decides both the flush below and the start mode
    // further down.
    var inherits = output == null && !readerGone() && !_stdoutIsGone;

    // Dart's `stdout` is asynchronous when it is a pipe, and an inheriting
    // child writes to that same descriptor directly — so without this a task's
    // `::group::` line can arrive after the output it folds. A piped child
    // never touches it, and flushing anyway marks the sink bound for as long
    // as the flush is in flight, which a second task writing its buffered
    // block turns into `StreamSink is bound to a stream`.
    //
    // The reader going away is not this task failing, so a closed pipe is
    // swallowed; and the flush is bounded because it can hang, which would end
    // the isolate at 0.
    //
    // **A deadline reached gives up the ORDERING and nothing else.** Only the
    // closed pipe says the descriptor is unusable. Reading a slow flush as a
    // dead one sent every later task's output to `_nowhere`.
    if (inherits && !_orderingGivenUp) {
      try {
        await flushStdout().timeout(
          orderingDeadline,
          onTimeout: () => _orderingGivenUp = true,
        );
      } on FileSystemException catch (error) {
        if (!isAClosedPipe(error)) {
          rethrow;
        }
        _stdoutIsGone = true;
      }
      inherits = !_stdoutIsGone;
    }

    // Held so they can be cancelled on every path out. A grandchild that
    // inherited the pipes keeps them open, so nothing else closes them and the
    // isolate would stay alive with its exit code already set.
    final reading = <StreamSubscription<void>>[];
    Future<void>? collecting;
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: runInShell,
      // Inheriting streams live output for free: the child writes to this
      // process's stdout with no copy and no buffer. Two children writing to
      // one terminal produce a transcript belonging to neither, so a parallel
      // run pipes instead and shows nothing until the task ends.
      mode: inherits ? ProcessStartMode.inheritStdio : ProcessStartMode.normal,
    );

    if (!inherits) {
      // A piped child gets a stdin this process holds open and never fills, so
      // a program that reads stdin when it is not a terminal waits for input
      // that cannot come while `exitCode` waits for it. An inheriting child
      // has the real stdin and needs none of this.
      unawaited(process.stdin.close().catchError((Object _) {}));
    }

    // Drained, not left to fill. A piped child whose output nobody collects
    // blocks on a full pipe once it has written 64K, which is a run stopped by
    // its own buffer.
    final collect = output ?? (inherits ? null : _nowhere);
    if (collect != null) {
      // Both streams into one buffer in arrival order, which is what a
      // terminal would have shown, and kept as futures so collecting is not
      // waited on before the process is. Malformed bytes pass through: the
      // strict decoder throws from inside the data handler, where nothing can
      // catch it, and these bytes are for a person to read rather than for
      // this engine to validate.
      for (final stream in [process.stdout, process.stderr]) {
        reading.add(
          stream
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())
              .listen(collect),
        );
      }
      collecting = Future.wait([
        for (final subscription in reading) subscription.asFuture<void>(),
      ]);
    }

    Future<void> stopReading() async {
      for (final subscription in reading) {
        await subscription.cancel();
      }
    }

    if (timeout == null && until == null) {
      final code = await process.exitCode;
      // Bounded: a task that backgrounds something keeps the pipes open for
      // as long as the grandchild lives.
      await collecting?.timeout(grace, onTimeout: () => const <void>[]);
      await stopReading();
      return code;
    }

    // Asked to stop, then made to: SIGTERM lets a test runner write its
    // partial output and a compiler remove a half-written file, and SIGKILL is
    // for one that ignores being asked. It does NOT reach the process's own
    // children — Windows has job objects, POSIX has process groups, and
    // neither is what `Process` exposes — so a task that spawns a server may
    // leave it behind.
    //
    // Whichever comes first wins: the process ending, its deadline, or the run
    // giving up. Which one is read where it wins rather than from a flag set
    // in the losing callback, so a process that genuinely ran past its
    // `timeout:` is not relabelled a stop.
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
      await collecting?.timeout(grace, onTimeout: () => const <void>[]);
      await stopReading();
      return outcome.code!;
    }
    // The two futures can complete in the same turn, and a process that has
    // already finished was not stopped.
    final finishedAnyway = alreadyFinished;
    if (finishedAnyway != null) {
      await collecting?.timeout(grace, onTimeout: () => const <void>[]);
      await stopReading();
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
    // Bounded, because the pipes may outlive the process: collecting ends when
    // stdout and stderr close, and a grandchild that inherited them keeps them
    // open. The same grace as the kill — a moment for what was already
    // written, and no longer.
    await collecting?.timeout(grace, onTimeout: () => const <void>[]);
    await stopReading();
    return stoppedEarly ? interrupted : timedOut;
  }

  /// What a killed process answers with — `timeout(1)`'s number, so a shell
  /// wrapping xtask need not learn a new one. The engine still answers 1: a
  /// task that hung is a task that failed.
  static const timedOut = 124;

  /// What a process stopped because the run gave up answers with — a shell's
  /// number for SIGINT. Distinct from [timedOut] so a report can say which
  /// happened, and never a task failure: it was not allowed to finish.
  static const interrupted = 130;
}

/// Where the output of a child goes when nobody is reading this process.
void _nowhere(String line) {}

/// Whether [error] is the reader having gone away, which is an ordinary end
/// for a writer rather than a fault.
///
/// POSIX: `EPIPE` (32), and `EBADF` (9) for a descriptor closed rather than
/// piped, which is what `xtask check >&-` hands a process. Windows:
/// `ERROR_BROKEN_PIPE` (109) and `ERROR_NO_DATA` (232).
///
/// Per platform, because the two schemes collide: 9 is `ERROR_INVALID_BLOCK`
/// on Windows and 32 is `ERROR_SHARING_VIOLATION`, and honouring those would
/// drop a report the writer could still have delivered.
bool isAClosedPipe(Object error) =>
    error is FileSystemException &&
    (Platform.isWindows ? const {109, 232} : const {9, 32}).contains(
      error.osError?.errorCode,
    );
