import 'dart:async';

import 'caps.dart';
import 'entry.dart';
import 'errors.dart';
import 'frame.dart';
import 'payload.dart';
import 'service.dart';
import 'transport.dart';
import 'wire.dart';

/// How long `close()` waits for a worker to finish before killing it.
const Duration _gracePeriod = Duration(seconds: 5);

/// A handle on a running worker.
///
/// [Worker] is the owning handle returned by `spawn`; [Worker.attach] hands out
/// additional clients of the same worker, which implement this same interface.
/// Every client sees every event and shares one command stream, so a lock
/// screen and a UI can drive one pipeline without knowing about each other.
abstract interface class WorkerClient {
  /// Events the worker sent, in the order it sent them.
  ///
  /// A broadcast stream. Events are buffered from the moment the worker starts
  /// until the first listener subscribes, then delivered live - so nothing is
  /// lost while an app wires up its UI, and nothing is replayed to a second
  /// listener afterwards.
  ///
  /// A fatal error inside the worker's handler arrives here as a
  /// [RemoteWorkerError], immediately before the worker closes.
  Stream<Object?> get events;

  /// Sends [message] to the worker without waiting for anything.
  ///
  /// Messages from one client arrive in send order. There is no ordering
  /// guarantee between clients, and no back pressure: `post` never blocks.
  ///
  /// [message] must be portable - `null`, `bool`, `int`, `double`, `String`,
  /// typed data, or a [List]/[String]-keyed [Map] of those - or implement
  /// [WireMessage]. Anything else throws [ArgumentError], on every platform,
  /// so a message that works on the VM works in a browser.
  ///
  /// Entries in [transfer] must be typed data or byte buffers. On the web they
  /// move: the source buffer is detached and reading it afterwards throws. On
  /// native the isolate message copy already gives the worker an independent
  /// buffer; a transfer entry that *is* the message, or the encoded bytes of a
  /// [WireMessage], additionally skips that copy. Either way, treat a
  /// transferred buffer as gone.
  ///
  /// Throws [StateError] if the worker has closed.
  void post(Object? message, {List<Object>? transfer});

  /// Sends [message] and completes with the worker's answer.
  ///
  /// The worker answers with the function it passed to
  /// `WorkerChannel.handleRequests`. If that function throws, this future
  /// completes with a [RemoteWorkerError] carrying the original type name,
  /// message and stack trace.
  ///
  /// With a [timeout], the future fails with [TimeoutException] and the reply
  /// is discarded if it arrives later. Without one it waits as long as the
  /// worker lives; if the worker closes first it fails with [StateError].
  ///
  /// ```dart
  /// final duration = await worker.request<Duration>(const ProbeCmd());
  /// ```
  Future<R> request<R>(
    Object? message, {
    List<Object>? transfer,
    Duration? timeout,
  });

  /// Whether this client can still be used.
  bool get isClosed;

  /// Releases this client.
  ///
  /// On an attached client this detaches it: its [events] stream closes and
  /// its in-flight requests fail, but the worker keeps running for the other
  /// clients. On the owning [Worker] it shuts the worker down. Idempotent.
  Future<void> close();
}

/// The owning handle on a running worker.
///
/// ```dart
/// final worker = await spawn(peaksEntry);
/// worker.post(bytes, transfer: [bytes.buffer]);
/// await for (final event in worker.events) { ... }
/// await worker.close();
/// ```
class Worker implements WorkerClient {
  Worker._(this._core);

  final _WorkerCore _core;

  /// The entry this worker was spawned from.
  SpawnEntry get entry => _core.entry;

  /// What the worker reported it can do, from its `hello` frame.
  SpawnCaps get caps => _core.caps;

  /// The fatal error that ended the worker, or `null`.
  ///
  /// Set just before [events] closes when a handler throws. A worker that
  /// returned normally, or was closed by the host, leaves this `null`.
  Object? get error => _core.fatalError;

  /// Completes when the worker has stopped, however it stopped.
  ///
  /// Never completes with an error; see [error] and [events].
  Future<void> get done => _core.done;

