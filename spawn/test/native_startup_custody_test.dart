@TestOn('vm')
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:spawn/spawn.dart';
import 'package:test/test.dart';

void main() {
  test(
    'hello timeout retains real onExit while startup is blocked in FFI',
    () async {
      final api = _WindowsEvents();
      final releaseGate = api.createEvent();
      final Pointer<Void> enteredGate;
      try {
        enteredGate = api.createEvent();
      } on Object {
        api.closeHandle(releaseGate);
        rethrow;
      }

      Future<_SpawnOutcome>? attempt;
      var confirmedExit = false;
      try {
        // Only ordinary integer HANDLE values and a SendPort cross isolates.
        // The protocol runs on the host too; its control port skips that call.
        final protocol = _GateProtocol(
          Isolate.current.controlPort,
          enteredGate.address,
          releaseGate.address,
        );
        final entry = SpawnEntry.inline(
          _waitForMessages,
          asset: 'native-startup-custody-gate',
          protocol: protocol.call,
        );
        attempt = spawn(entry, timeout: const Duration(seconds: 1))
            .then<_SpawnOutcome>(
              _SpawnOutcome.started,
              onError: (Object error, StackTrace stack) =>
                  _SpawnOutcome.failed(error, stack),
            );

        await _awaitSignaled(api, enteredGate);
        final outcome = await attempt.timeout(const Duration(seconds: 5));
        expect(
          outcome.error,
          isA<SpawnStartupException>(),
          reason: '${outcome.stack}',
        );
        final failure = outcome.error! as SpawnStartupException;
        expect(failure, isA<SpawnException>());
        expect(failure.message, contains('did not start within 1000ms'));
        expect(failure.cleanupError, isNull);

        final receipt = failure.termination;
        var acknowledgments = 0;
        unawaited(receipt.then<void>((_) => acknowledgments++));
        expect(identical(failure.termination, receipt), isTrue);

        // Neither the original timeout nor repeated logical stops may stand
        // in for VM exit while the worker is still inside the native call.
        final firstStop = failure.requestStop();
        final secondStop = failure.requestStop();
        expect(identical(firstStop, secondStop), isTrue);
        await Future.wait(<Future<void>>[firstStop, secondStop])
            .timeout(const Duration(seconds: 1));
        await expectLater(
          receipt.timeout(const Duration(milliseconds: 25)),
          throwsA(isA<TimeoutException>()),
        );
        expect(acknowledgments, 0);

        api.signal(releaseGate);
        expect(
          await receipt.timeout(const Duration(seconds: 5)),
          WorkerTerminationEvidence.nativeOnExit,
        );
        confirmedExit = true;
        await failure.requestStop();
        expect(identical(failure.termination, receipt), isTrue);
        expect(acknowledgments, 1);
      } finally {
        // Always release FFI, including when spawn/assertions/observation fail.
        // Do not close a HANDLE that a regressed backend might still wait on.
        api.signal(releaseGate);
        final pending = attempt;
        try {
          if (pending == null) {
            confirmedExit = true; // No isolate was requested.
          } else {
            final outcome = await pending.timeout(const Duration(seconds: 5));
            final worker = outcome.worker;
            final error = outcome.error;
            if (worker != null) {
              await worker.close(force: true);
              confirmedExit =
                  await worker.termination.timeout(
                    const Duration(seconds: 5),
                  ) ==
                  WorkerTerminationEvidence.nativeOnExit;
            } else if (error is SpawnStartupFailure) {
              await error.requestStop();
              final evidence = await error.termination.timeout(
                const Duration(seconds: 5),
              );
              confirmedExit =
                  evidence == WorkerTerminationEvidence.nativeOnExit ||
                  evidence == WorkerTerminationEvidence.notStarted;
            }
          }
        } finally {
          if (confirmedExit) {
            api.closeHandle(enteredGate);
            api.closeHandle(releaseGate);
          }
        }
      }
    },
    skip: !Platform.isWindows || sizeOf<IntPtr>() != 8
        ? 'Uses the 64-bit Windows kernel event API without a native build.'
        : false,
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test('a real VM spawn rejection reports notStarted', () async {
    final unsendablePort = ReceivePort();
    try {
      // A bound protocol tear-off retains a ReceivePort, which Isolate.spawn
      // rejects before creating an actor. This is not a hello timeout.
      final protocol = _UnsendableProtocol(unsendablePort);
      final entry = SpawnEntry.inline(
        _waitForMessages,
        asset: 'native-startup-rejected',
        protocol: protocol.call,
      );
      SpawnStartupException? failure;
      try {
        final worker = await spawn(entry);
        await worker.close(force: true);
        fail('Isolate.spawn unexpectedly accepted a ReceivePort');
      } on SpawnStartupException catch (error) {
        failure = error;
      }
      expect(failure, isNotNull);
      expect(failure!.cause, isNotNull);
      expect(
        await failure.termination.timeout(const Duration(seconds: 5)),
        WorkerTerminationEvidence.notStarted,
      );
      await failure.requestStop();
      await failure.requestStop();
    } finally {
      unsendablePort.close();
    }
  });
}

Future<void> _waitForMessages(WorkerChannel channel) async {
  await for (final _ in channel.messages) {}
}

class _SpawnOutcome {
  _SpawnOutcome.started(this.worker) : error = null, stack = null;
  _SpawnOutcome.failed(this.error, this.stack) : worker = null;

  final Worker? worker;
  final Object? error;
  final StackTrace? stack;
}

class _GateProtocol {
  const _GateProtocol(
    this.hostControlPort,
    this.enteredHandle,
    this.releaseHandle,
  );

  final SendPort hostControlPort;
  final int enteredHandle;
  final int releaseHandle;

  void call() {
    if (Isolate.current.controlPort == hostControlPort) return;
    final api = _WindowsEvents();
    // The marker is signaled inside this same blocking native call. The host
    // therefore knows FFI was entered before it checks timeout/stop evidence.
    final result = api.signalAndWait(
      Pointer<Void>.fromAddress(enteredHandle),
      Pointer<Void>.fromAddress(releaseHandle),
      0xffffffff,
      0,
    );
    if (result != 0) throw StateError('SignalObjectAndWait returned $result');
  }
}

class _UnsendableProtocol {
  const _UnsendableProtocol(this.port);

  final ReceivePort port;

  void call() {
    if (port.sendPort == Isolate.current.controlPort) {
      throw StateError('unexpected control port');
    }
  }
}

Future<void> _awaitSignaled(_WindowsEvents api, Pointer<Void> event) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (api.waitForSingleObject(event, 0) == 0x102) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('worker never entered its pre-hello FFI gate');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(api.waitForSingleObject(event, 0), 0);
}

