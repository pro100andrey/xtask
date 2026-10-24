/// Installing a project's own VS Code extension, built as a VSIX, into the
/// VS Code profile the person running the verb works in.
///
/// VS Code installs extensions **per profile**, and `code` without
/// `--profile` acts on the Default one — which is very likely not where the
/// person works. Worse, `code --profile <name>` CREATES a profile that does
/// not exist rather than refusing, so a mistyped name silently installs into
/// a new, empty profile and reports success. So every verb here checks the
/// name against the profiles VS Code keeps before it hands it to `code`.
///
/// Profile names can contain spaces ("Dart Work" is a real one), so nothing
/// here word-splits: a name is one argv entry, always.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xtask/xtask.dart';

/// A VS Code extension the project builds, and what [vsCodeInstall] needs to
/// know to install it.
///
/// Data, not steps: where the extension lives. Everything else is read from
/// its `package.json` when the verb runs — the id from `publisher` and
/// `name`, and the VSIX from `name` and `version`, which is how `vsce
/// package` names the file it writes. Reading them rather than being told
/// them is what keeps a version bump from leaving the install looking for the
/// last build. Building the VSIX is a task of its own — a `run:` the install
/// task `needs:` — so a build failure is reported as the build's.
final class VsCodeExtension {
  const VsCodeExtension({required this.directory});

  /// The extension's directory, from the root: where its `package.json` is,
  /// and where `vsce package` leaves the VSIX.
  final String directory;
}

/// What an extension's `package.json` says about it.
final class VsCodeManifest {
  const VsCodeManifest({
    required this.publisher,
    required this.name,
    required this.version,
  });

  final String publisher;
  final String name;
  final String version;

  /// The id `code` knows the extension by: `<publisher>.<name>`.
  String get id => '$publisher.$name';

  /// The file `vsce package` writes: `<name>-<version>.vsix`.
  String get vsix => '$name-$version.vsix';
}

/// The names of the profiles on this machine — or why they could not be
/// read.
///
/// Two outcomes that must not be confused, hence two fields rather than an
/// empty list: "this is the whole list" (including no state file at all,
/// which means no named profiles) and "could not look". A verb checking a
/// name has to tell those apart, or it reports a real profile as a typo. A
/// half-written or wrong-shaped state file lands on the first side: a broken
/// editor file must not be able to break a build.
final class ProfileNames {
  const ProfileNames(this.names, {this.unreadable});

  /// Every profile, `Default` first. The Default profile is implicit — it has
  /// no entry in the state file — so it is always here.
  final List<String> names;

  /// Why the named profiles could not be read, or null when [names] is the
  /// whole list.
  final String? unreadable;
}

/// `do:` a verb installing [extension]'s built VSIX into the person's profile
/// ([installVsCodeExtension]).
Verb vsCodeInstall(VsCodeExtension extension) =>
    (context) => installVsCodeExtension(context, extension);

/// `do:` a verb removing [extension] from the person's profile
/// ([uninstallVsCodeExtension]).
Verb vsCodeUninstall(VsCodeExtension extension) =>
    (context) => uninstallVsCodeExtension(context, extension);

/// `do:` a verb listing the profiles on this machine, each with the version
/// of [extension] it holds, or `—`.
///
/// The question an install leaves open: the build is in *a* profile, and
/// whether it is in the one the person has open is what this answers.
Verb vsCodeProfiles(VsCodeExtension extension) =>
    (context) => _profiles(context, extension);

/// Installs [extension]'s built VSIX into the profile the person names, and
/// answers with an [ExitCode]. A function as well as a verb, for a project
/// whose install does more around it.
///
/// The profile is `--profile <name>` after `--`, or `PROFILE` from the
/// environment — set once and forgotten — and VS Code's Default profile
/// without either, which it warns about.
///
/// `--force` makes it idempotent: a local build rarely changes the version,
/// and without it `code` declines to reinstall a version it has, which reads
/// as "my change did nothing".
///
/// It refuses, naming why, without `code` on `PATH` (`3`), for a profile that
/// does not exist, for an argument it does not know, and when the manifest or
/// the VSIX is not there.
Future<int> installVsCodeExtension(
  VerbContext context,
  VsCodeExtension extension,
) async {
  if (_noCode(context) case final refused?) {
    return refused;
  }
  final (:profile, :refusal) = _profile(context);
  if (refusal != null) {
    context.log(refusal);
    return ExitCode.taskFailed;
  }
  final manifest = _manifest(context, extension);
  if (manifest.refusal case final why?) {
    context.log(why);
    return ExitCode.taskFailed;
  }
  final read = manifest.manifest!;
  final vsix = context.file(p.join(extension.directory, read.vsix));
  if (!vsix.existsSync()) {
    context.log('there is no ${read.vsix} at ${vsix.path} — build it first');
    return ExitCode.taskFailed;
  }
  if (profile == null) {
    context.log(
      "⚠ no profile named — installing into VS Code's Default profile, which "
      'is very likely not where you work. Name one with PROFILE or '
      '`-- --profile <name>`.',
    );
  }
  final installed = await context.run([
    'code',
    ...profileArgs(profile),
    '--install-extension',
    vsix.path,
    '--force',
  ]);
  if (installed != ExitCode.success) {
    return installed;
  }
  context.log(
    '✓ ${read.id} ${read.version} installed into ${_where(profile)} — '
    "now run 'Developer: Reload Window'",
  );
  return ExitCode.success;
}

