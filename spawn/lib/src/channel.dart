import 'dart:async';

import 'caps.dart';
import 'entry.dart';
import 'frame.dart';
import 'payload.dart';
import 'transport.dart';
import 'wire.dart';

/// The worker's end of the channel: what a [WorkerHandler] is handed.
///
/// ```dart
/// Future<void> peaksWorker(WorkerChannel channel) async {
///   channel.handleRequests((request) => _describe(request));
///   await for (final message in channel.messages) {
///     final peaks = scan(message! as Uint8List);
///     channel.send(peaks, transfer: [peaks.buffer]);
///   }
/// }
/// ```
///
/// The handler owns the worker's lifetime: when the future it returns
/// completes, the worker shuts down. [messages] closes when the host calls
/// `close`, so an `await for` loop like the one above ends by itself.
abstract interface class WorkerChannel {
  /// Messages posted by the host, in send order per client.
  ///
  /// Single subscription, and buffered until listened to - a handler that does
  /// some setup before its loop does not lose anything.
  Stream<Object?> get messages;

  /// The value passed to `spawn`'s `message` argument, or `null`.
  Object? get initialMessage;

  /// What this worker is running as, as reported to the host.
  SpawnCaps get caps;

  /// Sends an event to every client attached to this worker.
  ///
  /// Fire and forget: there is no acknowledgement and no back pressure.
  /// Entries in [transfer] move instead of being copied where the platform
  /// supports it; see `WorkerClient.post` for exactly where that holds.
  void send(Object? event, {List<Object>? transfer});

  /// Installs the function answering `WorkerClient.request`.
  ///
  /// Requests that arrive before this is called are buffered and delivered in
  /// order once it is. A handler that throws fails that one request on the
  /// host with a `RemoteWorkerError`; the worker keeps running.
  ///
  /// Calling this twice replaces the previous handler.
  void handleRequests(FutureOr<Object?> Function(Object? request) handler);

  /// Completes when the host asks this worker to stop.
  ///
  /// [messages] closes at the same moment. Useful for handlers that are not
  /// shaped as a loop over [messages].
  Future<void> get onClose;
}

/// Runs [handler] against [transport] and reports its outcome.
///
/// Shared by every backend: the isolate bootstrap, the Web Worker entrypoint
/// and the in-process loopback all call this, which is why the three behave
/// the same.
Future<void> runHandlerOn(
  WorkerTransport transport,
  WorkerHandler handler,
  Object? initialMessage,
  SpawnCaps caps,
) async {
  final channel = _WorkerChannel(transport, initialMessage, caps);
  transport.send(
    Frame(WireKind.hello, payload: encodeHelloPayload(caps.toJson())),
  );
  final subscription = transport.incoming.listen(
    channel._onFrame,
    onDone: channel._onTransportDone,
  );
  try {
    await handler(channel);
  } on Object catch (error, stack) {
    channel._sendFatal(error, stack);
  } finally {
    channel._shutdown();
    await subscription.cancel();
    transport.send(const Frame(WireKind.bye));
  }
}

class _WorkerChannel implements WorkerChannel {
  _WorkerChannel(this._transport, this.initialMessage, this.caps);

  final WorkerTransport _transport;
  final _messages = StreamController<Object?>();
  final _closed = Completer<void>();
  final List<Frame> _pendingRequests = <Frame>[];

  FutureOr<Object?> Function(Object? request)? _requestHandler;
  bool _shuttingDown = false;

  @override
  final Object? initialMessage;

  @override
  final SpawnCaps caps;

  @override
  Stream<Object?> get messages => _messages.stream;

  @override
  Future<void> get onClose => _closed.future;

  @override
  void send(Object? event, {List<Object>? transfer}) {
    checkTransfer(transfer);
    final (typeId, payload) = encodeValue(event);
    _transport.send(
      Frame(
        WireKind.message,
        typeId: typeId,
        payload: payload,
        transfers: transfer,
      ),
    );
  }

  @override
  void handleRequests(FutureOr<Object?> Function(Object? request) handler) {
    _requestHandler = handler;
    if (_pendingRequests.isEmpty) return;
    final queued = List<Frame>.of(_pendingRequests);
    _pendingRequests.clear();
    for (final frame in queued) {
      _answer(frame, handler);
    }
  }

  void _onFrame(Frame frame) {
    switch (frame.kind) {
      case WireKind.message:
        if (!_messages.isClosed) {
          _messages.add(decodeValue(frame.typeId, frame.payload));
        }
      case WireKind.request:
        final handler = _requestHandler;
        if (handler == null) {
          _pendingRequests.add(frame);
        } else {
          _answer(frame, handler);
        }
      case WireKind.bye:
        _requestClose();
      case WireKind.hello:
      case WireKind.response:
      case WireKind.error:
        // Host to worker frames of these kinds are not part of the protocol.
        break;
    }
  }

  void _answer(
    Frame frame,
    FutureOr<Object?> Function(Object? request) handler,
  ) {
    Object? request;
    try {
      request = decodeValue(frame.typeId, frame.payload);
    } on Object catch (error, stack) {
      _sendRequestError(frame.correlationId, error, stack);
      return;
    }
    late final Future<Object?> answer;
    try {
      answer = Future<Object?>.sync(() => handler(request));
    } on Object catch (error, stack) {
      _sendRequestError(frame.correlationId, error, stack);
      return;
    }
    answer.then(
      (Object? value) {
        try {
          final (typeId, payload) = encodeValue(value);
          _transport.send(
            Frame(
              WireKind.response,
              typeId: typeId,
              correlationId: frame.correlationId,
              payload: payload,
            ),
          );
        } on Object catch (error, stack) {
          _sendRequestError(frame.correlationId, error, stack);
        }
      },
      onError: (Object error, StackTrace stack) {
        _sendRequestError(frame.correlationId, error, stack);
      },
    );
  }

  void _sendRequestError(int correlationId, Object error, StackTrace stack) {
    _transport.send(
      Frame(
        WireKind.error,
        correlationId: correlationId,
        payload: encodeErrorPayload(
          error.runtimeType.toString(),
          error.toString(),
          stack.toString(),
        ),
      ),
    );
  }

  void _sendFatal(Object error, StackTrace stack) {
    _transport.send(
      Frame(
        WireKind.error,
        payload: encodeErrorPayload(
          error.runtimeType.toString(),
          error.toString(),
          stack.toString(),
        ),
      ),
    );
  }

  void _onTransportDone() => _requestClose();

  void _requestClose() {
    if (_shuttingDown) return;
    _shuttingDown = true;
    if (!_closed.isCompleted) _closed.complete();
    _failPendingRequests();
    if (!_messages.isClosed) unawaited(_messages.close());
  }

  void _shutdown() {
    _requestClose();
  }

  void _failPendingRequests() {
    if (_pendingRequests.isEmpty) return;
    final queued = List<Frame>.of(_pendingRequests);
    _pendingRequests.clear();
    for (final frame in queued) {
      _sendRequestError(
        frame.correlationId,
        StateError(
          'spawn: the worker closed without installing a request handler '
          '(WorkerChannel.handleRequests was never called)',
        ),
        StackTrace.empty,
      );
    }
  }
}
