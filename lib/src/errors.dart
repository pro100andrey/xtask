import 'package:source_span/source_span.dart';

/// A refusal to read the file, reported at the place that caused it.
///
/// §5.3 gives this exit code `2`, "distinguished because a `2` is never the
/// code's fault". That distinction is only worth anything if the message says
/// which line to look at, which is why the span travels with the message
/// instead of being flattened into a string at the throw site.
final class XtaskFormatException implements Exception {
  XtaskFormatException(this.message, [this.span]);

  /// What was wrong, in the terms the file is written in.
  final String message;

  /// Where it was wrong. Absent only when the failure has no single place —
  /// an empty document, or a file that is not a mapping at all.
  final SourceSpan? span;

  /// The message a person reads: `SourceSpan` renders the offending line with
  /// a caret under it, which is the whole reason §8 can promise that a
  /// non-breaking space pasted from a document does not become "a parse error
  /// with a useless message".
  @override
  String toString() => span?.message(message) ?? message;
}

/// Why a run stopped, when it stopped.
///
/// Beside [XtaskFormatException] because it is the same kind of thing said a
/// different way: one carries a line to look at, the other the code §5.3 gives
/// the outcome. It lived in the executor while only the executor threw it —
/// resolution throws it too now, and neither of them owns it.
final class RunFailure implements Exception {
  const RunFailure(this.code, this.message);

  /// One of the codes §5.3 defines — see `exit_codes.dart`, which is not
  /// imported here because an exception type that depended on the vocabulary
  /// of exit codes would be a cycle waiting to be written.
  final int code;

  /// What to print. Names the task, and under `each:` the member.
  final String message;

  @override
  String toString() => message;
}

/// Why a task in the plan did not run.
///
/// **A value, not a string.** These four reasons used to be written into one
/// map as free text and printed through one template — `skipped $name (needs
/// $blocker)` — which is a true sentence for the first of them and a false one
/// for the rest. A task stopped because something *else* failed does not need
/// anything, and what came out was `skipped third (needs a failure
/// elsewhere)`. A reason that carries its own sentence cannot be put into the
/// wrong one.
sealed class Skipped {
  const Skipped();

  /// What the summary says after the task's name.
  String get sentence;
}

/// Something it needs failed, or was itself skipped.
final class NeedsStopped extends Skipped {
  const NeedsStopped(this.name);

  final String name;

  @override
  String get sentence => 'needs `$name`, which did not pass';
}

/// It is the continuation of a task that did not succeed.
///
/// Separate from [NeedsStopped] because `then:` is not `needs:`: a publish that
/// failed is not something the announcement *required*, it is something the
/// announcement was to follow, and saying the first would misdescribe the file.
final class FollowsStopped extends Skipped {
  const FollowsStopped(this.name);

  final String name;

  @override
  String get sentence => 'follows `$name`, which did not pass';
}

/// Something else failed and this run is not keeping going.
final class RunStopped extends Skipped {
  const RunStopped();

  @override
  String get sentence => 'the run stopped at an earlier failure';
}

/// Nothing that could have started it ever finished.
///
/// **A guard against a plan that is not in order, not a case that happens.**
/// `planRun` emits every requirement before the task that needs it, so by the
/// time the walk reaches a step its needs have all been taken off the queue —
/// this cannot fire. It exists because the alternative to noticing is
/// spinning: a walk with nothing running and nothing startable would loop
/// forever, and a hang is the one failure with nothing to read afterwards.
final class NeverStartable extends Skipped {
  const NeverStartable();

  @override
  String get sentence => 'nothing that would let it start ever finished';
}
