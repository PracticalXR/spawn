@TestOn('browser || node')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:spawn/src/backend/web.dart' show encodeWebFrame;
import 'package:spawn/src/frame.dart';
import 'package:spawn/src/platform_value.dart';
import 'package:spawn/src/wire.dart';
import 'package:test/test.dart';

@JS('MessageChannel')
extension type _Channel._(JSObject _) implements JSObject {
  external _Channel();
  external _Port get port1;
  external _Port get port2;
}

extension type _Port._(JSObject _) implements JSObject {
  external set onmessage(JSFunction callback);
  external void postMessage(JSAny? message, JSArray<JSAny?> transfer);
  external void close();
}

@JS('Object.is')
external bool _same(JSAny? left, JSAny? right);

@JS('globalThis')
external JSObject get _global;

JSObject _payload(JSObject wire) => wire.getProperty<JSObject>('p'.toJS);
JSArrayBuffer _backing(JSObject view) =>
    view.getProperty<JSArrayBuffer>('buffer'.toJS);
int _number(JSObject object, String key) =>
    object.getProperty<JSNumber>(key.toJS).toDartInt;

Future<JSObject> _post(JSObject wire, JSArray<JSAny?> transfer) async {
  final channel = _Channel();
  final received = Completer<JSObject>();
  channel.port2.onmessage = ((JSObject event) {
    received.complete(event.getProperty<JSObject>('data'.toJS));
  }).toJS;
  try {
    channel.port1.postMessage(wire, transfer);
    return await received.future.timeout(const Duration(seconds: 5));
  } finally {
    channel.port1.close();
    channel.port2.close();
  }
}

