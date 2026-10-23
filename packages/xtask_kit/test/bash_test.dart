import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/xtask.dart';
import 'package:xtask_kit/src/bash.dart';

/// Which bash a script runs under: on Windows Git's, found from `git` and
/// never WSL's launcher; elsewhere the `bash` on `PATH`.
///
/// The Windows rules are tested here on any machine, against a Windows
/// filesystem that exists only as a set of paths — the machines this is
/// written on are not Windows, and a rule that can be run only there would
/// ship untested. The last group runs on a real one, in CI.
void main() {
  const git = r'C:\Program Files\Git';
  const wsl = r'C:\Windows\System32\bash.exe';

  group('findGitBash', () {
    Future<String?> find({
      Set<String> files = const {},
      Map<String, String> commands = const {},
      String? execPath,
      Map<String, String> environment = const {},
    }) => findGitBash(
      environment: environment,
      which: (name) => commands[name],
      gitExecPath: () async => execPath,
      exists: files.contains,
    );

    test("Git's bash beside the git on PATH, over WSL's bash before it", () {
      expect(
        find(
          files: {'$git\\bin\\bash.exe', wsl},
          commands: {'git': '$git\\cmd\\git.exe', 'bash': wsl},
        ),
        completion('$git\\bin\\bash.exe'),
      );
    });

    test(r"when PATH names Git's mingw64\bin, two levels under its root", () {
      expect(
        find(
          files: {'$git\\usr\\bin\\bash.exe'},
          commands: {'git': '$git\\mingw64\\bin\\git.exe'},
        ),
        completion('$git\\usr\\bin\\bash.exe'),
      );
    });

    test('from `git --exec-path` when the git on PATH is a shim', () {
      const scoop = r'C:\Users\me\scoop';
      expect(
        find(
          files: {'$scoop\\apps\\git\\current\\bin\\bash.exe'},
          commands: {'git': '$scoop\\shims\\git.exe'},
          // What Git for Windows answers: forward slashes.
          execPath:
              'C:/Users/me/scoop/apps/git/current/mingw64/libexec/'
              'git-core',
        ),
        completion('$scoop\\apps\\git\\current\\bin\\bash.exe'),
      );
    });

    test('from where Git installs itself, with no git on PATH', () {
      const mine = r'C:\Users\me\AppData\Local\Programs\Git';
      expect(
        find(
          files: {'$mine\\bin\\bash.exe'},
          environment: {
            'ProgramFiles': r'C:\Program Files',
            'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
          },
        ),
        completion('$mine\\bin\\bash.exe'),
      );
      expect(
        find(
          files: {'$git\\bin\\bash.exe'},
          // Windows' variables are not case-sensitive; a map handed on may be.
          environment: {'PROGRAMFILES': r'C:\Program Files'},
        ),
        completion('$git\\bin\\bash.exe'),
      );
    });

    test('a bash on PATH that is not WSL’s, where no Git is found', () {
      const msys = r'C:\msys64\usr\bin\bash.exe';
      expect(
        find(files: {msys}, commands: {'bash': msys}),
        completion(msys),
      );
    });

    test("never WSL's launcher, and nothing when there is nothing", () {
      const store = r'C:\Users\me\AppData\Local\Microsoft\WindowsApps';
      expect(find(files: {wsl}, commands: {'bash': wsl}), completion(isNull));
      expect(
        find(
          files: {'$store\\bash.exe'},
          commands: {'bash': '$store\\bash.exe'},
        ),
        completion(isNull),
      );
      expect(find(), completion(isNull));
    });
  });

  group('runBashScript', () {
    late List<String> said;
    late List<List<String>> started;
    late List<List<String>> captured;

    setUp(() {
      said = [];
      started = [];
      captured = [];
    });

    VerbContext context(
      List<String> args, {
      Map<String, String> commands = const {},
    }) => VerbContext(
      args: args,
      env: const {},
      root: Directory.systemTemp.path,
      workingDirectory: Directory.systemTemp.path,
      log: said.add,
      start: (argv, {workingDirectory}) async {
        started.add(argv);
        return ExitCode.success;
      },
      locate: (name, {workingDirectory}) => commands[name],
      collect: (argv, {workingDirectory, timeout}) async {
        captured.add(argv);
        return (exitCode: ExitCode.taskFailed, stdout: '', stderr: '');
      },
    );

    test('refuses without a script to run, saying how to name one', () async {
      expect(
        await runBashScript(context(const []), windows: false),
        ExitCode.invalidFile,
      );
      expect(said.single, contains('args:'));
      expect(started, isEmpty);
    });

    test('elsewhere, the bash on PATH, with every argument', () async {
      expect(
        await runBashScript(
          context(const ['tool/release.sh', '--dry-run']),
          windows: false,
        ),
        ExitCode.success,
      );
      expect(started, [
        ['bash', 'tool/release.sh', '--dry-run'],
      ]);
    });

    test("on Windows, Git's bash rather than the one on PATH", () async {
      expect(
        await runBashScript(
          context(
            const ['tool/release.sh'],
            commands: {'git': '$git\\cmd\\git.exe', 'bash': wsl},
          ),
          windows: true,
          exists: {'$git\\bin\\bash.exe', wsl}.contains,
        ),
        ExitCode.success,
      );
      expect(started, [
        ['$git\\bin\\bash.exe', 'tool/release.sh'],
      ]);
      // Found beside git.exe, so git itself was never asked.
      expect(captured, isEmpty);
    });

    test(
      'asks git where it lives only when its bash is not beside it',
      () async {
        await runBashScript(
          context(
            const ['tool/release.sh'],
            commands: {'git': r'C:\shims\git.exe'},
          ),
          windows: true,
          exists: const <String>{}.contains,
        );
        expect(captured, [
          ['git', '--exec-path'],
        ]);
      },
    );

    test('on Windows without Git, a missing tool, saying what it looked '
        'for', () async {
      expect(
        await runBashScript(
          context(const ['tool/release.sh'], commands: {'bash': wsl}),
          windows: true,
          exists: {wsl}.contains,
        ),
        ExitCode.missingTool,
      );
      expect(said.single, allOf(contains('Git'), contains('WSL')));
      expect(started, isEmpty);
    });
  });

  group('on a real Windows machine', testOn: 'windows', () {
    test("finds Git's bash, and it is Git's", () async {
      final bash = await findGitBash(
        environment: Platform.environment,
        which: (name) {
          final where = Process.runSync('where', [name]);
          final first = '${where.stdout}'.split('\n').first.trim();
          return where.exitCode == 0 && first.isNotEmpty ? first : null;
        },
        gitExecPath: () async {
          final result = await Process.run('git', ['--exec-path']);
          return result.exitCode == 0 ? '${result.stdout}'.trim() : null;
        },
        exists: (path) => File(path).existsSync(),
      );
      expect(bash, isNotNull);
      expect(p.split(bash!.toLowerCase()), isNot(contains('system32')));
      // MSYS is what Git's bash is built on; WSL's would answer GNU/Linux.
      final uname = await Process.run(bash, ['-c', 'uname -o']);
      expect('${uname.stdout}'.trim(), 'Msys');
    });
  });
}
