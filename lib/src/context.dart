/// What a verb is handed, and what starts a process — the two seams execution
/// is built on.
library;

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
  /// [locate] and [collect] are the engine's; a context built by hand — a
  /// verb's own test — gives them only if the verb under test asks, and
  /// [which] or [capture] without one says so rather than answering "absent".
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

  /// The environment the body would see: this machine's, with the task's own
  /// `env:` applied over it — and winning where both name the same variable.
  ///
  /// **Not the task's `env:` on its own**, which is what the name suggests and
  /// what this doc comment said until somebody read it beside the code. A verb
  /// that wants `PATH` finds it here; a verb that wants to know what the file
  /// declared cannot ask, and has not needed to.
  final Map<String, String> env;

  /// The repository root, absolute: the directory holding `xtask.yaml`.
  ///
  /// **Not [workingDirectory]**, which is where the task runs — `in:` moves
  /// that and leaves this alone. Every path the file writes is relative to
  /// here: a set's member, an `in:`, a `remove` argument. A verb that joins a
  /// member onto [workingDirectory] instead builds a path that is right only
  /// for a task without `in:`, and the example taught exactly that until the
  /// first project with a dozen such joins was read beside the code.
  final String root;

  /// Where the task runs, absolute: [root], or the `in:` under it — under
  /// `each:` with `in: \$each`, the member's own directory.
  final String workingDirectory;

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
  /// the engine flushes it when the verb returns, so a last line without a
  /// newline is not lost.
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
  final String? Function(String name)? locate;

  /// How a program is run to the end with its output kept. Use [capture].
  final Future<Captured> Function(
    List<String> argv, {
    String? workingDirectory,
  })?
  collect;

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
  /// a separator taken as a path from this task's directory — so a verb that
  /// has to decide before it starts something asks the same question the
  /// start will. The first project to migrate wrote its own `PATH` walk for
  /// this, and a second one is a second set of Windows rules to get wrong.
  String? which(String name) {
    final locate = this.locate;
    if (locate == null) {
      throw StateError(
        'this VerbContext was built without `locate`, so `which` cannot '
        'answer; the engine always gives one, and a test calling `which` has '
        'to as well',
      );
    }
    return locate(name);
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
  Future<Captured> capture(List<String> argv, {String? workingDirectory}) {
    final collect = this.collect;
    if (collect == null) {
      throw StateError(
        'this VerbContext was built without `collect`, so `capture` cannot '
        'run anything; the engine always gives one, and a test calling '
        '`capture` has to as well',
      );
    }
    return collect(argv, workingDirectory: workingDirectory);
  }
}

/// A `StringSink` that hands each complete line to [log].
///
/// What is written without a trailing newline is held until the next newline
/// or [flush]. The engine flushes [VerbContext.out] when the verb returns; a
/// sink made by hand is flushed by whoever made it.
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
      log('$_pending');
      _pending.clear();
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
    log('$_pending');
    _pending.clear();
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
  /// what the program said.
  Future<Captured> capture(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
  });
}
