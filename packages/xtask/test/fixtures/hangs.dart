// A process that never finishes on its own, for the one test that has to kill
// something real. Waiting on a Completer that is never completed is portable
// and needs no `sleep` binary; the timer keeps the isolate from being told
// there is nothing left to do.
import 'dart:async';
import 'dart:io';

Future<void> main() async {
  // **It gives up on its own, well outside every test's patience.** If the
  // engine's kill ever stops working, the suite must go red rather than hang:
  // this process inherits the test runner's stdout, so one that never dies
  // keeps the runner alive forever and a broken timeout would look like a
  // frozen machine instead of a failing test.
  Timer(const Duration(seconds: 30), () => exit(9));
  Timer.periodic(const Duration(seconds: 1), (_) {});
  await Completer<void>().future;
}
