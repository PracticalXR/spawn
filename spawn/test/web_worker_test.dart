@TestOn('browser')
@Tags(<String>['browser'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:spawn/spawn.dart';
import 'package:spawn/src/backend/web.dart' show resolveAssetUrl;
import 'package:test/test.dart';

import 'workers/echo_worker.dart';

/// The payload `dart run spawn:build test/workers` produced.
///
/// Relative on purpose: the test runner serves everything under a random
/// per-run prefix, so an absolute path would miss it. Resolving against the
/// page is what a real app does too.
const String payloadUrl = './workers/build/echo_worker.dart.js';

const realEntry = SpawnEntry.inline(
  echoWorker,
  asset: payloadUrl,
  protocol: registerTestProtocol,
);

/// An inline entry whose payload does not exist: the debug fallback case.
const missingInlineEntry = SpawnEntry.inline(
  echoWorker,
  asset: './workers/build/does_not_exist.dart.js',
  protocol: registerTestProtocol,
);

/// A split entry whose payload does not exist. A split worker's body is not in
/// the main bundle, so falling back is impossible and this must report the
/// build step instead.
const missingSplitEntry = SpawnEntry.split(
  echoWorker,
  asset: './workers/build/also_missing.dart.js',
);

void main() {
  group('asset resolution', () {
    test('a conventional asset id becomes a payload URL', () {
      final url = resolveAssetUrl('packages/my_package/workers/peaks_worker');
      expect(
        url,
        endsWith(
          'assets/packages/my_package/workers/build/peaks_worker.dart.js',
        ),
      );
    });

    test('an explicit URL is used as given', () {
      expect(
        resolveAssetUrl(payloadUrl),
        endsWith('workers/build/echo_worker.dart.js'),
      );
      expect(
        resolveAssetUrl('https://cdn.example/w.js'),
        'https://cdn.example/w.js',
      );
    });
  });

  group('a real Web Worker', () {
    test('the payload really loads (no silent main-thread fallback)', () async {
      // A split entry can never fall back, so this fails loudly if the payload
      // URL is wrong instead of quietly running on the main thread.
      const strict = SpawnEntry.split(
        echoWorker,
        asset: payloadUrl,
        protocol: registerTestProtocol,
      );
      final worker = await spawn(strict, timeout: const Duration(seconds: 10));
      addTearDown(() => worker.close(force: true));
      expect(await worker.request<String>('ping'), 'ping');
    });

    test('starts and reports a wasm payload', () async {
      final worker = await spawn(realEntry);
      addTearDown(() => worker.close(force: true));
      expect(worker.caps.hosted, SpawnHost.dart);
      expect(worker.caps.payload, SpawnPayload.wasm);
      expect(worker.caps.zeroCopyTransfer, isTrue);
      expect(worker.caps.isolated, isTrue);
    });

    test('answers requests', () async {
      final worker = await spawn(realEntry);
      addTearDown(() => worker.close(force: true));
      expect(await worker.request<String>('ping'), 'ping');
      expect(await worker.request<String>('payload'), 'wasm');
    });

    test('carries portable values both ways', () async {
      final worker = await spawn(realEntry);
      addTearDown(() => worker.close(force: true));
      for (final value in <Object?>[
        null,
        true,
        42,
        'text',
        <Object?>[1, 'two', null],
        <String, Object?>{'a': 1, 'b': 'two'},
      ]) {
        expect(await worker.request<Object?>(value), value);
      }
    });

    test('carries the initial message', () async {
      final worker = await spawn(realEntry, message: 'seeded');
      addTearDown(() => worker.close(force: true));
      expect(await worker.request<String>('initial'), 'seeded');
    });

    test('a structured initial message survives the init frame', () async {
      // A String initial message survived a bug here by accident; a map did
      // not. The init frame must be decoded by the same rules as any other
      // payload rather than assumed to be bytes.
      final worker = await spawn(
        realEntry,
        message: <String, Object?>{
          'name': 'config',
          'count': 3,
          'nested': <Object?>[1, null, 'two'],
        },
      );
      addTearDown(() => worker.close(force: true));
      expect(await worker.request<Object?>('initial'), <String, Object?>{
        'name': 'config',
        'count': 3,
        'nested': <Object?>[1, null, 'two'],
      });
    });

    test(
      'dictionary keys cannot become prototypes or opaque wrappers',
      () async {
        final value = <String, Object?>{
          '__proto__': <String, Object?>{'nested': 'ordinary data'},
          'constructor': <String, Object?>{'name': 'Uint8Array'},
          r'$spawn$platform': <String, Object?>{'value': 17},
          r'$spawn$map': <String, Object?>{'constructor': 'Array'},
          'toString': Uint8List.fromList([3, 7, 11]),
        };
        final worker = await spawn(realEntry, message: value);
        addTearDown(() => worker.close(force: true));
        expect(await worker.request<Object?>('initial'), value);
        expect(await worker.request<Object?>(value), value);
      },
    );

    test('a WireMessage decodes on the other side', () async {
      final worker = await spawn(realEntry);
      addTearDown(() => worker.close(force: true));
      final answer = await worker.request<Object?>(
        Blob(utf8.encode('over the wire')),
      );
      expect(answer, isA<Blob>());
      expect(utf8.decode((answer! as Blob).bytes), 'over the wire');
    });

    test('a transfer detaches the source buffer', () async {
      final worker = await spawn(realEntry);
      addTearDown(() => worker.close(force: true));

      // JS-owned storage is movable under both dart2js and dart2wasm.
      // Wasm GC-owned Dart storage itself cannot detach when converted.
      final bytes = JSUint8Array.withLength(4 * 1024 * 1024).toDart;
      bytes[0] = 7;
      bytes[bytes.length - 1] = 9;
      final buffer = bytes.buffer;
      expect(buffer.lengthInBytes, 4 * 1024 * 1024);

      final echoed = Completer<Uint8List>();
      final subscription = worker.events.listen((event) {
        if (event is Uint8List && !echoed.isCompleted) echoed.complete(event);
      });
      addTearDown(subscription.cancel);

      worker.post(bytes, transfer: <Object>[buffer]);

      // The platform moved the original JS storage, so the source is now
      // an empty, detached ArrayBuffer.
      expect(
        buffer.lengthInBytes,
        0,
        reason: 'postMessage should have detached the transferred buffer',
      );

      final result = await echoed.future.timeout(const Duration(seconds: 20));
      expect(result.lengthInBytes, 4 * 1024 * 1024);
      expect(result[0], 7);
      expect(result[result.length - 1], 9);
    });

    test('an encoded request transfers an offset byte view', () async {
      final worker = await spawn(realEntry);
      addTearDown(() => worker.close(force: true));
      final source = JSUint8Array.withLength(64).toDart;
      source.setAll(0, List.generate(64, (i) => 255 - i));
      final bytes = Uint8List.view(source.buffer, 8, 16);
      final expected = List<int>.from(bytes);
      final sourceBuffer = source.buffer;
      final answer = await worker.request<Blob>(
        Blob(bytes),
        transfer: [bytes, sourceBuffer, bytes.buffer],
      );
      expect(sourceBuffer.lengthInBytes, 0);
      expect(answer.bytes, expected);
      expect(answer.bytes.offsetInBytes, 8);
    });

    test('a transferred reply map carries bytes and metadata', () async {
      final worker = await spawn(realEntry);
      addTearDown(() => worker.close(force: true));
      final answer = await worker.request<Map<String, Object?>>('reply-map');
      expect(answer['needsKeyframe'], isTrue);
      expect(answer['rgba'], List.generate(64, (i) => (i * 3) & 0xff));
    });

    test('an opaque platform object crosses, and is transferred', () async {
      final worker = await spawn(realEntry);
      addTearDown(() => worker.close(force: true));

      // OffscreenCanvas stands in for a VideoFrame here: same story - an
      // opaque, transferable platform object with no byte encoding - but one
      // a test can conjure without a decoder.
      final canvas = _OffscreenCanvas(64, 32);
      expect(canvas.width, 64);

      // No explicit transfer list: a PlatformValue always means "move this",
      // because most of these types cannot be cloned at all.
      final measured = await worker.request<Map<String, Object?>>(
        <String, Object?>{'op': 'measure', 'canvas': PlatformValue(canvas)},
      );

      // The worker saw the real object, with its real dimensions.
      expect(measured['width'], 64);
      expect(measured['height'], 32);
      // ...and this side no longer owns it: a transferred OffscreenCanvas is
      // detached, and a detached one reports 0.
      expect(
        canvas.width,
        0,
        reason: 'the canvas should have been transferred, not cloned',
      );
    });

    test('an opaque value round-trips back from the worker', () async {
      final worker = await spawn(realEntry);
      addTearDown(() => worker.close(force: true));
      final canvas = _OffscreenCanvas(8, 4);
      // Worker to host is the direction that matters: it is how a decoded
      // VideoFrame reaches the main thread. A response has no transfer list,
      // so this only works because a PlatformValue transfers itself.
      final echoed = await worker.request<Object?>(PlatformValue(canvas));
      expect(echoed, isA<PlatformValue>());
      final returned = (echoed! as PlatformValue).value! as JSObject;
      expect(returned.getProperty<JSNumber>('width'.toJS).toDartInt, 8);
    });

    test('a handler throw closes the worker', () async {
      final worker = await spawn(realEntry);
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
    });

    test('events buffer until the first listener, then go live', () async {
      final worker = await spawn(realEntry);
      addTearDown(() => worker.close(force: true));
      worker.post('burst');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final seen = <Object?>[];
      final subscription = worker.events.listen(seen.add);
      addTearDown(subscription.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, <String>['one', 'two', 'three']);
    });

    test('graceful close ends the worker', () async {
      final worker = await spawn(realEntry);
      await worker.close();
      expect(worker.isClosed, isTrue);
      expect(worker.error, isNull);
    });

    test('attached clients share one worker', () async {
      final worker = await spawn(realEntry);
      addTearDown(() => worker.close(force: true));
      final second = worker.attach();
      final answers = await Future.wait(<Future<String>>[
        worker.request<String>('one'),
        second.request<String>('two'),
      ]);
      expect(answers, <String>['one', 'two']);
    });
  });

  group('a missing payload', () {
    test('a split entry reports the build step', () async {
      await expectLater(
        spawn(missingSplitEntry, timeout: const Duration(seconds: 5)),
        throwsA(
          isA<SpawnPayloadMissingError>().having(
            (e) => e.toString(),
            'toString',
            allOf(contains('dart run spawn:build'), contains('also_missing')),
          ),
        ),
      );
    });

    test('an inline entry falls back to the main thread in debug', () async {
      final worker = await spawn(
        missingInlineEntry,
        timeout: const Duration(seconds: 5),
      );
      addTearDown(() => worker.close(force: true));
      // It works, but it says so: nothing was transferred and nothing ran in
      // parallel.
      expect(worker.caps.zeroCopyTransfer, isFalse);
      expect(worker.caps.isolated, isFalse);
      expect(await worker.request<String>('ping'), 'ping');
    });
  });

  test('portability is enforced the same way it is on the VM', () async {
    final worker = await spawn(realEntry);
    addTearDown(() => worker.close(force: true));
    expect(() => worker.post(Object()), throwsA(isA<ArgumentError>()));
  });
}

@JS('OffscreenCanvas')
extension type _OffscreenCanvas._(JSObject _) implements JSObject {
  external factory _OffscreenCanvas(int width, int height);
  external int get width;
}
