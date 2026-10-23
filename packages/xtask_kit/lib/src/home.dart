/// Where a person's own files go, read from the environment a verb is
/// handed rather than from the process's.
library;

import 'package:path/path.dart' as p;

/// The home directory [environment] names, or null where it names none.
///
/// `HOME`, and on Windows `USERPROFILE` where no `HOME` is set — the rule
/// every per-user install written before this one used, so the two agree
/// about whose machine it is.
String? homeOf(Map<String, String> environment, {required bool windows}) {
  String? named(String variable) {
    final value = environment[variable]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  return named('HOME') ?? (windows ? named('USERPROFILE') : null);
}

/// `XDG_DATA_HOME` from [environment] where it is set and absolute, and
/// `~/.local/share` under [home] otherwise.
///
/// A relative value is ignored, as the XDG base directory specification
/// says it must be: it would be relative to wherever the run happened to
/// start, and the menu that reads the entry starts somewhere else.
String dataHome(Map<String, String> environment, {required String home}) =>
    switch (environment['XDG_DATA_HOME']) {
      final String set when p.isAbsolute(set) => set,
      _ => p.join(home, '.local', 'share'),
    };
