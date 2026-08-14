// The web half of the example. The spawn code below is character-for-character
// what `example/spawn_example.dart` runs on the VM - only the reporting
// differs, because one prints to a console and the other writes to a page.
//
// Build and serve:
//
//     dart run spawn:build example/workers
//     dart compile js -O2 -o example/web/main.dart.js example/web/main.dart
//     dart pub global run dhttpd --path example/web
//
// Then open the page and watch: the sieve runs while the spinner keeps
// spinning, which is the entire point.

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:spawn/spawn.dart';

import '../workers/primes_worker.dart';

/// The payload sits next to the page, so a relative URL finds it.
const webPrimesEntry = SpawnEntry.inline(
  primesWorker,
  asset: './workers/build/primes_worker.dart.js',
);

Future<void> main() async {
  _log('spawning...');
  final worker = await spawn(webPrimesEntry);
  _log('worker started: ${worker.caps}');

  final subscription = worker.events.listen((event) {
    final sieve = event! as Uint8List;
    _log('sieve of ${sieve.length} bytes arrived');
  });

  worker.post(2000000);
  await Future<void>.delayed(const Duration(milliseconds: 800));
  _log('primes found: ${await worker.request<int>('count')}');

  await subscription.cancel();
  await worker.close();
  _log('closed cleanly');
}

void _log(String message) {
  final output = _document.getElementById('output');
  if (output == null) return;
  output.textContent = '${output.textContent ?? ''}$message\n';
}

@JS('document')
external _Document get _document;

extension type _Document._(JSObject _) implements JSObject {
  external _Element? getElementById(String id);
}

extension type _Element._(JSObject _) implements JSObject {
  external String? get textContent;
  external set textContent(String? value);
}
