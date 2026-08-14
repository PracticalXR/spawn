import 'dart:typed_data';

import 'wire.dart';

/// One message in flight, in the shape every backend agrees on.
///
/// [payload] is either a [Uint8List] - framework frames and [WireMessage]
/// payloads - or a portable value that the backend carries natively. The
/// [transfers] list is metadata for the backend and never crosses on its own.
class Frame {
  /// Creates a frame.
  const Frame(
    this.kind, {
    this.typeId = 0,
    this.correlationId = 0,
    this.payload,
    this.transfers,
  });

  /// What the frame is.
  final WireKind kind;

  /// The payload's [WireMessage.typeId], or `0` for framework frames and
  /// portable values.
  final int typeId;

  /// Pairs requests with responses; `0` when not part of a request.
  final int correlationId;

  /// The encoded bytes or the portable value.
  final Object? payload;

  /// Buffers the caller asked to move rather than copy.
  final List<Object>? transfers;

  /// Whether [payload] is already bytes.
  bool get isEncoded => payload is Uint8List;

  /// [payload] as bytes. Only valid when [isEncoded].
  Uint8List get bytes => payload! as Uint8List;

  /// The header describing this frame.
  WireHeader get header => WireHeader(
    kind: kind,
    typeId: typeId,
    correlationId: correlationId,
    payloadLength: isEncoded ? bytes.lengthInBytes : 0,
  );

  @override
  String toString() =>
      'Frame($kind, typeId: $typeId, correlationId: $correlationId, '
      'payload: ${isEncoded ? '${bytes.lengthInBytes} bytes' : payload.runtimeType})';
}
