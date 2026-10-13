import 'dart:async';
import 'dart:js_interop';
// Property access on plain JS objects. An SDK library, so the package still
// has zero dependencies; `package:web` would add one for bindings this file
// declares in twenty lines.
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../caps.dart';
import '../channel.dart';
import '../entry.dart';
import '../errors.dart';
import '../frame.dart';
import '../payload.dart';
import '../platform_value.dart';
import '../service.dart';
import '../termination.dart';
import '../transport.dart';
import '../wire.dart';
import '../worker.dart';
import 'local.dart';

const bool _isWasmPayload =
    String.fromEnvironment('spawn.worker.payload') == 'wasm';

/// What a worker reports on this platform.
const SpawnCaps platformCaps = SpawnCaps(
  hosted: SpawnHost.dart,
  payload: _isWasmPayload ? SpawnPayload.wasm : SpawnPayload.js,
  zeroCopyTransfer: true,
  isolated: true,
);

/// Starts [entry] in a Web Worker and returns a handle on it.
Future<Worker> connect(
  SpawnEntry entry, {
  required Object? message,
  required List<Object>? transfer,
  required Duration timeout,
  ServiceGrant? grant,
}) async {
  if (entry.kind == SpawnEntryKind.native) {
    throw UnsupportedError(
      'spawn: SpawnEntry.native is reserved and has no host in this release '
      '(${entry.asset})',
    );
  }
  final url = resolveAssetUrl(entry.asset);
  final (typeId, payload) = encodeValue(message);
  // A plain message, NOT a hello. A `hello` payload is caps JSON by
  // definition, so decoding one always reads bytes - and an init carrying a
  // portable value (a map of config, say) would be reinterpreted as a byte
  // array. The worker treats whatever arrives first as its init, so the kind
  // carries no extra meaning here and the honest one is `message`.
  final initFrame = Frame(
    WireKind.message,
    typeId: typeId,
    payload: payload,
    transfers: transfer,
  );

  _JsWorker jsWorker;
  try {
    jsWorker = _JsWorker(url);
  } on Object catch (error, stack) {
    return _cannotStart(
      entry,
      message,
      timeout,
      grant,
      SpawnPayloadMissingError(entry.asset, url, error),
      stack,
    );
  }

  // Own the raw Worker before installing handlers or sending anything. A
  // partially installed transport must not hide a live Worker from cleanup.
  final custody = _WebWorkerCustody(jsWorker);
  _WebHostTransport? transport;
  try {
    final created = _WebHostTransport(custody);
    transport = created;
    created.installHandlers();
    created.send(initFrame);

    final pending = createWorker(entry, created, timeout, grant: grant);
    final race = Completer<Worker>();
    unawaited(
      pending.then<void>(
        (worker) {
          if (race.isCompleted) {
            unawaited(worker.close(force: true));
          } else {
            race.complete(worker);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!race.isCompleted) race.completeError(error, stack);
        },
      ),
    );
    unawaited(
      created.loadFailure.then<void>((reason) {
        if (!race.isCompleted) {
          race.completeError(
            SpawnPayloadMissingError(entry.asset, url, reason),
            StackTrace.current,
          );
        }
      }),
    );
    return await race.future;
  } on Object catch (error, stack) {
    final requestStop = transport?.kill ?? custody.requestStop;
    Object? cleanupError;
    try {
      await requestStop();
    } on Object catch (cleanup) {
      cleanupError = cleanup;
    }
    if (error is SpawnPayloadMissingError) {
      final failure = SpawnPayloadStartupException(
        error.asset,
        error.url,
        cause: error.cause,
        termination: custody.termination,
        requestStop: requestStop,
        cleanupError: cleanupError,
      );
      return _cannotStart(
        entry,
        message,
        timeout,
        grant,
        failure,
        stack,
        allowFallback: custody.terminateAccepted,
      );
    }
    if (error is SpawnStartupException && cleanupError == null) {
      Error.throwWithStackTrace(error, stack);
    }
    Error.throwWithStackTrace(
      SpawnStartupException(
        error is SpawnException
            ? error.message
            : 'could not start worker "${entry.asset}"',
        cause: error is SpawnException ? error.cause : error,
        termination: custody.termination,
        requestStop: requestStop,
        cleanupError: error is SpawnStartupException
            ? error.cleanupError ?? cleanupError
            : cleanupError,
      ),
      stack,
    );
  }
}

