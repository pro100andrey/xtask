import 'dart:convert';

import 'package:test/test.dart';
import 'package:xtask/src/model.dart';
import 'package:xtask/src/schema.dart';

void main() {
  late Map<String, Object?> schema;

  setUpAll(() {
    schema = jsonDecode(xtaskJsonSchema()) as Map<String, Object?>;
  });

  Map<String, Object?> at(List<Object> path) {
    Object? node = schema;
    for (final step in path) {
      node = step is int
          ? (node! as List)[step]
          : (node! as Map<String, Object?>)[step];
    }
    return node! as Map<String, Object?>;
  }

  Map<String, Object?> task() =>
      at(['properties', 'tasks', 'additionalProperties']);

  group('it is a projection of the model, not a second copy of it', () {
    test("the task keys are the engine's, all of them and only them", () {
      expect(
        (task()['properties']! as Map<String, Object?>).keys.toSet(),
        taskKeys,
      );
    });

    test("and in the engine's order, so a reordering is not a diff", () {
      expect((task()['properties']! as Map<String, Object?>).keys, taskKeys);
    });

    test('the top-level keys likewise', () {
      expect(
        (schema['properties']! as Map<String, Object?>).keys.toSet(),
        topLevelKeys,
      );
    });

    test('and a glob set names the two keys the parser accepts', () {
      final glob = at(['properties', 'sets', 'additionalProperties'])['oneOf']!;
      final object = (glob as List)[1] as Map<String, Object?>;
      expect(
        (object['properties']! as Map<String, Object?>).keys.toSet(),
        globSetKeys,
      );
    });

    test('the version is the one this engine reads, spelled as a constant', () {
      expect(at(['properties', 'version'])['const'], supportedVersion);
    });

    test('and two bodies are refused, from the same list the parser uses', () {
      expect(task()['not'], containsPair('required', bodyKeys.toList()));
    });
  });

  group('and the projection refuses to drift', () {
    // The guard is the whole reason this file may describe keys at all. It is
    // reached only by a mistake that must never be committed, so it is code
    // that would otherwise run for the first time on the day it is needed.
    test('a key the engine has and the table has not stops everything', () {
      expect(
        () => checkedProperties({'a', 'b'}, {'a': {}}, 'task key'),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', contains('b')),
        ),
      );
    });

    test('and so does one the table has and the engine has not', () {
      expect(
        () => checkedProperties({'a'}, {'a': {}, 'b': {}}, 'task key'),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', contains('b')),
        ),
      );
    });

    test('the message names the kind of key, not just the name', () {
      expect(
        () => checkedProperties({'a'}, const {}, 'top-level key'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('top-level key'),
          ),
        ),
      );
    });

    test("and agreement passes through, in the engine's order", () {
      expect(
        checkedProperties({'b', 'a'}, {'a': {}, 'b': {}}, 'x').keys,
        ['b', 'a'],
      );
    });
  });

  group('it says the things an editor acts on', () {
    test('an unknown key is an error at every level', () {
      // Without this the whole point is lost: `dsec:` would be accepted as an
      // extra property and underlined by nothing.
      expect(schema['additionalProperties'], isFalse);
      expect(task()['additionalProperties'], isFalse);
    });

    test('a task must say what it is for', () {
      expect(task()['required'], ['desc']);
    });

    test('only `version:` is required of the file, as the parser has it', () {
      // A schema stricter than the engine underlines a file that runs. The
      // parser accepts a document with no `tasks:` and no `sets:`.
      expect(schema['required'], ['version']);
    });

    test('every key carries a sentence, because hover text is the point', () {
      final described = task()['properties']! as Map<String, Object?>;
      for (final key in taskKeys) {
        final property = described[key]! as Map<String, Object?>;
        expect(
          property['description'],
          isA<String>().having((d) => d.length, 'length', greaterThan(20)),
          reason: '`$key` has nothing to show on hover',
        );
      }
    });

    test('and it declares the draft the editors implement', () {
      expect(schema[r'$schema'], contains('draft-07'));
    });
  });

  group('the text is a file, not a fragment', () {
    test('it parses as JSON', () {
      expect(() => jsonDecode(xtaskJsonSchema()), returnsNormally);
    });

    test('it is indented, because a person reads the diff of it', () {
      expect(xtaskJsonSchema(), contains('\n  "title"'));
    });

    test('and it ends in exactly one newline', () {
      // `> xtask.schema.json` writes what it is given. A missing newline, or
      // two, is a diff every editor would then argue with.
      final text = xtaskJsonSchema();
      expect(text, endsWith('}\n'));
      expect(text, isNot(endsWith('\n\n')));
    });

    test('and it is the same text twice, so the gate compares equal', () {
      expect(xtaskJsonSchema(), xtaskJsonSchema());
    });
  });
}
