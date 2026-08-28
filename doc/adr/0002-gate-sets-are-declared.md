# A gate set is declared, not inferred from the tasks that name it

`gates:` lists every gate set at the top of the file, even though the list is
derivable from the tasks' own `gate:` keys. Inferred, a gate set came into
existence by being mentioned, so `gate: [chekc]` was not a misspelling — it was
a new gate set with one member, which nothing ran and nothing could report as
missing. One transposed letter, a green result nobody checked. Declaring costs
a line and buys three things: a misspelling is a refusal, `--list` can group by
something complete, and the declaration order is an order a report can use.
