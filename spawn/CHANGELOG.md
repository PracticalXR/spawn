# Changelog

## 0.1.0

First release.

- `spawn(entry)` starts a worker on an isolate (native) or a compiled Web
  Worker payload (web) behind one API, and completes only once the handler is
  running.
- `Worker` / `WorkerClient`: `post`, `request`, a broadcast `events` stream
  buffered until its first listener, graceful and forced `close`, and
  `attach()` for additional clients of one worker.
- `WorkerChannel`: `messages`, `send`, `handleRequests`, `initialMessage`,
  `onClose`.
- One portability contract on every platform — the portable set, or
  `WireMessage` — so a message that works on the VM works in a browser.
- A documented 12-byte wire envelope with a `WireRegistry`, and
  `SpawnEntry.protocol` to register a protocol's decoders on both ends.
- `transfer:` lists: a real move on the web, and a skipped copy on native for
  byte payloads. `SpawnCaps.zeroCopyTransfer` reports which you got.
- `SpawnService` lifetimes with pluggable, reference-counted `ServiceProvider`s
  and an error at spawn time that names the missing registration.
- `spawnLocal` runs a handler in process behind a real `Worker`, for tests and
  as the web debug fallback when a payload has not been built.
- `dart run spawn:build` compiles `lib/workers/*.dart` to web payloads, with
  content-hash skipping. No code generation and no build_runner.
- `JobEntry` parses and validates; `Jobs.enqueue` throws until deferred,
  OS-scheduled work lands.
- `SpawnEntry.native` is reserved for a C- or wasm-hosted worker and throws.
- `PlatformValue` carries an opaque platform object - a `VideoFrame`,
  `AudioData`, `ImageBitmap`, `OffscreenCanvas` - through a channel untouched.
  It always transfers rather than clones, including from a request response,
  because most of those types cannot be cloned at all. This is what lets a
  decode worker hand finished frames to the main thread.
- `spawn:build` skips files in the worker directory that declare no `main`,
  so a worker can sit next to its conditional-import stubs and helpers, and
  its up-to-date check now covers path dependencies. A payload that ignored
  changes to a sibling package under active development is worse than no
  caching at all: the tests pass against code that is no longer there.
