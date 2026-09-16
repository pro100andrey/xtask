import 'dart:async';

import 'package:test/test.dart';
import 'package:xtask/src/budget.dart';

void main() {
  group('a place is held by one unit and given back once', () {
    test('and giving it back twice is refused as the bug it is', () {
      final slots = Slots(1);
      final place = slots.takeNow()..release();
      expect(place.release, throwsStateError);
    });

    test('and a place taken now is a place the budget has', () {
      final slots = Slots(1);
      expect(slots.hasFree, isTrue);
      final place = slots.takeNow();
      expect(slots.hasFree, isFalse);
      expect(slots.takeNow, throwsStateError);
      place.release();
      expect(slots.hasFree, isTrue);
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
      // Two tasks each holding half of the same pair is how a pair deadlocks.
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
    final givenUp = GivenUp();
    expect(givenUp.already, isFalse);
    givenUp
      ..now()
      ..now();
    expect(givenUp.already, isTrue);
    expect(givenUp.reached, completes);
  });
}
