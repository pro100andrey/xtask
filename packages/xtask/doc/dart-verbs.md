# Dart verbs

For a Dart repository with a job that has real logic in it — read this when a
`run:` body would need a condition, a loop or a pipe, which the file has no way
to say.

## Your own entry point

The only thing here that needs Dart code is a **verb**: a
function of your own for a job with real logic in it. An engine somebody else
shipped cannot contain your function, so you hand it over from a file of yours:

```shell
dart run :xtask <task>
```

That file is `bin/xtask.dart`, and it is the whole of what a project writes:

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

A verb is ordinary Dart — testable, typed, debuggable:

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

The engine ships **no** project verbs — `regen` above is one repository's
business, not the tool's. Its only built-in is `remove`.

The file name *is* the declaration: `dart run :xtask` resolves to
`bin/xtask.dart` and nothing else, so nothing has to name it to make that work.
(`pubspec.yaml` does carry an `executables:` entry, and it is there for
`dart install` — which fails outright without one — not for `dart run`.)

The colon in `dart run :xtask` is the whole difference from
`dart run xtask:xtask`, and it is easy to read past: what is written to the
left of it is which package the executable comes from, and an empty left side
means yours. Without a `bin/xtask.dart` of your
own the short spelling fails with `Could not find bin/xtask.dart in package
<yours>`, which is a truthful error and a baffling one if nobody said the file
was optional.

`dart install xtask` puts a real `xtask` on the PATH, compiled, and for a
repository whose tasks are all `run:` that is the pleasant way to work.

A project that registers a **verb** has its own `bin/xtask.dart`, and that is
where the verb is: what gets installed is this package's entry point, which
cannot contain a Dart function of your repository. So the installed `xtask`
looks for one. Where the directory holding `xtask.yaml` has a `bin/xtask.dart`,
it hands the whole run to it and answers with its exit code — `xtask install`
then means exactly what `dart run :xtask install` means, verbs, pinned version
and all.

An entry point kept anywhere else is named in the file, from the root:

```yaml
version: 1
entry: tools/bin/xtask.dart   # a tools package of its own
```

Its package is the nearest `pubspec.yaml` at or above it — `tools/` here, not
the root — and `--validate` says so when the file is not there or is in no
package. The project's entry is started where you are standing, so relative
paths on the command line keep meaning what they meant:

- `dart run <package>:xtask`, when the entry point is its package's
  `bin/xtask.dart` and the package resolution nearest to you is that
  package's own — from the package, or from any package of its workspace
  where it says `resolution: workspace`. It costs what `dart run :xtask`
  costs, about a third of a second, on top of the installed binary's start.
- `dart run <path>/<entry>`, otherwise: from outside that resolution, or for
  an entry point that is any other file. Correct, and slower: a file is
  compiled every time. A resolution that only depends on the package — an
  `example/` beside a library, a root depending on its tools package — gets
  this form too: it has the package but not the package's
  `dev_dependencies`, which is where `xtask` usually is.
- When the package has never been resolved, or its `pubspec.yaml`,
  `pubspec.lock` or `pubspec_overrides.yaml` is newer than its resolution
  (or it has no lock), as after a pull that brought a dependency:
  `dart pub get` in it, then the file, still from where you stand, and the
  resolution is marked current as `dart run` marks it — a `pub get` that
  changes nothing writes nothing, so without the mark a touched lock would
  cost one on every run. The name form needs none of this, since `dart run`
  does the same check itself.
  `dart run :xtask` in the package would resolve it too, but only by moving
  the run there, and every relative path you typed (`--report`,
  `--check-schema`, …) would be read from the wrong directory.

A workflow step running that file — `dart run tools/bin/xtask.dart check`, or
an entry point with a name of its own — is a gate set's invocation to
`--check-ci`, as `xtask check` is. A file named in `entry:` is matched by its
whole path, `./` or a directory before it allowed: with `entry:
tool/main.dart`, `dart run bin/main.dart serve` is the application, not a
gate set. Under a `working-directory:` written out, a relative path is read
from that directory: `dart run bin/main.dart check` in `tool` is the entry
point.

`--completion` is not handed over, and neither is `--names`, which a
completion script asks on every TAB, while the installed engine can read the
file — only a file written for a newer `xtask` sends it to the project.
Arguments after `--` are a task's and decide nothing here. A task that runs
`xtask` hands over again, as the person typing it would; a run handed over
eight times deep is taken for a loop (`XTASK_HAND_OVERS` counts) and refused
with `2`. Without `dart` on `PATH` the installed `xtask` says so and answers
`3`; a `dart pub get` that fails is shown and answered `1`; otherwise the code
is the project's, and an entry point that does not compile is `dart run`'s
`254` or `255`. Where `dart` is a batch file (`dart.bat`, as Flutter puts on
`PATH`), a command line carrying a character `cmd.exe` would read — `&`, `|`,
`%`, … — is refused with `2` before anything runs; the SDK's `dart.exe`
ahead of it on `PATH` has no such limit. In this package itself there is
nothing to hand over to: its `bin/xtask.dart` is the installed one. Each of
those refusals writes the `--report` the command line asked for, as the
engine's own refusals do: the run that would have written it never starts.
So does a project that is started and ends before its engine has written a
word — an entry point that does not compile: the report says it ended with
that code, rather than being the last run's.

What an interrupt does to a run handed over this way, on each platform, is in
[Ctrl-C, and SIGTERM](internals-and-platforms.md#when-the-installed-xtask-handed-the-run-over).

`dart run` pays the JIT's start-up — around half a second, every invocation. It
is nothing against a gate that spends seconds inside a test runner, and it is
the entire cost of `--gate-members`, `--why` or `--dry-run`, which is where a
shell loop or a file being written notices it. `dart compile exe
bin/xtask.dart` removes it. The binary still reads `xtask.yaml` at run time, so
tasks, gates and sets keep changing without recompiling; verbs are Dart, so a
binary holds the ones it was built with and wants rebuilding after one changes.
This repository keeps its own invocation as the `aot` task rather than a second
copy in this file — `xtask --dry-run aot` prints it.

An entry point that has to ask the file something before it hands the run
over — which tasks a gate set holds, to choose among them — need not start a
second engine for the answer and pay that half second again. Two functions
read it in-process, from the code the command line answers from:

```dart
final root = findRoot(Directory.current.path);   // the directory holding
                                                 // xtask.yaml, or null
final members = gateMembers('check');            // what --gate-members prints
```

`gateMembers` looks for the file from `workingDirectory:` upwards (left out,
from where the process runs) and answers the gate set's tasks in run order. It
is the code `--gate-members` itself runs, so where that command refuses —
no `xtask.yaml` here or above, one that cannot be read or does not parse, a
gate set the file does not declare — the function throws
`XtaskFormatException` carrying the same message. A declared gate set with no
members is `[]`. Neither function runs a task or reads anything but the file.

## Testing a verb

A verb is a function of a `VerbContext`, so a test builds one and calls it —
no engine, no file, no process:

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
same way, as `relay` stands behind `tee`, and are needed only by a verb that
calls them — one that does and
was not given them is told so, rather than answered "not found". `out` is a
sink over `log` unless one is given; call `context.out.flush()` before
reading `logged` if the verb's last line may lack a newline.
