/// The members of one task, run under the run's budget.
///
/// **One subject that used to be four frames of the executor.** How much of
/// `-j` a fanned-out task may spend, whether its members' output has to be
/// collected, which member's failure the run answers with, what the other
/// members did afterwards, and how much work there was altogether — all of it
/// is about the members of one task, and none of it is about the plan.
///
/// It is also where the question "is more than one thing writing at once" was
/// answered a second and a third time, in expressions that had to be kept in
/// step by hand. [Fanout.couldOverlap] is that question, asked once; the run
/// asks it of a task before the set is read, and this asks it again with the
/// member count in hand.
library;

import 'dart:async';

import 'bodies.dart';
import 'body_runner.dart';
import 'budget.dart';
import 'errors.dart';
import 'model.dart';

/// What a fan-out came to.
///
/// **A value rather than a throw, because two things come back.** The members
/// account for how much work there was even when one of them failed, and a
/// throw loses everything the frame was about to return: that accounting used
/// to be written from four frames down into a map the executor owned, for
/// exactly this reason. Here the caller is handed both and decides what to do
/// with each.
final class FanoutOutcome {
  const FanoutOutcome({required this.work, required this.failure});

  /// How much work the members added up to, or null where there was one
  /// member and the row would only repeat the task's own.
  final ({Duration spent, int members})? work;

  /// What to raise, or null when every member passed.
  ///
  /// §8's code 2 — the file being wrong — outranks a task that failed, so
  /// where both happened this is the [XtaskFormatException]. Decided here,
  /// which is the one place both are in hand.
  /// Typed as [Exception] and not as [Object] on purpose: both of the things
  /// that can land here are one, and a field the caller has to `throw` is a
  /// field whose type should say it may be thrown.
  final Exception? failure;
}

/// Running the bodies one task resolved to.
final class Fanout {
  const Fanout({
    required this.runner,
    required this.slots,
    required this.log,
    required this.now,
    this.keepGoing = false,
  });

  /// What one body comes to.
  final BodyRunner runner;

  /// The run's budget. A member holds a place, which is what makes `-j` mean
  /// anything on the shape it exists for.
  final Slots slots;

  /// Where lines go when nothing is collecting them.
  final void Function(String line) log;

  /// Where the clock comes from — injected, so a summary can be asserted.
  final DateTime Function() now;

  /// Whether a failed member stops the rest.
  final bool keepGoing;

  /// Whether [task] could have two members in flight at [concurrency].
  ///
  /// **Asked before the set is read, which is why it names a key and not a
  /// count.** A set is expanded when its task is about to run, so the
  /// announcement — which has to come first, or it explains a silence that has
  /// already happened — cannot know how many members there will be. `each:`
  /// without `serial:` is the shape that can fan out, and that is readable
  /// from the file with no filesystem anywhere near it.
  ///
  /// This is the whole of the question. It used to be spelled once for the
  /// announcement, once for whether a task's output is collected, and once for
  /// whether its members run together — three expressions over one fact, which
  /// every change to `-j` had to keep in step by hand, and which `serial:`
  /// duly caught out.
  static bool couldOverlap(Task task, int concurrency) =>
      concurrency > 1 && task.each != null && !task.serial;

