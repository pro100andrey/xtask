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
  Set<String>? hopeless,
}) {
  // The path being walked, so a cycle does not hang it.
  final seen = <String>{};
  // **And what has already been proven not to reach [to].** `seen` had to
  // become a path rather than a visited set — kept across branches, a dead
  // branch marked everything it touched unreachable and a route down a later
  // edge was answered "nothing reaches it". But a path set alone re-walks
  // every shared subtree once per path, and `--why` asks this once per gate
  // member per gate. A no is worth remembering; a yes returns immediately.
  // **Shared across one question, when the caller has one.** Whether [to] can
  // be reached from a task does not depend on where the walk started, so a no
  // is worth remembering for the whole of `--why` — which asks this once per
  // gate member per gate, every time with the same target, and rebuilt the
  // memo from nothing for each. On a two-thousand task chain that was the
  // difference between eight seconds and a quarter of one.
  final unreachable = hopeless ?? <String>{};
  // **And nothing is remembered once a branch has been cut short.** A "no"
  // that came from the path guard rather than from having looked says nothing
  // about that task in general — entered from somewhere
  // else, the edge it turned back on would be walked. Cycles are §8's to
  // refuse, so this costs the fast bound only on files that are already being
  // reported as broken.
  var cutShort = false;

  // **Built once, on the way out.** Each level used to return
  // `[edge, ...rest]`, copying the whole remaining route at every hop — which
  // is quadratic in a route's length, and a route is as long as the chain.
  // The edges are appended as the recursion unwinds, so they come out
  // deepest-first and are reversed at the end.
  final route = <PlanEdge>[];

  /// One task on the path, and how far through its edges the walk has got.
  ///
  /// **An explicit stack, because the recursion was one frame per edge.** A
  /// `needs:` chain long enough overflowed it and ended `--why` at 255, and
  /// bounding the depth instead only moved the problem: a branch given up on
  /// is neither a route nor a proof there is none, so the answer was either
  /// silently short or a refusal of a question the deep chain never touched.
  /// A loop has no depth to bound.
  List<(String, String)> edgesOf(String at) {
    final task = file.tasks[at];
    if (task == null) {
      return const [];
    }
    return [
      for (final need in task.needs) ('needs', need),
      for (final next in task.then) ('then', next),
    ];
  }

  bool walk(String start) {
    if (start == to) {
      return true;
    }
    if (unreachable.contains(start) || file.tasks[start] == null) {
      return false;
    }
    seen.add(start);
    final path = <_Hop>[_Hop(start, edgesOf(start))];

    while (path.isNotEmpty) {
      final hop = path.last;
      if (hop.cursor == hop.edges.length) {
        // **Taken off the path on the way out.** Kept, it marked every task a
        // dead branch had touched as unreachable for the rest of the search,
        // so a route that existed down a later edge was answered "nothing
        // reaches it" — the one answer §8 says this question exists to
        // prevent. `seen` is the path, not the visited set.
        seen.remove(hop.at);
        if (!cutShort) {
          unreachable.add(hop.at);
        }
        path.removeLast();
        continue;
      }

      final (kind, next) = hop.edges[hop.cursor++];
      if (next == to) {
        route
          ..clear()
          ..addAll([
            for (final entered in path.skip(1)) entered.enteredBy!,
            PlanEdge(hop.at, kind, next),
          ]);
        for (final on in path) {
          seen.remove(on.at);
        }
        return true;
      }
      if (unreachable.contains(next)) {
        continue;
      }
      // A cycle is `--validate`'s to report; here it must only not hang.
      if (!seen.add(next)) {
        cutShort = true;
        continue;
      }
      if (file.tasks[next] == null) {
        // Taken off the path like every other end. Left on it, a second branch
        // reaching the same dangling name read it as a ring and switched the
        // memo off for the rest of the question.
        seen.remove(next);
        continue;
      }
      path.add(_Hop(next, edgesOf(next), PlanEdge(hop.at, kind, next)));
    }
    return false;
  }

  return walk(from) ? List.of(route) : null;
}

/// One task on the path a route walk is holding, and its unexplored edges.
final class _Hop {
  _Hop(this.at, this.edges, [this.enteredBy]);

  final String at;
  final List<(String, String)> edges;

  /// The edge that led here, for the route to be read off the path.
  final PlanEdge? enteredBy;

  /// How many of [edges] have been taken.
  var cursor = 0;
}

/// How deep a chain of `needs:` or `then:` this engine walks.
///
/// **A bound on the planner, because [_Planner.resolve] is one stack frame per
/// edge.** Without it a long enough chain ended `--validate` and `--dry-run`
/// on a stack overflow and exit 255, which is not a code the table defines —
/// a file answered with a crash by the modes whose job is to answer about
/// files.
///
/// It does not bound `routeTo`, which holds its own stack and walks as far as
/// a file goes: a bound there had no honest answer, because a branch given up
/// on is neither a route nor a proof there is none. Far past anything a person
/// writes either way: the depth of a real graph is the length of its longest
/// dependency chain, which is tens.
const mostDepth = 1000;

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
  final members = tasksInGate(file, gate);
  final continuations = _continuedInto(file, members);
  for (final task in members) {
    // Seeded in declaration order, minus the members another member continues
    // into: those are reached by the task whose `then:` names them, which is
    // where they belong and where they are told what they continue.
    if (!continuations.contains(task.name)) {
      planner.resolve(task.name, from: null);
    }
  }
  // And then whatever a ring of `then:` left unseeded, because every member of
  // one defers to another. Declaration order decides, as it did before: a ring
  // has no first task, and refusing the gate over it would refuse a file
  // `xtask <member>` runs without complaint.
  for (final task in members) {
    planner.resolve(task.name, from: null);
  }
  return Plan(List.unmodifiable(planner.steps));
}

