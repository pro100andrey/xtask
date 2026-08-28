import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'exit_codes.dart';

/// Finding the program a task's `run:` names.
///
/// This is the one place in the engine that knows starting a program means
/// different things on three platforms. §5.2 says there is no shell in the
/// *description* of a task; it does not say the engine may be ignorant of the
/// operating system, and an engine that refuses the shell and stops there does
/// not run on the platform its portability argument was made for.
///
/// Everything the answer depends on is injected — the environment, whether
/// this is Windows, and whether a path names something startable. Not for
/// purity: the Windows branch is the one that matters and the machines this is
/// written on are not Windows, so a version reading `Platform.isWindows`
/// directly would ship its most important rule untested. That is how the
/// reference this was ported from, `resolveOnPath()` in Lake's
/// `step_runner.dart`, has to be read as well: right, and unprovable away from
/// the platform it is about.
final class ExecutableResolver {
  ExecutableResolver({
    required this.environment,
    required this.windows,
    required this.isRunnable,
  }) : _paths = p.Context(style: windows ? p.Style.windows : p.Style.posix);

  /// The resolver for the machine this process is running on.
  factory ExecutableResolver.forHost() => ExecutableResolver(
    environment: Platform.environment,
    windows: Platform.isWindows,
    isRunnable: Platform.isWindows ? _existsOnWindows : _executableOnPosix,
  );

  /// Where `PATH` and `PATHEXT` are read from.
  final Map<String, String> environment;

  /// Whether the rules are Windows' rules: `;` between `PATH` entries, and a
  /// bare name that may match `dart.bat`.
  final bool windows;

  /// Whether this path names something that could actually be started.
  ///
  /// **Not "does a file exist".** `execvp` and `which` skip a file without an
  /// execute bit and keep walking `PATH`; a resolver that stops at the first
  /// name-match hands back a stale non-executable `/usr/local/bin/dart` and
  /// never reaches the real toolchain further along. The caller then gets a
  /// `ProcessException: Permission denied`, which is exit 1 territory — while
  /// §5.3 gives the missing-tool case code 3 precisely so that "not installed"
  /// and "the code is broken" reach different people.
  ///
  /// Injected so the Windows cases can be tested at all: they are about paths
  /// that do not exist on the machine running them.
  final bool Function(String path) isRunnable;

  final p.Context _paths;

  /// What each written name resolved to, this run.
  ///
  /// **The answer cannot change while a run is happening**, and finding it
  /// costs a `stat` per directory on `PATH` — nineteen of them on an ordinary
  /// machine, about 39µs. It was paid once per `run:` body, which under
  /// `each:` is once per member, and again for every program a verb starts.
  final _resolved = <String, String?>{};

  /// The default `PATHEXT`, used when the machine does not set a usable one.
  static const defaultPathExt = '.COM;.EXE;.BAT;.CMD';

  /// What Windows can hand to `CreateProcess` directly.
  ///
  /// The complement, not a list of shims, and that is the fix for a real bug:
  /// a closed `{.bat, .cmd}` was checked against an **open** `PATHEXT`, so a
  /// stock machine's `.VBS`, `.JS`, `.WSF` or `.MSC` resolved as executables
  /// and were then told they could be started directly. `CreateProcess` can no
  /// more start a `.ps1` than a `.bat`. Everything that is not one of these
  /// goes through the shell.
  static const directlyStartable = {'.exe', '.com'};

  /// Where [executable] is, or null when nothing on `PATH` answers to it.
  ///
  /// A null here is a **missing tool**, which §5.3 gives its own exit code
  /// because "Dart is not installed on this machine" and "the code is broken"
  /// are repaired by different people, and one exit code sends both to the
  /// same one.
  ///
  /// On Windows the answer is spelled the way `PATHEXT` is, not the way the
  /// disk is: a `dart.bat` found through the entry `.BAT` comes back as
  /// `dart.BAT`. NTFS does not care and the path starts either way, but
  /// `--dry-run` prints this string (§7), so it is behaviour rather than an
  /// implementation detail, and a test pins it.
  String? resolve(String executable) =>
      _resolved.putIfAbsent(executable, () => _find(executable));

  String? _find(String executable) {
    if (executable.isEmpty) {
      return null;
    }

    // A name that is already a path is used as given (§5.4, rule 1) — the
    // author said where it is, and searching `PATH` for it would be
    // second-guessing a statement of fact.
    if (_paths.split(executable).length > 1) {
      return isRunnable(executable) ? executable : null;
    }

    // Read once. They are getters over the environment, and leaving them
    // inside the loop re-split `PATHEXT` for every directory on `PATH`.
    final suffixes = _suffixesFor(executable);
    for (final directory in _searchPath) {
      for (final suffix in suffixes) {
        final candidate = _paths.join(directory, '$executable$suffix');
        if (isRunnable(candidate)) {
          return candidate;
        }
      }
    }
    return null;
  }

  /// Whether starting [resolvedPath] has to go through the system shell.
  ///
  /// True on Windows for anything that is not [directlyStartable]. `dart`,
  /// `flutter` and everything `dart pub global activate` installs are
  /// `.bat`/`.cmd` files there, and `CreateProcess` will not start one: the
  /// shell is what knows how. Dart's own documentation warns that such a file
  /// **may be launched by the OS in a system shell regardless of the caller's
  /// intent**, and that its arguments are then parsed by shell rules — so a
  /// caller that gets this answer owes its arguments an escaping pass, which
  /// is an obligation and not a precaution.
  ///
  /// Compared in lower case, and that is not tidiness. `PATHEXT` is spelled in
  /// capitals, so [resolve] hands back `dart.BAT`; a case-sensitive match
  /// answers wrongly for the exact file this method exists to recognise.
  bool needsShell(String resolvedPath) =>
      windows &&
      !directlyStartable.contains(_paths.extension(resolvedPath).toLowerCase());

