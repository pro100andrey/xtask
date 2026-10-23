/// Publishing a package to pub — the checks that cannot be taken back after,
/// the upload, and a wait until the registry serves what was uploaded.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xtask/xtask.dart';

/// How long [publishToPub] holds off before each look at the registry, once
/// the upload is through.
///
/// Bounded, which is the timeout: what is waited on is an index write the
/// upload has already triggered, so a registry that has not caught up in
/// three and a half minutes is not going to in thirty — and saying that out
/// loud, with the code that means it, beats a run that hangs.
const registryWaits = <Duration>[
  Duration.zero,
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 20),
  Duration(seconds: 30),
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 1),
];

/// A package to publish, and what [pubPublish] needs to know beyond its
/// manifest.
///
/// Its name, its version and its registry are read from the manifest rather
/// than written here: a second copy of the version is one that falls behind
/// the first on the day it matters.
final class PubPackage {
  const PubPackage(
    this.directory, {
    this.changelog = 'CHANGELOG.md',
    this.waits = registryWaits,
  });

  /// The package — the directory holding its `pubspec.yaml` — from the root.
  final String directory;

  /// Its changelog, from [directory].
  final String changelog;

  /// The pauses before each look at the registry after the upload; how long
  /// that wait may take is their sum.
  final List<Duration> waits;
}

/// What a [RegistryProbe] throws when the registry could not be asked — as
/// opposed to having answered that it lists nothing.
final class RegistryUnavailable implements Exception {
  const RegistryUnavailable(this.reason);

  /// Why, as a phrase: `connection refused`, `answered 503`.
  final String reason;

  @override
  String toString() => 'the registry could not be asked: $reason';
}

/// The versions of [package] the registry at [registry] serves — empty for a
/// package it has never heard of — or a [RegistryUnavailable] thrown.
///
/// **Injected, so a test never reaches a registry.** Every outcome worth
/// asserting about a publish — refused before, refused by pub, served after,
/// never served — is about what a registry answered, none of which needs a
/// real one; [askRegistry] is the one that asks.
typedef RegistryProbe =
    Future<Set<String>> Function(String registry, String package);

/// [RegistryProbe] by pub's own API: `GET <registry>/api/packages/<package>`.
///
/// Without a credential, which is what pub.dev asks for. A registry that
/// wants one to list a package — most private ones — is asked by a probe of
/// the project's own, handed to [pubPublish]; this one would find it
/// unavailable, and the publish would be refused before anything was
/// uploaded rather than wait on an answer it cannot get.
Future<Set<String>> askRegistry(String registry, String package) async {
  final base = registry.endsWith('/')
      ? registry.substring(0, registry.length - 1)
      : registry;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(
      Uri.parse('$base/api/packages/$package'),
    );
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.pub.v2+json',
    );
    final response = await request.close().timeout(
      const Duration(seconds: 30),
    );
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    // A package the registry has never heard of is one with no versions, not
    // a registry that failed: it is what the first publish of every package
    // sees.
    if (response.statusCode == HttpStatus.notFound) {
      return const {};
    }
    if (response.statusCode != HttpStatus.ok) {
      throw RegistryUnavailable('answered ${response.statusCode}');
    }
    return servedVersions(body);
  } on SocketException catch (error) {
    throw RegistryUnavailable(error.message);
  } on HttpException catch (error) {
    throw RegistryUnavailable(error.message);
  } on TimeoutException {
    throw const RegistryUnavailable('it did not answer in time');
  } finally {
    client.close(force: true);
  }
}

/// The versions listed in [body], an answer of pub's
/// `GET /api/packages/<package>`.
Set<String> servedVersions(String body) {
  try {
    final versions = (jsonDecode(body) as Map<String, Object?>)['versions'];
    return {
      for (final entry in versions! as List<Object?>)
        (entry! as Map<String, Object?>)['version']! as String,
    };
  } on Object {
    // Anything not shaped as pub's answer is no answer, and saying "it lists
    // nothing" instead would let a publish start on a claim nobody checked.
    throw const RegistryUnavailable('its answer is not a package listing');
  }
}

/// `do:` a verb publishing [package] to pub ([publishToPub]).
///
/// [probe] asks the registry what it serves ([askRegistry] unless given);
/// [pause] waits between looks after the upload, and is a parameter for the
/// same reason [probe] is.
Verb pubPublish(
  PubPackage package, {
  RegistryProbe probe = askRegistry,
  Future<void> Function(Duration delay) pause = _delay,
}) =>
    (context) => publishToPub(context, package, probe: probe, pause: pause);

