/// What an invocation asks for — the grammar of the command line, once.
///
/// **Once, because the second copy is what this tool exists to remove.** The
/// command line is parsed here and nowhere else: `--check-ci` has to decide
/// whether a workflow step is a well-formed invocation, and it used to answer
/// that by walking the words itself — attached values, `--jobs=` against
/// `-j4`, a lone `-`, a second operand. Two readings of one grammar, and both
/// had already been wrong: `-j4` swallowed the gate set after it, and a lone
/// `-` raised a `RangeError` out of `--check-ci` instead of a diagnostic.
/// `flags.dart` shared the constants between them, which is half a fix — the
/// constants were never the part that drifted.
///
/// So a step is checked by being parsed, and what comes back is a value both
/// readers ask questions of.
library;

import 'dart:io';

/// The file, at the repository root (§4).
const xtaskFileName = 'xtask.yaml';

/// What an invocation asked for.
///
/// Parsed into a value first and acted on second, so that every refusal §7
/// implies — two modes at once, a flag that is not one, `--gate` without the
/// `--list` it narrows — can be asserted without a filesystem, a plan or a
/// process anywhere near it.
sealed class Request {
  const Request();
}

/// `xtask <task> [-- <args>]` — run it and everything it needs.
final class RunTask extends Request {
  const RunTask(
    this.task, {
    this.arguments = const [],
    this.keepGoing = false,
    this.concurrency = 1,
  });

  final String task;

  /// What followed `--`, for [task]'s body alone.
  final List<String> arguments;

  /// `--keep-going`: report every failure rather than the first.
  final bool keepGoing;

  /// `-j`: how many tasks may be in flight. 1 is §5.2's run.
  final int concurrency;
}

/// `xtask --dry-run <task> [-- <args>]` — print what that would come to (§7).
final class DryRunTask extends Request {
  const DryRunTask(this.task, [this.arguments = const []]);

  final String task;

  /// What followed `--`, for [task]'s body alone.
  final List<String> arguments;
}

/// `xtask --list [--gate <name>]` — every task with its description.
final class ListTasks extends Request {
  const ListTasks(this.gate);

  /// The gate set to narrow to, or null for all of them.
  final String? gate;
}

/// `xtask --gate-members <name>` — the members of one gate set, one per line.
///
/// **A window on the data, not the mechanism.** No pipeline consumes this:
/// the duplicate list disappears because CI stops naming commands and runs one
/// task per job (§7.1), not because something reads this output. That is why
/// the format is one name per line — right for a person reading, and wrong for
/// feeding a build matrix, which it is not for.
final class GateMembers extends Request {
  const GateMembers(this.gate);

  final String gate;
}

/// `xtask --check-ci` — does the workflow still run the gate sets (§7.1)?
final class CheckCi extends Request {
  const CheckCi();
}

/// `xtask --validate` — parse and check, run nothing (§8).
final class Validate extends Request {
  const Validate();
}

/// `xtask --why <task>` — what puts that task in a plan.
final class WhyTask extends Request {
  const WhyTask(this.task);

  final String task;
}

/// `xtask --version` — print which engine this is.
///
/// Answered without a file, for the same reason as [EmitSchema]: it is a fact
/// about the engine. It is also the first thing a bug report needs, which is
/// no use if it only works in a directory that already works.
final class ShowVersion extends Request {
  const ShowVersion();
}

/// `xtask --emit-schema` — print the JSON Schema for the file format.
///
/// **The one request that does not want a file.** It describes what an
/// `xtask.yaml` may contain, which is a fact about the engine and not about
/// any repository — so it is answered before the file is looked for, and works
/// in a directory that has none. That is the point: it is how a repository
/// gets its first one.
final class EmitSchema extends Request {
  const EmitSchema();
}

/// The usage text, printed on request and as the error message.
final class ShowUsage extends Request {
  const ShowUsage([this.problem]);

  /// What was wrong with the invocation, or null when the usage was asked for.
  final String? problem;
}

/// The modes, exactly §7's list.
///
/// Public because the usage text has to name every one of them, and a test
/// that checked it against a list of its own would be a third copy of this —
/// drift between the parser and its own help being the sort that survives
/// review, since both halves read plausibly on their own.
const modes = {
  '--check-ci',
  '--list',
  '--why',
  '--gate-members',
  '--validate',
  '--dry-run',
  '--emit-schema',
  '--version',
};

/// How wide `-j auto` may go, whatever the machine is.
///
/// **A job here is a whole toolchain.** One unit is a `dart test` or a `dart
/// analyze`, each already multi-threaded and each holding an analysis server.
/// On a 32-core workstation, one per core is 32 of them.
const autoJobsCap = 8;

