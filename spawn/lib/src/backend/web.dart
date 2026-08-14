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
import '../transport.dart';
import '../wire.dart';
import '../worker.dart';
import 'local.dart';

/// What a worker reports on this platform.
const SpawnCaps platformCaps = SpawnCaps(
  hosted: SpawnHost.dart,
  payload: SpawnPayload.js,
  zeroCopyTransfer: true,
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
  final initFrame = Frame(
    WireKind.hello,
    typeId: typeId,
    payload: payload,
    transfers: transfer,
  );

  _JsWorker jsWorker;
  try {
    jsWorker = _JsWorker(url);
  } on Object catch (error) {
    return _cannotStart(
      entry,
      message,
      timeout,
      grant,
      SpawnPayloadMissingError(entry.asset, url, error),
    );
  }

  final transport = _WebHostTransport(jsWorker);
  transport.send(initFrame);

  final pending = createWorker(entry, transport, timeout, grant: grant);
  final race = Completer<Worker>();
  unawaited(
    pending.then(
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
    transport.loadFailure.then((reason) {
      if (!race.isCompleted) {
        race.completeError(
          SpawnPayloadMissingError(entry.asset, url, reason),
          StackTrace.current,
        );
      }
    }),
  );

  try {
    return await race.future;
  } on SpawnPayloadMissingError catch (failure) {
    await transport.kill();
    return _cannotStart(entry, message, timeout, grant, failure);
  }
}

/// Handles a worker that will not start: fall back in debug, or report it.
Future<Worker> _cannotStart(
  SpawnEntry entry,
  Object? message,
  Duration timeout,
  ServiceGrant? grant,
  SpawnPayloadMissingError failure,
) {
  // Only an inline entry can fall back: a split entry's body is not in the
  // main bundle, so there is nothing here to run.
  if (_assertionsEnabled && entry.kind == SpawnEntryKind.inline) {
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
    await grant?.release();
    throw failure;
  });
}

