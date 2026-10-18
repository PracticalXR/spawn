# Changelog

## 0.1.2

- Web: a worker started from inside another worker now resolves its payload
  against the app's asset base, not the parent worker's directory. Rebuild
  the calling and nested worker payloads together to get the fix.
- Web: map keys are always plain data, including `__proto__` and
  `constructor`, so a key can no longer change how a message decodes (for
  example make a map arrive as an array or typed buffer). Maps whose keys
  collide with spawn's internal markers are escaped. Rebuild and deploy host
  and worker payloads together: an older decoder cannot read an escaped map.
- New `SpawnCaps.isolated`: true when the handler runs in its own isolate or
  Web Worker, false when it runs in process (`spawnLocal`, the web debug
  fallback) or the peer is older. Use it to decide whether a worker's cleanup
  may release process-wide resources.
- `spawn:build --target wasm` builds Dart WasmGC workers, served from the same
  `.dart.js` URL your `SpawnEntry` declarations already use. Messages sent
  during startup are queued, a server that does not send the Wasm MIME type
  still works, and these workers report `SpawnPayload.wasm` in their
  capabilities.
- `spawn:build --target hybrid` ships a WasmGC worker and a JavaScript worker
  behind one URL: the bootstrap checks for the Wasm features it needs and
  falls back to JavaScript if startup fails (for example on older iOS
  browsers). The Wasm-only and JS-only targets remain available.
- New `Worker.termination` reports how a dedicated worker actually ended,
  separately from `done`, which only means the channel closed. On native,
  `WorkerTerminationEvidence.nativeOnExit` means the isolate runs no more
  code; on the web, `browserTerminateRequested` means the browser accepted
  `terminate()`. In-process workers report `notStarted`. Wait for
  `nativeOnExit` before freeing native memory or handles a worker may still
  be using. A custom host transport can report it by implementing
  `WorkerTerminationTransport`.
- A failed start now keeps hold of the worker it began. `spawn` throws a
  `SpawnStartupException` (still a `SpawnException`) or, on the web when the
  payload is missing, a `SpawnPayloadStartupException` (still a
  `SpawnPayloadMissingError`), so existing catches keep matching. Both
  implement the new `SpawnStartupFailure`: `termination`, plus a
  `requestStop()` that is safe to repeat. A startup timeout no longer counts
  as the worker having stopped; one stuck in a native call is still running
  until `termination` says otherwise. Other errors during startup now arrive
  wrapped in a `SpawnStartupException`, with the original as `cause`.
- `SpawnReply` takes optional hooks around sending a reply: `prepare` (may be
  async, runs before encoding), `prepareEncoded` and `beforeSendEncoded`
  (see the exact encoded reply as a `SpawnPreparedReply`), and `beforeSend`
  (synchronous, just before handoff). Throwing from any of them refuses the
  reply, and the requester gets the error instead. `onSettled` runs once the
  reply is sent or refused, to free data the handler owns; an error thrown
  there is fatal to the worker.

## 0.1.1

- **Fix: `transfer:` never transferred on native.** Buffers were matched by
  identity, which never matches on the VM, so payloads were always copied
  (with correct bytes). They are now matched by backing store.
- **Native transfers now look one level into a Map** (such as
  `{'rgba': bytes, ...}`), as the web backend already did.
- **New `SpawnReply`**: a request handler can name buffers to move, rather
  than copy, in its response. Before, a worker returning a decoded frame paid
  a full copy on the receiving thread (3.7 MB at 720p).
- **Web: a message the worker cannot deserialize no longer vanishes.** The
  browser reports it as a `messageerror` without data, so the request went
  unanswered until the host's timeout (seen on iPad with transferred
  `VideoFrame`s). Every request in flight now fails with the reason, and the
  worker keeps running.
- **Web: an error thrown inside a running worker is no longer dropped.** Only
  startup failures were handled. Now the requests in flight fail with the
  browser's message, and the worker keeps running.

## 0.1.0

First release.

- `spawn(entry)` starts a worker on an isolate (native) or a compiled Web
  Worker payload (web) behind one API, and completes once the handler is
  running.
- `Worker` / `WorkerClient`: `post`, `request`, a broadcast `events` stream
  buffered until its first listener, graceful and forced `close`, and
  `attach()` for more clients of one worker.
- `WorkerChannel`: `messages`, `send`, `handleRequests`, `initialMessage`,
  `onClose`.
- One portability contract everywhere (the portable set, or `WireMessage`),
  so a message that works on the VM works in a browser.
- A documented 12-byte wire envelope with a `WireRegistry`, and
  `SpawnEntry.protocol` to register a protocol's decoders on both ends.
- `transfer:` lists: a real move on the web, and a skipped copy on native for
  byte payloads. `SpawnCaps.zeroCopyTransfer` reports which you got.
- `SpawnService` lifetimes with pluggable, reference-counted
  `ServiceProvider`s, and an error at spawn time that names a missing
  registration.
- `spawnLocal` runs a handler in process behind a real `Worker`, for tests and
  as the web debug fallback when a payload has not been built.
- `dart run spawn:build` compiles `lib/workers/*.dart` to web payloads,
  skipping unchanged ones. No code generation and no build_runner. Files
  without a `main` are skipped, so helpers and conditional-import stubs can
  sit next to workers, and the up-to-date check covers path dependencies.
- `JobEntry` parses and validates; `Jobs.enqueue` throws until deferred,
  OS-scheduled work lands.
- `SpawnEntry.native` is reserved for a C- or wasm-hosted worker and throws.
- `PlatformValue` carries an opaque platform object (`VideoFrame`,
  `AudioData`, `ImageBitmap`, `OffscreenCanvas`) through a channel untouched.
  It is always transferred, never cloned, including in a request response,
  since most of these types cannot be cloned; this lets a decode worker hand
  finished frames to the main thread.