/// Handles a worker that will not start: fall back in debug, or report it.
Future<Worker> _cannotStart(
  SpawnEntry entry,
  Object? message,
  Duration timeout,
  ServiceGrant? grant,
  SpawnPayloadMissingError failure,
  StackTrace stack, {
  bool allowFallback = true,
}) {
  // Only an inline entry can fall back: a split entry's body is not in the
  // main bundle, so there is nothing here to run.
  if (allowFallback &&
      _assertionsEnabled &&
      entry.kind == SpawnEntryKind.inline) {
    if (!_warnedAboutFallback) {
      _warnedAboutFallback = true;
      _consoleWarn(
        'spawn: could not start a worker for "${entry.asset}" '
                '(${failure.url}): ${failure.cause}. Running the handler on '
                'the main thread for this debug session - there is no '
                'parallelism. Run `dart run spawn:build` to fix a missing '
                'payload. Release builds throw instead.'
            .toJS,
      );
    }
    return connectLocal(
      entry,
      message: message,
      timeout: timeout,
      caps: const SpawnCaps(
        hosted: SpawnHost.dart,
        payload: SpawnPayload.js,
        zeroCopyTransfer: false,
      ),
      grant: grant,
    );
  }
  return Future<Worker>.sync(() async {
    try {
      await grant?.release();
    } on Object catch (cleanup) {
      if (failure is SpawnPayloadStartupException) {
        Error.throwWithStackTrace(
          SpawnPayloadStartupException(
            failure.asset,
            failure.url,
            cause: failure.cause,
            termination: failure.termination,
            requestStop: failure.requestStop,
            cleanupError: failure.cleanupError ?? cleanup,
          ),
          stack,
        );
      }
      Error.throwWithStackTrace(failure, stack);
    }
    Error.throwWithStackTrace(failure, stack);
  });
}

/// The entrypoint of a compiled worker payload; see `runWorker`.
void runWorkerEntrypoint(WorkerHandler handler) {
  _WebWorkerTransport? transport;
  // 🔴 A MESSAGE THE WORKER CANNOT DESERIALIZE IS NEVER DELIVERED. The
  // browser fires `messageerror` on the worker's global scope instead of
  // `message`, with no data at all — so without this handler the request
  // simply never arrives: no reply, no error, and the host waits for its
  // timeout (an iPad, 2026-09-01: every request carrying a transferred
  // VideoFrame vanished this way while every other request was answered).
  // The correlation id is inside the data the browser could not clone, so
  // the report cannot name the request; the host fails every request in
  // flight with it and KEEPS the worker — the worker is fine, the message
  // was not.
  _self.onmessageerror = ((JSAny? _) {
    final t = transport ?? _WebWorkerTransport();
    t.send(
      Frame(
        WireKind.error,
        payload: encodeErrorPayload(
          'DataCloneError',
          'a message from the host could not be deserialized by the worker '
              '(messageerror) — a platform object in it (a VideoFrame, an '
              'ImageBitmap, …) cannot cross into a worker on this browser; '
              'the request it carried will never be answered',
          '',
        ),
      ),
    );
  }).toJS;
  _self.onmessage = ((_MessageEvent event) {
    final frame = _decodeFrame(event.data);
    if (frame == null) return;
    final existing = transport;
    if (existing != null) {
      existing.deliver(frame);
      return;
    }
    // A worker's own location is its payload URL, not the application's asset
    // base. Inherit the parent's base once, outside the user payload, so nested
    // workers resolve the same packaged assets at every level.
    final raw = event.data;
    if (raw != null && raw.isA<JSObject>()) {
      final base = (raw as JSObject).getProperty<JSAny?>('spawnAssetBase'.toJS);
      if (base != null && base.isA<JSString>()) {
        final text = (base as JSString).toDart;
        final uri = text.length <= 8192 ? Uri.tryParse(text) : null;
        if (uri != null &&
            uri.hasAuthority &&
            (uri.scheme == 'http' || uri.scheme == 'https')) {
          _inheritedAssetBase = text;
        }
      }
    }
    Object? initialMessage;
    try {
      initialMessage = decodeValue(frame.typeId, frame.payload);
    } on Object {
      initialMessage = null;
    }
    final created = _WebWorkerTransport();
    transport = created;
    unawaited(
      runHandlerOn(created, handler, initialMessage, platformCaps).then((_) {
        _self.close();
      }),
    );
  }).toJS;
}

