# spawn

Background execution for Dart that works everywhere: isolates on native, Web
Workers on the web, one API. `spawn` is the missing web half of
`dart:isolate`, built to SDK conventions so your worker code — and your
mental model — stop forking per platform.

```dart
final worker = await spawn(peaksEntry);
worker.post(bytes, transfer: [bytes.buffer]);
await for (final event in worker.events) { ... }
```

## Why

- **One API, real parallelism on every platform.** `Isolate.spawn` on
  native; a compiled `Worker` payload on the web (where Dart has no
  isolates and `compute` runs on the main thread).
- **No annotations. No generated source. No build_runner.** A worker is an
  ordinary Dart file you can read and debug. The only build artifact is the
  compiled web payload itself.
- **The same rules on every platform.** A message that works in a VM test
  works in a browser, because `spawn` enforces one portability contract
  everywhere instead of letting each platform fail differently.
- **Zero-copy where the platform allows it**, and honest where it does not:
  explicit `transfer` lists, and a `caps` flag that tells you which you got.
- **Service lifetimes.** A worker can declare it needs to outlive the UI
  (media playback, capture); pluggable providers supply the OS machinery
  (foreground service, background audio) and `spawn` fails loudly — at
  spawn time, with the fix named — when the app lacks them.
- **Zero runtime dependencies.** Pure Dart on `dart:` libraries only
  (`dart:isolate`, `dart:js_interop`), like an SDK library should be.

## Getting started

**1. Write a worker** — an ordinary file under `lib/workers/`:

```dart
// lib/workers/peaks_worker.dart
import 'package:spawn/spawn.dart';

Future<void> peaksWorker(WorkerChannel channel) async {
  await for (final message in channel.messages) {
    final peaks = scan(message! as Uint8List);
    channel.send(peaks, transfer: [peaks.buffer]);
  }
}

// `main` makes this file the web compilation unit. It is never called on
// native — spawn() invokes [peaksWorker] directly.
void main() => runWorker(peaksWorker);
```

**2. Declare the entry** — one const, the only identity the worker has:

```dart
const peaksEntry = SpawnEntry.inline(
  peaksWorker,
  asset: 'packages/my_package/workers/peaks_worker',
);
```

**3. Build the web payload** (skip entirely for native-only use):

```console
$ dart run spawn:build
  peaks_worker  built  (312 kB)
spawn:build: 1 built, 0 up to date
```

**4. Spawn it:**

```dart
final worker = await spawn(peaksEntry);
```

Packages that ship workers ship the compiled payload as a package asset —
consumers of those packages run nothing, build nothing, configure nothing.

## Entries

| Constructor | Use | Notes |
|---|---|---|
| `SpawnEntry.inline` | most workers | one const; on web the handler also lands in the main bundle |
| `SpawnEntry.split` | bundle-sensitive workers | two-file conditional-import pattern keeps worker code out of the main web bundle (documented recipe, no magic) |
| `SpawnEntry.service` | must outlive the UI | adds `service:` — see below |
| `SpawnEntry.native` | C-hosted servers | reserved in v1 (`caps.hosted`, wire envelope); spawning one throws |

## What a message can be

Anything in the **portable set** crosses as itself: `null`, `bool`, `int`,
`double`, `String`, typed data, byte buffers, and `List`s and `String`-keyed
`Map`s of those.

Anything richer implements `WireMessage` — a type id and a byte encoding:

```dart
class ScanCmd implements WireMessage {
  ScanCmd(this.bytes);
  final Uint8List bytes;

  @override
  int get typeId => 1;

  @override
  Uint8List encode() => bytes;

  static ScanCmd decode(Uint8List bytes) => ScanCmd(bytes);
}

void registerScanProtocol() =>
    WireRegistry.instance.register(1, ScanCmd.decode);

const peaksEntry = SpawnEntry.inline(
  peaksWorker,
  asset: 'packages/my_package/workers/peaks_worker',
  protocol: registerScanProtocol, // runs on both ends
);
```

A registry belongs to one isolate or worker, so naming the registration
function on the entry is what keeps the two ends in step: `spawn` calls it on
the host, and the worker calls it before the handler runs. On the web, pass
the same function to `runWorker` in the payload's `main` — the payload never
sees the entry.

Anything outside both categories throws `ArgumentError` **on every platform**,
naming the offending value's path. That is deliberate: the VM would happily
copy an arbitrary object graph that a browser cannot carry, and a package
whose whole promise is one API should not let you write code that only works
in a test.

## Transfers

