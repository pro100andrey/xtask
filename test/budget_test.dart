import 'dart:async';

import 'package:test/test.dart';
import 'package:xtask/src/budget.dart';

void main() {
  group('a place is given back exactly once', () {
    test('however many frames think they hold it', () async {
      // The whole reason the place is an object. It used to be a mutable flag
      // threaded three levels down — the task takes a place to start its
      // clock, the first member runs on it — with a guard at the bottom for
      // the case where nobody claimed it. Releasing twice has to be releasing
      // once, or the budget grows by a place nobody ever took.
      final slots = Slots(1);
      final first = await slots.take();
      first
        ..release()
        ..release();

      final second = await slots.take();
      var third = false;
      unawaited(slots.take().then((_) => third = true));
      await pumpEventQueue();
      expect(
        third,
        isFalse,
        reason: 'the budget grew by a release nobody made',
      );

      second.release();
      await pumpEventQueue();
      expect(third, isTrue);
    });

    test('and a place that was never used is still given back', () async {
      // A body that could not resolve never reaches a member, so nothing below
      // takes the place over. A few of those and the run stops for want of a
      // budget nobody is spending.
      final slots = Slots(1);
      final lease = await slots.take();
      expect(lease.held, isTrue);
      lease.release();
      expect(lease.held, isFalse);

      var again = false;
      unawaited(slots.take().then((_) => again = true));
      await pumpEventQueue();
      expect(again, isTrue);
    });
  });

  test('a freed place goes to whoever has waited longest', () async {
    // Handed straight on rather than released and re-taken: releasing first
    // would let a newcomer overtake whoever has been waiting longest, and the
    // plan's cheap-before-slow order survives only as the order things are
    // ASKED for.
    final slots = Slots(1);
    final held = await slots.take();
    final order = <int>[];

    unawaited(
      slots.take().then((place) {
        order.add(1);
        place.release();
      }),
    );
    await pumpEventQueue();
    unawaited(
      slots.take().then((place) {
        order.add(2);
        place.release();
      }),
    );
    await pumpEventQueue();

    held.release();
    await pumpEventQueue();
    expect(order, [1, 2]);
  });

  group('a token is held by one task at a time', () {
    test('and a pair is taken all or none', () {
      // Two tasks each holding half of the same pair is how a pair deadlocks,
      // and neither can hold half of one.
      final exclusive = Exclusive();
      expect(exclusive.tryHold(['db', 'browser']), isTrue);
      expect(exclusive.tryHold(['browser']), isFalse);
      exclusive.release(['db', 'browser']);
      expect(exclusive.tryHold(['browser']), isTrue);
    });

    test('so a refused hold leaves nothing behind it', () {
      final exclusive = Exclusive();
      expect(exclusive.tryHold(['db']), isTrue);
      expect(exclusive.tryHold(['browser', 'db']), isFalse);
      exclusive.release(['db']);
      expect(
        exclusive.tryHold(['browser']),
        isTrue,
        reason: 'the refused hold kept `browser` it never got `db` for',
      );
    });
  });

  test('giving up twice gives up once', () {
    // The `isCompleted` guard used to live at the call site, which is the only
    // thing standing between a second failure and a `StateError` that takes
    // the run with it.
    final givenUp = GivenUp();
    expect(givenUp.already, isFalse);
    givenUp
      ..now()
      ..now();
    expect(givenUp.already, isTrue);
    expect(givenUp.reached, completes);
  });
}
