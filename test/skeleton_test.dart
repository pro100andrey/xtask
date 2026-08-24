import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/xtask.dart';

void main() {
  group('dart run :xtask', () {
    // The claim this proves, and the reason it is a subprocess rather than a
    // direct call: §7 says the command is `dart run :xtask`, and that resolves
    // through `bin/xtask.dart` by file name alone. Calling `runXtask`
    // in-process would pass even if bin/ were empty or misnamed — which is
    // precisely the failure the sentence in §7 would then be hiding.
    //
    // `Platform.resolvedExecutable` is the Dart running this test, so the test
    // does not itself depend on `dart` being resolvable on PATH. That question
    // is §5.4's, and it belongs to the `resolve` slice, not to this one.
    Future<ProcessResult> xtask(List<String> args) => Process.run(
      Platform.resolvedExecutable,
      ['run', ':xtask', ...args],
      workingDirectory: Directory.current.path,
    );

    test("reaches this package, and its usage is §7's", () async {
      final run = await xtask(['--help']);
      expect(run.exitCode, 0);
      expect(run.stdout, contains('xtask --validate'));
      expect(run.stdout, contains('xtask --dry-run <task>'));
    });

    test('and carries the answer out to the process exit code', () async {
      // The entry point has to USE the answer. `bin/xtask.dart` assigns it to
      // `exitCode`; a consumer that writes `=> runXtask(args)` — as §9's own
      // snippet used to — discards it and exits 0 for every outcome.
      //
      // An invocation asking for nothing is the cheapest refusal there is, and
      // §5.3 gives it 2 rather than 1: a 1 would send somebody looking for the
      // task that failed.
      final run = await xtask([]);
      expect(run.exitCode, 2);
      expect(run.stderr, contains('usage:'));
    });
  });

  group('a task is a section in the shipped binary, not only in a test', () {
    // The one claim that cannot be made in-process. §7.1 says a CI job is one
    // invocation and each task folds — which needs the `::group::` line to
    // reach the stream BEFORE the body's own output. The engine writes through
    // Dart's `stdout`, which is asynchronous when it is a pipe (what it is on
    // a runner), while the body inherits the descriptor and writes to it
    // directly. Nothing in-process can tell those two apart; a real subprocess
    // with a real pipe can.
    late Directory root;
    late ProcessResult run;

    setUpAll(() async {
      root = Directory.systemTemp.createTempSync('xtask_grouped_');
      File(p.join(root.path, 'xtask.yaml')).writeAsStringSync(
        'version: 1\n'
        'tasks:\n'
        '  version:\n'
        '    desc: print the toolchain\n'
        // Single-quoted, and that is not a style choice: a double-quoted
        // YAML scalar reads `\` as an escape, so a Windows path arrives as
        // `C:hostedtoolcachewindows...` with `\x64` swallowed as a hex
        // escape. The test written to prove Windows grouping was broken by
        // Windows quoting.
        "    run: ['${Platform.resolvedExecutable}', --version]\n",
      );
      run = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          p.join(Directory.current.path, 'bin', 'xtask.dart'),
          'version',
        ],
        workingDirectory: root.path,
        environment: {'GITHUB_ACTIONS': 'true'},
      );
    });

    tearDownAll(() => root.deleteSync(recursive: true));

    test('and the marker arrives before the output it folds', () {
      final output = run.stdout as String;
      expect(run.exitCode, 0, reason: output + (run.stderr as String));
      expect(output, contains('::group::version'));
      expect(
        output.indexOf('::group::version'),
        lessThan(output.indexOf('Dart SDK version')),
        reason: 'a group that opens after its content folds the wrong thing',
      );
      expect(
        output.indexOf('Dart SDK version'),
        lessThan(output.indexOf('::endgroup::')),
      );
    });
  });

  group('a parallel run of real processes survives its own stdout', () {
    // The other claim no fake can make. `stdout.flush()` marks the sink bound
    // for as long as it is in flight, so a task ending and writing its
    // buffered block while another task is starting threw `Bad state:
    // StreamSink is bound to a stream` and took the whole run with it. Every
    // test above uses a fake starter and a list for a log, and none of them
    // has a sink to bind.
    //
    // The engine now flushes only where the flush is for — a child that
    // inherits the descriptor, which is a run that is not parallel at all.
    late Directory root;
    late ProcessResult run;

    setUpAll(() async {
      root = Directory.systemTemp.createTempSync('xtask_parallel_');
      final dart = Platform.resolvedExecutable;
      File(p.join(root.path, 'xtask.yaml')).writeAsStringSync(
        'version: 1\n'
        'tasks:\n'
        '  one:\n'
        '    desc: first\n'
        '    gate: [both]\n'
        "    run: ['$dart', --version]\n"
        '  two:\n'
        '    desc: second\n'
        '    gate: [both]\n'
        "    run: ['$dart', --version]\n"
        '  both:\n'
        '    desc: everything\n'
        '    collects: both\n',
      );
      run = await Process.run(dart, [
        'run',
        p.join(Directory.current.path, 'bin', 'xtask.dart'),
        'both',
        '--parallel',
      ], workingDirectory: root.path);
    });

    tearDownAll(() => root.deleteSync(recursive: true));

    test('it does not die of its own bookkeeping', () {
      final output = run.stdout as String;
      expect(
        run.stderr,
        isNot(contains('StreamSink')),
        reason: 'the run crashed writing its own output',
      );
      expect(run.exitCode, 0, reason: output + (run.stderr as String));
    });

    test('and both tasks are in the transcript, whole', () {
      final output = run.stdout as String;
      expect(output, contains('── one ──'));
      expect(output, contains('── two ──'));
      expect(
        output,
        contains('up to'),
        reason: 'a parallel run says so before it goes quiet',
      );
    });
  });

  group('runXtask is the whole public surface (§9)', () {
    // In-process, because what is being asserted is the function a consumer
    // calls rather than the file it is called from.
    late Directory root;
    late String previous;

    setUp(() {
      root = Directory.systemTemp.createTempSync('xtask_public_');
      previous = Directory.current.path;
      Directory.current = root;
    });

    tearDown(() {
      Directory.current = previous;
      root.deleteSync(recursive: true);
    });

    test(
      'a project with no verbs still gets the built-ins and the file',
      () async {
        File(p.join(root.path, 'xtask.yaml')).writeAsStringSync(
          'version: 1\ntasks:\n  a: {desc: x, do: remove, args: [gone]}\n',
        );
        expect(await runXtask(['--validate']), 0);
      },
    );

    test(
      'and a directory with no file is refused, not assumed empty',
      () async {
        // The outcome §7.1 makes dangerous: a CI job is one invocation, so a 0
        // from an xtask that found nothing to do is a permanently green job.
        expect(await runXtask(['a']), 2);
      },
    );
  });
}
