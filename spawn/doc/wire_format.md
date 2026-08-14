# The spawn wire format

Every message `spawn` carries has an exact byte encoding, whether or not the
bytes are actually produced. Dart-to-Dart channels skip the encoding for
portable values — an isolate can copy them faster than we can serialise them —
but they never skip the *semantics*: same kinds, same ordering, same errors.

That is not tidiness for its own sake. It is what makes a worker hosted
somewhere other than Dart — a C event loop, a wasm module — a drop-in
replacement for a Dart one rather than a second protocol to maintain.

## Envelope

Little-endian. A 12-byte header, then `payloadLength` bytes.

| offset | type | field |
|---|---|---|
| 0 | u8 | version — `1` |
| 1 | u8 | kind |
| 2 | u16 | typeId |
| 4 | u32 | correlationId |
| 8 | u32 | payloadLength |
| 12 | bytes | payload |

### Kinds

| code | kind | direction | meaning |
|---|---|---|---|
| 0 | `hello` | worker → host | "I am running", carrying capabilities. Sent once, first. `spawn()` completes on it. |
| 0 | `hello` | host → worker | *web only:* the init frame, carrying the initial message. Not part of the native handshake, which passes it in the isolate's spawn message. |
| 1 | `bye` | both | host → worker: return from your handler. worker → host: I have returned. |
| 2 | `message` | both | one-way. `WorkerClient.post` and `WorkerChannel.send`. |
| 3 | `request` | host → worker | expects a `response` or an `error` with the same `correlationId`. |
| 4 | `response` | worker → host | answers a `request`. |
| 5 | `error` | worker → host | with `correlationId != 0`, fails that one request. With `correlationId == 0`, a fatal handler error: the worker is closing. |

### typeId

`0` for framework frames and for payloads in the portable set. Non-zero
identifies a `WireMessage`, and the payload is exactly what its `encode()`
returned. Valid ids are `1..65535`; both ends must register the same decoders,
which is what `SpawnEntry.protocol` is for.

### correlationId

`0` means "not part of a request". Otherwise unique per worker while the
request is in flight, and routed back to the client that issued it — so
`attach()`ed clients cannot see each other's answers.

## Framework payloads

**`hello`** — UTF-8 JSON:

```json
{"v": 1, "caps": {"hosted": "dart", "payload": "js", "zeroCopyTransfer": true}}
```

Unknown enum values decode to the nearest supported one rather than throwing,
so a newer worker can still talk to an older host.

**`error`** — UTF-8, three newline-separated fields:

```text
StateError
Bad state: the decoder ran out of input
#0      Decoder.read (package:example/decoder.dart:42:5)
...
```

The message has its newlines replaced with spaces, so the split is
unambiguous: everything after the second newline is the stack trace.

**`bye`** — empty.

## Transfers

Transfers never travel *inside* a payload. They are handed to the platform
alongside the frame — a `postMessage` transfer list on the web, a
`TransferableTypedData` on the VM — and the payload refers to the same buffer
by identity. A frame's declared `payloadLength` describes the encoded payload
only.

## Versioning

The header's version byte is checked on every frame; a mismatch is a
`FormatException` naming both versions rather than a misparse. Kinds are
append-only, and an unknown kind is rejected rather than ignored, so a host
one release behind fails loudly instead of silently dropping messages it
cannot act on.

## What is deliberately not here

- **No length-prefixed framing.** Both transports are message-oriented
  already; adding a stream framing layer would only be needed for a socket or
  pipe host, and that host can add it without changing this envelope.
- **No negotiation.** `hello` reports capabilities; it does not bargain over
  them. A host that needs a capability the worker lacks should fail, not
  degrade silently.
- **No compression.** The payloads that are large enough to want it are
  buffers, and buffers should be transferred, not squeezed.
