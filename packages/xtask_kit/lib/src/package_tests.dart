/// Running one package's tests with the runner the package needs: `flutter
/// test` where it depends on the Flutter SDK, `dart test` where it does not.
library;

import 'package:path/path.dart' as p;
import 'package:xtask/xtask.dart';
import 'package:yaml/yaml.dart';

/// `do:` a verb running one package's tests ([runPackageTests]).
///
/// **The project's opt-in to a choice the engine refuses to make.** The
/// engine never picks `flutter` or `dart` by reading a pubspec: a body is
/// what the file says, and a file that said `test` and ran either is a file
/// whose meaning depends on what it is pointed at. A project whose packages
/// are of both kinds otherwise splits one suite into a task per runner, and
/// keeps the split in step by hand as packages come and go; registering this
/// verb is the project saying, in Dart, that the pubspec decides.
///
/// ```yaml
/// pkg-test:
///   desc: every package's tests, with the runner each needs
///   each: packages
///   in: $each
///   do: tests
///   args: [--reporter=failures-only]
/// ```
///
/// `in: $each` because a task with `each:` has to write `$each` somewhere,
/// or the engine refuses it: the member is what tells the runs apart.
Verb packageTests() => runPackageTests;

/// Runs the tests of the package [context] is for, and answers with an
/// [ExitCode].
///
/// The package is the nearest directory with a `pubspec.yaml`, from the
/// member of `each:` up — so a set whose members are the packages'
/// directories, their `pubspec.yaml` files, or paths inside them all work —
/// or, outside `each:`, from the task's own directory (its `in:`). The
/// runner is started in that directory, not the root's: a package with
/// native assets builds them only for the package `dart test` starts in.
///
/// The task's `args:` and what follows `--` go to the runner, after `test`.
///
/// A package without `test/` is skipped, and the verb says so and succeeds:
/// both runners fail there, and a package without tests is no failure of its
/// tests. A failing suite answers 1 whatever number the runner gave, because
/// what a verb answers is read against [ExitCode]'s table, which a test
/// runner has never heard of.
///
/// A runner that is not installed is a 3 ([ExitCode.missingTool]), not a
/// failed suite: "Flutter is not on this machine" is repaired by somebody
/// other than whoever repairs a test. Asked before it starts
/// ([VerbContext.which]) rather than read from the code it answered with,
/// because a runner may answer 3 for reasons of its own.
///
/// It refuses, naming why, a member in no package, and a `pubspec.yaml` that
/// cannot be read.
Future<int> runPackageTests(VerbContext context) async {
  final from =
      context.member ??
      p.relative(context.workingDirectory, from: context.root);
  final package = _packageOf(context, from);
  if (package == null) {
    context.log('no pubspec.yaml in $from or above it');
    return ExitCode.invalidFile;
  }
  if (!context.directory(_join(package, 'test')).existsSync()) {
    context.log('$package: skipped, no test/');
    return ExitCode.success;
  }
  final pubspec = _join(package, 'pubspec.yaml');
  final bool flutter;
  try {
    flutter = usesFlutter(context.file(pubspec).readAsStringSync());
  } on FormatException catch (error) {
    context.log('$pubspec cannot be read: ${error.message}');
    return ExitCode.taskFailed;
  }
  final argv = [if (flutter) 'flutter' else 'dart', 'test', ...context.args];
  if (context.which(argv.first, workingDirectory: package) == null) {
    context.log(
      '$package: `${argv.first}` is not on PATH, and its tests need it',
    );
    return ExitCode.missingTool;
  }
  context.log('$package: ${argv.join(' ')}');
  final code = await context.run(argv, workingDirectory: package);
  return code == ExitCode.success ? ExitCode.success : ExitCode.taskFailed;
}

/// Whether the package whose `pubspec.yaml` is [pubspec] needs `flutter
/// test`: whether anything in its `dependencies` or `dev_dependencies` comes
/// from the Flutter SDK (`sdk: flutter`).
///
/// `dev_dependencies` as well, because a package whose code is pure Dart and
/// whose tests are widget tests takes `flutter_test` there and nothing else.
/// Only what the pubspec names: a package that reaches Flutter only through
/// another package of its own is not seen, and its pubspec is where to say
/// so — which it has to anyway for `flutter_test`.
///
/// Throws a [FormatException] when [pubspec] is not YAML, or not a map.
bool usesFlutter(String pubspec) {
  final document = loadYaml(pubspec);
  if (document is! Map) {
    throw const FormatException('a pubspec is a map');
  }
  for (final section in ['dependencies', 'dev_dependencies']) {
    if (document[section] case final Map<Object?, Object?> dependencies) {
      for (final dependency in dependencies.values) {
        if (dependency case {'sdk': 'flutter'}) {
          return true;
        }
      }
    }
  }
  return false;
}

/// The package [path] is in, from the root and written with `/`: [path]
/// itself — or its directory, where it names a `pubspec.yaml` — or the
/// nearest directory above with a `pubspec.yaml`, the root's included; null
/// when there is none.
///
/// With `/` because it is handed back to [VerbContext.run] and shown, both
/// of which take a path the way the file writes one.
String? _packageOf(VerbContext context, String path) {
  final segments = [
    for (final segment in p.split(p.normalize(path)))
      if (segment != '.') segment,
  ];
  if (segments.isNotEmpty && segments.last == 'pubspec.yaml') {
    segments.removeLast();
  }
  while (true) {
    final directory = segments.isEmpty ? '.' : segments.join('/');
    if (context.file(_join(directory, 'pubspec.yaml')).existsSync()) {
      return directory;
    }
    if (segments.isEmpty) {
      return null;
    }
    segments.removeLast();
  }
}

String _join(String directory, String name) =>
    directory == '.' ? name : '$directory/$name';
