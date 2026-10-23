/// What a verb is handed, and what starts a process — the two seams execution
/// is built on.
library;

import 'dart:io' show Directory, File;

import 'boundary.dart';
import 'errors.dart';
import 'exit_codes.dart';

/// A job the project implements in Dart, named by a task's `do:` key.
///
/// The file cannot branch, which pushes logic here deliberately: the file
/// cannot branch, so a task that needs a condition becomes one of these
/// instead. It is ordinary Dart — testable, typed, debuggable — and free to do
/// whatever it needs.
typedef Verb = Future<int> Function(VerbContext context);

/// Why `do: [verb]` on task [task] is refused.
///
/// **Here rather than at either caller, for `boundary.dart`'s reason.** The
/// resolver refuses this when a run reaches the task and `--validate` refuses
/// it when the file is read, and the two had a sentence each — one of which
/// had learnt to list the known verbs while the other had learnt to say what a
/// verb IS. Each knew something the other did not, which is drift already
/// under way.
String unknownVerb({
  required String task,
  required String verb,
  required Set<String> known,
}) =>
    'task `$task` names the verb `$verb`, which this project has not '
    'registered. The engine ships no project verbs: a verb is a Dart function '
    'the project hands to `runXtask`'
    '${known.isEmpty ? '' : ' — known: '
              '${(known.toList()..sort()).join(', ')}'}';

/// What a program answered and what it wrote, each stream whole — for a verb
/// that has to read a program's output rather than pass it through.
typedef Captured = ({int exitCode, String stdout, String stderr});

/// Everything a verb is given.
final class VerbContext {
  /// [locate], [collect] and [relay] are the engine's; a context built by
  /// hand — a verb's own test — gives them only if the verb under test asks,
  /// and [which], [capture] or [tee] without one says so rather than
  /// answering "absent".
  /// [out] is a sink over [log] unless one is given.
  VerbContext({
    required this.args,
    required this.env,
    required this.root,
    required this.workingDirectory,
    required this.log,
    required this.start,
    this.member,
    this.locate,
    this.collect,
    this.relay,
    LogSink? out,
  }) : out = out ?? LogSink(log);

  /// Everything the body was given, in one list: the task's `args:` with any
  /// `\$all` and `\$each` already standing for what they name, then whatever
  /// the command line passed after `--`.
  ///
  /// **In place, not appended.** `\$all` is written where its members belong,
  /// so the order here is the order the file wrote.
  ///
  /// Already expanded, so a verb never touches the filesystem to find out what
  /// it was asked about — and **a verb is reached by `--` exactly as a process
  /// is**, which the three sources being one list is the whole statement of. A
  /// verb that wants to tell them apart cannot, and has not needed to.
  final List<String> args;

  /// The environment the body would see: this machine's, without what the
  /// task's `env-unset:` names, with its own `env:` applied over it — and
  /// winning where both name the same variable.
  ///
  /// **Not the task's `env:` on its own**, which is what the name suggests and
  /// what this doc comment said until somebody read it beside the code. A verb
  /// that wants `PATH` finds it here; a verb that wants to know what the file
  /// declared cannot ask, and has not needed to.
  final Map<String, String> env;

  /// The repository root, absolute: the directory holding `xtask.yaml`.
  ///
  /// **Not [workingDirectory]**, which is where the task runs — `in:` moves
  /// that and leaves this alone. A set's member and an `in:` are relative to
  /// here; what a body is handed to act on where it runs — a `remove`
  /// argument, a program written with a separator — is read from
  /// [workingDirectory] instead. A verb that joins a member onto
  /// [workingDirectory] builds a path that is right only for a task without
  /// `in:`, and the example taught exactly that until the first project with
  /// a dozen such joins was read beside the code.
  final String root;

  /// Where the task runs, absolute: [root], or the `in:` under it — under
  /// `each:` with `in: \$each`, the member's own directory.
  final String workingDirectory;

  /// The file at [path] under [root], refused if the repository does not own
  /// it.
  ///
  /// **What every verb that touched a set's members wrote for itself**, and
  /// mostly wrote half of: joined onto [root] with the host's separator and
  /// nothing asked. [path] is read the way the file writes one — relative to
  /// the root, with `/` on every platform, so a member passes as it is — and
  /// an absolute path is allowed where it lands inside the root. A path that
  /// climbs out, or leads out through a link, ends the task with `2`, as
  /// `remove` answers on the same question.
  File file(String path) => File(_owned(path));

  /// The directory at [path] under [root], under [file]'s rules.
  Directory directory(String path) => Directory(_owned(path));

  String _owned(String path) =>
      verbPathUnderRoot(root, path) ??
      (throw RunFailure(ExitCode.invalidFile, verbPathLeavesRoot(path)));

  /// Where to write. A verb writing to `stdout` directly would bypass the
  /// grouping markers a folded CI log needs, so it is given a sink instead
  /// of finding one.
  final void Function(String line) log;