`transfer:` moves buffers instead of copying them. The rule that decides
whether it helps: **a buffer's cost is decided where it is born.** Bytes from
`fetch` or a `File` are already JS buffers and transfer free; browser media
objects move as handles; only bytes born on the Dart heap in a dart2wasm
payload must be copied out, because a WasmGC object can be neither
transferred nor shared.

| | what `transfer:` does |
|---|---|
| Web | a real move. The source `ArrayBuffer` is detached; reading it afterwards throws. |
| Native | the isolate message copy already hands the worker an independent buffer. A transfer entry that *is* the message — or the encoded bytes of a `WireMessage` — additionally skips that copy by crossing as `TransferableTypedData`. Other shapes fall back to the ordinary copy. |

Either way, treat a transferred buffer as gone. `worker.caps.zeroCopyTransfer`
reports what you actually got.

One-shot native results need nothing at all: `Isolate.run` already returns by
reference.

## Service workers

```dart
void main() async {
  SpawnServices.register(MyMediaServices()); // provides SpawnService.mediaPlayback
  runApp(...);
}

const playbackEntry = SpawnEntry.service(
  playbackWorker,
  asset: 'packages/my_package/workers/playback_worker',
  service: SpawnService.mediaPlayback,
);
```

A `.service` worker is not torn down with the widget tree; the registered
provider supplies the platform lifetime — on Android a foreground service
holding the engine (providers ship as ordinary Flutter plugin packages,
which is the only way Kotlin service classes and manifest entries can reach
an app build), on iOS the background-audio session, on the web the
no-`requestAnimationFrame` pacing contract. Grants are reference counted per
service, so N service workers share one platform service. Spawning without a
provider throws immediately:

```text
SpawnServiceUnavailableError: SpawnService.mediaPlayback has no provider.
Register one with SpawnServices.register(...) - media apps: add the
spawn_flutter package or your media-session package's provider.
```

`spawn_flutter` provides the generic service types (`dataSync`,
`shortService`, `specialUse`).

## Multiple clients

`worker.attach()` returns an additional client of the same worker: events
fan out to every client, commands merge in order, `request`s are correlated
per client. This is how a lock-screen media session and your UI drive one
pipeline without knowing about each other.

## Testing a worker

`spawnLocal` runs the handler on the current thread behind a real `Worker`.
There is no parallelism, but every guarantee still holds — request
correlation, event buffering, close semantics, even service grants — so a
handler can be unit tested without a build step or a browser:

```dart
test('answers a probe', () async {
  final worker = await spawnLocal(peaksEntry);
  expect(await worker.request<int>('count'), 0);
  await worker.close();
});
```

## Platform support

| | spawn runs on | payload | `transfer:` |
|---|---|---|---|
| Windows / macOS / Linux / Android / iOS | `Isolate.spawn` | none needed (AOT) | skips the copy for byte payloads |
| Web (all current browsers) | `Worker` | dart2js (`spawn:build`) | real move, source detaches |
| Web, WasmGC payload | `Worker` | dart2wasm | planned; heap-born bytes copy once |

One caveat worth knowing before you rely on `close(force: true)`: on native, a
worker blocked inside a **synchronous native call** cannot be killed.
`Isolate.kill` only takes effect at a message loop boundary, so an isolate
sitting in a blocking FFI call keeps running and `close` returns while it does.
Unblock the resource first — close the pipe, shut down the socket — then close
the worker. `spawn` cannot do it for you, because only your code knows what the
handler is waiting on. A Web Worker's `terminate()` has no such limit.

Debug builds on the web fall back to running an `.inline` worker on the main
thread — with one console warning naming the fix — when its payload will not
load, so the edit-refresh loop never blocks on `spawn:build`. Release builds
throw `SpawnPayloadMissingError` instead, and a `.split` entry always throws,
because its body is not in the main bundle to fall back to.

## Design notes

- API names and semantics follow `dart:isolate` conventions (`spawn`, a
  `Worker` handle like `Isolate`); the package is written to Dart SDK
  internal standards — zero runtime deps, strict analysis, full dartdoc — so
  it can stand as a candidate for lifting into the SDK.
- Every frame has an exact byte encoding: a 12-byte little-endian envelope
  (version, kind, type id, correlation id, payload length) documented in
  `doc/wire_format.md`. Dart-to-Dart channels skip the encoding for portable
  values, but never the semantics — which is what keeps a future native- or
  wasm-hosted worker a drop-in replacement rather than a rewrite.
- Deferred, OS-scheduled jobs (survive the process; WorkManager /
  BGTaskScheduler) are a sibling model with an inverted contract. `JobEntry`
  parses and validates today so worker files need no migration; `Jobs.enqueue`
  throws until it lands.

## License

MIT
