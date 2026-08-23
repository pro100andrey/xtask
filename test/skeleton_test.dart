import 'dart:io';

import 'package:test/test.dart';
import 'package:xtask/xtask.dart';

void main() {
  group('until the CLI exists, every invocation is refused', () {
    // These three used to assert 0, and a code review named that as a defect
    // rather than a placeholder: §7.1 has a pipeline run `dart run :xtask
    // ci-analyze` as a job's only step, so a 0 gives whoever wires CI before
    // the `cli` slice lands a permanently green job that ran nothing —
    // indistinguishable from a passing gate, which is §1's third defect
    // reproduced by the tool written to remove it.
    test('with no arguments', () async {
      expect(await runXtask([]), 2);
    });

    test('with a task name', () async {
      expect(await runXtask(['ci-analyze']), 2);
    });

    test('with --validate, which is not implemented either', () async {
      expect(await runXtask(['--validate']), 2);
    });

    test('a project passing no verbs is still refused, not excused', () async {
      expect(await runXtask([], verbs: {}), 2);
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

    test('reaches this package, not some other xtask', () {
      expect(run.stderr, contains('xtask.md'));
    });

    test('and carries the refusal out to the process exit code', () {
      // The entry point has to USE the answer. `bin/xtask.dart` assigns it to
      // `exitCode`; a consumer that writes `=> runXtask(args)` — as §9's own
      // snippet used to — discards it and exits 0 for every outcome.
      expect(run.exitCode, 2);
    });
  });
}
