import 'dart:async';

import 'package:test/test.dart';
import 'package:xtask/src/bodies.dart';
import 'package:xtask/src/body_runner.dart';
import 'package:xtask/src/budget.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/executables.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/fanout.dart';
import 'package:xtask/src/model.dart';

/// A starter nothing here reaches: every body below is a verb.
final class _NoStarter implements ProcessStarter {
  @override
  Future<int> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
    Duration? timeout,
    Future<void>? until,
    void Function(String line)? output,
  }) async => throw StateError('no process is started here');
}

/// A clock that advances by 100ms every time it is read, so a member's share
/// of the work is a number a test can assert.
DateTime Function() ticking() {
  var at = DateTime.utc(2026);
  return () {
    final was = at;
    at = at.add(const Duration(milliseconds: 100));
    return was;
  };
}

void main() {
  Task fannedOut({String? each = 'pkgs', bool serial = false}) =>
      Task(name: 'fmt', desc: 'x', each: each, serial: serial);

  ResolvedVerb memberOf(
    Task task,
    String name,
    Future<int> Function() answer,
  ) => ResolvedVerb(
    task: task,
    member: name,
    workingDirectory: '/',
    environment: const {},
    declaredEnvironment: const {},
    arguments: const [],
    verb: 'v',
    implementation: (_) => answer(),
  );

  Fanout fanoutOn(Slots slots, {bool keepGoing = false}) => Fanout(
    runner: BodyRunner(
      bodies: BodyResolver(
        root: '/',
        resolver: ExecutableResolver(
          environment: const {},
          windows: false,
          isRunnable: (_) => false,
        ),
      ),
      starter: _NoStarter(),
      log: (_) {},
      givenUp: GivenUp(),
    ),
    slots: slots,
    log: (_) {},
    now: ticking(),
    keepGoing: keepGoing,
  );

  group('whether a task can fan out is one question, asked once', () {
    // It used to be three expressions over one fact — the announcement,
    // whether a task's output is collected, and whether its members run
    // together — which every change to `-j` had to keep in step by hand, and
    // which `serial:` duly caught out.
    test('at one job nothing can overlap', () {
      expect(Fanout.couldOverlap(fannedOut(), 1), isFalse);
    });

    test('without `each:` there is one body and nothing to overlap with', () {
      expect(Fanout.couldOverlap(fannedOut(each: null), 4), isFalse);
    });

    test('`serial:` is the file saying these members may not', () {
      expect(Fanout.couldOverlap(fannedOut(serial: true), 4), isFalse);
    });

    test('`exclusive:` says the task holds something alone', () {
      // A token is taken once, when the walk admits the task, so members
      // running together drive the one browser four at a time — the failure
      // the key's own doc comment describes. Holding a token makes a task
      // serial in its members, which is what the key promises.
      const holds = Task(
        name: 'e2e',
        desc: 'x',
        each: 'pkgs',
        exclusive: ['browser'],
      );
      expect(Fanout.couldOverlap(holds, 4), isFalse);
    });

    test('and otherwise they can', () {
      expect(Fanout.couldOverlap(fannedOut(), 4), isTrue);
    });
  });

  group('what a fan-out answers with', () {
    test('the work is accounted even when a member failed', () async {
      // **A value rather than a throw, and this is why.** The accounting used
      // to be written from inside a member into a map the executor owned,
      // because a throw loses what the frame was about to return — and where
      // the run spent itself before it broke is most of what somebody wants
      // from a red job.
      final task = fannedOut();
      final slots = Slots(1);
      final outcome = await fanoutOn(slots, keepGoing: true).run(
        task,
        [
          for (final name in ['a', 'b', 'c'])
            memberOf(task, name, () async => ExitCode.taskFailed),
        ],
        lease: await slots.take(),
      );

      expect(outcome.failure, isA<RunFailure>());
      expect(outcome.work?.members, 3);
      expect(
        (outcome.failure! as RunFailure).message,
        contains('3 of 3 members failed'),
      );
    });

    test('and a member that never ran is said out loud', () async {
      // A member that never ran reads exactly like one that passed, which is
      // the failure this whole tool is about.
      final task = fannedOut();
      final slots = Slots(1);
      final outcome = await fanoutOn(slots).run(
        task,
        [
          memberOf(task, 'a', () async => ExitCode.taskFailed),
          for (final name in ['b', 'c'])
            memberOf(task, name, () async => ExitCode.success),
        ],
        lease: await slots.take(),
      );

      expect(outcome.work?.members, 1, reason: 'only one member was attempted');
      expect(
        (outcome.failure! as RunFailure).message,
        contains('2 of 3 not attempted'),
      );
    });

    test('and nothing at all when every member passed', () async {
      final task = fannedOut();
      final slots = Slots(1);
      final outcome = await fanoutOn(slots).run(
        task,
        [
          for (final name in ['a', 'b'])
            memberOf(task, name, () async => ExitCode.success),
        ],
        lease: await slots.take(),
      );
      expect(outcome.failure, isNull);
      expect(outcome.work?.members, 2);
    });
  });

  test(
    'every place it took comes back, the one it was given included',
    () async {
      // The leak the flag was guarding: the task's place goes to the first
      // member, the rest take their own, and all of them are given back. A few
      // that are not and the run stops for want of a budget nobody is spending.
      final task = fannedOut();
      final slots = Slots(2);
      final lease = await slots.take();

      await fanoutOn(slots).run(
        task,
        [
          for (final name in ['a', 'b', 'c'])
            memberOf(task, name, () async => ExitCode.success),
        ],
        lease: lease,
      );

      expect(
        lease.held,
        isFalse,
        reason: 'the first member never took it over',
      );
      var free = 0;
      for (var at = 0; at < 2; at++) {
        unawaited(slots.take().then((_) => free++));
      }
      await pumpEventQueue();
      expect(free, 2, reason: 'a place leaked');
    },
  );
}
