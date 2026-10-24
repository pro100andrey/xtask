import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/xtask.dart';
import 'package:yaml/yaml.dart';

/// Every `xtask.yaml` the README and `doc/` show passes the engine's
/// `--validate`.
///
/// Asked of the engine through `runXtask`, the public entry point, rather
/// than a parser of its own: a second reading of the file format could pass a
/// file the engine refuses. `--validate` runs nothing, so the verbs it is
/// handed are stubs named after the file's own `do:`.
void main() {
  final pages = [
    File('README.md'),
    ...Directory('doc').listSync().whereType<File>().where(
      (file) => file.path.endsWith('.md'),
    ),
  ];

  test('there are pages to read', () {
    expect(pages.length, greaterThan(1));
  });

  for (final page in pages) {
    final blocks = RegExp(
      r'^```yaml\n(.*?)^```',
      multiLine: true,
      dotAll: true,
    ).allMatches(page.readAsStringSync()).map((match) => match[1]!).toList();

    for (final (index, yaml) in blocks.indexed) {
      test('${page.path}, YAML example ${index + 1} validates', () async {
        final root = Directory.systemTemp.createTempSync('xtask_kit_docs_');
        addTearDown(() => root.deleteSync(recursive: true));
        File(p.join(root.path, 'xtask.yaml')).writeAsStringSync(yaml);
        // What the examples point at, so that a set or an `in:` that names
        // nothing is not what fails.
        for (final file in ['packages/my_pkg/pubspec.yaml', 'vscode/.keep']) {
          File(p.join(root.path, file))
            ..createSync(recursive: true)
            ..writeAsStringSync('name: my_pkg\n');
        }

        final tasks = (loadYaml(yaml) as YamlMap)['tasks'] as YamlMap;
        final verbs = <String, Verb>{
          for (final task in tasks.values.cast<YamlMap>())
            if (task['do'] case final String name)
              name: (context) async => ExitCode.success,
        };

        final code = await runXtask(
          ['--validate'],
          verbs: verbs,
          workingDirectory: root.path,
        );
        expect(code, ExitCode.success, reason: yaml);
      });
    }
  }
}