  /// Creates another client of this same worker.
  ///
  /// The new client has its own [events] stream - buffered until its own first
  /// listener, exactly like the owner's - and its own request correlation.
  /// Closing it detaches it; closing the [Worker] closes it too.
  ///
  /// Throws [StateError] if the worker has already closed.
  WorkerClient attach() => _core.attach();

  @override
  Stream<Object?> get events => _core.ownerClient.events;

  @override
  bool get isClosed => _core.isClosed;

  @override
  void post(Object? message, {List<Object>? transfer}) =>
      _core.ownerClient.post(message, transfer: transfer);

  @override
  Future<R> request<R>(
    Object? message, {
    List<Object>? transfer,
    Duration? timeout,
  }) => _core.ownerClient.request<R>(
    message,
    transfer: transfer,
    timeout: timeout,
  );

  /// Shuts the worker down.
  ///
  /// By default this is graceful: the worker is asked to stop, its
  /// `WorkerChannel.messages` stream closes so a loop over it ends, and the
  /// handler gets [grace] - five seconds by default - to return before the
  /// worker is killed. With `force: true` it is killed immediately and [grace]
  /// is ignored.
  ///
  /// Idempotent, and safe to call from any client. Any [SpawnService] this
  /// worker held is released once shutdown completes.
  ///
  /// **A worker blocked in a synchronous native call cannot be killed.**
  /// `Isolate.kill` only takes effect at a message loop boundary, so an
  /// isolate sitting inside a blocking FFI call - `av_read_frame` on a live
  /// stream, a socket read, a mutex wait - keeps running, and `close` returns
  /// while it does. The remedy is always the same and always belongs to the
  /// code that owns the resource: unblock it first (close the pipe, shut down
  /// the socket) so the native call returns, and *then* close the worker.
  /// A `Worker` cannot do that for you, because only the caller knows what the
  /// handler is blocked on. Web Workers have no such caveat: `terminate()`
  /// really does stop one.
  @override
  Future<void> close({bool force = false, Duration grace = _gracePeriod}) =>
      _core.shutdown(force: force, grace: grace);

  @override
  String toString() => 'Worker(${_core.entry.asset})';
}

/// Builds a [Worker] over [transport]. Used by the backends and by `spawnLocal`.
Future<Worker> createWorker(
  SpawnEntry entry,
  WorkerTransport transport,
  Duration timeout, {
  ServiceGrant? grant,
}) async {
  final core = _WorkerCore(entry, transport, grant);
  final worker = Worker._(core);
  try {
    await core.awaitHello(timeout);
  } on Object {
    await core.shutdown(force: true);
    rethrow;
  }
  return worker;
}

class _WorkerCore {
  _WorkerCore(this.entry, this._transport, this._grant) {
    _subscription = _transport.incoming.listen(
      _onFrame,
      onDone: _onTransportDone,
      onError: _onTransportError,
    );
    ownerClient = _Client(this);
    _clients.add(ownerClient);
    unawaited(_transport.done.then((_) => _onTransportDone()));
  }

  final SpawnEntry entry;
  final WorkerTransport _transport;
  final ServiceGrant? _grant;

  late final StreamSubscription<Frame> _subscription;
  late final _Client ownerClient;

  final List<_Client> _clients = <_Client>[];
  final Map<int, _Pending> _pending = <int, _Pending>{};
  final Completer<void> _hello = Completer<void>();
  final Completer<void> _done = Completer<void>();

  SpawnCaps _caps = const SpawnCaps(
    hosted: SpawnHost.dart,
    payload: SpawnPayload.aot,
    zeroCopyTransfer: false,
  );
  Object? fatalError;
  int _nextCorrelation = 1;
  Future<void>? _shutdownFuture;
  bool _closed = false;

  SpawnCaps get caps => _caps;

  bool get isClosed => _closed;

  Future<void> get done => _done.future;

  Future<void> awaitHello(Duration timeout) {
    if (_hello.isCompleted) return _hello.future;
    return _hello.future.timeout(
      timeout,
      onTimeout: () => throw SpawnException(
        'worker "${entry.asset}" did not start within '
        '${timeout.inMilliseconds}ms',
      ),
    );
  }

  WorkerClient attach() {
    if (_closed) {
      throw StateError(
        'spawn: cannot attach to a closed worker (${entry.asset})',
      );
    }
    final client = _Client(this);
    _clients.add(client);
    return client;
  }