/// The entrypoint of a compiled worker payload; see `runWorker`.
void runWorkerEntrypoint(WorkerHandler handler) {
  _WebWorkerTransport? transport;
  _self.onmessage = ((_MessageEvent event) {
    final frame = _decodeFrame(event.data);
    if (frame == null) return;
    final existing = transport;
    if (existing != null) {
      existing.deliver(frame);
      return;
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
/// against the document's base URL. An asset that already looks like a URL is
/// used as given, which is how tests and non-Flutter web apps point at a
/// payload directly.
String resolveAssetUrl(String asset) {
  final base = Uri.parse(_baseUrl());
  if (asset.startsWith('http://') ||
      asset.startsWith('https://') ||
      asset.startsWith('/') ||
      asset.startsWith('./') ||
      asset.startsWith('../') ||
      asset.endsWith('.js')) {
    return base.resolve(asset).toString();
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

class _WebHostTransport implements WorkerTransport {
  _WebHostTransport(this._worker) {
    _worker.onmessage = ((_MessageEvent event) {
      final frame = _decodeFrame(event.data);
      if (frame == null) return;
      if (frame.kind == WireKind.hello && !_loaded.isCompleted) {
        _loaded.complete();
      }
      if (!_incoming.isClosed) _incoming.add(frame);
      if (frame.kind == WireKind.bye) unawaited(kill());
    }).toJS;
    _worker.onerror = ((JSAny? event) {
      if (_loaded.isCompleted || _loadFailure.isCompleted) return;
      _loadFailure.complete(_describeErrorEvent(event));
    }).toJS;
    _worker.onmessageerror = ((JSAny? _) {
      if (_incoming.isClosed) return;
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
  final StreamController<Frame> _incoming = StreamController<Frame>();
  final Completer<void> _done = Completer<void>();
  final Completer<void> _loaded = Completer<void>();
  final Completer<String> _loadFailure = Completer<String>();

  bool _dead = false;

  /// Completes if the worker script fails to load, or throws on startup,
  /// before it says hello. The value describes what the browser reported.
  Future<String> get loadFailure => _loadFailure.future;

  @override
  Stream<Frame> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(Frame frame) {
    if (_dead) return;
    final (message, transfers) = _encodeFrame(frame);
    _worker.postMessage(message, transfers);
  }

  @override
  Future<void> kill() async {
    if (_dead) return;
    _dead = true;
    _worker.onmessage = null;
    _worker.onerror = null;
    _worker.onmessageerror = null;
    _worker.terminate();
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
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
    final (message, transfers) = _encodeFrame(frame);
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

(JSObject, JSArray<JSAny?>) _encodeFrame(Frame frame) {
  final message = JSObject();
  message.setProperty('h'.toJS, WireEnvelope.encodeHeader(frame.header).toJS);
  // Opaque values are collected as the payload is converted, so they cost no
  // extra traversal - and so a response can move one even though a response
  // has no transfer list of its own.
  final opaque = <JSAny>[];
  final payload = frame.payload;
  if (payload != null) {
    message.setProperty(
      'p'.toJS,
      frame.isEncoded ? frame.bytes.toJS : _toJs(payload, opaque),
    );
  }
  return (message, _transferList(frame.transfers, opaque));
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

JSArray<JSAny?> _transferList(List<Object>? transfer, List<JSAny> opaque) {
  final array = JSArray<JSAny?>();
  final moved = <JSAny>[];
  // A duplicate entry in a transfer list is a DataCloneError, and a caller
  // that both nests a PlatformValue and lists it is doing the obvious thing.
  void add(JSAny value) {
    for (final existing in moved) {
      if (identical(existing, value)) return;
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
      buffer = item.toJS;
    } else if (item is TypedData) {
      buffer = item.buffer.toJS;
    } else if (item is PlatformValue) {
      // Already a JS object; the platform moves it as itself.
      buffer = item.value as JSAny?;
    } else {
      continue;
    }
    if (buffer == null) continue;
    add(buffer);
  }
  return array;
}

/// Property name marking an opaque platform value inside a cloned message.
///
/// Structured clone gives back a plain object, so without a marker a
/// `PlatformValue` would be indistinguishable from a `Map` on arrival - and a
/// `VideoFrame` would decode into an empty map rather than a frame.
const String _platformMarker = r'$spawn$platform';

JSAny? _toJs(Object? value, List<JSAny> opaque) {
  if (value == null) return null;
  if (value is PlatformValue) {
    final holder = JSObject();
    final inner = value.value as JSAny?;
    holder.setProperty(_platformMarker.toJS, inner);
    if (inner != null) opaque.add(inner);
    return holder;
  }
  if (value is bool) return value.toJS;
  if (value is int) return value.toJS;
  if (value is double) return value.toJS;
  if (value is String) return value.toJS;
  if (value is ByteBuffer) return value.toJS;
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
      array.setProperty(i.toJS, _toJs(value[i], opaque));
    }
    return array;
  }
  if (value is Map<Object?, Object?>) {
    final object = JSObject();
    value.forEach((key, element) {
      object.setProperty('$key'.toJS, _toJs(element, opaque));
    });
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

  // Dispatch on the constructor name rather than `instanceof`: a value that
  // arrived through structured clone can come from another realm, where
  // `instanceof` is false for the very types we are trying to recognise.
  switch (_constructorName(value)) {
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
      if (object.hasProperty(_platformMarker.toJS).toDart) {
        // Opaque on the way in, opaque on the way out: hand back exactly what
        // the platform delivered, unconverted.
        return PlatformValue(object.getProperty<JSAny?>(_platformMarker.toJS));
      }
      final keys = _objectKeys(object);
      final length = keys.getProperty<JSNumber>('length'.toJS).toDartInt;
      return <String, Object?>{
        for (var i = 0; i < length; i++)
          keys.getProperty<JSString>(i.toJS).toDart: _fromJs(
            object.getProperty<JSAny?>(keys.getProperty<JSString>(i.toJS)),
          ),
      };
  }
}

String? _constructorName(JSAny value) {
  final constructor = (value as JSObject).getProperty<JSObject?>(
    'constructor'.toJS,
  );
  return constructor?.getProperty<JSString?>('name'.toJS)?.toDart;
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

String _baseUrl() {
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
