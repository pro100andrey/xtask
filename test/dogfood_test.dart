import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/cli.dart';
import 'package:xtask/src/gates.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/model.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/primitives.dart';
import 'package:xtask/src/schema.dart';
import 'package:xtask/src/sets.dart';
import 'package:xtask/src/validate.dart';
import 'package:xtask/src/version.dart';
import 'package:yaml/yaml.dart';

/// This repository's own `xtask.yaml`, checked by this repository's own suite.
///
/// §13 item 9 asks xtask to be its first user, and the reason to spend a test
/// file on it is that the first user is the one who finds out whether the
/// design survives a real file. What is asserted here is deliberately about
/// RELATIONS rather than contents: an assertion that the `check` gate holds
/// `format`, `analyze` and `test` would be a third copy of the list — after
/// the file itself and the CI workflow — which is the defect §1 exists to
/// remove, written into the test that is supposed to guard against it.
void main() {
  late String root;
  late XtaskFile file;

  setUpAll(() {
    // Found the way the command finds it — upwards — so the suite passes from
    // a subdirectory as well as from the root.
    final found = findRoot(Directory.current.path);
    expect(
      found,
      isNotNull,
      reason: 'this repository is meant to have an `$xtaskFileName`',
    );
    root = found!;
    final path = p.join(root, xtaskFileName);
    file = parseXtaskFile(
      File(path).readAsStringSync(),
      sourceUrl: Uri.file(path),
    );
  });

  group('the file this repository runs on', () {
    test('parses, which is what reaching this test means', () {
      expect(file.tasks, isNotEmpty);
    });

    test('and passes everything §8 refuses', () {
      // The same check `--validate` does, run from inside the suite so that a
      // broken task file cannot be green. This project registers no verbs of
      // its own (§9), so what a `do:` may name is the built-in list.
      final report = validateFile(
        withCollectedGates(file),
        knownVerbs: builtInVerbNames,
        sets: SetExpander(root: root),
      );
      expect(report.problems, isEmpty, reason: '$report');
    });

    test('the `check` gate gathers something', () {
      // A composite over an empty gate is the failure this whole tool is
      // about: a command that passes having examined nothing.
      expect(tasksInGate(file, 'check'), isNotEmpty);
    });

    test('and running it reaches every task in the file', () {
      // The local half of §7.1's residual — a task no gate ever reaches is
      // invisible, and it looks exactly like a task that is checked. With one
      // gate and one job the property is exact here, so it is asserted rather
      // than deferred to `--emit-ci`.
      final reached = planRun(withCollectedGates(file), 'check').names.toSet();
      expect(
        file.tasks.keys.toSet().difference(reached),
        isEmpty,
        reason: 'these tasks are in the file and nothing runs them',
      );
    });
  });

  group('the schema beside it is the one this engine emits', () {
    // The committed file is generated, and generated files rot the moment
    // nothing compares them. There is no `--check-schema` mode for this: a
    // task cannot write the file either, because `>` is shell and §5.2 says a
    // task's description has none — so writing stays a person's deliberate
    // act and checking is the gate's, which is the right way round.
    late File schema;

    setUpAll(() => schema = File(p.join(root, 'xtask.schema.json')));

    test('it is there at all', () {
      expect(
        schema.existsSync(),
        isTrue,
        reason:
            'an editor points at this file, and a clone without it is a '
            'clone with no key completion and no red squiggle',
      );
    });

    test('and it has not fallen behind the model it describes', () {
      expect(
        schema.readAsStringSync(),
        xtaskJsonSchema(),
        reason:
            'the schema is out of date. Regenerate it:\n'
            '  dart run :xtask --emit-schema > xtask.schema.json',
      );
    });

    test('and the file points at it, by a path that survives a clone', () {
      // Relative, so it needs no network and no per-person editor setting.
      final text = File(p.join(root, xtaskFileName)).readAsStringSync();
      expect(
        text,
        contains(r'# yaml-language-server: $schema=./xtask.schema.json'),
      );
    });
  });

  group('the version in code is the version in the manifest', () {
    // The number has to be in `pubspec.yaml` because pub needs it there, and
    // in code because a compiled entry point has no manifest beside it to
    // read. §1 is about drift, not about a fact being named twice — so this is
    // the thing that makes the second mention safe, and it is the whole reason
    // no generator was written for one line.
    test('and neither has moved without the other', () {
      final manifest = File(p.join(root, 'pubspec.yaml')).readAsStringSync();
      final declared = RegExp(
        r'^version:\s*(\S+)\s*$',
        multiLine: true,
      ).firstMatch(manifest);
      expect(declared, isNotNull, reason: 'pubspec.yaml has no `version:`');
      expect(
        packageVersion,
        declared!.group(1),
        reason:
            'lib/src/version.dart and pubspec.yaml disagree. Change '
            '`packageVersion` to match the manifest',
      );
    });
  });

  group('the workflow runs gates, not commands', () {
    // §7.1's other residual, and the one that grows back quietly: somebody
    // adds `- run: dart analyze` to the workflow instead of a task to the
    // file, and the two lists start drifting the same afternoon. A `uses:`
    // step is untouched — actions are what §7.1 leaves to the CI file, being
    // what must EXIST before xtask runs rather than what runs.
    late List<String> commands;
    late Set<String> collected;

    setUpAll(() {
      collected = {
        for (final task in file.tasks.values)
          if (task.collects != null) task.collects!,
      };
      commands = [
        for (final workflow in Directory(
          p.join(root, '.github', 'workflows'),
        ).listSync().whereType<File>())
          ..._shellSteps(loadYaml(workflow.readAsStringSync()) as YamlMap),
      ];
    });

    test('there is a workflow, and it runs something', () {
      expect(commands, isNotEmpty);
    });

    test('every shell step is one invocation of one gate set', () {
      final invocation = RegExp(r'^dart run :xtask (\S+)$');
      for (final command in commands) {
        final match = invocation.firstMatch(command);
        expect(
          match,
          isNotNull,
          reason:
              '`$command` is a command the workflow names itself. What runs '
              'belongs in `$xtaskFileName`, as a task in a gate set; the '
              'workflow runs the gate',
        );
        expect(
          collected,
          contains(match!.group(1)),
          reason: '`${match.group(1)}` is not a gate set anything collects',
        );
      }
    });

    test("and this repository's own gate is actually one of them", () {
      // Not implied by the rule above: a workflow running no gate at all
      // satisfies it vacuously, and would be a repository whose checks are
      // described and never run.
      expect(commands, contains('dart run :xtask check'));
    });
  });
}

/// Every `run:` step of every job in [workflow], in order.
Iterable<String> _shellSteps(YamlMap workflow) sync* {
  for (final job in (workflow['jobs'] as YamlMap).values.cast<YamlMap>()) {
    for (final step in (job['steps'] as YamlList).cast<YamlMap>()) {
      if (step['run'] case final String command) {
        yield command.trim();
      }
    }
  }
}
