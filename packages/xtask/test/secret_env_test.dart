import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/cli.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/executables.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/project_entry.dart';
import 'package:xtask/src/request.dart';
import 'package:xtask/src/secrets.dart';
import 'package:xtask/src/style.dart';

import 'helpers.dart';

/// Starts nothing, answers [code] for every program.
final class _Starter implements ProcessStarter {
  _Starter([this.code = ExitCode.success]);

  final int code;

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
  }) async => code;

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
  }) async => (exitCode: code, stdout: '', stderr: '');
}

const _token = 'hunter2-token';

void main() {
  group('the values', () {
    test('shorter than the threshold, or empty, are not masked', () {
      final secrets = Secrets(['', 'abc', 'abcd']);
      expect(secrets.values, ['abcd']);
      expect(secrets.mask('abc abcd'), 'abc ***');
      expect(secretMinimumLength, 4);
    });

    test('are masked in the forms the engine writes them in', () {
      final secrets = Secrets(["it's%secret"]);
      // As written; as `describe` quotes it for reading; as a workflow
      // command escapes it.
      expect(secrets.mask("x it's%secret y"), 'x *** y');
      expect(secrets.mask(r"'it\'s%secret'"), "'***'");
      expect(secrets.mask("::error::it's%25secret"), '::error::***');
    });

    test('a longer secret is masked before a shorter one inside it', () {
      final secrets = Secrets(['abcd', 'abcdefgh']);
      expect(secrets.mask('abcdefgh'), '***');
    });

    test('a value of several lines is masked whole and line by line', () {
      final secrets = Secrets(['line-one\nline-two']);
      expect(secrets.mask('a line-one\nline-two b'), 'a *** b');
      expect(secrets.mask('only line-two here'), 'only *** here');
      expect(secrets.addMasks, [
        '::add-mask::line-one',
        '::add-mask::line-two',
      ]);
    });

    test('a JSON value is masked string by string', () {
      final secrets = Secrets([_token]);
      expect(
        secrets.maskJson({
          'why': 'ran $_token',
          'tasks': [
            {'task': _token, 'code': 1},
          ],
        }),
        {
          'why': 'ran ***',
          'tasks': [
            {'task': '***', 'code': 1},
          ],
        },
      );
    });

    test('come from the environment and from every `env:`', () {
      final secrets = secretsIn(
        loadDocument('''
version: 1
secret-env: [TOKEN, KEY]
tasks:
  a: {desc: x, run: [dart], env: {KEY: declared-key}}
  b: {desc: x, run: [dart], env: {OTHER: not-a-secret}}
'''),
        {'TOKEN': _token, 'OTHER': 'ambient-other'},
        windows: false,
      );
      expect(secrets.values, unorderedEquals([_token, 'declared-key']));
    });

    test('and from every `env-paths:`, as the path the body is given', () {
      // The body gets the absolute path, so that is the form that reaches a
      // line — the written one is only the end of it.
      final secrets = secretsIn(
        loadDocument('''
version: 1
secret-env: [KEY]
tasks:
  a: {desc: x, run: [dart], env-paths: {KEY: keys/./signing}}
  b: {desc: x, run: [dart], env-paths: {OTHER: not/a/secret}}
'''),
        const {},
        windows: true,
        root: r'C:\repo',
      );
      expect(secrets.values, [r'C:\repo\keys\signing']);
    });

    test('on Windows a name is matched whatever its case', () {
      final document = loadDocument('version: 1\nsecret-env: [TOKEN]\n');
      expect(
        secretsIn(document, {'Token': _token}, windows: true).values,
        [_token],
      );
      expect(
        secretsIn(document, {'Token': _token}, windows: false).isEmpty,
        isTrue,
      );
    });
  });

  group('the key', () {
    test('is a list of names at the top level', () {
      expect(
        refusalOf(() => parseXtaskFile('version: 1\nsecret-env: TOKEN\n')),
        contains('must be a list'),
      );
      expect(
        refusalOf(() => parseXtaskFile('version: 1\nsecret-env: [A=B]\n')),
        contains('has an `=` in it'),
      );
      parseXtaskFile('version: 1\nsecret-env: [TOKEN]\n');
    });

    test(r'refuses a secret whose `env:` value is made from `$each`', () {
      expect(
        refusalOf(
          () => parseXtaskFile(r'''
version: 1
secret-env: [TOKEN]
tasks:
  a: {desc: x, run: [dart], env: {TOKEN: tok-$each}}
'''),
        ),
        allOf(contains('`TOKEN`'), contains(r'`$each`')),
      );
    });
  });

  group('what the engine prints', () {
    late Directory root;
    late List<String> out;
    late List<String> err;

    setUp(() {
      root = tempRepo('secret');
      out = [];
      err = [];
    });

    void writeFile(String yaml) =>
        File(p.join(root.path, xtaskFileName)).writeAsStringSync(yaml);

    Future<int> run(
      List<String> args, {
      Map<String, String> environment = const {'TOKEN': _token},
      int code = ExitCode.success,
      Map<String, Verb> verbs = const {},
      Style style = Style.plain,
    }) => runCli(
      args,
      workingDirectory: root.path,
      environment: environment,
      out: out.add,
      err: err.add,
      resolver: ExecutableResolver(
        environment: const {'PATH': '/bin'},
        windows: false,
        isRunnable: (path) => true,
      ),
      starter: _Starter(code),
      verbs: verbs,
      style: style,
    );

    String all() => [...out, ...err].join('\n');

    const file = '''
version: 1
secret-env: [TOKEN, SIGNING]
gates: [check]
tasks:
  deploy: {desc: x, run: [dart, deploy], env: {SIGNING: signing-key-value}}
  check: {desc: x, gate: [check], run: [dart, check]}
''';

    test('--dry-run masks argv and `env:` lines', () async {
      writeFile(file);
      expect(
        await run(['--dry-run', 'deploy', '--', '--token=$_token']),
        ExitCode.success,
      );
      expect(all(), isNot(contains(_token)));
      expect(all(), isNot(contains('signing-key-value')));
      expect(all(), contains('--token=***'));
      expect(all(), contains('env  SIGNING=***'));
    });

    test('--dry-run masks an `env-paths:` value', () async {
      writeFile('''
version: 1
secret-env: [SIGNING]
tasks:
  deploy: {desc: x, run: [dart, deploy], env-paths: {SIGNING: keys/signing}}
''');
      expect(await run(['--dry-run', 'deploy']), ExitCode.success);
      expect(all(), isNot(contains(p.join('keys', 'signing'))));
      expect(all(), contains('env  SIGNING=***'));
    });

    test('a value inside a coloured fragment is masked all the same', () async {
      // **Colour is drawn around a whole fragment, never through one**, so
      // the line the exit masks holds the value in one piece. A heading, and
      // the faint list of a set's members, each with the value as all of it.
      writeFile('''
version: 1
secret-env: [TOKEN]
sets:
  keys: {values: [$_token]}
tasks:
  $_token: {desc: x, run: [dart]}
  sign: {desc: x, each: keys, run: [dart, \$each]}
''');
      for (final args in [
        [_token],
        ['--graph', 'sign'],
      ]) {
        expect(await run(args, style: Style.ansi), ExitCode.success);
      }
      final printed = all();
      expect(printed, isNot(contains(_token)));
      expect(printed, contains('\x1B[1m── *** ──\x1B[0m'));
      expect(printed, contains('\x1B[2m***\x1B[0m'));
    });

    test('the reproduction line and the annotation are masked', () async {
      writeFile(file);
      final code = await run(
        ['deploy', '--', '--token=$_token'],
        environment: const {'TOKEN': _token, 'GITHUB_ACTIONS': 'true'},
        code: 1,
      );
      expect(code, ExitCode.taskFailed);
      final printed = [
        for (final line in [...out, ...err])
          if (!line.startsWith('::add-mask::')) line,
      ].join('\n');
      expect(printed, isNot(contains(_token)));
      expect(printed, contains('--token=***'));
      expect(printed, contains('::error::'));
    });

    test('on GitHub the masks come before any other line', () async {
      writeFile(file);
      await run(
        ['check'],
        environment: const {'TOKEN': _token, 'GITHUB_ACTIONS': 'true'},
      );
      expect(
        out.take(2),
        unorderedEquals([
          '::add-mask::$_token',
          '::add-mask::signing-key-value',
        ]),
      );
      expect(out.skip(2).where((l) => l.startsWith('::add-mask::')), isEmpty);
    });

    test('and nowhere else', () async {
      writeFile(file);
      await run(['check']);
      expect(out.where((l) => l.startsWith('::add-mask::')), isEmpty);
    });

    test('nor ahead of an answer a program reads', () async {
      writeFile(file);
      await run(
        ['--gate-members', 'check'],
        environment: const {'TOKEN': _token, 'GITHUB_ACTIONS': 'true'},
      );
      expect(out, ['check']);
    });

    test('a refusal quoting the command line is masked', () async {
      writeFile(file);
      // A gate set has nothing to hand arguments to.
      expect(
        await run(['check', '--', _token]),
        ExitCode.invalidFile,
      );
      expect(all(), isNot(contains(_token)));
      expect(all(), contains('`***`'));
      err.clear();
      // And one the file is not read for at all.
      await run([_token, 'other']);
      expect(all(), isNot(contains(_token)));
    });

    test('the report is masked', () async {
      writeFile(file);
      await run(
        ['deploy', '--report', 'out/run.json', '--', '--token=$_token'],
        code: 1,
      );
      final text = File(
        p.join(root.path, 'out', 'run.json'),
      ).readAsStringSync();
      expect(text, isNot(contains(_token)));
      expect(jsonEncode(jsonDecode(text)), contains('--token=***'));
    });

    test("a body's own output is not the engine's to filter", () async {
      writeFile('''
version: 1
secret-env: [TOKEN]
tasks:
  say: {desc: x, do: say}
''');
      await run(
        ['say'],
        verbs: {
          'say': (context) async {
            context.log('the verb says ${context.env['TOKEN']}');
            return ExitCode.success;
          },
        },
      );
      expect(out, contains('the verb says $_token'));
    });
  });

  test("the hand-over's own messages are masked", () async {
    final root = tempRepo('secret_hand_over');
    File(
      p.join(root.path, xtaskFileName),
    ).writeAsStringSync('version: 1\nsecret-env: [TOKEN]\n');
    final err = <String>[];
    final code = await runProjectEntry(
      (
        root: root.path,
        entry: 'bin/xtask.dart',
        arguments: ['run', 'bin/xtask.dart', '--', _token],
        resolveIn: null,
        report: null,
      ),
      environment: const {'TOKEN': _token},
      err: err.add,
      // A `dart` that is not there, so starting it fails and the failure
      // quotes the command line.
      resolver: ExecutableResolver(
        environment: const {'PATH': '/nonexistent'},
        windows: false,
        isRunnable: (path) => true,
      ),
    );
    expect(code, ExitCode.taskFailed);
    expect(err.join('\n'), contains('***'));
    expect(err.join('\n'), isNot(contains(_token)));
  });
}
