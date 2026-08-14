import 'entry.dart';

/// A unit of work the operating system runs later, on its own schedule.
///
/// Jobs are the sibling of workers, with the contract inverted: a worker runs
/// now, for as long as you hold it; a job runs eventually, possibly after the
/// process has died and been restarted, and reports progress you watch rather
/// than await.
///
/// **Not yet implemented.** This release parses and validates job entries so a
/// worker file that declares one needs no migration later, but [Jobs.enqueue]
/// throws. Do not ship a feature that depends on it.
///
/// When it lands it maps to Android `WorkManager` and iOS `BGTaskScheduler`.
/// Neither is a cron: Android is reliable within its constraints, iOS is
/// opportunistic and may never run a task on a device the user rarely opens,
/// and the web has no resurrection at all.
class JobEntry {
  /// Declares a job.
  const JobEntry(
    WorkerHandler this.handler, {
    required this.asset,
    required this.uniqueName,
    this.requiresNetwork = false,
    this.requiresCharging = false,
    this.requiresIdle = false,
    this.initialDelay = Duration.zero,
    this.backoff = const Duration(seconds: 30),
  });

  /// The function the job runs, checkpointing as it goes.
  final WorkerHandler? handler;

  /// The compiled payload's asset id, as for `SpawnEntry`.
  final String asset;

  /// Identifies this job to the platform scheduler. Enqueuing the same name
  /// twice replaces the earlier request rather than adding a second one.
  final String uniqueName;

  /// Whether the platform should wait for a network connection.
  final bool requiresNetwork;

  /// Whether the platform should wait until the device is charging.
  final bool requiresCharging;

  /// Whether the platform should wait until the device is idle.
  final bool requiresIdle;

  /// How long the platform should wait before the first attempt.
  final Duration initialDelay;

  /// The base delay for retrying a failed attempt; platforms back off from it.
  final Duration backoff;

  /// Throws [ArgumentError] if this entry could not be scheduled.
  ///
  /// Called by [Jobs.enqueue]. Exposed so a worker file's declarations can be
  /// checked by a test today, before the scheduler exists.
  void validate() {
    if (uniqueName.isEmpty) {
      throw ArgumentError.value(uniqueName, 'uniqueName', 'must not be empty');
    }
    if (initialDelay.isNegative) {
      throw ArgumentError.value(
        initialDelay,
        'initialDelay',
        'must not be negative',
      );
    }
    if (backoff <= Duration.zero) {
      throw ArgumentError.value(backoff, 'backoff', 'must be positive');
    }
    if (handler == null) {
      throw ArgumentError.value(handler, 'handler', 'a job needs a handler');
    }
  }

  @override
  String toString() => 'JobEntry($uniqueName, $asset)';
}

/// The deferred, OS-scheduled half of `spawn`.
///
/// **Not yet implemented**; see [JobEntry].
abstract final class Jobs {
  /// Hands [entry] to the platform scheduler.
  ///
  /// Always throws [UnimplementedError] in this release. The entry is
  /// validated first, so a mistake in a job declaration still surfaces.
  static Future<void> enqueue(JobEntry entry) => Future<void>.sync(() {
    entry.validate();
    throw UnimplementedError(
      'spawn: Jobs.enqueue is not implemented yet. Deferred, OS-scheduled work '
      'lands in a later release; JobEntry exists now so worker files declaring '
      'one need no migration.',
    );
  });
}
