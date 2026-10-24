/// Completing a command line in a shell — `--names` and `--completion`.
///
/// **The scripts know the command line; the names come from the file.** A
/// script carries the flags, because they are this engine's and do not change
/// between repositories, and asks `xtask --names` for everything a file
/// declares, at the moment TAB is pressed — so a task added a minute ago
/// completes without anything being regenerated, and a script generated once
/// keeps working in every repository.
library;

import 'gates.dart';
import 'model.dart';
import 'request.dart';

/// `--names`: every gate set, task and set the file declares, one per line,
/// as `kind<TAB>name<TAB>description`.
///
/// Gate sets first, in the order `gates:` declares them — the names a person
/// types most — then tasks and sets in the file's order. A gate set's
/// description is what it runs, which is the question its name leaves open.
List<String> names(XtaskFile file) => [
  for (final gate in file.gates.keys)
    _line('gate', gate, tasksInGate(file, gate).map((t) => t.name).join(', ')),
  for (final task in file.tasks.values) _line('task', task.name, task.desc),
  for (final MapEntry(key: name, value: set) in file.sets.entries)
    _line('set', name, switch (set) {
      ValueSet() => 'set of values',
      ListSet() => 'set of paths',
      GlobSet() => 'set of paths a glob finds',
    }),
];

/// One line of [names]. A tab inside a field would be read as the next one,
/// so it is written as the space it looks like.
String _line(String kind, String name, String description) =>
    [kind, name, description].map((f) => f.replaceAll('\t', ' ')).join('\t');

/// Every option the command line takes, as a script offers them after `-`.
List<String> get completedOptions => [
  ...modes,
  ...runOptions,
  '--help',
]..sort();

/// The options a value follows, which is what a script completes after them.
List<String> get _takingAValue => [
  ...modesTakingAName,
  ...modesTakingAnOptionalName,
  ...runOptionsTakingAValue,
]..sort();

/// What a script offers after an option that takes a value.
enum _Value { gates, tasks, gatesAndTasks, sets, shells, jobs, files }

/// What follows [option].
///
/// **The one table, and every shell is rendered from it.** It was three — a
/// `case` in bash, one in zsh, a list in fish — beside the parser's own, and
/// the next option to take a value would have had to be added to all four.
/// An option the parser says takes a value and this does not know is a
/// script that cannot be written, and every script is written by a test.
_Value _after(String option) => switch (option) {
  '--gate' || '--gate-members' => _Value.gates,
  '--why' => _Value.tasks,
  '--dry-run' || '--graph' => _Value.gatesAndTasks,
  '--only' => _Value.sets,
  '--completion' => _Value.shells,
  '--jobs' => _Value.jobs,
  '--check-schema' || '--report' => _Value.files,
  _ => throw StateError(
    '`$option` takes a value, and no completion script knows what it is',
  ),
};

/// The kinds `--names` gives, as a [_Value] that is names asks for them.
String _kinds(_Value value) => switch (value) {
  _Value.gates => 'gate',
  _Value.tasks => 'task',
  _Value.gatesAndTasks => 'gate task',
  _Value.sets => 'set',
  _ => throw StateError('$value is not a kind of name'),
};

/// The completion script for [shell], one of [completionShells].
String completionScript(String shell) => switch (shell) {
  'bash' => _bash(),
  'zsh' => _zsh(),
  'fish' => _fish(),
  _ => throw ArgumentError.value(shell, 'shell'),
};

/// [option] as a `case` pattern, with `-j` beside `--jobs`.
String _pattern(String option) => option == '--jobs' ? '-j|--jobs' : option;

/// [template] with each `@KEY@` replaced — so a script is written as the
/// shell reads it, rather than through a second layer of Dart escapes.
String _fill(String template, Map<String, String> values) =>
    values.entries.fold(
      template,
      (text, entry) => text.replaceAll('@${entry.key}@', entry.value),
    );

String _bash() {
  String arm(String option) {
    final value = _after(option);
    final words = switch (value) {
      _Value.shells => completionShells.join(' '),
      _Value.jobs => 'auto',
      _Value.files => '',
      _ =>
        r'$(_xtask_names '
            "'${_kinds(value)}')",
    };
    final reply = switch (value) {
      _Value.files => r'$(compgen -f -- "$cur")',
      _Value.sets => '\$(compgen -S = -W "$words" -- "\$cur")',
      _ => '\$(compgen -W "$words" -- "\$cur")',
    };
    return [
      '    ${_pattern(option)})',
      // `compopt` is bash 4's, and macOS ships 3.2: there the `=` is
      // followed by a space, which is all that is lost.
      if (value == _Value.sets) '      compopt -o nospace 2>/dev/null',
      '      COMPREPLY=($reply) ;;',
    ].join('\n');
  }

  return _fill(_bashTemplate, {
    'ARMS': _takingAValue.map(arm).join('\n'),
    'OPTIONS': completedOptions.join(' '),
  });
}

