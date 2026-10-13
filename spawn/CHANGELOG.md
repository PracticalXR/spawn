# Changelog

## 0.1.2-WIP

- Nested browser workers inherit the application's asset base at startup, so
  packaged workers do not resolve under another worker's payload directory.
  Rebuild callers and nested worker payloads together to use this correction.
- Web dictionaries preserve prototype-bearing keys and escape opaque-wrapper
  marker collisions. Decoding uses the intrinsic value brand, so an ordinary
  `constructor` entry cannot spoof an array or typed buffer. Rebuild and deploy
  host and worker payloads together; older decoders cannot unwrap exceptional
  marker-bearing dictionaries.
- `SpawnCaps.isolated` distinguishes a real isolate/Web Worker from in-process
  execution, so worker cleanup can respect ownership of global resources.
  Local/debug fallback and older peers conservatively report false.
- `spawn:build --target hybrid` packages a Dart WasmGC worker and a separately
  compiled JavaScript worker behind one entry URL. The bootstrap probes required
  Wasm features and falls back to JS when startup fails, including older iOS
  browsers. Wasm-only and JS-only targets remain available.
- `spawn:build --target wasm` now produces Dart WasmGC Web Workers behind the
  same `.dart.js` asset URL used by existing `SpawnEntry` declarations. The
  bootstrap queues startup messages, falls back when a server omits the Wasm
  MIME type, and workers report `SpawnPayload.wasm` in their capabilities.

## 0.1.1

Three ways a message could go missing, and the response direction learning to
transfer.

- **Native transfer never actually transferred.** The payload matcher compared
  `ByteBuffer`s with `identical`, and on the VM every `.buffer` access on
  internal typed data allocates a fresh wrapper — so `identical(u.buffer,
  u.buffer)` is false and no match ever fired. The designed transfer machinery
  had been dead code since it shipped, silently: the fallback delivers
  identical bytes, so every test asserting content passed. Now compared with
  `==`, which on the VM asks about the backing store's identity — the question
  actually being asked — and on the web degrades to `identical` unchanged.

- **Native now transfers one level into a Map**, which is the shape every
  worker returning bytes actually produces (`{'rgba': bytes, ...}`). The web
  backend had always walked a Map's values; native only matched a whole-payload
  buffer, so the same worker transferred on web and took the plain isolate-send
  path on native, per frame, with nothing to show for it.

- **New `SpawnReply`**: a request handler can now name buffers to move rather
  than clone on the way BACK. The request direction has had `transfer:` from
  the start; the response direction had none, so a worker returning a decoded
  frame paid a full W×H×4 structured clone on the receiving thread — 3.7 MB at
  720p, 29.5 MB at 5K.

- **Web: a message the worker cannot deserialize is no longer lost in
  silence.** The browser fires `messageerror` on the worker's global scope
  instead of `message`, with no data at all, so the request simply never
  arrived — no reply, no error, and the host waited out its timeout. Seen on an
  iPad, where every request carrying a transferred `VideoFrame` vanished this
  way while every other request was answered. The correlation id is inside the
  data the browser could not clone, so the report cannot name the request: every
  request in flight fails with the reason and the worker is KEPT, because the
  worker is fine and the next portable message will be delivered as usual.

- **Web: an error AFTER the worker loaded is no longer dropped.** Only failure
  to START was handled, so an uncaught throw inside a running worker left the
  request it was serving unanswered with no diagnosis anywhere. It is now
  treated like a clone failure — fail what is in flight with the browser's
  message, keep the worker.

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
