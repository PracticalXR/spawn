import 'dart:async';

import 'channel.dart';
import 'service.dart';

/// A worker's body: the function `spawn` runs on the other thread.
///
/// It must be a top-level or static function - a closure cannot cross an
/// isolate boundary, and on the web the function has to be reachable from the
/// compiled payload's `main`.
///
/// The worker ends when this future completes. Returning early is a normal
/// shutdown; throwing surfaces on the host as a `RemoteWorkerError` on
/// `Worker.events`.
typedef WorkerHandler = FutureOr<void> Function(WorkerChannel channel);

/// How an entry's code reaches the worker.
enum SpawnEntryKind {
  /// The handler is in the same library graph as the caller, and the compiled
  /// payload also contains it.
  inline,

  /// The handler reaches the caller through a conditional import that resolves
  /// to a stub on the web, keeping the worker body out of the main bundle.
  split,

  /// Like [inline], and declares a [SpawnService] the worker must run under.
  service,

  /// The worker is a native or wasm host reached over the wire envelope.
  /// Reserved; spawning one throws [UnsupportedError] in this release.
  native,
}

/// The identity of a worker: its handler, its compiled payload, and the
/// lifetime it needs.
///
/// Declare one `const` per worker, next to the worker itself, and pass it to
/// `spawn`. The [asset] id is the worker's name everywhere - it is what the
/// web backend resolves to a payload URL, and what shows up in errors and
/// isolate debug names.
///
/// ```dart
/// const peaksEntry = SpawnEntry.inline(
///   peaksWorker,
///   asset: 'packages/my_package/workers/peaks_worker',
/// );
/// ```
class SpawnEntry {
  /// A worker whose handler is reachable from the calling library.
  ///
  /// On the web the handler also ends up in the main bundle. That is usually
  /// fine; use [SpawnEntry.split] when it is not.
  const SpawnEntry.inline(
    WorkerHandler this.handler, {
    required this.asset,
    this.protocol,
  }) : kind = SpawnEntryKind.inline,
       service = null;

  /// A worker whose handler is imported conditionally, so the web bundle only
  /// contains a stub.
  ///
  /// The recipe is two files and no magic:
  ///
  /// ```dart
  /// // peaks_entry.dart
  /// import 'peaks_handler_stub.dart'
  ///     if (dart.library.isolate) 'peaks_handler.dart';
  ///
  /// const peaksEntry = SpawnEntry.split(
  ///   peaksHandler,
  ///   asset: 'packages/my_package/workers/peaks_worker',
  /// );
  /// ```
  ///
  /// The stub declares `peaksHandler` and throws if called; only the compiled
  /// payload carries the real body. The web backend never runs a split entry
  /// on the main thread, so a missing payload always reports the build step
  /// rather than silently working in debug.
  const SpawnEntry.split(
    WorkerHandler this.handler, {
    required this.asset,
    this.protocol,
  }) : kind = SpawnEntryKind.split,
       service = null;

  /// A worker that must outlive the UI, running under [service].
  ///
  /// Spawning throws `SpawnServiceUnavailableError` when no provider is
  /// registered for [service]; see [SpawnServices.register].
  const SpawnEntry.service(
    WorkerHandler this.handler, {
    required this.asset,
    required SpawnService this.service,
    this.protocol,
  }) : kind = SpawnEntryKind.service;

  /// A worker hosted outside Dart, reached over the wire envelope.
  ///
  /// Reserved: this release carries the envelope and the capability flag but
  /// has no native host, so spawning throws [UnsupportedError].
  const SpawnEntry.native({required this.asset, this.protocol})
    : kind = SpawnEntryKind.native,
      handler = null,
      service = null;

  /// How this entry's code reaches the worker.
  final SpawnEntryKind kind;

  /// The function the worker runs. `null` only for [SpawnEntryKind.native].
  final WorkerHandler? handler;

  /// The worker's identity, conventionally
  /// `packages/<package>/workers/<file stem>`.
  ///
  /// The web backend turns that into
  /// `assets/packages/<package>/workers/build/<file stem>.dart.js`. An asset
  /// that is already a URL - it starts with `/`, `./`, `http:` or `https:`, or
  /// ends in `.js` - is used as given, which is what tests and non-Flutter web
  /// apps do.
  final String asset;

  /// The platform lifetime this worker needs, or `null` for an ordinary
  /// worker.
  final SpawnService? service;

  /// Registers this worker's `WireMessage` decoders, on both ends.
  ///
  /// A `WireRegistry` belongs to one isolate or worker, so a registration the
  /// host makes does not reach the worker - and a protocol that appears to
  /// work in a unit test fails the moment it runs on a real thread. Naming the
  /// registration function here fixes that: `spawn` calls it on the host
  /// before connecting, and the worker calls it before the handler runs.
  ///
  /// ```dart
  /// void registerPeaksProtocol() {
  ///   WireRegistry.instance.register(1, ScanCmd.decode);
  /// }
  ///
  /// const peaksEntry = SpawnEntry.inline(
  ///   peaksWorker,
  ///   asset: 'packages/my_package/workers/peaks_worker',
  ///   protocol: registerPeaksProtocol,
  /// );
  /// ```
  ///
  /// Must be a top-level or static function, and must be safe to call more
  /// than once - registering the same decoder for the same id twice is a
  /// no-op. On the web, pass the same function to `runWorker` in the payload's
  /// `main`, since the payload never sees the entry.
  final void Function()? protocol;

  @override
  String toString() => 'SpawnEntry.${kind.name}($asset)';
}
