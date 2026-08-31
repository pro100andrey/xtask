import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/globs.dart';
import 'package:xtask/src/model.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/sets.dart';

import 'helpers.dart';

void main() {
  group('a brace does not switch pruning off by itself', () {
    test('one inside a segment still prunes, and finds the same members', () {
      // `packages/{a,b}/**` splits and rejoins exactly, so the prune
      // arithmetic holds. Reading every brace as unprunable made an ordinary
      // monorepo shape read all of `node_modules` and `.git` — 250ms against
      // 10ms for the same set written without it.
      final root = tempRepo('brace');
      for (final path in [
        'packages/a/lib/one.dart',
        'packages/b/lib/two.dart',
        'packages/c/lib/three.dart',
      ]) {
        File(p.join(root.path, p.joinAll(p.posix.split(path))))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('');
      }
      expect(
        SetExpander(root: root.path).expand(
          's',
          const GlobSet(include: ['packages/{a,b}/**/*.dart'], exclude: []),
        ),
        ['packages/a/lib/one.dart', 'packages/b/lib/two.dart'],
      );
    });

    test('and one that spans a separator keeps reaching everywhere', () {
      // `{a,b/c}/**` makes the segment COUNT depend on which alternative is
      // taken, so a pattern with four apparent segments may still reach five
      // deep. That one has to keep going.
      final root = tempRepo('brace2');
      for (final path in ['a/deep/one.dart', 'b/c/deep/two.dart']) {
        File(p.join(root.path, p.joinAll(p.posix.split(path))))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('');
      }
      expect(
        SetExpander(root: root.path).expand(
          's',
          const GlobSet(include: ['{a,b/c}/**/*.dart'], exclude: []),
        ),
        ['a/deep/one.dart', 'b/c/deep/two.dart'],
      );
    });
  });

  test('and it is refused before every reading is built', () {
    // The limit used to be applied after every reading had been materialised:
    // twenty-four globstars built sixteen million strings and then refused,
    // and thirty ran the process out of memory instead of reaching the
    // sentence written here for it. The readings are accumulated left to
    // right and the count is checked at each step, so a pattern like this one
    // is refused having built thirty-three strings, not 2^50000.
    final root = tempRepo('vast');
    // Eight, which is inside the segment bound and well past the readings
    // one: 2^8 is 256. The two limits are different questions and this is
    // about the second.
    final vast = '${'**/x/' * 8}*.dart';
    expect(
      () => SetExpander(root: root.path).expand(
        's',
        GlobSet(include: [vast], exclude: const []),
      ),
      throwsA(
        isA<XtaskFormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains('readings'), contains('set `s`')),
        ),
      ),
    );
  });

  test('and a pattern whose readings collapse is bounded by its length', () {
    // The readings bound cannot catch this one: `{a,**/}` keeps the set at a
    // single member however many times it is repeated, so the loop ran once
    // per segment and nothing stopped it — sixteen thousand of them was a
    // second and a half of work to answer with one string.
    //
    // Counted rather than timed. A wall-clock assertion in a suite three OS
    // runners run is a gate that goes red for being busy.
    expect(
      () => zeroOrMoreDirectories('{a,**/}' * (mostGlobstarSegments + 10)),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('`**/` in it'),
        ),
      ),
    );
    expect(
      zeroOrMoreDirectories('{a,**/}' * mostGlobstarSegments),
      hasLength(1),
      reason: 'the bound is on the segments, and this many is still read',
    );
  });

  test("an empty pattern is the caller's own, not an invented variant", () {
    // The empty variants are dropped on the way out because `**/` alone reads
    // as one and `Glob` refuses it. That removal took a pattern somebody
    // actually wrote with it: `include: ['']` contributed no glob at all and
    // surfaced as "the set expands to nothing", about a cause the sentence
    // does not name. Handed back, it reaches `Glob` and gets its own.
    expect(zeroOrMoreDirectories(''), {''});
    expect(
      () => Glob('', context: p.posix),
      throwsA(isA<FormatException>()),
      reason: 'which is the refusal the reader is meant to get',
    );
  });

  test('and an alternative that is only a globstar is never emptied', () {
    // `{**/,b}` dropped to `{,b}`, which `package:glob` builds and then
    // throws `Bad state: No element` from at match time — a StateError, past
    // the FormatException guard, so exit 255. The check was asked of the text
    // before the globstar, which after the first segment no longer holds the
    // `{`: `{**/**/,b}` reached it with nothing to look at and built `{,b}`
    // anyway.
    for (final pattern in ['{**/,b}', '{**/**/,b}', '{a,**/**/}']) {
      for (final reading in zeroOrMoreDirectories(pattern)) {
        expect(
          () => Glob(reading).matches('x'),
          returnsNormally,
          reason: '$pattern produced `$reading`, which Glob cannot match',
        );
      }
    }
  });

  test(
    'and a pattern whose readings collapse is not refused for its shape',
    () {
      // Counting globstars and calling it `2^n` refused this: six of them, so
      // sixty-four readings by that arithmetic. Dropping one adjacent globstar
      // and dropping the next produce the same string, so there are seven.
      expect(zeroOrMoreDirectories('a/**/**/**/**/**/**/b'), hasLength(7));
    },
  );

  test('a pattern with too many readings is refused, not matched', () {
    // Each `**/` doubles them, because it means none OR more directories, and
    // every reading becomes a glob matched against every entry of the walk:
    // eight globstars is 256 globs per file, ten is over a thousand. One line
    // of the file, unbounded work.
    final root = tempRepo('many');
    final wild = '${'**/x/' * 8}*.dart';
    expect(
      () => SetExpander(root: root.path).expand(
        's',
        GlobSet(include: [wild], exclude: const []),
      ),
      throwsA(
        isA<XtaskFormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains('readings'), contains('set `s`')),
        ),
      ),
    );
  });

  group('a directory that cannot be read is refused, not passed over', () {
    test('because a set that is quietly short is a gate that checked less', () {
      // Unhandled, this left `--validate` on a stack trace and exit 255 — a
      // number §5.3 does not have — from the one gate the README tells every
      // project to put in CI.
      final root = Directory.systemTemp.createTempSync('xtask_locked_');
      final locked = Directory(p.join(root.path, 'src', 'shut'))
        ..createSync(recursive: true);
      File(p.join(root.path, 'src', 'a.dart')).writeAsStringSync('');
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() {
        Process.runSync('chmod', ['755', locked.path]);
        root.deleteSync(recursive: true);
      });

      expect(
        () => SetExpander(root: root.path).expand(
          's',
          const GlobSet(include: ['src/**.dart'], exclude: []),
        ),
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('cannot be read'), contains('src/shut')),
          ),
        ),
      );
    }, testOn: '!windows');
  });

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
    root = tempRepo('sets');
  });

  group('a list set', () {
    test('is the members, as written', () {
      final members = expander().expand('s', const ListSet(['b', 'a', 'c']));
      expect(members, ['b', 'a', 'c']);
    });

    test('refuses a written member that leaves the repository', () {
      // The glob arm had refused this since it was written; the list arm never
      // met the check at all, so these reached a working directory and a verb
      // that deletes with nothing said about them.
      //
      // Windows spellings included, because a fence read only as POSIX is not
      // a fence on the machine that writes `..\..` — and every caller joins
      // what comes back with the platform's own `p.join`.
      const escapes = [
        '/etc',
        '../..',
        r'C:\Windows',
        'C:relative',
        r'..\..',
        r'\foo',
        r'\\server\share',
        r'a\..\b',
      ];
      for (final member in escapes) {
        expect(
          refusalOf(() => expander().expand('s', ListSet([member]))),
          contains('reaches outside the repository'),
          reason: member,
        );
      }
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
    // a monorepo's own pattern is written expecting that. The failure
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

    test('a globstar starting a brace alternative reads as none-or-more', () {
      // `{templates,packages}/**/*.lake` is the shape the README writes, and
      // it was fine — the globstar there follows a `/`. This is the other
      // shape, where each alternative is its own pattern and the globstar
      // begins one: nothing preceded it with a slash, so the correction
      // skipped it and the set matched every nested file and no root one.
      given(['top.lake', 'deep/nested.lake', 'top.yaml', 'deep/nested.yaml']);
      expect(
        expandGlob(['{**/*.lake,**/*.yaml}']),
        containsAll([
          'top.lake',
          'deep/nested.lake',
          'top.yaml',
          'deep/nested.yaml',
        ]),
      );
    });

    test('a globstar that IS a brace alternative is left alone', () {
      // The zero-directory reading of `{**/,b}` is `{,b}` — an empty
      // alternative, which `package:glob` builds without complaint and then
      // throws `Bad state: No element` from at MATCH time, past the
      // `FormatException` guard that catches a malformed pattern. A variant
      // this engine invents must not be one the file could not have written.
      given(['a.dart', 'deep/a.dart']);
      expect(
        () => expandGlob(['{**/,b}*.dart']),
        returnsNormally,
        reason: 'it crashed the whole run, past every exit code',
      );
    });

    test('a comma outside braces is an ordinary character', () {
      // `,` starts an alternative only INSIDE a group. Outside one it is
      // text, and reading it as a segment start invented `data/a,b` for
      // `data/a,**/b` — a variant OR'd into the match and fed to a verb that
      // deletes.
      given(['data/a,b', 'data/a,deep/b']);
      expect(expandGlob(['data/a,**/b']), ['data/a,deep/b']);
    });

    test('`**` inside a segment still reaches what it matches', () {
      // `package:glob` lets `**` cross `/` wherever it appears, and
      // `lib/**.dart` is the shape this repository's own example ships.
      // Reading it as a whole segment pruned `lib/src` out of the walk and
      // lost every nested match — silently, since the set stays non-empty and
      // the gate just checks fewer files.
      given(['lib/a.dart', 'lib/src/b.dart']);
      expect(expandGlob(['lib/**.dart']), ['lib/a.dart', 'lib/src/b.dart']);
    });

    test('a prefix that will not compile is read as `keep going`', () {
      // Valid as a whole, split across an escape. Unreadable here, so it must
      // not be read as "no" — the alternative is a scanner exception out of
      // `expand`, past the exit codes.
      given(['a/b/c.dart']);
      expect(() => expandGlob([r'a\/b/*.dart']), returnsNormally);
    });

    test('a directory no include pattern could reach is not entered', () {
      // Observable rather than asserted about: a directory the walk cannot
      // read at all. Entering it throws; pruning it does not. Include
      // patterns were used to match and never to prune, so a set over `src`
      // walked all of `node_modules` and all of `.git` to find nothing there
      // by construction.
      given(['src/a.dart', 'node_modules/deep/b.dart']);
      final shut = Directory(p.join(root.path, 'node_modules'));
      Process.runSync('chmod', ['000', shut.path]);
      addTearDown(() => Process.runSync('chmod', ['755', shut.path]));

      expect(expandGlob(['src/**/*.dart']), ['src/a.dart']);
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
      // `[` rather than `*`: Windows will not create a file named `a*b`, so
      // the case could only have been skipped there — and Windows is exactly
      // where `\` being the escape is worth asserting, since it is also the
      // separator.
      given(['a[b.lake', 'axb.lake']);
      expect(expandGlob([r'a\[b.lake']), ['a[b.lake']);
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

  group('a value set holds what is not a path', () {
    test('and is never asked whether it leaves the repository', () {
      // That question refused `a:b` for looking like a Windows drive, and it
      // means nothing at all about `dev` or `stable`.
      expect(
        expander().expand('flavours', const ValueSet(['dev', 'a:b', '/etc'])),
        ['dev', 'a:b', '/etc'],
      );
    });

    test('and is never matched on disk', () {
      // No file called `dev` exists here, and the set is still its members.
      expect(
        expander().expand('f', const ValueSet(['dev', 'prod'])),
        ['dev', 'prod'],
      );
    });

    test('but empty is still an error, for the reason it always was', () {
      expect(
        () => expander().expand('f', const ValueSet([])),
        throwsA(isA<XtaskFormatException>()),
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
