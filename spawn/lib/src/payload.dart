import 'dart:typed_data';

import 'frame.dart';
import 'wire.dart';

/// Turns a user value into the `(typeId, payload)` pair a [Frame] carries.
///
/// A [WireMessage] is encoded to bytes on every platform, not just where the
/// platform demands it. That is deliberate: a protocol behaves identically
/// everywhere, a missing [WireRegistry] registration fails the same way on the
/// VM as in a browser, and a worker can later move to a native or wasm host
/// without its protocol changing.
(int typeId, Object? payload) encodeValue(Object? value) {
  if (value is WireMessage) {
    final typeId = value.typeId;
    if (typeId < 1 || typeId > WireEnvelope.maxTypeId) {
      throw ArgumentError.value(
        typeId,
        'typeId',
        '${value.runtimeType}.typeId must be in '
            '1..${WireEnvelope.maxTypeId} (0 is reserved)',
      );
    }
    return (typeId, value.encode());
  }
  checkPortable(value);
  return (0, value);
}

/// Reverses [encodeValue].
Object? decodeValue(int typeId, Object? payload) {
  if (typeId == 0) return payload;
  if (payload is! Uint8List) {
    throw StateError(
      'spawn: frame declares typeId $typeId but carries '
      '${payload.runtimeType} instead of bytes',
    );
  }
  return WireRegistry.instance.decode(typeId, payload);
}

/// Throws [ArgumentError] unless [value] is something every backend can carry.
///
/// The portable set is `null`, `bool`, `int`, `double`, `String`, [TypedData],
/// [ByteBuffer], and [List]s and [String]-keyed [Map]s of those. Anything else
/// must implement [WireMessage].
///
/// This is checked on every platform, including the VM where an isolate would
/// happily copy far more. A message that works in a test on the VM has to work
/// in a browser, or the package's single-API promise is a lie.
void checkPortable(Object? value) =>
    _checkPortable(value, <Object>[], 'message');

void _checkPortable(Object? value, List<Object> seen, String path) {
  if (value == null ||
      value is bool ||
      value is num ||
      value is String ||
      value is TypedData ||
      value is ByteBuffer) {
    return;
  }
  if (value is List<Object?> || value is Map<Object?, Object?>) {
    for (final ancestor in seen) {
      if (identical(ancestor, value)) {
        throw ArgumentError.value(
          value,
          path,
          'spawn cannot carry a cyclic structure',
        );
      }
    }
    seen.add(value);
    if (value is List<Object?>) {
      for (var i = 0; i < value.length; i++) {
        _checkPortable(value[i], seen, '$path[$i]');
      }
    } else if (value is Map<Object?, Object?>) {
      value.forEach((key, element) {
        if (key is! String) {
          throw ArgumentError.value(
            key,
            path,
            'spawn map keys must be String, got ${key.runtimeType}',
          );
        }
        _checkPortable(element, seen, '$path["$key"]');
      });
    }
    seen.removeLast();
    return;
  }
  throw ArgumentError.value(
    value,
    path,
    'spawn cannot carry ${value.runtimeType}. Portable values are null, bool, '
    'int, double, String, TypedData, ByteBuffer, and List/Map<String, ...> '
    'of those. Implement WireMessage for anything else.',
  );
}

/// Throws [ArgumentError] unless every entry of [transfer] is a buffer.
void checkTransfer(List<Object>? transfer) {
  if (transfer == null) return;
  for (var i = 0; i < transfer.length; i++) {
    final item = transfer[i];
    if (item is! TypedData && item is! ByteBuffer) {
      throw ArgumentError.value(
        item,
        'transfer[$i]',
        'transfer entries must be TypedData or ByteBuffer, '
            'got ${item.runtimeType}',
      );
    }
  }
}

/// Whether [buffer] backs [candidate], so a transfer entry can be matched to
/// the payload it belongs to.
bool bufferMatches(Object candidate, Object buffer) {
  if (identical(candidate, buffer)) return true;
  if (candidate is TypedData && buffer is ByteBuffer) {
    return identical(candidate.buffer, buffer);
  }
  if (candidate is ByteBuffer && buffer is TypedData) {
    return identical(candidate, buffer.buffer);
  }
  if (candidate is TypedData && buffer is TypedData) {
    return identical(candidate.buffer, buffer.buffer);
  }
  return false;
}
