import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../caps.dart';
import '../channel.dart';
import '../entry.dart';
import '../errors.dart';
import '../frame.dart';
import '../payload.dart';
import '../service.dart';
import '../termination.dart';
import '../transport.dart';
import '../wire.dart';
import '../worker.dart';

/// What a worker reports on this platform.
const SpawnCaps platformCaps = SpawnCaps(
  hosted: SpawnHost.dart,
  payload: SpawnPayload.aot,
  zeroCopyTransfer: true,
  isolated: true,
);

/// Starts [entry] in a new isolate and returns a handle on it.
Future<Worker> connect(
  SpawnEntry entry, {
  required Object? message,
  required List<Object>? transfer,
  required Duration timeout,
  ServiceGrant? grant,
}) async {
  final handler = entry.handler;
  if (entry.kind == SpawnEntryKind.native || handler == null) {
    throw UnsupportedError(
      'spawn: SpawnEntry.native is reserved and has no host in this release '
      '(${entry.asset})',
    );
  }
  final (typeId, payload) = encodeValue(message);
  final hostPort = ReceivePort('spawn:${entry.asset}');
  final exitPort = ReceivePort('spawn-exit:${entry.asset}');
  final errorPort = ReceivePort('spawn-error:${entry.asset}');
  // Custody and the onExit listener exist before the isolate can run. Frames
  // are buffered until createWorker subscribes, including an early hello.
  final transport = _IsolateHostTransport(hostPort, exitPort, errorPort);

  final Isolate isolate;
  try {
    isolate = await Isolate.spawn<_Boot>(
      _bootstrap,
      _Boot(hostPort.sendPort, handler, entry.protocol, typeId, payload),
      errorsAreFatal: true,
      onExit: exitPort.sendPort,
      onError: errorPort.sendPort,
      debugName: entry.asset,
    );
  } on Object catch (error, stack) {
    Object? cleanupError;
    try {
      await transport.rejectSpawn();
    } on Object catch (cleanup) {
      cleanupError = cleanup;
    }
    try {
      await grant?.release();
    } on Object catch (cleanup) {
      cleanupError ??= cleanup;
    }
    Error.throwWithStackTrace(
      SpawnStartupException(
        'could not start isolate for "${entry.asset}"',
        cause: error,
        termination: transport.termination,
        requestStop: transport.kill,
        cleanupError: cleanupError,
      ),
      stack,
    );
  }

  transport.bindIsolate(isolate);
  return createWorker(entry, transport, timeout, grant: grant);
}

/// Never returns normally: a worker entrypoint's `main` is not used on native.
Never runWorkerEntrypoint(WorkerHandler handler) {
  throw UnsupportedError(
    'spawn: runWorker() is the entrypoint of a compiled web payload. On '
    'native, spawn() invokes the handler directly and main() is never called.',
  );
}

class _Boot {
  const _Boot(
    this.hostPort,
    this.handler,
    this.protocol,
    this.typeId,
    this.payload,
  );

  final SendPort hostPort;
  final WorkerHandler handler;
  final void Function()? protocol;
  final int typeId;
  final Object? payload;
}

Future<void> _bootstrap(_Boot boot) async {
  // A fresh isolate has a fresh WireRegistry; register before anything can be
  // decoded, including the initial message.
  boot.protocol?.call();
  final transport = _IsolateWorkerTransport(boot.hostPort);
  Object? initialMessage;
  try {
    initialMessage = decodeValue(boot.typeId, boot.payload);
  } on Object {
    initialMessage = null;
  }
  await runHandlerOn(transport, boot.handler, initialMessage, platformCaps);
  await transport.kill();
}

/// The shape a [Frame] takes when it crosses an isolate boundary.
///
/// Isolate messages are deep copied, so the frame travels as a plain object
/// graph. Two things are special: the worker's [SendPort] rides along with its
/// `hello`, and a byte payload the caller asked to transfer is swapped for a
/// [TransferableTypedData] so the VM hands over the memory instead of copying
/// it a second time.
class _NativeFrame {
  const _NativeFrame(
    this.kind,
    this.typeId,
    this.correlationId,
    this.payload,
    this.port,
    this.transferred,
    this.transferShape, [
    this.transferKey,
  ]);

  final int kind;
  final int typeId;
  final int correlationId;
  final Object? payload;
  final SendPort? port;
  final TransferableTypedData? transferred;

  /// 0 none, 1 the payload was a `Uint8List`, 2 the payload was a
  /// `ByteBuffer`, 3/4 the SAME two shapes but for one entry INSIDE a Map
  /// payload (its key rides in [transferKey]; the rest of the map travels by
  /// copy). 3/4 exist because the WEB backend has always transferred buffers
  /// nested one level down (`_transferList` walks the values) while this one
  /// only matched the whole payload — so a worker returning
  /// `{'rgba': bytes, ...}` transferred on web and took the plain
  /// isolate-send path on native, silently, per frame.
  final int transferShape;

