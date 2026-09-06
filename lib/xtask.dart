/// `xtask` — a task runner whose tasks are data.
///
/// The README is the record of what this is and why it refuses what it
/// refuses — three rules and a list of anti-goals, each there because it
/// prevents a failure that has already happened somewhere. Read it before
/// changing anything here.
library;

import 'dart:async';
import 'dart:io';

import 'src/cli.dart';
import 'src/context.dart';
import 'src/executables.dart';
import 'src/process.dart';

// Re-exported rather than restated. A second declaration of `Verb` or of what
// a verb is handed would be two lists of the same thing, which is the defect
// this package exists to remove.
export 'src/context.dart' show Verb, VerbContext;

// A verb answers with a number, and the README tells its author to write that
// number against the table this class is. Not exporting it meant telling them
// to write `return 0;` — the very thing `boundaries_test.dart` refuses inside
// this package, for the reason that applies just as well outside it: the
// constant carries why the code is that code, and the digit does not.
//
// Found by the guard, on the example this package ships.
export 'src/exit_codes.dart' show ExitCode;

/// Runs `xtask` with the verbs this project supplies, and answers with the
/// process exit code — the README's exit code table says what each means.
///
/// This is the whole public surface. A project depends on `xtask`, writes
/// `bin/xtask.dart` calling this, and `dart run :xtask <task>` reaches it by
/// file name. **The answer is the process's exit code and has to be
/// used as one** — a caller that discards it reports success whatever
/// happened.
///
/// Everything ambient is supplied here and nowhere below: the directory the
/// command was run in, the environment, the two output streams, how a program
/// is found on this machine and how one is started. [runCli] takes all of it
/// as parameters, which is what lets the report and its GitHub grouping
/// markers be tested without a toolchain, from a machine that is not a runner.
Future<int> runXtask(
  List<String> args, {
  Map<String, Verb> verbs = const {},
  String? workingDirectory,
}) {
  // Made once and asked twice: the engine writes through it, and the starter
  // asks it whether there is still anybody to write for.
  final out = _writing(stdout);
  return runCli(
    args,
    // **A default, not a reading.** The file is looked for from here upwards,
    // and for a command that is what the process was started in. It is a
    // parameter because `Directory.current` is one thing for a whole process:
    // anything wanting to point xtask at a directory — an embedding CLI, or a
    // test — otherwise has to assign to it and hand every other isolate in the
    // process a directory it did not ask for. That is not hypothetical. It cost
    // this suite a flaky failure that read `dartdev embedder initialization
    // failed: Error determining current directory`, from a temporary directory
    // deleted by one test while another was starting a process in it.
    workingDirectory: workingDirectory ?? Directory.current.path,
    environment: Platform.environment,
    // The engine's own reports go to stdout, with the bodies' output rather
    // than beside it: GitHub's grouping markers only fold what is on the same
    // stream, and on GitHub an `::error::` written to stderr is not an
    // annotation, it is a line of red text.
    out: out.write,
    err: _writing(stderr).write,
    resolver: ExecutableResolver.forHost(),
    // Given the same fact the writer has, so that a run behind a reader that
    // went away stops writing AND stops handing that descriptor to its
    // children. Two answers to "is anybody reading" is two things that can
    // disagree, and this is the one place that has the answer.
    starter: SystemProcessStarter(readerGone: () => out.gone),
    verbs: verbs,
  );
}

/// Writing a line to [sink], and stopping quietly when nobody is reading.
///
/// **`xtask --list | head -2` is an ordinary thing to type.** `head` closes the
/// pipe as soon as it has what it wants, and the next write raises
/// `FileSystemException: Broken pipe` — which nothing caught, so the run ended
/// on a stack trace and exit 255, a number the exit code table does not have,
/// for output that
/// arrived exactly as asked. Every well-behaved command answers a closed pipe
/// by stopping, and this is how it stops: the remaining lines go nowhere,
/// because there is nowhere for them to go.
_Writer _writing(IOSink sink) => _Writer(sink);

/// Writing a line to a sink, and the one place that knows whether anybody is
/// still reading it.
///
/// **A value rather than a closure, because the fact outlives the write.** The
/// writer stops when the reader goes away; so must the starter, which
/// otherwise flushes a descriptor nobody reads and hands it to every child it
/// inherits into. Asked twice, in two places, that becomes two answers to one
/// question — which is how the ordering and the inheriting came to disagree
/// about whether there was anything left to order.
final class _Writer {
  _Writer(this._sink) {
    // **Claimed up front, because the write is not where it surfaces.** An
    // `IOSink` is asynchronous: `writeln` returns before the bytes reach the
    // pipe, so a `try` around it catches nothing and the failure arrives later
    // as an unhandled error that ends the process at 255. Claiming `done` is
    // what makes a closed pipe ours to ignore.
    //
    // **And only a closed pipe.** Marking every sink error handled would
    // swallow the ones that matter: `xtask check > report.txt` on a full disk
    // would write a truncated report and answer 0, with nothing on stderr — a
    // green result nobody checked, which is the failure this whole tool is
    // against. Anything else is left unhandled, exactly as loud as it was.
    unawaited(
      _sink.done.catchError(
        (Object error) => _closed = true,
        test: isAClosedPipe,
      ),
    );
  }

  final IOSink _sink;
  var _closed = false;

  /// Whether the reader has gone away.
  bool get gone => _closed;

  void write(String line) {
    if (_closed) {
      return;
    }
    try {
      _sink.writeln(line);
    } on FileSystemException catch (error) {
      if (!isAClosedPipe(error)) {
        rethrow;
      }
      _closed = true;
    }
  }
}
