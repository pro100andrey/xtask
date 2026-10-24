/// The file `--report` writes: where it goes, and how it is written.
///
/// Its own module because two programs write it. The engine writes a run's,
/// as it goes; and the installed `xtask`, handing a run to a project's own
/// entry point, writes one only when it refuses to start that run — and
/// then has to write the same thing, in the same place, the same way, or a
/// program reading the report would see two formats for one refusal.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'report.dart';
import 'secrets.dart';

/// Where a run's report goes, and the one way it is written.
final class ReportFile {
  /// The report at [path] as it was typed, read against [workingDirectory]
  /// — where the command was run, as `--check-schema` reads its path: that
  /// is where the person typing it is looking.
  ReportFile(
    this.path, {
    required String workingDirectory,
    required this.secrets,
  }) : _file = File(p.join(workingDirectory, path));

  /// The path as it was typed, for what is said about it.
  final String path;

  /// What every string in the report is masked by before it is encoded:
  /// what a task failed with is the reproduction line, argv and all.
  final Secrets secrets;

  final File _file;

  /// Writes [json] over the report, its directory made first.
  ///
  /// Whole or not at all: a reader that opens it while the run is writing,
  /// or after a run cut off mid-write, finds the last report and not half of
  /// the next one.
  ///
  /// Throws [FileSystemException]; [cannotWrite] says it.
  void write(Map<String, Object?> json) {
    final part = File('${_file.path}.part');
    _file.parent.createSync(recursive: true);
    part
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(secrets.maskJson(json))}'
        '\n',
      )
      ..renameSync(_file.path);
  }

  /// What is said when [problem] kept the report from being written.
  String cannotWrite(FileSystemException problem) =>
      'xtask: cannot write the report to `$path`: '
      '${problem.osError?.message ?? problem.message}';
}

/// Writes the report of a run refused before it had a plan: complete,
/// answering [code], with [refusal] as its `why` and no tasks.
///
/// **The one refusal report, for both programs that refuse.** The engine
/// writes it for a command line it would not read — `-j 0`, an option it
/// has not got — and the installed `xtask` for a hand-over it would not
/// start: a loop, no `dart`, a `pub get` that failed. Either way the report
/// the command line asked for would otherwise be the last run's, which
/// reads to whatever waits on it as this one's answer.
///
/// [asked] is what `reportAskedIn` found. A report that cannot be written is
/// said on [err] and changes nothing: the run was already refused, and its
/// code says why.
void reportRefusal(
  ({String path, String? task}) asked, {
  required String workingDirectory,
  required Secrets secrets,
  required int code,
  required String refusal,
  required void Function(String line) err,
}) {
  final file = ReportFile(
    asked.path,
    workingDirectory: workingDirectory,
    secrets: secrets,
  );
  try {
    file.write(runReport(asked.task, null, code: code, refusal: refusal));
  } on FileSystemException catch (problem) {
    err(file.cannotWrite(problem));
  }
}
