/// A published version's place in git — a tag, pushed — and on GitHub — a
/// release of its changelog's entry — for [publishToPub] to make right after
/// its upload, and for [tagRelease] to make for a version published before.
///
/// @docImport 'publish.dart';
library;

import 'dart:convert';

import 'package:xtask/xtask.dart';

import 'publish.dart' show changelogNames, manifestField;

/// The tag of a package's version where a repository publishes several
/// packages, each on its own: `xtask_kit-v0.2.0`. The form pub.dev's
/// publishing from GitHub Actions asks for, `{{version}}` the version and
/// `{{name}}` the package; a repository of one package may say
/// `v{{version}}`.
const releaseTagPattern = '{{name}}-v{{version}}';

/// The tag [pattern] gives [name]'s [version]: `{{name}}` and `{{version}}`
/// replaced. Throws an [ArgumentError] where [pattern] has no `{{version}}`,
/// since every version would then get the same tag.
String releaseTag(String pattern, String name, String version) {
  if (!pattern.contains('{{version}}')) {
    throw ArgumentError.value(pattern, 'pattern', 'has no {{version}}');
  }
  return pattern
      .replaceAll('{{name}}', name)
      .replaceAll('{{version}}', version);
}

/// What [text], a changelog, says under its heading of [version] — the lines
/// after it, up to the next heading of its level or above, trimmed — or null
/// where no heading names [version] as [changelogNames] reads one.
String? changelogEntry(String text, String version) {
  final lines = const LineSplitter().convert(text);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.startsWith('#') || !changelogNames(line, version)) {
      continue;
    }
    final level = _level(line);
    final entry = <String>[];
    for (var j = i + 1; j < lines.length; j++) {
      final next = lines[j];
      if (next.startsWith('#') && _level(next) <= level) {
        break;
      }
      entry.add(next);
    }
    return entry.join('\n').trim();
  }
  return null;
}

int _level(String heading) {
  var level = 0;
  while (level < heading.length && heading[level] == '#') {
    level++;
  }
  return level;
}

/// `do:` a verb tagging a version published before: its arguments are the
/// package, from the root, and the commit it was published from, `HEAD`
/// where there is none ([tagRelease]).
Verb pubTagRelease({
  String pattern = releaseTagPattern,
  String changelog = 'CHANGELOG.md',
}) => (context) async {
  if (context.args.isEmpty || context.args.length > 2) {
    context.log(
      'give the package, its path from the root, and the commit it was '
      'published from (HEAD where none is given)',
    );
    return ExitCode.invalidFile;
  }
  return tagRelease(
    context,
    context.args.first,
    commit: context.args.length == 2 ? context.args[1] : 'HEAD',
    pattern: pattern,
    changelog: changelog,
  );
};

