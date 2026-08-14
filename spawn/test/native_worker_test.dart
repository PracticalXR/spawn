@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:spawn/spawn.dart';
import 'package:test/test.dart';

import 'workers/echo_worker.dart';

void main() {
  tearDownAll(WireRegistry.instance.clear);

  test('runs the handler on another isolate', () async {
    final worker = await spawn(echoEntry);
    addTearDown(() => worker.close(force: true));
    expect(worker.caps.hosted, SpawnHost.dart);
    expect(worker.caps.payload, SpawnPayload.aot);
    expect(await worker.request<String>('ping'), 'ping');
  });

  test('really is another thread', () async {
    final worker = await spawn(echoEntry);
    addTearDown(() => worker.close(force: true));
    // A request the worker answers after a delay must not need the host's
    // event loop to be idle: block this isolate hard and the answer still
    // arrives once we yield.
    final pending = worker.request<String>('slow');
    final until = DateTime.now().add(const Duration(milliseconds: 120));
    while (DateTime.now().isBefore(until)) {
      // Deliberately synchronous: no await, no timers, nothing yields.
    }
    expect(await pending, 'slow-done');
  });

  test('the initial message crosses', () async {
    final worker = await spawn(echoEntry, message: <String, Object?>{'k': 1});
    addTearDown(() => worker.close(force: true));
    expect(await worker.request<Object?>('initial'), <String, Object?>{'k': 1});
  });

  test('moves 64 MB through a transfer', () async {
    final worker = await spawn(echoEntry);
    addTearDown(() => worker.close(force: true));

    const size = 64 * 1024 * 1024;
    final bytes = Uint8List(size);
    for (var i = 0; i < size; i += 4096) {
      bytes[i] = i % 251;
    }
    bytes[size - 1] = 42;

    final echoed = Completer<Uint8List>();
    final subscription = worker.events.listen((event) {
      if (event is Uint8List && !echoed.isCompleted) echoed.complete(event);
    });
    addTearDown(subscription.cancel);

    worker.post(bytes, transfer: <Object>[bytes.buffer]);
    final result = await echoed.future.timeout(const Duration(seconds: 30));

    expect(result.lengthInBytes, size);
    expect(result[size - 1], 42);
    expect(result[4096], 4096 % 251);
    // The worker echoed it back with its own transfer, so the bytes we hold
    // are the ones the worker released - not a copy the host also kept.
    expect(identical(result, bytes), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'a WireMessage crosses as bytes and decodes on the other side',
    () async {
      final worker = await spawn(echoEntry);
      addTearDown(() => worker.close(force: true));
      final blob = Blob(utf8.encode('protocol payload'));
      final answer = await worker.request<Object?>(blob);
      expect(answer, isA<Blob>());
      expect(utf8.decode((answer! as Blob).bytes), 'protocol payload');
    },
  );

  test('an unregistered typeId fails loudly rather than silently', () async {
    // The entry's `protocol` hook is what keeps both ends in step. An entry
    // that omits it must fail with a message that says exactly that, rather
    // than appearing to work because the host happens to have registered.
    const forgetful = SpawnEntry.inline(
      echoWorker,
      asset: 'packages/spawn/workers/echo_worker',
    );
    final worker = await spawn(forgetful);
    addTearDown(() => worker.close(force: true));
    WireRegistry.instance.register(11, Blob.decode);
    await expectLater(
      worker.request<Object?>(Blob(Uint8List(1))),
      throwsA(
        isA<RemoteWorkerError>().having(
          (e) => e.message,
          'message',
          contains('typeId 11'),
        ),
      ),
    );
  });

  test('a handler throw propagates and closes the isolate', () async {
    final worker = await spawn(echoEntry);
    final errors = <Object>[];
    final subscription = worker.events.listen((_) {}, onError: errors.add);
    addTearDown(subscription.cancel);

    worker.post('fatal');
    await worker.done.timeout(const Duration(seconds: 10));

    expect(errors.single, isA<RemoteWorkerError>());
    expect(
      (errors.single as RemoteWorkerError).message,
      contains('worker exploded'),
    );
    expect(worker.isClosed, isTrue);
    expect(() => worker.post('x'), throwsA(isA<StateError>()));
  });

  test('graceful close returns as soon as the handler does', () async {
    final worker = await spawn(echoEntry);
    final started = DateTime.now();
    await worker.close();
    final elapsed = DateTime.now().difference(started);
    expect(worker.isClosed, isTrue);
    // Nowhere near the five second grace period.
    expect(elapsed.inMilliseconds, lessThan(2000));
  });

  test('a stubborn handler is force-killed after the grace period', () async {
    final worker = await spawn(stubbornEntry);
    final started = DateTime.now();
    await worker.close(grace: const Duration(milliseconds: 200));
    final elapsed = DateTime.now().difference(started);
    expect(elapsed.inMilliseconds, greaterThanOrEqualTo(180));
    expect(elapsed.inMilliseconds, lessThan(3000));
    expect(worker.isClosed, isTrue);
  });

  test('force close is immediate', () async {
    final worker = await spawn(stubbornEntry);
    final started = DateTime.now();
    await worker.close(force: true);
    expect(DateTime.now().difference(started).inMilliseconds, lessThan(500));
  });

  test('closing is idempotent under concurrency', () async {
    final worker = await spawn(echoEntry);
    await Future.wait(<Future<void>>[
      worker.close(),
      worker.close(),
      worker.close(force: true),
    ]);
    expect(worker.isClosed, isTrue);
  });

  test('attached clients share one isolate', () async {
    final worker = await spawn(echoEntry);
    addTearDown(() => worker.close(force: true));
    final second = worker.attach();

    final ownerEvents = <Object?>[];
    final secondEvents = <Object?>[];
    final a = worker.events.listen(ownerEvents.add);
    final b = second.events.listen(secondEvents.add);
    addTearDown(a.cancel);
    addTearDown(b.cancel);

    final answers = await Future.wait(<Future<String>>[
      worker.request<String>('one'),
      second.request<String>('two'),
    ]);
    expect(answers, <String>['one', 'two']);

    worker.post('broadcast');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ownerEvents, <String>['broadcast']);
    expect(secondEvents, <String>['broadcast']);
  });

  test('many workers run concurrently', () async {
    final workers = await Future.wait(
      List<Future<Worker>>.generate(6, (_) => spawn(echoEntry)),
    );
    addTearDown(() => Future.wait(workers.map((w) => w.close(force: true))));
    final answers = await Future.wait(
      workers.map((w) => w.request<String>('hello')),
    );
    expect(answers, List<String>.filled(6, 'hello'));
  });

  test('SpawnEntry.native is reserved, not silently broken', () async {
    await expectLater(
      spawn(const SpawnEntry.native(asset: 'packages/spawn/workers/hosted')),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('runWorker on the VM explains what it is for', () {
    expect(
      () => runWorker(echoWorker),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('compiled web payload'),
        ),
      ),
    );
  });
}
