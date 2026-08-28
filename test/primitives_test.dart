import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/primitives.dart';

void main() {
  late Directory root;
  late List<String> logged;

  setUp(() {
    root = Directory.systemTemp.createTempSync('xtask_remove_');
    logged = [];
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  void given(List<String> paths) {
    for (final path in paths) {
      File(p.join(root.path, p.joinAll(p.posix.split(path))))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');
    }
  }

  bool exists(String path) =>
      FileSystemEntity.typeSync(
        p.join(root.path, p.joinAll(p.posix.split(path))),
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound;

  Future<int> remove(List<String> args) => removeVerb(
    VerbContext(
      args: args,
      env: const {},
      workingDirectory: root.path,
      log: logged.add,
      start: (_, {workingDirectory}) async =>
          throw StateError('`remove` starts nothing'),
    ),
    root: root.path,
  );

  group('deletes what it is given', () {
    test('a file', () async {
      given(['build/out.js', 'keep.txt']);
      expect(await remove(['build/out.js']), ExitCode.success);
      expect(exists('build/out.js'), isFalse);
      expect(exists('keep.txt'), isTrue);
    });

    test('a directory, recursively', () async {
      given(['out/a.js', 'out/deep/b.js']);
      expect(await remove(['out']), ExitCode.success);
      expect(exists('out'), isFalse);
    });

    test('several arguments, each of them', () async {
      given(['a.txt', 'b.txt', 'c.txt']);
      await remove(['a.txt', 'b.txt']);
      expect(exists('a.txt'), isFalse);
      expect(exists('b.txt'), isFalse);
      expect(exists('c.txt'), isTrue);
    });

    test(
      'and says what it removed, because silence reads as success',
      () async {
        given(['out/a.js']);
        await remove(['out']);
        expect(logged.join('\n'), contains('removed'));
        expect(logged.join('\n'), contains('out'));
      },
    );
  });

  group('a path that is not there is not an error', () {
    test('a plain name', () async {
      expect(await remove(['never-existed']), ExitCode.success);
    });

    test('and so `clean` can run twice, which is the whole point', () async {
      // The reading of §6 this verb takes, stated as a test because the
      // section can be read the other way. `clean` names build output that is
      // usually already gone; a second run must not fail.
      given(['vscode/out/a.js', 'vscode/plugin.vsix']);
      expect(await remove(['vscode/out', 'vscode/*.vsix']), ExitCode.success);
      expect(await remove(['vscode/out', 'vscode/*.vsix']), ExitCode.success);
    });

    test('a glob matching nothing is not an error either', () async {
      // The other half of the §6 reading. A NAMED SET expanding to nothing is
      // an error (§4.2) because a task given no files checked nothing; a
      // pattern among THIS verb's arguments matching nothing is not, because
      // "delete what is there" is satisfied by there being nothing.
      given(['keep.txt']);
      expect(await remove(['*.vsix']), ExitCode.success);
      expect(exists('keep.txt'), isTrue);
    });
  });

  group('globs are expanded by the engine, not by a shell', () {
    test('a star matches within one directory', () async {
      given(['vscode/a.vsix', 'vscode/b.vsix', 'vscode/keep.js']);
      await remove(['vscode/*.vsix']);
      expect(exists('vscode/a.vsix'), isFalse);
      expect(exists('vscode/b.vsix'), isFalse);
      expect(exists('vscode/keep.js'), isTrue);
    });

    test('`**/` reads as none-or-more here too, not one-or-more', () async {
      // The divergence this closes: `sets:` corrected `package:glob`'s
      // reading of `**/` and this verb did not, so the same pattern in the
      // same file matched a different set of paths depending on which key it
      // was written under. `packages/coverage` is the case that tells them
      // apart — one-or-more never reaches it.
      given([
        'packages/coverage/f',
        'packages/one/coverage/f',
        'packages/one/lib/keep.dart',
      ]);
      await remove(['packages/**/coverage']);
      expect(exists('packages/coverage'), isFalse);
      expect(exists('packages/one/coverage'), isFalse);
      expect(exists('packages/one/lib/keep.dart'), isTrue);
    });

    test('a star in the middle matches directories', () async {
      // §12's `packages/*/coverage`, which is the reason this has to reach
      // directories and not only files.
      given([
        'packages/one/coverage/f',
        'packages/two/coverage/f',
        'packages/one/lib/keep.dart',
      ]);
      await remove(['packages/*/coverage']);
      expect(exists('packages/one/coverage'), isFalse);
      expect(exists('packages/two/coverage'), isFalse);
      expect(exists('packages/one/lib/keep.dart'), isTrue);
    });

    test('a literal that looks like a path is not globbed', () async {
      // `[` rather than `*`, and that is the whole reason: Windows refuses
      // `*` in a file name, so a fixture built on it cannot exist there and
      // the assertion could only ever have been skipped. `[` is a glob
      // metacharacter on every platform and a legal name character on every
      // platform, which is what lets this run where it matters — on the host
      // whose own separator is the escape character.
      given(['a[b.txt']);
      await remove([r'a\[b.txt']);
      expect(exists('a[b.txt'), isFalse);
    });
  });

  group('a symlink is removed, never followed', () {
    test('the link goes and its target stays', () async {
      given(['real/keep.txt']);
      Link(p.join(root.path, 'alias')).createSync(p.join(root.path, 'real'));
      expect(await remove(['alias']), ExitCode.success);
      expect(exists('alias'), isFalse);
      expect(
        exists('real/keep.txt'),
        isTrue,
        reason: 'following it would have deleted the target directory',
      );
    });

    test('a BROKEN link is removed, not read as an absent path', () async {
      // The one case where following or not following is visible on POSIX.
      // Dart's own Directory.delete already leaves a live link's target
      // alone, so the explicit branch is defence there rather than something
      // this suite could catch you removing — but a dangling link answers
      // `notFound` to a following lookup, and would survive `clean` forever.
      Link(p.join(root.path, 'dangling')).createSync(
        p.join(root.path, 'gone'),
      );
      expect(await remove(['dangling']), ExitCode.success);
      expect(exists('dangling'), isFalse);
    });

    test('a link matched by a glob goes the same way', () async {
      given(['real/keep.txt']);
      Link(p.join(root.path, 'a.vsix')).createSync(p.join(root.path, 'real'));
      await remove(['*.vsix']);
      expect(exists('a.vsix'), isFalse);
      expect(exists('real/keep.txt'), isTrue);
    });
  });

  group('it refuses to reach outside the repository', () {
    // The check that matters most in the whole file: this is the verb that
    // deletes recursively, and §6's "a missing path is not an error" means a
    // path taken on trust would be followed without a word.
    test('an absolute path', () async {
      final outside = Directory.systemTemp.createTempSync('xtask_outside_');
      addTearDown(() => outside.deleteSync(recursive: true));
      expect(await remove([outside.path]), ExitCode.invalidFile);
      expect(outside.existsSync(), isTrue);
      expect(logged.join('\n'), contains('outside the repository'));
    });

    test('a path climbing through `..`', () async {
      final sibling = Directory(p.join(root.parent.path, 'xtask_sibling_probe'))
        ..createSync();
      addTearDown(() => sibling.deleteSync(recursive: true));
      final code = await remove(['../${p.basename(sibling.path)}']);
      expect(code, ExitCode.invalidFile);
      expect(sibling.existsSync(), isTrue);
    });

    test('a Windows absolute path', () async {
      expect(await remove([r'C:\Windows']), ExitCode.invalidFile);
    });

    test(
      'and it refuses BEFORE deleting anything else in the same call',
      () async {
        given(['a.txt']);
        final code = await remove(['/etc', 'a.txt']);
        expect(code, ExitCode.invalidFile);
        expect(
          exists('a.txt'),
          isTrue,
          reason: 'the call stopped at the refusal',
        );
      },
    );
  });

  group('the walk is pruned, as `sets:` prunes it', () {
    test('a subtree no pattern can reach is not read', () {
      // Not a timing assertion — the point is that the ANSWER is unchanged
      // while the reading is not. Include patterns were used to match and
      // never to prune here, so `do: remove build/**` read all of
      // `node_modules` and all of `.git` on every invocation to find nothing
      // there by construction: 0.19s against 0.01s on eighteen thousand files.
      given([
        'build/out/a.o',
        'build/keep/b.o',
        'node_modules/pkg/lib/src/deep.js',
        '.git/objects/ab/cdef',
      ]);
      // The directories themselves, not their contents: a match is about to
      // be deleted whole, so the walk does not descend into one.
      expect(pathsMatching('build/**', root: root.path), [
        'build/keep',
        'build/out',
      ]);
    });

    test('and a pattern that can reach anywhere still does', () {
      given(['a/b/c/x.tmp', 'y.tmp', 'node_modules/pkg/z.tmp']);
      expect(pathsMatching('**/*.tmp', root: root.path), [
        'a/b/c/x.tmp',
        'node_modules/pkg/z.tmp',
        'y.tmp',
      ]);
    });
  });

  group('a pattern that will not compile is a sentence, not a stack trace', () {
    test('the verb says which argument and why', () async {
      // Uncaught, `[` left the verb as a raw `FormatException` whose "line 1,
      // column 2" points inside the pattern string rather than at anything in
      // the file — reported as "task threw FormatException", which sends the
      // reader to look at this engine.
      given(['a.txt']);
      expect(await remove(['a{b']), ExitCode.invalidFile);
      expect(logged.join('\n'), contains('a{b'));
      expect(logged.join('\n'), contains('not a valid pattern'));
      expect(exists('a.txt'), isTrue, reason: 'it deleted something anyway');
    });
  });

  group('what a dry run may say it would delete', () {
    test('is what is on disk, and nothing that is not', () {
      given(['build/out/a.o', 'keep.txt']);
      expect(
        removeWouldDelete(['build', 'coverage', 'keep.txt'], root: root.path),
        ['build', 'keep.txt'],
        reason: '`coverage` is not there, and a missing path is not deleted',
      );
    });

    test('and nothing at all where the run would refuse', () {
      given(['a.txt']);
      expect(removeWouldDelete(['../etc'], root: root.path), isEmpty);
      expect(removeWouldDelete(['a{b'], root: root.path), isEmpty);
    });

    test('and it deletes nothing itself', () {
      given(['build/out/a.o']);
      removeWouldDelete(['build'], root: root.path);
      expect(exists('build/out/a.o'), isTrue);
    });
  });

  group('a delete that could not happen', () {
    test('is a sentence about the path, not about the verb', () async {
      // Unguarded, a permission error came out through the general handler as
      // "the project's own verb threw PathAccessException", which sends the
      // reader to look at a verb the engine ships.
      given(['build/inner/f.txt']);
      final build = Directory(p.join(root.path, 'build'));
      Process.runSync('chmod', ['500', build.path]);
      addTearDown(() => Process.runSync('chmod', ['755', build.path]));

      await expectLater(
        remove(['build']),
        throwsA(
          isA<RunFailure>().having(
            (f) => f.message,
            'message',
            allOf(contains('could not delete'), contains('build')),
          ),
        ),
      );
      expect(
        logged.join('\n'),
        isNot(contains('removed')),
        reason: 'it announced a deletion that did not happen',
      );
    }, testOn: '!windows');
  });

  group('the closed list §6 promises', () {
    test('is exactly one verb', () {
      expect(builtInVerbNames, {'remove'});
    });

    test('and what is bound matches what is named', () {
      // Two lists of the same thing would be the defect §1 exists to remove,
      // and this is the pair most likely to drift: a primitive added to the
      // map and forgotten in the set is one `--validate` would then refuse.
      expect(builtInVerbs(root: root.path).keys.toSet(), builtInVerbNames);
    });
  });
}
