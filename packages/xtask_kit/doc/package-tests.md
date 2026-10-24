# Tests, package by package

`packageTests()` runs one package's tests with the runner it needs: `flutter
test` where its pubspec takes anything from the Flutter SDK (`sdk: flutter`,
in `dependencies` or `dev_dependencies`), `dart test` where it does not. The
engine never makes that choice by reading a pubspec; registering the verb is
the project making it.

```dart
exitCode = await runXtask(args, verbs: {'tests': packageTests()});
```

```yaml
version: 1

sets:
  packages:
    include: [packages/*]
    containing: [pubspec.yaml]

tasks:
  pkg-test:
    desc: every package's tests, with the runner each needs
    each: packages
    in: $each
    do: tests
    args: [--reporter=failures-only]
```

## Which package, which arguments

The package is the nearest directory with a `pubspec.yaml` from the member up,
so a member can be the package's directory, its `pubspec.yaml`, or a path
inside it; without `each:` it is found from the task's `in:`. A task with
`each:` has to write `$each` somewhere, and `in: $each` is the place here —
`args:` go to the runner. The runner starts
in the package's directory, and the task's `args:` follow `test`.

## Refusals and exit codes

A package without `test/` is skipped with a line, and succeeds. A failing
suite answers `1`, whatever the runner said; a runner that is not on `PATH` —
`flutter` on a machine with only Dart — answers `3`, asked before it starts. A member in no package is refused
with `2`; a `pubspec.yaml` that is not YAML answers `1`, naming the file.

## On Windows

Nothing differs: the runner is found on `PATH` and started by the engine as
any `run:` body's program is, so Flutter's `flutter.bat` is found as `flutter`.

## As functions

`runPackageTests` is the same as a function, and `usesFlutter` the check on
its own.
