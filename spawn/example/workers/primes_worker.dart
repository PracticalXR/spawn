// A worker entrypoint. On native `spawn` calls [primesWorker] directly; on the
// web `dart run spawn:build example/workers` compiles this file's `main` into
// the payload a Worker loads.
//
// Nothing here is generated, annotated, or special: it is a Dart file with a
// function in it.

import 'dart:typed_data';

import 'package:spawn/spawn.dart';

/// Sieves primes, and answers how many it found.
///
/// The sieve is deliberately slow enough to be felt: run the same work on the
/// main thread and a UI stutters, which is the whole reason this file exists.
Future<void> primesWorker(WorkerChannel channel) async {
  var lastCount = 0;

  channel.handleRequests((request) {
    if (request == 'count') return lastCount;
    throw ArgumentError.value(request, 'request', 'unknown request');
  });

  await for (final message in channel.messages) {
    final limit = message! as int;
    final sieve = Uint8List(limit + 1);
    var count = 0;
    for (var candidate = 2; candidate <= limit; candidate++) {
      if (sieve[candidate] != 0) continue;
      count++;
      for (
        var multiple = candidate * 2;
        multiple <= limit;
        multiple += candidate
      ) {
        sieve[multiple] = 1;
      }
    }
    lastCount = count;

    // The sieve is ours and we are done with it, so hand the memory over
    // instead of copying it.
    channel.send(sieve, transfer: <Object>[sieve.buffer]);
  }
}

/// The worker's identity. One `const`, next to the worker itself.
const primesEntry = SpawnEntry.inline(
  primesWorker,
  asset: 'packages/spawn/workers/primes_worker',
);

void main() => runWorker(primesWorker);