/// Turns an entry's asset id into the URL its payload is served from.
///
/// `packages/my_package/workers/peaks_worker` becomes
/// `assets/packages/my_package/workers/build/peaks_worker.dart.js`, resolved
/// against the application's base URL, including in nested workers. Explicit
/// relative script URLs keep their caller-local meaning; tests and non-Flutter
/// web apps can still point at a payload directly.
String resolveAssetUrl(String asset) {
  final base = Uri.parse(_baseUrl());
  if (asset.startsWith('http://') ||
      asset.startsWith('https://') ||
      asset.startsWith('/') ||
      asset.startsWith('./') ||
      asset.startsWith('../') ||
      asset.endsWith('.js')) {
    return Uri.parse(_localBaseUrl()).resolve(asset).toString();
  }
  final slash = asset.lastIndexOf('/');
  final path = slash < 0
      ? 'build/$asset.dart.js'
      : '${asset.substring(0, slash)}/build/${asset.substring(slash + 1)}.dart.js';
  return base.resolve('assets/$path').toString();
}

// --------------------------------------------------------------------------
// Transports
// --------------------------------------------------------------------------

/// Custody exists independently of whether a transport was fully installed.
class _WebWorkerCustody {
  _WebWorkerCustody(this.worker);

  final _JsWorker worker;
  final Completer<WorkerTerminationEvidence> _termination =
      Completer<WorkerTerminationEvidence>();
  Future<void>? _stopFuture;
  bool terminateAccepted = false;

  Future<WorkerTerminationEvidence> get termination => _termination.future;

  Future<void> requestStop() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    final completer = Completer<void>();
    final future = _stopFuture = completer.future;
    try {
      // Publish the request before invoking JS, including reentrant JS hooks.
      worker.terminate();
      terminateAccepted = true;
      if (!_termination.isCompleted) {
        _termination.complete(
          WorkerTerminationEvidence.browserTerminateRequested,
        );
      }
      completer.complete();
    } on Object catch (error, stack) {
      if (identical(_stopFuture, future)) _stopFuture = null;
      completer.completeError(error, stack);
    }
    return future;
  }
}

class _WebHostTransport implements WorkerTransport, WorkerTerminationTransport {
  _WebHostTransport(this._custody) : _worker = _custody.worker;