  /// The Map key whose value was extracted into [transferred] (shapes 3/4).
  final Object? transferKey;

  Frame? toFrame() {
    final kindValue = WireKind.fromCode(kind);
    if (kindValue == null) return null;
    Object? value = payload;
    final moved = transferred;
    if (moved != null) {
      final buffer = moved.materialize();
      if (transferShape == 3 || transferShape == 4) {
        // Shapes 3/4: reassemble the Map around the moved buffer.
        final map = Map<Object?, Object?>.of(payload! as Map);
        map[transferKey] = transferShape == 4 ? buffer : buffer.asUint8List();
        value = map;
      } else {
        value = transferShape == 2 ? buffer : buffer.asUint8List();
      }
    }
    return Frame(
      kindValue,
      typeId: typeId,
      correlationId: correlationId,
      payload: value,
    );
  }

  static _NativeFrame from(Frame frame, {SendPort? port}) {
    final payload = frame.payload;
    final transfers = frame.transfers;
    if (transfers != null && transfers.isNotEmpty && payload != null) {
      for (final candidate in transfers) {
        if (!bufferMatches(payload, candidate)) continue;
        if (payload is Uint8List) {
          return _NativeFrame(
            frame.kind.code,
            frame.typeId,
            frame.correlationId,
            null,
            port,
            TransferableTypedData.fromList(<Uint8List>[payload]),
            1,
          );
        }
        if (payload is ByteBuffer) {
          return _NativeFrame(
            frame.kind.code,
            frame.typeId,
            frame.correlationId,
            null,
            port,
            TransferableTypedData.fromList(<Uint8List>[payload.asUint8List()]),
            2,
          );
        }
      }
      // One level into a Map — the shape every worker that returns bytes
      // PLUS metadata uses (`{'rgba': bytes, 'needsKeyframe': flag}`), and
      // the shape the web backend has always transferred. First matching
      // entry wins; the remainder of the map is small metadata that copies.
      if (payload is Map) {
        for (final entry in payload.entries) {
          final Object? v = entry.value;
          if (v is! Uint8List && v is! ByteBuffer) continue;
          for (final candidate in transfers) {
            // `v!`: the is!-checks above exclude null, but a two-type union
            // is beyond flow promotion.
            if (!bufferMatches(v!, candidate)) continue;
            final rest = Map<Object?, Object?>.of(payload)..remove(entry.key);
            return _NativeFrame(
              frame.kind.code,
              frame.typeId,
              frame.correlationId,
              rest,
              port,
              TransferableTypedData.fromList(<Uint8List>[
                v is Uint8List ? v : (v as ByteBuffer).asUint8List(),
              ]),
              v is Uint8List ? 3 : 4,
              entry.key,
            );
          }
        }
      }
    }
    return _NativeFrame(
      frame.kind.code,
      frame.typeId,
      frame.correlationId,
      payload,
      port,
      null,
      0,
    );
  }
}

