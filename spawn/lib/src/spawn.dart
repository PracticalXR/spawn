import 'dart:async';

import 'backend/backend.dart';
import 'backend/local.dart';
import 'caps.dart';
import 'entry.dart';
import 'errors.dart';
import 'service.dart';
import 'worker.dart';

/// How long `spawn` waits for a worker to report for duty.
const Duration _defaultTimeout = Duration(seconds: 10);

/// Starts [entry] on another thread and completes once it is running.
///
/// On native this spawns an isolate. On the web it starts a `Worker` running
/// the entry's compiled payload. Either way the returned [Worker] behaves the
/// same, and the handler is guaranteed to have started before this completes.
///
/// ```dart
/// final worker = await spawn(peaksEntry);
/// worker.post(bytes, transfer: [bytes.buffer]);
/// final peaks = await worker.request<Peaks>(const GetPeaks());
/// await worker.close();
/// ```
///
/// [message] is handed to the handler as `WorkerChannel.initialMessage`. It
/// follows the same portability rules as `WorkerClient.post`, and buffers in
/// [transfer] move with it.
///
/// Throws [SpawnException] if the worker does not start within [timeout], and
/// [SpawnPayloadMissingError] on the web when the entry's payload has not been
/// built. An entry with a [SpawnService] throws
/// [SpawnServiceUnavailableError] when nothing provides that service; the
/// service is acquired before the handler runs and released once the worker
/// has closed.
Future<Worker> spawn(
  SpawnEntry entry, {
  Object? message,
  List<Object>? transfer,
  Duration timeout = _defaultTimeout,
}) => _start(
  entry,
  (grant) => connect(
    entry,
    message: message,
    transfer: transfer,
    timeout: timeout,
    grant: grant,
  ),
);

/// Runs [entry]'s handler on the current thread, behind a real [Worker].
///
/// Nothing runs in parallel - this is not a worker, it is the worker's
/// protocol with the thread removed. Every guarantee `spawn` makes still
/// holds, which makes it the cheap way to unit test a handler:
///
/// ```dart
/// test('answers a probe', () async {
///   final worker = await spawnLocal(peaksEntry);
///   expect(await worker.request<int>(const Probe()), 0);
///   await worker.close();
/// });
/// ```
///
/// The web backend uses this same path as its debug fallback when a payload
/// has not been built.
Future<Worker> spawnLocal(
  SpawnEntry entry, {
  Object? message,
  Duration timeout = _defaultTimeout,
}) => _start(
  entry,
  (grant) => connectLocal(
    entry,
    message: message,
    timeout: timeout,
    caps: _localCaps,
    grant: grant,
  ),
);

/// The part [spawn] and [spawnLocal] must agree on: register the protocol on
/// this end, hold the service the entry asked for, and release it again if the
/// worker never starts.
///
/// Keeping this in one place is what lets `spawnLocal` claim that every
/// guarantee holds - a service worker tested in process really does acquire
/// and release its grant.
Future<Worker> _start(
  SpawnEntry entry,
  Future<Worker> Function(ServiceGrant? grant) connector,
) async {
  entry.protocol?.call();
  final service = entry.service;
  final grant = service == null
      ? null
      : await SpawnServices.acquire(service, entry);
  try {
    return await connector(grant);
  } on Object {
    await grant?.release();
    rethrow;
  }
}

/// In-process workers share the caller's heap, so nothing is ever transferred.
const SpawnCaps _localCaps = SpawnCaps(
  hosted: SpawnHost.dart,
  payload: SpawnPayload.aot,
  zeroCopyTransfer: false,
);