  void installHandlers() {
    _worker.onmessage = ((_MessageEvent event) {
      if (_dead) return;
      final frame = _decodeFrame(event.data);
      if (frame == null) return;
      if (frame.kind == WireKind.hello && !_loaded.isCompleted) {
        _loaded.complete();
      }
      if (!_incoming.isClosed) _incoming.add(frame);
      if (frame.kind == WireKind.bye) unawaited(kill());
    }).toJS;
    _worker.onerror = ((JSAny? event) {
      if (_dead) return;
      if (!_loaded.isCompleted && !_loadFailure.isCompleted) {
        _loadFailure.complete(_describeErrorEvent(event));
        return;
      }
      // 🔴 AN ERROR AFTER LOAD WAS DROPPED ON THE FLOOR, AND THAT COST A DAY.
      // Everything above only handled the worker failing to START. Once the
      // hello had arrived, an UNCAUGHT error inside the worker — a throw from
      // a callback the browser invoked, so no request's `catch` can see it —
      // was ignored here: the request in flight was simply never answered and
      // the host learned nothing until its own timeout. On 2026-09-01 that
      // timeout ("did not answer within 6s") was then read by the caller as a
      // hung GPU import and it walked a whole fallback ladder for a worker
      // that had died on its first `print`.
      //
      // So it is REPORTED, as the worker's own errors are: a correlation-less
      // error frame carrying the browser's message. The worker is not
      // terminated here — an `ErrorEvent` is a fact about one callback and
      // the worker's event loop is still running — but the host's protocol
      // treats an unattributable error as fatal and tears the route down,
      // which is the honest answer for a worker whose state is now unknown.
      if (_incoming.isClosed) return;
      _incoming.add(
        Frame(
          WireKind.error,
          payload: encodeErrorPayload(
            'WorkerError',
            'the worker threw an uncaught error: '
                '${_describeErrorEvent(event)}',
            '',
          ),
        ),
      );
    }).toJS;
    _worker.onmessageerror = ((JSAny? _) {
      if (_dead || _incoming.isClosed) return;
      _incoming.add(
        Frame(
          WireKind.error,
          payload: encodeErrorPayload(
            'DataCloneError',
            'a message could not be deserialized by the worker; payloads must '
                'be portable values or WireMessage bytes',
            '',
          ),
        ),
      );
    }).toJS;
  }

  final _JsWorker _worker;
  final _WebWorkerCustody _custody;
  final StreamController<Frame> _incoming = StreamController<Frame>();
  final Completer<void> _done = Completer<void>();
  final Completer<void> _loaded = Completer<void>();
  final Completer<String> _loadFailure = Completer<String>();

  bool _dead = false;
  bool _sentInitial = false;
  Future<void>? _killFuture;
  Future<void>? _teardownFuture;

  /// Completes if the worker script fails to load, or throws on startup,
  /// before it says hello. The value describes what the browser reported.
  Future<String> get loadFailure => _loadFailure.future;

  @override
  Stream<Frame> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<WorkerTerminationEvidence> get termination => _custody.termination;

  @override
  void send(Frame frame) {
    if (_dead) return;
    final (message, transfers) = encodeWebFrame(frame);
    if (!_sentInitial) {
      message.setProperty('spawnAssetBase'.toJS, _baseUrl().toJS);
      _sentInitial = true;
    }
    _worker.postMessage(message, transfers);
  }

  @override
  Future<void> kill() {
    final existing = _killFuture;
    if (existing != null) return existing;
    final completer = Completer<void>();
    final future = _killFuture = completer.future;
    _dead = true;
    unawaited(
      _requestStopAndTeardown().then<void>(
        (_) => completer.complete(),
        onError: (Object error, StackTrace stack) {
          // Logical death must not prevent retrying a failed terminate call.
          if (identical(_killFuture, future)) _killFuture = null;
          completer.completeError(error, stack);
        },
      ),
    );
    return future;
  }

  Future<void> _requestStopAndTeardown() async {
    Object? failure;
    StackTrace? failureStack;
    try {
      await _custody.requestStop();
    } on Object catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
    try {
      await _teardown();
    } on Object catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  Future<void> _teardown() {
    final existing = _teardownFuture;
    if (existing != null) return existing;
    final completer = Completer<void>();
    final future = _teardownFuture = completer.future;
    Object? failure;
    StackTrace? failureStack;
    void detach(void Function() clearHandler) {
      try {
        clearHandler();
      } on Object catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }

    detach(() => _worker.onmessage = null);
    detach(() => _worker.onerror = null);
    detach(() => _worker.onmessageerror = null);
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
    if (failure == null) {
      completer.complete();
    } else {
      if (identical(_teardownFuture, future)) _teardownFuture = null;
      completer.completeError(failure!, failureStack!);
    }
    return future;
  }
}

class _WebWorkerTransport implements WorkerTransport {
  final StreamController<Frame> _incoming = StreamController<Frame>();
  final Completer<void> _done = Completer<void>();
  bool _dead = false;

