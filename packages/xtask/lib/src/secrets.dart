/// Keeping the values of `secret-env:` out of what the engine prints.
///
/// **One place masks, and it masks at the exits.** Everything the engine
/// says leaves through one of three: the line it writes to stdout, the line
/// it writes to stderr, and the `--report` file. The places that put a value
/// into a line are many — `--dry-run`'s argv and `env` lines, the
/// reproduction a failure prints, an `::error::` annotation, a refusal that
/// quotes the command line, the hand-over's own sentences — and a mask added
/// to each of them is a list the next message is missing from. Masked where
/// the lines leave, a message nobody has written yet is masked already.
///
/// **What a body prints is not the engine's to filter**, and does not go
/// through here: a program's own output reaches the terminal by itself when
/// nothing collects it, so filtering only the output that is collected would
/// make what is hidden depend on `-j`. The README says where that boundary is.
library;

import 'dart:io' show File, FileSystemException;

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'markers.dart' show workflowEscaped;
import 'model.dart' show eachMarker;
import 'readable.dart' show withoutByteOrderMark;
import 'report.dart' show quotedInside;
import 'request.dart' show xtaskFileName;

/// The shortest value that is masked.
///
/// **Four, because a mask replaces every occurrence.** A secret of one to
/// three characters is a word, a number or a flag — `1`, `dev`, `on` — and
/// masking it would put `***` into every count, path and sentence that
/// happens to contain it, on the engine's lines and, through `::add-mask::`,
/// on every line of the job. The log would stop being readable while hiding
/// nothing an attacker could not guess in a few thousand tries, which is what
/// a value that short is anyway.
const secretMinimumLength = 4;

/// What a masked value is printed as.
const secretMask = '***';

/// The values that are masked in a run, and the masking itself.
final class Secrets {
  /// [written], less what is too short to mask, a value of several lines
  /// joined by each of its lines.
  Secrets(Iterable<String> written)
    : values = List.unmodifiable({
        for (final value in written)
          if (value.length >= secretMinimumLength) ...[
            value,
            // Each line too: a line of a key is still the key, and GitHub's
            // `::add-mask::` reads one line.
            if (value.contains('\n'))
              for (final line in value.split(RegExp(r'\r?\n')))
                if (line.length >= secretMinimumLength) line,
          ],
      });

  static final none = Secrets(const []);

  /// Every value masked, in no particular order.
  final List<String> values;

  bool get isEmpty => values.isEmpty;

  /// Every form a value can reach a line in, longest first.
  ///
  /// As written; as `commandLine` quotes it; and each of those as a workflow
  /// command escapes it — `describe` is printed inside `::error::`. Longest
  /// first, so a secret that contains another is masked whole rather than
  /// leaving its remainder beside a `***`.
  late final List<String> _forms = () {
    final forms = <String>{
      for (final value in values)
        for (final quoted in [value, quotedInside(value)]) ...[
          quoted,
          workflowEscaped(quoted),
        ],
    }.toList()..sort((a, b) => b.length.compareTo(a.length));
    return forms;
  }();

  /// [text] with every value in it printed as [secretMask].
  String mask(String text) {
    var masked = text;
    for (final form in _forms) {
      masked = masked.replaceAll(form, secretMask);
    }
    return masked;
  }

  /// [json] with every string in it — key or value — masked.
  ///
  /// Before it is encoded, because an encoder escapes `"` and `\`, and a
  /// value holding either would be in the file in a form nothing looked for.
  Object? maskJson(Object? json) => switch (json) {
    final String text => mask(text),
    final Map<String, Object?> map => {
      for (final MapEntry(:key, :value) in map.entries)
        mask(key): maskJson(value),
    },
    final List<Object?> list => [for (final item in list) maskJson(item)],
    _ => json,
  };

  /// What tells GitHub Actions to mask the values in the job's log: one
  /// `::add-mask::` per value of one line.
  ///
  /// A value of several lines is masked by its lines, which are among
  /// [values]; the command reads to the end of its line, so the whole would
  /// reach the runner as its first line.
  List<String> get addMasks => [
    for (final value in values)
      if (!value.contains('\n')) '::add-mask::${workflowEscaped(value)}',
  ];
}

/// [text] as a YAML document, read as loosely as it can be read, or null.
///
/// **Not the parser.** A run is masked from its first line, and the first
/// line can come before the file is parsed — a command line that is not one,
/// quoted back — or from a run that cannot parse it at all, the hand-over of
/// a file written for a newer `xtask`. Whether `secret-env:` is well formed
/// is the parser's to refuse; which values to hide is asked of whatever the
/// file says.
Object? loadDocument(String text) {
  try {
    return loadYaml(withoutByteOrderMark(text));
  } on Exception {
    return null;
  }
}

/// The secrets of the `xtask.yaml` at [root], for a run in [environment].
///
/// None where there is no file to read: a file that is not there names no
/// secret.
Secrets readSecrets(
  String root,
  Map<String, String> environment, {
  required bool windows,
}) {
  final String text;
  try {
    text = File(p.join(root, xtaskFileName)).readAsStringSync();
  } on FileSystemException {
    return Secrets.none;
  }
  return secretsIn(loadDocument(text), environment, windows: windows);
}

/// The values the names in [document]'s `secret-env:` have in this run.
///
/// **Every value the name has anywhere in the run**: what [environment] holds
/// under it, and what any task's `env:` sets it to. One set for the whole run
/// rather than one per task, because the output is one stream — a token
/// printed by a task that did not declare it is just as printed. A task's
/// `env-unset:` takes the variable from that body, not the value from the
/// world: it is still a secret wherever else it turns up.
///
/// A name is matched whatever its case on Windows, as Windows matches it. A
/// value made from `$each` is a member's name, which the parser refuses; it
/// is passed over here, where the file has not been parsed.
Secrets secretsIn(
  Object? document,
  Map<String, String> environment, {
  required bool windows,
}) {
  if (document is! Map) {
    return Secrets.none;
  }
  final listed = document['secret-env'];
  if (listed is! List) {
    return Secrets.none;
  }
  String folded(String name) => windows ? name.toUpperCase() : name;
  final names = {
    for (final name in listed)
      if (name is String) folded(name),
  };
  if (names.isEmpty) {
    return Secrets.none;
  }
  return Secrets([
    for (final MapEntry(:key, :value) in environment.entries)
      if (names.contains(folded(key))) value,
    if (document['tasks'] case final Map<Object?, Object?> tasks)
      for (final task in tasks.values)
        if (task case {'env': final Map<Object?, Object?> env})
          for (final MapEntry(:key, :value) in env.entries)
            if (key is String &&
                names.contains(folded(key)) &&
                value is String &&
                !value.endsWith(eachMarker))
              value,
  ]);
}