void main() {
  // package:test's Wasm failure reporter asks Uri.base even on Node.
  if (!_global.hasProperty('location'.toJS).toDart) {
    _global.setProperty(
      'location'.toJS,
      JSObject()..setProperty('href'.toJS, 'file:///spawn-tests/'.toJS),
    );
  }
  test(
    'request aliases share the exact transferred backing and offsets',
    () async {
      final source = Uint8List.fromList(List.generate(64, (i) => i));
      final bytes = Uint8List.view(source.buffer, 8, 16);
      final words = Uint32List.view(source.buffer, 8, 4);
      final expected = List<int>.from(bytes);
      final (wire, transfers) = encodeWebFrame(
        Frame(
          WireKind.request,
          correlationId: 71,
          payload: {
            'bytes': bytes,
            'again': bytes,
            'words': words,
            'backing': source.buffer,
          },
          transfers: [source.buffer, bytes, words, source.buffer],
        ),
      );
      final payload = _payload(wire);
      final sentBytes = payload.getProperty<JSUint8Array>('bytes'.toJS);
      final sentBacking = _backing(sentBytes);
      expect(transfers.length, 1);
      expect(
        _same(transfers[0], sentBacking),
        isTrue,
        reason: 'moving a separate clone leaves the payload on the copy path',
      );
      expect(
        _same(
          sentBacking,
          _backing(payload.getProperty<JSObject>('words'.toJS)),
        ),
        isTrue,
      );
      expect(
        _same(sentBacking, payload.getProperty<JSAny>('backing'.toJS)),
        isTrue,
      );
      expect(
        _same(sentBytes, payload.getProperty<JSAny>('again'.toJS)),
        isTrue,
      );
      expect(_number(sentBytes, 'byteOffset'), 8);
      final received = await _post(wire, transfers);
      expect(
        _number(sentBacking, 'byteLength'),
        0,
        reason: 'the actual payload backing must detach on MessageChannel',
      );
      final got = _payload(received);
      final receivedBytes = got.getProperty<JSUint8Array>('bytes'.toJS);
      expect(receivedBytes.toDart, expected);
      expect(_number(receivedBytes, 'byteOffset'), 8);
      expect(
        _same(
          _backing(receivedBytes),
          _backing(got.getProperty<JSObject>('words'.toJS)),
        ),
        isTrue,
      );
      expect(
        _same(receivedBytes, got.getProperty<JSAny>('again'.toJS)),
        isTrue,
      );
    },
  );

  test('encoded replies transfer their actual byte view', () async {
    final source = Uint8List.fromList(List.generate(32, (i) => 255 - i));
    final bytes = Uint8List.view(source.buffer, 4, 12);
    final expected = List<int>.from(bytes);
    final (wire, transfers) = encodeWebFrame(
      Frame(
        WireKind.response,
        typeId: 42,
        correlationId: 72,
        payload: bytes,
        transfers: [bytes.buffer],
      ),
    );
    final sent = _payload(wire) as JSUint8Array;
    final backing = _backing(sent);
    expect(_same(backing, transfers[0]), isTrue);
    final received = await _post(wire, transfers);
    expect(_number(backing, 'byteLength'), 0);
    expect((_payload(received) as JSUint8Array).toDart, expected);
    final header = WireEnvelope.decodeHeader(
      received.getProperty<JSUint8Array>('h'.toJS).toDart,
    );
    expect(header.kind, WireKind.response);
    expect(header.typeId, 42);
    expect(header.correlationId, 72);
    expect(header.payloadLength, 12);
  });

  test('all supported typed views retain byte layout on one backing', () async {
    final source = Uint8List.fromList(List.generate(64, (i) => i + 17));
    final expected = List<int>.from(source);
    final buffer = source.buffer;
    final views = <String, TypedData>{
      'Uint8Array': Uint8List.view(buffer, 8, 16),
      'Int8Array': Int8List.view(buffer, 8, 16),
      'Uint8ClampedArray': Uint8ClampedList.view(buffer, 8, 16),
      'Int16Array': Int16List.view(buffer, 8, 8),
      'Uint16Array': Uint16List.view(buffer, 8, 8),
      'Int32Array': Int32List.view(buffer, 8, 4),
      'Uint32Array': Uint32List.view(buffer, 8, 4),
      'Float32Array': Float32List.view(buffer, 8, 4),
      'Float64Array': Float64List.view(buffer, 8, 2),
      'DataView': ByteData.view(buffer, 8, 16),
    };
    final (wire, transfers) = encodeWebFrame(
      Frame(WireKind.message, payload: views, transfers: [buffer]),
    );
    final received = _payload(await _post(wire, transfers));
    JSArrayBuffer? receivedBacking;
    for (final name in views.keys) {
      final view = received.getProperty<JSObject>(name.toJS);
      final constructor = view.getProperty<JSObject>('constructor'.toJS);
      expect(constructor.getProperty<JSString>('name'.toJS).toDart, name);
      expect(_number(view, 'byteOffset'), 8);
      expect(_number(view, 'byteLength'), 16);
      final backing = _backing(view);
      receivedBacking ??= backing;
      expect(_same(backing, receivedBacking), isTrue);
      expect(JSUint8Array(backing).toDart, expected);
    }
  });

  test(
    'JS-origin storage still detaches with duplicate opaque entries',
    () async {
      final js = JSUint8Array.withLength(24);
      final source = js.toDart..setAll(0, List.generate(24, (i) => i * 3));
      final backing = _backing(js);
      final view = Uint8List.view(source.buffer, 4, 8);
      final expected = List<int>.from(view);
      final (wire, transfers) = encodeWebFrame(
        Frame(
          WireKind.response,
          payload: {'view': view, 'opaque': PlatformValue(backing)},
          transfers: [source.buffer, view, PlatformValue(backing)],
        ),
      );
      expect(transfers.length, 1);
      final received = await _post(wire, transfers);
      expect(_number(backing, 'byteLength'), 0);
      final got = _payload(received).getProperty<JSUint8Array>('view'.toJS);
      expect(got.toDart, expected);
    },
  );

  test(
    'unlisted slices keep view-only conversion and are not detached',
    () async {
      final source = Uint8List(1024 * 1024);
      final slice = Uint8List.view(source.buffer, 512, 8)..fillRange(0, 8, 73);
      final normal = slice.toJS;
      final (wire, transfers) = encodeWebFrame(
        Frame(WireKind.request, payload: {'slice': slice}),
      );
      final converted = _payload(wire).getProperty<JSUint8Array>('slice'.toJS);
      expect(
        _number(_backing(converted), 'byteLength'),
        _number(_backing(normal), 'byteLength'),
        reason: 'an unlisted small slice must not acquire a whole-buffer copy',
      );
      expect(_number(converted, 'byteOffset'), _number(normal, 'byteOffset'));
      expect(transfers.length, 0);
      final received = await _post(wire, transfers);
      expect(_number(converted, 'byteLength'), 8);
      expect(source.length, 1024 * 1024);
      expect(
        _payload(received).getProperty<JSUint8Array>('slice'.toJS).toDart,
        List.filled(8, 73),
      );
    },
  );

  test(
    'unrelated transfer entries keep their existing move semantics',
    () async {
      final unrelated = JSUint8Array.withLength(24);
      final source = Uint8List.fromList([7, 8, 9]);
      final (wire, transfers) = encodeWebFrame(
        Frame(
          WireKind.message,
          payload: {
            'nested': [source, true, null, 'ok', 1.5],
          },
          transfers: [unrelated.toDart.buffer, unrelated.toDart.buffer],
        ),
      );
      expect(transfers.length, 1);
      final payloadBacking = _backing(
        _payload(wire).getProperty<JSArray>('nested'.toJS)[0] as JSObject,
      );
      expect(_same(payloadBacking, transfers[0]), isFalse);
      final received = await _post(wire, transfers);
      expect(_number(_backing(unrelated), 'byteLength'), 0);
      expect(_number(payloadBacking, 'byteLength'), 3);
      final nested = _payload(received).getProperty<JSArray>('nested'.toJS);
      expect((nested[0] as JSUint8Array).toDart, [7, 8, 9]);
      expect((nested[1] as JSBoolean).toDart, isTrue);
      expect(nested[2], isNull);
      expect((nested[3] as JSString).toDart, 'ok');
      expect((nested[4] as JSNumber).toDartDouble, 1.5);
    },
  );
}
