@TestOn('!windows')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/xtask.dart';
import 'package:xtask_kit/xtask_kit.dart';

void main() {
  late Directory root;
  late List<String> said;

  VerbContext context() => VerbContext(
    args: const [],
    env: const {},
    root: root.path,
    workingDirectory: root.path,
    log: said.add,
    start: (argv, {workingDirectory}) async => (await Process.run(
      argv.first,
      argv.skip(1).toList(),
      workingDirectory: workingDirectory,
    )).exitCode,
  );

  String source(String name) {
    final file = File(p.join(root.path, 'build', name))
      ..createSync(recursive: true)
      ..writeAsStringSync(name);
    return file.path;
  }

  /// A directory under [path] whose contents cannot be removed — what an
  /// earlier install leaves where a person made part of it read-only.
  void lockedInside(String path) {
    final directory = Directory(p.join(path, 'locked'))
      ..createSync(recursive: true);
    File(p.join(directory.path, 'kept')).writeAsStringSync('kept');
    Process.runSync('chmod', ['555', directory.path]);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('xtask_kit_replace_');
    said = [];
  });

  // Recursive, because the swap moves a locked directory to `.old`, where the
  // path [lockedInside] made no longer is.
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+w', root.path]);
    root.deleteSync(recursive: true);
  });

  String into() => p.join(root.path, 'installed');

  test(
    'a swap that succeeded is a success, though the earlier copy stays',
    () async {
      expect(
        await replaceDirectory(
          context(),
          sources: [source('v1')],
          into: into(),
          owner: 'test',
        ),
        ExitCode.success,
      );
      lockedInside(into());

      expect(
        await replaceDirectory(
          context(),
          sources: [source('v2')],
          into: into(),
          owner: 'test',
        ),
        ExitCode.success,
      );
      expect(File(p.join(into(), 'v2')).existsSync(), isTrue);
      expect(said.last, contains('${into()}.old'));
    },
  );

  test(
    'a leftover it cannot clear is a refusal before anything is copied',
    () async {
      lockedInside('${into()}.old');

      expect(
        await replaceDirectory(
          context(),
          sources: [source('v1')],
          into: into(),
          owner: 'test',
        ),
        ExitCode.taskFailed,
      );
      expect(said.single, contains('${into()}.old'));
      expect(Directory(into()).existsSync(), isFalse);
    },
  );
}
