@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';
import 'package:spawn/spawn.dart';
import 'package:test/test.dart';

const _entry = SpawnEntry.inline(
  _serve,
  asset: 'packages/spawn/test/guarded_reply',
);

final class _EncodedReply implements WireMessage {
  _EncodedReply(this.bytes, [this.onEncode]);
  static const kind = 3971;
  final Uint8List bytes;
  final void Function()? onEncode;
  @override
  int get typeId => kind;
  @override
  Uint8List encode() {
    onEncode?.call();
    return Uint8List.fromList(bytes);
  }

  static WireMessage decode(Uint8List bytes) => _EncodedReply(bytes);
}

Future<void> _serve(WorkerChannel channel) async {
  var revoked = false, settled = 0;
  var encodes = 0;
  Uint8List? owned;
  Completer<void>? release;
  final subscription = channel.messages.listen((message) {
    if (message == 'revoke') {
      revoked = true;
      release?.complete();
    }
  });
  channel.handleRequests((request) {
    if (request == 'stats') {
      return {'settled': settled, 'cleared': owned?.first == 0};
    }
    if (request == 'encodes') return encodes;
    final bytes = owned = Uint8List.fromList([41, 42, 43]);
    SpawnPreparedReply? prepared;
    return SpawnReply(
      request == 'encoded'
          ? _EncodedReply(bytes, () => encodes++)
          : {'bytes': bytes},
      prepare: () async {
        if (request == 'hold') {
          release = Completer<void>();
          channel.send('prepared');
          await release!.future;
        }
      },
      prepareEncoded: (reply) {
        prepared = reply;
        if (request == 'encoded' &&
            (reply.typeId != _EncodedReply.kind ||
                reply.correlationId == 0 ||
                reply.payload is! Uint8List)) {
          throw StateError('Preparation did not receive the encoded reply');
        }
      },
      beforeSend: () {
        if (revoked) throw StateError('Retired before handoff');
        // Retirement after the first handoff begins cannot discard its result.
        revoked = true;
      },
      beforeSendEncoded: (reply) {
        if (!identical(prepared, reply) ||
            request == 'encoded' && encodes != 1) {
          throw StateError('Final handoff changed or re-encoded the reply');
        }
      },
      onSettled: () {
        bytes.fillRange(0, bytes.length, 0);
        settled++;
      },
    );
  });
  await channel.onClose;
  await subscription.cancel();
}

void main() {
  WireRegistry.instance.register(_EncodedReply.kind, _EncodedReply.decode);
  test('encoded preparation and handoff use one exact native reply', () async {
    final worker = await spawn(_entry);
    addTearDown(() => worker.close(force: true));
    final reply = await worker.request<_EncodedReply>('encoded');
    expect(reply.bytes, Uint8List.fromList([41, 42, 43]));
    expect(await worker.request<Object?>('encodes'), 1);
    expect(await worker.request<Object?>('stats'), {
      'settled': 1,
      'cleared': true,
    });
  });
  test('loopback retains reply bytes when sender disposes its copy', () async {
    final worker = await spawnLocal(_entry);
    addTearDown(() => worker.close(force: true));
    final result = await worker.request<Map<String, Object?>>('send');
    expect(result['bytes'], Uint8List.fromList([41, 42, 43]));
    expect(await worker.request<Object?>('stats'), {
      'settled': 1,
      'cleared': true,
    });
  });

  test('refuses retired prepared reply and settles its owned bytes', () async {
    final worker = await spawn(_entry);
    addTearDown(() => worker.close(force: true));
    final prepared = Completer<void>();
    final events = worker.events.listen((event) {
      if (event == 'prepared') prepared.complete();
    });
    addTearDown(events.cancel);
    final refused = expectLater(
      worker.request<Object?>('hold'),
      throwsA(isA<RemoteWorkerError>()),
    );
    await prepared.future;
    worker.post('revoke');
    await refused;
    expect(await worker.request<Object?>('stats'), {
      'settled': 1,
      'cleared': true,
    });
  });

  test('begun reply drains before owned bytes are cleared', () async {
    final worker = await spawn(_entry);
    addTearDown(() => worker.close(force: true));
    final result = await worker.request<Map<Object?, Object?>>('send');
    expect(result['bytes'], Uint8List.fromList([41, 42, 43]));
    expect(await worker.request<Object?>('stats'), {
      'settled': 1,
      'cleared': true,
    });
  });
}
