/// Running a shell script of the project under the bash it was written for —
/// which on Windows is Git's, and not the program `bash` names there.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xtask/xtask.dart';

/// `do:` a verb running a shell script under bash ([runBashScript]): the
/// task's `args:` name the script first and then what it is given.
///
/// ```yaml
/// release-notes:
///   do: bash
///   args: [tool/release_notes.sh]
/// ```
///
/// A verb and not `run: [bash, …]`, because on Windows the program called
/// `bash` is the wrong one or none at all. A plain `PATH` there has no bash on
/// it, and where one is found first it is often WSL's launcher in
/// `System32`, which runs the script in another machine's filesystem with
/// another machine's tools. Nothing to configure, so no data: what differs
/// between projects is the script, and that is the task's to name.
Verb bashScript() => runBashScript;

/// Runs the script [context]'s `args:` name, with the rest of them, under
/// bash, and answers with its exit code. A function as well as a verb, for a
/// project whose verb does more around the script.
///
/// On Windows that bash is Git's ([findGitBash]); elsewhere it is `bash`, as
/// `PATH` finds it. [windows] and [exists] are this machine's unless given —
/// given only by a test, which is what lets the Windows rules be proved on a
/// machine that is not Windows.
///
/// It refuses, naming why, without a script, and on Windows where no Git's
/// bash is found — as a missing tool, which is what it is.
Future<int> runBashScript(
  VerbContext context, {
  bool? windows,
  bool Function(String path)? exists,
}) async {
  if (context.args.isEmpty) {
    context.log('bash: which script? `args: [<script>, …]`');
    return ExitCode.invalidFile;
  }
  if (!(windows ?? Platform.isWindows)) {
    return context.run(['bash', ...context.args]);
  }
  final bash = await findGitBash(
    environment: context.env,
    which: context.which,
    gitExecPath: () async {
      final answer = await context.capture(['git', '--exec-path']);
      return answer.exitCode == ExitCode.success ? answer.stdout.trim() : null;
    },
    exists: exists ?? (path) => File(path).existsSync(),
  );
  if (bash == null) {
    context.log(
      'bash: no Git bash found — looked beside the git on PATH, where git '
      'says it lives, and where Git for Windows installs itself; a bash on '
      'PATH in System32 or WindowsApps is WSL’s and is not used. Install Git '
      'for Windows.',
    );
    return ExitCode.missingTool;
  }
  return context.run([bash, ...context.args]);
}

/// Git's own bash on a Windows machine, or null where none is found.
///
/// Looked for, in this order, under the root of a Git for Windows:
///
/// 1. the one the `git` on `PATH` belongs to ([which]) — the Git the scripts
///    and the hooks already run against;
/// 2. the one [gitExecPath], `git --exec-path`, answers from, asked only
///    when `git` is on `PATH` and has no bash about it: a shim's, like
///    Scoop's, which stands somewhere else than the Git it starts;
/// 3. where the installer puts Git: under `ProgramFiles`, `ProgramW6432`,
///    `ProgramFiles(x86)`, and `LOCALAPPDATA\Programs` for a per-user
///    install — for a machine whose `PATH` has no Git on it at all;
///
/// and last a bash on `PATH` ([which]) that is not WSL's launcher — in
/// `System32`, or `WindowsApps` where it comes from the Store — which is
/// some other MSYS bash that runs a script written for Git's.
///
/// [exists] says whether a file is there. Everything is injected so that the
/// order can be tested away from Windows, where these paths do not exist;
/// they are read as Windows paths whatever this machine is.
Future<String?> findGitBash({
  required Map<String, String> environment,
  required String? Function(String name) which,
  required Future<String?> Function() gitExecPath,
  required bool Function(String path) exists,
}) async {
  // Git's root is the nearest directory above [from] that holds a bash, no
  // more than three up:
  // `<Git>\cmd` and `<Git>\bin` are one level under it, `<Git>\mingw64\bin`
  // two, and the exec path `<Git>\mingw64\libexec\git-core` three.
  String? above(String from) {
    var root = _windows.normalize(from);
    for (var up = 0; up < 3; up++) {
      root = _windows.dirname(root);
      if (_bashUnder(root, exists) case final bash?) {
        return bash;
      }
    }
    return null;
  }

  if (which('git') case final git?) {
    if (above(_windows.dirname(git)) case final bash?) {
      return bash;
    }
    final execPath = await gitExecPath();
    if (execPath != null && execPath.isNotEmpty) {
      if (above(execPath) case final bash?) {
        return bash;
      }
    }
  }

  final variables = {
    for (final MapEntry(:key, :value) in environment.entries)
      key.toUpperCase(): value,
  };
  for (final (variable, under) in const [
    ('PROGRAMFILES', ['Git']),
    ('PROGRAMW6432', ['Git']),
    ('PROGRAMFILES(X86)', ['Git']),
    ('LOCALAPPDATA', ['Programs', 'Git']),
  ]) {
    final base = variables[variable]?.trim();
    if (base == null || base.isEmpty) {
      continue;
    }
    if (_bashUnder(_windows.joinAll([base, ...under]), exists)
        case final bash?) {
      return bash;
    }
  }

  if (which('bash') case final bash?
      when exists(bash) && !_isWsl(_windows.dirname(bash))) {
    return bash;
  }
  return null;
}

final _windows = p.Context(style: p.Style.windows);

/// The bash a Git for Windows rooted at [root] carries, or null.
String? _bashUnder(String root, bool Function(String path) exists) {
  for (final bash in [
    _windows.join(root, 'bin', 'bash.exe'),
    _windows.join(root, 'usr', 'bin', 'bash.exe'),
  ]) {
    if (exists(bash)) {
      return bash;
    }
  }
  return null;
}

/// Whether [directory] is where WSL's `bash.exe` launcher lives.
bool _isWsl(String directory) {
  final parts = _windows.split(directory.toLowerCase());
  return parts.contains('system32') || parts.contains('windowsapps');
}
