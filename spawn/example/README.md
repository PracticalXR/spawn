# spawn examples

One worker, two platforms, the same code.

`workers/primes_worker.dart` is the worker: an ordinary Dart file with a
handler in it and a `main` that hands the handler to `runWorker`. Nothing is
generated and nothing is annotated.

## Native

```console
$ dart run example/spawn_example.dart
worker started: SpawnCaps(hosted: dart, payload: aot, zeroCopyTransfer: true)
sieve of 2000001 bytes arrived
primes found: 148933
worker refused: ArgumentError: Invalid argument (request): unknown request: "nonsense"
sieve of 100001 bytes arrived
observer saw an event too
closed cleanly, error: null
```

No build step: `spawn` calls the handler in a new isolate directly.

## Web

```console
$ dart run spawn:build example/workers
  primes_worker  built  (98 kB)
$ dart compile js -O2 -o example/web/main.dart.js example/web/main.dart
$ dart pub global activate dhttpd && dart pub global run dhttpd --path example/web
```

Open the page. The spinner is driven by a `setInterval` on the main thread; it
keeps turning while the worker sieves two million numbers. Comment out the
`spawn` call and run the sieve inline to see what the alternative looks like.

`spawn:build` is only needed for the web, and only for workers you wrote
yourself. A package that ships workers ships the compiled payloads as assets,
so its consumers run nothing.
