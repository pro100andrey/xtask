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

/// The completion script for [shell], one of [completionShells].
String completionScript(String shell) => switch (shell) {
  'bash' => _bash,
  'zsh' => _zsh,
  'fish' => _fish,
  _ => throw ArgumentError.value(shell, 'shell'),
};

String get _bash =>
    '''
# xtask completion for bash. Load it from ~/.bashrc with:
#   source <(xtask --completion bash)
_xtask_names() {
  xtask --names 2>/dev/null | awk -F '\\t' -v kinds="\$1" \\
    'index(" " kinds " ", " " \$1 " ") { print \$2 }'
}
_xtask() {
  local cur=\${COMP_WORDS[COMP_CWORD]} prev=\${COMP_WORDS[COMP_CWORD-1]} word
  for word in "\${COMP_WORDS[@]:1:COMP_CWORD-1}"; do
    # After `--` the words are the task's own arguments.
    if [[ \$word == -- ]]; then
      COMPREPLY=(\$(compgen -f -- "\$cur"))
      return
    fi
  done
  case \$prev in
    --gate|--gate-members)
      COMPREPLY=(\$(compgen -W "\$(_xtask_names gate)" -- "\$cur")); return ;;
    --why)
      COMPREPLY=(\$(compgen -W "\$(_xtask_names task)" -- "\$cur")); return ;;
    --dry-run)
      COMPREPLY=(\$(compgen -W "\$(_xtask_names 'gate task')" -- "\$cur"))
      return ;;
    --only)
      compopt -o nospace
      COMPREPLY=(\$(compgen -S = -W "\$(_xtask_names set)" -- "\$cur")); return ;;
    --completion)
      COMPREPLY=(\$(compgen -W "${completionShells.join(' ')}" -- "\$cur"))
      return ;;
    -j|--jobs)
      COMPREPLY=(\$(compgen -W auto -- "\$cur")); return ;;
    --check-schema)
      COMPREPLY=(\$(compgen -f -- "\$cur")); return ;;
  esac
  if [[ \$cur == -* ]]; then
    COMPREPLY=(\$(compgen -W "${completedOptions.join(' ')}" -- "\$cur"))
  else
    COMPREPLY=(\$(compgen -W "\$(_xtask_names 'gate task')" -- "\$cur"))
  fi
}
complete -F _xtask xtask
''';

String get _zsh =>
    '''
#compdef xtask
# xtask completion for zsh. Load it from ~/.zshrc, after compinit, with:
#   source <(xtask --completion zsh)
_xtask_names() {
  # `name:description`, with a colon inside a name escaped, as `_describe`
  # reads it.
  local line kind name rest
  reply=()
  xtask --names 2>/dev/null | while IFS=\$'\\t' read -r kind name rest; do
    [[ " \$1 " == *" \$kind "* ]] && reply+=("\${name//:/\\\\:}:\$rest")
  done
}
_xtask() {
  local -a reply
  if (( \${words[(I)--]} && \${words[(I)--]} < CURRENT )); then
    _files
    return
  fi
  case \${words[CURRENT-1]} in
    --gate|--gate-members) _xtask_names gate; _describe 'gate set' reply ;;
    --why) _xtask_names task; _describe task reply ;;
    --dry-run) _xtask_names 'gate task'; _describe 'gate set or task' reply ;;
    --only) _xtask_names set; _describe set reply -S = ;;
    --completion) compadd -- ${completionShells.join(' ')} ;;
    -j|--jobs) compadd -- auto ;;
    --check-schema) _files ;;
    *)
      if [[ \$PREFIX == -* ]]; then
        compadd -- ${completedOptions.join(' ')}
      else
        _xtask_names 'gate task'; _describe 'gate set or task' reply
      fi
      ;;
  esac
}
compdef _xtask xtask
''';

String get _fish =>
    '''
# xtask completion for fish. Load it with:
#   xtask --completion fish | source
# or keep it in ~/.config/fish/completions/xtask.fish.
function __xtask_names
    xtask --names 2>/dev/null | string match -r -- '^('(string join '|' \$argv)')\\t.*' \\
        | string replace -r -- '^[^\\t]*\\t' ''
end
complete -c xtask -f
complete -c xtask -n 'not __fish_seen_argument -l --' -a '(__xtask_names gate task)'
complete -c xtask -l gate -x -a '(__xtask_names gate)' -d 'narrow --list to one gate set'
complete -c xtask -l gate-members -x -a '(__xtask_names gate)' -d 'the tasks in a gate set'
complete -c xtask -l why -x -a '(__xtask_names task)' -d 'what puts a task in a plan'
complete -c xtask -l dry-run -x -a '(__xtask_names gate task)' -d 'print the resolved plan'
complete -c xtask -l only -x -a '(__xtask_names set | string replace -r -- "\\t" "=\\t")' -d 'narrow a set'
complete -c xtask -l completion -x -a '${completionShells.join(' ')}' -d 'a completion script'
complete -c xtask -l check-schema -r -F -d 'does that file match --emit-schema?'
complete -c xtask -s j -l jobs -x -a auto -d 'run n at once'
${[for (final option in completedOptions)
      if (!_fishTakesAValue.contains(option)) "complete -c xtask -l ${option.substring(2)}"].join('\n')}
''';

/// The options the fish script completes a value for, above, rather than
/// only offering by name.
const _fishTakesAValue = {
  '--gate',
  '--gate-members',
  '--why',
  '--dry-run',
  '--only',
  '--completion',
  '--check-schema',
  '--jobs',
};
