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
String onPathLine(
  Map<String, String> environment, {
  required String command,
  required String installed,
  required bool windows,
}) {
  final name = windows ? '$command.exe' : command;
  final path = environment['PATH'] ?? environment['Path'] ?? '';
  final directory = p.dirname(installed);
  for (final entry in path.split(windows ? ';' : ':')) {
    if (entry.isEmpty) {
      continue;
    }
    final found = p.join(entry, name);
    if (FileSystemEntity.typeSync(found) != FileSystemEntityType.notFound) {
      return p.equals(found, installed)
          ? '✓ $found'
          : '⚠ `$command` on PATH is $found — not the build just installed. '
                'Put this earlier on PATH: $directory';
    }
  }
  return '⚠ installed, but `$command` is not on PATH — add this to it: '
      '$directory';
}