/// How many processors this machine has.
///
/// **A parameter, not a reading, and the doc comment above is why.** This
/// function promises an invocation becomes a value with nothing ambient
/// touched, and `-j auto` was the one line that broke the promise: the same
/// arguments produced a different [RunTask] on a different machine, and the
/// cap could not be proved to fire from a machine narrower than the cap.
int hostProcessors() => Platform.numberOfProcessors;

/// What [args] asked for, or a [ShowUsage] naming what was wrong with it.
///
/// Hand-written rather than configured into a general parser: the grammar is
/// six lines and closed, and what matters about it is the refusals, which are
/// easier to state exactly than to arrange. Both spellings of the narrowing
/// flag — `--gate=name` and `--gate name` — are accepted, because both are
/// what people type.
Request parseArguments(
  List<String> args, {
  int Function() processors = hostProcessors,
}) {
  if (args.isEmpty) {
    return const ShowUsage('nothing to do');
  }

  final written = <String>[];
  final operands = <String>[];
  String? gate;
  var narrowed = false;
  var keepGoing = false;
  var concurrency = 1;
  var jobsWritten = false;

  final passed = <String>[];
  var separated = false;

  final rest = [...args];
  while (rest.isNotEmpty) {
    final argument = rest.removeAt(0);

    // **Everything after it is taken as written, options included.** That is
    // the whole point of the separator: `xtask test -- --name x` has to reach
    // the body with `--name` intact, and a parser that kept looking at these
    // would refuse the first one it did not recognise.
    if (argument == '--') {
      separated = true;
      passed.addAll(rest);
      rest.clear();
      continue;
    }

    if (argument == '--help' || argument == '-h') {
      return const ShowUsage();
    }

    if (argument == '--gate' || argument.startsWith('--gate=')) {
      narrowed = true;
      gate = argument.startsWith('--gate=')
          ? argument.substring('--gate='.length)
          : rest.isNotEmpty && !rest.first.startsWith('-')
          ? rest.removeAt(0)
          : null;
      if (gate == null || gate.isEmpty) {
        return const ShowUsage('`--gate` needs the name of a gate set');
      }
      continue;
    }

    if (argument == '--keep-going') {
      keepGoing = true;
      continue;
    }

    // **`-j N`, in every spelling make and cargo and xargs already taught.**
    // `--parallel` read as a boolean and behaved as a number: bare, it meant
    // "as many as this machine has processors", so `--parallel 2` was a task
    // called `2` and needed a refusal of its own to explain its own syntax. A
    // flag that has to do that has the wrong syntax.
    if (argument == '-j' ||
        argument == '--jobs' ||
        argument.startsWith('-j') ||
        argument.startsWith('--jobs=')) {
      // Named `asked` rather than `written`: the enclosing `written` is the
      // list of modes, and shadowing it here made it unreachable by its own
      // name inside this block.
      final asked = switch (argument) {
        '-j' || '--jobs' => rest.isNotEmpty ? rest.removeAt(0) : null,
        final a when a.startsWith('--jobs=') => a.substring('--jobs='.length),
        final a => a.substring(2),
      };
      if (asked == null || asked.isEmpty) {
        return const ShowUsage(
          '`-j` needs a number of jobs, or `auto`. Bare, it would have to mean '
          'something, and every number a machine could pick is wrong on some '
          'other machine',
        );
      }
      jobsWritten = true;
      if (!isAJobCount(asked)) {
        return ShowUsage(
          '`-j $asked` is not a number of jobs. Write `-j <n>` with n at '
          'least 1, or `-j auto`',
        );
      }
      if (asked == 'auto') {
        final available = processors();
        concurrency = available < autoJobsCap ? available : autoJobsCap;
        continue;
      }
      concurrency = int.parse(asked);
      continue;
    }

    if (modes.contains(argument)) {
      written.add(argument);
      continue;
    }

    // **Both spellings, because `--gate` already took both.** A person who
    // learns `--gate=check` from the usage line writes `--why=test` next, and
    // what they used to get was "`--why=test` is not an option xtask has" — a
    // refusal that denies the flag exists rather than naming the form it
    // wants. The value joins the operands, where the mode below reads it as
    // if it had been written as its own word.
    final joined = modes.firstWhere(
      (mode) => argument.startsWith('$mode='),
      orElse: () => '',
    );
    if (joined.isNotEmpty) {
      written.add(joined);
      operands.add(argument.substring(joined.length + 1));
      continue;
    }

    if (argument.startsWith('-')) {
      return ShowUsage('`$argument` is not an option xtask has');
    }

    operands.add(argument);
  }

  if (written.length > 1) {
    return ShowUsage(
      '`${written[0]}` and `${written[1]}` ask for different things; '
      'write one',
    );
  }

  final mode = written.isEmpty ? null : written.single;

  if (narrowed && mode != '--list') {
    // `--gate` is a modifier, not a mode. It used to be one letter away from
    // `--gates`, which is why this refusal was written; the flag is now
    // `--gate-members` and cannot be reached by a slip of the finger, but a
    // `--gate` written without `--list` still has to be answered rather than
    // quietly ignored or listed past.
    return const ShowUsage(
      '`--gate` narrows `--list`. For the members of one gate set on their '
      'own, write `--gate-members <name>`',
    );
  }

  if (jobsWritten && mode != null) {
    // **Whether it was WRITTEN, not what it came to.** Testing the number let
    // `--list -j 1` through in silence, and made `--list -j auto` a refusal on
    // an eight-core machine and an acceptance on a one-core runner — the same
    // command line answering differently depending on the host.
    return ShowUsage(
      '`-j` is about a run, and `$mode` does not run anything',
    );
  }

  if (keepGoing && mode != null) {
    // It changes what a RUN does when something fails, and none of the modes
    // run anything. `--validate` in particular already collects every problem
    // it can find, which is the argument this flag borrows.
    return ShowUsage(
      '`--keep-going` is about a run, and `$mode` does not run anything',
    );
  }

  if (separated && mode != null && mode != '--dry-run') {
    // Only a body can take arguments, and only running or resolving one
    // reaches a body. `--list -- --name x` has nothing to hand them to, and
    // arguments that reach nothing are the silence this tool exists against.
    return ShowUsage(
      '`$mode` does not run anything, so there is nothing for the arguments '
      'after `--` to be arguments to',
    );
  }

  if (mode == '--list') {
    return operands.isEmpty
        ? ListTasks(gate)
        : ShowUsage(
            '`--list` takes no task name — to narrow it, write '
            '`--list --gate <name>`, and it was given `${operands.first}`',
          );
  }

  if (mode == '--version') {
    return operands.isEmpty
        ? const ShowVersion()
        : ShowUsage(
            '`--version` says which engine this is and takes nothing else, '
            'and it was given `${operands.first}`',
          );
  }

  if (mode == '--emit-schema') {
    return operands.isEmpty
        ? const EmitSchema()
        : ShowUsage(
            '`--emit-schema` describes the file format and takes nothing '
            'else, and it was given `${operands.first}`',
          );
  }

  if (mode == '--check-ci') {
    return operands.isEmpty
        ? const CheckCi()
        : ShowUsage(
            '`--check-ci` checks the whole workflow and takes no name, and it '
            'was given `${operands.first}`',
          );
  }

  if (mode == '--validate') {
    return operands.isEmpty
        ? const Validate()
        : ShowUsage(
            '`--validate` checks the whole file and takes no task name, and '
            'it was given `${operands.first}`',
          );
  }

  if (mode == '--why') {
    return operands.length == 1
        ? WhyTask(operands.single)
        : const ShowUsage('`--why` needs the name of one task');
  }

  if (mode == '--gate-members') {
    return operands.length == 1
        ? GateMembers(operands.single)
        : const ShowUsage('`--gate-members` needs the name of one gate set');
  }

  if (mode == '--dry-run') {
    return operands.length == 1
        ? DryRunTask(operands.single, passed)
        : const ShowUsage('`--dry-run` needs one task to resolve');
  }

  if (operands.isEmpty && separated) {
    return const ShowUsage(
      'the arguments after `--` belong to one task, and no task was named',
    );
  }

  return operands.length == 1
      ? RunTask(
          operands.single,
          arguments: passed,
          keepGoing: keepGoing,
          concurrency: concurrency,
        )
      : ShowUsage(
          'xtask runs one task at a time, and it was given '
          '${operands.map((o) => '`$o`').join(' and ')}',
        );
}