  @override
  Stream<Frame> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(Frame frame) {
    if (_dead) return;
    final (message, transfers) = encodeWebFrame(frame);
    _self.postMessage(message, transfers);
  }

  @override
  Future<void> kill() async {
    if (_dead) return;
    _dead = true;
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }

  void deliver(Frame frame) {
    if (_dead || _incoming.isClosed) return;
    _incoming.add(frame);
  }
}

// --------------------------------------------------------------------------
// Frame <-> structured clone
// --------------------------------------------------------------------------

/// The web transport's encoded message and its exact transferable objects.
/// Kept at this internal seam so MessageChannel tests exercise the same
/// conversion used by both host requests and worker replies.
(JSObject, JSArray<JSAny?>) encodeWebFrame(Frame frame) {
  final message = JSObject();
  message.setProperty('h'.toJS, WireEnvelope.encodeHeader(frame.header).toJS);
  // Opaque values are collected as the payload is converted, so they cost no
  // extra traversal - and so a response can move one even though a response
  // has no transfer list of its own.
  final opaque = <JSAny>[];
  final conversion = _TransferredBuffers(frame.transfers);
  final payload = frame.payload;
  if (payload != null) {
    message.setProperty('p'.toJS, _toJs(payload, opaque, conversion));
  }
  return (message, _transferList(frame.transfers, opaque, conversion));
}

Frame? _decodeFrame(JSAny? data) {
  if (data == null || !data.isA<JSObject>()) return null;
  final object = data as JSObject;
  final rawHeader = object.getProperty<JSUint8Array?>('h'.toJS);
  if (rawHeader == null) return null;
  final WireHeader header;
  try {
    header = WireEnvelope.decodeHeader(rawHeader.toDart);
  } on FormatException {
    return null;
  }
  final rawPayload = object.getProperty<JSAny?>('p'.toJS);
  final Object? payload;
  if (rawPayload == null) {
    payload = null;
  } else if (header.typeId != 0 ||
      header.kind == WireKind.hello ||
      header.kind == WireKind.bye ||
      header.kind == WireKind.error) {
    payload = (rawPayload as JSUint8Array).toDart;
  } else {
    payload = _fromJs(rawPayload);
  }
  return Frame(
    header.kind,
    typeId: header.typeId,
    correlationId: header.correlationId,
    payload: payload,
  );
}

class _TransferredBuffer {
  _TransferredBuffer(this.source);
  final ByteBuffer source;
  JSArrayBuffer? converted;
}

/// Convert an explicitly transferred backing once, then use that SAME JS
/// buffer in payload views and postMessage's transfer list. Dart-owned
/// buffers clone on every toJS under Wasm; independent conversions move an
/// unused clone while the real payload still pays a structured-clone copy.
/// Unlisted views keep their normal view-only conversion, so a small slice
/// of a large scratch buffer does not suddenly copy the entire allocation.
class _TransferredBuffers {
  _TransferredBuffers(List<Object>? transfer) {
    if (transfer == null) return;
    for (final item in transfer) {
      final buffer = item is ByteBuffer
          ? item
          : item is TypedData
          ? item.buffer
          : null;
      if (buffer != null && !_buffers.any((b) => b.source == buffer)) {
        _buffers.add(_TransferredBuffer(buffer));
      }
    }
  }

  // ByteBuffer getters may return fresh wrappers. Equality compares their
  // backing, whereas identical would miss aliased views on Dart/Wasm.
  final _buffers = <_TransferredBuffer>[];
  Map<TypedData, JSObject>? _views;

