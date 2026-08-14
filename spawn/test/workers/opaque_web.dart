/// Reads a property off an opaque platform object, to prove the object that
/// crossed the worker boundary is the real one and not a husk.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Returns [value]'s integer [property].
int measureOpaque(Object? value, String property) {
  final object = value! as JSObject;
  return object.getProperty<JSNumber>(property.toJS).toDartInt;
}
