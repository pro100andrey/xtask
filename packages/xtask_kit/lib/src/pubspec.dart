/// Reading a `pubspec.yaml`, once for every verb that asks one something.
library;

import 'package:yaml/yaml.dart';

/// [text], a `pubspec.yaml`, as the map pub reads it.
///
/// One reading for the package, so that what counts as a pubspec — YAML, and
/// a map at the top — is decided in one place rather than in each verb that
/// asks it a question, where one would drift from the other. Throws a
/// [FormatException] where [text] is not YAML or not a map.
Map<Object?, Object?> readPubspec(String text) => switch (loadYaml(text)) {
  final Map<Object?, Object?> document => document,
  _ => throw const FormatException('a pubspec is a map'),
};
