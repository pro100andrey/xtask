/// What the tasks of one run share, which the plan cannot say.
///
/// Three facts, and none of them is an edge in the graph: how many units may
/// be in flight, which named things only one task may hold at a time, and
/// whether the run has already decided the answer.
library;

import 'dart:async';

/// One place from the run's budget.
///
/// Held by exactly one unit of work — the first member of a task takes the
/// place the walk took for it, every member after that takes its own — and
/// given back by that unit when it ends. Giving a place back twice is a bug
/// in whoever thought they held it, and is refused as one.
final class Lease {
  Lease._(this._slots);

  final Slots _slots;
  var _held = true;

  /// Gives the place back to the run.
  void release() {
    if (!_held) {
      throw StateError('a place was released twice');
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
/// without becoming plan steps.
///
/// First come, first served, so the plan's cheap-before-slow order survives as
/// the order things are ASKED for.
final class Slots {
  Slots(this.total);

  /// How many places there are — `-j`'s number.
  final int total;

  var _taken = 0;
  final _waiting = <Completer<Lease>>[];

  /// Whether a place could be taken right now, without waiting.
  bool get hasFree => _taken < total;

  /// A place, right now.
  ///
  /// For the walk's admission pass, which has to know synchronously whether
  /// a task can begin: a task admitted without a place would hold its
  /// `exclusive:` tokens while doing nothing. Asked only after [hasFree]
  /// said yes.
  Lease takeNow() {
    if (!hasFree) {
      throw StateError('no place is free');
    }
    _taken++;
    return Lease._(this);
  }

  /// A place, as soon as there is one.
  Future<Lease> take() {
    if (hasFree) {
      return Future.value(takeNow());
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
/// What the graph cannot say: two tasks with no `needs:` between them are
/// independent as far as the plan is concerned, and may still both bind
/// `:8080` or drive the one browser on the machine. The file names the thing
/// they share; this makes the name mean something.
final class Exclusive {
  final _held = <String>{};

  /// Takes every name in [tokens], or none of them, and says which.
  ///
  /// Synchronous, so the walk's admission pass can ask it: a task that cannot
  /// have its tokens is simply not admitted, and its place goes to something
  /// that can run.
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
/// Said once, at the moment of the first failure, and consulted everywhere a
/// unit of work is about to begin: by the walk before it admits a task, and
/// by a member the moment it has a place. A task that may be stopped waits on
/// [reached]; the code that decides whether a 130 was a stop or a program's
/// own exit asks [already].
final class GivenUp {
  final _completer = Completer<void>();

  /// Whether the run has already given up.
  bool get already => _completer.isCompleted;

  /// Completes once the run has decided the answer is known.
  ///
  /// Only tasks the file called `interruptible:` are given this.
  Future<void> get reached => _completer.future;

  /// Says the answer is known. Saying it twice says it once.
  void now() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}