/// Removes [extension] from the profile the person names, as
/// [installVsCodeExtension] names it, and answers with an [ExitCode].
///
/// Safe to repeat: it asks `code` what the profile holds first, and where the
/// extension is not there it says so and succeeds — rather than starting an
/// uninstall that fails and leaves the person to guess whether it failed for
/// that reason or another. It still refuses a profile that does not exist,
/// since naming one would create it, a strange thing for an uninstall to do.
Future<int> uninstallVsCodeExtension(
  VerbContext context,
  VsCodeExtension extension,
) async {
  if (_noCode(context) case final refused?) {
    return refused;
  }
  final (:profile, :refusal) = _profile(context);
  if (refusal != null) {
    context.log(refusal);
    return ExitCode.taskFailed;
  }
  final manifest = _manifest(context, extension);
  if (manifest.refusal case final why?) {
    context.log(why);
    return ExitCode.taskFailed;
  }
  final id = manifest.manifest!.id;
  final installed = await installedVersion(context, id, profile: profile);
  if (installed.refusal case final why?) {
    context.log(why);
    return ExitCode.taskFailed;
  }
  if (installed.version == null) {
    context.log('$id is not installed in ${_where(profile)}');
    return ExitCode.success;
  }
  final removed = await context.run([
    'code',
    ...profileArgs(profile),
    '--uninstall-extension',
    id,
  ]);
  if (removed != ExitCode.success) {
    return removed;
  }
  context.log('✓ $id removed from ${_where(profile)}');
  return ExitCode.success;
}

/// The version of the extension [id] installed in [profile] — VS Code's
/// Default one where it is null — or null where none is; or why `code` could
/// not be asked.
///
/// Captured rather than run, because the answer has to be read; through the
/// engine, which starts `code`'s `.cmd` shim on Windows as it starts any
/// `run:` body.
Future<({String? version, String? refusal})> installedVersion(
  VerbContext context,
  String id, {
  String? profile,
}) async {
  final listed = await context.capture([
    'code',
    ...profileArgs(profile),
    '--list-extensions',
    '--show-versions',
  ]);
  if (listed.exitCode != ExitCode.success) {
    return (
      version: null,
      refusal:
          '`code --list-extensions` exited ${listed.exitCode}'
          '${listed.stderr.trim().isEmpty ? '' : ': ${listed.stderr.trim()}'}',
    );
  }
  // Each line is `<id>@<version>`. Compared whole and without case — ids are
  // case-insensitive to VS Code, and a prefix or substring match would take
  // `notacme.demo` for `acme.demo`.
  for (final line in const LineSplitter().convert(listed.stdout)) {
    final at = line.trim().lastIndexOf('@');
    if (at > 0 &&
        line.trim().substring(0, at).toLowerCase() == id.toLowerCase()) {
      return (version: line.trim().substring(at + 1), refusal: null);
    }
  }
  return (version: null, refusal: null);
}

/// The argv entries that address [profile]: none for the Default profile,
/// which `code` addresses by naming nothing.
List<String> profileArgs(String? profile) =>
    profile == null || profile.isEmpty || profile == 'Default'
    ? const []
    : ['--profile', profile];

