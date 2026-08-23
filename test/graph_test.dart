import 'package:test/test.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/parse.dart';

/// Parses a document whose tasks are written as `name: needs -> then`.
///
/// Written this way because every case below is about ORDER, and a page of
/// YAML per case buries the one line that differs.
Plan planOf(String taskName, Map<String, String> tasks) {
  final buffer = StringBuffer('version: 1\ntasks:\n');
  tasks.forEach((name, spec) {
    final parts = spec.split('->');
    final needs = parts[0].trim();
    final then = parts.length > 1 ? parts[1].trim() : '';
    buffer
      ..writeln('  $name:')
      ..writeln('    desc: $name');
    if (needs.isNotEmpty) {
      buffer.writeln('    needs: [$needs]');
    }
    if (then.isNotEmpty) {
      buffer.writeln('    then: [$then]');
    }
  });
  return planRun(parseXtaskFile(buffer.toString()), taskName);
}

String refusalOf(void Function() body) {
  try {
    body();
  } on XtaskFormatException catch (e) {
    return e.toString();
  }
  fail('expected a refusal, got none');
}

void main() {
  group('order', () {
    test('a task with nothing around it is the whole plan', () {
      expect(planOf('a', {'a': ''}).names, ['a']);
    });

    test('needs come first', () {
      expect(planOf('a', {'a': 'b', 'b': ''}).names, ['b', 'a']);
    });

    test('needs are taken in declared order, not alphabetical', () {
      final plan = planOf('a', {'a': 'z, m', 'z': '', 'm': ''});
      expect(plan.names, ['z', 'm', 'a']);
    });

    test('and depth-first, so a need of a need lands before both', () {
      final plan = planOf('a', {'a': 'b', 'b': 'c', 'c': ''});
      expect(plan.names, ['c', 'b', 'a']);
    });

    test('`then` comes after the body', () {
      expect(planOf('a', {'a': ' -> b', 'b': ''}).names, ['a', 'b']);
    });

    test('`then` entries are taken in declared order', () {
      final plan = planOf('a', {'a': ' -> z, m', 'z': '', 'm': ''});
      expect(plan.names, ['a', 'z', 'm']);
    });

    test(
      'a continuation brings its own needs with it, still after the body',
      () {
        final plan = planOf('a', {'a': ' -> b', 'b': 'c', 'c': ''});
        expect(plan.names, ['a', 'c', 'b']);
      },
    );

    test('needs, then body, then continuations — all three at once', () {
      final plan = planOf('a', {'a': 'n -> t', 'n': '', 't': ''});
      expect(plan.names, ['n', 'a', 't']);
    });
  });

  group('a task runs at most once, however many tasks want it', () {
    test('a shared need is not repeated', () {
      final plan = planOf('a', {
        'a': 'b, c',
        'b': 'shared',
        'c': 'shared',
        'shared': '',
      });
      expect(plan.names, ['shared', 'b', 'c', 'a']);
    });

    test('and it keeps the earliest position, not the last', () {
      // The one that matters: `install` shared by four tasks runs before the
      // first of them, not before the last.
      final plan = planOf('a', {
        'a': 'b, c',
        'b': 'install',
        'c': 'install',
        'install': '',
      });
      expect(plan.names.where((n) => n == 'install').length, 1);
      expect(plan.names.first, 'install');
    });

    test('a task named by both `needs` and `then` appears once', () {
      final plan = planOf('a', {'a': 'b -> b', 'b': ''});
      expect(plan.names, ['b', 'a']);
    });
  });

  group('a cycle is refused, and the refusal shows the cycle', () {
    test('two tasks needing each other', () {
      final message = refusalOf(() => planOf('a', {'a': 'b', 'b': 'a'}));
      expect(message, contains('a → b → a'));
      expect(message, contains('none of them can go first'));
    });

    test('a longer ring is spelled out in full', () {
      final message = refusalOf(
        () => planOf('a', {'a': 'b', 'b': 'c', 'c': 'a'}),
      );
      expect(message, contains('a → b → c → a'));
    });

    test('a task needing itself', () {
      expect(refusalOf(() => planOf('a', {'a': 'a'})), contains('a → a'));
    });

    test('the ring is named from where it closes, not from the root', () {
      // Entering at `a`, the cycle is b→c→b; printing a→b→c→b would name a
      // task that is not in it.
      final message = refusalOf(
        () => planOf('a', {'a': 'b', 'b': 'c', 'c': 'b'}),
      );
      expect(message, contains('b → c → b'));
      expect(message, isNot(contains('a → b → c → b')));
    });

    test('the refusal carries the line, not just the names', () {
      expect(
        refusalOf(() => planOf('a', {'a': 'b', 'b': 'a'})),
        contains('line'),
      );
    });
  });

  group('`then` pointing back is an order, not a contradiction', () {
    test('`a needs b`, `b then a` resolves to b, a', () {
      // Both keys agree: b before a. Treating it as a cycle would refuse a
      // file that says nothing contradictory — and the run-once rule already
      // stops it looping, because `a` emits itself when its own frame ends.
      final plan = planOf('a', {'a': 'b', 'b': ' -> a'});
      expect(plan.names, ['b', 'a']);
    });

    test('two tasks continuing into each other still terminate', () {
      final plan = planOf('a', {'a': ' -> b', 'b': ' -> a'});
      expect(plan.names, ['a', 'b']);
    });
  });

  group('a name that does not exist', () {
    test('asked for on the command line', () {
      expect(
        refusalOf(() => planOf('nope', {'a': ''})),
        contains('there is no task called `nope`'),
      );
    });

    test('named by `needs`, blamed on the task that named it', () {
      final message = refusalOf(() => planOf('a', {'a': 'ghost'}));
      expect(message, contains('task `a` names `ghost`'));
      expect(message, contains('line'));
    });

    test('named by `then`, blamed the same way', () {
      final message = refusalOf(() => planOf('a', {'a': ' -> ghost'}));
      expect(message, contains('task `a` names `ghost`'));
    });
  });

  group('what came through a continuation is marked as one', () {
    // §5.3 gives that case exit code 4 rather than 1, so the plan has to say
    // which steps are inside a continuation — otherwise the executor cannot
    // tell "the publish failed" from "the publish happened and the check
    // after it is red", and those are opposite reports.
    test('the body is not a continuation, what follows it is', () {
      final plan = planOf('a', {'a': ' -> b', 'b': ''});
      expect(plan.steps.map((s) => s.isContinuation), [false, true]);
    });

    test("a continuation's own needs are inside the continuation", () {
      final plan = planOf('a', {'a': ' -> b', 'b': 'c', 'c': ''});
      expect(plan.names, ['a', 'c', 'b']);
      expect(plan.steps.map((s) => s.isContinuation), [false, true, true]);
    });

    test('a plain need is not marked, even when a continuation exists', () {
      final plan = planOf('a', {'a': 'n -> t', 'n': '', 't': ''});
      expect(plan.steps.map((s) => s.isContinuation), [false, false, true]);
    });
  });

  group('the exit codes §5.3 defines', () {
    test('are five, and distinct', () {
      final codes = {
        ExitCode.success,
        ExitCode.taskFailed,
        ExitCode.invalidFile,
        ExitCode.missingTool,
        ExitCode.continuationFailed,
      };
      expect(codes, hasLength(5));
      expect(codes, containsAll([0, 1, 2, 3, 4]));
    });

    test('a failed continuation is not a failed task', () {
      // The distinction the whole key exists for. Written as an assertion so
      // that anyone tempted to simplify the two into one has to delete a test
      // that says why.
      expect(
        ExitCode.continuationFailed,
        isNot(ExitCode.taskFailed),
        reason: ExitCode.continuationNotice,
      );
    });
  });
}
