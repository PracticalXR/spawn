/// Native twin of [measureOpaque]: there are no opaque platform objects to
/// measure on the VM, so this exists only to keep the worker file compiling
/// for both backends.
library;

/// Always throws; the opaque-value tests are browser-only.
int measureOpaque(Object? value, String property) =>
    throw UnsupportedError('opaque platform values are a web concept');
