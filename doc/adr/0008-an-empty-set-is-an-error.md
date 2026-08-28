# A set that expands to nothing is refused, with one narrow exception

A task whose set came back empty runs its body with no arguments, and `dart
format` with no arguments formats the whole tree. The quieter case is worse:
inside a gate the set was empty, the task passed, the gate went green and
nothing was checked. A pattern matches nothing for two reasons — the repository
genuinely has none, and the pattern is broken — and in a gate the second is the
dangerous one, so there is no key to soften this.

The exception is `produced: true`, which says the members are made by the run
itself. It buys exactly one thing: the emptiness of that set is not judged
before its task has run. Everything else about it still is — the repository
boundary, the pattern syntax — and a run still refuses it empty.
