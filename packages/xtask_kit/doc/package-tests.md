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

A package without `test/` is skipped with a line, and succeeds. A runner that
is not on `PATH` — `flutter` on a machine with only Dart — answers `3`, asked
before it starts. A member in no package is refused with `2`; a `pubspec.yaml`
that is not YAML answers `1`, naming the file.

What the runner answers is translated to the engine's table rather than
passed on, which the runner has never heard of, and not flattened to `1`,
since three of its endings are not a failing suite. The numbers are measured
from `dart test` and `flutter test`:

| The runner answers | When | The task answers |
| --- | --- | --- |
| `0` | every test passed | `0` |
| `79` | no test ran: a `--name` or `--tags` this package has nothing for, or a `test/` with no test file | `0`, with a line saying so — no tests of the kind asked for is no failure of them, as with no `test/` |
| `64`, `65` | the runner refused an argument in `args:`, or its `dart_test.yaml`, before any test began | `2`: the request was wrong, not the code |
| `130` | the engine stopped it — an `interruptible:` suite after an earlier failure | `130`, so the run reports it stopped rather than failed |
| killed by a signal | nobody in the run sent it | `128` and the signal, as a shell says it: `137` for a `SIGKILL` |
| anything else | a failing test, one that does not compile, a timeout, the runner's own crash | `1` |

A runner does not answer `130` or `143` on its own: `dart test` sent a
`SIGINT` or a `SIGTERM` exits `1`. A run stopped by Ctrl-C is reported as stopped by
the engine whatever the task answers. `flutter test` answers `1` for a
`test/` with no test file, so there it is a failure.

## On Windows

Nothing differs: the runner is found on `PATH` and started by the engine as
any `run:` body's program is, so Flutter's `flutter.bat` is found as `flutter`.

## As functions

`runPackageTests` is the same as a function, and `usesFlutter` the check on
its own.
