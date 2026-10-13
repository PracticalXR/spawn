import 'termination.dart';

/// Thrown when a worker cannot be started, or does not start in time.
///
/// ```dart
/// try {
///   await spawn(entry, timeout: const Duration(seconds: 2));
/// } on SpawnException catch (e) {
///   print('worker never said hello: $e');
/// }
/// ```
class SpawnException implements Exception {
  /// Creates an exception describing a failed `spawn` attempt.
  SpawnException(this.message, [this.cause]);

  /// Human readable description of what went wrong.
  final String message;

  /// The underlying error, when the failure wraps one.
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'SpawnException: $message'
      : 'SpawnException: $message ($cause)';
}

/// A failed startup that retains dedicated worker termination custody.
///
/// This remains a [SpawnException] for existing callers. Its message and cause
/// describe startup; [cleanupError] separately records a failed cleanup attempt.
class SpawnStartupException extends SpawnException
    implements SpawnStartupFailure {
  /// Creates a startup failure retaining [termination] and [requestStop].
  SpawnStartupException(
    String message, {
    Object? cause,
    required this.termination,
    required Future<void> Function() requestStop,
    this.cleanupError,
  }) : _requestStop = requestStop,
       super(message, cause);

  /// The backend's original termination future.
  @override
  final Future<WorkerTerminationEvidence> termination;

  /// A failure encountered while requesting stop or cleaning up the route.
  ///
  /// The startup message, cause, and thrown stack remain those of startup.
  final Object? cleanupError;

  final Future<void> Function() _requestStop;

  /// Retries the retained backend stop request and logical route cleanup.
  @override
  Future<void> requestStop() => _requestStop();
}

/// An error that was thrown inside a worker and re-thrown on the host.
///
/// The original type name, message and stack trace are preserved as text; the
/// original object itself cannot cross an isolate or worker boundary.
class RemoteWorkerError extends Error {
  /// Creates a remote error from the parts carried in an `error` frame.
  RemoteWorkerError(this.remoteType, this.message, this.remoteStackTrace);

  /// The `runtimeType` of the error as it was thrown inside the worker.
  final String remoteType;

  /// The remote error's message.
  final String message;

  /// The remote stack trace, as text. Empty when the worker had none.
  final String remoteStackTrace;

  @override
  String toString() {
    final buffer = StringBuffer('RemoteWorkerError: $remoteType: $message');
    if (remoteStackTrace.isNotEmpty) {
      buffer
        ..write('\nworker stack trace:\n')
        ..write(remoteStackTrace);
    }
    return buffer.toString();
  }
}

/// Thrown on the web when a worker's compiled payload is not present.
///
/// The fix is always the same, and this error names it: run
/// `dart run spawn:build` in the package that owns the worker.
class SpawnPayloadMissingError extends Error {
  /// Creates the error for the entry identified by [asset], loaded from [url].
  SpawnPayloadMissingError(this.asset, this.url, [this.cause]);

  /// The entry's asset id, for example `packages/my_package/workers/peaks`.
  final String asset;

  /// The URL that was requested and could not be loaded.
  final String url;

  /// The underlying loader error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      'SpawnPayloadMissingError: no compiled payload for "$asset" at "$url".\n'
      'Run `dart run spawn:build` in the package that owns the worker, and '
      'make sure lib/workers/build/ ships as an asset.';
}

/// A missing web payload discovered after a dedicated Worker was created.
///
/// Existing catches of [SpawnPayloadMissingError] continue to match. The raw
/// Worker and its stop callback remain in custody if termination could not be
/// requested successfully.
class SpawnPayloadStartupException extends SpawnPayloadMissingError
    implements SpawnStartupFailure {
  /// Creates a payload failure retaining [termination] and [requestStop].
  SpawnPayloadStartupException(
    String asset,
    String url, {
    Object? cause,
    required this.termination,
    required Future<void> Function() requestStop,
    this.cleanupError,
  }) : _requestStop = requestStop,
       super(asset, url, cause);

  /// The backend's original termination future.
  @override
  final Future<WorkerTerminationEvidence> termination;

  /// A failure encountered while requesting stop or cleaning up the route.
  final Object? cleanupError;

  final Future<void> Function() _requestStop;

  /// Retries the retained backend stop request and logical route cleanup.
  @override
  Future<void> requestStop() => _requestStop();
}

/// Thrown when a `.service` entry is spawned with no provider registered for
/// its `SpawnService`.
///
/// See `SpawnServices.register`.
class SpawnServiceUnavailableError extends Error {
  /// Creates the error naming the [service] that has no provider.
  SpawnServiceUnavailableError(this.service);

  /// The service the entry asked for.
  final Object service;

  @override
  String toString() =>
      'SpawnServiceUnavailableError: $service has no provider.\n'
      'Register one with SpawnServices.register(...) - media apps: add the '
      'spawn_flutter package or your media-session package\'s provider.';
}
