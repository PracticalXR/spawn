import 'dart:async';

import 'package:spawn/spawn.dart';
import 'package:test/test.dart';

import 'workers/echo_worker.dart';

const playbackEntry = SpawnEntry.service(
  echoWorker,
  asset: 'packages/spawn/workers/echo_worker',
  service: SpawnService.mediaPlayback,
  protocol: registerTestProtocol,
);

const syncEntry = SpawnEntry.service(
  echoWorker,
  asset: 'packages/spawn/workers/echo_worker',
  service: SpawnService.dataSync,
  protocol: registerTestProtocol,
);

class _FakeProvider implements ServiceProvider {
  _FakeProvider(this.provides);

  @override
  final Set<SpawnService> provides;

  final List<SpawnService> acquired = <SpawnService>[];
  final List<SpawnService> released = <SpawnService>[];
  Duration delay = Duration.zero;
  Object? failWith;

  @override
  Future<ServiceGrant> acquire(SpawnService service, SpawnEntry entry) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final failure = failWith;
    if (failure != null) throw failure;
    acquired.add(service);
    return _FakeGrant(this, service);
  }
}

class _FakeGrant implements ServiceGrant {
  _FakeGrant(this.provider, this.service);

  final _FakeProvider provider;
  final SpawnService service;

  @override
  Future<void> release() async => provider.released.add(service);
}

