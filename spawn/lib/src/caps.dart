/// What is actually executing a worker's handler.
enum SpawnHost {
  /// A Dart isolate or a Dart-compiled Web Worker. The only value this release
  /// produces.
  dart,

  /// A native event loop reached over the wire envelope. Reserved.
  native,

  /// A wasm module hosted by the framework. Reserved.
  wasmModule,
}

/// The form of the code a worker is running.
enum SpawnPayload {
  /// Native AOT or JIT - no separate payload is needed.
  aot,

  /// A `dart compile js` payload, produced by `dart run spawn:build`.
  js,

  /// A `dart compile wasm` payload, produced by
  /// `dart run spawn:build --target wasm`.
  wasm,
}

/// What a running worker can do, reported in its `hello` frame.
///
/// ```dart
/// final worker = await spawn(entry);
/// if (!worker.caps.zeroCopyTransfer) {
///   // Buffers are copied here; batch fewer, larger messages.
/// }
/// ```
class SpawnCaps {
  /// Creates a capability set.
  const SpawnCaps({
    required this.hosted,
    required this.payload,
    required this.zeroCopyTransfer,
    this.isolated = false,
  });

  /// Reads capabilities from the JSON object in a `hello` payload.
  ///
  /// Unknown enum values decode to the nearest supported value rather than
  /// throwing, so a newer worker can still talk to an older host.
  factory SpawnCaps.fromJson(Map<String, Object?> json) => SpawnCaps(
    hosted: _enumByName(SpawnHost.values, json['hosted'], SpawnHost.dart),
    payload: _enumByName(
      SpawnPayload.values,
      json['payload'],
      SpawnPayload.aot,
    ),
    zeroCopyTransfer: json['zeroCopyTransfer'] == true,
    isolated: json['isolated'] == true,
  );

  /// What is executing the handler.
  final SpawnHost hosted;

  /// The form of the code being executed.
  final SpawnPayload payload;

  /// Whether entries in a `transfer` list move instead of being copied.
  ///
  /// `true` on the web, where the platform detaches the source buffer. `true`
  /// on native for the shapes documented on `WorkerClient.post`; other shapes
  /// fall back to the isolate message copy.
  final bool zeroCopyTransfer;

  /// Whether this handler has its own isolate or Web Worker global state.
  ///
  /// In-process tests and the web debug fallback share the caller's globals.
  /// They must not tear down a shared singleton as if it belonged only to the
  /// worker. This describes execution ownership, not a security sandbox or a
  /// promise of exclusive native resources. Absent on older peers means false.
  final bool isolated;

  /// The JSON object carried in a `hello` payload.
  Map<String, Object?> toJson() => <String, Object?>{
    'hosted': hosted.name,
    'payload': payload.name,
    'zeroCopyTransfer': zeroCopyTransfer,
    'isolated': isolated,
  };

  @override
  String toString() =>
      'SpawnCaps(hosted: ${hosted.name}, payload: ${payload.name}, '
      'zeroCopyTransfer: $zeroCopyTransfer, isolated: $isolated)';

  static T _enumByName<T extends Enum>(
    List<T> values,
    Object? name,
    T fallback,
  ) {
    if (name is! String) return fallback;
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }
}
