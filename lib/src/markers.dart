/// Making a run readable on the host it runs on.
library;

/// How a host wants a section of output marked.
///
/// **This is what makes one invocation per job acceptable.** §7.1 has a CI job
/// run `xtask ci-analyze` as its only step rather than one step per task, and
/// the obvious objection is that a failure then arrives as one blob. Grouping
/// answers it: each task is a collapsible section and the failing one is
/// annotated with the command that broke, which is not worse than a step per
/// task and additionally shows the order.
///
/// What grouping does **not** do is say how long anything took, and it cannot:
/// a line inside a group is folded away with it, so a duration printed beside
/// its task is invisible in exactly the state somebody is in when they want
/// one. `Executor` prints the timing after the last section instead.
sealed class LogMarkers {
  const LogMarkers();

  /// The markers for the host described by [environment].
  ///
  /// Detected rather than configured. A flag would be a second place to say
  /// where the run is happening, and it would be wrong on the day somebody
  /// copies a workflow.
  factory LogMarkers.forHost(Map<String, String> environment) =>
      environment['GITHUB_ACTIONS'] == 'true'
      ? const GitHubMarkers()
      : const PlainMarkers();

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
  const PlainMarkers();

  @override
  List<String> open(String task) => ['── $task ──'];

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
  List<String> open(String task) => ['::group::${_escaped(task)}'];

  @override
  List<String> close() => const ['::endgroup::'];

  /// **Closed before the annotation, deliberately.** An `::error::` inside a
  /// group is folded away with it, so the one line somebody needs is the one
  /// line they have to expand a section to reach.
  @override
  List<String> error(String message) => [
    '::endgroup::',
    '::error::${_escaped(message)}',
  ];

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
  static String _escaped(String message) => message
      .replaceAll('%', '%25')
      .replaceAll('\r', '%0D')
      .replaceAll('\n', '%0A');
}
