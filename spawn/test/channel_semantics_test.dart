// Pins the channel contract every backend has to honour. These run against
// the in-process loopback so they are fast and deterministic, and the native
// and browser suites re-run the same expectations over a real thread.

import 'dart:async';

import 'package:spawn/spawn.dart';
import 'package:spawn/src/backend/loopback.dart';
import 'package:spawn/src/worker.dart' show createWorker;
import 'package:test/test.dart';

import 'workers/echo_worker.dart';

Future<void> _settle([int turns = 4]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('R4.1 spawn completes on hello', () {
    test('completes once the handler is running', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      expect(worker.isClosed, isFalse);
      expect(worker.caps.hosted, SpawnHost.dart);
    });

    test('throws SpawnException when hello never arrives', () async {
      // A transport with nothing on the other end: the exact shape of a worker
      // that failed to start.
      final pair = LoopbackPair();
      addTearDown(pair.host.kill);
      await expectLater(
        createWorker(echoEntry, pair.host, const Duration(milliseconds: 50)),
        throwsA(
          isA<SpawnException>().having(
            (e) => e.message,
            'message',
            contains('did not start'),
          ),
        ),
      );
    });
  });

  group('R4.2 post is fire and forget, FIFO per client', () {
    test('delivers in send order', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      final seen = <Object?>[];
      final subscription = worker.events.listen(seen.add);
      addTearDown(subscription.cancel);

      for (var i = 0; i < 50; i++) {
        worker.post(i);
      }
      await _settle(8);
      expect(seen, List<int>.generate(50, (i) => i));
    });

    test('does not block on a slow worker', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      final before = DateTime.now();
      for (var i = 0; i < 1000; i++) {
        worker.post('x');
      }
      expect(DateTime.now().difference(before).inMilliseconds, lessThan(500));
    });
  });

  group('R4.3 request correlates and propagates failure', () {
    test('answers the matching request', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      expect(await worker.request<String>('ping'), 'ping');
    });

    test('correlates concurrent requests independently', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      final answers = await Future.wait(<Future<Object?>>[
        worker.request<String>('slow'),
        worker.request<String>('fast'),
        worker.request<String>('slow'),
        worker.request<String>('also-fast'),
      ]);
      expect(answers, <String>['slow-done', 'fast', 'slow-done', 'also-fast']);
    });

    test('a worker-side throw surfaces as RemoteWorkerError', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      await expectLater(
        worker.request<String>('boom'),
        throwsA(
          isA<RemoteWorkerError>()
              .having((e) => e.remoteType, 'remoteType', 'StateError')
              .having(
                (e) => e.message,
                'message',
                contains('requested failure'),
              )
              .having((e) => e.toString(), 'toString', contains('StateError')),
        ),
      );
      // The worker survives a failed request.
      expect(worker.isClosed, isFalse);
      expect(await worker.request<String>('still-here'), 'still-here');
    });

    test('the initial message reaches the handler', () async {
      final worker = await spawnLocal(echoEntry, message: 'seeded');
      addTearDown(() => worker.close(force: true));
      expect(await worker.request<String>('initial'), 'seeded');
    });

    test('a timeout fails the request without killing the worker', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      await expectLater(
        worker.request<String>('slow', timeout: const Duration(minutes: 0)),
        throwsA(isA<TimeoutException>()),
      );
      expect(worker.isClosed, isFalse);
      expect(await worker.request<String>('after'), 'after');
    });
  });

  group('R4.4 events buffer until the first listener', () {
    test('nothing sent before the first listener is lost', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      worker.post('burst');
      await _settle(8);

      final seen = <Object?>[];
      final subscription = worker.events.listen(seen.add);
      addTearDown(subscription.cancel);
      await _settle(8);
      expect(seen, <String>['one', 'two', 'three']);
    });

    test('a second listener gets no replay', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      worker.post('burst');
      await _settle(8);

      final first = <Object?>[];
      final firstSubscription = worker.events.listen(first.add);
      addTearDown(firstSubscription.cancel);
      await _settle(8);

      final second = <Object?>[];
      final secondSubscription = worker.events.listen(second.add);
      addTearDown(secondSubscription.cancel);
      await _settle(8);

      expect(first, <String>['one', 'two', 'three']);
      expect(second, isEmpty);

      worker.post('live');
      await _settle(8);
      expect(second, <String>['live']);
    });

    test('order is preserved across the buffered-to-live handover', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      worker
        ..post('a')
        ..post('b');
      final seen = <Object?>[];
      final subscription = worker.events.listen(seen.add);
      addTearDown(subscription.cancel);
      worker
        ..post('c')
        ..post('d');
      await _settle(12);
      expect(seen, <String>['a', 'b', 'c', 'd']);
    });
  });

  group('R4.5 a fatal handler error closes the worker', () {
    test('emits the error, then closes', () async {
      final worker = await spawnLocal(echoEntry);
      final errors = <Object>[];
      final subscription = worker.events.listen((_) {}, onError: errors.add);
      addTearDown(subscription.cancel);

      worker.post('fatal');
      await worker.done;
      await _settle(8);

      expect(errors, hasLength(1));
      expect(errors.single, isA<RemoteWorkerError>());
      expect(
        (errors.single as RemoteWorkerError).message,
        contains('worker exploded'),
      );
      expect(worker.error, same(errors.single));
      expect(worker.isClosed, isTrue);
    });

    test('post and request throw StateError after closing', () async {
      final worker = await spawnLocal(echoEntry);
      final subscription = worker.events.listen((_) {}, onError: (_) {});
      addTearDown(subscription.cancel);
      worker.post('fatal');
      await worker.done;

      expect(() => worker.post('anything'), throwsA(isA<StateError>()));
      await expectLater(
        worker.request<String>('anything'),
        throwsA(isA<StateError>()),
      );
    });

    test('a late listener still sees the fatal error', () async {
      final worker = await spawnLocal(echoEntry);
      worker.post('fatal');
      await worker.done;
      await _settle(8);

      final errors = <Object>[];
      final subscription = worker.events.listen((_) {}, onError: errors.add);
      addTearDown(subscription.cancel);
      await _settle(8);
      expect(errors.single, isA<RemoteWorkerError>());
    });

    test('an in-flight request fails when the worker dies', () async {
      final worker = await spawnLocal(echoEntry);
      final subscription = worker.events.listen((_) {}, onError: (_) {});
      addTearDown(subscription.cancel);
      final pending = worker.request<String>('slow');
      worker.post('fatal');
      await expectLater(pending, throwsA(isA<StateError>()));
    });
  });

  group('R4.6 close', () {
    test('graceful close lets the handler return', () async {
      final worker = await spawnLocal(echoEntry);
      await worker.close();
      expect(worker.isClosed, isTrue);
      expect(worker.error, isNull);
    });

    test('is idempotent', () async {
      final worker = await spawnLocal(echoEntry);
      await Future.wait(<Future<void>>[
        worker.close(),
        worker.close(),
        worker.close(force: true),
      ]);
      expect(worker.isClosed, isTrue);
    });

    test('a stubborn handler is killed after the grace period', () async {
      final worker = await spawnLocal(stubbornEntry);
      final started = DateTime.now();
      await worker.close(grace: const Duration(milliseconds: 120));
      final elapsed = DateTime.now().difference(started);
      expect(elapsed.inMilliseconds, greaterThanOrEqualTo(100));
      expect(worker.isClosed, isTrue);
    });

    test('force skips the grace period entirely', () async {
      final worker = await spawnLocal(stubbornEntry);
      final started = DateTime.now();
      await worker.close(force: true);
      expect(DateTime.now().difference(started).inMilliseconds, lessThan(100));
      expect(worker.isClosed, isTrue);
    });

    test('the worker returning by itself closes the handle', () async {
      final worker = await spawnLocal(echoEntry);
      worker.post('quit');
      await worker.done;
      expect(worker.isClosed, isTrue);
      expect(worker.error, isNull);
    });
  });

  group('R4.7 attach', () {
    test('events fan out to every client', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      final second = worker.attach();

      final ownerEvents = <Object?>[];
      final secondEvents = <Object?>[];
      final a = worker.events.listen(ownerEvents.add);
      final b = second.events.listen(secondEvents.add);
      addTearDown(a.cancel);
      addTearDown(b.cancel);

      worker.post('shared');
      await _settle(8);
      expect(ownerEvents, <String>['shared']);
      expect(secondEvents, <String>['shared']);
    });

    test('commands from both clients merge', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      final second = worker.attach();
      final seen = <Object?>[];
      final subscription = worker.events.listen(seen.add);
      addTearDown(subscription.cancel);

      worker.post('owner-1');
      second.post('other-1');
      worker.post('owner-2');
      await _settle(8);
      expect(seen, containsAll(<String>['owner-1', 'other-1', 'owner-2']));
      expect(seen, hasLength(3));
    });

    test('requests are correlated per client', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      final second = worker.attach();
      final answers = await Future.wait(<Future<String>>[
        worker.request<String>('from-owner'),
        second.request<String>('from-second'),
      ]);
      expect(answers, <String>['from-owner', 'from-second']);
    });

    test('closing a client detaches only that client', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      final second = worker.attach();
      await second.close();

      expect(second.isClosed, isTrue);
      expect(worker.isClosed, isFalse);
      expect(() => second.post('nope'), throwsA(isA<StateError>()));
      expect(await worker.request<String>('fine'), 'fine');
    });

    test('closing the worker closes every attached client', () async {
      final worker = await spawnLocal(echoEntry);
      final second = worker.attach();
      await worker.close();
      expect(second.isClosed, isTrue);
      expect(() => second.post('nope'), throwsA(isA<StateError>()));
    });

    test('attaching to a closed worker throws', () async {
      final worker = await spawnLocal(echoEntry);
      await worker.close();
      expect(worker.attach, throwsA(isA<StateError>()));
    });
  });

  group('portability is enforced identically everywhere', () {
    test('post rejects a non-portable value', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      expect(() => worker.post(Object()), throwsA(isA<ArgumentError>()));
    });

    test('portable values round-trip', () async {
      final worker = await spawnLocal(echoEntry);
      addTearDown(() => worker.close(force: true));
      for (final value in <Object?>[
        null,
        true,
        42,
        'text',
        <Object?>[1, 'two', null],
        <String, Object?>{'a': 1},
      ]) {
        expect(await worker.request<Object?>(value), value);
      }
    });
  });
}
