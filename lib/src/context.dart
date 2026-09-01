/// What a verb is handed, and what starts a process — the two seams execution
/// is built on.
library;

/// A job the project implements in Dart, named by a task's `do:` key.
///
/// Rule R1 pushes logic here deliberately: the file cannot branch, so a task
/// that needs a condition becomes one of these instead. It is ordinary Dart —
/// testable, typed, debuggable — and free to do whatever it needs.
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

/// Everything a verb is given.
final class VerbContext {
  const VerbContext({
    required this.args,
    required this.env,
    required this.workingDirectory,
    required this.log,
    required this.start,
    this.member,
  });

  /// Everything the body was given, in one list: the task's `args:` with any
  /// `\$all` and `\$each` already standing for what they name, then whatever
  /// the command line passed after `--`.
  ///
  /// **In place, not appended.** A set used to be added at the end and nowhere
  /// else; `\$all` is written where its members belong, so the order here is
  /// the order the file wrote.
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

  /// Where the task runs, absolute.
  final String workingDirectory;

  /// Where to write. A verb writing to `stdout` directly would bypass the
  /// grouping markers a folded CI log needs, so it is given a sink instead
  /// of finding one.
  final void Function(String line) log;

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

  /// Runs [argv] the way a `run:` body is run, and answers with its code.
  ///
  /// **Because "make it a verb" was advice that could not be taken.** R1 puts
  /// logic in Dart and the README sends derived paths there — `x.proto` to
  /// `x.pb.dart` is a verb's job — but a verb that wanted to run a program had
  /// to reach for `Process.start` itself, and lost the engine's `PATH` walk,
  /// its
  /// `PATHEXT` rules, its refusal to hand `cmd.exe` a metacharacter through a
  /// batch shim, and the exit code that says a tool is missing rather than
  /// broken. Half an escape hatch is not one.
  ///
  /// [workingDirectory] is a path from the repository root, written the way
  /// the file writes one — and left as null it is the task's own, which under
  /// `each:` is already the member's. An absolute path is taken as written and
  /// allowed where it lands inside the root, so passing [workingDirectory]
  /// back in, or a path composed around it, says what it looks like it says.
  ///
  /// **Passed through as written, not defaulted here.** Filling it in with
  /// [workingDirectory] made every call arrive at the engine holding an
  /// absolute path it had already resolved, which is indistinguishable from a
  /// verb that wrote one — so the boundary the engine draws around the root
  /// could not be drawn at all without refusing the ordinary call. The engine
  /// applies the same default one layer down, where it can still tell the two
  /// apart.
  Future<int> run(List<String> argv, {String? workingDirectory}) =>
      start(argv, workingDirectory: workingDirectory);
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
}