/// VS Code's user directory on this platform, read from [environment], or
/// null where it names none or the platform's layout is not known here.
String? vsCodeUserDir(Map<String, String> environment) {
  String? named(String variable) {
    final value = environment[variable]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  final home = named('HOME');
  if (Platform.isMacOS) {
    return home == null
        ? null
        : p.join(home, 'Library', 'Application Support', 'Code', 'User');
  }
  if (Platform.isWindows) {
    final appData = named('APPDATA');
    return appData == null ? null : p.join(appData, 'Code', 'User');
  }
  if (Platform.isLinux) {
    final config =
        named('XDG_CONFIG_HOME') ??
        (home == null ? null : p.join(home, '.config'));
    return config == null ? null : p.join(config, 'Code', 'User');
  }
  return null;
}

/// The profile names out of VS Code's `globalStorage/storage.json`, under
/// the user directory [environment] gives ([vsCodeUserDir]).
ProfileNames readProfileNames(Map<String, String> environment) {
  const defaultOnly = ProfileNames(['Default']);
  final user = vsCodeUserDir(environment);
  if (user == null) {
    return const ProfileNames(
      ['Default'],
      unreadable: "VS Code's user directory is not known here",
    );
  }
  final storage = File(p.join(user, 'globalStorage', 'storage.json'));
  if (!storage.existsSync()) {
    return defaultOnly;
  }
  // Everything inside the try, not just the parse: the file can be valid JSON
  // of the wrong shape, and reaching into that throws as readily as a syntax
  // error does.
  try {
    final document = jsonDecode(storage.readAsStringSync());
    final profiles = document is Map ? document['userDataProfiles'] : null;
    return ProfileNames([
      'Default',
      if (profiles is List)
        for (final profile in profiles)
          if (profile case {'name': final String name} when name.isNotEmpty)
            name,
    ]);
  } on Object {
    return defaultOnly;
  }
}

/// `3`, said, where `code` is not on `PATH`; null where it is.
///
/// Asked before anything else, so the person learns the one thing that
/// needs installing rather than a profile or a VSIX that would not have
/// helped.
int? _noCode(VerbContext context) {
  if (context.which('code') != null) {
    return null;
  }
  context.log(
    'the `code` command is not on PATH.\n'
    '  In VS Code: Command Palette → Shell Command: Install "code" command '
    'in PATH.',
  );
  return ExitCode.missingTool;
}

/// The profile the person named — `--profile <name>` after `--` over
/// `PROFILE` — null for none; or why it is refused.
///
/// A name that cannot be checked is used, with a warning: failing to read
/// VS Code's list is not evidence of a typo.
({String? profile, String? refusal}) _profile(VerbContext context) {
  var profile = context.env['PROFILE'];
  final args = context.args;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--profile' && i + 1 < args.length) {
      profile = args[++i];
    } else {
      return (
        profile: null,
        refusal:
            'unknown argument `${args[i]}` — this verb takes '
            '`--profile <name>`',
      );
    }
  }
  if (profile == null || profile.isEmpty) {
    return (profile: null, refusal: null);
  }
  final known = readProfileNames(context.env);
  if (known.unreadable case final why?) {
    context.log(
      '⚠ could not read the profile list ($why) — using "$profile" '
      'unverified. If it does not exist, VS Code will create it empty.',
    );
    return (profile: profile, refusal: null);
  }
  if (known.names.contains(profile)) {
    return (profile: profile, refusal: null);
  }
  return (
    profile: null,
    refusal:
        'there is no VS Code profile named "$profile" — `code` would create '
        'it empty. Known:\n${known.names.map((n) => '  $n').join('\n')}',
  );
}

/// [extension]'s manifest, or why it could not be read.
({VsCodeManifest? manifest, String? refusal}) _manifest(
  VerbContext context,
  VsCodeExtension extension,
) {
  final file = context.file(p.join(extension.directory, 'package.json'));
  if (!file.existsSync()) {
    return (
      manifest: null,
      refusal: 'there is no package.json at ${file.path}',
    );
  }
  Object? document;
  try {
    document = jsonDecode(file.readAsStringSync());
  } on FormatException catch (error) {
    return (
      manifest: null,
      refusal: '${file.path} is not JSON: ${error.message}',
    );
  }
  String? field(String key) => switch (document is Map ? document[key] : null) {
    final String value when value.isNotEmpty => value,
    _ => null,
  };
  for (final key in ['publisher', 'name', 'version']) {
    if (field(key) == null) {
      return (manifest: null, refusal: '${file.path} carries no "$key"');
    }
  }
  return (
    manifest: VsCodeManifest(
      publisher: field('publisher')!,
      name: field('name')!,
      version: field('version')!,
    ),
    refusal: null,
  );
}

Future<int> _profiles(VerbContext context, VsCodeExtension extension) async {
  if (_noCode(context) case final refused?) {
    return refused;
  }
  final manifest = _manifest(context, extension);
  if (manifest.refusal case final why?) {
    context.log(why);
    return ExitCode.taskFailed;
  }
  final id = manifest.manifest!.id;
  final known = readProfileNames(context.env);
  if (known.unreadable case final why?) {
    context.log('⚠ $why — listing the Default profile only');
  }
  // Sized to the longest name rather than to a guess a long one would break.
  final width = [
    'PROFILE',
    ...known.names,
  ].map((name) => name.length).reduce((a, b) => a > b ? a : b);
  context
    ..log('${'PROFILE'.padRight(width)}  $id')
    ..log('${''.padRight(width, '-')}  ${''.padRight(id.length, '-')}');
  for (final name in known.names) {
    final installed = await installedVersion(context, id, profile: name);
    final held = switch (installed) {
      (version: _, refusal: final String why) => '? $why',
      (:final String version, refusal: null) => version,
      _ => '—',
    };
    context.log('${name.padRight(width)}  $held');
  }
  return ExitCode.success;
}

String _where(String? profile) =>
    profile == null ? 'the Default profile' : 'profile "$profile"';
