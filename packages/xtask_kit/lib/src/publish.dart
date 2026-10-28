/// Publishing a package to pub — the checks that cannot be taken back after,
/// the upload, and a wait until the registry serves what was uploaded.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xtask/xtask.dart';

import 'pubspec.dart';

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

/// What `dart pub publish` answers when it refuses before uploading — a
/// package its validation fails, a registry that turns its credentials down:
/// `EX_DATAERR`, as pub's `exit_codes.dart` names it.
const _pubRefused = 65;

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
    this.alreadyServed = AlreadyServed.refuse,
  });

  /// The package — the directory holding its `pubspec.yaml` — from the root.
  final String directory;

  /// Its changelog, from [directory].
  final String changelog;

  /// The pauses before each look at the registry after the upload; how long
  /// that wait may take is their sum.
  final List<Duration> waits;

  /// What a version the registry already serves comes to: a refusal, by
  /// default, or — for a task publishing every package of a repository,
  /// where only some were bumped — a skip.
  final AlreadyServed alreadyServed;
}

/// What [publishToPub] does with a version its registry already serves.
enum AlreadyServed {
  /// Refuses it, `1`: a version is never uploaded twice, and a publish of
  /// one already out is a version somebody forgot to bump.
  refuse,

  /// Answers `0` with `⊘` and checks nothing else, the version being out:
  /// the package was not bumped, and there is nothing of it to publish. Asked
  /// before anything else is checked, so a package left as it was is not
  /// held to a tree or a changelog nobody is about to upload. A registry
  /// that cannot be asked is still a refusal — whether there is anything to
  /// publish is not known.
  skip,
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
  } on TlsException catch (error) {
    throw RegistryUnavailable(error.message);
  } on IOException catch (error) {
    // Every other way the connection can fail. Escaping as itself it would
    // end the run as a crash, which before the upload reads as a defect here
    // and after it as a failed publish — neither of which it is.
    throw RegistryUnavailable('$error');
  } on FormatException catch (error) {
    // An answer that is not UTF-8, or a URL that is not one.
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
///   `publish_to: none` — its registry is the URL there, or `PUB_HOSTED_URL`,
///   or pub.dev: where pub uploads it;
/// - the changelog names the version in a heading ([changelogNames]): the
///   archive carries the changelog, and the page pub.dev shows for a version
///   is the one it was uploaded with;
/// - git says the package matches HEAD ([uncommittedRefusal]), and every
///   file pub would upload is one git tracks ([untrackedRefusal]);
/// - the registry does not already serve the version, and could be asked —
///   asked first instead where [PubPackage.alreadyServed] is
///   [AlreadyServed.skip], a version it serves then being a `0` with
///   nothing else checked.
///
/// Then `dart pub publish --force` in the package. `--force` because the
/// checks above are the confirmation, and a prompt is what a CI job cannot
/// answer; pub still refuses what it would refuse. That it answered other
/// than `0` does not prove nothing went up — the connection can fail after
/// the archive did — so the registry is asked once: serving the version is a
/// `0`. Not serving it is a `1` only after pub's `65`, its refusal before the
/// upload (validation, credentials); after any other failure, and where the
/// registry does not answer, it is a `4`, since the upload may have happened.
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
/// that version again. Nothing after the upload answers `1`: a probe that
/// throws, of whatever kind, is one more look that found nothing.
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
  // Where pub uploads it, in pub's order: a registry asked other than the
  // one uploaded to would answer about a different package.
  final registry =
      publishTo ??
      switch (context.env['PUB_HOSTED_URL']?.trim()) {
        final String hosted when hosted.isNotEmpty => hosted,
        _ => 'https://pub.dev',
      };
  final release = '$name $version';

  // Asked first where a version out already is a skip: everything below is
  // about an upload that would not happen.
  var asked = false;
  if (package.alreadyServed == AlreadyServed.skip) {
    switch (await _served(context, probe, registry, name, version)) {
      case null:
        return ExitCode.taskFailed;
      case true:
        context.log('⊘ $registry already serves $release — nothing to publish');
        return ExitCode.success;
      case false:
        asked = true;
    }
  }

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

  // What pub itself would pack, against what git tracks. `git status` does
  // not show what git ignores, and pub does not read every ignore git does:
  // a `.pubignore` stops it reading the `.gitignore` beside it, and
  // `.git/info/exclude` it never reads. A file ignored by one and not the
  // other is uploaded from a state that exists on one machine.
  final dryRun = await context.capture([
    'dart',
    'pub',
    'publish',
    '--dry-run',
  ], workingDirectory: package.directory);
  final shipped = publishedFiles(dryRun.stdout);
  if (shipped == null) {
    // Its exit code is no verdict — a dry run with warnings answers 65 — but
    // a run that listed nothing leaves what would be uploaded unknown.
    final said = [
      dryRun.stdout.trim(),
      dryRun.stderr.trim(),
    ].where((text) => text.isNotEmpty);
    context.log(
      '`dart pub publish --dry-run` (exit ${dryRun.exitCode}) listed no '
      'files, so what would be uploaded is not known:\n${said.join('\n')}',
    );
    return ExitCode.taskFailed;
  }
  // From the package, not the root: a package that is a git submodule is
  // tracked by its own repository, of which the superproject's
  // `git ls-files` sees only the gitlink. Asked in the package, git answers
  // from whichever repository the package belongs to, with paths from it.
  final tracked = await context.capture([
    'git',
    'ls-files',
    '-z',
  ], workingDirectory: package.directory);
  if (tracked.exitCode != 0) {
    context.log(
      '`git ls-files` failed (exit ${tracked.exitCode}), so whether git '
      'tracks what pub would upload is not known: ${tracked.stderr.trim()}',
    );
    return ExitCode.taskFailed;
  }
  if (untrackedRefusal(
        package.directory,
        shipped: shipped,
        tracked: tracked.stdout
            .split('\u0000')
            .where((path) => path.isNotEmpty),
      )
      case final refusal?) {
    context.log(refusal);
    return ExitCode.taskFailed;
  }

  if (!asked) {
    final served = await _served(context, probe, registry, name, version);
    if (served == null) {
      return ExitCode.taskFailed;
    }
    if (served) {
      context.log(
        '$registry already serves $release, and a version is never uploaded '
        'twice; bump the version',
      );
      return ExitCode.taskFailed;
    }
  }

  context.log('publishing $release to $registry');
  final published = await context.run([
    'dart',
    'pub',
    'publish',
    '--force',
  ], workingDirectory: package.directory);
  if (published != ExitCode.success) {
    String why;
    try {
      if ((await probe(registry, name)).contains(version)) {
        context.log(
          '`dart pub publish` answered $published, but ✓ $registry serves '
          '$release: the upload went through',
        );
        return ExitCode.success;
      }
      // 65 is pub refusing before anything went up — its validation, its
      // credentials — and only that is proof of nothing uploaded. Any other
      // failure, the 1 of an upload that broke, can come after the archive
      // was accepted and before the registry lists it.
      if (published == _pubRefused) {
        context.log(
          '`dart pub publish` refused $release ($published) and $registry '
          'does not serve it, so it was not uploaded',
        );
        return ExitCode.taskFailed;
      }
      why = '$registry does not list it yet';
    } on Object catch (error) {
      why = error is RegistryUnavailable ? error.reason : '$error';
    }
    context.log(
      '`dart pub publish` answered $published, and whether $release may have '
      'been uploaded is not known — $why. Look at $registry before '
      'publishing it again',
    );
    return ExitCode.continuationFailed;
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
    } on Object catch (error) {
      // After the upload, a registry that cannot be asked is one more reason
      // to look again, not a verdict: what is being waited out is the
      // registry catching up. Whatever the probe threw — a project's own
      // probe may throw anything — since a crash here would end the run as a
      // `1`, the one answer the upload rules out.
      why = error is RegistryUnavailable ? error.reason : '$error';
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

/// Whether [registry] serves [version] of [name], before the upload — or
/// null, said, where it could not be asked.
///
/// Before the upload a registry that cannot be asked is a refusal, not a
/// "probably not published": the upload is the step that cannot be taken
/// back, so it does not start on a guess.
Future<bool?> _served(
  VerbContext context,
  RegistryProbe probe,
  String registry,
  String name,
  String version,
) async {
  try {
    return (await probe(registry, name)).contains(version);
  } on RegistryUnavailable catch (error) {
    context.log(
      'whether $registry already serves $name $version is not known — '
      '${error.reason} — so nothing was uploaded',
    );
    return null;
  }
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

/// Why what pub would upload of [package] is not what git tracks, or null
/// when every file of it is tracked.
///
/// [shipped] is [publishedFiles] and [tracked] is `git ls-files`, both from
/// the package. Only that way round: a tracked file pub leaves out is what a
/// `.pubignore` is for.
///
/// A tracked entry covers what is under it. Git keeps a committed link to a
/// directory as one entry, and a nested submodule as one gitlink, while pub
/// follows either and lists the files beneath; each of those is what that
/// entry commits to, not a file git has never seen.
String? untrackedRefusal(
  String package, {
  required List<String> shipped,
  required Iterable<String> tracked,
}) {
  final inGit = tracked.toSet();
  bool covered(String path) {
    for (var at = path; at != '.'; at = p.posix.dirname(at)) {
      if (inGit.contains(at)) {
        return true;
      }
    }
    return false;
  }

  final untracked = [
    for (final path in shipped)
      if (!covered(path)) path,
  ];
  if (untracked.isEmpty) {
    return null;
  }
  return 'pub would upload these from $package, which git does not track — '
      'a `.pubignore` stops pub reading the `.gitignore` beside it, and it '
      'never reads `.git/info/exclude`; list them in `.pubignore` or commit '
      'them first:\n'
      '${untracked.map((path) => '  $path').join('\n')}';
}

/// The files `dart pub publish --dry-run` lists in [dryRun], its output, by
/// their paths in the package and written with `/`; null where it lists
/// none.
///
/// Read from the tree pub draws, in Unicode or — on a terminal without it —
/// in ASCII. A line is a directory where the next one is deeper, and a file
/// otherwise, which ends with its size in parentheses; telling them apart by
/// what follows, not by the parentheses, keeps a file named `a (1 KB).dart`
/// what it is.
List<String>? publishedFiles(String dryRun) {
  final lines = const LineSplitter().convert(
    dryRun.replaceAll(RegExp('\x1B\\[[0-9;]*m'), ''),
  );
  final header = lines.indexWhere(
    (line) => line.startsWith('Publishing ') && line.endsWith(':'),
  );
  if (header < 0) {
    return null;
  }
  final entry = RegExp(r"^((?:[│|]   |    )*)(?:├── |└── |\|-- |'-- )(.*)$");
  final entries = <(int, String)>[];
  for (final line in lines.skip(header + 1)) {
    final match = entry.firstMatch(line);
    if (match == null) {
      break;
    }
    entries.add((match[1]!.length ~/ 4, match[2]!));
  }
  final files = <String>[];
  final above = <String>[];
  for (final (index, (depth, name)) in entries.indexed) {
    above.length = depth;
    final next = index + 1 < entries.length ? entries[index + 1].$1 : -1;
    if (next > depth) {
      above.add(name);
    } else {
      files.add(
        [...above, name.replaceFirst(RegExp(r' \([^()]*\)$'), '')].join('/'),
      );
    }
  }
  return files.isEmpty ? null : files;
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
/// **Parsed as YAML, the way pub reads it**, so a value quoted, folded or
/// written in flow style means here what it means to pub. Throws a
/// [FormatException] where [text] is not YAML or not a map, and where the
/// value is something other than a string — `version: 1.0` is a number, and
/// pub refuses it; reading it back as text would let a publish start on a
/// manifest pub will not take.
String? manifestField(String text, String key) =>
    switch (readPubspec(text)[key]) {
      null => null,
      final String value => value,
      _ => throw FormatException('`$key:` is not a string'),
    };

Future<void> _delay(Duration delay) => Future<void>.delayed(delay);