  /// [log] as a `StringSink`, for a library that writes to one — a logger, a
  /// formatter, anything taking a sink rather than a callback.
  ///
  /// **A verb handing such a library `stdout` writes past the engine**: under
  /// `-j` a task's output is collected and printed whole when it ends, and on
  /// a folding host each task is a section, and a line on `stdout` lands
  /// outside both. The first project to migrate wrote this adapter itself;
  /// the engine flushes it before each [log] line and each program [run]
  /// starts, so a partial line keeps its place, and when the verb returns,
  /// so a last one is not lost. [capture] shows nothing and flushes nothing;
  /// [tee] shows, and flushes as [run] does.
  final LogSink out;

  /// The member of `each:` this invocation is for, or null when there is none.
  ///
  /// **A verb under `each:` could not tell which member it was.** It ran once
  /// per member with the same arguments and a different working directory, and
  /// that was all it had; anything else it wanted to say about the member —
  /// name it in a message, derive a path from it — it could not, because it
  /// did not know one.
  final String? member;

  /// How a program is started on this verb's behalf. Use [run].
  final Future<int> Function(List<String> argv, {String? workingDirectory})
  start;

  /// How a program is found on this verb's behalf. Use [which].
  final String? Function(String name, {String? workingDirectory})? locate;

  /// How a program is run to the end with its output kept. Use [capture].
  final Future<Captured> Function(
    List<String> argv, {
    String? workingDirectory,
    Duration? timeout,
  })?
  collect;

  /// How a program is run to the end with its output kept and shown. Use
  /// [tee].
  final Future<Captured> Function(
    List<String> argv, {
    String? workingDirectory,
    Duration? timeout,
  })?
  relay;

  /// Runs [argv] the way a `run:` body is run, and answers with its code.
  ///
  /// Logic goes in Dart, so a verb has to be able to run a program without
  /// losing what a `run:` body gets: the `PATH` walk, the `PATHEXT` rules, the
  /// refusal to hand `cmd.exe` a metacharacter through a batch shim, and the
  /// exit code that says a tool is missing rather than broken.
  ///
  /// [workingDirectory] is a path from the repository root, written the way
  /// the file writes one, and an absolute one is allowed where it lands inside
  /// the root — so passing this context's own directory back in says what it
  /// looks like it says. Left null it is the task's own, which under `each:`
  /// is already the member's.
  ///
  /// It is passed through as written rather than defaulted here, so the engine
  /// can still tell a path a verb wrote from one it handed out.
  Future<int> run(List<String> argv, {String? workingDirectory}) =>
      start(argv, workingDirectory: workingDirectory);

  /// The file [name] would start as, absolute, or `null` when nothing would.
  ///
  /// The lookup a `run:` body gets — `PATH`, `PATHEXT` on Windows, a name with
  /// a separator taken as a path from [workingDirectory], under [run]'s rules
  /// for it — so a verb that has to decide before it starts something asks
  /// the same question the start will, given the same directory. The first
  /// project to migrate wrote its own `PATH` walk for this, and a second one
  /// is a second set of Windows rules to get wrong. A [workingDirectory]
  /// outside the repository is refused, as [run] refuses it, rather than
  /// answered `null`.
  String? which(String name, {String? workingDirectory}) {
    final locate = this.locate;
    if (locate == null) {
      throw StateError(
        'this VerbContext was built without `locate`, so `which` cannot '
        'answer; the engine always gives one, and a test calling `which` has '
        'to as well',
      );
    }
    return locate(name, workingDirectory: workingDirectory);
  }

  /// Runs [argv] to the end and answers with its exit code and its output,
  /// [Captured] whole rather than streamed.
  ///
  /// Started exactly as [run] starts it — the same lookup, the same refusal
  /// to hand `cmd.exe` a metacharacter through a batch shim, the same `3`
  /// with the same sentence when nothing on `PATH` answers to the name, the
  /// same rules for [workingDirectory]. **Without this a verb that had to read
  /// what a program said reached for `Process.run`**, and lost every one of
  /// those. Nothing is shown while it runs, and its standard input is closed.
  ///
  /// [timeout] is the one thing a verb can say about a program it waits on:
  /// one that outlives it is asked to stop, then made to, and answers 124 —
  /// `timeout(1)`'s number — with whatever it had written. A `do:` cannot
  /// carry a `timeout:`, and wrapping this call in `Future.timeout` would
  /// leave the program running. Like a task's `timeout:`, it does not reach
  /// the program's own children.
  Future<Captured> capture(
    List<String> argv, {
    String? workingDirectory,
    Duration? timeout,
  }) {
    final collect = this.collect;
    if (collect == null) {
      throw StateError(
        'this VerbContext was built without `collect`, so `capture` cannot '
        'run anything; the engine always gives one, and a test calling '
        '`capture` has to as well',
      );
    }
    return collect(
      argv,
      workingDirectory: workingDirectory,
      timeout: timeout,
    );
  }

