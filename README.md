# xtask

A task runner whose tasks are **data**: an `xtask.yaml`, run without a shell.

The package, and everything about using it, is in
[`packages/xtask`](packages/xtask/README.md).

This repository is a Dart workspace. Its own tasks are in
[`xtask.yaml`](xtask.yaml) and run through its own entry point,
[`bin/xtask.dart`](bin/xtask.dart):

```shell
dart run :xtask check
```

To put this checkout's engine on the PATH instead of the published one:

```shell
dart install "xtask@{path: $PWD/packages/xtask}"
```