  /// What to tell somebody whose machine cannot start [executable].
  ///
  /// Says where it looked, because the two cures are different: install the
  /// tool, or put the directory it is already in on `PATH`.
  String missingToolMessage(String executable) {
    final where = _paths.split(executable).length > 1
        ? 'no file at `$executable`, or it is not executable'
        : 'nothing runnable by that name in the '
              '${_searchPath.length} directories on PATH';
    final tried = _suffixesFor(executable).where((s) => s.isNotEmpty);
    final suffixes = windows && tried.isNotEmpty
        ? ', with any of ${tried.join(', ')}'
        : '';
    return '`$executable` is not installed, or is not on PATH — $where'
        '$suffixes';
  }

  List<String> get _searchPath => [
    for (final directory in (_lookup('PATH') ?? '').split(windows ? ';' : ':'))
      if (directory.isNotEmpty) directory,
  ];

  /// The suffixes to try for [executable], in order.
  List<String> _suffixesFor(String executable) {
    if (!windows) {
      return const [''];
    }

    // **Only when the name already carries an extension.** cmd.exe tries a
    // bare name with the `PATHEXT` entries and with nothing else; trying the
    // empty suffix first regardless is how `flutter` loses to `flutter.bat`.
    // The Flutter SDK ships both in `bin\` — a POSIX `sh` script beside the
    // batch shim — and nodejs ships `npm` beside `npm.cmd`, so this misses on
    // exactly the two tools §5.4 names as the reason it exists. What comes
    // back then is a shell script with no PE header, reported as
    // ERROR_BAD_EXE_FORMAT rather than as anything §5.4 explains.
    final named = _paths.extension(executable).isNotEmpty ? [''] : <String>[];

    // An empty `PATHEXT` is not an absent one to `??`, but it is to Windows,
    // which falls back to its default. Without this, `PATHEXT=` collapses the
    // list to the bare name and `dart` is reported missing with `dart.bat`
    // sitting right there — code 3, "not installed", for an installed tool.
    final configured = _lookup('PATHEXT');
    final pathExt = (configured == null || configured.trim().isEmpty)
        ? defaultPathExt
        : configured;

    return [...named, ...pathExt.split(';').where((s) => s.isNotEmpty)];
  }

  /// Windows environment variable names are case-insensitive, and the real
  /// variable is spelled `Path`. `Platform.environment` already hides that on
  /// Windows; a map supplied by a test does not, and a lookup that works on
  /// the machine but not in the test is worse than either.
  String? _lookup(String name) {
    final direct = environment[name];
    if (direct != null || !windows) {
      return direct;
    }
    for (final entry in environment.entries) {
      if (entry.key.toUpperCase() == name) {
        return entry.value;
      }
    }
    return null;
  }
}

/// A file with an execute bit, on a platform that has them.
bool _executableOnPosix(String path) {
  final stat = FileStat.statSync(path);
  if (stat.type != FileSystemEntityType.file) {
    return false;
  }
  // Any of owner, group or other — `which` does not ask whose bit it is
  // either, and asking would need the process's own uid and groups.
  return stat.mode & 0x49 != 0;
}

/// On Windows the execute bit does not exist; what makes a file startable is
/// its extension, and [ExecutableResolver._suffixesFor] has already decided
/// that before this is asked.
bool _existsOnWindows(String path) =>
    FileStat.statSync(path).type == FileSystemEntityType.file;

/// Characters `cmd.exe` acts on rather than passes along.
const _cmdMetacharacters = {'&', '|', '<', '>', '^', '(', ')', '"'};

/// Refuses an argument the shell would reinterpret, when the shell is
/// unavoidable — §5.4, rule 3.
///
/// A batch shim cannot be started by `CreateProcess`, so its arguments are
/// parsed by `cmd.exe` whatever the caller intended, and Dart's own
/// documentation says so. That leaves two ways to be wrong and one to be
/// honest:
///
/// - quote for `cmd.exe` here **and** let `Process.start` quote for
///   `CreateProcess` as well, which is two layers of quoting nobody can
///   verify from a machine that is not Windows;
/// - pass them through and let `&` end the command and start another one,
///   silently, which is the worst outcome available;
/// - refuse, name the character, and say what it would have done.
///
/// This takes the third. It costs a task that genuinely wants `&` in an
/// argument to a `.bat` — which it can have by pointing at a `.exe`, or by
/// making the job a verb, where R1 says logic belongs anyway. It is a
/// **stated** limit rather than an untested claim of correctness, and it
/// stops being needed the day this runs on a Windows CI machine that can
/// prove an escaping pass right.
void refuseShellMetacharacters(
  String task,
  String executable,
  List<String> arguments,
) {
  for (final argument in arguments) {
    for (final character in _cmdMetacharacters) {
      if (!argument.contains(character)) {
        continue;
      }
      throw RunFailure(
        ExitCode.invalidFile,
        'task `$task` passes `$argument` to `$executable`, which is '
        'a batch file. Windows starts one through the shell whatever the '
        'caller asks for, so `$character` in that argument would be read as '
        'a shell operator rather than as text. Point the task at a real '
        'executable, or make it a verb — a Dart function is where logic '
        'belongs anyway',
      );
    }
  }
}
