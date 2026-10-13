import 'dart:async';
import 'dart:typed_data';

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

/// A request-handler return value that names buffers to MOVE, not clone.
///
/// The request direction has had a `transfer` list from the start; the
/// RESPONSE direction had none, so every reply was structured-cloned. For a
/// worker returning a decoded video frame that was a full W×H×4 copy per
/// frame — 3.7 MB at 720p, 29.5 MB at 5K — on the receiving thread. Wrap
/// the reply instead:
///
/// ```dart
/// channel.handleRequests((req) {
///   final rgba = decode(req);
///   return SpawnReply({'rgba': rgba}, transfer: [rgba.buffer]);
/// });
/// ```
///
/// Additive: handlers returning a plain value behave exactly as before. The
/// [transfer] entries obey `send`'s rules ([checkTransfer]), and the buffers
/// named must be the SAME ones referenced by [value] — a transferred buffer
/// is detached on the sending side, so the worker must not touch it again.
class SpawnReply {
  /// Wraps [value] with an optional [transfer] list.
  const SpawnReply(
    this.value, {
    this.transfer,
    this.prepare,
    this.prepareEncoded,
    this.beforeSend,
    this.beforeSendEncoded,
    this.onSettled,
  });

  /// The actual reply, delivered to the requester exactly as if the
  /// handler had returned it bare.
  final Object? value;

  /// Buffers to MOVE with the reply. Same rules as `send`'s `transfer`.
  final List<Object>? transfer;

  /// Optional installed preparation after the handler finishes, before encoding.
  /// An exception refuses the reply. It does not cancel an admitted operation.
  final FutureOr<void> Function()? prepare;

  /// Preparation of the exact encoded reply retained for transport handoff.
  /// This also sees the independent payload used by a settled loopback reply.
  /// A final [beforeSendEncoded] check can refuse data changed during the await.
  final FutureOr<void> Function(SpawnPreparedReply reply)? prepareEncoded;

  /// Synchronous fence after encoding, immediately before transport handoff.
  /// A remote check in [prepare] is not atomic with a remote policy change.
  final void Function()? beforeSend;

  /// Synchronous final check of the same encoded reply, immediately before send.
  /// This callback must not mutate its payload or the transfer list.
  final void Function(SpawnPreparedReply reply)? beforeSendEncoded;

  /// Disposes owned temporary data after refusal or synchronous handoff. Never
  /// mutate transferred buffers or opaque platform values here; their ownership
  /// and lifetime follow their separate backend contracts.
  final void Function()? onSettled;
}

/// The original sender's finalized reply representation. Constructed only by
/// the channel; its fields are the ones handed to the transport without another
/// encode. The payload may contain mutable owned buffers: authorization hooks
/// must compare their commitment again immediately before sending.
final class SpawnPreparedReply {
  const SpawnPreparedReply._(this.typeId, this.correlationId, this.payload);

  /// Registered wire type, or zero for a portable untyped value.
  final int typeId;

  /// Original request correlation carried by the response frame.
  final int correlationId;

  /// Encoded portable value or wire-message bytes retained for actual handoff.
  final Object? payload;
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
      (Object? value) async {
        final wrapped = value is SpawnReply ? value : null;
        try {
          List<Object>? transfer;
          if (wrapped != null) {
            if (wrapped.prepare != null) await wrapped.prepare!();
            transfer = wrapped.transfer;
            checkTransfer(transfer);
            value = wrapped.value;
          }
          final (typeId, encoded) = encodeValue(value);
          // Loopback queues references rather than synchronously cloning like
          // native/web transports. Retain its own portable payload before the
          // sender disposes temporary buffers. Ordinary replies are unchanged.
          final payload = wrapped?.onSettled != null && !caps.isolated
              ? _settledPayload(encoded)
              : encoded;
          final prepared = SpawnPreparedReply._(
            typeId,
            frame.correlationId,
            payload,
          );
          if (wrapped?.prepareEncoded != null) {
            await wrapped!.prepareEncoded!(prepared);
            // Encoding and preparation can run caller code. Revalidate portable
            // payload and transfer rules before the final synchronous fences.
            checkPortable(payload);
            checkTransfer(transfer);
          }
          wrapped?.beforeSend?.call();
          wrapped?.beforeSendEncoded?.call(prepared);
          _transport.send(
            Frame(
              WireKind.response,
              typeId: typeId,
              correlationId: frame.correlationId,
              payload: payload,
              transfers: transfer,
            ),
          );
        } on Object catch (error, stack) {
          _sendRequestError(frame.correlationId, error, stack);
        } finally {
          // Cleanup is part of the handler lifecycle, never an unobserved async
          // error or a second response after an already-started handoff.
          try {
            wrapped?.onSettled?.call();
          } on Object catch (error, stack) {
            _sendFatal(error, stack);
          }
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

Object? _settledPayload(Object? value) => switch (value) {
  Uint8List v => Uint8List.fromList(v),
  Uint8ClampedList v => Uint8ClampedList.fromList(v),
  Int8List v => Int8List.fromList(v),
  Uint16List v => Uint16List.fromList(v),
  Int16List v => Int16List.fromList(v),
  Uint32List v => Uint32List.fromList(v),
  Int32List v => Int32List.fromList(v),
  Uint64List v => Uint64List.fromList(v),
  Int64List v => Int64List.fromList(v),
  Float32List v => Float32List.fromList(v),
  Float64List v => Float64List.fromList(v),
  Float32x4List v => Float32x4List.fromList(v),
  Float64x2List v => Float64x2List.fromList(v),
  Int32x4List v => Int32x4List.fromList(v),
  ByteData v => ByteData.sublistView(
    Uint8List.fromList(v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes)),
  ),
  ByteBuffer v => Uint8List.fromList(v.asUint8List()).buffer,
  Map<Object?, Object?> v => <String, Object?>{
    for (final e in v.entries) e.key as String: _settledPayload(e.value),
  },
  List<Object?> v => v.map(_settledPayload).toList(),
  // Scalars and explicitly opaque platform values retain their contract.
  _ => value,
};