  void send(Frame frame) => _transport.send(frame);

  int allocateCorrelation(_Pending pending) {
    var id = _nextCorrelation;
    while (id == 0 || _pending.containsKey(id)) {
      id = id == 0xFFFFFFFF ? 1 : id + 1;
    }
    _nextCorrelation = id == 0xFFFFFFFF ? 1 : id + 1;
    _pending[id] = pending;
    return id;
  }

  void dropCorrelation(int id) => _pending.remove(id);

  void _onFrame(Frame frame) {
    switch (frame.kind) {
      case WireKind.hello:
        if (frame.isEncoded) {
          try {
            _caps = SpawnCaps.fromJson(decodeHelloPayload(frame.bytes));
          } on FormatException {
            // A hello we cannot parse still means the worker is alive; keep
            // the conservative defaults rather than failing the spawn.
          }
        }
        if (!_hello.isCompleted) _hello.complete();
      case WireKind.message:
        Object? value;
        try {
          value = decodeValue(frame.typeId, frame.payload);
        } on Object catch (error, stack) {
          _emitToAll(_Event.error(error, stack));
          return;
        }
        _emitToAll(_Event.value(value));
      case WireKind.response:
        final pending = _pending.remove(frame.correlationId);
        if (pending == null) return;
        try {
          pending.complete(decodeValue(frame.typeId, frame.payload));
        } on Object catch (error, stack) {
          pending.completeError(error, stack);
        }
      case WireKind.error:
        final (type, message, stack) = frame.isEncoded
            ? decodeErrorPayload(frame.bytes)
            : ('StateError', 'malformed error frame', '');
        final error = RemoteWorkerError(type, message, stack);
        if (frame.correlationId != 0) {
          _pending
              .remove(frame.correlationId)
              ?.completeError(error, StackTrace.current);
          return;
        }
        fatalError = error;
        _emitToAll(_Event.error(error, StackTrace.current));
        unawaited(shutdown(force: true));
      case WireKind.bye:
        unawaited(shutdown(force: true));
      case WireKind.request:
        // Worker to host requests are not part of this release's protocol.
        break;
    }
  }

  void _onTransportError(Object error, StackTrace stack) {
    fatalError ??= error;
    _emitToAll(_Event.error(error, stack));
    unawaited(shutdown(force: true));
  }

  void _onTransportDone() {
    if (_closed) return;
    unawaited(shutdown(force: true));
  }

  void _emitToAll(_Event event) {
    for (final client in List<_Client>.of(_clients)) {
      client._emit(event);
    }
  }

  Future<void> shutdown({required bool force, Duration grace = _gracePeriod}) {
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    return _shutdownFuture = _shutdown(force: force, grace: grace);
  }

  Future<void> _shutdown({required bool force, required Duration grace}) async {
    if (!force) {
      _transport.send(const Frame(WireKind.bye));
      await _transport.done.timeout(grace, onTimeout: () {});
    }
    _closed = true;
    await _transport.kill();
    await _subscription.cancel();

    if (!_hello.isCompleted) {
      _hello.completeError(
        SpawnException('worker "${entry.asset}" closed before it started'),
        StackTrace.current,
      );
    }
    final orphans = List<_Pending>.of(_pending.values);
    _pending.clear();
    for (final pending in orphans) {
      pending.completeError(
        StateError(
          'spawn: worker "${entry.asset}" closed with a request in flight',
        ),
        StackTrace.current,
      );
    }
    for (final client in List<_Client>.of(_clients)) {
      client._finish();
    }
    _clients.clear();
    await _grant?.release();
    if (!_done.isCompleted) _done.complete();
  }

  void detach(_Client client) {
    if (identical(client, ownerClient)) {
      unawaited(shutdown(force: false));
      return;
    }
    _clients.remove(client);
    final orphans = <int>[];
    _pending.forEach((id, pending) {
      if (identical(pending.client, client)) orphans.add(id);
    });
    for (final id in orphans) {
      _pending
          .remove(id)
          ?.completeError(
            StateError('spawn: client detached with a request in flight'),
            StackTrace.current,
          );
    }
    client._finish();
  }
}

