/// Two facts about the source that no type and no lint can hold.
///
/// Both are true today and neither is enforced by anything else: the analyzer
/// cannot express "only this file may print", and the type system cannot say
/// "this integer came from §5.3". They are asserted by reading the source
/// because that is the only place they are visible — which makes this the
/// cheap half of what a custom analyzer plugin would cost, and the half that
/// runs in the gate that already exists.
///
/// Each is written as an EQUALITY against a declared exception, the same shape
/// `dogfood_test.dart` uses: a new offender fails, and so does an exception
/// left behind after the thing it excused is gone.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/cli.dart';

void main() {
  late Map<String, String> sources;

  setUpAll(() {
    final root = findRoot(Directory.current.path)!;
    // Everything that ships, not just `lib/`. The omission was not free once:
    // the entry point went on naming the deleted design document for a day
    // after every other file stopped, because it was the one source outside
    // `lib/` — and it is the file the README tells every consumer to copy.
    // `example/` is here for the same reason, one step further: it is written
    // to be copied.
    sources = {
      for (final directory in ['lib', 'bin', 'example'])
        for (final file in Directory(
          p.join(root, directory),
        ).listSync(recursive: true).whereType<File>())
          if (file.path.endsWith('.dart'))
            // Joined with `/` whatever the host uses, because the exception
            // below is written once and read on three platforms.
            p.posix.joinAll(p.split(p.relative(file.path, from: root))): file
                .readAsStringSync(),
    };
    expect(sources, isNotEmpty, reason: 'no sources were read at all');
  });

  test('the terminal has one author, and one file that only flushes it', () {
    // Everything else takes a `log` callback, which is what lets the whole of
    // `report.dart` be tested by calling it. The day a module reaches for
    // `stdout` directly is the day its output stops being observable, and it
    // will look like a one-line convenience when it happens.
    //
    // `exec.dart` is here for a `stdout.flush()` and nothing else: Dart's
    // stdout is asynchronous when it is a pipe, so a run that ends without
    // flushing loses its last lines in CI and not on a terminal. That is a
    // fact about the process ending, not a second place that decides what to
    // say.
    const allowed = {'lib/xtask.dart', 'lib/src/exec.dart'};
    final writers = {
      for (final MapEntry(key: file, value: source) in sources.entries)
        if (RegExp(r'\b(stdout|stderr)\.|(?<![.\w])print\(').hasMatch(source))
          file,
    };
    expect(
      writers,
      allowed,
      reason:
          'a module reached for the terminal directly. Take a `log` callback '
          'instead, or add the file above with the reason it cannot',
    );
  });

  test('and no message sends a reader to a document they do not have', () {
    // Eleven messages used to end in `(§9)`, `(§4.1)` or a bare `R1` — a
    // citation of the design document this was written against. It was never
    // in the clone and is now not anywhere: the numbering survives only in
    // the comments, as the coordinates of the reasoning they were written
    // beside.
    //
    // A comment is read by somebody holding the source and can be read as
    // that. A message is read by somebody holding a failed command, and a
    // pointer they cannot follow is a dead end at the worst moment.
    final citation = RegExp(r"'[^']*(§|\bR[123]\b)");
    final offenders = {
      for (final MapEntry(key: file, value: source) in sources.entries)
        for (final line in source.split('\n'))
          if (!line.trimLeft().startsWith('//') && citation.hasMatch(line))
            file,
    };
    expect(
      offenders,
      isEmpty,
      reason:
          'a message cites a section of a document the reader has no copy of. '
          'Say the thing instead — the sentence is usually already complete '
          'without it',
    );
  });

  test('and nothing names the design document, which no longer exists', () {
    // Nineteen doc comments pointed at `xtask.md`, one of them the library
    // header that pub.dev renders — telling a consumer to read a file that
    // was never in the archive and is now not in the repository either.
    //
    // Narrower than the citation guard above and for a different reason: a
    // section number is a coordinate that can be read as one, while a file
    // name is a claim that the file is there. This one holds in comments too.
    final named = {
      for (final MapEntry(key: file, value: source) in sources.entries)
        if (source.contains('xtask.md')) file,
    };
    expect(
      named,
      isEmpty,
      reason: 'this file is gone; say the thing rather than pointing at it',
    );
  });

  test('an exit code is never a number written at the place it is used', () {
    // §5.3 gives five codes and a paragraph each. A bare `return 2;` is the
    // same value with the paragraph deleted, and the deletion is invisible:
    // it reads like arithmetic and reviews like nothing at all.
    // Line by line, and comment lines dropped — the first version read the
    // whole file and reported `lib/xtask.dart` for a comment that QUOTED
    // `return 0;` while explaining why not to write it. A guard that cannot
    // tell code from prose about code is a guard nobody keeps.
    final literal = RegExp(r'\breturn -?\d+;|\bexit\(-?\d+\)');
    final offenders = {
      for (final MapEntry(key: file, value: source) in sources.entries)
        if (file != 'lib/src/exit_codes.dart')
          for (final line in source.split('\n'))
            if (!line.trimLeft().startsWith('//') && literal.hasMatch(line))
              file,
    };
    expect(
      offenders,
      isEmpty,
      reason:
          'name the code from `ExitCode` — the constant carries the reason '
          '§5.3 gives it, and the number does not',
    );
  });
}
