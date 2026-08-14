import 'dart:async';

import '../frame.dart';
import '../transport.dart';

/// A pair of transports wired to each other inside one isolate.
///
/// Used by `spawnLocal`, by the web debug fallback, and by the tests that pin
/// the channel semantics - the same code path every backend goes through, with
/// the thread removed.
class LoopbackPair {
  /// Creates a connected pair.
  LoopbackPair() {
    host = LoopbackTransport._();
    worker = LoopbackTransport._();
    host._peer = worker;
    worker._peer = host;
  }

  /// The end a `Worker` is built on.
  late final LoopbackTransport host;

  /// The end the handler runs against.
  late final LoopbackTransport worker;
}

/// One end of a [LoopbackPair].
class LoopbackTransport implements WorkerTransport {
  LoopbackTransport._();

  final StreamController<Frame> _incoming = StreamController<Frame>();
  final Completer<void> _done = Completer<void>();

  late final LoopbackTransport _peer;
  bool _dead = false;

  @override
  Stream<Frame> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(Frame frame) {
    if (_dead || _peer._incoming.isClosed) return;
    _peer._incoming.add(frame);
  }

  @override
  Future<void> kill() async {
    if (_dead) return;
    _dead = true;
    _close();
    // Tearing down one end tears down the other: there is no separate thread
    // to keep alive, and leaving the peer open would hang an `await for`.
    await _peer._detach();
  }

  Future<void> _detach() async {
    if (_dead) return;
    _dead = true;
    _close();
  }

  /// Closing is never awaited: a controller that was never listened to only
  /// completes its `done` future once someone does listen, so awaiting it
  /// deadlocks a worker that nobody read from.
  void _close() {
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }
}
