# Dart verbs

For a Dart repository with a job that has real logic in it. Read this when a
`run:` body would need a condition, a loop or a pipe, which the file cannot
say.

## Your own entry point

A **verb** is a Dart function of your own, named by a task's `do:`. An engine
somebody else shipped cannot contain your function, so you hand it over from a
file of yours, `bin/xtask.dart`, and run:

```shell
dart run :xtask <task>
```

That file is the whole of what a project writes:

```dart
import 'dart:io';

import 'package:xtask/xtask.dart';

Future<void> main(List<String> args) async {
  // Assigned, not discarded. `runXtask` answers with the run's exit code, and
  // `=> runXtask(args)` throws it away — the process then reports success for
  // every outcome, including the two that mean the file is wrong.
  exitCode = await runXtask(
    args,
    verbs: {
      'regen': regen,
    },
  );
}
```

A verb is ordinary Dart, so it can be tested, typed and debugged:

```dart
Future<int> regen(VerbContext context) async {
  context.log('regenerating ${context.args.length} files');
  // context.member   which member of `each:` this run is for, or null
  // context.run(...)  a program, started the way a `run:` body is —
  //                   PATH, PATHEXT, the batch rule, the exit codes.
  //                   `workingDirectory:` is a path from the repository
  //                   root, and stays inside it; left out, it is the task's
  // context.capture(...)
  //                   the same start, run to the end with its output kept:
  //                   `(exitCode:, stdout:, stderr:)`, each stream whole.
  //                   For a verb that has to read what a program said —
  //                   not `Process.run`, which loses everything above.
  //                   `timeout:` stops one that outlives it, with 124
  // context.tee(...)
  //                   `capture`, with the output shown as it arrives,
  //                   the way `run` shows it — for a program the verb
  //                   waits minutes on and then reads
  // context.which('code')
  //                   the file a start would find, or null — to decide
  //                   before starting anything. Takes the same
  //                   `workingDirectory:` `run` would be given
  // context.out      `log` as a StringSink, for a library that writes to
  //                  one; a last line without a newline is flushed for you
  // context.args     `args:` with `$all` expanded, then anything
  //                  the command line passed after `--`
  // context.env      this machine's environment, without `env-unset:`,
  //                  with `env:` and `env-paths:` winning a clash
  // context.root     the repository root, absolute — what a set's members
  //                  and `in:` are relative to
  // context.file('packages/a/x.dart'), context.directory(...)
  //                  a path from the root, written with `/` — a member as it
  //                  is — and a 2 for one that climbs or links out of it
  // context.workingDirectory
  //                  where the task runs: the root, or its `in:` under it —
  //                  what a `remove` argument is read from. A set's member
  //                  is `context.file(member)`, never joined onto this
  return 0;
}
```

The engine ships **no** project verbs. `regen` above is one repository's
business, not the tool's. The only built-in is `remove`.

Nothing has to name the file: `dart run :xtask` resolves to `bin/xtask.dart`
and nothing else. The `executables:` entry in `pubspec.yaml` is for `dart
install`, which fails without one, not for `dart run`.

The colon in `dart run :xtask` is the whole difference from `dart run
xtask:xtask`, and it is easy to read past. The left of the colon names the
package the executable comes from, and an empty left side means yours.
Without a `bin/xtask.dart` of your own, the short spelling fails with `Could
not find bin/xtask.dart in package <yours>`. That error is truthful, and
baffling if nobody said the file was optional.

### When the installed `xtask` hands the run over

`dart install xtask` puts a compiled `xtask` on the PATH. For a repository
whose tasks are all `run:`, that is the pleasant way to work.

A project that registers a verb has its own `bin/xtask.dart`, and the verb
lives there. The installed engine cannot contain a Dart function from your
repository, so it looks for one. Where the directory holding `xtask.yaml` has
a `bin/xtask.dart`, it hands the whole run to it and answers with its exit
code. `xtask install` then means exactly what `dart run :xtask install` means,
verbs and pinned version included.

An entry point kept anywhere else is named in the file, as a path from the
root:

```yaml
version: 1
entry: tools/bin/xtask.dart   # a tools package of its own
```

Its package is the nearest `pubspec.yaml` at or above it (`tools/` here, not
the root). `--validate` says so when the file is not there or is in no
package. The entry point is started where you are standing, so relative paths
on the command line keep their meaning. It is started in one of three ways:

- `dart run <package>:xtask`, when the entry point is its package's
  `bin/xtask.dart` and the package resolution nearest to you is that
  package's own: from the package, or from any package of its workspace that
  says `resolution: workspace`. It costs what `dart run :xtask` costs, about a
  third of a second on top of the installed binary's start.
- `dart run <path>/<entry>`, otherwise: from outside that resolution, or for an
  entry point that is any other file. Correct but slower, since a file is
  compiled every time. A resolution that only depends on the package (an
  `example/` beside a library, a root depending on its tools package) gets
  this form too. It has the package but not the package's
  `dev_dependencies`, which is usually where `xtask` is.
