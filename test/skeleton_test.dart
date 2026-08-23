import 'dart:io';

import 'package:test/test.dart';
import 'package:xtask/xtask.dart';

void main() {
  group('the package answers', () {
    test('runXtask returns the success code', () async {
      expect(await runXtask([]), 0);
    });

    test('a project with no verbs need not pass an empty map', () async {
      expect(await runXtask([], verbs: {}), 0);
    });
  });

  group('dart run :xtask', () {
    // The claim this slice exists to prove, and the reason it is a subprocess
    // rather than a direct call: §7 says the command is `dart run :xtask`, and
    // that resolves through `bin/xtask.dart` by file name alone. Calling
    // `runXtask` in-process would pass even if bin/ were empty or misnamed —
    // which is precisely the failure the sentence in §7 would then be hiding.
    //
    // `Platform.resolvedExecutable` is the Dart running this test, so the test
    // does not itself depend on `dart` being resolvable on PATH. That question
    // is §5.4's, and it belongs to the `resolve` slice, not to this one.
    late final ProcessResult run;

    setUpAll(() async {
      run = await Process.run(
        Platform.resolvedExecutable,
        ['run', ':xtask'],
        workingDirectory: Directory.current.path,
      );
    });

    test('exits 0', () {
      expect(run.exitCode, 0, reason: 'stderr was: ${run.stderr}');
    });

    test('reaches this package, not some other xtask', () {
      expect(run.stdout, contains('see xtask.md'));
    });
  });
}
