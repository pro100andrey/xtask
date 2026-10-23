import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/bodies.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/dry_run.dart';
import 'package:xtask/src/exec.dart';
import 'package:xtask/src/executables.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/model.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/sets.dart';
import 'package:xtask/src/validate.dart';

import 'helpers.dart';

/// Every body here is a verb, so nothing needs starting; a run that tried
/// to would be a test about the wrong thing.
final class _NoProcesses implements ProcessStarter {
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
  }) => throw StateError('nothing here starts a process');

  @override
  Future<Captured> capture(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
    Duration? timeout,
    Future<void>? until,
    void Function(String line)? echo,
  }) => throw StateError('nothing here starts a process');
}

void main() {
  late Directory root;
  late List<String> logged;

  setUp(() {
    root = tempRepo('unchanged');
    logged = [];
  });

  File at(String path) =>
      File(p.join(root.path, p.joinAll(p.posix.split(path))));

  void write(String path, String text) => at(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  /// A verb that writes [files] and answers success: a generator, which is
  /// what a task holding a set unchanged is usually running.
  Verb writing(Map<String, String> files) => (context) async {
    files.forEach(write);
    return ExitCode.success;
  };

  Verb deleting(String path) => (context) async {
    at(path).deleteSync();
    return ExitCode.success;
  };

  BodyResolver bodiesFor(XtaskFile file, Map<String, Verb> verbs) =>
      BodyResolver(
        root: root.path,
        resolver: ExecutableResolver(
          environment: const {'PATH': '/bin'},
          windows: false,
          isRunnable: (_) => true,
        ),
        sets: file.sets,
        verbs: verbs,
      );

  Future<int> run(
    String yaml,
    String name, {
    Map<String, Verb> verbs = const {},
    bool keepGoing = false,
    int concurrency = 1,
  }) {
    final file = parseXtaskFile(yaml);
    return Executor(
      bodies: bodiesFor(file, verbs),
      starter: _NoProcesses(),
      log: logged.add,
      keepGoing: keepGoing,
      concurrency: concurrency,
    ).run(planFor(file, name));
  }

  String output() => logged.join('\n');

  const generated =
      'version: 1\n'
      'sets:\n'
      "  generated: {include: ['lib/**.g.dart']}\n";

  group('`unchanged:` is a task key', () {
    test('which the parser reads rather than refusing', () {
      expect(
        () => parseXtaskFile(
          '${generated}tasks:\n'
          '  codegen: {desc: x, do: gen, unchanged: generated}\n',
        ),
        returnsNormally,
      );
    });

    test('naming one set, by name', () {
      expect(
        refusalOf(
          () => parseXtaskFile(
            '${generated}tasks:\n'
            '  codegen: {desc: x, do: gen, unchanged: [generated]}\n',
          ),
        ),
        contains('`unchanged:` of task `codegen` must be a string'),
      );
    });
  });

  group('a task fails when it changed what its `unchanged:` set holds', () {
    test('and passes when what it wrote is what was there', () async {
      write('lib/a.g.dart', 'same');
      final code = await run(
        '${generated}tasks:\n'
            '  codegen: {desc: x, do: gen, unchanged: generated}\n',
        'codegen',
        verbs: {
          'gen': writing({'lib/a.g.dart': 'same'}),
        },
      );
      expect(code, ExitCode.success, reason: output());
    });

    test('naming the file whose bytes changed', () async {
      write('lib/a.g.dart', 'old');
      write('lib/b.g.dart', 'same');
      final code = await run(
        '${generated}tasks:\n'
            '  codegen: {desc: x, do: gen, unchanged: generated}\n',
        'codegen',
        verbs: {
          'gen': writing({'lib/a.g.dart': 'new', 'lib/b.g.dart': 'same'}),
        },
      );
      expect(code, ExitCode.taskFailed);
      expect(output(), contains('changed  lib/a.g.dart'));
      expect(output(), isNot(contains('lib/b.g.dart')));
      // Left as the task wrote it: the regenerated file is the fix, and
      // putting the old one back would make somebody run it again.
      expect(at('lib/a.g.dart').readAsStringSync(), 'new');
    });

    test('and a file it added or removed is a change too', () async {
      write('lib/a.g.dart', 'a');
      write('lib/gone.g.dart', 'b');
      final code = await run(
        '${generated}tasks:\n'
            '  codegen: {desc: x, needs: [add], do: drop, '
            'unchanged: generated}\n'
            '  add: {desc: x, do: add}\n',
        'codegen',
        verbs: {
          'add': writing({'lib/new.g.dart': 'c'}),
          'drop': deleting('lib/gone.g.dart'),
        },
      );
      expect(code, ExitCode.taskFailed);
      expect(output(), contains('added    lib/new.g.dart'));
      expect(output(), contains('removed  lib/gone.g.dart'));
      expect(output(), isNot(contains('lib/a.g.dart')));
    });

    test('and a directory a set names is every file beneath it', () async {
      // Lake's targets are directories, each holding a generated tree; the
      // set names the directory and the files are what is compared.
      write('gen/deep/x.dart', 'old');
      final code = await run(
        'version: 1\n'
            'sets:\n'
            '  targets: [gen]\n'
            'tasks:\n'
            '  regen: {desc: x, do: gen, unchanged: targets}\n',
        'regen',
        verbs: {
          'gen': writing({'gen/deep/x.dart': 'new'}),
        },
      );
      expect(code, ExitCode.taskFailed);
      expect(output(), contains('changed  gen/deep/x.dart'));
    });
  });

  group('what the set held is read before anything in the run has run', () {
    test('so a change made by what the task needs counts', () async {
      // The multi-step generation: the composite holds the set, and the
      // steps that write it are its `needs:`.
      write('lib/a.g.dart', 'old');
      final code = await run(
        '${generated}tasks:\n'
            '  codegen: {desc: x, needs: [l10n, build], unchanged: generated}\n'
            '  l10n: {desc: x, do: l10n}\n'
            '  build: {desc: x, do: build}\n',
        'codegen',
        verbs: {
          'l10n': writing({}),
          'build': writing({'lib/a.g.dart': 'new'}),
        },
      );
      expect(code, ExitCode.taskFailed);
      expect(output(), contains('changed  lib/a.g.dart'));
    });

    test(
      'and so does one made earlier by another branch of the graph',
      () async {
        // `needs:` runs once per invocation. `test` reaches `build` first, so
        // by the time `codegen` is reached the generation has happened — read
        // before `codegen`'s own needs, the set would already be regenerated,
        // and stale committed code would pass.
        write('lib/a.g.dart', 'old');
        final code = await run(
          'version: 1\n'
              'gates: [check]\n'
              'sets:\n'
              "  generated: {include: ['lib/**.g.dart']}\n"
              'tasks:\n'
              '  test: {desc: x, gate: [check], needs: [build], do: noop}\n'
              '  codegen: {desc: x, gate: [check], needs: [build], '
              'unchanged: generated}\n'
              '  build: {desc: x, do: build}\n',
          'check',
          verbs: {
            'noop': writing({}),
            'build': writing({'lib/a.g.dart': 'new'}),
          },
        );
        expect(code, ExitCode.taskFailed);
        expect(output(), contains('changed  lib/a.g.dart'));
      },
    );

    test(
      'and a set that held nothing then and nothing now is refused',
      () async {
        final code = await run(
          'version: 1\n'
              'sets:\n'
              "  generated: {include: ['lib/**.g.dart'], produced-by: gen}\n"
              'tasks:\n'
              '  codegen: {desc: x, needs: [gen], unchanged: generated}\n'
              '  gen: {desc: x, do: gen}\n',
          'codegen',
          verbs: {'gen': writing({})},
        );
        expect(code, ExitCode.invalidFile);
        expect(output(), contains('set `generated` is empty'));
      },
    );

    test('while one the run filled from nothing is a change', () async {
      final code = await run(
        'version: 1\n'
            'sets:\n'
            "  generated: {include: ['lib/**.g.dart'], produced-by: gen}\n"
            'tasks:\n'
            '  codegen: {desc: x, needs: [gen], unchanged: generated}\n'
            '  gen: {desc: x, do: gen}\n',
        'codegen',
        verbs: {
          'gen': writing({'lib/a.g.dart': 'a'}),
        },
      );
      expect(code, ExitCode.taskFailed);
      expect(output(), contains('added    lib/a.g.dart'));
    });
  });

  group('a set `unchanged:` cannot compare is refused', () {
    const values =
        'version: 1\n'
        'sets:\n'
        '  flavors: {values: [dev, prod]}\n'
        'tasks:\n'
        '  codegen: {desc: x, do: gen, unchanged: flavors}\n';

    test('by the run, before the body runs', () async {
      var ran = false;
      final code = await run(
        values,
        'codegen',
        verbs: {
          'gen': (_) async {
            ran = true;
            return ExitCode.success;
          },
        },
      );
      expect(code, ExitCode.invalidFile);
      expect(ran, isFalse);
      expect(output(), contains('holds values'));
    });

    test('by `--validate`, a set of values and a set there is not', () {
      final report = validateFile(
        parseXtaskFile(
          '$values  other: {desc: x, do: gen, unchanged: nothing}\n',
        ),
        knownVerbs: const {'gen'},
        sets: SetExpander(root: root.path),
      );
      expect('$report', contains('holds values'));
      expect(
        '$report',
        contains(
          'task `other` has `unchanged: nothing`, and there is no set called '
          '`nothing`',
        ),
      );
    });

    test('and by `--dry-run`, with the code the run would give', () async {
      final file = parseXtaskFile(values);
      final code = await dryRun(
        plan: planRun(file, 'codegen'),
        bodies: bodiesFor(file, {'gen': writing({})}),
        log: logged.add,
      );
      expect(code, ExitCode.invalidFile);
      expect(output(), contains('holds values'));
    });
  });

  test('`--dry-run` says which set the task is to leave alone', () async {
    write('lib/a.g.dart', 'a');
    final file = parseXtaskFile(
      '${generated}tasks:\n'
      '  codegen: {desc: x, do: gen, unchanged: generated}\n',
    );
    final code = await dryRun(
      plan: planRun(file, 'codegen'),
      bodies: bodiesFor(file, {'gen': writing({})}),
      log: logged.add,
    );
    expect(code, ExitCode.success);
    expect(output(), contains('same set `generated`'));
  });
}
