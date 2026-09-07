// An UNCAUGHT error inside a worker, after it has said hello, is REPORTED.
//
// 🔴 The bug this pins. `_WebHostTransport` installed `onerror` only to catch
// a worker that would not START: `if (_loaded.isCompleted) return;`. After
// the hello, an uncaught worker-side error — a throw from a callback the
// browser invoked, which no request's `catch` can ever see — was dropped on
// the floor. The request in flight was never answered and the host learned
// nothing until its own timeout fired.
//
// 2026-09-01 is what that costs: the encode worker died on its very first
// `print` (a console tap whose `.toJS` closure had no `$1` stub), the host
// saw only "land did not answer within 6s", the caller read that as a hung
// GPU import, and it walked a whole fallback ladder — bring-up, 60 s first
// land, 6 s x2, a route switch, 6 s x2, a full camera restart — for a worker
// that had been dead for a minute.
//
// The host now turns that `ErrorEvent` into a correlation-less error frame
// carrying the browser's message. This drives the host end of that protocol
// over the loopback pair, exactly as `messageerror_test.dart` does — the real
// `onerror` wiring needs a browser, so it is pinned as source below.

import 'dart:async';
import 'dart:io';

import 'package:spawn/spawn.dart';
import 'package:spawn/src/backend/loopback.dart';
import 'package:spawn/src/frame.dart';
import 'package:spawn/src/wire.dart';
import 'package:spawn/src/worker.dart' show createWorker;
import 'package:test/test.dart';

import 'workers/echo_worker.dart';

Future<void> _settle([int turns = 12]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const String _why = 'the worker threw an uncaught error: '
    "NoSuchMethodError: method not found: '\$1' (line 2472)";

Frame _uncaught() => Frame(
      WireKind.error,
      payload: encodeErrorPayload('WorkerError', _why, ''),
    );

void main() {
  test('🔴 a request in flight FAILS instead of waiting for its timeout',
      () async {
    final pair = LoopbackPair();
    // The worker answers nothing, which is the whole point: before the fix
    // the only thing that ever completed this request was the timeout.
    pair.worker.incoming.listen((_) {});
    pair.worker.send(const Frame(WireKind.hello));
    final worker =
        await createWorker(echoEntry, pair.host, const Duration(seconds: 1));
    addTearDown(() => worker.close(force: true));

    final events = <Object>[];
    final sub = worker.events.listen((_) {}, onError: events.add);
    addTearDown(sub.cancel);

    // A minute of budget, so a passing test cannot be the timeout in
    // disguise — the request must be finished by the report, not by the clock.
    final pending =
        worker.request<Object?>('a', timeout: const Duration(seconds: 60));
    await _settle();
    pair.worker.send(_uncaught());

    // ...WITH the reason — the browser's text, not "timed out" — and the
    // worker is KEPT: an uncaught throw inside one handler is one lost
    // request, not a dead worker (worker.dart treats 'WorkerError' like a
    // clone failure since 2026-09-01).
    await expectLater(
        pending,
        throwsA(isA<RemoteWorkerError>()
            .having((e) => e.remoteType, 'remoteType', 'WorkerError')
            .having((e) => e.message, 'message', contains('uncaught error'))
            .having((e) => e.message, 'message', contains('method not found'))));
    expect(worker.error, isNull, reason: 'the worker must stay alive');
    expect(events, isEmpty,
        reason: 'the report went to the request that was in flight, not to '
            'the events stream');
  });

  test('with nothing in flight it still reaches the events stream', () async {
    final pair = LoopbackPair();
    pair.worker.send(const Frame(WireKind.hello));
    final worker =
        await createWorker(echoEntry, pair.host, const Duration(seconds: 1));
    addTearDown(() => worker.close(force: true));
    final errors = <Object>[];
    final sub = worker.events.listen((_) {}, onError: errors.add);
    addTearDown(sub.cancel);
    pair.worker.send(_uncaught());
    await _settle();
    expect(errors, hasLength(1));
    expect(errors.single, isA<RemoteWorkerError>());
    expect((errors.single as RemoteWorkerError).message, contains(_why));
  });

  test('🔴 the web host reports an onerror AFTER load, not just before it', () {
    // Source pin: a real `ErrorEvent` needs a browser. What is pinned is the
    // shape whose absence shipped — the early `return` that swallowed every
    // post-load error.
    final src = File('lib/src/backend/web.dart').readAsStringSync();
    final at = src.indexOf('_worker.onerror = ');
    expect(at, isNonNegative);
    final body = src.substring(at, src.indexOf('_worker.onmessageerror = ', at));
    expect(
      body.contains('if (_loaded.isCompleted || _loadFailure.isCompleted) '
          'return;'),
      isFalse,
      reason: 'that early return is the bug: it dropped every error a live '
          'worker reported',
    );
    expect(body, contains('_loadFailure.complete(_describeErrorEvent(event));'),
        reason: 'a worker that will not START is still a load failure');
    expect(body, contains('_incoming.add('));
    expect(body, contains("'WorkerError',"));
    expect(body, contains('_describeErrorEvent(event)'));
    expect(body, isNot(contains('terminate()')),
        reason: 'an ErrorEvent is a fact about one callback; the worker is '
            'not killed from inside the handler',
    );
  });
}
