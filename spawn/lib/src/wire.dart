import 'dart:convert';
import 'dart:typed_data';

/// The kind of a frame on the wire.
///
/// The numeric [code] is part of the wire format and must not change.
enum WireKind {
  /// Worker to host, once at startup, carrying the worker's capabilities.
  hello(0),

  /// Either direction: "I am done". Host to worker asks the handler to return;
  /// worker to host reports that it has returned.
  bye(1),

  /// A one-way message: host to worker for `WorkerClient.post`, worker to host
  /// for `WorkerChannel.send`.
  message(2),

  /// Host to worker, expecting a [response] or an [error] with the same
  /// correlation id.
  request(3),

  /// Worker to host, answering a [request].
  response(4),

  /// An error. With a non-zero correlation id it fails one [request]; with a
  /// zero correlation id it is a fatal handler error.
  error(5);

  const WireKind(this.code);

  /// The byte written at offset 1 of the envelope header.
  final int code;

  /// The kind for [code], or `null` if no kind uses it.
  static WireKind? fromCode(int code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

/// The decoded 12-byte envelope header.
class WireHeader {
  /// Creates a header. [version] defaults to [WireEnvelope.version].
  const WireHeader({
    required this.kind,
    this.typeId = 0,
    this.correlationId = 0,
    this.payloadLength = 0,
    this.version = WireEnvelope.version,
  });

  /// Envelope version. Always [WireEnvelope.version] for frames this release
  /// produces.
  final int version;

  /// What the frame is.
  final WireKind kind;

  /// The protocol type id of the payload, or `0` when the payload is not a
  /// [WireMessage] (framework frames always use `0`).
  final int typeId;

  /// Pairs a [WireKind.request] with its [WireKind.response] or
  /// [WireKind.error]. `0` means "not part of a request".
  final int correlationId;

  /// Length in bytes of the payload that follows the header.
  final int payloadLength;

  @override
  String toString() =>
      'WireHeader(v$version, $kind, typeId: $typeId, '
      'correlationId: $correlationId, payloadLength: $payloadLength)';

  @override
  bool operator ==(Object other) =>
      other is WireHeader &&
      other.version == version &&
      other.kind == kind &&
      other.typeId == typeId &&
      other.correlationId == correlationId &&
      other.payloadLength == payloadLength;

  @override
  int get hashCode =>
      Object.hash(version, kind, typeId, correlationId, payloadLength);
}

/// The byte format every `spawn` frame uses.
///
/// Little-endian, a 12-byte header followed by `payloadLength` bytes:
///
/// | offset | type | field                                   |
/// |--------|------|-----------------------------------------|
/// | 0      | u8   | version (currently 1)                   |
/// | 1      | u8   | kind ([WireKind.code])                  |
/// | 2      | u16  | typeId                                  |
/// | 4      | u32  | correlationId                           |
/// | 8      | u32  | payloadLength                           |
/// | 12     | ...  | payload                                 |
///
/// Dart-to-Dart channels may carry values without encoding them, but every
/// frame they exchange has an equivalent in this format - which is what keeps
/// a future native- or wasm-hosted worker a drop-in replacement.
abstract final class WireEnvelope {
  /// The envelope version this release reads and writes.
  static const int version = 1;

  /// Size of the header in bytes.
  static const int headerLength = 12;

  /// Largest value [WireHeader.typeId] can hold.
  static const int maxTypeId = 0xFFFF;

  /// Writes [header] as [headerLength] bytes.
  ///
  /// [WireHeader.payloadLength] is written as given; use [encode] to keep it
  /// consistent with an actual payload.
  static Uint8List encodeHeader(WireHeader header) {
    final bytes = Uint8List(headerLength);
    final view = ByteData.sublistView(bytes);
    view.setUint8(0, header.version);
    view.setUint8(1, header.kind.code);
    view.setUint16(2, header.typeId, Endian.little);
    view.setUint32(4, header.correlationId, Endian.little);
    view.setUint32(8, header.payloadLength, Endian.little);
    return bytes;
  }

  /// Reads a header from the first [headerLength] bytes of [bytes].
  ///
  /// Throws [FormatException] when the buffer is too short, the version is not
  /// [version], or the kind byte is unknown.
  static WireHeader decodeHeader(Uint8List bytes) {
    if (bytes.lengthInBytes < headerLength) {
      throw FormatException(
        'spawn envelope: need at least $headerLength bytes, '
        'got ${bytes.lengthInBytes}',
      );
    }
    final view = ByteData.sublistView(bytes, 0, headerLength);
    final wireVersion = view.getUint8(0);
    if (wireVersion != version) {
      throw FormatException(
        'spawn envelope: unsupported version $wireVersion (expected $version)',
      );
    }
    final kindCode = view.getUint8(1);
    final kind = WireKind.fromCode(kindCode);
    if (kind == null) {
      throw FormatException('spawn envelope: unknown kind $kindCode');
    }
    return WireHeader(
      version: wireVersion,
      kind: kind,
      typeId: view.getUint16(2, Endian.little),
      correlationId: view.getUint32(4, Endian.little),
      payloadLength: view.getUint32(8, Endian.little),
    );
  }

  /// Encodes a complete frame: header followed by [payload].
  ///
  /// [WireHeader.payloadLength] is taken from [payload], not from [header].
  static Uint8List encode(WireHeader header, [Uint8List? payload]) {
    final body = payload ?? _empty;
    final frame = Uint8List(headerLength + body.lengthInBytes);
    frame.setRange(
      0,
      headerLength,
      encodeHeader(
        WireHeader(
          version: header.version,
          kind: header.kind,
          typeId: header.typeId,
          correlationId: header.correlationId,
          payloadLength: body.lengthInBytes,
        ),
      ),
    );
    frame.setRange(headerLength, frame.length, body);
    return frame;
  }

  /// Decodes a complete frame produced by [encode].
  ///
  /// Throws [FormatException] when the header is malformed or the declared
  /// payload length does not match the bytes present.
  static (WireHeader, Uint8List) decode(Uint8List frame) {
    final header = decodeHeader(frame);
    final available = frame.lengthInBytes - headerLength;
    if (header.payloadLength != available) {
      throw FormatException(
        'spawn envelope: declared payload length ${header.payloadLength} '
        'but $available bytes follow the header',
      );
    }
    return (header, Uint8List.sublistView(frame, headerLength));
  }

  static final Uint8List _empty = Uint8List(0);
}

/// A protocol message with a stable type id and a byte encoding.
///
/// Implement this for anything richer than the portable values `spawn` carries
/// on its own (`null`, `bool`, `int`, `double`, `String`, typed data, and
/// lists and string-keyed maps of those). A [WireMessage] crosses every
/// boundary the package supports - including, in a later release, workers
/// hosted in C or in a wasm module.
///
/// ```dart
/// class ScanCmd implements WireMessage {
///   ScanCmd(this.bytes);
///   final Uint8List bytes;
///
///   @override
///   int get typeId => 1;
///
///   @override
///   Uint8List encode() => bytes;
///
///   static ScanCmd decode(Uint8List bytes) => ScanCmd(bytes);
/// }
///
/// void registerScanProtocol() {
///   WireRegistry.instance.register(1, ScanCmd.decode);
/// }
/// ```
///
/// Both ends must call the same registration function; a worker file and its
/// host normally import the same protocol library and call it from `main`.
abstract interface class WireMessage {
  /// Identifies the type on the wire. Must be in `1..[WireEnvelope.maxTypeId]`
  /// and unique within an application; `0` is reserved.
  int get typeId;

  /// Encodes this message's payload. The bytes must be independently owned -
  /// they may be transferred.
  Uint8List encode();
}

/// Rebuilds a [WireMessage] from the bytes [WireMessage.encode] produced.
typedef WireDecoder = WireMessage Function(Uint8List payload);

/// Maps [WireMessage.typeId] values to decoders.
///
/// There is one registry per isolate or worker: [WireRegistry.instance]. Both
/// ends of a channel must register the same ids.
class WireRegistry {
  /// Creates an empty registry. Applications normally use [instance].
  WireRegistry();

  /// The registry `spawn` decodes incoming frames with.
  static final WireRegistry instance = WireRegistry();

  final Map<int, WireDecoder> _decoders = <int, WireDecoder>{};

  /// Registers [decoder] for [typeId].
  ///
  /// Throws [ArgumentError] when [typeId] is out of range, and [StateError]
  /// when a *different* decoder is already registered for it. Registering the
  /// same decoder twice is allowed, so protocol libraries can offer an
  /// idempotent `registerX()` function.
  void register(int typeId, WireDecoder decoder) {
    if (typeId < 1 || typeId > WireEnvelope.maxTypeId) {
      throw ArgumentError.value(
        typeId,
        'typeId',
        'must be in 1..${WireEnvelope.maxTypeId} (0 is reserved)',
      );
    }
    final existing = _decoders[typeId];
    if (existing != null && existing != decoder) {
      throw StateError(
        'spawn: typeId $typeId is already registered to a different decoder',
      );
    }
    _decoders[typeId] = decoder;
  }

  /// Whether [typeId] has a decoder.
  bool contains(int typeId) => _decoders.containsKey(typeId);

  /// Decodes [payload] as the type registered for [typeId].
  ///
  /// Throws [StateError] when nothing is registered, naming the id - the usual
  /// cause is one end forgetting to call the protocol's registration function.
  WireMessage decode(int typeId, Uint8List payload) {
    final decoder = _decoders[typeId];
    if (decoder == null) {
      throw StateError(
        'spawn: no WireMessage decoder registered for typeId $typeId. '
        'Both ends must call the same WireRegistry.instance.register(...).',
      );
    }
    return decoder(payload);
  }

  /// Removes every registration. Intended for tests.
  void clear() => _decoders.clear();
}

/// Encodes the `hello` payload: UTF-8 JSON `{"v": 1, "caps": {...}}`.
Uint8List encodeHelloPayload(Map<String, Object?> caps) => utf8.encode(
  jsonEncode(<String, Object?>{'v': WireEnvelope.version, 'caps': caps}),
);

/// Decodes a `hello` payload into its `caps` object.
Map<String, Object?> decodeHelloPayload(Uint8List payload) {
  final decoded = jsonDecode(utf8.decode(payload));
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('spawn: hello payload is not a JSON object');
  }
  final caps = decoded['caps'];
  if (caps is! Map<String, Object?>) {
    throw const FormatException('spawn: hello payload has no caps object');
  }
  return caps;
}

/// Encodes an `error` payload: UTF-8 `type\nmessage\nstack`.
Uint8List encodeErrorPayload(String type, String message, String stack) =>
    utf8.encode('$type\n${message.replaceAll('\n', ' ')}\n$stack');

/// Decodes an `error` payload into its three parts.
(String type, String message, String stack) decodeErrorPayload(
  Uint8List payload,
) {
  final text = utf8.decode(payload, allowMalformed: true);
  final firstBreak = text.indexOf('\n');
  if (firstBreak < 0) return (text, '', '');
  final secondBreak = text.indexOf('\n', firstBreak + 1);
  if (secondBreak < 0) {
    return (text.substring(0, firstBreak), text.substring(firstBreak + 1), '');
  }
  return (
    text.substring(0, firstBreak),
    text.substring(firstBreak + 1, secondBreak),
    text.substring(secondBreak + 1),
  );
}
