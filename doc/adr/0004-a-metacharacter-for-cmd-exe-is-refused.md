# An argument `cmd.exe` would reinterpret is refused, not escaped

Windows cannot start a `.bat` or `.cmd` through `CreateProcess`, so its
arguments are parsed by `cmd.exe` whatever the caller intended — and `dart`,
`flutter` and everything `dart pub global activate` installs are batch shims
there. That leaves three options: quote for `cmd.exe` *and* let `Process.start`
quote for `CreateProcess` as well, which is two layers nobody can verify from a
machine that is not Windows; pass them through and let `&` end the command and
start another one silently; or refuse, name the character, and say what it
would have done.

The third is taken. It is a **stated** limit rather than an untested claim of
correctness, and it costs a task that genuinely wants `&` in an argument to a
batch file — which it can have by pointing at a real executable, or by becoming
a verb. It stops being needed the day a Windows CI machine can prove an
escaping pass right.
