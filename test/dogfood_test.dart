import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/ci.dart';
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

    test('and every gate it declares gathers something', () {
      // A composite over an empty gate is the failure this whole tool is
      // about: a command that passes having examined nothing. Asked of every
      // collected gate rather than of `check` by name — naming them here
      // would be a list of gates beside the file's own, and the second one is
      // always the one that stops being updated.
      final gates = collectedGates(file);
      expect(gates, isNotEmpty);
      for (final gate in gates) {
        expect(tasksInGate(file, gate), isNotEmpty, reason: 'gate `$gate`');
      }
    });

    test('and running the gates reaches every task but the hand-typed one', () {
      // The local half of §7.1's residual — a task no gate ever reaches is
      // invisible, and it looks exactly like a task that is checked.
      //
      // Every gate, not `check` alone. `publishable` is why: `pub publish
      // --dry-run` exits 65 while a checked-in file is modified, so it can
      // only pass in a clean checkout — which makes it CI's to run, not the
      // desk's, and gives it a gate set of its own rather than no gate at all.
      // A test that asked about `check` would have called a task CI runs on
      // every push "typed by hand", and the word would have been wrong.
      //
      // Planned from each composite's own name rather than from the gate's:
      // they happen to match in this file and nothing makes them.
      //
      // What is left is equality, not containment. A task added and forgotten
      // fails here, and so does a name left behind after the task it excused
      // is gone. It is not a second copy of any gate: their members are
      // exactly what is not written on this line.
      const typedByHand = {'aot'};
      final collected = withCollectedGates(file);
      final reached = {
        for (final task in file.tasks.values)
          if (task.collects != null) ...planRun(collected, task.name).names,
      };
      expect(
        file.tasks.keys.toSet().difference(reached),
        typedByHand,
        reason:
            'a task nothing runs is either missing a `gate:` or belongs in '
            '`typedByHand` above',
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

  group('the README quotes the command rather than describing it', () {
    // §1, in the repository that exists for §1. `usage` in `cli.dart` and the
    // block under "## The command" are the same list, and when this test was
    // written they had already drifted three ways: `--parallel` had lost the
    // cost it names, `--why` half of its answer, and `--validate` and
    // `--check-ci` had swapped places. Each half read plausibly on its own,
    // which is what makes this drift survive a review.
    //
    // `modes` is public so the help cannot forget a flag the parser accepts;
    // this is the other half of the same promise, for the copy that is not in
    // the program.
    test("and it is the parser's own text, line for line", () {
      final readme = File(p.join(root, 'README.md')).readAsStringSync();
      // Two spaces come off, and exactly two: the lines are indented where
      // they are printed under a `usage:` header, and the README's fence
      // supplies that header instead. Trimming further would stop comparing
      // the alignment the block is written for.
      final printed = [
        for (final line in usage.skip(1).takeWhile((line) => line.isNotEmpty))
          line.replaceFirst(RegExp('^  '), ''),
      ];
      expect(
        _fencedBlockAfter(readme, '## The command'),
        printed,
        reason:
            'README.md and `usage` in cli.dart have drifted. The README quotes '
            'the parser — copy the block printed by `xtask` with no arguments.',
      );
    });
  });

  group("the README's own examples are files this engine would accept", () {
    // Written after both defects in one example: it had no `version:` at all,
    // and it wrote a glob as a plain list, which is a literal member that
    // happens to contain a `*`. Neither is visible by reading, and a reader
    // copying an example out of the README meets both.
    //
    // Only blocks declaring `version:` are examined, which is the line
    // between a FILE and a fragment: the workflow snippet is not an
    // `xtask.yaml` and the one-task illustrations are not whole ones.
    // Parsed rather than validated, because an example may name a verb the
    // project it belongs to registered and this repository has not.
    test('every complete one parses', () {
      final readme = File(p.join(root, 'README.md')).readAsStringSync();
      final blocks = [
        for (final block in _fencedBlocks(readme, 'yaml'))
          if (block.startsWith('version:')) block,
      ];
      expect(
        blocks,
        hasLength(greaterThan(1)),
        reason: 'the README used to carry two whole files; find them again',
      );
      for (final block in blocks) {
        // **Validated, not merely parsed.** Parsing says the shape is right;
        // §8's checks are what a reader meets the moment they copy the block
        // and run the first gate this document tells them to adopt. The
        // declared-gates rule landed in `--validate` and the flagship example
        // was left using `gate:` without a `gates:` line, so the document's
        // own first instruction refused the document's own first file. Only a
        // check that asks the same question a reader will ask can catch that.
        late final XtaskFile file;
        expect(
          () => file = parseXtaskFile(block, sourceUrl: Uri.parse('README.md')),
          returnsNormally,
          reason: block,
        );
        final report = validateFile(
          withCollectedGates(file),
          knownVerbs: {
            ...builtInVerbNames,
            ...file.tasks.values.map(
              (task) => task.body is DoBody ? (task.body! as DoBody).verb : '',
            ),
          }..remove(''),
        );
        expect(report.ok, isTrue, reason: '$block\n$report');
      }
    });
  });

  group('and its Dart examples define what they register', () {
    // The entry point in the README registered two verbs, `regen` and
    // `publish`, and defined one. Copied out, it does not compile:
    //
    //   bin/xtask.dart:10:18: Error: Undefined name 'publish'.
    //
    // A reader meeting that has no way to tell whether they mistyped it or
    // the document is wrong. Checked by reading rather than by compiling,
    // which would need a scratch package and a `pub get` in the gate: what
    // went wrong here is a NAME with no declaration, and that is visible in
    // the text.
    test('every verb the entry point hands over is defined nearby', () {
      final readme = File(p.join(root, 'README.md')).readAsStringSync();
      final dart = _fencedBlocks(readme, 'dart').join('\n');
      final registered = RegExp("'([a-z-]+)': ([a-zA-Z]+)").allMatches(dart);
      expect(
        registered,
        isNotEmpty,
        reason: 'the README used to show a verb being registered; find it',
      );
      for (final registration in registered) {
        final verb = registration.group(2);
        expect(
          dart,
          contains('Future<int> $verb('),
          reason:
              'the README registers `$verb` and never defines it, so the '
              'example does not compile when it is copied',
        );
      }
    });
  });

  group('and its internal links point at headings it has', () {
    // `[Gate sets](#gate-sets-and-what-they-are-for)` outlived the heading it
    // named by one commit: the section was renamed and the link was not, which
    // renders as a link that quietly does nothing. Nothing in a markdown file
    // complains, and a reader who follows it lands at the top of the page and
    // assumes they missed something.
    test('every one of them', () {
      final readme = File(p.join(root, 'README.md')).readAsStringSync();
      // GitHub's own rule: lower-case, punctuation dropped, spaces hyphenated.
      String slug(String heading) =>
          '#${heading.toLowerCase().replaceAll(RegExp('[^a-z0-9 -]'), '')}'
              .replaceAll(' ', '-');
      final anchors = {
        for (final heading in RegExp(
          r'^#+ (.+)$',
          multiLine: true,
        ).allMatches(readme))
          slug(heading.group(1)!),
      };
      final links = [
        for (final link in RegExp(r'\]\((#[a-z0-9-]+)\)').allMatches(readme))
          link.group(1)!,
      ];
      expect(
        links,
        isNotEmpty,
        reason: 'the README used to link inside itself',
      );
      for (final link in links) {
        expect(anchors, contains(link), reason: 'no heading makes `$link`');
      }
    });
  });

  group('and nothing it marks as shell is unbalanced', () {
    // The command listing was fenced as ```shell and contained one apostrophe,
    // in "that gate set's task names". A shell highlighter reads that as the
    // start of a string and colours everything after it to the end of the
    // block — so the whole table rendered as one quoted run on pub.dev, while
    // the markdown itself was perfectly well formed. The fence says `text`
    // now, because a usage listing is not shell.
    test('so a stray quote cannot colour a whole block', () {
      final readme = File(p.join(root, 'README.md')).readAsStringSync();
      for (final block in _fencedBlocks(readme, 'shell')) {
        for (final quote in ["'", '"']) {
          expect(
            quote.allMatches(block).length.isEven,
            isTrue,
            reason:
                'an odd number of $quote in a shell block, which a highlighter '
                'reads as a string that never closes:\n$block',
          );
        }
      }
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
    // §7.1's residual, and the one that grows back quietly: somebody adds
    // `- run: dart analyze` to the workflow instead of a task to the file, and
    // the two lists start drifting the same afternoon.
    //
    // Asked of the TOOL rather than reimplemented here. This test used to walk
    // the workflow itself, which made it a second answer to the same question
    // — and a second answer in the guard against second answers.
    late CiReport report;

    setUpAll(() => report = checkCi(file, root: root));

    test('every shell step is one invocation of one gate set', () {
      expect(
        report.problems,
        isEmpty,
        reason: report.problems.join('\n'),
      );
      expect(report.invocations, isNotEmpty);
    });

    test("and this repository's own gate is one of them", () {
      expect(report.invocations.map((i) => i.gate), contains('check'));
    });

    test('and no gate set is left with no job to run it', () {
      // True here because there is one gate and one job. In a repository with
      // human-only entry points it would not be, which is why the tool reports
      // this rather than refusing it.
      expect(report.unrun, isEmpty);
    });
  });
}

/// The lines of the first fenced block after [heading] in [markdown].
List<String> _fencedBlockAfter(String markdown, String heading) {
  final lines = markdown.split('\n');
  final at = lines.indexOf(heading);
  expect(at, isNonNegative, reason: 'README.md has no `$heading` section');
  // Matched by the fence, not by the whole line: a fence may carry a language
  // (` ```shell `), and looking for a bare ` ``` ` then finds the CLOSING one
  // and returns the prose after it — which is how this helper failed the first
  // time somebody labelled the block.
  final opened = lines.indexWhere((line) => line.startsWith('```'), at) + 1;
  final closed = lines.indexWhere((line) => line.startsWith('```'), opened);
  expect(
    closed,
    isNonNegative,
    reason: 'the block under `$heading` is unclosed',
  );
  return lines.sublist(opened, closed);
}

/// Every fenced block in [markdown] tagged with [language], content only.
List<String> _fencedBlocks(String markdown, String language) {
  final blocks = <String>[];
  final lines = markdown.split('\n');
  for (var at = 0; at < lines.length; at++) {
    if (lines[at] != '```$language') {
      continue;
    }
    final closed = lines.indexWhere((line) => line.startsWith('```'), at + 1);
    blocks.add('${lines.sublist(at + 1, closed).join('\n')}\n');
    at = closed;
  }
  return blocks;
}
