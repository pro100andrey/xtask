import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask_kit/xtask_kit.dart';

void main() {
  late Directory mine;
  late Directory theirs;

  setUp(() {
    mine = Directory.systemTemp.createTempSync('xtask_kit_mine_');
    theirs = Directory.systemTemp.createTempSync('xtask_kit_theirs_');
  });

  tearDown(() {
    mine.deleteSync(recursive: true);
    theirs.deleteSync(recursive: true);
  });

  String line(List<Directory> path) {
    final windows = Platform.isWindows;
    File(p.join(mine.path, windows ? 'demo.exe' : 'demo')).createSync();
    return onPathLine(
      {'PATH': path.map((d) => d.path).join(windows ? ';' : ':')},
      command: 'demo',
      installed: p.join(mine.path, windows ? 'demo.exe' : 'demo'),
      windows: windows,
    );
  }

  test('the build just installed, found first', () {
    expect(line([mine]), startsWith('✓ '));
  });

  test('another command of the name, found before it', () {
    File(
      p.join(theirs.path, Platform.isWindows ? 'demo.exe' : 'demo'),
    ).createSync();
    final said = line([theirs, mine]);
    expect(said, startsWith('⚠ `demo` on PATH is '));
    expect(said, endsWith(mine.path));
  });

  test('nothing of the name at all', () {
    expect(
      line([theirs]),
      startsWith('⚠ installed, but `demo` is not on PATH'),
    );
  });

  test('on Windows, a script PATHEXT names found before it', () {
    // cmd and PowerShell both start `demo.bat` for `demo`, so a shim an
    // earlier directory holds is the command — not only a `demo.exe`.
    File(p.join(theirs.path, 'demo.bat')).createSync();
    File(p.join(mine.path, 'demo.exe')).createSync();
    final installed = p.join(mine.path, 'demo.exe');
    for (final environment in [
      {'PATH': '${theirs.path};${mine.path}'},
      {'Path': '${theirs.path};${mine.path}', 'PathExt': '.COM;.EXE;.BAT'},
    ]) {
      expect(
        onPathLine(
          environment,
          command: 'demo',
          installed: installed,
          windows: true,
        ),
        startsWith('⚠ `demo` on PATH is ${p.join(theirs.path, 'demo.bat')}'),
      );
    }
    expect(
      onPathLine(
        {'PATH': '${theirs.path};${mine.path}', 'PATHEXT': '.EXE'},
        command: 'demo',
        installed: installed,
        windows: true,
      ),
      startsWith('✓ '),
      reason: 'what PATHEXT leaves out is not started',
    );
  });

  test('and HOME, with USERPROFILE only on Windows', () {
    expect(homeOf({'HOME': ' '}, windows: false), isNull);
    expect(homeOf({'USERPROFILE': r'C:\me'}, windows: false), isNull);
    expect(homeOf({'USERPROFILE': r'C:\me'}, windows: true), r'C:\me');
  });
}
