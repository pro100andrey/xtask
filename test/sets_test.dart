import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/model.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/sets.dart';

/// The message of the [XtaskFormatException] [body] throws.
String refusalOf(void Function() body) {
  try {
    body();
  } on XtaskFormatException catch (e) {
    return e.toString();
  }
  fail('expected a refusal, got none');
}

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

    test('names the exclusion that was in play', () {
      given(['packages/test_data/a.lake']);
      expect(
        () => expandGlob(['**/*.lake'], ['**/test_data/**']),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('with or without'), contains('`**/test_data/**`')),
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

  group('the fixes a code review asked for', () {
    test('a glob set works at all — Glob.listSync would have refused', () {
      // glob.dart:145 begins `if (context.style != p.style) throw StateError`.
      // Every pattern here is POSIX by design, so on Windows the whole feature
      // threw — past §5.3's exit codes, past --validate, with a stack trace.
      // Matching, unlike listing, has no such rule; the walk is ours now.
      given(['a/b.lake']);
      expect(expandGlob(['**/*.lake']), ['a/b.lake']);
      expect(
        () => Glob('*.lake', context: p.windows).listSync(root: root.path),
        throwsA(isA<StateError>()),
        reason: 'the library rule this design had to stop depending on',
      );
    }, testOn: 'posix');

    test('an excluded directory is not itself a member', () {
      // `**/test_data/**` needs a segment after `test_data`, so the directory
      // survived the filter — and §6's `remove` deletes recursively, which
      // made the exclusion the thing that listed its own files for deletion.
      given(['packages/a.lake', 'packages/test_data/b.lake', 'keep.lake']);
      final members = expandGlob(['**'], ['**/test_data/**']);
      expect(members, isNot(contains('packages/test_data')));
      expect(members, isNot(contains('packages/test_data/b.lake')));
      expect(members, containsAll(['keep.lake', 'packages/a.lake']));
    });

    test('an excluded directory is not descended into either', () {
      given(['x/test_data/deep/deeper/a.lake']);
      expect(
        () => expandGlob(['**/*.lake'], ['**/test_data/**']),
        throwsA(isA<XtaskFormatException>()),
        reason: 'everything matched was under the pruned directory',
      );
    });

    test('an absolute pattern is refused, not followed', () {
      // It used to come back with `../../../../../../etc/hosts` — real paths,
      // outside the repository, on their way to a verb that deletes.
      given(['a.lake']);
      expect(
        () => expandGlob(['/etc/hos*']),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.toString(),
            'message',
            contains('reaches outside the repository'),
          ),
        ),
      );
    });

    test('a Windows absolute pattern is refused too', () {
      given(['a.lake']);
      expect(
        () => expandGlob([r'C:\Windows\*']),
        throwsA(isA<XtaskFormatException>()),
      );
    });

    test('a pattern climbing through `..` is refused', () {
      given(['a.lake']);
      expect(
        () => expandGlob(['../sibling/**']),
        throwsA(isA<XtaskFormatException>()),
      );
    });

    test('a later `**/` is expanded even when an earlier one is not', () {
      // The scan stopped at the first `**/` and, finding it part of a larger
      // token, returned the pattern untouched — abandoning the zero-directory
      // reading of every legitimate one after it.
      given(['ax/b/c.lake', 'ax/b/z/c.lake']);
      expect(expandGlob(['a**/b/**/c.lake']), [
        'ax/b/c.lake',
        'ax/b/z/c.lake',
      ]);
    });

    test('a `**/` after a brace is expanded', () {
      given(['a/x.lake', 'a/deep/x.lake']);
      expect(expandGlob(['{a,b}/**/x.lake']), ['a/deep/x.lake', 'a/x.lake']);
    });

    test('the answer cannot be appended to, whichever kind it came from', () {
      // The list arm handed back the model's own list while the glob arm built
      // a fresh one, so `expand(...)..addAll(args)` worked on a glob and
      // permanently poisoned a list — and no test could see it, because the
      // suite is almost all globs.
      given(['a.lake']);
      expect(() => expandGlob(['*.lake']).add('x'), throwsUnsupportedError);
      expect(
        () => expander().expand('s', const ListSet(['a'])).add('x'),
        throwsUnsupportedError,
      );
    });

    test('the model keeps its own list when a set is expanded', () {
      const set = ListSet(['a', 'b']);
      expander().expand('s', set);
      expect(set.members, ['a', 'b']);
    });

    test(
      'a malformed pattern is refused with the file, not a scanner dump',
      () {
        given(['a.lake']);
        for (final bad in ['[', 'a{b', '{']) {
          expect(
            () => expandGlob([bad]),
            throwsA(
              isA<XtaskFormatException>().having(
                (e) => e.toString(),
                'message for `$bad`',
                contains('is not a valid pattern'),
              ),
            ),
            reason: bad,
          );
        }
      },
    );

    test('`**/` alone does not crash on a pattern the library accepts', () {
      // The engine manufactured the empty pattern itself: the zero-directory
      // reading of `**/` is ``, and Glob('') throws a scanner exception —
      // past §5.3's exit codes, pointing "line 1, column 2" inside the pattern
      // string rather than at xtask.yaml. It matches nothing here, which is a
      // refusal; what matters is that it is OUR refusal.
      given(['a.lake', 'b/c.lake']);
      expect(
        () => expandGlob(['**/']),
        throwsA(isA<XtaskFormatException>()),
      );
    });

    test('an exclusion is blamed only when there was something to remove', () {
      given(['lib/a.dart']);
      final message = refusalOf(() => expandGlob(['**/*.lake'], ['**/x/**']));
      expect(message, contains('with or without'));
    });

    test('the refusal names the line the set was written on', () {
      // Only possible because the model now carries a span. Before, every
      // message raised after parsing said "somewhere in your file".
      final file = parseXtaskFile(
        'version: 1\nsets:\n  pkgs: []\ntasks: {}\n',
      );
      expect(
        refusalOf(() => expander().expand('pkgs', file.sets['pkgs']!)),
        contains('line 3'),
      );
    });
  });

  group('patterns mean the same thing on every platform', () {
    // The review found the previous version of this group vacuous: on a POSIX
    // host `p.posix` IS `p.context`, so deleting the pin left it green. These
    // two compare the two readings directly, which is the only way to show
    // that choosing one of them was a decision.
    test(r'a `\` in a pattern escapes, so a literal `*` can be named', () {
      // POSIX glob syntax reads `\` as escaping the next character, and that
      // is what a pattern in xtask.yaml gets — the file's own notation, not
      // the host's.
      //
      // HONEST LIMIT: I could not build a case where p.windows and p.posix
      // disagree once the walk produces `/`-joined relative paths, so
      // `context: p.posix` is now a statement of intent rather than something
      // this suite can catch you removing. Saying so beats a test that pins
      // nothing and claims otherwise — which is what this group used to be.
      given(['a*b.lake', 'axb.lake']);
      expect(expandGlob([r'a\*b.lake']), ['a*b.lake']);
    });

    test('a pattern with `/` matches on a host that spells paths otherwise', () {
      // Stated against the windows context so the assertion survives being
      // read on Windows, where the naive version becomes a tautology the other
      // way round.
      expect(
        Glob('a/b/*.lake', context: p.posix).matches('a/b/c.lake'),
        isTrue,
      );
    });
  });

  group('symlinks are listed, never followed', () {
    // §6 says `remove` never follows a symlink, and listing takes the same
    // line — plus a second reason: a link into an ancestor turns the walk into
    // a loop. Both were previously asserted by a test that stayed green with
    // `followLinks: false` deleted.
    test('a link to a matching file is not a member', () {
      given(['real/a.lake']);
      Link(
        p.join(root.path, 'alias.lake'),
      ).createSync(p.join(root.path, 'real', 'a.lake'));
      expect(expandGlob(['**/*.lake']), ['real/a.lake']);
    });

    test('a link that points at an ancestor does not hang the walk', () {
      given(['deep/a.lake']);
      Link(p.join(root.path, 'deep', 'loop')).createSync(root.path);
      expect(expandGlob(['**/*.lake']), ['deep/a.lake']);
    });
  }, testOn: 'posix');
}
