@TestOn('vm')
library;

/// `bufferMatches` — the predicate that decides whether the native backend's
/// transfer machinery engages at all.
///
/// 🔴 On the VM, every `.buffer` access on internal typed data allocates a
/// FRESH wrapper object: `identical(u.buffer, u.buffer)` is FALSE. The
/// original identical-based comparisons therefore never matched a
/// `transfer: [bytes.buffer]` against its own bytes, and the designed
/// transfer path was dead code from the day it shipped — invisible, because
/// the fallback (plain isolate send) delivers identical bytes. `ByteBuffer.==`
/// on the VM compares the BACKING STORE, which is the question actually being
/// asked. These tests are the only thing distinguishing the two.

import 'dart:typed_data';

import 'package:spawn/src/payload.dart';
import 'package:test/test.dart';

void main() {
  test('a typed list matches its own buffer across separate .buffer reads',
      () {
    final u = Uint8List(16);
    // The exact shape every caller produces: the transfer list is built from
    // one `.buffer` read, the match runs against another.
    final transferEntry = u.buffer;
    expect(bufferMatches(u, transferEntry), isTrue,
        reason: 'identical() is false for these on the VM — the wrapper is '
            'fresh per access; == compares the backing store');
    expect(bufferMatches(transferEntry, u), isTrue);
  });

  test('two views of one buffer match; unrelated buffers do not', () {
    final u = Uint8List(32);
    final view = Uint8List.view(u.buffer, 8, 8);
    expect(bufferMatches(view, u.buffer), isTrue);
    expect(bufferMatches(view, u), isTrue);
    expect(bufferMatches(Uint8List(32), u.buffer), isFalse,
        reason: 'equal content is not the same buffer');
  });
}
