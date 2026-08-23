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