- `dart pub get` in the package first, then the file, still from where you
  stand. This happens when the package has never been resolved, or when its
  `pubspec.yaml`, `pubspec.lock` or `pubspec_overrides.yaml` is newer than its
  resolution (or it has no lock), as after a pull that brought a dependency.
  The resolution is then marked current, as `dart run` marks it; a `pub get`
  that changes nothing writes nothing, so without the mark a touched lock
  would cost one on every run. The name form needs none of this, because `dart
  run` does the same check itself. `dart run :xtask` in the package would
  resolve it too, but only by moving the run there, and every relative path
  you typed (`--report`, `--check-schema`, …) would be read from the wrong
  directory.

To `--check-ci`, a workflow step running that file is a gate set's invocation,
as `xtask check` is: `dart run tools/bin/xtask.dart check`, or an entry point
with a name of its own. A file named in `entry:` is matched by its whole path,
with `./` or a directory before it allowed. With `entry: tool/main.dart`,
`dart run bin/main.dart serve` is the application, not a gate set. Under a
`working-directory:` written out, a relative path is read from that directory:
`dart run bin/main.dart check` in `tool` is the entry point.

What is not handed over, and what is refused:

- `--completion` is not handed over, and neither is `--names`, which a
  completion script asks on every TAB. The installed engine can read the file
  itself; only a file written for a newer `xtask` sends them to the project.
- Arguments after `--` belong to a task and decide nothing here.
- A task that runs `xtask` hands over again, as a person typing it would. A run
  handed over eight times deep is taken for a loop (`XTASK_HAND_OVERS` counts)
  and refused with `2`.
- Without `dart` on `PATH`, the installed `xtask` says so and answers `3`. A
  `dart pub get` that fails is shown and answered `1`. Otherwise the code is
  the project's, and an entry point that does not compile answers `dart run`'s
  `254` or `255`.
- Ctrl-C or `SIGTERM` during that `dart pub get` stops it (`SIGTERM`, then
  `SIGKILL` after a grace), and the run is refused with `130` or `143`, as it
  is for one between the `pub get`'s end and the run's start. The `pub get` gets a stdin that ends at once,
  so one that asks a question is answered with nothing rather than waited on.
- Where `dart` is a batch file (`dart.bat`, as Flutter puts on `PATH`), a
  command line carrying a character `cmd.exe` would read (`&`, `|`, `%`, …) is
  refused with `2` before anything runs. The SDK's `dart.exe` ahead of it on
  `PATH` has no such limit.

Each of those refusals writes the `--report` the command line asked for, as
the engine's own refusals do, because the run that would have written it never
starts. So does a project that starts and ends before its engine has written a
word, such as an entry point that does not compile: the report says it ended
with that code, rather than still being the last run's. The report is begun,
`complete: false`, before anything is started, the `dart pub get` included. In
this package itself
there is nothing to hand over to: its `bin/xtask.dart` is the installed one.

What an interrupt does to a handed-over run, on each platform, is in
[Ctrl-C, and SIGTERM](internals-and-platforms.md#when-the-installed-xtask-handed-the-run-over).

### Compiling it

`dart compile exe bin/xtask.dart` removes the JIT start-up of `dart run`,
about half a second on every invocation. That is nothing against a gate that
spends seconds in a test runner, and it is the entire cost of
`--gate-members`, `--why` or `--dry-run`, which is where a shell loop or a
file being written notices it. The binary still reads `xtask.yaml` at run time, so tasks,
gates and sets keep changing without recompiling. Verbs are Dart, so a binary
holds the ones it was built with and needs rebuilding after one changes. This
repository keeps its own invocation as the `aot` task rather than as a second
copy here; `xtask --dry-run aot` prints it.

### Reading the file in-process

An entry point that has to ask the file something before it hands the run
over, such as which tasks a gate set holds, need not start a second engine and
pay that half second again. Two functions read it in-process, with the code
the command line answers from:

```dart
final root = findRoot(Directory.current.path);   // the directory holding
                                                 // xtask.yaml, or null
final members = gateMembers('check');            // what --gate-members prints
```

`gateMembers` looks for the file from `workingDirectory:` upwards (left out,
from where the process runs) and answers the gate set's tasks in run order. It
runs the same code as `--gate-members`, so where that command refuses, the
function throws `XtaskFormatException` with the same message: no
`xtask.yaml` here or above, one that cannot be read or does not parse, or a
gate set the file does not declare. A declared gate set with no members is
`[]`. Neither function runs a task or reads anything but the file.

## Testing a verb

A verb is a function of a `VerbContext`, so a test builds one and calls it,
with no engine, no file and no process:

```dart
final logged = <String>[];
final code = await regen(
  VerbContext(
    args: ['schema/a.proto'],
    env: const {},
    root: repo.path,
    workingDirectory: repo.path,
    log: logged.add,
    start: (argv, {workingDirectory}) async => 0,
  ),
);
expect(code, ExitCode.success);
```

`start` is how `context.run` starts a program, so a fake one records what the
verb asked for. `locate` and `collect` stand behind `which` and `capture` the
same way, and `relay` behind `tee`. A verb needs them only if it calls them;
one that does without being given them is told so, rather than answered "not
found". `out` is a sink over `log` unless one is given. Call
`context.out.flush()` before reading `logged` if the verb's last line may lack
a newline.
