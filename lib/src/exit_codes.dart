/// What the process answers with.
///
/// Five codes, and the last two exist because collapsing them into the first
/// three sends the wrong person to look. That is the whole design: an exit
/// code is not a success flag, it is the shortest possible bug report.
abstract final class ExitCode {
  /// Everything asked for ran and passed.
  static const success = 0;

  /// A task ran and failed. The report names the task, its command line and
  /// its exit code.
  static const taskFailed = 1;

  /// The request was refused: a bad document, an unknown key, a cycle, a
  /// dangling reference, a set that expands to nothing — and a command line
  /// the parser turns down, or a `--check-ci` that found something.
  ///
  /// **The file is the common case and not the whole of it**, which the name
  /// keeps saying and the table did too: `xtask --bogus` and a red
  /// `--check-ci` both answer 2, and a reader told "the file was refused"
  /// goes and looks at `xtask.yaml`. What the three share is that nothing ran
  /// and nothing was going to — the request was wrong before any task began.
  ///
  /// Distinguished because a `2` is never the code's fault.
  static const invalidFile = 2;

  /// A task's executable was not found on `PATH`, or at the path the task
  /// named.
  ///
  /// Distinguished because "Dart is not installed on this machine" and "the
  /// code is broken" are repaired by different people, and one exit code sends
  /// both to the same one.
  static const missingTool = 3;

  /// A task's body succeeded and one of its `then:` continuations failed.
  ///
  /// The outcome `then:` was invented for. A publish followed by a
  /// verification has three endings, not two: nothing was published,
  /// everything passed, or **the upload happened and the check after it is
  /// red**. Collapsing the third into [taskFailed] tells a pipeline the
  /// publish failed, which is false and unrecoverable in the wrong direction —
  /// the registry will not accept that version again.
  static const continuationFailed = 4;

  /// What a [continuationFailed] run prints, and what the Makefile it replaces
  /// already printed.
  static const continuationNotice =
      'the upload took place, and a red result below it does not undo that';
}
