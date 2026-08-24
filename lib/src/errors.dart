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
