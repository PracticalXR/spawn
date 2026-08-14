import 'dart:async';

import 'frame.dart';

/// One end of the pipe between a host and its worker.
///
/// Backends implement this and nothing else; every channel guarantee - request
/// correlation, event buffering, close semantics - is built on top of it once,
/// so an isolate, a Web Worker and an in-process loopback behave identically.
abstract interface class WorkerTransport {
  /// Frames arriving from the other end.
  ///
  /// Single subscription. Closes when the other end is gone.
  Stream<Frame> get incoming;

  /// Sends [frame] to the other end.
  ///
  /// Must not throw once the transport is closed; dropping is correct, because
  /// the layer above has already reported the closure.
  void send(Frame frame);

  /// Completes when the other end has gone away, for any reason.
  Future<void> get done;

  /// Ends the other end immediately, without waiting for it to finish.
  Future<void> kill();
}
