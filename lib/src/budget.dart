/// What the tasks of one run share, which the plan cannot say.
///
/// Three facts, and none of them is an edge in the graph: how many units may
/// be in flight, which named things only one task may hold at a time, and
/// whether the run has already decided the answer. They lived inside the
/// executor while the executor was the only thing that walked, and a fan-out
/// that spends the budget by member needs the first of them as much as the
/// walk does.
library;

import 'dart:async';

/// One place from the run's budget.
///
/// Given back exactly once, however many frames think they hold it. The place
/// a task takes to start its clock is the place its first member runs on, so
/// two frames share one — and a place that leaks stops the run for want of a
/// budget nobody is spending. Releasing twice releases once, so neither frame
/// has to know whether the other got there first.
final class Lease {
  Lease._(this._slots);

  final Slots _slots;
  var _held = true;

  /// Whether this place has not been given back yet.
  bool get held => _held;

  /// Gives the place back to the run.
  void release() {
    if (!_held) {
      return;
    }
    _held = false;
    _slots._give();
  }
}

/// The concurrency budget, held by whatever is actually running.
///
/// A unit occupies a place, not a task: gating which TASKS are admitted makes
/// `-j 4` over one fanned-out task run its forty members one after another.
/// Counting units lets a task's members share the budget with other tasks
/// without becoming plan steps — a plan step is what `needs:`, `then:` and a
/// `::group::` are about, and a member is none of those.
///
/// First come, first served, so the plan's cheap-before-slow order survives as
/// the order things are ASKED for.
final class Slots {
  Slots(this.total);

  /// How many places there are — `-j`'s number.
  final int total;

  var _taken = 0;
  final _waiting = <Completer<Lease>>[];

  /// A place, as soon as there is one.
  Future<Lease> take() {
    if (_taken < total) {
      _taken++;
      return Future.value(Lease._(this));
    }
    final wait = Completer<Lease>();
    _waiting.add(wait);
    return wait.future;
  }

  void _give() {
    if (_waiting.isEmpty) {
      _taken--;
      return;
    }
    // Handed straight on rather than released and re-taken: releasing first
    // would let a newcomer overtake whoever has been waiting longest.
    _waiting.removeAt(0).complete(Lease._(this));
  }
}

/// Named mutexes, one holder each, for as long as a task runs.
///
/// **What the graph cannot say.** Two tasks with no `needs:` between them are
/// independent as far as the plan is concerned, and may still both bind
/// `:8080` or drive the one browser on the machine. The file names the thing
/// they share; this makes the name mean something.
final class Exclusive {
  final _held = <String>{};

  /// Takes every name in [tokens], or none of them, and says which.
  ///
  /// Synchronous, so the walk's admission pass can ask it: a task that cannot
  /// have its tokens is simply not admitted, and its place goes to something
  /// that can run. An awaiting acquire inside the task's own future would let
  /// three tasks sharing a browser all be admitted and two of them block.
  ///
  /// All or nothing, which settles the ordering question too: two tasks each
  /// holding half of the same pair is how a pair deadlocks.
  bool tryHold(List<String> tokens) {
    if (tokens.any(_held.contains)) {
      return false;
    }
    _held.addAll(tokens);
    return true;
  }

  /// Lets go of everything [tryHold] took.
  void release(List<String> tokens) => _held.removeAll(tokens);
}

/// Whether the run has decided the answer is known.
///
/// **A value rather than a raw `Completer`, because two things ask different
/// questions of it.** A task that may be stopped waits on [reached]; the code
/// that decides whether a 130 was a stop or a program's own exit asks
/// [already]. Both used to be spelled against the completer directly, with an
/// `isCompleted` guard at the one call site that completes it — a guard that
/// is the only thing standing between a second failure and a `StateError`.
/// [now] is idempotent, so there is nothing left to guard.
final class GivenUp {
  final _completer = Completer<void>();

  /// Whether the run has already given up.
  bool get already => _completer.isCompleted;

  /// Completes once the run has decided the answer is known.
  ///
  /// Only tasks the file called `interruptible:` are given this, and only when
  /// the run is not keeping going: with `--keep-going` nothing is stopped at
  /// all, which is the whole of what that flag says.
  Future<void> get reached => _completer.future;

  /// Says the answer is known. Saying it twice says it once.
  void now() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}
