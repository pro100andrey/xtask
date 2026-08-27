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
    all: build-outputs
    args: [$all]

  check:
    desc: reproduce CI locally
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
    });

    test(r'keeps `in: $each` as written, unsubstituted', () {
      expect(file.tasks['test']!.workingDirectory, r'$each');
      expect(file.tasks['test']!.each, 'test-packages');
    });

    test('reads env-required, needs, then, args, all, gate', () {
      expect(file.tasks['web-e2e']!.envRequired, ['CHROMEDRIVER']);
      expect(file.tasks['web-e2e']!.gate, ['ci-web']);
      expect(file.tasks['publish']!.needs, ['install']);
      expect(file.tasks['publish']!.then, ['scaffold-check']);
      expect(file.tasks['publish']!.args, ['--dry-run']);
      expect(file.tasks['clean']!.all, 'build-outputs');
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
    // §4.3 makes the run order of a gate set the order its tasks are
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

  group('§8: the scan of the raw text, before the parser', () {
    // It has to be before, and this is the only function that ever holds the
    // raw text: by the time an XtaskFile exists, package:yaml has expanded
    // every alias into a copy and there is nothing left to detect.
    test('an anchor is refused', () {
      final message = refusal(
        () => parseXtaskFile(
          'version: 1\ntasks:\n  base: &b {desc: shared}\n',
        ),
      );
      expect(message, contains('anchor'));
      expect(message, contains('line 3'));
    });

    test('an alias is refused', () {
      expect(
        refusal(
          () => parseXtaskFile(
            'version: 1\ntasks:\n  a: {desc: x}\n  third: *b\n',
          ),
        ),
        contains('alias'),
      );
    });

    test('without this, an alias silently copies a task body', () {
      // What the refusal protects. R2 says a task is read completely from its
      // own keys; an alias means the reader of `third:` has to leave it and go
      // find `&b`, which is the property R2 is written to protect.
      final expanded =
          loadYaml('base: &b {desc: shared}\nthird: *b\n') as YamlMap;
      expect((expanded['third'] as YamlMap)['desc'], 'shared');
    });

    test('a merge key is refused as itself, not as an unknown key', () {
      final message = refusal(
        () => parseXtaskFile(
          'version: 1\ntasks:\n  b:\n    <<: {desc: y}\n',
        ),
      );
      expect(message, contains('merge key'));
      // Before this it surfaced as "unknown key in task `b`: `<<`", which
      // sends the author looking for a typo.
      expect(message, isNot(contains('unknown')));
    });

    test('a glob is not an alias, and needs no quoting to survive', () {
      // The false positive a careless scan would produce. `&` and `*` are
      // YAML indicators only where a node begins.
      final file = parseXtaskFile(
        'version: 1\nsets:\n  s: [packages/*/coverage, a&b]\ntasks: {}\n',
      );
      expect((file.sets['s']! as ListSet).members, [
        'packages/*/coverage',
        'a&b',
      ]);
    });

    test('an ampersand inside a comment or a quoted string is left alone', () {
      final file = parseXtaskFile(
        'version: 1\n# a comment with & and * in it\n'
        "tasks:\n  a: {desc: 'literally &b and *b'}\n",
      );
      expect(file.tasks['a']!.desc, 'literally &b and *b');
    });

    test('a non-breaking space is named, at the character itself', () {
      final message = refusal(
        () => parseXtaskFile('version: 1\ntasks:\n\u00a0 a: {desc: x}\n'),
      );
      expect(message, contains('U+00A0'));
      expect(message, contains('not a space'));
      expect(message, contains('line 3'));
    });

    test('a stray byte-order mark is caught too', () {
      expect(
        refusal(() => parseXtaskFile('version: 1\n\ufefftasks: {}\n')),
        contains('U+FEFF'),
      );
    });
  });

  group('a refusal points at one line, not at a whole block', () {
    // `SourceSpan.message` reprints everything its span covers. Handing it a
    // container answers "which line?" with all of them — on §12's ninety-line
    // example, the most common first-time error printed the whole file back.
    int quotedLines(String message) => message
        .split('\n')
        .where((l) => RegExp(r'^\s*\d+ .').hasMatch(l))
        .length;

    test('a missing `version:` does not reprint the file', () {
      final long =
          'tasks:\n'
          '${List.generate(20, (i) => '  t$i: {desc: x}').join('\n')}\n';
      expect(quotedLines(refusal(() => parseXtaskFile(long))), 1);
    });

    test('a missing `desc:` points at the task, not at its body', () {
      final message = refusal(
        () => parseXtaskFile(
          'version: 1\ntasks:\n  first: {desc: fine}\n  broken:\n'
          '    run: [dart, analyze]\n    gate: [check]\n    needs: [first]\n',
        ),
      );
      expect(message, contains('line 4'));
      expect(quotedLines(message), 1);
    });

    test('a set that is not a list or a glob points at its name', () {
      expect(
        refusal(
          () => parseXtaskFile('version: 1\nsets:\n  s: 3\ntasks: {}\n'),
        ),
        contains('line 3'),
      );
    });
  });

  group('the model carries the position it was read from', () {
    // So that a refusal raised AFTER parsing — an empty set, a cycle, a
    // dangling name — can still name a line. Dropping the span at the parser
    // boundary is what makes every later message say "somewhere in the file".
    test('a task knows its own line', () {
      final file = parseXtaskFile(
        'version: 1\ntasks:\n  first: {desc: a}\n  second: {desc: b}\n',
      );
      expect(file.tasks['first']!.span!.start.line, 2);
      expect(file.tasks['second']!.span!.start.line, 3);
    });

    test('a set knows its own line', () {
      final file = parseXtaskFile(
        'version: 1\nsets:\n  pkgs: [a]\n  srcs:\n'
        "    include: ['**/*.lake']\ntasks: {}\n",
      );
      expect(file.sets['pkgs']!.span!.start.line, 2);
      expect(file.sets['srcs']!.span!.start.line, 3);
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
      expect(message, contains('gate'));
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

    test('a set is a list, a glob or values, and nothing else', () {
      expect(
        refusal(() => parseXtaskFile('version: 1\nsets:\n  s: 3\ntasks: {}\n')),
        contains('must be a list of paths, a mapping'),
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

  group('a value that parses and means nothing', () {
    // Each of these used to travel on as a RUNTIME problem: an empty verb name
    // reached the registry as "no such verb", an empty executable reached §5.4
    // as a missing tool — exit 3, "not installed" — when the defect was in the
    // file and §5.3 has a code for that.
    test('an empty `desc:` is refused', () {
      expect(
        refusal(
          () => parseXtaskFile('version: 1\ntasks:\n  a: {desc: ""}\n'),
        ),
        contains('is empty'),
      );
    });

    test('a `desc:` running to more than one line is refused', () {
      // §4.3 calls it one line, and `--list` prints it beside the task name.
      final message = refusal(
        () => parseXtaskFile(
          'version: 1\ntasks:\n  a:\n    desc: |\n      first\n      second\n',
        ),
      );
      expect(message, contains('more than one line'));
    });

    test('an empty `do:` is refused', () {
      expect(
        refusal(
          () => parseXtaskFile('version: 1\ntasks:\n  a: {desc: x, do: ""}\n'),
        ),
        contains('a verb name is empty'),
      );
    });

    test('an empty executable is refused', () {
      expect(
        refusal(
          () => parseXtaskFile(
            'version: 1\ntasks:\n  a: {desc: x, run: ["", analyze]}\n',
          ),
        ),
        contains('executable'),
      );
    });

    test('but an empty ARGUMENT is ordinary and is kept', () {
      // `dart test --name ''` is a real command. Refusing every empty string
      // in `run:` would forbid it, so only the first element is checked.
      final file = parseXtaskFile(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart, --name, ""]}\n',
      );
      expect((file.tasks['a']!.body! as RunBody).argv, ['dart', '--name', '']);
    });

    test('an empty name in `needs:` is refused', () {
      expect(
        refusal(
          () => parseXtaskFile(
            'version: 1\ntasks:\n  a: {desc: x, needs: [""]}\n',
          ),
        ),
        contains('is empty'),
      );
    });
  });

  group('two bodies are reported in the order the file wrote them', () {
    // The list used to come from `bodyKeys`, so the message named `run:` first
    // whatever the file said, while the caret pointed at whichever was written
    // second — a message and a pointer disagreeing about the same defect.
    test('`do:` before `run:` is reported in that order', () {
      final message = refusal(
        () => parseXtaskFile(
          'version: 1\ntasks:\n  a:\n    desc: x\n    do: regen\n'
          '    run: [dart]\n',
        ),
      );
      expect(message.indexOf('`do:`'), lessThan(message.indexOf('`run:`')));
      expect(message, contains('line 6'), reason: 'caret on the second one');
    });

    test('`run:` before `do:` is reported in that order', () {
      final message = refusal(
        () => parseXtaskFile(
          'version: 1\ntasks:\n  a:\n    desc: x\n    run: [dart]\n'
          '    do: regen\n',
        ),
      );
      expect(message.indexOf('`run:`'), lessThan(message.indexOf('`do:`')));
      expect(message, contains('line 6'));
    });
  });

  group('what the parser hands back cannot be quietly rearranged', () {
    // The `const []` defaults on Task throw on mutation while parsed
    // collections accepted it — one type behaving two ways depending on what
    // the file happened to say. And `tasks` is a map whose ORDER §4.3 calls
    // load-bearing, which does not go with anybody being able to reorder it.
    late final XtaskFile file;

    setUpAll(() {
      file = parseXtaskFile(
        'version: 1\nsets:\n  s: [a]\n'
        'tasks:\n  a: {desc: x, run: [dart], needs: [b], args: [--x],'
        " env: {K: '1'}, gate: [check]}\n  b: {desc: y}\n",
      );
    });

    test('the task map cannot be reordered', () {
      expect(() => file.tasks.remove('b'), throwsUnsupportedError);
      expect(() => file.tasks['c'] = file.tasks['a']!, throwsUnsupportedError);
    });

    test('the set map cannot be reordered', () {
      expect(() => file.sets.remove('s'), throwsUnsupportedError);
    });

    test('a parsed list behaves like the default it replaced', () {
      final task = file.tasks['a']!;
      expect(() => task.needs.add('c'), throwsUnsupportedError);
      expect(() => task.args.add('--y'), throwsUnsupportedError);
      expect(() => task.gate.add('ci'), throwsUnsupportedError);
      expect(() => task.env['J'] = '2', throwsUnsupportedError);
      expect(
        () => (task.body! as RunBody).argv.add('x'),
        throwsUnsupportedError,
      );
      // The default, for comparison: the same answer, which is the point.
      expect(() => file.tasks['b']!.needs.add('c'), throwsUnsupportedError);
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

  group('`gates:` is a list of names and nothing else', () {
    test('is read in the order written', () {
      final file = parseXtaskFile(
        'version: 1\ngates: [check, release, nightly]\n'
        'tasks:\n  a: {desc: x, run: [d]}\n',
      );
      expect(file.gates.keys, ['check', 'release', 'nightly']);
    });

    test('every name carries the line it was written on', () {
      final file = parseXtaskFile(
        'version: 1\ngates: [check]\ntasks:\n  a: {desc: x, run: [d]}\n',
      );
      expect(file.gates['check']?.start.line, 1);
    });

    test('a mapping is refused — a gate set has nothing to describe', () {
      expect(
        () => parseXtaskFile(
          'version: 1\ngates: {check: everything}\n'
          'tasks:\n  a: {desc: x, run: [d]}\n',
        ),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.message,
            'message',
            contains('is a list of names'),
          ),
        ),
      );
    });

    test('the same name twice is refused', () {
      expect(
        () => parseXtaskFile(
          'version: 1\ngates: [check, check]\n'
          'tasks:\n  a: {desc: x, run: [d]}\n',
        ),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.message,
            'message',
            contains('declared twice'),
          ),
        ),
      );
    });

    test('a name that is the empty string is refused', () {
      expect(
        () => parseXtaskFile(
          "version: 1\ngates: ['']\ntasks:\n  a: {desc: x, run: [d]}\n",
        ),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.message,
            'message',
            contains('no name'),
          ),
        ),
      );
    });

    test('an empty list is refused rather than read as none', () {
      expect(
        () => parseXtaskFile(
          'version: 1\ngates: []\ntasks:\n  a: {desc: x, run: [d]}\n',
        ),
        throwsA(isA<XtaskFormatException>()),
      );
    });
  });

  group('a task whose keys contradict each other', () {
    String refusalOf(String yaml) {
      try {
        parseXtaskFile(yaml);
      } on XtaskFormatException catch (e) {
        return e.message;
      }
      fail('expected a refusal, got none');
    }

    test('is refused with every contradiction at once', () {
      // **Three mistakes used to cost three rounds.** The first `throw` hid
      // the rest, so a person fixed one, reran, fixed the next, reran — the
      // loop `--validate` collects problems to avoid, reproduced one module
      // earlier. The rules answer with a list now, and the parser is the
      // policy that refuses on it.
      final message = refusalOf(
        'version: 1\n'
        'sets:\n  pkgs: [a, b]\n'
        'tasks:\n'
        r'  a: {desc: x, run: [dart, test, --files=$all],'
        ' all: pkgs, each: pkgs}\n',
      );
      // A marker buried in a larger word, a set that therefore reaches
      // nothing, `each:` beside `all:`, and an `each:` with no `$each`. Four
      // mistakes, one run.
      expect(message, contains('whole argument or nothing'));
      expect(message, contains(r'never writes `$all`'));
      expect(message, contains('both `each:` and `all:`'));
      expect(message, contains(r'never writes `$each`'));
    });

    test('and one contradiction still reads as one sentence', () {
      // A single mistake must not grow a paragraph break just because several
      // of them now can.
      final message = refusalOf(
        'version: 1\ntasks:\n'
        r'  a: {desc: x, run: [dart, test, $all]}'
        '\n',
      );
      expect(message, contains('has no `all:`'));
      expect(message, isNot(contains('\n')));
    });
  });

  group('`all:` and its marker have to agree', () {
    String refusalOf(String yaml) {
      try {
        parseXtaskFile(yaml);
      } on XtaskFormatException catch (e) {
        return e.message;
      }
      fail('expected a refusal, got none');
    }

    test('a set named and never used is refused', () {
      // It does not fail. It succeeds at the wrong thing: the task checks
      // whatever it would have checked with no arguments at all.
      expect(
        refusalOf(
          'version: 1\nsets:\n  s: [a]\n'
          'tasks:\n  a: {desc: x, all: s, run: [dart]}\n',
        ),
        contains('never writes'),
      );
    });

    test('a marker with no set is refused', () {
      expect(
        refusalOf(
          'version: 1\ntasks:\n'
          r'  a: {desc: x, run: [dart, $all]}'
          '\n',
        ),
        contains('no `all:`'),
      );
    });

    test('a marker inside a larger argument is refused', () {
      // `$all` stands for N arguments and there is nothing for N arguments to
      // mean inside one — splitting a string is a shell's job, and there is
      // no shell.
      expect(
        refusalOf(
          'version: 1\nsets:\n  s: [a]\n'
          'tasks:\n'
          r'  a: {desc: x, all: s, run: [dart, --files=$all]}'
          '\n',
        ),
        contains('whole argument'),
      );
    });

    test('the marker as the program is refused, not read as a program', () {
      // It counted as a marker while the resolver substituted only over the
      // arguments, so the set passed every check and reached nothing — and
      // the run then answered 3, blaming the machine for a missing tool.
      expect(
        refusalOf(
          'version: 1\nsets:\n  s: [a]\n'
          'tasks:\n'
          r'  a: {desc: x, all: s, run: [$all]}'
          '\n',
        ),
        contains('the first entry of `run:` is the program'),
      );
    });

    test('a longer name that merely starts with it is text', () {
      // `--allow=$allowlist` is a literal argument for a tool that does its
      // own expansion. Refusing it took every other task in the file down too.
      expect(
        () => parseXtaskFile(
          'version: 1\ntasks:\n'
          r'  a: {desc: x, run: [echo, --allow=$allowlist]}'
          '\n',
        ),
        returnsNormally,
      );
    });

    test('the marker written twice is refused', () {
      expect(
        refusalOf(
          'version: 1\nsets:\n  s: [a]\n'
          'tasks:\n'
          r'  a: {desc: x, all: s, run: [cp, $all, $all]}'
          '\n',
        ),
        contains('2 times'),
      );
    });

    test('a longer program name that merely starts with it is text', () {
      // The sibling check for `$each` was already delimited; this one used
      // `contains`, so a program called `$allowed-tool` was refused for a
      // substring.
      expect(
        () => parseXtaskFile(
          'version: 1\ntasks:\n'
          r'  a: {desc: x, run: ["$allowed-tool", hi]}'
          '\n',
        ),
        returnsNormally,
      );
    });

    test(r'`in: $all` is refused — a list is not one directory', () {
      // Neither refused nor substituted before, so the body ran in a
      // directory literally called `$all` and failed much later as "could not
      // be started".
      expect(
        refusalOf(
          'version: 1\nsets:\n  s: [a]\n'
          'tasks:\n'
          r'  a: {desc: x, all: s, in: $all, run: [dart, $all]}'
          '\n',
        ),
        contains('there is nothing for a list to be there'),
      );
    });

    test('`each:` and `all:` together are refused', () {
      // The combination that used to be legal and meant nothing anybody
      // wanted: every member of the `each:` set received the WHOLE `all:` set.
      expect(
        refusalOf(
          'version: 1\nsets:\n  s: [a]\n  p: [b]\n'
          'tasks:\n'
          r'  a: {desc: x, each: p, all: s, run: [dart, $all]}'
          '\n',
        ),
        contains('one or\nthe other'.replaceAll('\n', ' ')),
      );
    });
  });

  group(r'`$each` may end what it is written in, nothing may follow', () {
    String refused(String yaml) {
      try {
        parseXtaskFile(yaml);
      } on XtaskFormatException catch (e) {
        return e.message;
      }
      fail('expected a refusal, got none');
    }

    String withTask(String task) =>
        'version: 1\nsets:\n  s: [a]\ntasks:\n  a: {desc: x, $task}\n';

    test('a derived path is refused, and told where deriving belongs', () {
      // `packages/$each` composes a path AROUND a value. `$each.dart`
      // computes one FROM it, and a computation wants a modifier, and a
      // modifier wants a language.
      expect(
        refused(withTask(r'each: s, run: [gen, build/$each.dart]')),
        contains('nothing may follow it'),
      );
    });

    test('a prefix is fine, in `run:` and in `in:` alike', () {
      expect(
        () => parseXtaskFile(
          withTask(r'each: s, in: packages/$each, run: [d, --flavor=$each]'),
        ),
        returnsNormally,
      );
    });

    test('the marker twice in one argument is refused', () {
      // `endsWith` alone looked only at the last occurrence, so `$each/$each`
      // passed and the resolver — which substitutes the trailing one — left
      // the other in the argument as literal text.
      expect(
        refused(withTask(r'each: s, run: [echo, $each/$each]')),
        contains('nothing may follow it'),
      );
    });

    test('but once per argument, in several arguments, is fine', () {
      expect(
        () => parseXtaskFile(withTask(r'each: s, run: [cp, $each, bak/$each]')),
        returnsNormally,
      );
    });

    test('the marker as the program is refused', () {
      expect(
        refused(withTask(r'each: s, run: [$each]')),
        contains('the program'),
      );
    });

    test('a set named and never used is refused', () {
      expect(
        refused(withTask('each: s, run: [dart]')),
        contains('never writes'),
      );
    });

    test('a marker with no `each:` is refused', () {
      expect(
        refused(withTask(r'run: [dart, $each]')),
        contains('no `each:`'),
      );
    });

    test('a longer name that merely starts with it is text', () {
      expect(
        () => parseXtaskFile(withTask(r'run: [echo, $eachother]')),
        returnsNormally,
      );
    });

    test(r'`$each` in argv with `in: $each` is refused as provably wrong', () {
      // The member is a path from the root and `in:` moves into it, so the
      // two would be relative to different places. A composed `in:` says the
      // opposite — that the member is a name — and is legitimate.
      expect(
        refused(withTask(r'each: s, in: $each, run: [dart, $each]')),
        contains('relative to different places'),
      );
    });
  });

  group('`values:` says a set is not paths', () {
    test('and is read as its members', () {
      final file = parseXtaskFile(
        'version: 1\n'
        'sets:\n  flavours:\n    values: [dev, staging, prod]\n'
        'tasks:\n'
        r'  a: {desc: x, each: flavours, run: [b, --flavor=$each]}'
        '\n',
      );
      expect(
        (file.sets['flavours']! as ValueSet).values,
        ['dev', 'staging', 'prod'],
      );
    });

    test('`values:` beside `include:` is refused', () {
      expect(
        () => parseXtaskFile(
          'version: 1\n'
          'sets:\n  s:\n    values: [a]\n    include: [b]\n'
          'tasks:\n  a: {desc: x, run: [d]}\n',
        ),
        throwsA(isA<XtaskFormatException>()),
      );
    });
  });

  group('`interruptible:` is refused where it cannot be honoured', () {
    test(
      'a verb cannot be stopped from outside, so it may not claim to be',
      () {
        expect(
          () => parseXtaskFile(
            'version: 1\ntasks:\n'
            '  a: {desc: x, interruptible: true, do: remove}\n',
          ),
          throwsA(
            isA<XtaskFormatException>().having(
              (e) => e.message,
              'message',
              contains('a promise nothing keeps'),
            ),
          ),
        );
      },
    );
  });

  group('a boolean key is a boolean', () {
    test('and a set is not called a task when one is wrong', () {
      expect(
        () => parseXtaskFile(
          'version: 1\n'
          'sets:\n  s:\n    include: [a]\n    produced: yes\n'
          'tasks:\n'
          r'  a: {desc: x, all: s, run: [d, $all]}'
          '\n',
        ),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.message,
            'message',
            contains('of set `s`'),
          ),
        ),
      );
    });

    test('`serial: yes` is a string in YAML and is refused, not guessed', () {
      expect(
        () => parseXtaskFile(
          'version: 1\nsets:\n  s: [a]\ntasks:\n'
          r'  a: {desc: x, each: s, serial: yes, run: [d, $each]}'
          '\n',
        ),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.message,
            'message',
            contains('write `true` or `false`'),
          ),
        ),
      );
    });
  });

  group('`timeout:` is refused where it could not be honoured', () {
    test('a whole number of seconds is kept', () {
      final file = parseXtaskFile(
        'version: 1\ntasks:\n  a: {desc: x, timeout: 300, run: [dart]}\n',
      );
      expect(file.tasks['a']!.timeout, 300);
    });

    test('and its absence is no limit, not a default one', () {
      final file = parseXtaskFile(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n',
      );
      expect(file.tasks['a']!.timeout, isNull);
    });

    test('something that is not a number is refused', () {
      expect(
        () => parseXtaskFile(
          'version: 1\ntasks:\n  a: {desc: x, timeout: 5m, run: [dart]}\n',
        ),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.message,
            'message',
            contains('seconds'),
          ),
        ),
      );
    });

    test('and so is a length of time that is not one', () {
      // Zero would mean "kill it before it starts", which nobody means; a
      // negative is a typo.
      for (final value in [0, -1]) {
        expect(
          () => parseXtaskFile(
            'version: 1\ntasks:\n'
            '  a: {desc: x, timeout: $value, run: [dart]}\n',
          ),
          throwsA(isA<XtaskFormatException>()),
          reason: '`timeout: $value` was accepted',
        );
      }
    });

    test('a `do:` cannot carry one, and the message says why', () {
      // Dart cannot stop a running function from outside, so the limit would
      // pass while the verb carried on writing to the disk.
      expect(
        () => parseXtaskFile(
          'version: 1\ntasks:\n  a: {desc: x, timeout: 5, do: regen}\n',
        ),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('verb'), contains('inside the verb')),
          ),
        ),
      );
    });

    test('and neither can a task with no body to spend it', () {
      expect(
        () => parseXtaskFile(
          'version: 1\ntasks:\n  a: {desc: x, timeout: 5, needs: [b]}\n'
          '  b: {desc: y, run: [d]}\n',
        ),
        throwsA(isA<XtaskFormatException>()),
      );
    });
  });
}
