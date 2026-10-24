/// A run sent a real signal: what it stops, what it answers, and what it
/// leaves behind — which must be nothing.
///
/// **POSIX only.** Windows has no `SIGTERM`, and a Ctrl-C cannot be sent to
/// one process from another; what it gets is said in
/// doc/internals-and-platforms.md.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

/// Resets SIGINT and SIGQUIT to their defaults and becomes the program named
/// after it.
///
/// **Because of where the suite may be running.** A non-interactive shell
/// starts its background jobs with SIGINT and SIGQUIT ignored, that
/// disposition is inherited across `exec`, and Dart's `watch()` on an ignored
/// signal receives nothing — so a test that sends one would be measuring how
/// the suite was launched.
const _withDefaults =
    'import os, signal, sys\n'
    'signal.signal(signal.SIGINT, signal.SIG_DFL)\n'
    'signal.signal(signal.SIGQUIT, signal.SIG_DFL)\n'
    'os.execvp(sys.argv[1], sys.argv[1:])';

/// A body that writes its pid and waits a minute. `exec`, so the pid it
/// writes is the process the engine started.
const _holds = r"run: [sh, -c, 'echo $$ > body.pid; exec sleep 60']";

void main() {
  late Directory root;

  // Every pid a test read, killed by the teardown whatever the test found:
  // a failing run must not leave the sleeps it is about behind.
  late List<int> seen;

  setUp(() {
    root = tempRepo('signals');
    seen = [];
    addTearDown(() {
      for (final pid in seen) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
    });
  });

  /// Waits for the file at [path] in the repository to hold a pid.
  Future<int> pidIn(String path) async {
    final file = File(p.join(root.path, path));
    for (var tries = 0; tries < 300; tries++) {
      if (file.existsSync()) {
        if (int.tryParse(file.readAsStringSync().trim()) case final read?) {
          seen.add(read);
          return read;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('`$path` was never written');
  }

  /// Whether process [pid] is still there, a zombie not counting.
  bool alive(int pid) {
    final status = File('/proc/$pid/status');
    if (status.existsSync()) {
      return !RegExp(r'State:\s+Z').hasMatch(status.readAsStringSync());
    }
    // Not Linux: `kill -0` answers whether the pid can be signalled.
    return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
  }

  /// The engine on [args] in the repository, through [_withDefaults].
  Future<({Process run, StringBuffer said})> engine(List<String> args) async {
    final run = await Process.start('python3', [
      '-c',
      _withDefaults,
      Platform.resolvedExecutable,
      'run',
      p.join(Directory.current.path, 'test', 'fixtures', 'engine.dart'),
      ...args,
    ], workingDirectory: root.path);
    final said = StringBuffer();
    run.stdout.transform(utf8.decoder).listen(said.write);
    run.stderr.transform(utf8.decoder).listen(said.write);
    return (run: run, said: said);
  }

  /// Sends [signal] to the engine, and answers with the code it ends with.
  Future<int> send(
    ProcessSignal signal,
    ({Process run, StringBuffer said}) engine,
  ) async {
    Process.killPid(await pidIn('engine.pid'), signal);
    return engine.run.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () => fail('the engine did not end:\n${engine.said}'),
    );
  }

  void file(String yaml) =>
      File(p.join(root.path, 'xtask.yaml')).writeAsStringSync(yaml);

  for (final (signal, code) in [
    (ProcessSignal.sigterm, 143),
    (ProcessSignal.sigint, 130),
  ]) {
    test(
      '$signal stops the body, leaves no orphan and answers $code',
      () async {
        file('version: 1\ntasks:\n  hold: {desc: x, $_holds}\n');
        final started = await engine(['hold', '--report', 'run.json']);
        final body = await pidIn('body.pid');

        final answered = await send(signal, started);

        expect(alive(body), isFalse, reason: 'the body was left running');
        expect(
          answered,
          code,
          reason: '128 and the signal, as a shell says it\n${started.said}',
        );
        final report =
            jsonDecode(File(p.join(root.path, 'run.json')).readAsStringSync())
                as Map<String, Object?>;
        expect(report['complete'], isTrue, reason: 'the run got to its end');
        expect(report['code'], code);
        final hold = (report['tasks']! as List<Object?>).single! as Map;
        expect(hold['result'], 'not-run');
        expect(
          hold['why'],
          'stopped part-way: the run received ${signal.name}',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test('a task a failure stopped is not said to have been stopped by a '
      'signal that came later', () async {
    // `b` is stopped when `a` fails; the signal comes while `c` still runs.
    // Asked when the run ended, the cause was the signal for both.
    file(
      'version: 1\n'
      'tasks:\n'
      "  a: {desc: x, run: [sh, -c, 'while [ ! -f b.pid ]; do sleep 0.05; "
      "done; exit 1']}\n"
      r"  b: {desc: x, interruptible: true, run: [sh, -c, 'echo $$ > b.pid; "
      "exec sleep 60']}\n"
      r"  c: {desc: x, run: [sh, -c, 'echo $$ > c.pid; exec sleep 60']}"
      '\n'
      '  all: {desc: x, needs: [a, b, c]}\n',
    );
    final started = await engine(['all', '-j', '3', '--report', 'run.json']);
    final b = await pidIn('b.pid');
    await pidIn('c.pid');
    for (var tries = 0; alive(b) && tries < 300; tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(alive(b), isFalse, reason: '`a` failing stops `b`');

    expect(await send(ProcessSignal.sigint, started), 130);
    final report =
        jsonDecode(File(p.join(root.path, 'run.json')).readAsStringSync())
            as Map<String, Object?>;
    final why = {
      for (final task
          in (report['tasks']! as List<Object?>).cast<Map<String, Object?>>())
        task['task']: task['why'],
    };
    expect(
      why['b'],
      'stopped part-way: an earlier failure had already answered the run',
      reason: '${started.said}',
    );
    expect(why['c'], 'stopped part-way: the run received SIGINT');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('under -j every member of an `each:` is stopped', () async {
    for (final member in ['a', 'b']) {
      Directory(p.join(root.path, 'pkg', member)).createSync(recursive: true);
    }
    file(
      'version: 1\n'
      'sets:\n  pkgs: {include: [pkg/*]}\n'
      'tasks:\n'
      '  hold: {desc: x, each: pkgs, in: \$each, $_holds}\n',
    );
    final started = await engine(['hold', '-j', '2']);
    final members = [
      await pidIn('pkg/a/body.pid'),
      await pidIn('pkg/b/body.pid'),
    ];

    expect(await send(ProcessSignal.sigterm, started), 143);
    for (final pid in members) {
      expect(alive(pid), isFalse, reason: 'member $pid was left running');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a verb is waited for, and the program it started is stopped', () async {
    // A verb is Dart, and nothing outside it can stop it. What it started
    // can be, and the verb then carries on with the code it was handed.
    file('version: 1\ntasks:\n  hold: {desc: x, do: hold}\n');
    final started = await engine(['hold']);
    final body = await pidIn('body.pid');

    expect(await send(ProcessSignal.sigterm, started), 143);
    expect(alive(body), isFalse, reason: 'the program was left running');
    expect(
      '${started.said}',
      allOf(
        contains('the verb went on after its program, which answered 130'),
        contains('task `hold` was stopped: the run received SIGTERM'),
      ),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