const _bashTemplate = r'''
# xtask completion for bash. Load it from ~/.bashrc with:
#   source <(xtask --completion bash)
_xtask_names() {
  xtask --names 2>/dev/null | awk -F '\t' -v kinds="$1" \
    'index(" " kinds " ", " " $1 " ") { print $2 }'
}
_xtask() {
  # The words as the line has them. COMP_WORDS splits at `:` and `=` as well,
  # so a task called `web:build` would be three of them.
  local line=${COMP_LINE:0:COMP_POINT} cur= prev word
  local -a words
  read -ra words <<< "$line"
  if [[ $line != *[[:space:]] ]]; then
    cur=${words[${#words[@]}-1]}
    unset "words[${#words[@]}-1]"
  fi
  prev=${words[${#words[@]}-1]}
  COMPREPLY=()
  for word in "${words[@]:1}"; do
    # After `--` the words are the task's own arguments.
    if [[ $word == -- ]]; then
      COMPREPLY=($(compgen -f -- "$cur"))
      return
    fi
  done
  # `--gate=check` is the option and its value in one word: the value is
  # completed as it would be after `--gate `. Bash replaces the word from its
  # last break character on, so where `=` is not one, the answer has to
  # carry the option back with it.
  local kept=
  if [[ $cur == --*=* ]]; then
    prev=${cur%%=*}
    cur=${cur#*=}
    [[ $COMP_WORDBREAKS == *=* ]] || kept="$prev="
  fi
  case $prev in
@ARMS@
    *)
      if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W "@OPTIONS@" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "$(_xtask_names 'gate task')" -- "$cur"))
      fi
      ;;
  esac
  # Where `:` breaks words — it does unless somebody took it out — bash
  # replaces only what follows the last one, so that is the part of each
  # answer it is given.
  if [[ $cur == *:* && $COMP_WORDBREAKS == *:* ]]; then
    local colon=${cur%"${cur##*:}"}
    COMPREPLY=("${COMPREPLY[@]#"$colon"}")
  fi
  if [[ -n $kept ]]; then
    COMPREPLY=("${COMPREPLY[@]/#/$kept}")
  fi
}
complete -F _xtask xtask
''';

String _zsh() {
  String arm(String option) {
    final value = _after(option);
    final action = switch (value) {
      _Value.shells => 'compadd -- ${completionShells.join(' ')}',
      _Value.jobs => 'compadd -- auto',
      _Value.files => '_files',
      _Value.sets => '_xtask_names set; _describe set reply -S =',
      _ => "_xtask_names '${_kinds(value)}'; _describe name reply",
    };
    return '    ${_pattern(option)}) $action ;;';
  }

  return _fill(_zshTemplate, {
    'ARMS': _takingAValue.map(arm).join('\n'),
    'OPTIONS': completedOptions.join(' '),
  });
}

const _zshTemplate = r'''
#compdef xtask
# xtask completion for zsh. Load it from ~/.zshrc, after compinit, with:
#   source <(xtask --completion zsh)
_xtask_names() {
  # `name:description`, with a colon inside a name escaped, as `_describe`
  # reads it.
  local kind name rest
  reply=()
  xtask --names 2>/dev/null | while IFS=$'\t' read -r kind name rest; do
    [[ " $1 " == *" $kind "* ]] && reply+=("${name//:/\\:}:$rest")
  done
}
_xtask() {
  local -a reply
  # After `--` the words are the task's own arguments.
  if (( ${words[(I)--]} && ${words[(I)--]} < CURRENT )); then
    _files
    return
  fi
  local prev=${words[CURRENT-1]}
  # `--gate=check` is the option and its value in one word: the value is
  # completed as it would be after `--gate `.
  if [[ $PREFIX == --*=* ]]; then
    prev=${PREFIX%%=*}
    compset -P 1 '*='
  fi
  case $prev in
@ARMS@
    *)
      if [[ $PREFIX == -* ]]; then
        compadd -- @OPTIONS@
      else
        _xtask_names 'gate task'; _describe 'gate set or task' reply
      fi
      ;;
  esac
}
compdef _xtask xtask
''';

String _fish() {
  String line(String option) {
    final name = option == '--jobs'
        ? '-s j -l jobs'
        : '-l ${option.substring(2)}';
    if (!_takingAValue.contains(option)) {
      return 'complete -c xtask $name';
    }
    final value = _after(option);
    return switch (value) {
      _Value.shells =>
        "complete -c xtask $name -x -a '${completionShells.join(' ')}'",
      _Value.jobs => 'complete -c xtask $name -x -a auto',
      _Value.files => 'complete -c xtask $name -r -F',
      _Value.sets =>
        'complete -c xtask $name -x -a '
            r"""'(__xtask_names set | string replace -r -- "\t" "=\t")'""",
      _ => "complete -c xtask $name -x -a '(__xtask_names ${_kinds(value)})'",
    };
  }

  return _fill(_fishTemplate, {
    'OPTIONS': completedOptions.map(line).join('\n'),
  });
}

const _fishTemplate = r'''
# xtask completion for fish. Load it with:
#   xtask --completion fish | source
# or keep it in ~/.config/fish/completions/xtask.fish.
function __xtask_names
    xtask --names 2>/dev/null | string match -r -- '^('(string join '|' $argv)')\t.*' \
        | string replace -r -- '^[^\t]*\t' ''
end
# After `--` the words are the task's own arguments.
function __xtask_after_separator
    contains -- -- (commandline -opc)
end
complete -c xtask -f
complete -c xtask -n 'not __xtask_after_separator' -a '(__xtask_names gate task)'
complete -c xtask -n __xtask_after_separator -F
@OPTIONS@
''';
