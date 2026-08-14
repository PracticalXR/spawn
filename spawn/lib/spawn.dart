/// Background execution for Dart that works everywhere: isolates on native,
/// Web Workers on the web, one API.
///
/// A worker is an ordinary Dart file under `lib/workers/` whose `main` calls
/// `runWorker`. One `const` `SpawnEntry` names it, and `spawn` starts it:
///
/// ```dart
/// // lib/workers/peaks_worker.dart
/// import 'package:spawn/spawn.dart';
///
/// Future<void> peaksWorker(WorkerChannel channel) async {
///   await for (final message in channel.messages) {
///     final peaks = scan(message! as Uint8List);
///     channel.send(peaks, transfer: [peaks.buffer]);
///   }
/// }
///
/// void main() => runWorker(peaksWorker);
/// ```
///
/// ```dart
/// const peaksEntry = SpawnEntry.inline(
///   peaksWorker,
///   asset: 'packages/my_package/workers/peaks_worker',
/// );
///
/// final worker = await spawn(peaksEntry);
/// worker.post(bytes, transfer: [bytes.buffer]);
/// ```
///
/// Before running on the web, compile the payload once with
/// `dart run spawn:build`. Packages that ship workers ship the compiled
/// payload as an asset, so their consumers build nothing.
library;

export 'src/caps.dart' show SpawnCaps, SpawnHost, SpawnPayload;
export 'src/channel.dart' show WorkerChannel;
export 'src/entry.dart' show SpawnEntry, SpawnEntryKind, WorkerHandler;
export 'src/errors.dart'
    show
        RemoteWorkerError,
        SpawnException,
        SpawnPayloadMissingError,
        SpawnServiceUnavailableError;
export 'src/jobs.dart' show JobEntry, Jobs;
export 'src/platform_value.dart' show PlatformValue;
export 'src/service.dart'
    show ServiceGrant, ServiceProvider, SpawnService, SpawnServices;
export 'src/spawn.dart' show spawn, spawnLocal;
export 'src/wire.dart'
    show
        WireEnvelope,
        WireHeader,
        WireKind,
        WireMessage,
        WireRegistry,
        WireDecoder;
export 'src/worker.dart' show Worker, WorkerClient;
export 'src/worker_entrypoint.dart' show runWorker;
