/// Resolving what runs, and in what order.
///
/// **Planning is separate from running.** This answers "what would happen",
/// which is the same question `--dry-run` asks (§7) and the same one an
/// execution needs answered before it starts. Keeping them apart is what stops
/// `--dry-run` from being a second implementation of the order — a second list,
/// which is the defect §1 exists to remove.
library;

import 'package:source_span/source_span.dart';

import 'errors.dart';
import 'gates.dart';
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

  /// The names, in order — what `--gate-members` prints and `--dry-run` walks.
  List<String> get names => [for (final step in steps) step.task.name];
}

/// One edge of the graph, as `--why` prints it.
final class PlanEdge {
  const PlanEdge(this.from, this.kind, this.to);

  final String from;

  /// `needs` or `then` — and they are not interchangeable. "It runs before
  /// this" and "it runs after this" are opposite answers to "why is it here",
  /// and printing one for the other would be a lie with a plausible shape.
  final String kind;

  final String to;

  @override
  String toString() => '$from $kind $to';
}

/// The tasks nothing else names — the ones somebody types.
///
/// A gate set's members are among them: typing `xtask format` is as real an
/// entry as typing `xtask check`, and §7 says both are things a person does.
/// What a gate set adds is a second way in, which `--why` reports separately.
List<String> entryPoints(XtaskFile file) {
  final named = <String>{};
  for (final task in file.tasks.values) {
    named
      ..addAll(task.needs)
      ..addAll(task.then);
  }
  return [
    for (final name in file.tasks.keys)
      if (!named.contains(name)) name,
  ];
}

