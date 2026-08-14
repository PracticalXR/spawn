import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:spawn/spawn.dart';
// The package's own tests reach into src/ for the pieces that are internal to
// consumers but are exactly what these tests exist to pin.
import 'package:spawn/src/payload.dart';
import 'package:spawn/src/wire.dart'
    show
        decodeErrorPayload,
        decodeHelloPayload,
        encodeErrorPayload,
        encodeHelloPayload;
import 'package:test/test.dart';

class _Ping implements WireMessage {
  const _Ping(this.text);

  @override
  int get typeId => 7;

  @override
  Uint8List encode() => utf8.encode(text);

  final String text;

  static _Ping decode(Uint8List bytes) => _Ping(utf8.decode(bytes));
}

class _BadId implements WireMessage {
  @override
  int get typeId => 0;

  @override
  Uint8List encode() => Uint8List(0);
}

void main() {
  group('envelope', () {
    test('round-trips every kind', () {
      for (final kind in WireKind.values) {
        final payload = Uint8List.fromList(<int>[1, 2, 3, kind.code]);
        final header = WireHeader(
          kind: kind,
          typeId: 0x1234,
          correlationId: 0xDEADBEEF,
        );
        final frame = WireEnvelope.encode(header, payload);
        final (decoded, body) = WireEnvelope.decode(frame);

        expect(decoded.version, WireEnvelope.version);
        expect(decoded.kind, kind);
        expect(decoded.typeId, 0x1234);
        expect(decoded.correlationId, 0xDEADBEEF);
        expect(decoded.payloadLength, payload.length);
        expect(body, payload);
      }
    });

    test('header is exactly 12 little-endian bytes', () {
      final bytes = WireEnvelope.encodeHeader(
        const WireHeader(
          kind: WireKind.request,
          typeId: 0x0201,
          correlationId: 0x04030201,
          payloadLength: 0x08070605,
        ),
      );
      expect(bytes.length, WireEnvelope.headerLength);
      expect(bytes, <int>[1, 3, 1, 2, 1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('takes payloadLength from the payload, not the header', () {
      final frame = WireEnvelope.encode(
        const WireHeader(kind: WireKind.message, payloadLength: 999),
        Uint8List(4),
      );
      final (header, payload) = WireEnvelope.decode(frame);
      expect(header.payloadLength, 4);
      expect(payload.length, 4);
    });

    test('round-trips fuzzed lengths', () {
      final random = Random(20260817);
      for (var trial = 0; trial < 200; trial++) {
        final length = random.nextInt(4096);
        final payload = Uint8List.fromList(
          List<int>.generate(length, (_) => random.nextInt(256)),
        );
        final frame = WireEnvelope.encode(
          WireHeader(
            kind: WireKind.values[random.nextInt(WireKind.values.length)],
            typeId: random.nextInt(0x10000),
            correlationId: random.nextInt(0x7FFFFFFF),
          ),
          payload,
        );
        final (header, body) = WireEnvelope.decode(frame);
        expect(header.payloadLength, length);
        expect(body, payload);
      }
    });

    test('empty payload is legal', () {
      final (header, payload) = WireEnvelope.decode(
        WireEnvelope.encode(const WireHeader(kind: WireKind.bye)),
      );
      expect(header.kind, WireKind.bye);
      expect(payload, isEmpty);
    });

    test('rejects a short buffer', () {
      expect(
        () => WireEnvelope.decodeHeader(Uint8List(11)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects an unknown version', () {
      final frame = WireEnvelope.encode(const WireHeader(kind: WireKind.bye));
      frame[0] = 2;
      expect(
        () => WireEnvelope.decode(frame),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('unsupported version 2'),
          ),
        ),
      );
    });

    test('rejects an unknown kind', () {
      final frame = WireEnvelope.encode(const WireHeader(kind: WireKind.bye));
      frame[1] = 99;
      expect(
        () => WireEnvelope.decode(frame),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('unknown kind 99'),
          ),
        ),
      );
    });

    test('rejects a payload length that does not match the bytes', () {
      final frame = WireEnvelope.encode(
        const WireHeader(kind: WireKind.message),
        Uint8List(8),
      );
      frame[8] = 16; // claim 16 bytes when 8 follow
      expect(() => WireEnvelope.decode(frame), throwsA(isA<FormatException>()));
    });

    test('survives arbitrary garbage without crashing', () {
      final random = Random(7);
      for (var trial = 0; trial < 500; trial++) {
        final bytes = Uint8List.fromList(
          List<int>.generate(random.nextInt(40), (_) => random.nextInt(256)),
        );
        try {
          WireEnvelope.decode(bytes);
        } on FormatException {
          // The only failure mode a malformed frame is allowed to have.
        }
      }
    });
  });

  group('hello and error payloads', () {
    test('hello carries caps', () {
      const caps = SpawnCaps(
        hosted: SpawnHost.dart,
        payload: SpawnPayload.js,
        zeroCopyTransfer: true,
      );
      final decoded = SpawnCaps.fromJson(
        decodeHelloPayload(encodeHelloPayload(caps.toJson())),
      );
      expect(decoded.hosted, SpawnHost.dart);
      expect(decoded.payload, SpawnPayload.js);
      expect(decoded.zeroCopyTransfer, isTrue);
    });

    test('caps from an unknown future value fall back instead of throwing', () {
      final caps = SpawnCaps.fromJson(<String, Object?>{
        'hosted': 'quantum',
        'payload': 'llvm',
        'zeroCopyTransfer': true,
      });
      expect(caps.hosted, SpawnHost.dart);
      expect(caps.payload, SpawnPayload.aot);
    });

    test('error round-trips type, message and stack', () {
      final (type, message, stack) = decodeErrorPayload(
        encodeErrorPayload('StateError', 'bad thing', 'line 1\nline 2'),
      );
      expect(type, 'StateError');
      expect(message, 'bad thing');
      expect(stack, 'line 1\nline 2');
    });

    test('error with no stack still parses', () {
      final (type, message, stack) = decodeErrorPayload(
        encodeErrorPayload('Exception', 'nope', ''),
      );
      expect(type, 'Exception');
      expect(message, 'nope');
      expect(stack, isEmpty);
    });
  });

  group('registry', () {
    setUp(WireRegistry.instance.clear);
    tearDown(WireRegistry.instance.clear);

    test('decodes a registered type', () {
      WireRegistry.instance.register(7, _Ping.decode);
      const ping = _Ping('hello');
      final decoded = WireRegistry.instance.decode(7, ping.encode());
      expect(decoded, isA<_Ping>());
      expect((decoded as _Ping).text, 'hello');
    });

    test('registering the same decoder twice is idempotent', () {
      WireRegistry.instance
        ..register(7, _Ping.decode)
        ..register(7, _Ping.decode);
      expect(WireRegistry.instance.contains(7), isTrue);
    });

    test('registering a different decoder for one id throws', () {
      WireRegistry.instance.register(7, _Ping.decode);
      expect(
        () => WireRegistry.instance.register(7, (_) => const _Ping('other')),
        throwsA(isA<StateError>()),
      );
    });

    test('id 0 is reserved', () {
      expect(
        () => WireRegistry.instance.register(0, _Ping.decode),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('ids above 0xFFFF do not fit the header', () {
      expect(
        () => WireRegistry.instance.register(0x10000, _Ping.decode),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an unregistered id names the id and the fix', () {
      expect(
        () => WireRegistry.instance.decode(42, Uint8List(0)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('typeId 42'), contains('Both ends')),
          ),
        ),
      );
    });

    test('a WireMessage with typeId 0 is rejected when sent', () {
      expect(() => encodeValue(_BadId()), throwsA(isA<ArgumentError>()));
    });
  });

  group('portability', () {
    test('accepts the portable set', () {
      for (final value in <Object?>[
        null,
        true,
        42,
        3.5,
        'text',
        Uint8List(4),
        Float32List(2),
        Uint8List(4).buffer,
        <Object?>[1, 'two', null, Uint8List(1)],
        <String, Object?>{
          'a': 1,
          'b': <Object?>[true],
        },
      ]) {
        expect(() => checkPortable(value), returnsNormally);
      }
    });

    test('accepts an explicitly wrapped platform value', () {
      expect(
        () => checkPortable(const PlatformValue('anything at all')),
        returnsNormally,
      );
      expect(
        () =>
            checkPortable(<String, Object?>{'frame': const PlatformValue(42)}),
        returnsNormally,
      );
      expect(
        () => checkTransfer(<Object>[const PlatformValue(42)]),
        returnsNormally,
      );
    });

    test('rejects a plain object and names WireMessage', () {
      expect(
        () => checkPortable(Object()),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('WireMessage'), contains('PlatformValue')),
          ),
        ),
      );
    });

    test('rejects non-String map keys', () {
      expect(
        () => checkPortable(<Object?, Object?>{1: 'a'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a cycle instead of hanging', () {
      final list = <Object?>[1];
      list.add(list);
      expect(
        () => checkPortable(list),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('cyclic'),
          ),
        ),
      );
    });

    test('names the path to the offending value', () {
      expect(
        () => checkPortable(<String, Object?>{
          'outer': <Object?>[1, Object()],
        }),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.name,
            'name',
            'message["outer"][1]',
          ),
        ),
      );
    });

    test('transfer entries must be buffers', () {
      expect(
        () => checkTransfer(<Object>['not a buffer']),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => checkTransfer(<Object>[Uint8List(1), Uint8List(1).buffer]),
        returnsNormally,
      );
    });
  });
}
