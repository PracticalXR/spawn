import 'dart:async';

import 'entry.dart';
import 'errors.dart';

/// A platform lifetime a worker can ask to run under.
///
/// These name the guarantees an operating system offers, not the work being
/// done: a worker declares which one it needs, and a registered
/// [ServiceProvider] supplies the platform machinery.
enum SpawnService {
  /// Audio or video playback that must continue with the app in the
  /// background. Android foreground service (`mediaPlayback`), iOS background
  /// audio session.
  mediaPlayback,

  /// Screen or window capture that must continue with the app in the
  /// background. Android foreground service (`mediaProjection`).
  mediaProjection,

  /// Data transfer the user is waiting on. Android foreground service
  /// (`dataSync`).
  dataSync,

  /// A short burst of work that must survive backgrounding. Android
  /// foreground service (`shortService`), iOS background task assertion.
  shortService,

  /// A lifetime the platform has no dedicated category for. Requires an
  /// app-supplied justification in store review.
  specialUse,
}

/// A held platform lifetime, released when the worker closes.
abstract interface class ServiceGrant {
  /// Releases the platform lifetime.
  ///
  /// Called by `spawn` once the last worker holding this service has closed.
  /// Must be idempotent.
  Future<void> release();
}

/// Supplies the platform machinery behind one or more [SpawnService] values.
///
/// Providers ship as ordinary packages - a Flutter plugin is the only way
/// Kotlin service classes and manifest entries can reach an app build - and
/// are registered before any `.service` worker is spawned.
///
/// ```dart
/// class MyMediaServices implements ServiceProvider {
///   @override
///   Set<SpawnService> get provides => const {SpawnService.mediaPlayback};
///
///   @override
///   Future<ServiceGrant> acquire(SpawnService service, SpawnEntry entry) async {
///     await _platform.startForegroundService();
///     return _MyGrant(_platform);
///   }
/// }
/// ```
abstract interface class ServiceProvider {
  /// The services this provider can supply.
  Set<SpawnService> get provides;

  /// Acquires [service] on behalf of [entry].
  ///
  /// Called before the worker's handler runs, and only when the reference
  /// count for [service] goes from zero to one.
  Future<ServiceGrant> acquire(SpawnService service, SpawnEntry entry);
}

/// The registry `spawn` consults when a `.service` entry is spawned.
///
/// ```dart
/// void main() {
///   SpawnServices.register(MyMediaServices());
///   runApp(const MyApp());
/// }
/// ```
abstract final class SpawnServices {
  static final List<ServiceProvider> _providers = <ServiceProvider>[];
  static final Map<SpawnService, _Held> _held = <SpawnService, _Held>{};

  /// Adds [provider]. Registering the same instance twice is a no-op.
  ///
  /// When two providers offer the same service the first one registered wins,
  /// so an app can override a package's default by registering earlier.
  static void register(ServiceProvider provider) {
    if (!_providers.contains(provider)) _providers.add(provider);
  }

  /// Removes [provider]. Grants it already handed out are unaffected.
  static void unregister(ServiceProvider provider) =>
      _providers.remove(provider);

  /// Removes every provider and forgets held grants. Intended for tests.
  static void reset() {
    _providers.clear();
    _held.clear();
  }

  /// Whether some registered provider offers [service].
  static bool isAvailable(SpawnService service) =>
      _providers.any((p) => p.provides.contains(service));

  /// Acquires [service] for [entry], reference counted per service.
  ///
  /// The provider is only asked on the transition from zero holders to one;
  /// every later caller shares the same grant. Throws
  /// [SpawnServiceUnavailableError] when nothing provides [service].
  static Future<ServiceGrant> acquire(
    SpawnService service,
    SpawnEntry entry,
  ) async {
    final held = _held[service];
    if (held != null) {
      held.refCount++;
      return _SharedGrant(service);
    }
    ServiceProvider? provider;
    for (final candidate in _providers) {
      if (candidate.provides.contains(service)) {
        provider = candidate;
        break;
      }
    }
    if (provider == null) throw SpawnServiceUnavailableError(service);
    // Reserve the slot before awaiting so two concurrent spawns of the same
    // service do not both start a platform service.
    final pending = _Held(provider.acquire(service, entry));
    _held[service] = pending;
    try {
      pending.grant = await pending.pending;
      return _SharedGrant(service);
    } on Object {
      _held.remove(service);
      rethrow;
    }
  }

  static Future<void> _release(SpawnService service) async {
    final held = _held[service];
    if (held == null) return;
    if (--held.refCount > 0) return;
    _held.remove(service);
    await (held.grant ?? await held.pending).release();
  }
}

class _Held {
  _Held(this.pending);

  final Future<ServiceGrant> pending;
  ServiceGrant? grant;
  int refCount = 1;
}

class _SharedGrant implements ServiceGrant {
  _SharedGrant(this._service);

  final SpawnService _service;
  bool _released = false;

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await SpawnServices._release(_service);
  }
}
