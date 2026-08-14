// A worker entrypoint used by every backend's tests: the VM spawns it as an
// isolate, `dart run spawn:build test/workers` compiles it for the browser,
// and `spawnLocal` runs it in process. One file, three backends - which is the
// point of the package.

import 'dart:async';
import 'dart:typed_data';

import 'package:spawn/spawn.dart';

import 'opaque_stub.dart' if (dart.library.js_interop) 'opaque_web.dart';

/// Echoes messages, answers requests, and can be told to misbehave.
Future<void> echoWorker(WorkerChannel channel) async {
  channel.handleRequests((request) async {
    if (request == 'boom') throw StateError('requested failure');
    if (request == 'initial') return channel.initialMessage;
    if (request == 'payload') return channel.caps.payload.name;
    if (request is Map<String, Object?> && request['op'] == 'measure') {
      // An opaque platform object arrived. Report what it actually is, which
      // proves the browser handed us the real thing rather than a husk.
      final canvas = (request['canvas']! as PlatformValue).value;
      return <String, Object?>{
        'width': measureOpaque(canvas, 'width'),
        'height': measureOpaque(canvas, 'height'),
      };
    }
    if (request is PlatformValue) return request; // echo it straight back
    if (request == 'slow') {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return 'slow-done';
    }
    return request;
  });

  await for (final message in channel.messages) {
    if (message == 'fatal') throw StateError('worker exploded');
    if (message == 'quit') return;
    if (message == 'burst') {
      channel.send('one');
      channel.send('two');
      channel.send('three');
      continue;
    }
    if (message is Uint8List) {
      channel.send(message, transfer: <Object>[message.buffer]);
      continue;
    }
    channel.send(message);
  }
}

/// A worker that ignores the request to stop, so `close` has to force it.
Future<void> stubbornWorker(WorkerChannel channel) async {
  channel.messages.listen((_) {});
  await Completer<void>().future; // never completes
}

/// A protocol type the tests round-trip across a real thread boundary.
class Blob implements WireMessage {
  /// Wraps [bytes].
  const Blob(this.bytes);

  @override
  int get typeId => 11;

  @override
  Uint8List encode() => bytes;

  /// The payload.
  final Uint8List bytes;

  /// Rebuilds a [Blob] from [bytes].
  static Blob decode(Uint8List bytes) => Blob(bytes);
}

/// Registers the test protocol. Named by [echoEntry], so both ends get it.
void registerTestProtocol() => WireRegistry.instance.register(11, Blob.decode);

/// The entry the native and in-process tests use.
const echoEntry = SpawnEntry.inline(
  echoWorker,
  asset: 'packages/spawn/workers/echo_worker',
  protocol: registerTestProtocol,
);

/// The entry the force-close test uses.
const stubbornEntry = SpawnEntry.inline(
  stubbornWorker,
  asset: 'packages/spawn/workers/stubborn_worker',
);

void main() => runWorker(echoWorker, protocol: registerTestProtocol);
