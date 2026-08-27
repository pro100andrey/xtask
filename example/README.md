# A project using `xtask`

Two files, and one of them is optional until a task needs Dart.

`xtask.yaml` is the whole task graph — four tasks, one gate set, one set of
paths. `xtask check` runs the three members in the order they are written; the
CI job runs the same command and names nothing else.

`bin/xtask.dart` exists only because one task has a `do:`. A **verb** is a
function this project wrote, so no engine installed from pub.dev can contain
it: the project hands it over, and that is the whole of the entry point.

```shell
xtask --list          # every task, with its description
xtask --dry-run check # what would run, resolved on this machine
xtask check           # run it
```

The rest — the keys, the exit codes, what `-j` costs — is in the
[package README](https://pub.dev/packages/xtask).
