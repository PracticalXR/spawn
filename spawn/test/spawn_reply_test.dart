/// [SpawnReply] — a request handler's way to MOVE buffers instead of cloning.
///
/// Why it exists: the request direction has carried a `transfer` list from the
/// start, the response direction had none — so a worker returning a decoded
/// video frame structured-cloned W×H×4 bytes per frame (3.7 MB at 720p) into
/// the receiving thread. The wrapper is additive: a handler returning a plain
/// value is untouched, which the paired test below pins.
library;

import 'dart:typed_data';

import 'package:spawn/spawn.dart';
import 'package:test/test.dart';

Future<void> replyWorker(WorkerChannel channel) async {
  channel.handleRequests((req) {
    if (req == 'plain') return {'kind': 'plain', 'n': 7};
    // The transfer names the SAME buffer the value references — the contract.
    final rgba = Uint8List.fromList(List.filled(64, 0xAB));
    return SpawnReply(
      {'kind': 'wrapped', 'rgba': rgba},
      transfer: [rgba.buffer],
    );
  });
  await channel.onClose;
}

const _entry = SpawnEntry.inline(replyWorker, asset: 'test/reply_worker');

void main() {
  test(
    'a SpawnReply is unwrapped: the requester sees the inner value',
    () async {
      final w = await spawnLocal(_entry);
      addTearDown(w.close);

      final got = await w.request<Object?>('wrapped') as Map;
      expect(got['kind'], 'wrapped');
      final rgba = got['rgba'] as Uint8List;
      expect(rgba.length, 64);
      expect(
        rgba[0],
        0xAB,
        reason:
            'the bytes must survive the move intact — a detached or '
            'zeroed buffer here means the transfer list and the value '
            'referenced different buffers',
      );
    },
  );

  test('a plain return value is untouched (the additive half)', () async {
    final w = await spawnLocal(_entry);
    addTearDown(w.close);
    final got = await w.request<Object?>('plain') as Map;
    expect(got, {'kind': 'plain', 'n': 7});
  });

  test('a malformed transfer list is refused at the reply, not sent', () async {
    // checkTransfer applies to replies exactly as it does to send(): an
    // untransferable entry surfaces as the request's error rather than
    // vanishing downstream.
    final w = await spawnLocal(
      SpawnEntry.inline((channel) async {
        channel.handleRequests(
          (_) => SpawnReply('x', transfer: [DateTime.now()]),
        );
        await channel.onClose;
      }, asset: 'test/bad_reply_worker'),
    );
    addTearDown(w.close);
    await expectLater(w.request<Object?>('go'), throwsA(anything));
  });
}
