# A project using `xtask`

Two files, and one of them is optional until a task needs Dart.

`xtask.yaml` is the whole task graph — three tasks, one gate set, one set of
paths. `xtask check` runs its members in the order they are written; the CI job
runs the same command and names nothing else.

`bin/xtask.dart` exists only because one task has a `do:`. A **verb** is a
function this project wrote, so no engine installed from pub.dev can contain
it: the project hands it over, and that is the whole of the entry point.

```shell
dart run :xtask --list          # every task, with its description
dart run :xtask --dry-run check # what would run, resolved on this machine
dart run :xtask check           # run it
```

`dart run :xtask` and not the installed `xtask`, because one task here has a
`do:` — and a verb is this project's own function, so no engine installed from
pub.dev contains it. That is what `bin/xtask.dart` is for, and what reaches it.

The rest — the keys, the exit codes, what `-j` costs — is in the
[package README](https://pub.dev/packages/xtask).
