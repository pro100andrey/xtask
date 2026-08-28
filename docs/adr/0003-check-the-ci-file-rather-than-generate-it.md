# The CI file is checked against the gate sets, not generated from them

Generating the workflow (`--emit-ci`) was considered and refused. A workflow
contains what this tool deliberately leaves to it — the checkout, the
toolchain, a browser driver, an artifact upload — so generating one means
somewhere to write those down, which means a template inside `xtask.yaml`,
which is templating; the first `${…}` in it is the start of an expression
language, and the file not being a language is the whole design.

`--check-ci` closes the same drift and needs none of that: it reads the
workflow a person wrote and compares it with the gate sets in both directions.

## Consequences

A step is recognised by being handed to the command line's own parser, so
`--check-ci` and `xtask` cannot disagree about what a step would do. A gate set
no job runs is reported and **not** judged: nothing in the file distinguishes
"a person runs this by hand" from "a job was forgotten", and a key that claimed
to would be a second place saying what the workflow already says.