  /// Runs every body of [task], and answers with what that came to.
  ///
  /// [lease] is the place the caller already holds. **The first member runs on
  /// it** and gives it back when it ends, so the task never occupies a place
  /// for longer than a member takes — holding one for the task's whole life is
  /// what made two two-member tasks at `-j 2` deadlock. Every member after the
  /// first takes a place of its own.
  ///
  /// Which member inherits is decided here and synchronously, before any of
  /// them starts: they are all begun in one turn, so asking each of them
  /// whether the place is still free would tell two of them yes.
  Future<FanoutOutcome> run(
    Task task,
    List<Resolved> bodies, {
    required Lease lease,
    void Function(String line)? sink,
  }) async {
    // **`--keep-going` reaches members, and members that did not run are
    // said out loud.** Neither was true: the first bad file abandoned the rest
    // silently, so `format` over forty packages reported one unformatted file
    // per run and a person fixed, reran, fixed, reran — the exact loop
    // `--keep-going` exists to end. And a member that never ran read exactly
    // like one that passed, which is the failure this whole tool is about.
    //
    // Keyed by index, so which failure the run answers with does not depend
    // on which member happened to finish first. `first` used to mean
    // first-by-completion the moment members ran together, and a `do:` verb's
    // code is a deliberate decision — two members answering 2 and 1 made the
    // same command line answer differently run to run.
    final failures = <int, RunFailure>{};
    var attempted = 0;
    var stop = false;
    XtaskFormatException? malformed;
    ({Duration spent, int members})? work;

    // Buffering is the price of two things writing at once, and it is paid
    // only then: one member in flight keeps §5.2's live output exactly.
    final together = couldOverlap(task, slots.total) && bodies.length > 1;

    Lease? inherited = lease;

    Future<void> member(int at) async {
      if (stop) {
        return;
      }
      // Read and cleared before the first `await`, which is what makes it
      // safe: every member below is begun in the same turn.
      final mine = inherited;
      inherited = null;
      final place = mine ?? await slots.take();
      if (stop) {
        place.release();
        return;
      }
      final lines = together ? <String>[] : null;
      attempted++;
      // Read only where it is used. `now()` is injected so a summary can be
      // asserted, and a fake clock that advances on every read makes an
      // unused one a number somewhere else.
      final began = bodies.length > 1 ? now() : null;
      try {
        if (await runner.run(bodies[at], lines == null ? sink : lines.add)) {
          // **Stopped, so stop.** Returning normally left the loop with no
          // failure to act on, so every remaining member was started and
          // immediately killed — the opposite of what `interruptible:` is for,
          // which is the first answer at the first answer's price.
          stop = true;
        }
      } on Object catch (thrown) {
        if (thrown is XtaskFormatException) {
          // **Kept, not raised from inside the wait.** `Future.wait`
          // propagates the moment one member throws, so raising here abandoned
          // the tally its siblings had already filled in — the "N of M failed"
          // line `--keep-going` exists to produce. Stopped as well, since the
          // file being wrong is not a thing more members can fix.
          stop = true;
          malformed ??= thrown;
          return;
        }
        // **Anything, not only a `RunFailure`.** A verb is arbitrary project
        // Dart and can throw whatever it likes; catching one type meant a
        // `StateError` from member 2 left through the loop and discarded what
        // member 1 had already told us and the fact that member 3 never ran —
        // the silence this whole change was written to end.
        failures[at] = thrown is RunFailure ? thrown : bodyThrew(task, thrown);
        if (!keepGoing) {
          stop = true;
        }
      } finally {
        place.release();
        if (began != null) {
          work = (
            spent: (work?.spent ?? Duration.zero) + now().difference(began),
            members: (work?.members ?? 0) + 1,
          );
        }
        lines?.forEach(sink ?? log);
      }
    }

    if (together) {
      await Future.wait([
        for (var at = 0; at < bodies.length; at++) member(at),
      ]);
    } else {
      for (var at = 0; at < bodies.length; at++) {
        await member(at);
      }
    }

    return FanoutOutcome(
      work: work,
      // §8's code 2 is the file being wrong, which outranks a task that
      // failed, and `cli.dart` is where that sentence is written.
      failure: malformed ?? _tally(task, bodies, failures, attempted),
    );
  }

  /// The one failure the run answers with, carrying what happened to the rest.
  ///
  /// Says nothing about the others when there is one member: "1 of 1 members
  /// failed" is noise around a sentence that was already complete.
  RunFailure? _tally(
    Task task,
    List<Resolved> bodies,
    Map<int, RunFailure> failures,
    int attempted,
  ) {
    if (failures.isEmpty) {
      return null;
    }
    final order = failures.keys.toList()..sort();
    final failed = [for (final at in order) bodies[at].member ?? task.name];
    // **The EARLIEST failing member's code**, by the set's order rather than
    // by which finished first: a run with three failures cannot honestly claim
    // to be about all of them, and an answer that depends on scheduling is not
    // an answer.
    final failure = failures[order.first]!;
    final members = bodies.length;
    if (members == 1) {
      return failure;
    }
    final named = failed.take(5).map((member) => '`$member`').join(', ');
    final more = failed.length > 5 ? ' and ${failed.length - 5} more' : '';
    // Built here rather than inside the list: two string parts side by side in
    // a list literal read as a missing comma, and the lint that says so is
    // right about every other case.
    final unattempted =
        '${members - attempted} of $members not attempted — '
        '`--keep-going` runs them all';
    return RunFailure(
      failure.code,
      [
        failure.message,
        if (failed.length > 1)
          '${failed.length} of $members members failed: $named$more',
        if (attempted < members) unattempted,
      ].join('\n'),
    );
  }
}