class _IsolateHostTransport
    implements WorkerTransport, WorkerTerminationTransport {
  _IsolateHostTransport(this._hostPort, this._exitPort, this._errorPort) {
    _hostSubscription = _hostPort.listen(_onMessage);
    _exitSubscription = _exitPort.listen((_) => _onExit());
    _errorSubscription = _errorPort.listen(_onIsolateError);
  }

  Isolate? _isolate;
  final ReceivePort _hostPort;
  final ReceivePort _exitPort;
  final ReceivePort _errorPort;

  late final StreamSubscription<dynamic> _hostSubscription;
  late final StreamSubscription<dynamic> _exitSubscription;
  late final StreamSubscription<dynamic> _errorSubscription;

  final StreamController<Frame> _incoming = StreamController<Frame>();
  final Completer<void> _done = Completer<void>();
  final Completer<WorkerTerminationEvidence> _termination =
      Completer<WorkerTerminationEvidence>();
  final List<Frame> _queued = <Frame>[];

  SendPort? _workerPort;
  bool _dead = false;
  bool _killAccepted = false;
  Future<void>? _killFuture;
  Future<void>? _teardownFuture;
  Future<void>? _exitCleanupFuture;

  void bindIsolate(Isolate isolate) {
    _isolate = isolate;
  }

  /// A VM spawn rejection has no dedicated actor whose exit must be awaited.
  Future<void> rejectSpawn() async {
    _closeRoute();
    if (!_termination.isCompleted) {
      _termination.complete(WorkerTerminationEvidence.notStarted);
    }
    try {
      await _retireExitObserver();
    } finally {
      await _teardown();
    }
  }

  @override
  Stream<Frame> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<WorkerTerminationEvidence> get termination => _termination.future;

  @override
  void send(Frame frame) {
    if (_dead) return;
    final port = _workerPort;
    if (port == null) {
      _queued.add(frame);
      return;
    }
    port.send(_NativeFrame.from(frame));
  }

  @override
  Future<void> kill() {
    final existing = _killFuture;
    if (existing != null) return existing;
    final completer = Completer<void>();
    final future = _killFuture = completer.future;
    _closeRoute();
    unawaited(
      _requestStopAndTeardown().then<void>(
        (_) => completer.complete(),
        onError: (Object error, StackTrace stack) {
          // A failed request leaves its handle and receipt available to retry.
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
      final isolate = _isolate;
      if (!_termination.isCompleted && !_killAccepted && isolate != null) {
        isolate.kill(priority: Isolate.immediate);
        _killAccepted = true;
      }
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

  void _closeRoute() {
    _dead = true;
    _queued.clear();
    _workerPort = null;
  }

  void _onMessage(Object? message) {
    if (_dead || message is! _NativeFrame) return;
    final port = message.port;
    if (port != null && _workerPort == null) {
      _workerPort = port;
      final queued = List<Frame>.of(_queued);
      _queued.clear();
      for (final frame in queued) {
        port.send(_NativeFrame.from(frame));
      }
    }
    final frame = message.toFrame();
    if (frame != null && !_incoming.isClosed) _incoming.add(frame);
  }

  void _onIsolateError(Object? message) {
    if (_dead) return;
    // `onError` delivers [error, stackTrace] as strings.
    var text = 'isolate error';
    var stack = '';
    if (message is List && message.isNotEmpty) {
      text = '${message[0]}';
      if (message.length > 1) stack = '${message[1]}';
    }
    if (!_incoming.isClosed) {
      _incoming.add(
        Frame(
          WireKind.error,
          payload: encodeErrorPayload('IsolateError', text, stack),
        ),
      );
    }
  }

  void _onExit() {
    // Route teardown must never suppress this late, independent receipt.
    if (!_termination.isCompleted) {
      _termination.complete(WorkerTerminationEvidence.nativeOnExit);
    }
    _closeRoute();
    unawaited(_finishExit());
  }

  Future<void> _finishExit() async {
    try {
      await _retireExitObserver();
    } finally {
      await _teardown();
    }
  }

  Future<void> _teardown() {
    final existing = _teardownFuture;
    if (existing != null) return existing;
    final completer = Completer<void>();
    final future = _teardownFuture = completer.future;
    unawaited(
      _teardownRoute().then<void>(
        (_) => completer.complete(),
        onError: (Object error, StackTrace stack) {
          if (identical(_teardownFuture, future)) _teardownFuture = null;
          completer.completeError(error, stack);
        },
      ),
    );
    return future;
  }

  Future<void> _teardownRoute() async {
    try {
      await _hostSubscription.cancel();
      await _errorSubscription.cancel();
    } finally {
      _hostPort.close();
      _errorPort.close();
      if (!_incoming.isClosed) unawaited(_incoming.close());
      if (!_done.isCompleted) _done.complete();
    }
    // The exit port/subscription remain alive until onExit (or notStarted).
  }

  Future<void> _retireExitObserver() {
    final existing = _exitCleanupFuture;
    if (existing != null) return existing;
    final completer = Completer<void>();
    final future = _exitCleanupFuture = completer.future;
    _exitPort.close();
    unawaited(
      _exitSubscription.cancel().then<void>(
        (_) => completer.complete(),
        onError: (Object error, StackTrace stack) {
          completer.completeError(error, stack);
        },
      ),
    );
    return future;
  }
}

class _IsolateWorkerTransport implements WorkerTransport {
  _IsolateWorkerTransport(this._hostPort) {
    _subscription = _selfPort.listen(_onMessage);
  }

  final SendPort _hostPort;
  final ReceivePort _selfPort = ReceivePort('spawn:worker');
  final StreamController<Frame> _incoming = StreamController<Frame>();
  final Completer<void> _done = Completer<void>();

  late final StreamSubscription<dynamic> _subscription;
  bool _dead = false;
  bool _sentPort = false;

  @override
  Stream<Frame> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(Frame frame) {
    if (_dead) return;
    if (!_sentPort && frame.kind == WireKind.hello) {
      _sentPort = true;
      _hostPort.send(_NativeFrame.from(frame, port: _selfPort.sendPort));
      return;
    }
    _hostPort.send(_NativeFrame.from(frame));
  }

  @override
  Future<void> kill() async {
    if (_dead) return;
    _dead = true;
    await _subscription.cancel();
    _selfPort.close();
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }

  void _onMessage(Object? message) {
    if (message is! _NativeFrame) return;
    final frame = message.toFrame();
    if (frame != null && !_incoming.isClosed) _incoming.add(frame);
  }
}
