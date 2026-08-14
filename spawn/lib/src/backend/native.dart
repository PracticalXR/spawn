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
import '../transport.dart';
import '../wire.dart';
import '../worker.dart';

/// What a worker reports on this platform.
const SpawnCaps platformCaps = SpawnCaps(
  hosted: SpawnHost.dart,
  payload: SpawnPayload.aot,
  zeroCopyTransfer: true,
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
  } on Object catch (error) {
    hostPort.close();
    exitPort.close();
    errorPort.close();
    await grant?.release();
    throw SpawnException('could not start isolate for "${entry.asset}"', error);
  }

  final transport = _IsolateHostTransport(
    isolate,
    hostPort,
    exitPort,
    errorPort,
  );
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
    this.transferShape,
  );

  final int kind;
  final int typeId;
  final int correlationId;
  final Object? payload;
  final SendPort? port;
  final TransferableTypedData? transferred;

  /// 0 none, 1 the payload was a `Uint8List`, 2 the payload was a `ByteBuffer`.
  final int transferShape;

  Frame? toFrame() {
    final kindValue = WireKind.fromCode(kind);
    if (kindValue == null) return null;
    Object? value = payload;
    final moved = transferred;
    if (moved != null) {
      final buffer = moved.materialize();
      value = transferShape == 2 ? buffer : buffer.asUint8List();
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

class _IsolateHostTransport implements WorkerTransport {
  _IsolateHostTransport(
    this._isolate,
    this._hostPort,
    this._exitPort,
    this._errorPort,
  ) {
    _hostSubscription = _hostPort.listen(_onMessage);
    _exitSubscription = _exitPort.listen((_) => _onExit());
    _errorSubscription = _errorPort.listen(_onIsolateError);
  }

  final Isolate _isolate;
  final ReceivePort _hostPort;
  final ReceivePort _exitPort;
  final ReceivePort _errorPort;

  late final StreamSubscription<dynamic> _hostSubscription;
  late final StreamSubscription<dynamic> _exitSubscription;
  late final StreamSubscription<dynamic> _errorSubscription;

  final StreamController<Frame> _incoming = StreamController<Frame>();
  final Completer<void> _done = Completer<void>();
  final List<Frame> _queued = <Frame>[];

  SendPort? _workerPort;
  bool _dead = false;

  @override
  Stream<Frame> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

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
  Future<void> kill() async {
    if (_dead) return;
    _dead = true;
    _isolate.kill(priority: Isolate.immediate);
    await _teardown();
  }

  void _onMessage(Object? message) {
    if (message is! _NativeFrame) return;
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
    _dead = true;
    unawaited(_teardown());
  }

  Future<void> _teardown() async {
    await _hostSubscription.cancel();
    await _exitSubscription.cancel();
    await _errorSubscription.cancel();
    _hostPort.close();
    _exitPort.close();
    _errorPort.close();
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
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
