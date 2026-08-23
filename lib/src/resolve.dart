import 'dart:io';

import 'package:path/path.dart' as p;

/// Finding the program a task's `run:` names — §5.4 of `xtask.md`.
///
/// This is the one place in the engine that knows starting a program means
/// different things on three platforms. §5.2 says there is no shell in the
/// *description* of a task; it does not say the engine may be ignorant of the
/// operating system, and an engine that refuses the shell and stops there does
/// not run on the platform its portability argument was made for.
///
/// Everything the answer depends on is injected — the environment, whether
/// this is Windows, and whether a file exists. Not for purity: the Windows
/// branch is the one that matters and the machines this is written on are not
/// Windows, so a version reading `Platform.isWindows` directly would ship its
/// most important rule untested. That is how the reference this was ported
/// from, `resolveOnPath()` in Lake's `step_runner.dart`, has to be read as
/// well: right, and unprovable away from the platform it is about.
final class ExecutableResolver {
  ExecutableResolver({
    required this.environment,
    required this.windows,
    required this.exists,
  }) : _paths = p.Context(
         style: windows ? p.Style.windows : p.Style.posix,
       );

  /// The resolver for the machine this process is running on.
  factory ExecutableResolver.forHost() => ExecutableResolver(
    environment: Platform.environment,
    windows: Platform.isWindows,
    exists: (path) => File(path).existsSync(),
  );

  /// Where `PATH` and `PATHEXT` are read from.
  final Map<String, String> environment;

  /// Whether the rules are Windows' rules: `;` between `PATH` entries, and a
  /// bare name that may match `dart.bat`.
  final bool windows;

  /// Whether a file is there. Injected so the Windows cases can be tested at
  /// all: they are about paths that do not exist on the machine running them.
  final bool Function(String path) exists;

  final p.Context _paths;

  /// The default `PATHEXT`, used when the machine does not set one. Windows
  /// itself has more entries; these are the ones that make a program start.
  static const defaultPathExt = '.COM;.EXE;.BAT;.CMD';

  /// The extensions a batch shim has. Starting one is not starting a program
  /// (§5.4, rule 3).
  static const shimExtensions = {'.bat', '.cmd'};

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
  String? resolve(String executable) {
    if (executable.isEmpty) {
      return null;
    }

    // A name that is already a path is used as given (§5.4, rule 1) — the
    // author said where it is, and searching `PATH` for it would be
    // second-guessing a statement of fact.
    if (_paths.split(executable).length > 1) {
      return exists(executable) ? executable : null;
    }

    // Both lists are read once. They are getters over the environment, and
    // leaving `_suffixes` inside the loop re-split `PATHEXT` for every
    // directory on `PATH`.
    final suffixes = _suffixes;
    for (final directory in _searchPath) {
      for (final suffix in suffixes) {
        final candidate = _paths.join(directory, '$executable$suffix');
        if (exists(candidate)) {
          return candidate;
        }
      }
    }
    return null;
  }

  /// Whether starting [resolvedPath] has to go through the system shell.
  ///
  /// True only for a Windows batch shim. `dart`, `flutter` and everything
  /// `dart pub global activate` installs are `.bat`/`.cmd` files there, and
  /// `CreateProcess` will not start one: the shell is what knows how. Dart's
  /// own documentation warns that such a file **may be launched by the OS in a
  /// system shell regardless of the caller's intent**, and that its arguments
  /// are then parsed by shell rules — so a caller that gets this answer owes
  /// its arguments an escaping pass, which is an obligation and not a
  /// precaution.
  ///
  /// Compared in lower case, and that is not tidiness. `PATHEXT` is spelled in
  /// capitals by convention, so [resolve] hands back `dart.BAT`; matching it
  /// against a lower-case set answers false for the exact file this method
  /// exists to recognise, and the shim then fails to start with nothing
  /// pointing at why.
  bool needsShell(String resolvedPath) =>
      windows &&
      shimExtensions.contains(_paths.extension(resolvedPath).toLowerCase());

  /// What to tell somebody whose machine cannot start [executable].
  ///
  /// Says where it looked, because the two cures are different: install the
  /// tool, or put the directory it is already in on `PATH`.
  String missingToolMessage(String executable) {
    final where = _paths.split(executable).length > 1
        ? 'no file at `$executable`'
        : 'nothing by that name in the '
              '${_searchPath.length} directories on PATH';
    final suffixes = windows
        ? ', with any of ${_suffixes.where((s) => s.isNotEmpty).join(', ')}'
        : '';
    return '`$executable` is not installed, or is not on PATH — $where'
        '$suffixes';
  }

  List<String> get _searchPath => [
    for (final directory in (_lookup('PATH') ?? '').split(windows ? ';' : ':'))
      if (directory.isNotEmpty) directory,
  ];

  List<String> get _suffixes {
    if (!windows) {
      return const [''];
    }
    // The empty suffix first, so a name written WITH an extension resolves to
    // itself rather than to `foo.exe.COM`. The reference this was ported from
    // omits this and would miss `run: [something.exe, ...]`.
    return [
      '',
      ...(_lookup('PATHEXT') ?? defaultPathExt)
          .split(';')
          .where((s) => s.isNotEmpty),
    ];
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
