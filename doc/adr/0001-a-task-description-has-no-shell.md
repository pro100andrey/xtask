# A task's description contains no shell

A `run:` body is argv — the program, then its arguments, each its own entry —
and nothing splits a string or expands a variable before the child sees it. The
alternative is a command line, which means a shell, which means `xtask.yaml`
says one thing on POSIX and another on Windows and a third under `dash`; every
portability problem this tool exists to remove arrives back through that door.
The cost is real and accepted: `FOO=bar cmd`, `a && b`, `$(…)` and `>` cannot be
written, so `env:`, `needs:`/`then:`, a verb, and a person's own shell are what
replace them.