  JSArrayBuffer? forBuffer(ByteBuffer source) {
    for (final entry in _buffers) {
      if (entry.source == source) {
        return entry.converted ??= entry.source.toJS;
      }
    }
    return null;
  }

  JSObject view(TypedData source, JSArrayBuffer buffer) {
    final views = _views ??= Map<TypedData, JSObject>.identity();
    return views.putIfAbsent(source, () {
      final offset = source.offsetInBytes;
      if (source is Uint8List)
        return JSUint8Array(buffer, offset, source.length);
      if (source is Int8List) return JSInt8Array(buffer, offset, source.length);
      if (source is Uint8ClampedList) {
        return JSUint8ClampedArray(buffer, offset, source.length);
      }
      if (source is Int16List)
        return JSInt16Array(buffer, offset, source.length);
      if (source is Uint16List)
        return JSUint16Array(buffer, offset, source.length);
      if (source is Int32List)
        return JSInt32Array(buffer, offset, source.length);
      if (source is Uint32List)
        return JSUint32Array(buffer, offset, source.length);
      if (source is Float32List)
        return JSFloat32Array(buffer, offset, source.length);
      if (source is Float64List)
        return JSFloat64Array(buffer, offset, source.length);
      if (source is ByteData)
        return JSDataView(buffer, offset, source.lengthInBytes);
      throw ArgumentError.value(
        source,
        'message',
        'spawn cannot carry this value',
      );
    });
  }
}

JSArray<JSAny?> _transferList(
  List<Object>? transfer,
  List<JSAny> opaque,
  _TransferredBuffers conversion,
) {
  final array = JSArray<JSAny?>();
  final moved = <JSAny>[];
  // A duplicate entry in a transfer list is a DataCloneError, and a caller
  // that both nests a PlatformValue and lists it is doing the obvious thing.
  void add(JSAny value) {
    for (final existing in moved) {
      // Wasm can wrap one JS object more than once. Dart wrapper identity
      // would leave duplicate ArrayBuffers in postMessage's transfer list.
      if (_sameJsObject(existing, value)) return;
    }
    moved.add(value);
    array.setProperty((moved.length - 1).toJS, value);
  }

  for (final value in opaque) {
    add(value);
  }
  if (transfer == null) return array;
  for (var i = 0; i < transfer.length; i++) {
    final item = transfer[i];
    final JSAny? buffer;
    if (item is ByteBuffer) {
      buffer = conversion.forBuffer(item);
    } else if (item is TypedData) {
      buffer = conversion.forBuffer(item.buffer);
    } else if (item is PlatformValue) {
      // Already a JS object; the platform moves it as itself - unless it is
      // shared memory, which is cloned by sharing and cannot be moved at all.
      final inner = item.value as JSAny?;
      buffer = (inner != null && _isSharedMemory(inner)) ? null : inner;
    } else {
      continue;
    }
    if (buffer == null) continue;
    add(buffer);
  }
  return array;
}

@JS('Object.is')
external bool _sameJsObject(JSAny left, JSAny right);

/// Property name marking an opaque platform value inside a cloned message.
///
/// Structured clone gives back a plain object, so without a marker a
/// `PlatformValue` would be indistinguishable from a `Map` on arrival - and a
/// `VideoFrame` would decode into an empty map rather than a frame.
const String _platformMarker = r'$spawn$platform';
const String _mapMarker = r'$spawn$map';

/// Whether [value] is shared memory, which must be CLONED rather than moved.
///
/// A `SharedArrayBuffer` is the one platform object whose whole purpose is to
/// exist on both sides at once. Structured clone shares it - both threads end
/// up addressing the same memory - and listing one for transfer is a
/// `DataCloneError`, so the two things a `PlatformValue` normally does are
/// exactly inverted here. There is nothing for the caller to opt into: moving
/// shared memory is never what anyone means.
bool _isSharedMemory(JSAny value) =>
    _valueBrand(value) == 'SharedArrayBuffer';

JSAny? _toJs(
  Object? value,
  List<JSAny> opaque,
  _TransferredBuffers conversion,
) {
  if (value == null) return null;
  if (value is PlatformValue) {
    final holder = JSObject();
    final inner = value.value as JSAny?;
    holder.setProperty(_platformMarker.toJS, inner);
    if (inner != null && !_isSharedMemory(inner)) opaque.add(inner);
    return holder;
  }
  if (value is bool) return value.toJS;
  if (value is int) return value.toJS;
  if (value is double) return value.toJS;
  if (value is String) return value.toJS;
  if (value is ByteBuffer) return conversion.forBuffer(value) ?? value.toJS;
  if (value is TypedData) {
    final buffer = conversion.forBuffer(value.buffer);
    if (buffer != null) return conversion.view(value, buffer);
  }
  if (value is Uint8List) return value.toJS;
  if (value is Int8List) return value.toJS;
  if (value is Uint8ClampedList) return value.toJS;
  if (value is Int16List) return value.toJS;
  if (value is Uint16List) return value.toJS;
  if (value is Int32List) return value.toJS;
  if (value is Uint32List) return value.toJS;
  if (value is Float32List) return value.toJS;
  if (value is Float64List) return value.toJS;
  if (value is ByteData) return value.toJS;
  if (value is List<Object?>) {
    final array = JSArray<JSAny?>();
    for (var i = 0; i < value.length; i++) {
      array.setProperty(i.toJS, _toJs(value[i], opaque, conversion));
    }
    return array;
  }
  if (value is Map<Object?, Object?>) {
    // A portable key is data, including __proto__. Never invoke inherited
    // setters or let an own constructor key dictate the decoded value type.
    final object = _objectCreate(null);
    value.forEach((key, element) {
      object.setProperty('$key'.toJS, _toJs(element, opaque, conversion));
    });
    if (value.containsKey(_platformMarker) || value.containsKey(_mapMarker)) {
      // Escape dictionary keys that otherwise look like our opaque wrapper.
      // The decoder unwraps this dictionary without interpreting its own keys.
      final holder = _objectCreate(null);
      holder.setProperty(_mapMarker.toJS, object);
      return holder;
    }
    return object;
  }
  // checkPortable already rejected everything else before we got here.
  throw ArgumentError.value(value, 'message', 'spawn cannot carry this value');
}

Object? _fromJs(JSAny? value) {
  if (value == null) return null;
  if (value.typeofEquals('boolean')) return (value as JSBoolean).toDart;
  if (value.typeofEquals('string')) return (value as JSString).toDart;
  if (value.typeofEquals('number')) {
    final number = (value as JSNumber).toDartDouble;
    if (number.isFinite && number == number.truncateToDouble()) {
      return number.toInt();
    }
    return number;
  }
  if (!value.typeofEquals('object')) return null;

  // Dispatch on the intrinsic brand rather than `instanceof`: a value that
  // arrived through structured clone can come from another realm, where
  // `instanceof` is false for the very types we are trying to recognise.
  switch (_valueBrand(value)) {
    case 'ArrayBuffer':
      return (value as JSArrayBuffer).toDart;
    case 'Uint8Array':
      return (value as JSUint8Array).toDart;
    case 'Int8Array':
      return (value as JSInt8Array).toDart;
    case 'Uint8ClampedArray':
      return (value as JSUint8ClampedArray).toDart;
    case 'Int16Array':
      return (value as JSInt16Array).toDart;
    case 'Uint16Array':
      return (value as JSUint16Array).toDart;
    case 'Int32Array':
      return (value as JSInt32Array).toDart;
    case 'Uint32Array':
      return (value as JSUint32Array).toDart;
    case 'Float32Array':
      return (value as JSFloat32Array).toDart;
    case 'Float64Array':
      return (value as JSFloat64Array).toDart;
    case 'DataView':
      return (value as JSDataView).toDart;
    case 'Array':
      final array = value as JSArray<JSAny?>;
      final length = array.getProperty<JSNumber>('length'.toJS).toDartInt;
      return <Object?>[
        for (var i = 0; i < length; i++)
          _fromJs(array.getProperty<JSAny?>(i.toJS)),
      ];
    default:
      final object = value as JSObject;
      if (object.hasProperty(_mapMarker.toJS).toDart) {
        return _fromJsMap(object.getProperty<JSObject>(_mapMarker.toJS));
      }
      if (object.hasProperty(_platformMarker.toJS).toDart) {
        // Opaque on the way in, opaque on the way out: hand back exactly what
        // the platform delivered, unconverted.
        return PlatformValue(object.getProperty<JSAny?>(_platformMarker.toJS));
      }
      return _fromJsMap(object);
  }
}

Map<String, Object?> _fromJsMap(JSObject object) {
  final keys = _objectKeys(object);
  final length = keys.getProperty<JSNumber>('length'.toJS).toDartInt;
  return <String, Object?>{
    for (var i = 0; i < length; i++)
      keys.getProperty<JSString>(i.toJS).toDart: _fromJs(
        object.getProperty<JSAny?>(keys.getProperty<JSString>(i.toJS)),
      ),
  };
}

String _valueBrand(JSAny value) {
  final tag = _objectTag(value).toDart;
  return tag.substring(8, tag.length - 1); // [object Array], etc.
}

// --------------------------------------------------------------------------
// Minimal hand-rolled bindings (package:web is deliberately not a dependency)
// --------------------------------------------------------------------------

@JS('Worker')
extension type _JsWorker._(JSObject _) implements JSObject {
  external factory _JsWorker(String scriptUrl);

