// A process that refuses to be asked politely, for the one test that has to
// prove SIGTERM is followed by SIGKILL. Watching a signal replaces Dart's
// default handler for it, so the process simply carries on.
import 'dart:async';
import 'dart:io';

Future<void> main() async {
  ProcessSignal.sigterm.watch().listen((_) {});
  // **It gives up on its own, well outside every test's patience.** If the
  // engine's kill ever stops working, the suite must go red rather than hang:
  // this process inherits the test runner's stdout, so one that never dies
  // keeps the runner alive forever and a broken timeout would look like a
  // frozen machine instead of a failing test.
  Timer(const Duration(seconds: 30), () => exit(9));
  Timer.periodic(const Duration(seconds: 1), (_) {});
  await Completer<void>().future;
}