/// Which of [members] another member's `then:` reaches.
///
/// **Because seeding was in declaration order and `then:` is not.** A member
/// that a second member continues into was emitted first whenever it was
/// declared first — ahead of the task it is a continuation OF, and with no
/// `continuationOf`, because nothing had reached it through a `then:` yet. A
/// `release` gate holding `verify` and `publish then verify` therefore
/// verified before it published; a failed verification answered 1 instead of
/// §5.3's code for a continuation; `_walk`'s guard on a stopped body never
/// fired, so a publish that failed was announced anyway. `planRun` had the
/// order right the whole time, which left `--why`, `--validate` and
/// `xtask publish` describing a run `xtask release` does not take.
///
/// Reachability over both kinds of edge, counted only once a `then:` has been
/// crossed. A member reached through `needs:` alone already comes out before
/// whatever needs it, whichever of the two was seeded first — so deferring it
/// would move a task for no reason, and declaration order is meaningful (§4.3).
Set<String> _continuedInto(XtaskFile file, List<Task> members) {
  // Two visited sets, because arriving before any `then:` and arriving after
  // one are different arrivals: reaching a task the first way says nothing
  // about whether it is also reachable the second.
  final directly = <String>{};
  final afterAThen = <String>{};
  final pending = <(String, bool)>[
    for (final member in members) (member.name, false),
  ];
  while (pending.isNotEmpty) {
    final (name, past) = pending.removeLast();
    if (!(past ? afterAThen : directly).add(name)) {
      continue;
    }
    // A dangling name is §8's to report, not this walk's: it answers about the
    // members, and a name with no task reaches nothing either way.
    final task = file.tasks[name];
    if (task == null) {
      continue;
    }
    for (final need in task.needs) {
      pending.add((need, past));
    }
    for (final next in task.then) {
      pending.add((next, true));
    }
  }
  return {
    for (final member in members)
      if (afterAThen.contains(member.name)) member.name,
  };
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
  // One memo for the whole question: every call below asks about the same
  // target, and what cannot reach it cannot reach it from anywhere.
  final hopeless = <String>{};

  for (final gate in file.gates.keys) {
    for (final member in tasksInGate(file, gate)) {
      final route = routeTo(
        file,
        from: member.name,
        to: task,
        hopeless: hopeless,
      );
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
    final route = routeTo(file, from: entry, to: task, hopeless: hopeless);
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
  /// is the thing that can print the cycle; [_opened] is the thing that
  /// detects one.
  final _open = <String>[];

  /// The same names, as a set.
  ///
  /// **Because `contains` on the list is a scan, and it runs per edge.** One
  /// plan of depth d cost O(d²), and `--validate` plans every task — so a
  /// two-thousand task chain spent seven seconds inside `contains`. The list
  /// stays because a ring has to be printed in the order it was entered.
  final _opened = <String>{};

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
    int depth = 0,
  }) {
    if (_done.contains(name)) {
      return;
    }
    final task = file.tasks[name];
    // **After the name is looked up, not before.** Asked first, a `needs:`
    // naming a task that does not exist was reported as a chain too deep —
    // with no line under it, because there is no such task to have a span —
    // instead of as the missing name it is. Depth is about how far this walk
    // has come; whether the next name exists is about the file.
    if (task != null && depth > mostDepth) {
      // **A number the table has, rather than a stack overflow.** This walk
      // is one frame per edge, so a `needs:` chain long enough overflowed the
      // stack and ended the process at 255 — from `--validate`, whose whole
      // job is to answer about a file rather than fall over on one.
      throw XtaskFormatException(
        'the chain reaching `$name` is more than $mostDepth tasks deep. That '
        'is deeper than a file anybody writes and deeper than this engine '
        'walks, so it is refused rather than run partway',
        task.span,
      );
    }

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

    if (_opened.contains(name)) {
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
    _opened.add(name);
    for (final need in task.needs) {
      // Inside the same continuation as whatever needed it: a task pulled in
      // by a continuation's own `needs:` is part of that continuation.
      resolve(
        need,
        from: task,
        continuationOf: continuationOf,
        depth: depth + 1,
      );
    }
    _opened.remove(_open.removeLast());

    // Emitted before the continuations, which is what makes `then:` a
    // continuation rather than a dependency: the body has happened by the time
    // anything in `then:` is reached.
    _done.add(name);
    steps.add(PlanStep(task, continuationOf: continuationOf));

    for (final next in task.then) {
      if (_opened.contains(next)) {
        // A task still being resolved further up will emit itself when its own
        // frame finishes. Skipping here keeps the run-once rule without
        // calling this a cycle: `a needs b`, `b then a` is an ordering both
        // keys agree on — b, then a — and refusing it would refuse a file that
        // says nothing contradictory.
        continue;
      }
      resolve(next, from: task, continuationOf: name, depth: depth + 1);
    }
  }
}
