// Run with:
//
//     dart run example/spawn_example.dart
//
// The same code, unchanged, is what `example/web/main.dart` runs in a browser.

import 'dart:typed_data';

import 'package:spawn/spawn.dart';

import 'workers/primes_worker.dart';

Future<void> main() async {
  final worker = await spawn(primesEntry);
  print('worker started: ${worker.caps}');

  // Events arrive on a broadcast stream. Subscribing later is safe: nothing
  // sent before the first listener is lost.
  final subscription = worker.events.listen((event) {
    final sieve = event! as Uint8List;
    print('sieve of ${sieve.length} bytes arrived');
  });

  worker.post(2000000);
  await Future<void>.delayed(const Duration(milliseconds: 500));

  print('primes found: ${await worker.request<int>('count')}');

  // A request the worker refuses comes back as the error it threw, with the
  // original type and stack preserved.
  try {
    await worker.request<Object?>('nonsense');
  } on RemoteWorkerError catch (error) {
    print('worker refused: ${error.remoteType}: ${error.message}');
  }

  // A second client of the same worker: events fan out, commands merge.
  final observer = worker.attach();
  final observed = observer.events.listen(
    (_) => print('observer saw an event too'),
  );

  worker.post(100000);
  await Future<void>.delayed(const Duration(milliseconds: 200));

  await observed.cancel();
  await subscription.cancel();
  await worker.close();
  print('closed cleanly, error: ${worker.error}');
}