  external void postMessage(JSAny? message, JSArray<JSAny?> transfer);
  external void terminate();
  external set onmessage(JSFunction? value);
  external set onerror(JSFunction? value);
  external set onmessageerror(JSFunction? value);
}

extension type _MessageEvent._(JSObject _) implements JSObject {
  external JSAny? get data;
}

extension type _WorkerGlobalScope._(JSObject _) implements JSObject {
  external set onmessage(JSFunction? value);
  external set onmessageerror(JSFunction? value);
  external void postMessage(JSAny? message, JSArray<JSAny?> transfer);
  external void close();
}

@JS('self')
external _WorkerGlobalScope get _self;

@JS('globalThis')
external JSObject get _globalThis;

@JS('console.warn')
external void _consoleWarn(JSAny? message);

@JS('Object.keys')
external JSArray<JSString> _objectKeys(JSObject object);

@JS('Object.create')
external JSObject _objectCreate(JSObject? prototype);

@JS('Object.prototype.toString.call')
external JSString _objectTag(JSAny value);

/// Turns an `ErrorEvent` into something a developer can act on.
String _describeErrorEvent(JSAny? event) {
  if (event == null || !event.isA<JSObject>()) {
    return 'the worker failed to start';
  }
  final object = event as JSObject;
  final message = object.getProperty<JSAny?>('message'.toJS);
  final text = message == null ? '' : message.toString();
  if (text.isEmpty) {
    return 'the worker script did not load (network error, wrong URL, or a '
        'MIME type the browser refused)';
  }
  final line = object.getProperty<JSAny?>('lineno'.toJS);
  return line == null ? text : '$text (line $line)';
}

String? _inheritedAssetBase;

String _baseUrl() {
  if (_inheritedAssetBase != null) return _inheritedAssetBase!;
  return _localBaseUrl();
}

String _localBaseUrl() {
  final document = _globalThis.getProperty<JSObject?>('document'.toJS);
  if (document != null) {
    final base = document.getProperty<JSString?>('baseURI'.toJS);
    if (base != null) return base.toDart;
  }
  return Uri.base.toString();
}

bool _warnedAboutFallback = false;

bool get _assertionsEnabled {
  var enabled = false;
  assert(() {
    enabled = true;
    return true;
  }());
  return enabled;
}
