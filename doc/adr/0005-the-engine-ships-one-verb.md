# The engine ships exactly one built-in verb, and it is a closed list

`remove` is the only verb the engine provides. A primitive is added only when a
real task needs it and only if it is total, argument-driven, and never branches
on the result of anything: `remove: [paths]` qualifies, `test -f X && Y` does
not. Without that rule the list grows into a portable shell — the failure the
npm ecosystem took, one package per utility (`rimraf`, `mkdirp`, `cross-env`,
`shx`), all of them existing only because `package.json` scripts are shell.

Everything else is a **verb**: ordinary project Dart, typed and debuggable,
which is where logic was always meant to go. A project verb may not shadow a
built-in, because two things answering to one name in `do:` is one of them
running when the file says the other.
