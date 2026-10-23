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
    Style choose({
      Map<String, String> environment = const {},
      bool terminal = true,
      bool ansiEscapes = true,
      bool windows = false,
    }) => Style.choose(
      environment: environment,
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

    test('a terminal that draws no ANSI is not coloured', () {
      expect(choose(ansiEscapes: false).coloured, isFalse);
      // `TERM=dumb` on a POSIX terminal: no escapes, but UTF-8 all the same.
      expect(choose(ansiEscapes: false).glyphs, Glyphs.unicode);
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
      // `0` is how a pipeline says "not forced", as Node's tools read it.
      for (final off in ['', '0']) {
        expect(
          choose(environment: {'FORCE_COLOR': off}, terminal: false).coloured,
          isFalse,
          reason: 'FORCE_COLOR=$off',
        );
      }
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
      expect(const PlainMarkers(Style.ansi).open('test'), [
        '\x1B[1m── test ──\x1B[0m',
      ]);
      final github = LogMarkers.forHost({
        'GITHUB_ACTIONS': 'true',
      }, style: Style.ansi);
      expect(github.open('test'), ['::group::test']);
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
      expect(const PlainMarkers(Style.legacy).open('test'), ['-- test --']);
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
