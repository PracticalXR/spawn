import 'dart:async';

import '../caps.dart';
import '../channel.dart';
import '../entry.dart';
import '../service.dart';
import '../worker.dart';
import 'loopback.dart';

/// Runs [entry]'s handler on the current thread, behind a real [Worker].
///
/// Every channel guarantee holds - request correlation, event buffering, close
/// semantics - but nothing runs in parallel. This is what `spawnLocal` uses,
/// and what the web backend falls back to in debug builds when a payload has
/// not been built.
Future<Worker> connectLocal(
  SpawnEntry entry, {
  required Object? message,
  required Duration timeout,
  required SpawnCaps caps,
  ServiceGrant? grant,
}) {
  final handler = entry.handler;
  if (handler == null) {
    throw UnsupportedError(
      'spawn: ${entry.asset} has no handler to run in this process',
    );
  }
  final pair = LoopbackPair();
  final pending = createWorker(entry, pair.host, timeout, grant: grant);
  unawaited(
    Future<void>.microtask(() async {
      await runHandlerOn(pair.worker, handler, message, caps);
      // Tearing the worker end down is what makes the host's `done` complete,
      // so a graceful close returns as soon as the handler does instead of
      // waiting out the grace period.
      await pair.worker.kill();
    }),
  );
  return pending;
}
