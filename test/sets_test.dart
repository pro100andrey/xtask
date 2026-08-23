import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/model.dart';
import 'package:xtask/src/sets.dart';

void main() {
  late Directory root;

  /// Creates [paths] under the temporary root, directories and all.
  void given(List<String> paths) {
    for (final path in paths) {
      final file = File(p.join(root.path, p.joinAll(p.posix.split(path))));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('');
    }
  }

  SetExpander expander() => SetExpander(root: root.path);

  List<String> expandGlob(
    List<String> include, [
    List<String> exclude = const [],
  ]) => expander().expand('s', GlobSet(include: include, exclude: exclude));

  setUp(() {
    // A real filesystem rather than a fake one, deliberately: the property
    // under test is that a directory listing's order does not reach a task's
    // argument list, and a fake would have to be given an order to have one.
    root = Directory.systemTemp.createTempSync('xtask_sets_');
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('a list set', () {
    test('is the members, as written', () {
      final members = expander().expand('s', const ListSet(['b', 'a', 'c']));
      expect(members, ['b', 'a', 'c']);
    });

    test('is NOT sorted — somebody chose that order', () {
      // §4.2 asks for a deterministic order so an argument list does not
      // depend on the filesystem. It does not ask for an author's list to be
      // rearranged, and `each:` runs in this order. Sorting here would be the
      // engine overruling what is written, which is what R2 forbids.
      final members = expander().expand(
        's',
        const ListSet(['packages/lake', 'packages/lake_cli', 'examples/a']),
      );
      expect(members, [
        'packages/lake',
        'packages/lake_cli',
        'examples/a',
      ]);
    });

    test('members are not required to exist', () {
      // `clean` names build output that is usually already gone; §6 makes a
      // missing path explicitly not an error.
      expect(
        expander().expand('s', const ListSet(['vscode/out', 'coverage'])),
        ['vscode/out', 'coverage'],
      );
    });

    test('written empty is refused', () {
      expect(
        () => expander().expand('s', const ListSet([])),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('set `s` is empty'), contains('no members')),
          ),
        ),
      );
    });
  });

  group('a glob set', () {
    test('finds what the pattern reaches', () {
      given(['lib/a.dart', 'lib/b.dart', 'bin/c.dart']);
      expect(expandGlob(['lib/*.dart']), ['lib/a.dart', 'lib/b.dart']);
    });

    test('walks deep with `**`', () {
      given(['a/x.lake', 'a/b/y.lake', 'a/b/c/z.lake', 'a/skip.dart']);
      expect(expandGlob(['a/**/*.lake']), [
        'a/b/c/z.lake',
        'a/b/y.lake',
        'a/x.lake',
      ]);
    });

    test('expands braces', () {
      given(['templates/t.lake', 'packages/p.lake', 'other/o.lake']);
      expect(expandGlob(['{templates,packages}/*.lake']), [
        'packages/p.lake',
        'templates/t.lake',
      ]);
    });

    test('comes back sorted, not in filesystem order', () {
      // Created in an order chosen to be wrong. What the directory hands back
      // is its own business; what the task receives is not allowed to be.
      given(['z.lake', 'm.lake', 'a.lake', 'B.lake']);
      expect(expandGlob(['*.lake']), ['B.lake', 'a.lake', 'm.lake', 'z.lake']);
    });

    test('unions several include patterns without repeating a match', () {
      given(['a/x.lake', 'b/y.lake']);
      expect(expandGlob(['a/*.lake', '**/*.lake']), ['a/x.lake', 'b/y.lake']);
    });

    test('drops what exclude reaches', () {
      given([
        'packages/a.lake',
        'packages/test_data/b.lake',
        'packages/test_data/deep/c.lake',
      ]);
      expect(expandGlob(['packages/**/*.lake'], ['**/test_data/**']), [
        'packages/a.lake',
      ]);
    });

    test('matches directories as well as files', () {
      // `clean` removes `packages/*/coverage`, which are directories.
      given(['packages/one/coverage/f', 'packages/two/coverage/f']);
      expect(expandGlob(['packages/*/coverage']), [
        'packages/one/coverage',
        'packages/two/coverage',
      ]);
    });

    test('answers paths relative to the root, with `/`', () {
      given(['a/b/c.lake']);
      final members = expandGlob(['**/*.lake']);
      expect(members, ['a/b/c.lake']);
      expect(members.single, isNot(contains(r'\')));
      expect(members.single, isNot(contains(root.path)));
    });
  });

  group('an expansion that finds nothing', () {
    test('is refused, not answered with an empty list', () {
      given(['lib/a.dart']);
      expect(
        () => expandGlob(['**/*.lake']),
        throwsA(isA<XtaskFormatException>()),
      );
    });

    test('says what it looked for, so a broken pattern is visible', () {
      given(['lib/a.dart']);
      expect(
        () => expandGlob(['**/*.lake']),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('set `s` is empty'), contains('`**/*.lake`')),
          ),
        ),
      );
    });

    test('names the exclusion when that is what emptied it', () {
      given(['packages/test_data/a.lake']);
      expect(
        () => expandGlob(['**/*.lake'], ['**/test_data/**']),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('excluded'), contains('`**/test_data/**`')),
          ),
        ),
      );
    });

    test('explains the harm, because the harm is not obvious', () {
      // The failure this prevents is a task that succeeded having done
      // nothing, inside a gate that then went green. Somebody reading the
      // refusal should not have to guess why an empty list was not fine.
      given(['lib/a.dart']);
      expect(
        () => expandGlob(['**/*.lake']),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.toString(),
            'message',
            contains('nobody checked'),
          ),
        ),
      );
    });
  });

  group('`**/` stands for no directory as well as for several', () {
    // A deliberate departure from `package:glob`, which reads `**/` as one
    // directory or more. Every glob a person has met elsewhere — bash's
    // globstar, git's ignore rules, minimatch — reads it as none or more, and
    // the pattern in §12 of xtask.md is written expecting that. The failure
    // being avoided is not an error: it is a gate that examined fewer files
    // than it was written to examine and went green regardless.
    test('the depth-zero case, which the library alone would miss', () {
      given(['a/x.lake', 'a/b/y.lake']);
      expect(expandGlob(['a/**/*.lake']), ['a/b/y.lake', 'a/x.lake']);
    });

    test("§12's own pattern reaches a file directly under the directory", () {
      given(['packages/top.lake', 'packages/deep/inner.lake']);
      expect(expandGlob(['{templates,packages}/**/*.lake']), [
        'packages/deep/inner.lake',
        'packages/top.lake',
      ]);
    });

    test('a leading `**/` reaches the root', () {
      given(['top.lake', 'a/deep.lake']);
      expect(expandGlob(['**/*.lake']), ['a/deep.lake', 'top.lake']);
    });

    test('two of them in one pattern give all four readings', () {
      given(['a/b/c.lake', 'a/x/b/c.lake', 'a/b/y/c.lake', 'a/x/b/y/c.lake']);
      expect(expandGlob(['a/**/b/**/c.lake']), [
        'a/b/c.lake',
        'a/b/y/c.lake',
        'a/x/b/c.lake',
        'a/x/b/y/c.lake',
      ]);
    });

    test('an exclusion gets the same reading, or it under-excludes', () {
      // `**/test_data/**` has to drop a test_data sitting at the root too —
      // otherwise the exclusion is the thing that silently does less.
      given(['test_data/a.lake', 'packages/test_data/b.lake', 'keep.lake']);
      expect(expandGlob(['**/*.lake'], ['**/test_data/**']), ['keep.lake']);
    });

    test('`**` that is not a whole segment is left alone', () {
      // `a**/b` asks for something else, and rewriting it would answer a
      // question the author did not ask.
      given(['ax/b.lake', 'a/b.lake']);
      expect(expandGlob(['a**/*.lake']), ['a/b.lake', 'ax/b.lake']);
    });
  });

  group('patterns mean the same thing on every platform', () {
    test('a pattern is read as POSIX regardless of host', () {
      // `xtask.yaml` is committed and read on Windows too. If Glob were handed
      // the host context, `/` would be a separator on one platform and `\` on
      // another, and the same file would match different things.
      given(['a/b/c.lake']);
      expect(expandGlob(['a/b/*.lake']), ['a/b/c.lake']);
    });

    test('a backslash is not a separator in a pattern', () {
      given(['a/b/c.lake']);
      expect(
        () => expandGlob([r'a\b\*.lake']),
        throwsA(isA<XtaskFormatException>()),
      );
    });
  });
}
