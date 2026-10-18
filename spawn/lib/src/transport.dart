import 'dart:async';

import 'frame.dart';
import 'termination.dart';

/// One end of the pipe between a host and its worker.
///
/// Backends implement this and nothing else; every channel guarantee - request
/// correlation, event buffering, close semantics - is built on top of it once,
/// so an isolate, a Web Worker and an in-process loopback behave identically.
abstract interface class WorkerTransport {
  /// Frames arriving from the other end.
  ///
  /// Single subscription. Closes when the logical route is detached.
  Stream<Frame> get incoming;

  /// Sends [frame] to the other end.
  ///
  /// Must not throw once the transport is closed; dropping is correct, because
  /// the layer above has already reported the closure.
  void send(Frame frame);

  /// Completes after logical route shutdown, for any reason.
  ///
  /// Dedicated termination is a separate [WorkerTerminationTransport] receipt.
  Future<void> get done;

  /// Requests immediate stop and closes the logical route.
  ///
  /// Does not wait for dedicated exit evidence.
  Future<void> kill();
}

/// An optional dedicated termination capability of a host transport.
///
/// Implemented by transports that own a dedicated actor, and explicitly by
/// in-process hosts. Worker-end transports do not advertise this capability.
/// Logical [WorkerTransport.done] and [WorkerTransport.kill] are independent
/// of this receipt and cannot supply missing physical exit evidence.
abstract interface class WorkerTerminationTransport {
  /// The immutable termination receipt for this transport's dedicated actor.
  Future<WorkerTerminationEvidence> get termination;
}
