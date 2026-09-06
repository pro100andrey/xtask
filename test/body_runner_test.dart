import 'dart:async';
import 'dart:io' show ProcessException;

import 'package:test/test.dart';
import 'package:xtask/src/bodies.dart';
import 'package:xtask/src/body_runner.dart';
import 'package:xtask/src/budget.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/executables.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/model.dart';
import 'package:xtask/src/process.dart';

/// A starter that answers with [code], or raises what it is given.
final class FakeStarter implements ProcessStarter {
  FakeStarter({this.code = ExitCode.success, this.raises});

  final int code;
  final Exception? raises;

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
  }) async {
    final thrown = raises;
    if (thrown != null) {
      throw thrown;
    }
    return code;
  }
}

void main() {
  late List<String> logged;
  late GivenUp givenUp;

  setUp(() {
    logged = [];
    givenUp = GivenUp();
  });

  BodyRunner runnerWith(ProcessStarter starter) => BodyRunner(
    bodies: BodyResolver(
      root: '/repo',
      resolver: ExecutableResolver(
        environment: const {'PATH': '/bin'},
        windows: false,
        isRunnable: (_) => true,
      ),
    ),
    starter: starter,
    log: logged.add,
    givenUp: givenUp,
  );

  Task taskNamed(
    String name, {
    bool interruptible = false,
    int? timeout,
    String? member,
  }) => Task(
    name: name,
    desc: 'x',
    interruptible: interruptible,
    timeout: timeout,
  );

  ResolvedProcess process(
    Task task, {
    Duration? timeout,
    String? member,
  }) => ResolvedProcess(
    task: task,
    member: member,
    workingDirectory: '/repo',
    environment: const {},
    declaredEnvironment: const {},
    arguments: const ['test'],
    executable: '/bin/dart',
    runInShell: false,
    timeout: timeout,
  );

  ResolvedVerb verb(Task task, Future<int> Function() answer) => ResolvedVerb(
    task: task,
    member: null,
    workingDirectory: '/repo',
    environment: const {},
    declaredEnvironment: const {},
    arguments: const [],
    verb: 'v',
    implementation: (_) => answer(),
  );

  Future<RunFailure> failureOf(Future<void> Function() body) async {
    try {
      await body();
    } on RunFailure catch (failure) {
      return failure;
    }
    fail('expected a RunFailure, got none');
  }

  group('a body that finished', () {
    test('and passed is not stopped and is not a failure', () async {
      final runner = runnerWith(FakeStarter());
      expect(await runner.run(process(taskNamed('a')), null), isFalse);
    });

    test('and failed names the task, the command and the directory', () async {
      final runner = runnerWith(FakeStarter(code: 2));
      final failure = await failureOf(
        () => runner.run(process(taskNamed('a')), null),
      );
      expect(failure.message, contains('task `a` failed with exit code 2'));
      expect(failure.message, contains('/bin/dart test'));
      expect(failure.message, contains('/repo'));
    });

    test('under `each:` the member is named, not just the task', () async {
      // "The tests failed" over six packages is a report that makes somebody
      // run all six again by hand to find out which.
      final runner = runnerWith(FakeStarter(code: 2));
      final failure = await failureOf(
        () => runner.run(process(taskNamed('a'), member: 'pkg-b'), null),
      );
      expect(failure.message, contains('task `a` at `pkg-b`'));
    });
  });

  group("a verb's code is a decision; a program's is data", () {
    test('so a verb answering 2 makes the run answer 2', () async {
      // `remove` answering 2 for a path outside the repository is saying "the
      // FILE is wrong", and flattening it to 1 sends whoever reads the exit
      // code looking for a task that ran and failed.
      final runner = runnerWith(FakeStarter());
      final failure = await failureOf(
        () => runner.run(
          verb(taskNamed('a'), () async => ExitCode.invalidFile),
          null,
        ),
      );
      expect(failure.code, ExitCode.invalidFile);
    });

    test('and a program answering 2 makes the run answer 1', () async {
      // An external program has never heard of the exit code table: its 2
      // means whatever its author meant, so the number belongs in the message
      // and the run answers "a task failed".
      final runner = runnerWith(FakeStarter(code: 2));
      final failure = await failureOf(
        () => runner.run(process(taskNamed('a')), null),
      );
      expect(failure.code, ExitCode.taskFailed);
      expect(failure.message, contains('exit code 2'));
    });
  });

  group('a killed process is reported as killed, not as exit 124', () {
    test('where the task carried a deadline', () async {
      final runner = runnerWith(
        FakeStarter(code: SystemProcessStarter.timedOut),
      );
      final failure = await failureOf(
        () => runner.run(
          process(
            taskNamed('a', timeout: 30),
            timeout: const Duration(seconds: 30),
          ),
          null,
        ),
      );
      expect(failure.message, contains('did not finish inside its'));
      expect(failure.message, contains('timeout: 30'));
    });

    test('and as itself where it did not', () async {
      // Recognised rather than proved: a program that genuinely exits 124
      // while carrying no `timeout:` is described as what it is.
      final runner = runnerWith(
        FakeStarter(code: SystemProcessStarter.timedOut),
      );
      final failure = await failureOf(
        () => runner.run(process(taskNamed('a')), null),
      );
      expect(failure.message, contains('failed with exit code 124'));
      expect(failure.message, isNot(contains('did not finish')));
    });
  });

  group('a 130 is a stop only where the run actually gave up', () {
    test('and then it is not a failure at all', () async {
      // It was not allowed to finish, and calling that a failure would put a
      // second red thing beside the one that actually broke.
      givenUp.now();
      final runner = runnerWith(
        FakeStarter(code: SystemProcessStarter.interrupted),
      );
      final stopped = await runner.run(
        process(taskNamed('a', interruptible: true)),
        null,
      );
      expect(stopped, isTrue);
      expect(logged.join('\n'), contains('was stopped'));
    });

    test('but a 130 from a program that chose it is a failure', () async {
      // 130 is what a shell reports for SIGINT and what plenty of programs
      // exit with on their own; reading it as "stopped" wherever the key
      // appeared turned a real failure into a green result nobody checked.
      final runner = runnerWith(
        FakeStarter(code: SystemProcessStarter.interrupted),
      );
      final failure = await failureOf(
        () => runner.run(process(taskNamed('a', interruptible: true)), null),
      );
      expect(failure.message, contains('exit code 130'));
    });

    test(
      'and so is one from a task the file never said may be stopped',
      () async {
        givenUp.now();
        final runner = runnerWith(
          FakeStarter(code: SystemProcessStarter.interrupted),
        );
        final failure = await failureOf(
          () => runner.run(process(taskNamed('a')), null),
        );
        expect(failure.message, contains('exit code 130'));
      },
    );
  });

  group('"could not be started" is said only where it is literally true', () {
    test('for a process, with the directory it looked in', () async {
      // `Process.start` throws rather than answering when the working
      // directory does not exist. Nothing caught it: the run ended on an
      // unhandled exception at 255, a number the table does not have.
      final runner = runnerWith(
        FakeStarter(
          raises: const ProcessException('/bin/dart', ['test'], 'no'),
        ),
      );
      final failure = await failureOf(
        () => runner.run(process(taskNamed('a')), null),
      );
      expect(failure.code, ExitCode.taskFailed);
      expect(failure.message, contains('could not be started'));
      expect(failure.message, contains('/repo'));
    });

    test('and never for a verb, which may shell out on its own', () async {
      // A verb is arbitrary project Dart, and one that reaches for `git` on a
      // machine without it raises this too — reported as "could not be
      // started" it would print `do <verb>` and send the reader to inspect
      // the wrong command entirely.
      final runner = runnerWith(FakeStarter());
      await expectLater(
        runner.run(
          verb(
            taskNamed('a'),
            () async => throw const ProcessException('git', ['status']),
          ),
          null,
        ),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