/// Whether [written] is a number of jobs this parser would accept.
bool isAJobCount(String written) =>
    written == 'auto' || (int.tryParse(written) ?? 0) >= 1;

/// §7's list, and the message a refused invocation prints.
const usage = [
  'usage:',
  '  xtask <task>                 run a task and everything it needs',
  '  xtask <task> -- <args>       and pass those arguments to its body',
  '  xtask <task> --keep-going    report every failure, not just the first —',
  '                               across tasks and across an `each:`',
  '  xtask <task> -j <n>          run n at once — which costs seeing their',
  '                               output as it arrives. `-j auto` picks one',
  '  xtask --list                 every task, grouped under its gate set,',
  '                               in the order `gates:` declares',
  '  xtask --list --gate <name>   only the tasks in that gate set',
  '  xtask --gate-members <name>  the tasks in that gate set, one per line',
  '  xtask --why <task>           what puts that task in a plan, and by which',
  '                               `needs:` or `then:`',
  '  xtask --validate             parse and check the file; run nothing',
  '  xtask --check-ci             does the CI file still run the gate sets?',
  '  xtask --dry-run <task>       print the resolved plan; run nothing',
  '  xtask --emit-schema          print the JSON Schema for this file format',
  '  xtask --version              print which engine this is',
  '',
  'the file is `$xtaskFileName`, at the repository root.',
];