typedef _CreateEventNative = Pointer<Void> Function(
  Pointer<Void>,
  Int32,
  Int32,
  Pointer<Uint16>,
);
typedef _CreateEventDart = Pointer<Void> Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Uint16>,
);
typedef _HandleOperationNative = Int32 Function(Pointer<Void>);
typedef _HandleOperationDart = int Function(Pointer<Void>);
typedef _WaitNative = Uint32 Function(Pointer<Void>, Uint32);
typedef _WaitDart = int Function(Pointer<Void>, int);
typedef _SignalAndWaitNative = Uint32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Int32,
);
typedef _SignalAndWaitDart = int Function(
  Pointer<Void>,
  Pointer<Void>,
  int,
  int,
);

class _WindowsEvents {
  _WindowsEvents() {
    final library = DynamicLibrary.open('kernel32.dll');
    _createEvent = library.lookupFunction<_CreateEventNative, _CreateEventDart>(
      'CreateEventW',
    );
    _setEvent = library
        .lookupFunction<_HandleOperationNative, _HandleOperationDart>(
          'SetEvent',
        );
    _closeHandle = library
        .lookupFunction<_HandleOperationNative, _HandleOperationDart>(
          'CloseHandle',
        );
    waitForSingleObject = library.lookupFunction<_WaitNative, _WaitDart>(
      'WaitForSingleObject',
    );
    // Non-leaf FFI deliberately models a real synchronous native wait.
    signalAndWait = library
        .lookupFunction<_SignalAndWaitNative, _SignalAndWaitDart>(
          'SignalObjectAndWait',
        );
  }

  late final _CreateEventDart _createEvent;
  late final _HandleOperationDart _setEvent;
  late final _HandleOperationDart _closeHandle;
  late final _WaitDart waitForSingleObject;
  late final _SignalAndWaitDart signalAndWait;

  Pointer<Void> createEvent() {
    final event = _createEvent(nullptr, 1, 0, nullptr);
    if (event.address == 0) throw StateError('CreateEventW failed');
    return event;
  }

  void signal(Pointer<Void> event) {
    if (_setEvent(event) == 0) throw StateError('SetEvent failed');
  }

  void closeHandle(Pointer<Void> event) {
    if (_closeHandle(event) == 0) throw StateError('CloseHandle failed');
  }
}
