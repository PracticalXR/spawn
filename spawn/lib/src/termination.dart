/// The evidence a host has about its dedicated worker's termination.
///
/// This is independent of logical channel shutdown. Callers that retire a
/// native resource must require [nativeOnExit]; browser callers must explicitly
/// accept [browserTerminateRequested] as their platform's termination policy.
enum WorkerTerminationEvidence {
  /// The VM delivered `onExit`: the isolate will execute no further code.
  ///
  /// This does not acknowledge OS or allocator reclamation.
  nativeOnExit,

  /// The dedicated browser Worker's `terminate()` call returned successfully.
  ///
  /// This is a termination request, not an allocator or thread-exit receipt.
  browserTerminateRequested,

  /// No dedicated isolate or browser Worker was started.
  ///
  /// In-process workers also report this; it does not mean their handler has
  /// returned or stopped executing on the caller's thread.
  notStarted,

  /// The transport supplies no dedicated termination observation.
  unobservable,
}

/// Custody of a worker whose startup failed.
///
/// The failure retains its dedicated handle and stop callback until callers
/// can finish cleanup, including unblocking any synchronous native call.
abstract interface class SpawnStartupFailure {
  /// The same termination future supplied by the backend that attempted startup.
  ///
  /// A startup timeout or successful logical cleanup never supplies exit
  /// evidence. A native call that stays blocked can leave this pending forever.
  Future<WorkerTerminationEvidence> get termination;

  /// Requests stop and logical route cleanup, without waiting for exit evidence.
  ///
  /// Safe to repeat, including after a failed stop request. Callers must await
  /// [termination] separately and inspect its evidence before retiring resources.
  Future<void> requestStop();
}