class _Client implements WorkerClient {
  _Client(this._core) {
    _controller = StreamController<Object?>.broadcast(
      onListen: () {
        _live = true;
        if (_buffer.isNotEmpty) _scheduleDrain();
      },
    );
  }

  final _WorkerCore _core;
  late final StreamController<Object?> _controller;
  final List<_Event> _buffer = <_Event>[];

  bool _live = false;
  bool _draining = false;
  bool _detached = false;
  bool _finished = false;

  @override
  Stream<Object?> get events => _controller.stream;

  @override
  bool get isClosed => _detached || _core.isClosed;

  @override
  void post(Object? message, {List<Object>? transfer}) {
    _checkOpen();
    checkTransfer(transfer);
    final (typeId, payload) = encodeValue(message);
    _core.send(
      Frame(
        WireKind.message,
        typeId: typeId,
        payload: payload,
        transfers: transfer,
      ),
    );
  }

  @override
  Future<R> request<R>(
    Object? message, {
    List<Object>? transfer,
    Duration? timeout,
  }) {
    // A method that returns a Future must not throw synchronously: a caller
    // that has not awaited yet would get an exception where it expected a
    // failed future.
    try {
      return _request<R>(message, transfer, timeout);
    } on Object catch (error, stack) {
      return Future<R>.error(error, stack);
    }
  }

  Future<R> _request<R>(
    Object? message,
    List<Object>? transfer,
    Duration? timeout,
  ) {
    _checkOpen();
    checkTransfer(transfer);
    final (typeId, payload) = encodeValue(message);
    final pending = _Pending(this);
    final correlationId = _core.allocateCorrelation(pending);
    _core.send(
      Frame(
        WireKind.request,
        typeId: typeId,
        correlationId: correlationId,
        payload: payload,
        transfers: transfer,
      ),
    );
    final future = pending.future.then((Object? value) => value as R);
    if (timeout == null) return future;
    return future.timeout(
      timeout,
      onTimeout: () {
        _core.dropCorrelation(correlationId);
        throw TimeoutException(
          'spawn: request to "${_core.entry.asset}" timed out',
          timeout,
        );
      },
    );
  }

  @override
  Future<void> close() async {
    if (_detached || _finished) return;
    _detached = true;
    _core.detach(this);
  }

  void _checkOpen() {
    if (_detached) {
      throw StateError('spawn: this client has been detached');
    }
    if (_core.isClosed) {
      throw StateError('spawn: worker "${_core.entry.asset}" is closed');
    }
  }

  void _emit(_Event event) {
    if (_finished) return;
    if (_live && _buffer.isEmpty) {
      event.addTo(_controller);
      return;
    }
    _buffer.add(event);
    if (_live) _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_draining) return;
    _draining = true;
    scheduleMicrotask(() {
      _draining = false;
      while (_buffer.isNotEmpty) {
        _buffer.removeAt(0).addTo(_controller);
      }
      if (_finished && !_controller.isClosed) unawaited(_controller.close());
    });
  }

  /// Called when the worker - or this client - is gone for good.
  ///
  /// The event stream only closes once anything buffered has been observed, so
  /// a fatal error is still delivered to a listener that arrives late.
  void _finish() {
    if (_finished) return;
    _finished = true;
    _detached = true;
    if (_buffer.isNotEmpty) {
      if (_live) _scheduleDrain();
      return;
    }
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}

class _Pending {
  _Pending(this.client);

  final _Client client;
  final Completer<Object?> _completer = Completer<Object?>();

  Future<Object?> get future => _completer.future;

  void complete(Object? value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }

  void completeError(Object error, StackTrace stack) {
    if (!_completer.isCompleted) _completer.completeError(error, stack);
  }
}

class _Event {
  _Event.value(this.value) : error = null, stack = null;
  _Event.error(Object this.error, StackTrace this.stack) : value = null;

  final Object? value;
  final Object? error;
  final StackTrace? stack;

  void addTo(StreamController<Object?> controller) {
    if (controller.isClosed) return;
    final failure = error;
    if (failure != null) {
      controller.addError(failure, stack);
    } else {
      controller.add(value);
    }
  }
}
