/// What a verb is handed, and what starts a process — the two seams execution
/// is built on.
library;

/// A job the project implements in Dart, named by a task's `do:` key (§9).
///
/// Rule R1 pushes logic here deliberately: the file cannot branch, so a task
/// that needs a condition becomes one of these instead. It is ordinary Dart —
/// testable, typed, debuggable — and free to do whatever it needs.
typedef Verb = Future<int> Function(VerbContext context);

/// Everything a verb is given (§9).
final class VerbContext {
  const VerbContext({
    required this.args,
    required this.env,
    required this.workingDirectory,
    required this.log,
  });

  /// The task's `args:`, with the members of its `argv-from` set appended —
  /// already expanded, so a verb never touches the filesystem to find out what
  /// it was asked about.
  final List<String> args;

  /// The environment for this task only (§4.3).
  final Map<String, String> env;

  /// Where the task runs, absolute.
  final String workingDirectory;

  /// Where to write. A verb writing to `stdout` directly would bypass the
  /// grouping markers §7.1 needs, so it is given a sink instead of finding
  /// one.
  final void Function(String line) log;
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
  /// Output goes straight through as it arrives; §5.2 requires it never be
  /// buffered to the end, because a long test run has to be watchable.
  Future<int> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
  });
}
