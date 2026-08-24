/// Resolving what runs, and in what order — §5.1 of `xtask.md`.
///
/// **Planning is separate from running.** This answers "what would happen",
/// which is the same question `--dry-run` asks (§7) and the same one an
/// execution needs answered before it starts. Keeping them apart is what stops
/// `--dry-run` from being a second implementation of the order — a second list,
/// which is the defect §1 exists to remove.
library;

import 'errors.dart';
import 'model.dart';

/// One task, in the position the run reaches it.
final class PlanStep {
  const PlanStep(this.task, {this.continuationOf});

  final Task task;

  /// The task whose `then:` began the continuation this step is inside, or
  /// null when the run reached it directly.
  ///
  /// **The origin, not the immediate parent.** `b then c`, `c needs d` puts d
  /// before c, so asking "did c fail" when d is reached answers about a task
  /// that has not run yet. What decides whether this step should happen is
  /// whether the task whose `then:` opened the whole subtree succeeded, and
  /// that is what is carried down.
  ///
  /// It exists for two things. §5.3 gives a continuation its own exit code —
  /// a body that succeeded and a continuation that failed is a third outcome,
  /// not a failure of the body — and `--keep-going` needs to know that a
  /// publish which failed must not be announced anyway.
  final String? continuationOf;

  /// Whether the run arrived here through a `then:`, at any depth.
  ///
  /// Derived rather than stored beside [continuationOf]: two fields saying one
  /// thing are two fields that can disagree.
  bool get isContinuation => continuationOf != null;
}

/// The order a run will take.
final class Plan {
  const Plan(this.steps);

  /// Every task that will be reached, once each, in order.
  final List<PlanStep> steps;

  /// The names, in order — what `--gates` prints and `--dry-run` walks.
  List<String> get names => [for (final step in steps) step.task.name];
}

/// The order [taskName] resolves to in [file].
///
/// Order is: every `needs` in declared order, depth-first; then the task
/// itself; then every `then` in declared order. A task appears **at most
/// once**, however many tasks depend on it.
///
/// Throws [XtaskFormatException] — exit code 2 — for a name that does not
/// exist and for a cycle, which is reported with the cycle spelled out.
Plan planRun(XtaskFile file, String taskName) {
  final planner = _Planner(file)..resolve(taskName, from: null);
  return Plan(List.unmodifiable(planner.steps));
}

final class _Planner {
  _Planner(this.file);

  final XtaskFile file;
  final steps = <PlanStep>[];

  /// Tasks already emitted — the run-once rule.
  final _done = <String>{};

  /// Tasks whose resolution has begun and not finished, innermost last. This
  /// is both the cycle detector and the thing that can print the cycle.
  final _open = <String>[];

  /// The ring [name] closes, written from a fixed point.
  ///
  /// The members are whatever is open from [name] onwards — entering the ring
  /// at a different task must not name a task that is not in it. Among those,
  /// it starts at the alphabetically first, because **a ring has no start**:
  /// printing it from wherever the walk happened to arrive gives the same
  /// cycle several different spellings, and anything trying to tell one ring
  /// from another — `--validate` reporting each once rather than once per
  /// member — would be comparing entry points instead of cycles.
  List<String> _ring(String name) {
    final members = _open.skipWhile((n) => n != name).toList();
    final first = members.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
    final at = members.indexOf(first);
    final rotated = [...members.skip(at), ...members.take(at)];
    return [...rotated, first];
  }

  void resolve(
    String name, {
    required Task? from,
    String? continuationOf,
  }) {
    if (_done.contains(name)) {
      return;
    }

    final task = file.tasks[name];
    if (task == null) {
      throw XtaskFormatException(
        from == null
            ? 'there is no task called `$name`'
            : 'task `${from.name}` names `$name`, and there is no such task',
        from?.span,
      );
    }

    if (_open.contains(name)) {
      // Reached only through `needs`; a `then:` re-entry is handled where it
      // is issued, below. §5.1 makes this a validation error and asks for the
      // cycle itself, because "there is a cycle" leaves the reader to find it
      // in a file that just proved it is hard to read.
      throw XtaskFormatException(
        'these tasks need each other, so none of them can go first: '
        '${_ring(name).join(' → ')}',
        task.span,
      );
    }

    _open.add(name);
    for (final need in task.needs) {
      // Inside the same continuation as whatever needed it: a task pulled in
      // by a continuation's own `needs:` is part of that continuation.
      resolve(need, from: task, continuationOf: continuationOf);
    }
    _open.removeLast();

    // Emitted before the continuations, which is what makes `then:` a
    // continuation rather than a dependency: the body has happened by the time
    // anything in `then:` is reached.
    _done.add(name);
    steps.add(PlanStep(task, continuationOf: continuationOf));

    for (final next in task.then) {
      if (_open.contains(next)) {
        // A task still being resolved further up will emit itself when its own
        // frame finishes. Skipping here keeps the run-once rule without
        // calling this a cycle: `a needs b`, `b then a` is an ordering both
        // keys agree on — b, then a — and refusing it would refuse a file that
        // says nothing contradictory.
        continue;
      }
      resolve(next, from: task, continuationOf: name);
    }
  }
}
