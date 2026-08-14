import 'backend/backend.dart';
import 'entry.dart';

/// Makes the enclosing file a worker payload.
///
/// A worker file is an ordinary Dart file whose `main` hands its handler to
/// this function:
///
/// ```dart
/// // lib/workers/peaks_worker.dart
/// import 'package:spawn/spawn.dart';
///
/// Future<void> peaksWorker(WorkerChannel channel) async {
///   await for (final message in channel.messages) { ... }
/// }
///
/// void main() => runWorker(peaksWorker);
/// ```
///
/// `dart run spawn:build` compiles that `main` into the payload the web
/// backend loads. On native it is never called - `spawn` invokes the handler
/// directly - so calling this on the VM throws [UnsupportedError], which is
/// what running a worker file by hand looks like.
///
/// Pass [protocol] the same registration function the entry names, so the
/// payload registers its `WireMessage` decoders before it decodes anything:
///
/// ```dart
/// void main() => runWorker(peaksWorker, protocol: registerPeaksProtocol);
/// ```
void runWorker(WorkerHandler handler, {void Function()? protocol}) {
  protocol?.call();
  runWorkerEntrypoint(handler);
}