/// Publishes [package] to pub and answers with an [ExitCode] — one of the
/// three endings a publish has.
///
/// **Nothing was published**, `1`, or `2` where the package is not one that
/// can be: everything below is checked before the upload, because a version
/// cannot be uploaded twice and nothing after it can be taken back.
///
/// - the manifest names the package and its version, and does not say
///   `publish_to: none` — its registry is the URL there, or pub.dev;
/// - the changelog names the version in a heading ([changelogNames]): the
///   archive carries the changelog, and the page pub.dev shows for a version
///   is the one it was uploaded with;
/// - git says the package matches HEAD ([uncommittedRefusal]);
/// - the registry does not already serve the version, and could be asked.
///
/// Then `dart pub publish --force` in the package. `--force` because the
/// checks above are the confirmation, and a prompt is what a CI job cannot
/// answer; pub still refuses what it would refuse, and a refusal is a `1` with
/// nothing uploaded.
///
/// **Everything passed**, `0`: the registry serves the version — looked for
/// after each of [PubPackage.waits], because pub answers when the archive is
/// accepted, not when it is served, and a task that runs next, depending on
/// that version, would otherwise fail for a reason that is not its own.
///
/// **The upload happened and the check after it is red**, `4`
/// ([ExitCode.continuationFailed]): the registry did not serve the version in
/// time. Not a `1`, which would tell a pipeline the publish failed — false,
/// and unrecoverable in the wrong direction, since the registry will not take
/// that version again.
Future<int> publishToPub(
  VerbContext context,
  PubPackage package, {
  RegistryProbe probe = askRegistry,
  Future<void> Function(Duration delay) pause = _delay,
}) async {
  final directory = context.directory(package.directory);
  final pubspec = File(p.join(directory.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    context.log('there is no package at ${package.directory}: no pubspec.yaml');
    return ExitCode.invalidFile;
  }
  final String? name;
  final String? version;
  final String? publishTo;
  try {
    final text = pubspec.readAsStringSync();
    name = manifestField(text, 'name');
    version = manifestField(text, 'version');
    publishTo = manifestField(text, 'publish_to');
  } on FormatException catch (error) {
    context.log('${pubspec.path}: ${error.message}');
    return ExitCode.invalidFile;
  }
  if (name == null || version == null) {
    context.log(
      '${pubspec.path} names no ${name == null ? 'package' : 'version'}, '
      'so there is nothing to publish',
    );
    return ExitCode.invalidFile;
  }
  if (publishTo == 'none') {
    context.log(
      '$name says `publish_to: none`, so pub will not publish it; take that '
      'line out first if it is to be published',
    );
    return ExitCode.invalidFile;
  }
  final registry = publishTo ?? 'https://pub.dev';
  final release = '$name $version';

  final changelog = File(p.join(directory.path, package.changelog));
  if (!changelog.existsSync()) {
    context.log(
      'there is no ${package.changelog} in ${package.directory} to say what '
      '$version is; write it before the version goes out',
    );
    return ExitCode.taskFailed;
  }
  if (!changelogNames(changelog.readAsStringSync(), version)) {
    context.log(
      '${package.changelog} in ${package.directory} names no $version in a '
      'heading — what was uploaded is what pub.dev shows for the version, '
      'and it cannot be corrected after. Name it first: `## $version`',
    );
    return ExitCode.taskFailed;
  }

  // From the root and about the package only: that is the whole of what
  // ships, and work in flight elsewhere in the repository changes nothing in
  // the archive.
  final status = await context.capture([
    'git',
    'status',
    '--porcelain',
    '--',
    package.directory,
  ], workingDirectory: context.root);
  if (status.exitCode != 0) {
    // An empty answer would read as "clean"; a git that cannot answer is not
    // permission to go on.
    context.log(
      '`git status` failed (exit ${status.exitCode}), so whether the package '
      'matches HEAD is not known: ${status.stderr.trim()}',
    );
    return ExitCode.taskFailed;
  }
  if (uncommittedRefusal(
        package.directory,
        const LineSplitter()
            .convert(status.stdout)
            .where((line) => line.trim().isNotEmpty)
            .toList(),
      )
      case final refusal?) {
    context.log(refusal);
    return ExitCode.taskFailed;
  }

  try {
    if ((await probe(registry, name)).contains(version)) {
      context.log(
        '$registry already serves $release, and a version is never uploaded '
        'twice; bump the version',
      );
      return ExitCode.taskFailed;
    }
  } on RegistryUnavailable catch (error) {
    // Before the upload this is a refusal, not a "probably not published":
    // the upload is the step that cannot be taken back, so it does not start
    // on a guess.
    context.log(
      'whether $registry already serves $release is not known — '
      '${error.reason} — so nothing was uploaded',
    );
    return ExitCode.taskFailed;
  }

  context.log('publishing $release to $registry');
  final published = await context.run([
    'dart',
    'pub',
    'publish',
    '--force',
  ], workingDirectory: package.directory);
  if (published != ExitCode.success) {
    context.log(
      '`dart pub publish` answered $published, so $release was not uploaded',
    );
    return ExitCode.taskFailed;
  }

  for (final (index, delay) in package.waits.indexed) {
    await pause(delay);
    String why;
    try {
      if ((await probe(registry, name)).contains(version)) {
        context.log('✓ $registry serves $release');
        return ExitCode.success;
      }
      why = 'not listed yet';
    } on RegistryUnavailable catch (error) {
      // After the upload, a registry that cannot be asked is one more reason
      // to look again, not a verdict: what is being waited out is the
      // registry catching up.
      why = error.reason;
    }
    context.log('  ${index + 1}/${package.waits.length}: $why');
  }
  context.log(
    'the upload succeeded and is not undone, but $registry does not serve '
    '$release yet. That is the registry catching up, not a defect here: '
    'give it a few minutes before running what depends on it',
  );
  return ExitCode.continuationFailed;
}

/// Why [package]'s tree would not be what is uploaded, or null when it
/// matches HEAD.
///
/// [porcelain] is `git status --porcelain -- <package>`, a line each.
/// Untracked files count, and that is the point of asking `git status`
/// rather than `git diff`: pub packs the directory, not the index, so an
/// untracked file goes into the archive and is published from a state that
/// exists on one machine.
String? uncommittedRefusal(String package, List<String> porcelain) {
  if (porcelain.isEmpty) {
    return null;
  }
  return '$package differs from HEAD — pub packs the directory, not the '
      'index, so these would be uploaded as they are; commit or clean them '
      'first:\n'
      '${porcelain.map((line) => '  $line').join('\n')}';
}

/// Whether [text], a changelog, names [version] in a heading — `## 1.2.0`,
/// `## [1.2.0] - 2026-10-23`, `# v1.2.0`.
///
/// In a heading only, and only as a whole: a line mentioning the version in
/// passing is not the entry for it, and `1.2.0-dev.1` is another version.
bool changelogNames(String text, String version) {
  for (final line in const LineSplitter().convert(text)) {
    if (!line.startsWith('#')) {
      continue;
    }
    final words = line.split(RegExp(r'[^0-9A-Za-z.+\-]+'));
    if (words.contains(version) || words.contains('v$version')) {
      return true;
    }
  }
  return false;
}

/// The value of the top-level [key] in [text], a `pubspec.yaml`, or null
/// where it has none.
///
/// **Read narrowly rather than parsed, and refusing past that.** This package
/// carries no YAML parser, and the three fields read here — `name`, `version`,
/// `publish_to` — are a single plain scalar in every manifest pub accepts in
/// practice. So one written otherwise — a block scalar, a key given twice —
/// throws a [FormatException] naming it, rather than being read some way it
/// might not mean.
String? manifestField(String text, String key) {
  final values = [
    for (final line in const LineSplitter().convert(text))
      if (line.startsWith('$key:')) line.substring(key.length + 1),
  ];
  if (values.isEmpty) {
    return null;
  }
  if (values.length > 1) {
    throw FormatException('`$key:` is given ${values.length} times');
  }
  final match = RegExp(
    r'''^\s+(?:'([^']*)'|"([^"\\]*)"|([^\s#'"&*!|>\[{][^\s#]*))\s*(?:#.*)?$''',
  ).firstMatch(values.single);
  if (match == null) {
    throw FormatException(
      '`$key:` is not a single plain value on its line, which is all this '
      'reads',
    );
  }
  return match[1] ?? match[2] ?? match[3];
}

Future<void> _delay(Duration delay) => Future<void>.delayed(delay);
