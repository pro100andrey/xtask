/// Making a run readable on the host it runs on.
library;

import 'style.dart';

/// How a host wants a section of output marked.
///
/// What makes one invocation per job acceptable: each task is a
/// collapsible section and the failing one is annotated with the command that
/// broke, so a failure does not arrive as one blob.
///
/// It cannot say how long anything took — a line inside a group is folded away
/// with it, so a duration beside its task is invisible in exactly the state
/// somebody is in when they want one. `Executor` prints the timing after the
/// last section instead.
sealed class LogMarkers {
  const LogMarkers();

  /// The markers for the host described by [environment].
  ///
  /// Detected rather than configured. A flag would be a second place to say
  /// where the run is happening, and it would be wrong on the day somebody
  /// copies a workflow.
  ///
  /// [style] reaches the plain heading only. GitHub's markers are commands
  /// the runner reads to the end of the line, and a colour code in one is
  /// part of the group's name or the annotation's text.
  factory LogMarkers.forHost(
    Map<String, String> environment, {
    Style style = Style.plain,
  }) => environment['GITHUB_ACTIONS'] == 'true'
      ? const GitHubMarkers()
      : PlainMarkers(style);

  /// Opens a section for [task].
  List<String> open(String task);

  /// Closes the section [open] began.
  List<String> close();

  /// Marks [message] as the failure, where the host has a way to.
  List<String> error(String message);
}

/// A terminal, or any host with nothing to say about sections.
///
/// Still prints the task name: the point of a section is knowing which task
/// the next hundred lines belong to, and that is worth having with or without
/// a fold.
final class PlainMarkers extends LogMarkers {
  const PlainMarkers([this.style = Style.plain]);

  /// How the heading is drawn.
  final Style style;

  /// **Bold, rule and name together.** A body's own output is never
  /// coloured, so in a long transcript the heading is the one line that says
  /// where the next task begins; bold makes it findable at a glance without
  /// a colour that would read as a verdict before the task has one.
  @override
  List<String> open(String task) => [
    style.paint(
      '${style.glyphs.rule} $task ${style.glyphs.rule}',
      Tint.heading,
    ),
  ];

  @override
  List<String> close() => const [];

  @override
  List<String> error(String message) => ['error: $message'];
}

/// GitHub Actions, which folds `::group::` and annotates `::error::`.
final class GitHubMarkers extends LogMarkers {
  const GitHubMarkers();

  /// Escaped for the reason [error] is: a task name is a name somebody wrote,
  /// and `::group::` is read to the end of its line like any other workflow
  /// command. The escaping was added to the annotation and not to this, so the
  /// fold could still be opened on half a name with the rest printed beside
  /// it as stray output.
  @override
  List<String> open(String task) => ['::group::${workflowEscaped(task)}'];

  @override
  List<String> close() => const ['::endgroup::'];

  /// **Closed before the annotation, deliberately.** An `::error::` inside a
  /// group is folded away with it, so the one line somebody needs is the one
  /// line they have to expand a section to reach.
  @override
  List<String> error(String message) => [
    '::endgroup::',
    '::error::${workflowEscaped(message)}',
  ];
}

/// GitHub reads a workflow command up to the end of its line, so a newline
/// inside one truncates the annotation and prints the rest as plain output.
///
/// **`%` first, and the order is the whole rule.** The runner decodes the
/// percent escapes it reads back, so leaving `%` alone meant a message that
/// already contained `%0A` — a URL-encoded path, a `--name a%0Ab` quoted
/// back out of the argv `describe` prints — was decoded into exactly the
/// newline this exists to remove, and the annotation stopped there. Escaped
/// after the others instead, it would re-escape their own `%` and the reader
/// would be shown the text `%0A`.
///
/// Public, because `secrets.dart` masks a value in the form this writes it
/// in: a secret holding `%` reaches an annotation as `%25`, and a mask that
/// looked only for the value as written would let it through.
String workflowEscaped(String message) => message
    .replaceAll('%', '%25')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A');
