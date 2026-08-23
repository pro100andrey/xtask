import 'package:test/test.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/model.dart';
import 'package:xtask/src/parse.dart';
import 'package:yaml/yaml.dart';

/// The message of the [XtaskFormatException] [body] throws.
String refusal(void Function() body) {
  try {
    body();
  } on XtaskFormatException catch (e) {
    return e.toString();
  }
  fail('expected a refusal, got none');
}

void main() {
  group('a file that fits the types', () {
    late final XtaskFile file;

    setUpAll(() {
      file = parseXtaskFile(r'''
version: 1

sets:
  test-packages: [packages/lake, packages/lake_cli]
  lake-sources:
    include: ['{templates,packages}/**/*.lake']
    exclude: ['**/test_data/**']

tasks:
  analyze:
    desc: analyze every package, infos fatal
    gate: [check, ci-analyze]
    run: [dart, analyze, --fatal-infos]

  test:
    desc: run every package's hermetic tests
    gate: [check, ci-test]
    each: test-packages
    in: $each
    run: [dart, test]

  web-e2e:
    desc: browser e2e for the web binding
    gate: [ci-web]
    env-required: [CHROMEDRIVER]
    in: packages/lake
    run: [dart, test, test/web/web_e2e_test.dart]

  goldens:
    desc: rewrite the committed goldens
    do: goldens
    env: {UPDATE_GOLDENS: '1'}

  publish:
    desc: publish, then prove a stranger could use it
    needs: [install]
    do: publish
    args: [--dry-run]
    then: [scaffold-check]

  clean:
    desc: drop build output
    do: remove
    argv-from: build-outputs

  check:
    desc: reproduce CI locally
    collects: check
''');
    });

    test('reads the version', () {
      expect(file.version, supportedVersion);
    });

    test('reads a list set', () {
      final set = file.sets['test-packages']! as ListSet;
      expect(set.members, ['packages/lake', 'packages/lake_cli']);
    });

    test('reads a glob set, exclusions and all', () {
      final set = file.sets['lake-sources']! as GlobSet;
      expect(set.include, ['{templates,packages}/**/*.lake']);
      expect(set.exclude, ['**/test_data/**']);
    });

    test('an argv body is argv, not a string to be split later', () {
      final body = file.tasks['analyze']!.body! as RunBody;
      expect(body.argv, ['dart', 'analyze', '--fatal-infos']);
    });

    test('a verb body names the verb', () {
      expect((file.tasks['goldens']!.body! as DoBody).verb, 'goldens');
    });

    test('a composite has no body at all', () {
      expect(file.tasks['check']!.body, isNull);
      expect(file.tasks['check']!.collects, 'check');
    });

    test(r'keeps `in: $each` as written, unsubstituted', () {
      expect(file.tasks['test']!.workingDirectory, r'$each');
      expect(file.tasks['test']!.each, 'test-packages');
    });

    test('reads env-required, needs, then, args, argv-from, gate', () {
      expect(file.tasks['web-e2e']!.envRequired, ['CHROMEDRIVER']);
      expect(file.tasks['web-e2e']!.gate, ['ci-web']);
      expect(file.tasks['publish']!.needs, ['install']);
      expect(file.tasks['publish']!.then, ['scaffold-check']);
      expect(file.tasks['publish']!.args, ['--dry-run']);
      expect(file.tasks['clean']!.argvFrom, 'build-outputs');
    });

    test('reads env as strings', () {
      expect(file.tasks['goldens']!.env, {'UPDATE_GOLDENS': '1'});
    });

    test('a task with neither needs nor a body still parses', () {
      // Whether a task that does nothing is COHERENT is `validate`'s question.
      // Parsing answers only whether it fitted the types, and it did.
      final f = parseXtaskFile('version: 1\ntasks:\n  idle:\n    desc: x\n');
      expect(f.tasks['idle']!.body, isNull);
      expect(f.tasks['idle']!.needs, isEmpty);
    });
  });

  group('declaration order', () {
    // §4.3 makes the run order of a `collects:` composite the order tasks are
    // written in, so that cheap gates come before slow ones. That rests on the
    // parser keeping a mapping's key order, which every YAML implementation
    // does and the YAML specification does not promise. These two tests are
    // the pin: if a parser swap ever loses the order, a gate quietly reorders
    // and nothing else in the suite would notice.
    test('tasks come back in the order written, not sorted', () {
      final file = parseXtaskFile('''
version: 1
tasks:
  zebra: {desc: written first and sorts last}
  middle: {desc: written second}
  alpha: {desc: written last and sorts first}
''');
      expect(file.tasks.keys, ['zebra', 'middle', 'alpha']);
    });

    test('sets come back in the order written', () {
      final file = parseXtaskFile('''
version: 1
sets:
  zebra: [a]
  alpha: [b]
tasks: {}
''');
      expect(file.sets.keys, ['zebra', 'alpha']);
    });

    test('the assumption itself holds in this yaml build', () {
      // Stated separately from the two above so that a failure says WHICH of
      // the two sentences broke: our code, or the library underneath it.
      final map = loadYamlNode('z: 1\nm: 2\na: 3\n') as YamlMap;
      expect(map.nodes.keys.map((k) => (k as YamlNode).value), ['z', 'm', 'a']);
    });
  });

  group('version', () {
    test('is required', () {
      expect(
        refusal(() => parseXtaskFile('tasks: {}\n')),
        contains('`version:` is required'),
      );
    });

    test('must be an integer', () {
      expect(
        refusal(() => parseXtaskFile('version: "1"\ntasks: {}\n')),
        contains('must be an integer'),
      );
    });

    test('an unknown one is refused, not read as best it can be', () {
      final message = refusal(() => parseXtaskFile('version: 2\ntasks: {}\n'));
      expect(message, contains('unknown `version: 2`'));
      expect(message, contains('reads version 1'));
    });

    test('is refused before any key is called unknown', () {
      // Order, not cosmetics. `variables:` may well be an ordinary key of
      // whatever version 2 turns out to be, so complaining about it first
      // would answer in the terms of a dialect nobody claimed to write.
      final message = refusal(
        () => parseXtaskFile('version: 2\nvariables: {}\n'),
      );
      expect(message, contains('unknown `version: 2`'));
      expect(message, isNot(contains('unknown top-level key')));
    });
  });

  group('unknown keys', () {
    test('at the top level', () {
      final message = refusal(
        () => parseXtaskFile('version: 1\nvariables: {}\n'),
      );
      expect(message, contains('unknown top-level key: `variables`'));
      expect(message, contains('sets, tasks, version'));
    });

    test('in a task, listing what would have been known', () {
      final message = refusal(
        () => parseXtaskFile('''
version: 1
tasks:
  a:
    desc: x
    gates: check
'''),
      );
      expect(message, contains('unknown key in task `a`: `gates`'));
      // The list is what tells somebody who wrote the old name where to go.
      expect(message, contains('collects'));
    });

    test('are reported at the line they were written on', () {
      final message = refusal(
        () => parseXtaskFile('''
version: 1
tasks:
  a:
    desc: x
    nonsense: y
'''),
      );
      expect(message, contains('line 5'));
    });
  });

  group('a task', () {
    test('must say what it is for', () {
      expect(
        refusal(() => parseXtaskFile('version: 1\ntasks:\n  a: {}\n')),
        contains('has no `desc:`'),
      );
    });

    test('may not declare two bodies', () {
      final message = refusal(
        () => parseXtaskFile('''
version: 1
tasks:
  a:
    desc: x
    run: [dart]
    do: regen
'''),
      );
      expect(message, contains('declares two bodies'));
      expect(message, contains('`run:`'));
      expect(message, contains('`do:`'));
    });

    test('may not have an empty `run:` — there is nothing to start', () {
      expect(
        refusal(
          () => parseXtaskFile('''
version: 1
tasks:
  a:
    desc: x
    run: []
'''),
        ),
        contains('is empty'),
      );
    });

    test('may not write a list where a string belongs', () {
      expect(
        refusal(
          () => parseXtaskFile('''
version: 1
tasks:
  a:
    desc: [not, one, line]
'''),
        ),
        contains('must be a string'),
      );
    });
  });

  group('env is text, and is not coerced into it', () {
    test('an unquoted number is refused rather than stringified', () {
      final message = refusal(
        () => parseXtaskFile('''
version: 1
tasks:
  a:
    desc: x
    env: {VERSION: 1.10}
'''),
      );
      expect(message, contains('not a string'));
      expect(message, contains('quote it'));
    });

    test('and this is why: YAML has already lost the digit', () {
      // The justification for refusing rather than calling toString(). By the
      // time any of our code sees it, `1.10` is the double 1.1 and the zero
      // the author typed is gone — a coerced value would read back "1.1" and
      // look deliberate.
      final map = loadYamlNode('VERSION: 1.10') as YamlMap;
      expect(map.nodes['VERSION']!.value, 1.1);
      expect(map.nodes['VERSION']!.value.toString(), '1.1');
    });

    test('a quoted one is kept exactly', () {
      final file = parseXtaskFile('''
version: 1
tasks:
  a:
    desc: x
    env: {VERSION: '1.10'}
''');
      expect(file.tasks['a']!.env['VERSION'], '1.10');
    });
  });

  group('sets', () {
    test('a glob set needs `include:`', () {
      expect(
        refusal(
          () => parseXtaskFile('''
version: 1
sets:
  s:
    exclude: ['**/x/**']
tasks: {}
'''),
        ),
        contains('needs `include:`'),
      );
    });

    test('a set is a list or a glob, and nothing else', () {
      expect(
        refusal(() => parseXtaskFile('version: 1\nsets:\n  s: 3\ntasks: {}\n')),
        contains('must be a list of members, or a mapping'),
      );
    });

    test('an unknown key in a glob set is refused', () {
      expect(
        refusal(
          () => parseXtaskFile('''
version: 1
sets:
  s:
    include: ['a']
    order: sorted
tasks: {}
'''),
        ),
        contains('unknown key in glob set `s`: `order`'),
      );
    });
  });

  group('the document itself', () {
    test('an empty file says so, rather than parsing to nothing', () {
      expect(refusal(() => parseXtaskFile('')), contains('the file is empty'));
    });

    test('a file that is not a mapping is refused', () {
      expect(
        refusal(() => parseXtaskFile('- a\n- b\n')),
        contains('the file must be a mapping'),
      );
    });

    test("malformed YAML keeps the parser's own complaint", () {
      expect(
        refusal(() => parseXtaskFile('version: 1\n  bad indent\n')),
        isNotEmpty,
      );
    });
  });
}
