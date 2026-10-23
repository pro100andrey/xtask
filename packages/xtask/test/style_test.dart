import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/cli.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/executables.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/markers.dart';
import 'package:xtask/src/model.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/report.dart';
import 'package:xtask/src/request.dart';
import 'package:xtask/src/style.dart';

import 'helpers.dart';

/// Starts nothing, and every program it is asked for passes.
final class _Starter implements ProcessStarter {
  const _Starter();

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
  }) async => ExitCode.success;

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
  }) async => (exitCode: ExitCode.success, stdout: '', stderr: '');
}

const _escape = '\x1B[';

/// [line] as it reads with every colour code taken out.
String _uncoloured(String line) =>
    line.replaceAll(RegExp('\x1B\\[[0-9;]*m'), '');

void main() {
  group('the style is chosen from what stdout is and what was asked', () {
    // A terminal an ordinary emulator describes, unless a test says what
    // else it is.
    Style choose({
      Map<String, String> environment = const {},
      String? term = 'xterm-256color',
      bool terminal = true,
      bool ansiEscapes = true,
      bool windows = false,
    }) => Style.choose(
      environment: {'TERM': ?term, ...environment},
      terminal: terminal,
      ansiEscapes: ansiEscapes,
      windows: windows,
    );

    test('a terminal that draws ANSI is given colour', () {
      expect(choose().coloured, isTrue);
      expect(choose().glyphs, Glyphs.unicode);
    });

    test('a pipe or a file is given exactly what it always was', () {
      final piped = choose(terminal: false, ansiEscapes: false);
      expect(piped.coloured, isFalse);
      expect(piped.glyphs, Glyphs.unicode);
      // A pipe on Windows too: it is a file a program reads, not a console
      // that cannot draw a glyph.
      expect(
        choose(terminal: false, ansiEscapes: false, windows: true).glyphs,
        Glyphs.unicode,
      );
    });

    test("a POSIX terminal is coloured by its TERM, not by Dart's list", () {
      // Dart's `supportsAnsiEscapes` is false for these, measured on a pty,
      // and every one of them draws ANSI colour.
      for (final term in ['linux', 'foot', 'alacritty', 'xterm-kitty']) {
        expect(
          choose(term: term, ansiEscapes: false).coloured,
          isTrue,
          reason: 'TERM=$term',
        );
      }
      // `TERM=dumb`, or none at all: a terminal that says it draws nothing.
      for (final term in ['dumb', '', null]) {
        expect(
          choose(term: term).coloured,
          isFalse,
          reason: 'TERM=$term',
        );
        // No escapes, but UTF-8 all the same.
        expect(choose(term: term).glyphs, Glyphs.unicode);
      }
    });

    test('a Windows console is coloured by whether it draws ANSI', () {
      expect(choose(term: null, windows: true).coloured, isTrue);
      expect(choose(ansiEscapes: false, windows: true).coloured, isFalse);
    });

    test("Windows' legacy console is given ASCII, as marks and branches", () {
      final legacy = choose(ansiEscapes: false, windows: true);
      expect(legacy.coloured, isFalse);
      expect(legacy.glyphs, Glyphs.ascii);
      // Windows Terminal, and a console with VT processing on, draw both.
      expect(choose(windows: true).glyphs, Glyphs.unicode);
    });

    test('NO_COLOR, set to anything, takes colour away', () {
      expect(choose(environment: {'NO_COLOR': '1'}).coloured, isFalse);
      expect(choose(environment: {'NO_COLOR': 'false'}).coloured, isFalse);
      // Empty is unset, as no-color.org says.
      expect(choose(environment: {'NO_COLOR': ''}).coloured, isTrue);
    });

    test('FORCE_COLOR colours a pipe, and NO_COLOR still wins', () {
      final forced = choose(
        environment: {'FORCE_COLOR': '1'},
        terminal: false,
        ansiEscapes: false,
      );
      expect(forced.coloured, isTrue);
      expect(forced.glyphs, Glyphs.unicode);
      expect(
        choose(
          environment: {'FORCE_COLOR': '1', 'NO_COLOR': '1'},
          terminal: false,
        ).coloured,
        isFalse,
      );
      // Empty is unset, as it is for NO_COLOR.
      expect(
        choose(environment: {'FORCE_COLOR': ''}, terminal: false).coloured,
        isFalse,
      );
      expect(choose(environment: {'FORCE_COLOR': ''}).coloured, isTrue);
    });

    test('FORCE_COLOR=0 or false takes colour away, as Node reads it', () {
      for (final off in ['0', 'false']) {
        for (final terminal in [true, false]) {
          expect(
            choose(
              environment: {'FORCE_COLOR': off},
              terminal: terminal,
            ).coloured,
            isFalse,
            reason: 'FORCE_COLOR=$off, terminal: $terminal',
          );
        }
      }
      expect(choose(environment: {'FORCE_COLOR': 'true'}).coloured, isTrue);
    });

    test('FORCE_COLOR does not colour the legacy console', () {
      // Its escapes would be printed as text: `←[32m` before every mark.
      final legacy = choose(
        environment: {'FORCE_COLOR': '1'},
        ansiEscapes: false,
        windows: true,
      );
      expect(legacy.coloured, isFalse);
      expect(legacy.glyphs, Glyphs.ascii);
    });
  });

  group('colour is drawn around fragments, not into them', () {
    test('a fragment is wrapped, and an empty one is left alone', () {
      expect(Style.ansi.paint('✓', Tint.passed), '\x1B[32m✓\x1B[0m');
      expect(Style.ansi.paint('', Tint.passed), '');
      expect(Style.plain.paint('✓', Tint.passed), '✓');
    });

    final run = (
      tasks: [
        const Ended('format', Result.passed, took: Duration(milliseconds: 400)),
        const Ended(
          'test',
          Result.failed,
          took: Duration(milliseconds: 2500),
          code: 1,
        ),
        const Ended(
          'publish',
          Result.skipped,
          why: 'needs `test`, which did not pass',
        ),
        const Ended('install', Result.notRun),
      ],
      took: const Duration(seconds: 3),
    );

    test('the summary: marks by result, the code red, times faint', () {
      final lines = summary(run, concurrent: false, style: Style.ansi);
      expect(lines, contains(startsWith('\x1B[32m✓\x1B[0m format')));
      expect(lines, contains(startsWith('\x1B[31m✗\x1B[0m test')));
      expect(lines, contains(endsWith('\x1B[31mexit 1\x1B[0m')));
      expect(lines, contains(startsWith('\x1B[33m⊘\x1B[0m publish')));
      expect(lines, contains(startsWith('\x1B[2m·\x1B[0m install')));
      expect(lines, contains(contains('\x1B[2m0.4s\x1B[0m')));
      expect(
        lines,
        contains(endsWith('\x1B[2mneeds `test`, which did not pass\x1B[0m')),
      );
    });

    test('and with the colour taken out it is the plain summary', () {
      expect(
        summary(run, concurrent: false, style: Style.ansi).map(_uncoloured),
        summary(run, concurrent: false),
      );
    });

    test('the heading is bold; a GitHub group is never coloured', () {
      expect(const PlainMarkers().open('test', Style.ansi), [
        '\x1B[1m── test ──\x1B[0m',
      ]);
      final github = LogMarkers.forHost({'GITHUB_ACTIONS': 'true'});
      expect(github.open('test', Style.ansi), ['::group::test']);
      expect(github.error('broke'), ['::endgroup::', '::error::broke']);
    });
  });

  group('ASCII is the marks and the branches together', () {
    test('the summary marks are words of one width', () {
      final lines = summary(
        (
          tasks: [
            const Ended('a', Result.passed, took: Duration(seconds: 1)),
            const Ended('b', Result.failed, took: Duration(seconds: 1)),
            const Ended('c', Result.skipped, why: 'linux only'),
            const Ended('d', Result.notRun, took: Duration(seconds: 1)),
            const Ended('e', Result.notRun),
          ],
          took: const Duration(seconds: 3),
        ),
        concurrent: false,
        style: Style.legacy,
      );
      expect(lines.skip(1).take(5).map((line) => line.substring(0, 6)), [
        'ok   a',
        'FAIL b',
        'skip c',
        'stop d',
        '-    e',
      ]);
      expect(lines.join('\n'), isNot(contains(RegExp('[^\x00-\x7F]'))));
    });

    test("a mark is only the mark; its padding is the summary's", () {
      for (final glyphs in Glyphs.values) {
        for (final mark in [
          glyphs.passed,
          glyphs.failed,
          glyphs.skipped,
          glyphs.stopped,
          glyphs.notBegun,
        ]) {
          expect(mark, mark.trim(), reason: '${glyphs.name} "$mark"');
        }
      }
    });

    test("a member and the total begin where the task's name does", () {
      for (final style in [Style.plain, Style.legacy]) {
        final lines = summary(
          (
            tasks: [
              const Ended(
                'build',
                Result.failed,
                took: Duration(seconds: 2),
                members: [
                  Ended('a', Result.passed, took: Duration(seconds: 1)),
                  Ended(
                    'b',
                    Result.failed,
                    took: Duration(seconds: 1),
                    code: 1,
                  ),
                ],
              ),
              const Ended('lint', Result.passed, took: Duration(seconds: 1)),
            ],
            took: const Duration(seconds: 3),
          ),
          concurrent: false,
          style: style,
        );
        final name = lines[1].indexOf('build');
        expect(lines[2].indexOf(style.glyphs.passed), name, reason: lines[2]);
        expect(lines[3].indexOf(style.glyphs.failed), name, reason: lines[3]);
        expect(lines[5].indexOf('total'), name, reason: lines[5]);
        // And every time still in one column.
        final times = {
          for (final line in lines.skip(1)) line.indexOf(RegExp(r'\ds')),
        };
        expect(times, hasLength(1), reason: lines.join('\n'));
      }
    });

    test('everything the summary and the graph draw is ASCII', () {
      final file = parseXtaskFile(r'''
version: 1
sets:
  pkgs: {values: [a, b, c, d, e]}
  made: {include: ['out/*'], produced-by: gen}
tasks:
  publish: {desc: p, needs: [build, test, packs], then: [desktop], run: [dart]}
  build: {desc: b, each: pkgs, run: [dart, $each]}
  test: {desc: t, needs: [build], run: [dart]}
  gen: {desc: g, run: [dart]}
  packs: {desc: k, needs: [gen], each: made, run: [dart, $each]}
  desktop: {desc: d, platforms: [windows], run: [dart]}
''');
      final drawn = graph(
        file,
        name: 'publish',
        host: OperatingSystem.linux,
        fanOf: (task) => task.name == 'packs'
            ? const MembersNotYet('gen')
            : const Members(['a', 'b', 'c', 'd', 'e']),
        style: Style.legacy,
      );
      expect(drawn.join('\n'), contains('see above'));
      expect(drawn.join('\n'), contains('and 2 more'));
      expect(drawn.join('\n'), contains('cannot be resolved yet'));
      expect(drawn.join('\n'), contains('windows only'));
      final summed = summary(
        (
          tasks: [
            const Ended(
              'build',
              Result.notRun,
              took: Duration(seconds: 2),
              why: 'stopped after 1 of 2 members, at an earlier failure',
              members: [
                Ended('a', Result.failed, took: Duration(seconds: 1), code: 1),
                Ended('b', Result.notRun, why: 'the run ended before it began'),
              ],
            ),
            const Ended('desktop', Result.skipped, why: 'windows only'),
            const Ended(
              'test',
              Result.notRun,
              took: Duration(seconds: 1),
              why: 'stopped part-way: the run received SIGINT',
            ),
          ],
          took: const Duration(seconds: 3),
        ),
        concurrent: true,
        narrowed: const {'build': (kept: 2, of: 5)},
        style: Style.legacy,
      );
      for (final line in [
        ...drawn,
        ...summed,
        ...const PlainMarkers().open('build', Style.legacy),
      ]) {
        expect(line, isNot(contains(RegExp('[^\x00-\x7F]'))), reason: line);
      }
    });

    test('the tree, its count and its off-platform mark', () {
      final file = parseXtaskFile(r'''
version: 1
sets:
  pkgs: {values: [a, b]}
tasks:
  publish: {desc: p, needs: [build, test], then: [desktop], run: [dart]}
  build: {desc: b, each: pkgs, run: [dart, $each]}
  test: {desc: t, needs: [build], run: [dart]}
  desktop: {desc: d, platforms: [windows], run: [dart]}
''');
      expect(
        graph(
          file,
          name: 'publish',
          host: OperatingSystem.linux,
          fanOf: (_) => const Members(['a', 'b']),
          style: Style.legacy,
        ),
        [
          'publish',
          '+- needs build x2  a, b',
          '+- needs test',
          '|  `- needs build  (see above)',
          '`- then  desktop   skip windows only',
        ],
      );
      expect(const PlainMarkers().open('test', Style.legacy), ['-- test --']);
    });
  });

  group('what a program reads is never coloured', () {
    late Directory root;
    late List<String> out;
    late List<String> err;

    setUp(() {
      root = tempRepo('style');
      out = [];
      err = [];
      File(p.join(root.path, xtaskFileName)).writeAsStringSync('''
version: 1
gates: [check]
tasks:
  format: {desc: f, gate: [check], run: [dart, format]}
  test: {desc: t, gate: [check], needs: [format], run: [dart, test]}
''');
    });

    Future<int> run(List<String> args, {Map<String, String>? environment}) =>
        runCli(
          args,
          workingDirectory: root.path,
          environment: environment ?? const {},
          out: out.add,
          err: err.add,
          resolver: ExecutableResolver(
            environment: const {'PATH': '/bin'},
            windows: false,
            isRunnable: (path) => true,
          ),
          starter: const _Starter(),
          style: Style.ansi,
        );

    test('the answers a script reads', () async {
      for (final args in [
        ['--names'],
        ['--gate-members', 'check'],
        ['--emit-schema'],
        ['--check-ci'],
      ]) {
        out.clear();
        err.clear();
        await run(args);
        expect(
          [...out, ...err].join('\n'),
          isNot(contains(_escape)),
          reason: args.join(' '),
        );
      }
    });

    test('the report file, and the markers on GitHub', () async {
      expect(
        await run(
          [
            'check',
            '--report',
            'report.json',
          ],
          environment: const {'GITHUB_ACTIONS': 'true'},
        ),
        ExitCode.success,
      );
      final report = File(p.join(root.path, 'report.json')).readAsStringSync();
      expect(report, isNot(contains(_escape)));
      expect(jsonDecode(report), containsPair('complete', true));
      expect(out, contains('::group::format'));
      for (final line in out) {
        if (line.startsWith('::')) {
          expect(line, isNot(contains(_escape)));
        }
      }
      // The summary a person reads is still drawn in colour.
      expect(out, contains(startsWith('\x1B[32m✓\x1B[0m format')));
    });
  });
}
