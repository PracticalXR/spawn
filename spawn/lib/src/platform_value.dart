/// A value only the current platform can carry, passed through untouched.
///
/// `spawn` normally insists that a message be portable - the portable set or a
/// `WireMessage` - so that a message which works in a VM test works in a
/// browser. Some values cannot play by that rule and should not have to: a
/// `VideoFrame` decoded by WebCodecs is a GPU surface with no byte encoding
/// worth the name, and copying it out to make it portable would defeat the
/// reason it was decoded on a worker in the first place.
///
/// This is the door out of the rule, and it is deliberately a visible one.
/// Wrapping a value says: *this payload is platform-specific, and I know it.*
///
/// ```dart
/// // In a worker, sending a decoded frame to the main thread:
/// channel.send(
///   <String, Object?>{
///     'ptsUs': frame.timestamp,
///     'frame': PlatformValue(videoFrame),
///   },
///   transfer: <Object>[PlatformValue(videoFrame)],
/// );
/// ```
///
/// **Web:** [value] must be something the structured clone algorithm accepts -
/// a `VideoFrame`, `AudioData`, `ImageBitmap`, `OffscreenCanvas`,
/// `MessagePort`, `ReadableStream`. List it in `transfer` to move it rather
/// than clone it; most of these are transfer-only and will throw if cloned.
///
/// **Native:** [value] must be isolate-sendable. Most things are, but the VM
/// copies the object graph, so this is not a way to share mutable state.
///
/// A wrapped value never crosses a native- or wasm-hosted worker: those
/// boundaries carry bytes, and there are none here. That restriction is the
/// price of the escape hatch, and the reason it is not the default.
final class PlatformValue {
  /// Wraps [value] for transport without encoding or inspection.
  const PlatformValue(this.value);

  /// The platform object. Cast it to the type you know it is on arrival.
  final Object? value;

  @override
  String toString() => 'PlatformValue(${value.runtimeType})';
}
