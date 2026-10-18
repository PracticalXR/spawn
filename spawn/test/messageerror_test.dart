// A message the worker cannot deserialize is REPORTED, not lost.
//
// The browser delivers such a message as a `messageerror` event with no
// data: the worker never sees the request, so without a report the host
// simply waits for its timeout. The worker side now sends a correlation-less
// `DataCloneError` frame (it cannot know which request — the id was inside
// the data). This pins what the host does with it, over the loopback pair
// with the worker end driven by hand.

import 'dart:async';

import 'package:spawn/spawn.dart';
import 'package:spawn/src/backend/loopback.dart';
import 'package:spawn/src/frame.dart';
import 'package:spawn/src/wire.dart';
import 'package:spawn/src/worker.dart' show createWorker;
import 'package:test/test.dart';

import 'workers/echo_worker.dart';

Future<void> _settle([int turns = 6]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Frame _dataClone() => Frame(
  WireKind.error,
  payload: encodeErrorPayload(
    'DataCloneError',
    'a message from the host could not be deserialized by the worker',
    '',
  ),
);

void main() {
  test(
    '🔴 fails every request in flight with the reason and KEEPS the worker',
    () async {
      final pair = LoopbackPair();
      var echo = false;
      pair.worker.incoming.listen((f) {
        if (echo && f.kind == WireKind.request) {
          pair.worker.send(
            Frame(
              WireKind.response,
              typeId: f.typeId,
              correlationId: f.correlationId,
              payload: f.payload,
            ),
          );
        }
      });
      pair.worker.send(const Frame(WireKind.hello));
      final worker = await createWorker(
        echoEntry,
        pair.host,
        const Duration(seconds: 1),
      );
      addTearDown(() => worker.close(force: true));

      // Two requests in flight — the report cannot say which one, so both
      // must fail, with the reason.
      final a = worker.request<Object?>(
        'a',
        timeout: const Duration(seconds: 5),
      );
      final b = worker.request<Object?>(
        'b',
        timeout: const Duration(seconds: 5),
      );
      await _settle();
      pair.worker.send(_dataClone());
      for (final pending in [a, b]) {
        await expectLater(
          pending,
          throwsA(
            isA<RemoteWorkerError>().having(
              (e) => e.remoteType,
              'remoteType',
              'DataCloneError',
            ),
          ),
        );
      }
      // The worker is alive: the next portable message is answered as usual.
      expect(worker.isClosed, isFalse);
      echo = true;
      expect(
        await worker.request<Object?>('c', timeout: const Duration(seconds: 1)),
        'c',
      );
    },
  );

  test('with nothing in flight the report reaches the events stream', () async {
    final pair = LoopbackPair();
    pair.worker.send(const Frame(WireKind.hello));
    final worker = await createWorker(
      echoEntry,
      pair.host,
      const Duration(seconds: 1),
    );
    addTearDown(() => worker.close(force: true));
    final errors = <Object>[];
    final sub = worker.events.listen((_) {}, onError: errors.add);
    addTearDown(sub.cancel);
    pair.worker.send(_dataClone());
    await _settle();
    expect(errors, hasLength(1));
    expect(errors.single, isA<RemoteWorkerError>());
    expect(worker.isClosed, isFalse);
  });

  test('any other correlation-less error is still fatal', () async {
    final pair = LoopbackPair();
    pair.worker.send(const Frame(WireKind.hello));
    final worker = await createWorker(
      echoEntry,
      pair.host,
      const Duration(seconds: 1),
    );
    addTearDown(() => worker.close(force: true));
    final sub = worker.events.listen((_) {}, onError: (_) {});
    addTearDown(sub.cancel);
    pair.worker.send(
      Frame(
        WireKind.error,
        payload: encodeErrorPayload('StateError', 'the handler threw', ''),
      ),
    );
    await _settle(12);
    expect(worker.isClosed, isTrue);
  });
}
