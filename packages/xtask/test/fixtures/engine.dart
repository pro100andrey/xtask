// The engine as a project's own entry point would start it, for the tests
// that send it a real signal. It writes its own pid first: the process the
// test started is `dart run`, and a signal meant for the engine has to reach
// the engine and not the wrapper around it.
import 'dart:io';

import 'package:xtask/xtask.dart';

Future<void> main(List<String> args) async {
  File('engine.pid').writeAsStringSync('$pid');
  exitCode = await runXtask(
    args,
    verbs: {
      // A verb that starts a program and waits for it: the verb itself is
      // Dart nothing can stop, so what a signal can reach is the program.
      'hold': (context) async {
        final code = await context.run(['sh', '-c', _holds]);
        context.log('the verb went on after its program, which answered $code');
        return code;
      },
    },
  );
}

// `exec`, so the pid the body writes is the process the engine started.
const _holds = r'echo $$ > body.pid; exec sleep 60';
