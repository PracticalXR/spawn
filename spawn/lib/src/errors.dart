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
