import 'package:source_span/source_span.dart';

/// A refusal to read the file, reported at the place that caused it.
///
/// §5.3 gives this exit code `2`, "distinguished because a `2` is never the
/// code's fault". That distinction is only worth anything if the message says
/// which line to look at, which is why the span travels with the message
/// instead of being flattened into a string at the throw site.
base class XtaskFormatException implements Exception {
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
base class RunFailure implements Exception {
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

/// A set that matched nothing.
///
/// **A type rather than a sentence to match on.** Two callers need to tell
/// this apart from every other reason a set is refused — a pattern that leaves
/// the repository, a pattern that is not a pattern — because only this one can
/// stop being true later. Told apart by reading the message, they told it
/// apart wrongly: `--dry-run` reported a boundary violation and an unknown
/// verb as "cannot be resolved yet" and answered 0.
final class EmptySetException extends XtaskFormatException {
  EmptySetException(super.message, super.span, {required this.onlyYet});

  /// Whether this emptiness could stop being true once the run has begun.
  ///
  /// **Decided where the set is, and carried rather than re-derived.** A set
  /// whose members the run itself makes is empty before its task has run and
  /// full afterwards, and all three readers of this need to tell that apart:
  /// `--validate` passes over it, a run refuses it, `--dry-run` says "not
  /// yet". Each of them used to write the test out — `set is GlobSet &&
  /// set.produced`, in two modules — which is one rule kept in step by hand,
  /// and a third copy the day a second kind of set can be produced.
  ///
  /// The verdict travels with the refusal because the refusal is what travels.
  final bool onlyYet;
}

/// A body that cannot resolve yet because a set it names is still empty.
final class NotYetFailure extends RunFailure {
  const NotYetFailure(super.code, super.message);
}