  /// [capture], with the output shown as it arrives — as [run] shows it.
  ///
  /// **For a program a verb waits minutes on and then reads.** [run] shows
  /// the output and keeps none of it; [capture] keeps it and shows nothing
  /// until the program has ended, so a verb that needed a benchmark's report
  /// printed it all at the end and left the screen blank for the minutes
  /// before. Everything else is [capture]'s: the start, the `3` for a program
  /// nothing answers to, the rules for [workingDirectory], the closed standard
  /// input, and [timeout] answering 124.
  ///
  /// Shown a line at a time through [log], stdout's and stderr's in the order
  /// they arrived, so under `-j` it is collected with the rest of the task's
  /// output and on a folding host it lands inside the task's section. What
  /// [Captured] holds is each stream as the program wrote it.
  Future<Captured> tee(
    List<String> argv, {
    String? workingDirectory,
    Duration? timeout,
  }) {
    final relay = this.relay;
    if (relay == null) {
      throw StateError(
        'this VerbContext was built without `relay`, so `tee` cannot run '
        'anything; the engine always gives one, and a test calling `tee` has '
        'to as well',
      );
    }
    return relay(argv, workingDirectory: workingDirectory, timeout: timeout);
  }
}

/// A `StringSink` that hands each complete line to [log].
///
/// What is written without a trailing newline is held until the next newline
/// or [flush]. The engine flushes [VerbContext.out] before anything else
/// reaches the log and when the verb returns; a sink made by hand is flushed
/// by whoever made it.
final class LogSink implements StringSink {
  LogSink(this.log);

  /// Where each complete line goes.
  final void Function(String line) log;
  final _pending = StringBuffer();

  @override
  void write(Object? object) {
    final text = '$object';
    var start = 0;
    while (true) {
      final newline = text.indexOf('\n', start);
      if (newline < 0) {
        _pending.write(text.substring(start));
        return;
      }
      _pending.write(text.substring(start, newline));
      _emit();
      start = newline + 1;
    }
  }

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  /// Hands on what a last write left without a newline, if anything.
  void flush() {
    if (_pending.isEmpty) {
      return;
    }
    _emit();
  }

  /// The pending line, handed on and cleared.
  ///
  /// A `\r\n` ends a line as a `\n` does, as it does in what [VerbContext.tee]
  /// shows: a library that writes CRLF otherwise handed every line on with a
  /// `\r` on the end, which a terminal reads as "go back to the start".
  void _emit() {
    final line = '$_pending';
    _pending.clear();
    log(line.endsWith('\r') ? line.substring(0, line.length - 1) : line);
  }
}

/// Starting a process, as a seam.
///
/// **Injected, so a test never starts a toolchain.** Almost everything worth
/// asserting about execution — the order, the working directory, the
/// environment, what happens after a failure, which member of an `each:` was
/// reached — is about WHICH processes would start and with what, none of which
/// needs a real one. The one thing the fake cannot answer is whether a real
/// process streams, and that has its own test against a real one.
abstract interface class ProcessStarter {
  /// Runs [executable] with [arguments] and answers with its exit code.
  ///
  /// [environment] is **everything the child sees**, not an addition to this
  /// process's own: the engine has already built it from this machine's, and
  /// a variable missing from it is one `env-unset:` asked to be gone.
  ///
  /// Output goes straight through as it arrives, and is never buffered to
  /// the end, because a long test run has to be watchable.
  /// [timeout], where a task set one, is the starter's to enforce — not the
  /// caller's. Only whoever holds the process can kill it, and a deadline
  /// applied by waiting less would report a timeout while the process ran on.
  ///
  /// [output], when given, is where the body's own stdout and stderr go
  /// instead of straight through — **the one place that promise is
  /// deliberately not kept**, and only a run that asked to be parallel gives
  /// it. Two tasks writing to one terminal at once produce a transcript
  /// belonging to neither, and a section that folds lines from two tasks folds
  /// nothing; collecting each task's output and printing it whole is the price
  /// of running them together, and it is why parallelism is opt-in.
  Future<int> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
    Duration? timeout,
    Future<void>? until,
    void Function(String line)? output,
  });

  /// Runs [executable] with [arguments] to the end, with its standard input
  /// closed, and answers with its code and each output stream whole.
  ///
  /// The one way a body's output is kept rather than shown: only a verb asks
  /// for it, through [VerbContext.capture], and only because it has to read
  /// what the program said. [timeout], where given, is enforced here, for
  /// [start]'s reason: only whoever holds the process can stop it.
  ///
  /// [echo], when given, is handed each line as it arrives as well — what
  /// [VerbContext.tee] is. The streams are kept whole either way.
  Future<Captured> capture(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
    Duration? timeout,
    void Function(String line)? echo,
  });
}