void main() {
  setUp(SpawnServices.reset);
  tearDown(SpawnServices.reset);

  test(
    'spawning an unprovided service names the service and the fix',
    () async {
      await expectLater(
        spawnLocal(playbackEntry),
        throwsA(
          isA<SpawnServiceUnavailableError>().having(
            (e) => e.toString(),
            'toString',
            allOf(
              contains('mediaPlayback'),
              contains('SpawnServices.register'),
            ),
          ),
        ),
      );
    },
  );

  test('a registered provider is acquired before the handler runs', () async {
    final provider = _FakeProvider(<SpawnService>{SpawnService.mediaPlayback});
    SpawnServices.register(provider);

    final worker = await spawnLocal(playbackEntry);
    expect(provider.acquired, <SpawnService>[SpawnService.mediaPlayback]);
    expect(provider.released, isEmpty);

    await worker.close();
    expect(provider.released, <SpawnService>[SpawnService.mediaPlayback]);
  });

  test('grants are reference counted per service', () async {
    final provider = _FakeProvider(<SpawnService>{SpawnService.mediaPlayback});
    SpawnServices.register(provider);

    final first = await spawnLocal(playbackEntry);
    final second = await spawnLocal(playbackEntry);
    final third = await spawnLocal(playbackEntry);
    expect(provider.acquired, hasLength(1), reason: 'one platform service');

    await first.close();
    await second.close();
    expect(provider.released, isEmpty, reason: 'one worker still holds it');

    await third.close();
    expect(provider.released, <SpawnService>[SpawnService.mediaPlayback]);
  });

  test('concurrent spawns do not start two platform services', () async {
    final provider = _FakeProvider(<SpawnService>{SpawnService.mediaPlayback})
      ..delay = const Duration(milliseconds: 30);
    SpawnServices.register(provider);

    final workers = await Future.wait(<Future<Worker>>[
      spawnLocal(playbackEntry),
      spawnLocal(playbackEntry),
      spawnLocal(playbackEntry),
    ]);
    expect(provider.acquired, hasLength(1));

    await Future.wait(workers.map((w) => w.close()));
    expect(provider.released, hasLength(1));
  });

  test('different services are counted separately', () async {
    final provider = _FakeProvider(<SpawnService>{
      SpawnService.mediaPlayback,
      SpawnService.dataSync,
    });
    SpawnServices.register(provider);

    final playback = await spawnLocal(playbackEntry);
    final sync = await spawnLocal(syncEntry);
    expect(provider.acquired, hasLength(2));

    await playback.close();
    expect(provider.released, <SpawnService>[SpawnService.mediaPlayback]);
    await sync.close();
    expect(provider.released, hasLength(2));
  });

  test('a provider that fails to acquire fails the spawn', () async {
    final provider = _FakeProvider(<SpawnService>{SpawnService.mediaPlayback})
      ..failWith = StateError('no notification permission');
    SpawnServices.register(provider);

    await expectLater(spawnLocal(playbackEntry), throwsA(isA<StateError>()));
    // The failed acquisition must not leave a dangling reference count.
    provider.failWith = null;
    final worker = await spawnLocal(playbackEntry);
    expect(provider.acquired, hasLength(1));
    await worker.close();
  });

  test('a worker that dies on its own still releases the service', () async {
    final provider = _FakeProvider(<SpawnService>{SpawnService.mediaPlayback});
    SpawnServices.register(provider);

    final worker = await spawnLocal(playbackEntry);
    final subscription = worker.events.listen((_) {}, onError: (_) {});
    addTearDown(subscription.cancel);

    worker.post('fatal');
    await worker.done;
    expect(provider.released, <SpawnService>[SpawnService.mediaPlayback]);
  });

  test('an ordinary entry needs no provider', () async {
    final worker = await spawnLocal(echoEntry);
    addTearDown(() => worker.close(force: true));
    expect(await worker.request<String>('fine'), 'fine');
  });

  test('isAvailable reports what is registered', () {
    expect(SpawnServices.isAvailable(SpawnService.mediaPlayback), isFalse);
    final provider = _FakeProvider(<SpawnService>{SpawnService.mediaPlayback});
    SpawnServices.register(provider);
    expect(SpawnServices.isAvailable(SpawnService.mediaPlayback), isTrue);
    expect(SpawnServices.isAvailable(SpawnService.mediaProjection), isFalse);
    SpawnServices.unregister(provider);
    expect(SpawnServices.isAvailable(SpawnService.mediaPlayback), isFalse);
  });

  test('the first registered provider wins, so an app can override', () async {
    final appProvider = _FakeProvider(<SpawnService>{
      SpawnService.mediaPlayback,
    });
    final packageProvider = _FakeProvider(<SpawnService>{
      SpawnService.mediaPlayback,
    });
    SpawnServices.register(appProvider);
    SpawnServices.register(packageProvider);

    final worker = await spawnLocal(playbackEntry);
    addTearDown(() => worker.close(force: true));
    expect(appProvider.acquired, hasLength(1));
    expect(packageProvider.acquired, isEmpty);
  });

  test('registering the same provider twice is a no-op', () {
    final provider = _FakeProvider(<SpawnService>{SpawnService.dataSync});
    SpawnServices.register(provider);
    SpawnServices.register(provider);
    SpawnServices.unregister(provider);
    expect(SpawnServices.isAvailable(SpawnService.dataSync), isFalse);
  });

  group('jobs are declared but not scheduled yet', () {
    test('enqueue throws and says when it lands', () async {
      const job = JobEntry(
        echoWorker,
        asset: 'packages/spawn/workers/echo_worker',
        uniqueName: 'nightly-sync',
        requiresNetwork: true,
      );
      await expectLater(
        Jobs.enqueue(job),
        throwsA(
          isA<UnimplementedError>().having(
            (e) => e.message,
            'message',
            contains('later release'),
          ),
        ),
      );
    });

    test('a malformed job is rejected today, not at scheduling time', () {
      const job = JobEntry(
        echoWorker,
        asset: 'packages/spawn/workers/echo_worker',
        uniqueName: '',
      );
      expect(job.validate, throwsA(isA<ArgumentError>()));
    });

    test('a valid job validates', () {
      const job = JobEntry(
        echoWorker,
        asset: 'packages/spawn/workers/echo_worker',
        uniqueName: 'ok',
      );
      expect(job.validate, returnsNormally);
    });
  });
}
