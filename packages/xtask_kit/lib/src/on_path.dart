/// Whether a command just installed is the one a shell would start.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// The line an install ends with about [installed], an absolute path, as the
/// command [command] on [environment]'s `PATH`.
///
/// Three outcomes, not two: the build just installed is what `PATH` finds,
/// something else of that name is found first, or nothing is. Calling the
/// second a success is the failure worth naming — the person runs the old
/// binary and reports that the fix did not work.
///
/// On Windows a command is found by every extension `PATHEXT` names, in its
/// order, in each directory: `demo.bat` in an earlier directory is what cmd
/// and PowerShell start for `demo`, ahead of the `demo.exe` just installed.
/// Without `PATHEXT` it is Windows' own default list.
String onPathLine(
  Map<String, String> environment, {
  required String command,
  required String installed,
  required bool windows,
}) {
  final names = windows
      ? [
          for (final extension
              in (_variable(environment, 'PATHEXT', windows: windows) ??
                      '.COM;.EXE;.BAT;.CMD')
                  .split(';'))
            if (extension.isNotEmpty)
              // Lower case because Windows does not tell them apart and this
              // is checked on other systems too, which do.
              '$command${extension.toLowerCase()}',
        ]
      : [command];
  final path = _variable(environment, 'PATH', windows: windows) ?? '';
  final directory = p.dirname(installed);
  for (final entry in path.split(windows ? ';' : ':')) {
    if (entry.isEmpty) {
      continue;
    }
    for (final name in names) {
      final found = p.join(entry, name);
      if (FileSystemEntity.typeSync(found) != FileSystemEntityType.notFound) {
        return p.equals(found, installed)
            ? '✓ $found'
            : '⚠ `$command` on PATH is $found — not the build just '
                  'installed. Put this earlier on PATH: $directory';
      }
    }
  }
  return '⚠ installed, but `$command` is not on PATH — add this to it: '
      '$directory';
}

/// [name] in [environment], which on Windows is any spelling of it: the
/// variables there are not case sensitive, and `Path` is the usual one.
String? _variable(
  Map<String, String> environment,
  String name, {
  required bool windows,
}) {
  if (environment[name] case final value?) {
    return value;
  }
  if (!windows) {
    return null;
  }
  for (final MapEntry(:key, :value) in environment.entries) {
    if (key.toUpperCase() == name) {
      return value;
    }
  }
  return null;
}