/// One route from [from] to [to] through `needs:` and `then:`, or null.
///
/// **The route the planner would take, not the shortest.** Where several
/// reach the same task, declaration order decides — which is the order
/// `planRun` walks, so the answer to "why is this here" describes the run
/// rather than an equally true alternative the run does not take.
///
/// An empty list means [from] and [to] are the same task: it is reached by
/// being asked for.
List<PlanEdge>? routeTo(
  XtaskFile file, {
  required String from,
  required String to,
}) {
  // The path being walked, so a cycle does not hang it.
  final seen = <String>{};
  // **And what has already been proven not to reach [to].** `seen` had to
  // become a path rather than a visited set — kept across branches, a dead
  // branch marked everything it touched unreachable and a route down a later
  // edge was answered "nothing reaches it". But a path set alone re-walks
  // every shared subtree once per path, and `--why` asks this once per gate
  // member per gate. A no is worth remembering; a yes returns immediately.
  final hopeless = <String>{};
  // **And nothing is remembered once a ring has been met.** A branch cut short
  // by the path guard says nothing about that task in general — entered from
  // somewhere else, the edge it turned back on would be walked. Cycles are
  // §8's to refuse, so this costs the fast bound only on files that are
  // already being reported as broken.
  var metARing = false;

  List<PlanEdge>? walk(String at) {
    if (at == to) {
      return const [];
    }
    if (hopeless.contains(at)) {
      return null;
    }
    // A cycle is `--validate`'s to report; here it must only not hang.
    if (!seen.add(at)) {
      metARing = true;
      return null;
    }
    // **Removed again on the way out.** Kept, it marked every task a dead
    // branch had touched as unreachable for the rest of the search, so a route
    // that existed down a later edge was answered "nothing reaches it" — the
    // one answer §8 says this question exists to prevent. Cheap here and
    // wrong-shaped everywhere: `seen` is the path, not the visited set.
    void done({required bool reached}) {
      seen.remove(at);
      if (!reached && !metARing) {
        hopeless.add(at);
      }
    }

    final task = file.tasks[at];
    if (task == null) {
      // Taken off the path on the way out, like every other return. Left on
      // it, a second branch reaching the same dangling name read it as a ring
      // and switched the memo off for the rest of the question.
      seen.remove(at);
      return null;
    }
    for (final (kind, next) in [
      for (final need in task.needs) ('needs', need),
      for (final next in task.then) ('then', next),
    ]) {
      final rest = walk(next);
      if (rest != null) {
        done(reached: true);
        return [PlanEdge(at, kind, next), ...rest];
      }
    }
    done(reached: false);
    return null;
  }

  return walk(from);
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

/// The order the tasks in gate set [gate] resolve to, in declared order.
///
/// **What `collects:` used to be, without the composite.** A gate set was
/// rewritten into an ordinary task whose `needs:` were its members, so that
/// this file would not have to learn a third kind of edge. It still does not:
/// one planner, seeded with each member in turn, gives the same order, the
/// same run-once rule and the same cycle report — and drops the special case
/// the rewrite needed, where a composite in the gate set it gathers had to be
/// removed from its own members to avoid needing itself.
Plan planGate(XtaskFile file, String gate) {
  final planner = _Planner(file);
  for (final task in tasksInGate(file, gate)) {
    planner.resolve(task.name, from: null);
  }
  return Plan(List.unmodifiable(planner.steps));
}

/// The plan for [name], whether it is a gate set or a task.
///
/// **One name space, asked in one place.** §7 says a person types what they
/// want to happen, and a gate set is as much that as a task is — `xtask check`
/// used to work only because a composite task happened to carry the same name.
/// A gate set is now what its declaration says it is, so this is where the two
/// meet, and `_checkNoNameCollision` in the validator is what keeps the
/// question answerable.
///
/// **Here rather than at the command line, because it is a question about the
/// graph.** It lived in `cli.dart`, which meant this file offered [planRun] and
/// [planGate] while every caller wanted neither on its own: a reader asking how
/// a typed name becomes a plan read this file and did not find the function
/// that actually runs.
Plan planFor(XtaskFile file, String name) {
  if (!file.gates.containsKey(name)) {
    return planRun(file, name);
  }
  if (file.tasks.containsKey(name)) {
    // §8 reports this too, but a run must not quietly pick one of them: the
    // composite this replaced could not be ambiguous, and silently preferring
    // the gate set would run a plan the reader did not ask for.
    throw bothAGateSetAndATask(name, file.gates[name]);
  }
  final plan = planGate(file, name);
  if (plan.steps.isEmpty) {
    // **Silence would be a green gate that ran nothing.** An empty plan
    // printed nothing and answered 0, so a CI job whose only step is `xtask
    // check` passed in complete silence when every member's `gate:` was
    // misspelled — the exact failure this tool is against, reached by the one
    // path that does not validate first.
    throw XtaskFormatException(
      'gate set `$name` has no tasks in it, so running it would check '
      'nothing and answer 0. Put a task in it, or stop declaring it',
      file.gates[name],
    );
  }
  return plan;
}

/// Every way a run reaches [task]: the gate sets that run it, and the tasks
/// somebody types that lead to it — the whole of what `--why` prints.
///
/// **The gate sets are the half that used to be free.** A composite was a
/// task, so [entryPoints] found it and the route ran through its `needs:`. A
/// declared gate set has no such edge, and without this `--why format` would
/// answer "nothing reaches it" about a task that every `check` runs — the one
/// answer §8 says this question exists to prevent.
///
/// **Composed here rather than at the command line.** [routeTo] and
/// [entryPoints] are the pieces; this is the question, and it is a question
/// about the graph whichever mode happens to ask it.
Map<String, List<PlanEdge>> routesTo(XtaskFile file, String task) {
  final routes = <String, List<PlanEdge>>{};
  for (final gate in file.gates.keys) {
    for (final member in tasksInGate(file, gate)) {
      final route = routeTo(file, from: member.name, to: task);
      if (route == null) {
        continue;
      }
      // The first member that reaches it, which is the one the run reaches it
      // through: members are planned in declared order.
      // The edge is written even when the member IS the task, because an
      // empty route means "you typed it" — true of a task, and never of a
      // gate set, which reaches it by running it.
      routes.putIfAbsent(
        'gate $gate',
        () => [PlanEdge('gate $gate', 'runs', member.name), ...route],
      );
    }
  }
  for (final entry in entryPoints(file)) {
    final route = routeTo(file, from: entry, to: task);
    if (route != null) {
      routes[entry] = route;
    }
  }
  return routes;
}

/// The refusal for a name the file gives to a gate set and to a task.
///
/// **One sentence, because a person types one name.** It was written out at
/// three sites — the planner, the validator and the command line — in three
/// wordings, and the third had drifted into being wrong: `--why check` on a
/// colliding name answered "`check` is a gate set, not a task", which is false
/// about a file that declares both.
XtaskFormatException bothAGateSetAndATask(String name, SourceSpan? span) =>
    XtaskFormatException(
      '`$name` is both a gate set and a task, and a person types one name. '
      'Rename one of them: a gate set is run by being named, so there is '
      'nothing left for a task of the same name to be',
      span,
    );

/// Refuses [name] unless it is a task `--why` can answer about.
///
/// **The same table the planner walks, asked from the other side.** The
/// command line asked `gates.containsKey` first and had no arm for a name that
/// is both, so a colliding name was reported as a gate set and not a task —
/// about a file where it is also a task, and where every other mode says so.
void refuseUnlessATask(XtaskFile file, String name) {
  final isGate = file.gates.containsKey(name);
  final isTask = file.tasks.containsKey(name);
  if (isGate && isTask) {
    throw bothAGateSetAndATask(name, file.gates[name]);
  }
  if (isGate) {
    // Answerable, but not this question. What puts a gate set in a plan is
    // that somebody typed it; what is IN it is `--gate-members`.
    throw XtaskFormatException(
      '`$name` is a gate set, not a task — a run reaches it because somebody '
      'typed it. For what it runs, `--gate-members $name`',
      file.gates[name],
    );
  }
  if (!isTask) {
    throw XtaskFormatException('there is no task called `$name`');
  }
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
      // **A declared gate set is not "no such task".** Said that way it was
      // false — the file declares the name — and `--validate` printed it
      // ahead of the accurate sentence, so the first diagnostic a reader met
      // was the wrong one. An edge runs between tasks; a gate set is a list.
      final isGate = file.gates.containsKey(name);
      throw XtaskFormatException(
        switch ((from, isGate)) {
          (null, true) =>
            '`$name` is a gate set, not a task — run it by naming it',
          (null, false) => 'there is no task called `$name`',
          (final from?, true) =>
            'task `${from.name}` names the gate set `$name` in `needs:` or '
                '`then:`, and those are edges between tasks. A gate set is a '
                'list, not a step: name the tasks, or put this one in the set',
          (final from?, false) =>
            'task `${from.name}` names `$name`, and there is no such task',
        },
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