/// Tags the version of the package at [directory] (from the root) that the
/// `pubspec.yaml` of [commit] names, at that commit, and answers with an
/// [ExitCode]: `0` where the tag is there and pushed to [remote] and, with
/// `gh` on the PATH, the GitHub release of the tag is there too.
///
/// - The version, and the release's notes, are [commit]'s: its manifest's,
///   and its [changelog]'s entry for the version ([changelogEntry]), which
///   has to have one, as a publish does. A version published from an older
///   commit is tagged by naming that commit.
/// - The tag is annotated, `<name> <version>`, as [pattern] names it
///   ([releaseTag]).
/// - Run again, it makes what is missing: a tag already at [commit], here
///   or on [remote], is kept, and a release already there is left as it is.
///   A tag at another commit is a refusal, `1`, here or on [remote] — a
///   tag moved under somebody who fetched it is the one thing this must not
///   do.
/// - Without `gh` on the PATH, the release is not made, and that is said: the
///   tag is the part that cannot wait.
Future<int> tagRelease(
  VerbContext context,
  String directory, {
  String commit = 'HEAD',
  String pattern = releaseTagPattern,
  String changelog = 'CHANGELOG.md',
  String remote = 'origin',
}) async {
  Future<Captured> git(List<String> args) =>
      context.capture(['git', ...args], workingDirectory: context.root);

  final resolved = await git(['rev-parse', '--verify', '$commit^{commit}']);
  if (resolved.exitCode != 0) {
    context.log('no commit $commit to tag: ${resolved.stderr.trim()}');
    return ExitCode.taskFailed;
  }
  final sha = resolved.stdout.trim();
  final at = directory == '.' || directory.isEmpty ? '' : '$directory/';

  final manifest = await git(['show', '$sha:${at}pubspec.yaml']);
  if (manifest.exitCode != 0) {
    context.log('$commit has no ${at}pubspec.yaml: ${manifest.stderr.trim()}');
    return ExitCode.invalidFile;
  }
  final String? name;
  final String? version;
  try {
    name = manifestField(manifest.stdout, 'name');
    version = manifestField(manifest.stdout, 'version');
  } on FormatException catch (error) {
    context.log('${at}pubspec.yaml of $commit: ${error.message}');
    return ExitCode.invalidFile;
  }
  if (name == null || version == null) {
    context.log(
      '${at}pubspec.yaml of $commit names no '
      '${name == null ? 'package' : 'version'}, so there is nothing to tag',
    );
    return ExitCode.invalidFile;
  }
  final release = '$name $version';
  if (!pattern.contains('{{version}}')) {
    context.log(
      'the tag pattern $pattern has no {{version}}, so every version would '
      'get the same tag',
    );
    return ExitCode.invalidFile;
  }
  final tag = releaseTag(pattern, name, version);

  final log = await git(['show', '$sha:$at$changelog']);
  final notes = log.exitCode == 0 ? changelogEntry(log.stdout, version) : null;
  if (notes == null) {
    context.log(
      '$at$changelog of $commit names no $version in a heading, so '
      '$release has no notes to release with',
    );
    return ExitCode.taskFailed;
  }

  // here: made where missing, a refusal where it is at another commit
  final local = await git([
    'rev-parse',
    '-q',
    '--verify',
    'refs/tags/$tag^{commit}',
  ]);
  if (local.exitCode == 0) {
    if (local.stdout.trim() != sha) {
      context.log(
        'the tag $tag is at ${local.stdout.trim()}, not at $sha: a tag is '
        'not moved; delete it first if it is wrong',
      );
      return ExitCode.taskFailed;
    }
  } else {
    final made = await git(['tag', '-a', tag, '-m', release, sha]);
    if (made.exitCode != 0) {
      context.log('`git tag $tag` failed: ${made.stderr.trim()}');
      return ExitCode.taskFailed;
    }
    context.log('tagged $release at $sha as $tag');
  }

  // on the remote: the same, the commit read from the peeled line
  // the peeled line, the commit an annotated tag is at, is listed only
  // where it is asked for by name too
  final listed = await git([
    'ls-remote',
    '--tags',
    remote,
    'refs/tags/$tag',
    'refs/tags/$tag^{}',
  ]);
  if (listed.exitCode != 0) {
    context.log(
      'whether $remote has $tag is not known: `git ls-remote` failed: '
      '${listed.stderr.trim()}',
    );
    return ExitCode.taskFailed;
  }
  final there = _peeled(listed.stdout, tag);
  if (there == null) {
    final pushed = await git(['push', remote, 'refs/tags/$tag']);
    if (pushed.exitCode != 0) {
      context.log('`git push $remote $tag` failed: ${pushed.stderr.trim()}');
      return ExitCode.taskFailed;
    }
    context.log('pushed $tag to $remote');
  } else if (there != sha) {
    context.log(
      '$remote has $tag at $there, not at $sha: a tag is not moved; '
      'delete it there first if it is wrong',
    );
    return ExitCode.taskFailed;
  }

  if (context.which('gh') == null) {
    context.log(
      'no gh on the PATH, so $tag has no GitHub release; make it with '
      '`gh release create $tag`',
    );
    return ExitCode.success;
  }
  final viewed = await context.capture([
    'gh',
    'release',
    'view',
    tag,
  ], workingDirectory: context.root);
  if (viewed.exitCode == 0) {
    context.log('⊘ the GitHub release $tag is there already');
    return ExitCode.success;
  }
  // gh takes no empty notes: a version with none is released under its name
  final body = notes.isEmpty ? release : notes;
  final created = await context.capture([
    'gh',
    'release',
    'create',
    tag,
    '--verify-tag',
    '--title',
    release,
    '--notes',
    body,
  ], workingDirectory: context.root);
  if (created.exitCode != 0) {
    context.log(
      '`gh release create $tag` failed: ${created.stderr.trim()}; the tag '
      'is pushed, and running this again makes the release',
    );
    return ExitCode.taskFailed;
  }
  context.log('✓ released $tag on GitHub');
  return ExitCode.success;
}

/// The commit [tag] is at in [listing], what `git ls-remote --tags` answers
/// for it: the peeled `^{}` line of an annotated tag, else its own line;
/// null where it is not listed.
String? _peeled(String listing, String tag) {
  String? own;
  for (final line in const LineSplitter().convert(listing)) {
    final parts = line.split('\t');
    if (parts.length != 2) {
      continue;
    }
    if (parts[1] == 'refs/tags/$tag^{}') {
      return parts[0];
    }
    if (parts[1] == 'refs/tags/$tag') {
      own = parts[0];
    }
  }
  return own;
}
